import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// The window title and the pane header on Bots, Cron and Kanban, in a window
/// shaped like the app's (see `MacToolbarRealWindowTests`): the real
/// `MacSplitLayout` and `MacDetailRouter`, and a chat stand-in that applies the
/// title and toolbar items the way `RootView.chatNavigationContent` does.
@MainActor
final class MacPaneTitleTests: XCTestCase {
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

    private struct PaneRoot: View {
        let defaults: UserDefaults
        @AppStorage(MacSidebarState.tabDefaultsKey, store: nil) private var tabRaw = SidebarTab.sessions.rawValue
        @State private var query = ""

        init(defaults: UserDefaults) {
            self.defaults = defaults
            _tabRaw = AppStorage(wrappedValue: SidebarTab.sessions.rawValue, MacSidebarState.tabDefaultsKey, store: defaults)
        }

        var body: some View {
            MacSplitLayout(defaults: defaults, sidebar: {
                List { Text("Sidebar") }.searchable(text: $query, prompt: "Search sessions")
            }, chat: {
                NavigationStack {
                    Color.clear
                        .navigationTitle(MacChatRoute.navigationTitle(tabRaw: tabRaw))
                        .macHidingToolbarTitle(MacChatRoute.hidesToolbarTitle(tabRaw: tabRaw))
                        .toolbar {
                            if MacChatRoute.isChatActive(tabRaw: tabRaw) {
                                ToolbarItem(placement: .principal) { Text("Session tabs").frame(minWidth: 200) }
                                ToolbarItem(placement: .primaryAction) {
                                    Button {} label: { Image(systemName: "arrow.clockwise") }
                                        .accessibilityLabel("Refresh conversation")
                                }
                            } else {
                                MacPaneToolbarFill()
                            }
                        }
                }
            })
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
            .frame(minWidth: MacSidebarState.windowMinWidth, minHeight: 560)
        }
    }

    private final class AppShapedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func appWindow(tab: SidebarTab, dark: Bool = true) throws -> NSWindow {
        guard #available(macOS 26.0, *) else { throw XCTSkip("system toolbar platters need macOS 26") }
        suite.defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        suite.defaults.set(true, forKey: MacSidebarState.defaultsKey)
        let window = AppShapedWindow(contentRect: NSRect(x: 40, y: 60, width: 1180, height: 780),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: PaneRoot(defaults: suite.defaults))
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        HostedTestSupport.settle(1.0)
        return window
    }

    private func shot(_ window: NSWindow, _ name: String) throws {
        let dir = ProcessInfo.processInfo.environment["CONDUIT_FORM_SHOTS_DIR"] ?? "/private/tmp/conduit-form-shots"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let frame = try XCTUnwrap(window.contentView?.superview)
        let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    /// Bots, Cron and Kanban: the window keeps the pane's name as its title
    /// string (Window menu, Mission Control, accessibility) but the toolbar does
    /// not display it, since the pane's own header does. Chat shows no title.
    func testPaneNameIsNotShownInTheToolbarOnBotsCronAndKanban() throws {
        try XCTSkipUnless(MacPaneTitle.canHideKeepingTitle, "macOS 14 blanks the title instead")
        for tab in [SidebarTab.bots, .cron, .kanban] {
            let window = try appWindow(tab: tab)
            XCTAssertEqual(window.title, tab.displayName, "\(tab): the title string stays")
            XCTAssertEqual(window.titleVisibility, .hidden, "\(tab): the toolbar does not show the pane name")
        }
        let chat = try appWindow(tab: .sessions)
        XCTAssertEqual(chat.title, "")
        XCTAssertEqual(chat.titleVisibility, .visible, "chat keeps the toolbar it had")
    }

    /// Switching panes in a live window flips the title in and out of the toolbar.
    /// The window search item's platter (the rightmost one: the toolbar holds
    /// the sidebar toggle and, on the chat route, the strip and Refresh to its
    /// left), in window coordinates.
    private func searchFrame(in window: NSWindow) -> CGRect? {
        ToolbarStability.snapshot(of: window).platters.last?.frame
    }

    /// With the pane name gone from the toolbar the window search item must
    /// stay where it sits on the chat route, at the trailing edge (it follows
    /// the title slot otherwise and jumps to the leading edge).
    func testSearchItemStaysTrailingOnBotsCronAndKanban() throws {
        try XCTSkipUnless(MacPaneTitle.canHideKeepingTitle)
        for tab in [SidebarTab.bots, .cron, .kanban, .sessions] {
            let window = try appWindow(tab: tab)
            var frame: CGRect?
            HostedTestSupport.settle(0.8)
            frame = searchFrame(in: window)
            let search = try XCTUnwrap(frame, "\(tab): the window search item is in the toolbar")
            XCTAssertGreaterThan(search.midX, window.frame.width / 2, "\(tab): the search item is in the trailing half of the window")
            XCTAssertGreaterThan(search.maxX, window.frame.width - 40, "\(tab): the search item sits at the trailing edge")
            // Steady: no change in the toolbar over a second (the flicker class, D11).
            let first = ToolbarStability.snapshot(of: window)
            HostedTestSupport.settle(1.0)
            XCTAssertEqual(ToolbarStability.snapshot(of: window), first, "\(tab): the toolbar stays still")
            XCTAssertTrue(first.hidden.isEmpty, "\(tab): nothing in the overflow menu: \(first)")
        }
    }

    /// The search item stays trailing while the route changes in a live window.
    func testSearchItemStaysTrailingAcrossRouteChanges() throws {
        try XCTSkipUnless(MacPaneTitle.canHideKeepingTitle)
        let window = try appWindow(tab: .kanban)
        for tab in [SidebarTab.sessions, .bots, .sessions, .cron, .kanban] {
            suite.defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            XCTAssertTrue(HostedTestSupport.waitUntil { window.titleVisibility == (tab == .sessions ? .visible : .hidden) })
            HostedTestSupport.settle(1.0)
            let search = try XCTUnwrap(searchFrame(in: window))
            XCTAssertGreaterThan(search.maxX, window.frame.width - 40, "after switching to \(tab): the search item is trailing")
            XCTAssertTrue(ToolbarStability.snapshot(of: window).hidden.isEmpty, "after switching to \(tab): nothing in the overflow menu")
        }
    }

    func testTitleFollowsTheRoute() throws {
        try XCTSkipUnless(MacPaneTitle.canHideKeepingTitle)
        let window = try appWindow(tab: .kanban)
        XCTAssertEqual(window.titleVisibility, .hidden)
        suite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.titleVisibility == .visible && window.title == "" })
        suite.defaults.set(SidebarTab.cron.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.titleVisibility == .hidden && window.title == SidebarTab.cron.displayName })
    }

    func testTitleStringPolicy() {
        XCTAssertEqual(MacPaneTitle.windowTitle(forPane: "Kanban", canHideKeepingTitle: true), "Kanban")
        XCTAssertEqual(MacPaneTitle.windowTitle(forPane: "Kanban", canHideKeepingTitle: false), "", "macOS 14 blanks it")
        XCTAssertTrue(MacChatRoute.hidesToolbarTitle(tabRaw: SidebarTab.kanban.rawValue))
        XCTAssertTrue(MacChatRoute.hidesToolbarTitle(tabRaw: SidebarTab.bots.rawValue))
        XCTAssertTrue(MacChatRoute.hidesToolbarTitle(tabRaw: SidebarTab.cron.rawValue))
        XCTAssertFalse(MacChatRoute.hidesToolbarTitle(tabRaw: SidebarTab.sessions.rawValue))
        XCTAssertFalse(MacChatRoute.hidesToolbarTitle(tabRaw: nil))
    }

    /// RootView is the one upstream site that applies the removal; the stand-in
    /// above mirrors it, so pin the real call.
    func testRootViewAppliesTheRemovalToTheChatStack() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conduit/Views/RootView.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(source.contains(".navigationTitle(chatWindowTitle)\n            .macHidingToolbarTitle(MacChatRoute.hidesToolbarTitle(tabRaw: macTabRaw))"),
                      "RootView.chatNavigationContent must hide the pane-name title from the toolbar")
        XCTAssertTrue(source.contains(".toolbar { if chatPaneActive { chatToolbarContent } else { MacPaneToolbarFill() } }"),
                      "RootView.chatNavigationContent must keep the search item trailing on the other panes")
    }

    func testPaneTopShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_FORM_SHOTS"] == "1",
                          "set TEST_RUNNER_CONDUIT_FORM_SHOTS=1 to write PNGs")
        for tab in [SidebarTab.kanban, .bots, .cron] {
            for dark in [true, false] {
                let window = try appWindow(tab: tab, dark: dark)
                try shot(window, "pane-\(tab.rawValue.lowercased())-top-\(dark ? "dark" : "light")")
            }
        }
    }
}
