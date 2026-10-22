import AppKit
import XCTest
@testable import ConduitMac

/// New Chat commands at a cold launch (live check F8, and the pre-review fix): a New Chat asked for while Conduit
/// connects created no chat, not even after the connection. The menu item, the Cmd-K palette and the chat that opens
/// after the last tab closes called `createNewSession()`, which does nothing until the session is connected. The
/// sidebar button calls `startNewChat()` (upstream's `canTapNewChat` rule, Ruling R39), which queues one chat for the
/// connection. These three now go the same way. The Notch and Home are the callers that create a chat at once; they
/// stay on the strict gate (`macNewChatDisabled`) and must show a disabled state, not drop a click.
@MainActor
final class MacNewChatCommandTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var appState: AppState!
    private var dashboard: SavedDashboard!
    private var scratch: URL!

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacNewChatCommandTests.\(UUID().uuidString)", isDirectory: true)
        dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults)
        )
        // A created chat publishes widget snapshots: keep them out of the real app group.
        appState.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: scratch.appendingPathComponent("widgets", isDirectory: true))
        appState.widgetSnapshotReloadOverride = {}
        appState.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
        // The window is on screen and active, as at a cold launch once the user can press a key.
        _ = appState.handleScenePhase(.active)
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
    }

    override func tearDown() async throws {
        appState.widgetLaunchCoordinator.supersede()
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private var workspace: WidgetWorkspaceID { WidgetWorkspaceID(dashboardID: dashboard.id, profile: "default") }

    private func stubCreator(_ created: @escaping () -> Void) {
        appState.widgetSessionCreatorOverride = { _, _ in
            created()
            return (sessionId: "cmd-n-chat", storedSessionId: "cmd-n-chat", profile: "default")
        }
    }

    /// Lets the main actor run (a main-actor `Task` does not run inside a nested run loop).
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    private func connect() {
        appState.widgetSettledCatalogOwner = workspace
        appState.isConnecting = false
        appState.isConnected = true
    }

    // MARK: The cold launch

    func testCmdNWhileConduitConnectsQueuesOneChatThatIsCreatedAfterTheConnection() async throws {
        var creates = 0
        stubCreator { creates += 1 }
        appState.isConnecting = true
        XCTAssertFalse(appState.isConnected, "precondition: cold launch, the connection is on its way")

        MacAppActions.newChat(window: nil, appState: appState)
        MacAppActions.newChat(window: nil, appState: appState)
        // The key press has been handled before the connection comes up: let the main actor run what it started.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.pendingNewChat, workspace, "the chat is waiting for the connection")
        XCTAssertEqual(creates, 0, "nothing can be created before the connection")

        connect()
        let created = await waitUntil { !self.appState.showsPendingNewChat && self.appState.activeSessionId == "cmd-n-chat" }
        XCTAssertTrue(created, "the queued chat is created once connected")
        XCTAssertEqual(creates, 1, "two Cmd-N during the connect make one chat")
    }

    func testCmdNWhileConnectedStartsAChatAtOnce() async throws {
        var creates = 0
        stubCreator { creates += 1 }
        appState.isConnected = true

        MacAppActions.newChat(window: nil, appState: appState)

        let started = await waitUntil { self.appState.activeSessionId == "cmd-n-chat" }
        XCTAssertTrue(started, "the chat starts")
        XCTAssertEqual(creates, 1)
        XCTAssertFalse(appState.showsPendingNewChat)
    }

    func testCmdNWithNoConnectionOnItsWayStartsNothing() async throws {
        var creates = 0
        stubCreator { creates += 1 }
        appState.showLogin = true // the sign-in card is up: no session, none coming

        MacAppActions.newChat(window: nil, appState: appState)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(appState.showsPendingNewChat)
        XCTAssertEqual(creates, 0)
    }

    // MARK: The other New Chat commands queue too

    func testPaletteNewChatDuringTheConnectQueuesOneChatThatIsCreatedAfterTheConnection() async throws {
        var creates = 0
        stubCreator { creates += 1 }
        appState.isConnecting = true
        let calls = MacPaletteCalls.live(appState: appState)

        calls.newChat()
        calls.newChat()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.pendingNewChat, workspace, "the chat is waiting for the connection")
        XCTAssertEqual(creates, 0)

        connect()
        let created = await waitUntil { !self.appState.showsPendingNewChat && self.appState.activeSessionId == "cmd-n-chat" }
        XCTAssertTrue(created, "the queued chat is created once connected")
        XCTAssertEqual(creates, 1, "two palette New Chats during the connect make one chat")
    }

    func testChatAfterTheLastTabClosesIsQueuedDuringTheConnect() async throws {
        var creates = 0
        stubCreator { creates += 1 }
        let tabs = MacSessionTabsStore(defaults: suite.defaults, routeDefaults: suite.defaults)
        tabs.bind(to: appState)
        // One tab, and a chat with something in it, so that Cmd-W closes it instead of keeping the empty chat.
        tabs.activeSessionChanged("s1", title: "One")
        appState.messages = [ChatMessage(id: "m1", role: .user, content: "hello", timestamp: "1")]
        appState.isConnecting = true

        tabs.close("s1")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.pendingNewChat, workspace, "the new chat is waiting for the connection")
        XCTAssertEqual(creates, 0)

        connect()
        let created = await waitUntil { !self.appState.showsPendingNewChat && self.appState.activeSessionId == "cmd-n-chat" }
        XCTAssertTrue(created, "the queued chat is created once connected")
        XCTAssertEqual(creates, 1)
    }

    func testChatAfterTheLastTabPopsOutIsQueuedDuringTheConnect() async throws {
        let tabs = MacSessionTabsStore(defaults: suite.defaults, routeDefaults: suite.defaults)
        tabs.bind(to: appState)
        tabs.activeSessionChanged("s1", title: "One")
        appState.isConnecting = true

        tabs.popOut("s1") { _ in true }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.pendingNewChat, workspace)
    }

    // MARK: The Notch and Home show a disabled state during the connect

    private func showSavedCopy() {
        appState.offlineChatCacheForTesting.record(
            dashboardID: dashboard.id, profile: "default", sessionID: "saved", title: "Saved",
            messages: [ChatMessage(id: "c1", role: .user, content: "cached", timestamp: "1")], sessions: [])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard.id)
        XCTAssertNotNil(appState.offlineChatPresentation, "precondition: the saved copy is on screen")
    }

    private func homeCanStartChat() -> Bool {
        MacHomeBinding.input(appState: appState, feed: nil, kanban: .unavailable, cron: .notLoaded, now: Date()).canStartChat
    }

    func testNotchNewChatIsDisabledWhileConduitConnectsWithTheSavedCopyUp() throws {
        appState.isConnecting = true
        showSavedCopy()
        let notch = NotchActions.live(appState: appState)
        XCTAssertFalse(notch.newChatEnabled())
        notch.newChat()   // a click on a disabled item must do nothing
        XCTAssertFalse(appState.showsPendingNewChat)
    }

    func testNotchNewChatIsDisabledWhileConduitConnectsWithNoSavedCopy() throws {
        appState.isConnecting = true
        XCTAssertNil(appState.offlineChatPresentation, "precondition: no saved copy")
        let notch = NotchActions.live(appState: appState)
        XCTAssertFalse(notch.newChatEnabled(), "an enabled item here would drop the click: createNewSession needs a connected session")
        notch.newChat()
        XCTAssertFalse(appState.showsPendingNewChat)
    }

    func testNotchNewChatIsEnabledWhenConnected() throws {
        appState.isConnected = true
        XCTAssertTrue(NotchActions.live(appState: appState).newChatEnabled())
    }

    func testHomeNewChatIsOffWhileConduitConnects() throws {
        appState.isConnecting = true
        XCTAssertFalse(homeCanStartChat(), "no saved copy")
        showSavedCopy()
        XCTAssertFalse(homeCanStartChat(), "saved copy up")
    }

    func testHomeNewChatIsOnWhenConnected() throws {
        appState.isConnected = true
        XCTAssertTrue(homeCanStartChat())
    }

    // MARK: The menu item calls it

    func testTheNewChatMenuItemRunsTheSharedAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("ConduitMac/App/ConduitCommands.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "Button(\"New Chat\") {"))
        let tail = text[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: ".keyboardShortcut(\"n\", modifiers: .command)"))
        let item = String(tail[..<end.lowerBound])
        XCTAssertTrue(item.contains("MacAppActions.newChat(window: NSApp.keyWindow, appState: appState)"), item)
        XCTAssertFalse(item.contains("createNewSession"), "a direct create ignores a connection that is not up yet")
    }
}
