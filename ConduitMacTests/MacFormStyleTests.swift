import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Every `Form` in the shared views is the grouped style on Mac (D14). The
/// app-module `Form` (ConduitMac/Compat/App/FormShim.swift) shadows
/// `SwiftUI.Form` and applies `.formStyle(.grouped)` itself, because a style set
/// at the app root does not reach a sheet. Observable: a grouped Form is backed
/// by a scroll view (`HostingScrollView`, the card list); the default
/// `.columns` Form is a plain stack of controls with none.
@MainActor
final class MacFormStyleTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
    }

    private struct AppForm: View {
        var body: some View {
            ConduitMac.Form {
                Section {
                    Toggle("Alpha row", isOn: .constant(true))
                } header: { Text("Alpha header") } footer: { Text("Alpha footer") }
            }
        }
    }

    /// What a view's own `Form` gets with no help: SwiftUI's, unstyled.
    private struct PlainForm: View {
        var body: some View {
            SwiftUI.Form {
                Section {
                    Toggle("Alpha row", isOn: .constant(true))
                } header: { Text("Alpha header") } footer: { Text("Alpha footer") }
            }
        }
    }

    /// Presents `content` in a sheet, and, when `nested`, presents a second
    /// sheet from it (as the composer's Model, Skills and Parent pickers are).
    private struct Presenter<Content: View>: View {
        let content: Content
        var nested = false
        @State private var shown = true
        @State private var innerShown = true
        var body: some View {
            Color.clear.frame(width: 500, height: 400)
                .sheet(isPresented: $shown) {
                    if nested {
                        Color.clear.frame(width: 300, height: 200)
                            .sheet(isPresented: $innerShown) { content }
                    } else {
                        content
                    }
                }
        }
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = HostedTestSupport.host(view.frame(width: 500, height: 400), size: NSSize(width: 500, height: 400))
        windows.append(window)
        return window
    }

    /// The window whose content holds the form: the window itself, its sheet,
    /// or its sheet's sheet.
    private func target(of window: NSWindow, depth: Int) -> NSWindow? {
        var current: NSWindow? = window
        for _ in 0..<depth {
            _ = HostedTestSupport.waitUntil(timeout: 5) { current?.attachedSheet != nil }
            current = current?.attachedSheet
        }
        HostedTestSupport.settle(0.6)
        return current
    }

    private func isGrouped(_ window: NSWindow?) -> Bool {
        func has(_ view: NSView) -> Bool {
            String(describing: type(of: view)).contains("HostingScrollView") || view.subviews.contains(where: has)
        }
        guard let root = window?.contentView else { return false }
        return has(root)
    }

    func testAppFormIsGroupedInAWindow() {
        XCTAssertTrue(isGrouped(target(of: host(AppForm()), depth: 0)), "the app Form is a grouped card list")
        XCTAssertFalse(isGrouped(target(of: host(PlainForm()), depth: 0)), "control: SwiftUI's own Form is the columns style")
    }

    /// The reason for the shim. Red when the shim is removed: the sheet's Form
    /// is then `SwiftUI.Form`, and the sheet shows `.columns`.
    func testAppFormIsGroupedInASheet() {
        XCTAssertTrue(isGrouped(target(of: host(Presenter(content: AppForm())), depth: 1)))
    }

    func testAppFormIsGroupedInASheetOpenedFromASheet() {
        XCTAssertTrue(isGrouped(target(of: host(Presenter(content: AppForm(), nested: true)), depth: 2)))
    }

    /// An explicit `.formStyle(...)` on a shared Form wins over the shim's grouped default.
    func testAnExplicitFormStyleOnTheShimWins() {
        let window = host(ConduitMac.Form {
            Section { Toggle("Alpha row", isOn: .constant(true)) } header: { Text("Alpha header") }
        }.formStyle(.columns))
        XCTAssertFalse(isGrouped(target(of: window, depth: 0)), "the outer .columns style is applied, not the grouped default")
    }

    /// The finding behind D14: `.formStyle(.grouped)` set at the presenter, at
    /// any level above `.sheet`, does not reach the sheet's Form. If this goes
    /// red on a newer macOS, one root `.formStyle(.grouped)` works there and the
    /// shim can go.
    func testFormStyleSetAboveASheetDoesNotReachIt() {
        let window = host(Presenter(content: PlainForm()).formStyle(.grouped))
        XCTAssertFalse(isGrouped(target(of: window, depth: 1)))
        let nested = host(Presenter(content: PlainForm(), nested: true).formStyle(.grouped))
        XCTAssertFalse(isGrouped(target(of: nested, depth: 2)))
    }
}

/// The New task composer as a Mac sheet (D14): the Model / Skills / Depends
/// rows are full-width rows, the description is a sized editor, and nothing is
/// clipped at the right edge.
@MainActor
final class MacComposerSheetTests: XCTestCase {
    private struct Presenter: View {
        let store: KanbanStore
        @State private var shown = true
        var body: some View {
            Color.clear.frame(width: 900, height: 1000)
                .sheet(isPresented: $shown) {
                    KanbanTaskComposerView(initialStatus: "todo").environmentObject(store)
                }
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
        }
    }

    func testComposerSheetGeometry() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let window = HostedTestSupport.host(Presenter(store: KanbanStore(defaults: suite.defaults)), size: NSSize(width: 900, height: 1000))
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 8) { window.attachedSheet != nil })
        let sheet = try XCTUnwrap(window.attachedSheet)
        HostedTestSupport.settle(0.8)
        AccessibilityTreeBoost.set(true)
        HostedTestSupport.settle(0.6)
        defer { AccessibilityTreeBoost.set(false) }

        let width = try XCTUnwrap(sheet.contentView).bounds.width
        XCTAssertGreaterThanOrEqual(width, 520, "a readable sheet width")
        let nodes = AccessibilityProbe.nodes(in: sheet)
        let rows = nodes.filter { ($0.label ?? "").hasPrefix("Model,") || ($0.label ?? "").hasPrefix("Skills,") }
        XCTAssertEqual(rows.count, 2, "Model and Skills rows: \(nodes.compactMap(\.label))")
        for row in rows {
            XCTAssertGreaterThan(row.frame.width, width * 0.8, "\(row.label ?? ""): the whole row is the button")
        }
        let editor = try XCTUnwrap(nodes.first { $0.label == "Task description" }, "the description editor")
        XCTAssertGreaterThanOrEqual(editor.frame.height, 80)
        XCTAssertLessThanOrEqual(editor.frame.height, 140)
        let heading = try XCTUnwrap(nodes.first { $0.label == "Basics" }, "the Basics heading")
        XCTAssertLessThan(heading.frame.minY, editor.frame.minY, "the section header is above its rows")
        for node in nodes where node.frame.width > 1 {
            XCTAssertLessThanOrEqual(node.frame.maxX, width + 1, "nothing clipped at the right edge: \(node.role) \(node.label ?? "")")
        }
    }

    // MARK: Row clicks and the description prompt

    private func openComposer() throws -> (parent: NSWindow, sheet: NSWindow, suite: (defaults: UserDefaults, name: String)) {
        let suite = HostedTestSupport.makeSuite()
        let parent = HostedTestSupport.host(Presenter(store: KanbanStore(defaults: suite.defaults)), size: NSSize(width: 900, height: 1000))
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 8) { parent.attachedSheet != nil })
        let sheet = try XCTUnwrap(parent.attachedSheet)
        HostedTestSupport.settle(0.8)
        AccessibilityTreeBoost.set(true)
        HostedTestSupport.settle(0.6)
        return (parent, sheet, suite)
    }

    /// A left click at `point` (in the content view's top-left coordinates), through the window's event path.
    private func click(at point: CGPoint, in window: NSWindow) throws {
        let host = try XCTUnwrap(window.contentView)
        let location = host.convert(NSPoint(x: point.x, y: point.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            HostedTestSupport.settle(0.05)
        }
    }

    /// The whole row is the button: a click in the Spacer zone (45% across, between
    /// the title and the value) opens the picker sheet, as the old bordered slab did.
    /// Red against `.buttonStyle(.plain).contentShape(Rectangle())` applied outside the Button.
    func testClickingTheSpacerOfTheModelSkillsAndDependsRowsOpensThePicker() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        defer { AccessibilityTreeBoost.set(false) }
        for prefix in ["Model,", "Skills,", "Depends on,"] {
            let (parent, sheet, suite) = try openComposer()
            defer { HostedTestSupport.tearDown(parent); HostedTestSupport.dropSuite(suite) }
            let row = try XCTUnwrap(AccessibilityProbe.nodes(in: sheet).first { ($0.label ?? "").hasPrefix(prefix) }, "\(prefix) row")
            XCTAssertNil(sheet.attachedSheet)
            try click(at: CGPoint(x: row.frame.minX + row.frame.width * 0.45, y: row.frame.midY), in: sheet)
            XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 4) { sheet.attachedSheet != nil },
                          "\(prefix) a click 45% across the row opens its picker (row \(row.frame))")
        }
    }

    /// The "Description" prompt shows while the draft is empty and goes once there is text.
    func testDescriptionPromptShowsWhileEmptyAndGoesAfterTyping() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        defer { AccessibilityTreeBoost.set(false) }
        let (parent, sheet, suite) = try openComposer()
        defer { HostedTestSupport.tearDown(parent); HostedTestSupport.dropSuite(suite) }
        func promptShown() -> Bool {
            var found = false
            func walk(_ element: NSObject, depth: Int) {
                let role: String? = element.axValue("accessibilityRole")
                let value: String? = element.axValue("accessibilityValue")
                let label: String? = element.axValue("accessibilityLabel")
                if role == NSAccessibility.Role.staticText.rawValue, value == "Description" || label == "Description" { found = true }
                let kids: [Any]? = element.axValue("accessibilityChildren")
                if depth < 12 { for kid in kids ?? [] { if let o = kid as? NSObject { walk(o, depth: depth + 1) } } }
            }
            for kid in sheet.contentView?.accessibilityChildren() ?? [] { if let o = kid as? NSObject { walk(o, depth: 0) } }
            return found
        }
        XCTAssertTrue(promptShown(), "the Description prompt shows while the draft is empty")
        var textView: NSTextView?
        func find(_ view: NSView) {
            // Not a text field's field editor (the Title field's): the TextEditor's own view.
            if textView == nil, let tv = view as? NSTextView, tv.isEditable, !(tv.delegate is NSTextField) { textView = tv; return }
            view.subviews.forEach(find)
        }
        if let root = sheet.contentView { find(root) }
        let editor = try XCTUnwrap(textView, "the description editor")
        XCTAssertTrue(sheet.makeFirstResponder(editor))
        editor.insertText("Write the docs", replacementRange: NSRange(location: 0, length: 0))
        HostedTestSupport.settle(0.6)
        XCTAssertFalse(promptShown(), "the prompt goes once there is text")
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        HostedTestSupport.settle(0.6)
        XCTAssertTrue(promptShown(), "and comes back when the text is cleared")
    }
}
