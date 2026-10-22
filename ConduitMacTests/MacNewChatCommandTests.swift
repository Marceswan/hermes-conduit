import AppKit
import XCTest
@testable import ConduitMac

/// Cmd-N at a cold launch (live check F8): a Cmd-N while Conduit connects created no chat, not even after the
/// connection. The menu called `createNewSession()`, which does nothing until the session is connected. The sidebar
/// button calls `startNewChat()` (upstream's `canTapNewChat` rule, Ruling R39), which queues one chat for the
/// connection. Cmd-N now goes the same way.
@MainActor
final class MacNewChatCommandTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var appState: AppState!
    private var dashboard: SavedDashboard!

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults)
        )
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
