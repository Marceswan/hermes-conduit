import XCTest
@testable import ConduitMac

/// A restored conversation the gateway authoritatively reports missing
/// (`session.resume` 4007 "session not found") must not leave the user on a
/// dead read-only copy with New Chat disabled. These drive AppState through
/// its chat-resume test seams only; no gateway, no network.
@MainActor
final class MissingSessionRecoveryTests: XCTestCase {
    private final class Scheduler {
        private(set) var scheduledCount = 0
        func schedule(
            after delay: TimeInterval,
            operation: @escaping @MainActor () async -> Void
        ) -> ChatResumeReconnectCancellation {
            scheduledCount += 1
            return {}
        }
    }

    private final class Requests { var ids: [String] = [] }

    private struct Fixture {
        let appState: AppState
        let store: ChatResumeStore
        let scheduler: Scheduler
    }

    private let notFound = RpcError(code: 4007, message: "session not found")

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: nil, alternateIds: [], title: id, model: "Hermes",
            updatedLabel: "now", profile: "default", source: .chat, isActive: false,
            isArchived: false, lineageRootId: nil
        )
    }

    private func resumed(_ id: String) -> SessionResumeResult {
        SessionResumeResult(
            sessionId: id, storedSessionId: id,
            messages: [ChatMessage(id: "\(id)-m", role: .user, content: "hi", timestamp: "1")],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )
    }

    /// Cold launch with the saved copy up and a live client installed.
    private func makeFixture(
        saved: String,
        catalog: [SessionSummary],
        open: @escaping @MainActor (String) throws -> SessionResumeResult,
        persistedTranscript: (@MainActor (String, String, String) async -> PersistedTranscriptFetchOutcome)? = nil,
        requests: Requests
    ) -> Fixture {
        let suite = "MissingSessionRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.continueWhereLeftOff)
        let scheduler = Scheduler()
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            reconnectScheduler: scheduler.schedule(after:operation:),
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in catalog },
                openSession: { _, id, _ in
                    requests.ids.append(id)
                    return try open(id)
                },
                persistedTranscript: persistedTranscript,
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        store.setLastSessionID(saved, for: "default")

        let dashboard = UUID()
        appState.offlineChatCacheForTesting.record(
            dashboardID: dashboard, profile: "default", sessionID: saved, title: "Saved",
            messages: [ChatMessage(id: "c1", role: .user, content: "cached", timestamp: "1")],
            sessions: [session(saved)]
        )
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation, "precondition: cold launch shows the saved copy")
        return Fixture(appState: appState, store: store, scheduler: scheduler)
    }

    /// The automatic resume of a cold launch; afterwards the app is in the
    /// connected state the sidebar renders in (server answered, client live).
    private func coldLaunchSync(_ f: Fixture) async {
        await f.appState.syncSession(purpose: .automaticReturn, using: nil, automaticWorkToken: nil)
        f.appState.isConnected = true
    }

    // MARK: - Catalog lists the saved session but the gateway cannot resume it

    func testListedButMissingSavedSessionFallsBackToAnotherSession() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "other"])
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertEqual(f.store.lastSessionID(for: "default"), "other")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNil(f.appState.errorMessage)
        XCTAssertEqual(f.appState.turnState, .idle)
        XCTAssertEqual(f.scheduler.scheduledCount, 0, "No reconnect loop after an authoritative not-found")
        XCTAssertFalse(f.appState.macNewChatDisabled)
    }

    func testListedButMissingOnlySessionFallsBackToFreshChat() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone")],
            open: { _ in throw self.notFound },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone"], "The dead row is not resumed again")
        XCTAssertNil(f.store.lastSessionID(for: "default"), "The dead pointer is forgotten")
        XCTAssertTrue(
            f.appState.errorMessage?.hasPrefix("Failed to create session:") == true,
            "Recovery advances to creating a fresh chat (no transport in the test, so the create itself fails)"
        )
        XCTAssertEqual(f.scheduler.scheduledCount, 1, "Only the failed create remains retryable")
        XCTAssertFalse(f.appState.macNewChatDisabled, "Connected: New Chat works even though the copy is up")
    }

    func testSavedSessionNotInCatalogWhoseFallbackIsAlsoMissingTriesNextRow() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("stale"), session("good")],
            open: { id in
                if id == "gone" || id == "stale" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "stale", "good"])
        XCTAssertEqual(f.appState.activeSessionId, "good")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNil(f.appState.errorMessage)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    /// Evidence for the error source: the compact resume and the dashboard
    /// history fetch run concurrently and the resume RPC is awaited first, so
    /// its 4007 throws (and sets the not-found flag) whatever the history
    /// route answers. A REST 404 "Session not found" is not a path that
    /// bypasses the flag.
    func testDashboardHistory404WithResume4007StillFlagsNotFoundAndRecovers() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            persistedTranscript: { id, _, _ in
                id == "gone"
                    ? .failed(DashboardTicketBridgeError.http(status: 404, detail: "Session not found"))
                    : .unavailable
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(
            requests.ids, ["gone", "other", "other"],
            "the dead row once; the fallback twice (compact, then the legacy re-resume its .unavailable history asks for)"
        )
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNil(f.appState.errorMessage)
    }

    /// Control: the upstream recovery for a saved session the catalog omits
    /// already works with the saved copy up. Not part of the bug.
    func testSavedSessionAbsentFromCatalogRecoversWithSavedCopyUp() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "other"])
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    // MARK: - Unchanged behavior

    func testTransientResumeFailureOnListedSessionKeepsPointerAndRetries() async {
        struct Transient: Error {}
        let requests = Requests()
        let f = makeFixture(
            saved: "kept",
            catalog: [session("kept"), session("other")],
            open: { _ in throw Transient() },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["kept"])
        XCTAssertEqual(f.store.lastSessionID(for: "default"), "kept", "Only an authoritative not-found retires the pointer")
        XCTAssertEqual(f.scheduler.scheduledCount, 1)
        XCTAssertNotNil(f.appState.offlineChatPresentation)
    }

    func testOtherRpcCodeOnListedSessionIsNotAuthoritativeNotFound() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "kept",
            catalog: [session("kept"), session("other")],
            open: { _ in throw RpcError(code: 4001, message: "session not found") },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["kept"], "Only session.resume 4007 is authoritative, as upstream")
        XCTAssertEqual(f.store.lastSessionID(for: "default"), "kept")
        XCTAssertEqual(f.scheduler.scheduledCount, 1)
    }

    // MARK: - Sidebar New Chat gating

    func testNewChatGateRequiresLiveClientWhileSavedCopyIsUp() {
        func disabled(_ turn: TurnState, copy: Bool, live: Bool) -> Bool {
            AppState.macNewChatDisabled(turnState: turn, hasSavedCopy: copy, hasLiveGateway: live)
        }
        for turn in [TurnState.idle, .reconnecting, .running, .unsupportedGateway] {
            // No saved copy: never blocked here, live or not (createNewSession guards itself).
            XCTAssertFalse(disabled(turn, copy: false, live: true), "\(turn)")
            XCTAssertFalse(disabled(turn, copy: false, live: false), "\(turn)")
            // Saved copy, no live gateway: unchanged, disabled.
            XCTAssertTrue(disabled(turn, copy: true, live: false), "\(turn)")
            // Saved copy, live gateway: the copy no longer blocks it.
            XCTAssertFalse(disabled(turn, copy: true, live: true), "\(turn)")
        }
        // A running synchronize still disables it, as upstream.
        for copy in [false, true] {
            for live in [false, true] {
                XCTAssertTrue(disabled(.synchronizing, copy: copy, live: live))
            }
        }
    }

    func testNewChatGateReadsLiveGatewayFromClientState() {
        let f = makeFixture(
            saved: "s", catalog: [], open: { _ in throw self.notFound }, requests: Requests())
        let appState = f.appState

        // Cold launch: copy up, nothing connected.
        XCTAssertTrue(appState.macNewChatDisabled)

        // The connected flag without a client is not a live gateway.
        appState.client = nil
        appState.isConnected = true
        XCTAssertTrue(appState.macNewChatDisabled)

        // Mid-connect is not live either (createNewSession refuses).
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        appState.isConnecting = true
        XCTAssertTrue(appState.macNewChatDisabled)

        // Connected, client live, not connecting.
        appState.isConnecting = false
        XCTAssertFalse(appState.macNewChatDisabled)

        // Connection lost again: disabled.
        appState.isConnected = false
        XCTAssertTrue(appState.macNewChatDisabled)
    }

    func testOpeningAnotherSessionFromSidebarWorksWhileSavedCopyIsUp() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )
        f.appState.isConnected = true
        f.appState.sessions = [session("gone"), session("other")]

        let opened = await f.appState.requestOpenSession("other").value

        XCTAssertTrue(opened)
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertNil(f.appState.offlineChatPresentation)
    }
}
