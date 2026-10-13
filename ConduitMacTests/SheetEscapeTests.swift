import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

@MainActor
final class SheetEscapeTests: XCTestCase {
    private final class Counter { var counts: [String: Int] = [:]; func hit(_ k: String) { counts[k, default: 0] += 1 }
        func n(_ k: String) -> Int { counts[k] ?? 0 } }

    private final class Box { var presented = true }
    private final class Target: NSObject { var pressed = false; @objc func press() { pressed = true } }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    private struct Root<Sheet: View>: View {
        @Binding var presented: Bool
        let sheet: Sheet
        var body: some View {
            Text("root").frame(width: 300, height: 200)
                .sheet(isPresented: $presented) { sheet.frame(width: 300, height: 200) }
        }
    }

    /// Presents `sheet` through SwiftUI `.sheet` and returns the real sheet window.
    private func present<Sheet: View>(_ sheet: @escaping (Binding<Bool>) -> Sheet) -> (parent: NSWindow, sheet: NSWindow, retain: AnyObject)? {
        let box = Box()
        let binding = Binding(get: { box.presented }, set: { box.presented = $0 })
        let parent = makeWindow()
        parent.contentView = NSHostingView(rootView: Root(presented: binding, sheet: sheet(binding)))
        parent.orderFront(nil)
        let deadline = Date().addingTimeInterval(5)
        while parent.attachedSheet == nil && Date() < deadline { spin(0.05) }
        spin(0.3)
        guard let s = parent.attachedSheet else { return nil }
        return (parent, s, box)
    }

    private func icon(_ title: String, _ counter: Counter, _ key: String, _ b: Binding<Bool>) -> some View {
        Button(action: { counter.hit(key); b.wrappedValue = false }) {
            Image(systemName: "xmark").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Close \(title)")
    }

    // MARK: matching

    func testCloseLabelMatching() {
        XCTAssertTrue(SheetEscape.isCloseLabel("Cancel", iconOnly: false))
        XCTAssertTrue(SheetEscape.isCloseLabel("Close", iconOnly: false))
        XCTAssertTrue(SheetEscape.isCloseLabel("Close Settings", iconOnly: true))
        XCTAssertFalse(SheetEscape.isCloseLabel("Close sessions", iconOnly: false))
        XCTAssertFalse(SheetEscape.isCloseLabel("Cancel dictation", iconOnly: false))
        XCTAssertFalse(SheetEscape.isCloseLabel("Done", iconOnly: false))
        XCTAssertFalse(SheetEscape.isCloseLabel("Closet organizer", iconOnly: true))
        XCTAssertFalse(SheetEscape.isCloseLabel("Delete", iconOnly: true))
    }

    // MARK: hosted sheets

    func testIconOnlyCloseXIsPressed() throws {
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in self.icon("Settings", c, "x", b) })
        defer { ctx.parent.orderOut(nil) }
        XCTAssertNotNil(ctx.sheet.sheetParent)
        XCTAssertTrue(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertEqual(c.n("x"), 1)
    }

    func testAccessibilityBoostIsRestoredAndLeftAloneWhenAlreadyOn() throws {
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in self.icon("Settings", c, "x", b) })
        defer { ctx.parent.orderOut(nil) }
        let original = AccessibilityTreeBoost.isOn
        defer { _ = AccessibilityTreeBoost.withTree { true }; if AccessibilityTreeBoost.isOn != original { NSApp.perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"), with: NSNumber(value: original)) } }
        XCTAssertTrue(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertEqual(AccessibilityTreeBoost.isOn, original)
        // Already on (as the hover engine leaves it): untouched afterwards.
        NSApp.perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"), with: NSNumber(value: true))
        XCTAssertTrue(AccessibilityTreeBoost.withTree { true })
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
    }

    func testDoneIsNeverPressed() throws {
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in Button("Done") { c.hit("done"); b.wrappedValue = false } })
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertEqual(c.n("done"), 0)
    }

    func testVisibleTitleCancelDictationIsNotPressed() throws {
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in
            VStack {
                Button("Cancel dictation") { c.hit("dict") }
                Button("Close sessions") { c.hit("sessions") }
            }
        })
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertEqual(c.n("dict") + c.n("sessions"), 0)
    }

    func testCancelIsPreferredOverCloseX() throws {
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in
            VStack {
                self.icon("Settings", c, "x", b)
                Button("Cancel") { c.hit("cancel"); b.wrappedValue = false }
            }
        })
        defer { ctx.parent.orderOut(nil) }
        XCTAssertTrue(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertEqual(c.n("cancel"), 1)
        XCTAssertEqual(c.n("x"), 0)
    }

    func testDisabledCancelReturnsFalse() throws {
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in
            Button("Cancel") { c.hit("cancel") }.disabled(true)
        })
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertEqual(c.n("cancel"), 0)
    }

    private struct EditorRep: NSViewRepresentable {
        func makeNSView(context: Context) -> NSTextView { NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60)) }
        func updateNSView(_ v: NSTextView, context: Context) {}
    }

    func testEscapeWithMarkedTextIsIgnored() throws {
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in
            VStack { EditorRep().frame(height: 60); self.icon("Settings", c, "x", b) }
        })
        defer { ctx.parent.orderOut(nil) }
        func findEditor(_ v: NSView) -> NSTextView? {
            if let t = v as? NSTextView { return t }
            for s in v.subviews { if let t = findEditor(s) { return t } }
            return nil
        }
        let editor = try XCTUnwrap(ctx.sheet.contentView.flatMap(findEditor))
        XCTAssertTrue(ctx.sheet.makeFirstResponder(editor))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertEqual(c.n("x"), 0)
    }

    // MARK: scope

    func testEscapeOutsideSheetIsIgnored() {
        let window = makeWindow()
        XCTAssertFalse(SheetEscape.handleEscape(in: window))
        XCTAssertFalse(SheetEscape.handleEscape(in: nil))
    }

    func testNonHostingSheetIsIgnored() {
        let parent = makeWindow()
        parent.orderFront(nil)
        let sheet = makeWindow()
        let target = Target()
        let cancel = NSButton(title: "Cancel", target: target, action: #selector(Target.press))
        sheet.contentView?.addSubview(cancel)
        parent.beginSheet(sheet) { _ in }
        spin(0.2)
        defer { parent.endSheet(sheet); parent.orderOut(nil) }
        XCTAssertNotNil(sheet.sheetParent)
        XCTAssertFalse(SheetEscape.isSwiftUIHosted(sheet))
        XCTAssertFalse(SheetEscape.handleEscape(in: sheet))
        XCTAssertFalse(target.pressed)
    }

    func testOpenPanelSheetIsIgnored() {
        let parent = makeWindow()
        parent.orderFront(nil)
        let panel = NSOpenPanel()
        panel.beginSheetModal(for: parent) { _ in }
        spin(0.3)
        defer { panel.cancel(nil); spin(0.2); parent.orderOut(nil) }
        XCTAssertFalse(SheetEscape.handleEscape(in: panel))
    }

    func testAlertSheetIsIgnored() {
        let parent = makeWindow()
        parent.orderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Hi"
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent) { _ in }
        spin(0.3)
        defer { parent.endSheet(alert.window); parent.orderOut(nil) }
        XCTAssertFalse(SheetEscape.handleEscape(in: alert.window))
    }

    // MARK: selector guard

    func testUnavailableAccessibilitySelectorsSkipTheBoostAndReturnFalse() {
        let plain = NSObject()
        XCTAssertFalse(AccessibilityTreeBoost.isAvailable(on: plain))
        var ran = false
        XCTAssertFalse(AccessibilityTreeBoost.withTree(on: plain) { ran = true; return true })
        XCTAssertFalse(ran)
        XCTAssertTrue(AccessibilityTreeBoost.isAvailable)
    }

    // MARK: header shortcut + monitor

    func testHeaderCloseRunsExactlyOnceForEscape() throws {
        SheetEscape.install()
        let c = Counter()
        let ctx = try XCTUnwrap(present { b in
            VStack { ConduitSheetHeader(title: "Settings") { c.hit("close"); b.wrappedValue = false }; Spacer() }
        })
        defer { ctx.parent.orderOut(nil) }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: ctx.sheet.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(event)
        spin(0.5)
        XCTAssertEqual(c.n("close"), 1)
    }
}
