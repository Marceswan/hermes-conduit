import XCTest
@testable import ConduitMac

/// The sidebar New Chat button on Mac follows upstream's `canTapNewChat`
/// (R21): it can queue a chat while Conduit connects or synchronizes, shows a
/// chat already on its way, and is off while the app's own New Chat is
/// creating its chat. The Mac keeps one reason of its own: with the saved
/// copy up and no live gateway the button queues no chat.
/// `macNewChatDisabled` (the guard of callers that create at once) is not
/// changed; `MissingSessionRecoveryTests` pins it.
@MainActor
final class MacNewChatAvailabilityTests: XCTestCase {
    // The test host shares the Keychain service with the user's real app: these tests build an
    // `AppState`, so they run on an in-memory Keychain (see MacMemoryKeychainBackend).
    override func setUp() async throws {
        MacMemoryKeychainBackend.install()
    }

    override func tearDown() async throws {
        MacMemoryKeychainBackend.restore()
    }

    func testTheseTestsRunOnAnInMemoryKeychain() {
        XCTAssertTrue(KeychainHelper.backend is MacMemoryKeychainBackend)
    }

    private func makeAppState(connected: Bool = false, connecting: Bool = false) throws -> (AppState, SavedDashboard) {
        let suite = "MacNewChatAvailabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnecting = connecting
        appState.isConnected = connected
        return (appState, dashboard)
    }

    private func showSavedCopy(_ appState: AppState, dashboard: SavedDashboard) {
        appState.offlineChatCacheForTesting.record(
            dashboardID: dashboard.id,
            profile: "default",
            sessionID: "saved",
            title: "Saved",
            messages: [ChatMessage(id: "c1", role: .user, content: "cached", timestamp: "1")],
            sessions: []
        )
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard.id)
    }

    // MARK: - Upstream's rule

    func testNothingToWaitForKeepsTheButtonOff() throws {
        let (appState, _) = try makeAppState()
        XCTAssertTrue(appState.macNewChatButtonDisabled, "no connection is on its way")
    }

    func testButtonIsOnWhileConduitConnects() throws {
        let (appState, _) = try makeAppState(connecting: true)
        XCTAssertFalse(appState.macNewChatButtonDisabled, "a New Chat can wait for the connection")
    }

    func testButtonIsOnWhileConnected() throws {
        let (appState, _) = try makeAppState(connected: true)
        XCTAssertFalse(appState.macNewChatButtonDisabled)
        XCTAssertFalse(appState.macNewChatDisabled)
    }

    func testButtonIsOnWhileSynchronizingAndTheCreatingCallersWait() async throws {
        let (appState, _) = try makeAppState(connected: true)
        let release = AsyncStream<Void>.makeStream()
        appState.widgetSessionCreatorOverride = { _, _ in
            for await _ in release.stream { break }
            return (sessionId: "sync-1", storedSessionId: "sync-1", profile: "default")
        }
        // A create that does not come from the New Chat button: the turn state
        // is `.synchronizing`, and `isStartingNewChat` stays false.
        let creating = Task { await appState.createNewSession() }
        for _ in 0..<200 where appState.turnState != .synchronizing {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(appState.turnState, .synchronizing, "precondition")
        XCTAssertFalse(appState.isStartingNewChat)
        XCTAssertFalse(appState.macNewChatButtonDisabled, "upstream queues a New Chat while Conduit synchronizes")
        XCTAssertTrue(appState.macNewChatDisabled, "the Notch menu and Home would start a second create")
        release.continuation.yield()
        await creating.value
    }

    func testAChatOnItsWayKeepsTheButtonOn() throws {
        let (appState, dashboard) = try makeAppState()
        XCTAssertTrue(appState.macNewChatButtonDisabled, "precondition: nothing to wait for")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: "default")
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        appState.widgetLaunchPendingLinkChanged(link)
        XCTAssertTrue(appState.showsPendingNewChat)
        XCTAssertFalse(appState.macNewChatButtonDisabled, "a tap shows the chat already on its way")
    }

    func testButtonIsOffWhileTheAppsOwnNewChatCreatesItsChat() async throws {
        let (appState, _) = try makeAppState(connected: true)
        let release = AsyncStream<Void>.makeStream()
        appState.widgetSessionCreatorOverride = { _, _ in
            for await _ in release.stream { break }
            return (sessionId: "new-1", storedSessionId: "new-1", profile: "default")
        }
        XCTAssertFalse(appState.macNewChatButtonDisabled, "precondition")

        appState.startNewChat()

        XCTAssertTrue(appState.isStartingNewChat)
        XCTAssertTrue(appState.macNewChatButtonDisabled, "a second tap must not start a second chat")

        release.continuation.yield()
        for _ in 0..<200 where appState.isStartingNewChat {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(appState.isStartingNewChat)
        XCTAssertFalse(appState.macNewChatButtonDisabled)
    }

    // MARK: - The Mac reason: the saved copy

    func testSavedCopyWithoutALiveGatewayQueuesNoChat() throws {
        let (appState, dashboard) = try makeAppState(connecting: true)
        showSavedCopy(appState, dashboard: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation, "precondition: the saved copy is on screen")
        XCTAssertFalse(appState.isConnected)
        XCTAssertTrue(appState.canTapNewChat, "upstream would queue a chat while connecting")
        XCTAssertTrue(appState.macNewChatButtonDisabled, "Mac: the copy has no live gateway to create a chat on")
    }

    func testConnectedFlagWithoutAClientIsNotALiveGateway() throws {
        let (appState, dashboard) = try makeAppState(connected: true)
        showSavedCopy(appState, dashboard: dashboard)
        appState.client = nil
        XCTAssertTrue(appState.macNewChatButtonDisabled)
    }

    func testSavedCopyDoesNotBlockOnceTheClientIsLive() throws {
        let (appState, dashboard) = try makeAppState(connected: true)
        showSavedCopy(appState, dashboard: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation)
        XCTAssertFalse(appState.macNewChatButtonDisabled)
    }

    func testSavedCopyWithAChatOnItsWayStaysReachable() {
        XCTAssertFalse(AppState.macNewChatButtonDisabled(
            canTapNewChat: true, showsPendingNewChat: true, hasSavedCopy: true, hasLiveGateway: false))
    }

    // MARK: - The pure rule

    func testPureRule() {
        func disabled(tap: Bool, pending: Bool, copy: Bool, live: Bool) -> Bool {
            AppState.macNewChatButtonDisabled(
                canTapNewChat: tap, showsPendingNewChat: pending, hasSavedCopy: copy, hasLiveGateway: live)
        }
        for pending in [false, true] {
            for copy in [false, true] {
                for live in [false, true] {
                    XCTAssertTrue(disabled(tap: false, pending: pending, copy: copy, live: live),
                                  "upstream's rule off always wins")
                }
            }
        }
        XCTAssertFalse(disabled(tap: true, pending: false, copy: false, live: false))
        XCTAssertFalse(disabled(tap: true, pending: false, copy: false, live: true))
        XCTAssertFalse(disabled(tap: true, pending: false, copy: true, live: true))
        XCTAssertTrue(disabled(tap: true, pending: false, copy: true, live: false))
    }
}
