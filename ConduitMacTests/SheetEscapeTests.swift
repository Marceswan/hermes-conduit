import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

@MainActor
final class SheetEscapeTests: XCTestCase {
    private final class Target: NSObject { var pressed = false; @objc func press() { pressed = true } }

    private func makeParent() -> NSWindow {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        return parent
    }

    private func makeSheet(with target: Target) -> (NSWindow, NSButton) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: target, action: #selector(Target.press))
        close.setAccessibilityLabel("Close Settings")
        close.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        sheet.contentView?.addSubview(close)
        return (sheet, close)
    }

    private func settle() {
        let e = expectation(description: "settle")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    func testCloseLabelMatching() {
        XCTAssertTrue(SheetEscape.isCloseLabel("Close Settings"))
        XCTAssertTrue(SheetEscape.isCloseLabel("Cancel"))
        XCTAssertTrue(SheetEscape.isCloseLabel("Done"))
        XCTAssertFalse(SheetEscape.isCloseLabel("Closet organizer"))
        XCTAssertFalse(SheetEscape.isCloseLabel("Delete"))
    }

    func testEscapeInSheetPressesCloseButton() {
        let parent = makeParent()
        let target = Target()
        let (sheet, _) = makeSheet(with: target)
        parent.beginSheet(sheet) { _ in }
        settle()
        defer { parent.endSheet(sheet); parent.orderOut(nil) }

        XCTAssertTrue(SheetEscape.handleEscape(in: sheet))
        XCTAssertTrue(target.pressed)
    }

    func testEscapeOutsideSheetIsIgnored() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(SheetEscape.handleEscape(in: window))
        XCTAssertFalse(SheetEscape.handleEscape(in: nil))
    }

    func testEscapeWithMarkedTextIsIgnored() {
        let parent = makeParent()
        let target = Target()
        let (sheet, _) = makeSheet(with: target)
        let editor = NSTextView(frame: NSRect(x: 10, y: 50, width: 200, height: 60))
        sheet.contentView?.addSubview(editor)
        parent.beginSheet(sheet) { _ in }
        settle()
        defer { parent.endSheet(sheet); parent.orderOut(nil) }

        XCTAssertTrue(sheet.makeFirstResponder(editor))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())

        XCTAssertFalse(SheetEscape.handleEscape(in: sheet))
        XCTAssertFalse(target.pressed)
    }

    // Mirrors ConduitSheetHeader: an icon-only Button labelled "Close <title>".
    private struct HostedSheetRoot: View {
        @Binding var presented: Bool
        let closed: () -> Void
        var body: some View {
            Text("root")
                .frame(width: 300, height: 200)
                .sheet(isPresented: $presented) {
                    VStack {
                        Text("Settings")
                        Button(action: { closed(); presented = false }) {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Close Settings")
                    }
                    .frame(width: 300, height: 200)
                }
        }
    }

    private final class Flag { var closed = false }

    func testSwiftUIHostedSheetIsEscapable() {
        let flag = Flag()
        var presented = true
        let binding = Binding(get: { presented }, set: { presented = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HostedSheetRoot(presented: binding, closed: { flag.closed = true }))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let deadline = Date().addingTimeInterval(5)
        while window.attachedSheet == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let sheet = window.attachedSheet else {
            return XCTFail("SwiftUI .sheet did not present as an NSWindow sheet")
        }
        XCTAssertNotNil(sheet.sheetParent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let before = NSApp.value(forKey: "accessibilityEnhancedUserInterface") as? Bool
        XCTAssertTrue(SheetEscape.handleEscape(in: sheet))
        XCTAssertTrue(flag.closed)
        // SwiftUI exposes sheet controls only with the enhanced-UI flag on; it is restored.
        XCTAssertEqual(NSApp.value(forKey: "accessibilityEnhancedUserInterface") as? Bool, before)
    }
}
