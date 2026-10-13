import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

/// Upstream iOS views hide the iOS navigation bar with `.toolbar(.hidden, for: .navigationBar)`.
/// On Mac those modifiers must be no-ops; mapping them to `.windowToolbar` strips the title bar
/// and traffic lights from the main window.
@MainActor
final class WindowChromeTests: XCTestCase {
    private struct Probe: View {
        var body: some View {
            Text("probe")
                .frame(width: 300, height: 200)
                .toolbar(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    /// Closer to the real shell: a split view whose sidebar hides the bar inside a NavigationStack,
    /// and whose detail stack supplies toolbar items.
    private struct ShellProbe: View {
        var body: some View {
            NavigationSplitView {
                NavigationStack {
                    ScrollView { Text("sidebar") }
                        .toolbar(.hidden, for: .navigationBar)
                }
            } detail: {
                NavigationStack {
                    Text("detail")
                        .navigationTitle("")
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .toolbar { ToolbarItem(placement: .primaryAction) { Button("x") {} } }
                }
            }
            .frame(width: 600, height: 400)
        }
    }

    private struct RootHiddenProbe: View {
        var body: some View {
            NavigationSplitView {
                Text("sidebar")
            } detail: {
                Text("detail").toolbar { ToolbarItem(placement: .primaryAction) { Button("x") {} } }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .frame(width: 600, height: 400)
        }
    }

    private struct StackRootProbe: View {
        var body: some View {
            NavigationStack {
                Text("c").toolbar { ToolbarItem(placement: .primaryAction) { Button("x") {} } }
            }
            .toolbar(.hidden, for: .navigationBar)
            .frame(width: 400, height: 300)
        }
    }

    private func host<V: View>(_ v: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: v)
        w.makeKeyAndOrderFront(nil)
        spin(0.8)
        return w
    }

    func testRootHiddenSplit() { let w = host(RootHiddenProbe()); defer { w.close() }; assertChrome(w) }
    func testRootHiddenStack() { let w = host(StackRootProbe()); defer { w.close() }; assertChrome(w) }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func assertChrome(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.styleMask.contains(.titled), "styleMask lost .titled", file: file, line: line)
        for (name, kind) in [("close", NSWindow.ButtonType.closeButton),
                             ("miniaturize", .miniaturizeButton),
                             ("zoom", .zoomButton)] {
            let b = window.standardWindowButton(kind)
            XCTAssertNotNil(b, "\(name) button missing", file: file, line: line)
            XCTAssertEqual(b?.isHidden, false, "\(name) button hidden", file: file, line: line)
            XCTAssertNotNil(b?.superview, "\(name) button has no superview", file: file, line: line)
            XCTAssertNotNil(b?.window, "\(name) button not in window", file: file, line: line)
        }
    }

    func testNavigationBarModifiersKeepWindowChrome_hostingController() {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: Probe())
        w.makeKeyAndOrderFront(nil)
        spin(0.5)
        defer { w.close() }
        assertChrome(w)
    }

    func testNavigationBarModifiersKeepWindowChrome_hostingViewWithToolbar() {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: Probe())
        w.makeKeyAndOrderFront(nil)
        spin(0.5)
        defer { w.close() }
        assertChrome(w)
    }

    func testNavigationBarModifiersKeepWindowChrome_splitViewShell() {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ShellProbe())
        w.makeKeyAndOrderFront(nil)
        spin(0.8)
        defer { w.close() }
        assertChrome(w)
    }
}
