import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

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

/// Reads the accessibility tree of a hosted SwiftUI view. SwiftUI builds the
/// tree only while an assistive client is attached, so a test turns
/// `AccessibilityTreeBoost` on first (see `ButtonGeometryTests`).
@MainActor
enum AccessibilityProbe {
    struct Node {
        var role: String
        var label: String?
        /// Relative to the content view's top-left.
        var frame: CGRect
    }

    /// Every accessibility element below the window's content view, depth-first.
    static func nodes(in window: NSWindow) -> [Node] {
        guard let host = window.contentView else { return [] }
        let content = window.convertToScreen(host.convert(host.bounds, to: nil))
        var nodes: [Node] = []
        func walk(_ element: NSObject, depth: Int) {
            if let role: String = element.axValue("accessibilityRole"),
               let frame: NSValue = element.axValue("accessibilityFrame") {
                let r = frame.rectValue
                // Screen space is bottom-left; report top-left relative to the host.
                nodes.append(Node(role: role, label: element.axValue("accessibilityLabel"),
                                  frame: CGRect(x: r.minX - content.minX, y: content.maxY - r.maxY,
                                                width: r.width, height: r.height)))
            }
            let kids: [Any]? = element.axValue("accessibilityChildren")
            if depth < 10 { for kid in kids ?? [] { if let o = kid as? NSObject { walk(o, depth: depth + 1) } } }
        }
        for kid in host.accessibilityChildren() ?? [] { if let o = kid as? NSObject { walk(o, depth: 0) } }
        return nodes
    }

    static func labels(in window: NSWindow) -> [String] { nodes(in: window).compactMap(\.label) }

    static func frame(of label: String, in window: NSWindow) -> CGRect? {
        nodes(in: window).first { $0.label == label }?.frame
    }

    /// Presses the element labelled `label` (its default accessibility action).
    @discardableResult
    static func press(_ label: String, in window: NSWindow) -> Bool {
        guard let host = window.contentView else { return false }
        var target: NSObject?
        func walk(_ element: NSObject, depth: Int) {
            if target == nil, element.axValue("accessibilityLabel") == label { target = element; return }
            let kids: [Any]? = element.axValue("accessibilityChildren")
            if depth < 10 { for kid in kids ?? [] { if let o = kid as? NSObject { walk(o, depth: depth + 1) } } }
        }
        for kid in host.accessibilityChildren() ?? [] { if let o = kid as? NSObject { walk(o, depth: 0) } }
        guard let target else { return false }
        return (target as AnyObject).accessibilityPerformPress?() ?? false
    }
}
