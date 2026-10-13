import XCTest
import AppKit
@testable import ConduitMac

@MainActor
final class PhoneScenePresenceMacTests: XCTestCase {
    func testVisibleWindowCountsAsForeground() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; default true double-releases on close()
        window.orderFront(nil)
        defer { window.close() }
        XCTAssertTrue(PhoneScenePresence.isInForeground)
    }

    func testMiniaturizedOnlyWindowIsNotForeground() {
        NSApp.windows.forEach { $0.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; default true double-releases on close()
        window.orderFront(nil)
        window.miniaturize(nil)
        defer { window.close() }
        let expectation = expectation(description: "miniaturized")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 3)
        XCTAssertFalse(PhoneScenePresence.isInForeground)
    }
}
