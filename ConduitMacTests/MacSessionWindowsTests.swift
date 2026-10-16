import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowsTests: XCTestCase {
    func testSessionWindowIdentifierIsNotMainChatWindow() {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        XCTAssertTrue(MacSessionWindows.isSessionWindow(window))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(window), "Cmd-W closes the window, not a tab")
    }

    func testOpenRequestsTokenAndCallsOpenWindow() {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        var opened: [MacSessionWindowToken] = []
        XCTAssertTrue(MacSessionWindows.open("s1", appState: appState, registry: registry) { opened.append($0) })
        XCTAssertEqual(opened.map(\.sessionID), ["s1"])
        XCTAssertEqual(opened.first?.profile, appState.activeProfile)
    }

    func testOpenAtCapDoesNotCallOpenWindow() {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        for id in ["a", "b", "c", "d"] { _ = MacSessionWindows.open(id, appState: appState, registry: registry) { _ in } }
        var opened = 0
        XCTAssertFalse(MacSessionWindows.open("e", appState: appState, registry: registry) { _ in opened += 1 })
        XCTAssertEqual(opened, 0)
    }

    func testFocusComposerFromSessionWindowKeepsMainPane() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        let center = NotificationCenter()
        var posted: [Any?] = []
        let observer = center.addObserver(forName: .macFocusComposerRequested, object: nil, queue: nil) { posted.append($0.object) }
        MacKeyboardActions.focusComposer(window: window, defaults: suite.defaults, center: center)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
        XCTAssertEqual(posted.count, 1)
        center.removeObserver(observer)
    }

    // MARK: A requested window that never appears

    func testARequestThatNeverAppearsIsReleasedAfterTheGracePeriod() async throws {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(MacSessionWindows.open(id, appState: appState, registry: registry, graceDelay: .milliseconds(30)) { _ in })
        }
        XCTAssertTrue(registry.isFull)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(registry.isFull, "an openWindow that produced no window must not hold its slot until relaunch")
    }

    func testAWindowThatAppearedIsNotReleasedByTheGracePeriod() async throws {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        var token: MacSessionWindowToken?
        XCTAssertTrue(MacSessionWindows.open("a", appState: appState, registry: registry, graceDelay: .milliseconds(30)) { token = $0 })
        let opened = try XCTUnwrap(token)
        XCTAssertTrue(registry.appeared(opened))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(registry.open.contains(opened))
        registry.disappeared(opened)
        XCTAssertTrue(registry.open.isEmpty)
    }

    func testReleaseOnlyForgetsAnUnappearedRequest() {
        let registry = MacSessionWindowRegistry()
        let waiting = MacSessionWindowToken(dashboardID: nil, profile: "p", sessionID: "w")
        let shown = MacSessionWindowToken(dashboardID: nil, profile: "p", sessionID: "s")
        XCTAssertTrue(registry.request(waiting))
        XCTAssertTrue(registry.request(shown))
        XCTAssertTrue(registry.appeared(shown))
        registry.releaseIfUnappeared(waiting)
        registry.releaseIfUnappeared(shown)
        XCTAssertFalse(registry.appeared(waiting), "released: a late window is treated as restored")
        XCTAssertTrue(registry.open.contains(shown))
    }

    // MARK: Link policy (R11) in a session window

    private final class EnvBox { var openURL: OpenURLAction? }
    private struct EnvProbe: View {
        let box: EnvBox
        @Environment(\.openURL) private var openURL
        var body: some View {
            box.openURL = openURL
            return Color.clear.frame(width: 10, height: 10)
        }
    }

    func testLinkPolicyModifierRoutesAppLinksAndDiscardsDisallowedSchemes() async throws {
        let box = EnvBox()
        var widget: [URL] = []
        var links: [ConduitAppLink] = []
        let host = NSHostingView(rootView: EnvProbe(box: box).macLinkPolicy(
            routeWidgetLaunch: { widget.append($0); return $0.absoluteString == "conduit://widget/x" },
            openAppLink: { links.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        let openURL = try XCTUnwrap(box.openURL, "the modifier must install an environment openURL")

        openURL(URL(string: "conduit://widget/x")!)
        openURL(URL(string: "conduit://session/abc")!)
        openURL(URL(string: "file:///Applications/Calculator.app")!)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(widget.map(\.absoluteString), ["conduit://widget/x", "conduit://session/abc", "file:///Applications/Calculator.app"])
        XCTAssertEqual(links, [.session(id: "abc")], "only the session link reaches openAppLink; the file URL is discarded")
    }

    // MARK: Cmd-. from a session window

    func testStopFromASessionWindowStopsThatWindowAndNotMain() {
        let router = MacSessionWindowStopRouter()
        let a = NSWindow(), b = NSWindow()
        a.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        b.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-2")
        var stopped: [String] = []
        router.register(window: a) { stopped.append("a") }
        router.register(window: b) { stopped.append("b") }
        var mainStops = 0
        MacSessionWindows.stopResponse(window: b, router: router) { mainStops += 1 }
        XCTAssertEqual(stopped, ["b"])
        XCTAssertEqual(mainStops, 0)
    }

    func testStopFromASessionWindowWithNoControllerDoesNotCancelMain() {
        let router = MacSessionWindowStopRouter()
        let a = NSWindow()
        a.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        var mainStops = 0
        MacSessionWindows.stopResponse(window: a, router: router) { mainStops += 1 }
        XCTAssertEqual(mainStops, 0)
    }

    func testStopFromAnyOtherWindowStopsMain() {
        let router = MacSessionWindowStopRouter()
        let main = NSWindow()
        main.identifier = NSUserInterfaceItemIdentifier("conduit-primary-AppWindow-1")
        var mainStops = 0
        MacSessionWindows.stopResponse(window: main, router: router) { mainStops += 1 }
        XCTAssertEqual(mainStops, 1)
    }

    func testAnUnregisteredWindowIsNoLongerRouted() {
        let router = MacSessionWindowStopRouter()
        let a = NSWindow()
        var stops = 0
        router.register(window: a) { stops += 1 }
        router.unregister(window: a)
        XCTAssertFalse(router.stop(in: a))
        XCTAssertEqual(stops, 0)
    }

    // MARK: Option-Command-N

    private func tabsStore() -> (store: MacSessionTabsStore, suite: (defaults: UserDefaults, name: String)) {
        let suite = HostedTestSupport.makeSuite()
        let store = MacSessionTabsStore(defaults: suite.defaults)
        store.setScope(dashboardID: nil, profile: "default")
        store.openSession = { _ in }
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0) }
        return (store, suite)
    }

    private func mainWindow() -> NSWindow {
        let w = NSWindow()
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("conduit-primary-AppWindow-1")
        return w
    }

    func testPopOutActiveMovesTheActiveTabFromTheMainWindow() {
        let (store, suite) = tabsStore()
        defer { HostedTestSupport.dropSuite(suite) }
        var opened: [String] = []
        MacSessionTabsActions.popOutActive(store: store, window: mainWindow(), canPopOut: { _ in true }) { opened.append($0); return true }
        XCTAssertEqual(opened, ["b"])
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"])
    }

    func testPopOutActiveIsIgnoredOutsideTheMainChatWindow() {
        let (store, suite) = tabsStore()
        defer { HostedTestSupport.dropSuite(suite) }
        let other = NSWindow()
        other.identifier = NSUserInterfaceItemIdentifier("some-other-window")
        let session = NSWindow()
        session.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        var opened = 0
        for window in [other, session] {
            MacSessionTabsActions.popOutActive(store: store, window: window, canPopOut: { _ in true }) { _ in opened += 1; return true }
        }
        MacSessionTabsActions.popOutActive(store: store, window: nil, canPopOut: { _ in true }) { _ in opened += 1; return true }
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(store.model.tabs.count, 2)
    }

    func testPopOutActiveIgnoresAnUnavailableTab() {
        let (store, suite) = tabsStore()
        defer { HostedTestSupport.dropSuite(suite) }
        store.openFailed("b")
        var opened = 0
        MacSessionTabsActions.popOutActive(store: store, window: mainWindow(), canPopOut: { _ in true }) { _ in opened += 1; return true }
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
    }

    // MARK: Final review fixes (D21)

    private func summary(_ id: String, stored: String? = nil) -> SessionSummary {
        SessionSummary(id: id, storedSessionId: stored, alternateIds: [], title: id, model: "", updatedLabel: "",
                       profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
    }

    private func sessionWindow() -> NSWindow {
        let w = NSWindow()
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        return w
    }

    func testOnlyCatalogSessionsCanPopOut() {
        let catalog = [summary("a"), summary("row", stored: "stored")]
        XCTAssertTrue(MacSessionWindows.canPopOut("a", catalog: catalog))
        XCTAssertTrue(MacSessionWindows.canPopOut("stored", catalog: catalog), "any id of the row")
        XCTAssertFalse(MacSessionWindows.canPopOut("bot-chat", catalog: catalog), "a Bot Chat has no workspace catalog row")
        XCTAssertFalse(MacSessionWindows.canPopOut("a", catalog: []))
    }

    func testTabContextMenuPopOutIsDisabledForABotChatTab() {
        let catalog = [summary("a")]
        XCTAssertTrue(MacSessionTabStrip.popOutEnabled(tab: MacSessionTab(id: "a", title: "A"), catalog: catalog, windowsFull: false))
        XCTAssertFalse(MacSessionTabStrip.popOutEnabled(tab: MacSessionTab(id: "bot", title: "Bot"), catalog: catalog, windowsFull: false))
        XCTAssertFalse(MacSessionTabStrip.popOutEnabled(tab: MacSessionTab(id: "a", title: "A"), catalog: catalog, windowsFull: true))
        XCTAssertFalse(MacSessionTabStrip.popOutEnabled(tab: MacSessionTab(id: "a", title: "A", unavailable: true), catalog: catalog, windowsFull: false))
    }

    func testPopOutActiveIgnoresATabTheCatalogDoesNotList() {
        let (store, suite) = tabsStore()
        defer { HostedTestSupport.dropSuite(suite) }
        var opened = 0
        MacSessionTabsActions.popOutActive(store: store, window: mainWindow(), canPopOut: { _ in false }) { _ in opened += 1; return true }
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"], "the tab stays where it is")
        MacSessionTabsActions.popOutActive(store: store, window: mainWindow(),
                                           canPopOut: { MacSessionWindows.canPopOut($0, catalog: [self.summary("b")]) }) { _ in opened += 1; return true }
        XCTAssertEqual(opened, 1)
    }

    // MARK: Main-window commands from a session window

    func testTabShortcutsDoNothingFromASessionWindow() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        MacKeyboardActions.selectTab(.kanban, window: sessionWindow(), defaults: suite.defaults)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.sessions.rawValue)
        MacKeyboardActions.selectTab(.kanban, window: mainWindow(), defaults: suite.defaults)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
    }

    func testSidebarToggleDoesNothingFromASessionWindow() {
        var toggles = 0
        MacKeyboardActions.toggleSidebar(window: sessionWindow()) { toggles += 1 }
        XCTAssertEqual(toggles, 0)
        MacKeyboardActions.toggleSidebar(window: mainWindow()) { toggles += 1 }
        XCTAssertEqual(toggles, 1)
    }

    func testSearchSessionsDoesNotFocusTheMainSearchFromASessionWindow() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(false, forKey: MacSidebarState.defaultsKey)
        let requests = MacFocusRequests()
        let before = requests.searchToken
        XCTAssertNil(MacKeyboardActions.findOrSearchSessions(window: sessionWindow(), defaults: suite.defaults, requests: requests))
        XCTAssertEqual(suite.defaults.bool(forKey: MacSidebarState.defaultsKey), false, "the sidebar stays hidden")
        XCTAssertEqual(requests.searchToken, before)
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: mainWindow(), defaults: suite.defaults, requests: requests), .searchSessions)
        XCTAssertGreaterThan(requests.searchToken, before)
    }

    func testSessionNeighbourShortcutsDoNothingFromASessionWindow() {
        var opened: [String] = []
        MacKeyboardActions.openNeighbor(.next, order: ["a", "b"], activeID: "a", window: sessionWindow()) { opened.append($0) }
        XCTAssertTrue(opened.isEmpty)
        MacKeyboardActions.openNeighbor(.next, order: ["a", "b"], activeID: "a", window: mainWindow()) { opened.append($0) }
        XCTAssertEqual(opened, ["b"])
    }

    func testAskAboutWindowDoesNotRunFromASessionWindow() {
        XCTAssertFalse(MacAskAboutWindow.mayRun(from: sessionWindow()))
        XCTAssertTrue(MacAskAboutWindow.mayRun(from: mainWindow()))
    }

    func testNewChatFromASessionWindowBringsMainForwardThenCreates() {
        let main = mainWindow(), side = sessionWindow()
        var created = 0, reopened = 0
        MacAppActions.newChat(window: side, windows: [side, main], openMainWindow: { reopened += 1 }) { created += 1 }
        XCTAssertEqual(created, 1)
        XCTAssertEqual(reopened, 0)
        XCTAssertTrue(main.isVisible, "the new chat is shown in the main window")
        main.close()
    }

    func testNewChatFromASessionWindowReopensAClosedMainWindow() {
        let side = sessionWindow()
        var created = 0, reopened = 0
        MacAppActions.newChat(window: side, windows: [side], openMainWindow: { reopened += 1 }) { created += 1 }
        XCTAssertEqual(reopened, 1)
        XCTAssertEqual(created, 1)
    }

    func testNewChatFromTheMainWindowJustCreates() {
        let main = mainWindow()
        var created = 0, reopened = 0
        MacAppActions.newChat(window: main, windows: [main], openMainWindow: { reopened += 1 }) { created += 1 }
        XCTAssertEqual(created, 1)
        XCTAssertEqual(reopened, 0)
    }

    func testSettingsAndSwitchDashboardFromASessionWindowReopenAClosedMainWindow() {
        let side = sessionWindow()
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let palette = MacPaletteStore(defaults: suite.defaults)
        var reopened = 0
        XCTAssertFalse(MacAppActions.openSettings(window: side, windows: [side], palette: palette, center: NotificationCenter(),
                                                  openMainWindow: { reopened += 1 }))
        XCTAssertFalse(MacAppActions.switchDashboard(window: side, windows: [side], palette: palette,
                                                     switcher: MacDashboardSwitcherStore(), openMainWindow: { reopened += 1 }))
        XCTAssertEqual(reopened, 2)
        // From a window that is neither main nor session, nothing reopens.
        let other = NSWindow()
        XCTAssertFalse(MacAppActions.openSettings(window: other, windows: [], palette: palette, center: NotificationCenter(),
                                                  openMainWindow: { reopened += 1 }))
        XCTAssertEqual(reopened, 2)
    }

    // MARK: Dock reopen with the main window closed

    func testReopenOpensTheMainWindowWhenOnlyASessionWindowIsVisible() {
        let side = sessionWindow()
        side.orderFront(nil)
        defer { side.close() }
        XCTAssertEqual(MacPrimaryWindow.reopenAction(hasVisibleWindows: true, windows: [side]), .openPrimary)
    }

    func testReopenDoesNothingWithNoWindowsLeftForTheSystemToHandle() {
        XCTAssertEqual(MacPrimaryWindow.reopenAction(hasVisibleWindows: false, windows: []), .none)
        XCTAssertEqual(MacPrimaryWindow.reopenAction(hasVisibleWindows: false, windows: [sessionWindow()]), .none)
    }

    func testReopenShowsAHiddenPrimaryAndLeavesAVisibleOneAlone() {
        let main = mainWindow()
        XCTAssertEqual(MacPrimaryWindow.reopenAction(hasVisibleWindows: false, windows: [main]), .showPrimary(main))
        main.orderFront(nil)
        defer { main.close() }
        XCTAssertEqual(MacPrimaryWindow.reopenAction(hasVisibleWindows: true, windows: [main]), .none)
    }

    func testHandleReopenOpensThroughTheRegisteredOpener() {
        let side = sessionWindow()
        let opener = MacPrimaryWindowOpener()
        XCTAssertFalse(opener.open(), "nothing registered: a clean no-op")
        var opened = 0
        opener.register { opened += 1 }
        MacPrimaryWindow.handleReopen(hasVisibleWindows: true, windows: [side], opener: opener)
        XCTAssertEqual(opened, 1)
        MacPrimaryWindow.handleReopen(hasVisibleWindows: false, windows: [], opener: opener)
        XCTAssertEqual(opened, 1)
    }
}
