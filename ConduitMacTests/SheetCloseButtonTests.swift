import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

@MainActor
final class SheetCloseButtonTests: XCTestCase {
    /// Observable, as the app's presenting state is, so a reset binding
    /// takes the sheet down.
    private final class Box: ObservableObject { @Published var presented = true }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private struct Root<Sheet: View>: View {
        @ObservedObject var box: Box
        let sheet: Sheet
        let height: CGFloat
        var body: some View {
            Text("root").frame(width: 400, height: 300)
                .sheet(isPresented: $box.presented) { sheet.frame(width: 300, height: height) }
        }
    }

    /// Presents `sheet` through SwiftUI `.sheet`; returns the real sheet window
    /// and the box behind the presenting binding.
    private func present<Sheet: View>(_ sheet: Sheet, height: CGFloat = 200) -> (parent: NSWindow, sheet: NSWindow, box: Box)? {
        let box = Box()
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: Root(box: box, sheet: sheet, height: height))
        parent.orderFront(nil)
        let deadline = Date().addingTimeInterval(5)
        while parent.attachedSheet == nil && Date() < deadline { spin(0.05) }
        spin(0.3)
        guard let s = parent.attachedSheet else { return nil }
        return (parent, s, box)
    }

    private func click(in window: NSWindow, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func contentCenter(of window: NSWindow) -> NSPoint {
        NSPoint(x: window.contentLayoutRect.midX, y: window.contentLayoutRect.midY)
    }

    // MARK: which sheets get the X

    func testSheetWithoutControlsGetsTheX() throws {
        let ctx = try XCTUnwrap(present(Text("Pick something")))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(ctx.sheet))
        XCTAssertTrue(SheetCloseButton.isDecorated(ctx.sheet))
        // Added once only.
        XCTAssertFalse(SheetCloseButton.decorateIfNeeded(ctx.sheet))
    }

    func testSheetWithCancelGetsNoX() throws {
        let ctx = try XCTUnwrap(present(Button("Cancel") {}))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetCloseButton.decorateIfNeeded(ctx.sheet))
    }

    func testSheetWithDoneGetsNoX() throws {
        let ctx = try XCTUnwrap(present(Button("Done") {}))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetCloseButton.decorateIfNeeded(ctx.sheet))
    }

    func testSheetWithHeaderXGetsNoX() throws {
        let ctx = try XCTUnwrap(present(ConduitSheetHeader(title: "Settings", close: {})))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetCloseButton.decorateIfNeeded(ctx.sheet))
    }

    func testXSitsInsideTheWindowAndLeavesTheContentWhereItWas() throws {
        let ctx = try XCTUnwrap(present(Text("Long list"), height: 5_000))
        defer { ctx.parent.orderOut(nil) }
        let content = try XCTUnwrap(ctx.sheet.contentView)
        let frameView = try XCTUnwrap(content.superview)
        let before = content.frame
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(ctx.sheet))
        frameView.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertEqual(content.frame, before)
        let button = try XCTUnwrap(frameView.subviews.last)
        let rect = button.convert(button.bounds, to: nil)
        let window = NSRect(origin: .zero, size: ctx.sheet.frame.size)
        XCTAssertTrue(window.contains(rect), "\(rect) not inside \(window)")
        // Top-trailing corner.
        XCTAssertEqual(rect.maxX, window.maxX - 10, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, window.maxY - 10, accuracy: 0.5)
    }

    // MARK: closing

    func testCloseResetsThePresentingBinding() throws {
        let ctx = try XCTUnwrap(present(Text("Pick something")))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(ctx.sheet))
        SheetCloseButton.close(ctx.sheet)
        spin(0.6)
        XCTAssertFalse(ctx.box.presented)
        // The sheet animates away after the binding resets.
        let deadline = Date().addingTimeInterval(3)
        while ctx.parent.attachedSheet != nil && Date() < deadline { spin(0.05) }
        XCTAssertNil(ctx.parent.attachedSheet)
    }

    func testEscapeClosesADecoratedSheetWithNothingFocused() throws {
        let ctx = try XCTUnwrap(present(Text("Pick something")))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(ctx.sheet))
        XCTAssertTrue(SheetEscape.handleEscape(in: ctx.sheet))
        spin(0.6)
        XCTAssertFalse(ctx.box.presented)
    }

    func testEscapeLeavesAnUndecoratedSheetWithoutControlsAlone() throws {
        let ctx = try XCTUnwrap(present(Text("Pick something")))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetEscape.handleEscape(in: ctx.sheet))
        XCTAssertTrue(ctx.box.presented)
    }

    // MARK: click outside

    func testClickBehindADecoratedSheetClosesIt() throws {
        let ctx = try XCTUnwrap(present(Text("Pick something")))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(ctx.sheet))
        XCTAssertTrue(SheetCloseButton.handleOutsideClick(click(in: ctx.parent, at: contentCenter(of: ctx.parent))))
        spin(0.6)
        XCTAssertFalse(ctx.box.presented)
    }

    func testClickInTheTitleBarIsLeftAlone() throws {
        let ctx = try XCTUnwrap(present(Text("Pick something")))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(ctx.sheet))
        let titleBar = NSPoint(x: ctx.parent.frame.width / 2, y: ctx.parent.frame.height - 4)
        XCTAssertFalse(ctx.parent.contentLayoutRect.contains(titleBar))
        XCTAssertFalse(SheetCloseButton.handleOutsideClick(click(in: ctx.parent, at: titleBar)))
        XCTAssertTrue(ctx.box.presented)
    }

    func testClickBehindAFormSheetIsLeftAlone() throws {
        let ctx = try XCTUnwrap(present(Button("Cancel") {}))
        defer { ctx.parent.orderOut(nil) }
        XCTAssertFalse(SheetCloseButton.decorateIfNeeded(ctx.sheet))
        XCTAssertFalse(SheetCloseButton.handleOutsideClick(click(in: ctx.parent, at: contentCenter(of: ctx.parent))))
        XCTAssertTrue(ctx.box.presented)
    }

    func testClickWithNoSheetIsLeftAlone() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(SheetCloseButton.handleOutsideClick(click(in: window, at: contentCenter(of: window))))
    }
}
