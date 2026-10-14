import AppKit
import SwiftUI
import XCTest

/// Shared plumbing for tests that host SwiftUI in a real NSWindow: isolated
/// UserDefaults, condition-based waits, and explicit teardown, so a test can
/// neither see another test's state nor leave a live window behind.
@MainActor
enum HostedTestSupport {
    /// A throwaway defaults suite; remove with `dropSuite`.
    static func makeSuite() -> (defaults: UserDefaults, name: String) {
        let name = "conduit.mac.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    static func dropSuite(_ suite: (defaults: UserDefaults, name: String)) {
        suite.defaults.removePersistentDomain(forName: suite.name)
    }

    /// Runs the main run loop until `predicate` holds or `timeout` passes.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// For negative assertions ("nothing moves"): lets queued work drain.
    static func settle(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func host<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        return window
    }

    /// Detaches the hosting view (ending its subscriptions), closes the window
    /// and drains the run loop once.
    static func tearDown(_ window: NSWindow) {
        window.contentView = nil
        window.close()
        settle(0.05)
    }
}
