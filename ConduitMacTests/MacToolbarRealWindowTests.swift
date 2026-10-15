import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// The D11 toolbar in a window shaped like the app's own.
///
/// `MacSessionTabStripTests` hosts the toolbar through `NSHostingController`
/// with a stand-in navigation button. The app's `WindowGroup` window is not
/// that: its content view is an `NSHostingView` in a window with
/// `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`,
/// and SwiftUI adds the system sidebar toggle and a split-view separator item
/// to the toolbar (the controller variant adds neither). Those items, and a
/// window that starts with the sidebar hidden (the user's saved state), are the
/// conditions the 0.1.1 flicker showed itself in; the controller harness passed
/// the 0.1.1 code. This file pins the shape the user runs, at the widths the
/// older tests use and at the 1291 pt of the reported window, and it asserts
/// what the reader's sidebar lookup sees in that window.
@MainActor
final class MacToolbarRealWindowTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
    }

    override func tearDown() async throws {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
        HostedTestSupport.dropSuite(suite)
    }

    /// The real layout (`MacSplitLayout`) with the real strip, and the chat
    /// toolbar's three items as `RootView.chatToolbarContent` declares them:
    /// the strip (principal), Refresh and the status dot. The sidebar list
    /// carries `.searchable`, as the sessions list does (the window search item).
    private struct AppShapedRoot: View {
        let store: MacSessionTabsStore
        let defaults: UserDefaults
        @State private var query = ""

        var body: some View {
            MacSplitLayout(defaults: defaults, sidebar: {
                List { Text("Sidebar") }.searchable(text: $query, prompt: "Search sessions")
            }, chat: {
                NavigationStack {
                    Color.clear
                        .navigationTitle("")
                        // As RootView's chat stack: nothing hidden while chat is the route.
                        .macHidingToolbarTitle(false)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                MacSessionTabStrip(store: store, onRename: { _ in }, onDelete: { _ in })
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Button {} label: { Image(systemName: "arrow.clockwise") }
                                    .accessibilityLabel("Refresh conversation")
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Button {} label: { Circle().fill(.green).frame(width: 9, height: 9) }
                                    .accessibilityLabel("Gateway connected")
                            }
                        }
                }
            })
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
            // As ConduitMacApp's WindowGroup content: the window minimum comes from here.
            .frame(minWidth: MacSidebarState.windowMinWidth, minHeight: 560)
        }
    }

    /// A window that keeps the frame it is given. AppKit pulls a titled window
    /// back inside the screen as it is shown, which made the widths below depend
    /// on the machine's display (a 1600 pt window is 1512 pt on a 14-inch MacBook Pro).
    private final class AppShapedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func tabs() -> MacSessionTabsStore {
        let store = MacSessionTabsStore(defaults: suite.defaults)
        store.setScope(dashboardID: nil, profile: "default")
        for i in 0..<30 { store.activeSessionChanged("s\(i)", title: "Session number \(i)") }
        return store
    }

    /// A window built like the WindowGroup's: `NSHostingView` as the content
    /// view, the same style mask, the default (automatic) toolbar style.
    /// `sidebarShown` is the saved `conduit.mac.sidebarVisible` the window starts with.
    private func appWindow(width: CGFloat, sidebarShown: Bool = true) throws -> NSWindow {
        guard #available(macOS 26.0, *) else { throw XCTSkip("system toolbar platters need macOS 26") }
        suite.defaults.set(sidebarShown, forKey: MacSidebarState.defaultsKey)
        let window = AppShapedWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 813),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: AppShapedRoot(store: tabs(), defaults: suite.defaults))
        window.setContentSize(NSSize(width: width, height: 813))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        XCTAssertEqual(window.frame.width, width, accuracy: 0.5, "the window has the width the step names")
        return window
    }

    /// Flips the saved visibility and waits for the split view to take it (the
    /// `@AppStorage` change reaches SwiftUI a few turns later, longer under load;
    /// sampling for quiet before that would see the old, still toolbar).
    private func setSidebar(shown: Bool, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        suite.defaults.set(shown, forKey: MacSidebarState.defaultsKey)
        let took = HostedTestSupport.waitUntil(timeout: 5) {
            let width = MacToolbarSlotReader.ReaderView.sidebarWidth(in: window)
            return shown ? width >= MacSidebarState.sidebarMinWidth : width == 0
        }
        XCTAssertTrue(took, "the split view \(shown ? "showed" : "hid") the sidebar", file: file, line: line)
    }

    private func ideal(_ window: NSWindow, sidebar: CGFloat) -> CGFloat {
        MacToolbarSlot.idealWidth(windowWidth: window.frame.width, sidebarWidth: sidebar)
    }

    /// Every `NSSplitView` under the theme frame, outermost first, with its
    /// arranged subviews' widths and collapsed state.
    private struct SplitInfo {
        var type: String
        var frameInWindow: CGRect
        var arranged: [(width: CGFloat, collapsed: Bool)]
    }

    private func splitViews(in window: NSWindow) -> [SplitInfo] {
        guard let root = window.contentView?.superview else { return [] }
        var found: [SplitInfo] = []
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView {
                found.append(SplitInfo(type: String(describing: Swift.type(of: split)),
                                       frameInWindow: split.convert(split.bounds, to: nil),
                                       arranged: split.arrangedSubviews.map { ($0.frame.width, split.isSubviewCollapsed($0)) }))
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    // MARK: What the reader's sidebar lookup sees

    /// The reader takes the first `NSSplitView` under the theme frame. In the
    /// app-shaped window that is the only one (SwiftUI's own; the titlebar and
    /// toolbar views hold none), it is the navigation split with the
    /// sidebar first, and its sidebar width is the width the reader returns:
    /// the real sidebar when shown, zero when it starts hidden. The sidebar
    /// column is the same width at every window width, so the strip's width
    /// (which does change with the window) does not feed it.
    func testTheOnlySplitViewIsTheNavigationSplitAndTheReaderReadsItsSidebar() throws {
        for shown in [true, false] {
            let window = try appWindow(width: 1291, sidebarShown: shown)
            ToolbarStability.expectSteady(in: window, "1291 pt, sidebar \(shown ? "shown" : "hidden")")
            let splits = splitViews(in: window)
            XCTAssertEqual(splits.count, 1, "one NSSplitView under the theme frame: \(splits)")
            let split = try XCTUnwrap(splits.first)
            XCTAssertEqual(split.arranged.count, 2, "sidebar and detail")
            XCTAssertEqual(split.frameInWindow.width, 1291, accuracy: 0.5, "spans the window")
            XCTAssertEqual(split.arranged[0].collapsed, !shown)
            let read = MacToolbarSlotReader.ReaderView.sidebarWidth(in: window)
            XCTAssertEqual(read, shown ? MacSidebarState.sidebarIdealWidth : 0, accuracy: 0.5)
            if shown { XCTAssertEqual(read, split.arranged[0].width, accuracy: 0.5) }

            var strips: [CGFloat] = []
            for width in [1000, 1291, 1600] as [CGFloat] {
                window.setContentSize(NSSize(width: width, height: 813))
                let snap = ToolbarStability.expectSteady(in: window, "\(Int(width)) pt, sidebar \(shown ? "shown" : "hidden")",
                                                         idealWidth: ideal(window, sidebar: shown ? read : 0))
                strips.append(snap.platters[1].frame.width)
                XCTAssertEqual(MacToolbarSlotReader.ReaderView.sidebarWidth(in: window), read, accuracy: 0.5,
                               "the sidebar column does not follow the window or the strip")
            }
            XCTAssertEqual(Set(strips.map { Int($0) }).count, 3, "the strip did change width across the three windows: \(strips)")
        }
    }

    // MARK: Stability

    /// Each width the older tests use, plus the reported window's 1291 pt,
    /// with the sidebar shown and hidden at launch: all five items stay on the
    /// toolbar (toggle, strip, Refresh, status dot, search), the strip is its
    /// ideal width and fills the gap, and nothing moves for a second.
    func testToolbarIsWholeAndStillInAWindowShapedLikeTheApp() throws {
        for shown in [true, false] {
            for width in [820, 1000, 1200, 1291, 1600] as [CGFloat] {
                let window = try appWindow(width: width, sidebarShown: shown)
                let step = "\(Int(width)) pt, sidebar \(shown ? "shown" : "hidden at launch")"
                let snap = ToolbarStability.expectSteady(in: window, step, idealWidth: ideal(window, sidebar: shown ? MacSidebarState.sidebarIdealWidth : 0))
                XCTAssertEqual(snap.itemCount, 5, "\(step): toggle, strip, Refresh, status and the search item; now \(snap)")
            }
        }
    }

    /// The reported window (1291 pt) through what a user does: hide and show
    /// the sidebar, shrink to the window minimum and grow back, with the
    /// toolbar whole and still after each step. (Showing the sidebar in a
    /// window at the 820 pt minimum makes AppKit grow the window by the sidebar's
    /// width, with or without the strip, so that step is taken at 1291 pt.)
    func testToolbarStaysWholeAndStillThroughSidebarToggleAndResizeInTheAppShape() throws {
        let window = try appWindow(width: 1291, sidebarShown: false)
        let side = MacSidebarState.sidebarIdealWidth
        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 813))
            XCTAssertEqual(window.frame.width, width, accuracy: 0.5)
        }
        ToolbarStability.expectSteady(in: window, "hidden at launch", idealWidth: ideal(window, sidebar: 0))
        setSidebar(shown: true, in: window)
        ToolbarStability.expectSteady(in: window, "shown", idealWidth: ideal(window, sidebar: side))
        setSidebar(shown: false, in: window)
        ToolbarStability.expectSteady(in: window, "hidden again", idealWidth: ideal(window, sidebar: 0))
        resize(MacSidebarState.windowMinWidth)
        ToolbarStability.expectSteady(in: window, "820 pt, hidden", idealWidth: ideal(window, sidebar: 0))
        resize(1291)
        ToolbarStability.expectSteady(in: window, "back to 1291 pt, hidden", idealWidth: ideal(window, sidebar: 0))
        setSidebar(shown: true, in: window)
        ToolbarStability.expectSteady(in: window, "1291 pt, shown", idealWidth: ideal(window, sidebar: side))
        resize(1000)
        ToolbarStability.expectSteady(in: window, "1000 pt, shown", idealWidth: ideal(window, sidebar: side))
        setSidebar(shown: false, in: window)
        ToolbarStability.expectSteady(in: window, "1000 pt, hidden", idealWidth: ideal(window, sidebar: 0))
    }
}
