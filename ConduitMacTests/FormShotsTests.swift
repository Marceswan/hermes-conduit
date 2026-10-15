import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

/// Writes PNGs of the app's sheets (Kanban New task, board editor, filters,
/// task detail, bot editor), dark and light, from a real offscreen `NSWindow`:
/// `ImageRenderer` does not draw AppKit-backed Form controls. Each sheet is
/// presented through `.sheet` from a host shaped like the app's root, so the
/// picture shows what the user sees, including the grouped Form style. Off by
/// default; run with `TEST_RUNNER_CONDUIT_FORM_SHOTS=1`. Output goes to
/// `$CONDUIT_FORM_SHOTS_DIR` (set it as `TEST_RUNNER_CONDUIT_FORM_SHOTS_DIR`)
/// or `/private/tmp/conduit-form-shots/`; delete it afterwards.
@MainActor
final class FormShotsTests: XCTestCase {
    private var directory: String {
        ProcessInfo.processInfo.environment["CONDUIT_FORM_SHOTS_DIR"] ?? "/private/tmp/conduit-form-shots"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_FORM_SHOTS"] == "1",
                          "set TEST_RUNNER_CONDUIT_FORM_SHOTS=1 to write PNGs")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// The host the sheet hangs from: the app's root modifiers that matter to a
    /// sheet (environment objects, tint), around a plain body.
    private struct SheetHost<Sheet: View>: View {
        let sheet: () -> Sheet
        @State private var presented = true
        var body: some View {
            Color.clear
                .frame(width: 900, height: 1000)
                .sheet(isPresented: $presented) { sheet() }
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .tint(.conduitAccent)
        }
    }

    /// Presents `sheet`, lets it settle, runs `prepare` on the sheet window,
    /// and writes `<name>-dark.png` and `<name>-light.png`.
    private func shoot<Sheet: View>(_ name: String, prepare: (NSWindow) -> Void = { _ in },
                                    @ViewBuilder _ sheet: @escaping () -> Sheet) throws {
        for dark in [true, false] {
            let parent = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 900, height: 1000),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            parent.contentView = NSHostingView(rootView: SheetHost(sheet: sheet))
            parent.orderFront(nil)
            defer { HostedTestSupport.tearDown(parent) }
            XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 8) { parent.attachedSheet != nil }, "\(name): no sheet")
            guard let window = parent.attachedSheet else { continue }
            HostedTestSupport.settle(0.8)
            prepare(window)
            HostedTestSupport.settle(0.5)
            // The theme frame, not the content view: `cacheDisplay` of the content
            // view alone drops the SwiftUI text and the window background.
            let frame = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
            let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "\(directory)/\(name)-\(dark ? "dark" : "light").png"))
            let view = frame
            print("FORMSHOT \(name)-\(dark ? "dark" : "light") \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
    }

    private func store() -> KanbanStore {
        KanbanStore(defaults: UserDefaults(suiteName: "conduit.mac.tests.\(UUID().uuidString)")!)
    }

    /// Clicks the first switch in the sheet window (the grouped style draws a
    /// Toggle as an `NSSwitch`, not a checkbox button).
    private func clickFirstSwitch(in window: NSWindow) {
        var found: NSControl?
        func walk(_ view: NSView) {
            if found == nil, let control = view as? NSControl, control is NSSwitch { found = control; return }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        XCTAssertNotNil(found, "no NSSwitch in the sheet")
        found?.performClick(nil)
        HostedTestSupport.settle(0.4)
    }

    func testNewTaskComposer() throws {
        let store = store()
        try shoot("composer") {
            KanbanTaskComposerView(initialStatus: "todo").environmentObject(store)
        }
    }

    func testNewTaskComposerWithGoalMode() throws {
        let store = store()
        try shoot("composer-goal", prepare: { clickFirstSwitch(in: $0) }) {
            KanbanTaskComposerView(initialStatus: "todo").environmentObject(store)
        }
    }

    func testBoardEditorCreate() throws {
        let store = store()
        try shoot("board-editor") {
            KanbanBoardEditorView(mode: .create).environmentObject(store)
        }
    }

    func testBoardEditorSettings() throws {
        let store = store()
        let board = KanbanBoardMetadata(slug: "default", name: "Default", description: "Everything in flight",
                                        isCurrent: true, total: 12, defaultWorkdir: "/Users/me/project",
                                        defaultWorkspaceKind: "dir")
        try shoot("board-settings") {
            KanbanBoardEditorView(mode: .settings(board: board)).environmentObject(store)
        }
    }

    func testBoardFilterSheet() throws {
        let store = store()
        try shoot("board-filter") {
            KanbanBoardFilterSheet(includeArchived: .constant(false), assigneeFilter: .constant(nil),
                                   tenantFilter: .constant(nil), groupRunningByProfile: .constant(true))
                .environmentObject(store)
        }
    }

    func testTaskDetail() throws {
        let store = store()
        let task = KanbanTask(id: "t_8f3a21c0", title: "Port the settings sheet", body: "Move the form to the grouped style.",
                              status: "todo", assignee: "default", priority: 1)
        try shoot("task-detail") {
            KanbanTaskDetailView(task: task).environmentObject(store)
        }
    }

    func testOrchestrationSettings() throws {
        let store = store()
        try shoot("orchestration") {
            KanbanOrchestrationSettingsSheet().environmentObject(store)
        }
    }

    func testBotEditorCreate() throws {
        try shoot("bot-editor") {
            BotEditorSheet(mode: .create, onFinished: { _, _ in })
        }
    }
}
