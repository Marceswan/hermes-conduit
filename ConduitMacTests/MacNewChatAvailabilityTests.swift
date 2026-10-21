import XCTest
@testable import ConduitMac

/// New Chat on Mac.
///
/// The sidebar button is upstream's own: `.disabled(!appState.canTapNewChat)`, with no Mac region
/// (Ruling R39). It can queue a chat while Conduit connects or synchronizes, also at a cold launch
/// with the saved copy on screen, shows a chat already on its way, and is off while the app's own
/// New Chat is creating its chat. The tests below pin that state table in the Mac fixtures, so a
/// later upstream change to `canTapNewChat` shows here.
///
/// `macNewChatDisabled` is the stricter gate of the callers that create a chat at once (the Notch
/// menu and Home). `MissingSessionRecoveryTests` pins its saved-copy and synchronizing rules.
@MainActor
final class MacNewChatAvailabilityTests: XCTestCase {
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

    // MARK: - The sidebar button (upstream's canTapNewChat)

    func testNothingToWaitForKeepsTheButtonOff() throws {
        let (appState, _) = try makeAppState()
        XCTAssertFalse(appState.canTapNewChat, "no connection is on its way")
    }

    func testButtonIsOnWhileConduitConnects() throws {
        let (appState, _) = try makeAppState(connecting: true)
        XCTAssertTrue(appState.canTapNewChat, "a New Chat can wait for the connection")
    }

    func testButtonIsOnWhileConnected() throws {
        let (appState, _) = try makeAppState(connected: true)
        XCTAssertTrue(appState.canTapNewChat)
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
        XCTAssertTrue(appState.canTapNewChat, "upstream queues a New Chat while Conduit synchronizes")
        XCTAssertTrue(appState.macNewChatDisabled, "the Notch menu and Home would start a second create")
        release.continuation.yield()
        await creating.value
    }

    func testAChatOnItsWayKeepsTheButtonOn() throws {
        let (appState, dashboard) = try makeAppState()
        XCTAssertFalse(appState.canTapNewChat, "precondition: nothing to wait for")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: "default")
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        appState.widgetLaunchPendingLinkChanged(link)
        XCTAssertTrue(appState.showsPendingNewChat)
        XCTAssertTrue(appState.canTapNewChat, "a tap shows the chat already on its way")
    }

    func testButtonIsOffWhileTheAppsOwnNewChatCreatesItsChat() async throws {
        let (appState, _) = try makeAppState(connected: true)
        let release = AsyncStream<Void>.makeStream()
        appState.widgetSessionCreatorOverride = { _, _ in
            for await _ in release.stream { break }
            return (sessionId: "new-1", storedSessionId: "new-1", profile: "default")
        }
        XCTAssertTrue(appState.canTapNewChat, "precondition")
        XCTAssertFalse(appState.macNewChatDisabled, "precondition")

        appState.startNewChat()

        XCTAssertTrue(appState.isStartingNewChat)
        XCTAssertFalse(appState.canTapNewChat, "a second tap must not start a second chat")
        // The task that sets `.synchronizing` has not run yet: only `isStartingNewChat` closes the
        // Notch and Home gate in this gap.
        XCTAssertNotEqual(appState.turnState, .synchronizing, "precondition: the gap")
        XCTAssertTrue(appState.macNewChatDisabled, "a Notch or Home click in the gap would start a second create")

        release.continuation.yield()
        for _ in 0..<200 where appState.isStartingNewChat {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(appState.isStartingNewChat)
        XCTAssertTrue(appState.canTapNewChat)
        XCTAssertFalse(appState.macNewChatDisabled)
    }

    // MARK: - The saved copy (Ruling R39)

    /// Decision (R39): at a cold launch the Mac shows the saved copy while Conduit connects. The
    /// button still queues a chat, as upstream's does. The earlier Mac rule kept it off there.
    func testSavedCopyWhileConduitConnectsStillQueuesAChat() throws {
        let (appState, dashboard) = try makeAppState(connecting: true)
        showSavedCopy(appState, dashboard: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation, "precondition: the saved copy is on screen")
        XCTAssertFalse(appState.isConnected)
        XCTAssertTrue(appState.canTapNewChat, "the chat is queued while Conduit connects")
        XCTAssertTrue(appState.macNewChatDisabled, "a caller that creates at once has no live gateway to create on")
    }

    func testSavedCopyDoesNotBlockOnceTheClientIsLive() throws {
        let (appState, dashboard) = try makeAppState(connected: true)
        showSavedCopy(appState, dashboard: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation)
        XCTAssertTrue(appState.canTapNewChat)
        XCTAssertFalse(appState.macNewChatDisabled)
    }

    func testConnectedFlagWithoutAClientStillLetsTheButtonQueue() throws {
        let (appState, dashboard) = try makeAppState(connected: true)
        showSavedCopy(appState, dashboard: dashboard)
        appState.client = nil
        XCTAssertTrue(appState.canTapNewChat)
        XCTAssertTrue(appState.macNewChatDisabled, "the connected flag without a client is not a live gateway")
    }

    // MARK: - The live gateway (one rule for the strict gate and Home)

    func testLiveGatewayNeedsAConnectedClientThatIsNotConnecting() throws {
        let (appState, _) = try makeAppState()
        XCTAssertFalse(appState.macHasLiveGateway, "nothing connected")
        appState.isConnected = true
        XCTAssertTrue(appState.macHasLiveGateway)
        appState.isConnecting = true
        XCTAssertFalse(appState.macHasLiveGateway, "mid-connect is not live (createNewSession refuses)")
        appState.isConnecting = false
        appState.client = nil
        XCTAssertFalse(appState.macHasLiveGateway, "the connected flag without a client is not live")
    }

    // MARK: - The strict gate of the creating callers

    func testStrictGatePureRule() {
        func disabled(
            _ turn: TurnState = .idle, copy: Bool = false, live: Bool = true, switching: Bool = false,
            starting: Bool = false
        ) -> Bool {
            AppState.macNewChatDisabled(
                turnState: turn, hasSavedCopy: copy, hasLiveGateway: live,
                isProfileSwitching: switching, isStartingNewChat: starting)
        }
        XCTAssertFalse(disabled())
        XCTAssertTrue(disabled(starting: true), "the app's own New Chat is creating its chat")
        XCTAssertTrue(disabled(.synchronizing))
        XCTAssertTrue(disabled(switching: true))
        XCTAssertTrue(disabled(copy: true, live: false))
        XCTAssertFalse(disabled(copy: true, live: true))
    }
}
