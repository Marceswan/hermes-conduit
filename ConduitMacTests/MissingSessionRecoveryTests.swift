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

    private final class Requests {
        var ids: [String] = []
        /// Runs inside `session.resume`, before it answers (fence tests).
        var onOpen: ((String) -> Void)?
        /// `session.create` seam: nil leaves the real client (which throws notConnected).
        var create: (@MainActor () async throws -> String)?
        var createCalls = 0
        var gateDisabledDuringCreate: [Bool] = []
        var turnStateDuringCreate: [TurnState] = []
        weak var appState: AppState?
    }

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
        var operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in catalog },
            openSession: { _, id, _ in
                requests.ids.append(id)
                requests.onOpen?(id)
                return try open(id)
            },
            persistedTranscript: persistedTranscript,
            refreshContext: { _, _ in }
        )
        operations.createSession = { [unowned requests] _, _ in
            requests.createCalls += 1
            if let state = requests.appState {
                requests.gateDisabledDuringCreate.append(state.macNewChatDisabled)
                requests.turnStateDuringCreate.append(state.turnState)
            }
            guard let create = requests.create else { throw HermesError.notConnected }
            let id = try await create()
            return (sessionId: id, storedSessionId: id, profile: nil)
        }
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            reconnectScheduler: scheduler.schedule(after:operation:),
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        requests.appState = appState
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

    // MARK: - Probe cap, dead-row memory, fresh-chat success

    private func deadCatalog(_ count: Int) -> [SessionSummary] {
        (0..<count).map { session("r\($0)") }
    }

    func testDeadRowWalkIsCappedThenCreatesFreshChatWhileGateStaysClosed() async {
        let requests = Requests()
        requests.create = { "new-1" }
        let f = makeFixture(
            saved: "r0",
            catalog: deadCatalog(6),
            open: { _ in throw self.notFound },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["r0", "r1", "r2", "r3"], "the dead target plus at most 3 probes, then create")
        XCTAssertEqual(requests.createCalls, 1)
        XCTAssertEqual(requests.turnStateDuringCreate, [.synchronizing])
        XCTAssertEqual(requests.gateDisabledDuringCreate, [true], "New Chat is not pressable during the helper's create")
        XCTAssertEqual(f.appState.activeSessionId, "new-1")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNotEqual(f.store.lastSessionID(for: "default"), "r0", "the dead pointer is forgotten")
        XCTAssertEqual(f.appState.turnState, .idle)
        XCTAssertFalse(f.appState.macNewChatDisabled, "enabled again once the create settled")
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    func testRetryAfterFailedCreateDoesNotReprobeDeadRows() async {
        let requests = Requests()
        struct NoNetwork: Error {}
        requests.create = { throw NoNetwork() }
        let f = makeFixture(
            saved: "r0",
            catalog: deadCatalog(6),
            open: { _ in throw self.notFound },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["r0", "r1", "r2", "r3"])
        XCTAssertTrue(f.appState.errorMessage?.hasPrefix("Failed to create session:") == true)
        XCTAssertEqual(f.scheduler.scheduledCount, 1)
        XCTAssertEqual(f.appState.turnState, .idle)
        XCTAssertFalse(f.appState.macNewChatDisabled, "a failed create leaves New Chat usable")

        // The scheduled retry: same automatic purpose, pointer already forgotten.
        requests.create = { "new-2" }
        await f.appState.syncSession(purpose: .automaticReturn, using: nil, automaticWorkToken: nil)

        XCTAssertEqual(Set(requests.ids).count, requests.ids.count, "no row is probed twice: \(requests.ids)")
        XCTAssertEqual(requests.ids, ["r0", "r1", "r2", "r3", "r4", "r5"])
        XCTAssertEqual(f.appState.activeSessionId, "new-2")
    }

    func testTransientFailureAfterDeadRowDoesNotCreateAndRetries() async {
        struct Transient: Error {}
        let requests = Requests()
        requests.create = { "must-not-happen" }
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("flaky"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                throw Transient()
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "flaky"])
        XCTAssertEqual(requests.createCalls, 0, "a transient failure is not evidence the catalog is dead")
        XCTAssertNotEqual(f.store.lastSessionID(for: "default"), "flaky", "the transient row is not forgotten")
        XCTAssertNil(f.appState.activeSessionId)
        XCTAssertEqual(f.scheduler.scheduledCount, 1, "exactly one retry")
    }

    // MARK: - Fences

    func testClientSwitchMidWalkStopsRecovery() async {
        let requests = Requests()
        requests.create = { "must-not-happen" }
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("d1"), session("good")],
            open: { _ in throw self.notFound },
            requests: requests
        )
        requests.onOpen = { id in
            guard id == "d1" else { return }
            requests.appState?.client = HermesClient(
                connection: HermesConnection(baseUrl: "https://two.example", ticket: "t2"), profile: "default")
        }

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "d1"], "nothing is probed or created for the replaced client")
        XCTAssertEqual(requests.createCalls, 0)
        XCTAssertEqual(f.scheduler.scheduledCount, 0, "the new client owns its own recovery")
        XCTAssertNil(f.appState.activeSessionId)
    }

    func testNewReconciliationTakingOverMidWalkStopsRecovery() async {
        let requests = Requests()
        requests.create = { "must-not-happen" }
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("d1"), session("good")],
            open: { _ in throw self.notFound },
            requests: requests
        )
        // An explicit open or New Chat begins its own reconciliation.
        requests.onOpen = { id in
            if id == "d1" { _ = requests.appState?.beginReconciliation() }
        }

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "d1"])
        XCTAssertEqual(requests.createCalls, 0)
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
        // createNewSession refuses during a workspace switch, so the button is off too.
        XCTAssertTrue(AppState.macNewChatDisabled(
            turnState: .idle, hasSavedCopy: false, hasLiveGateway: true, isProfileSwitching: true))
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
