import XCTest
import AppKit
@testable import ConduitMac

@MainActor
final class PhoneScenePresenceMacTests: XCTestCase {
    /// Hides every window the test host already shows so only the test's own
    /// window decides the result; the returned closure restores them.
    private func hideHostWindows() -> () -> Void {
        let hidden = NSApp.windows.filter { $0.isVisible }
        hidden.forEach { $0.orderOut(nil) }
        return { hidden.forEach { $0.orderFront(nil) } }
    }

    func testVisibleWindowCountsAsForeground() {
        let restore = hideHostWindows()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; default true double-releases on close()
        window.orderFront(nil)
        defer { window.close(); restore() }
        XCTAssertTrue(PhoneScenePresence.isInForeground)
    }

    func testMiniaturizedOnlyWindowIsNotForeground() {
        let restore = hideHostWindows()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; default true double-releases on close()
        window.orderFront(nil)
        window.miniaturize(nil)
        defer { window.close(); restore() }
        XCTAssertFalse(NSApp.isHidden, "precondition: app hidden would make the result vacuous")
        let deadline = Date().addingTimeInterval(3)
        while !window.isMiniaturized, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(window.isMiniaturized, "precondition: window must finish miniaturizing")
        XCTAssertFalse(PhoneScenePresence.isInForeground)
    }
}
