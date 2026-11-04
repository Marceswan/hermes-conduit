import Combine
import XCTest
@testable import ConduitMac

/// The offline retry monitor (D36). A cold-launch restore that failed with no connection retried only on a
/// foreground that the Mac may not report. The monitor retries on a backoff, and on a few events. These tests drive
/// it with a hand clock, a hand timer and subjects, so nothing sleeps.
@MainActor
private final class RetryHarness {
    typealias Monitor = MacOfflineRetryMonitor

    let dashboardA = UUID()
    let dashboardB = UUID()
    var snapshot: Monitor.Snapshot
    var wouldPrompt = false
    private(set) var retries = 0
    private(set) var triggers: [Monitor.Trigger] = []
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let changes = PassthroughSubject<Void, Never>()
    let events = PassthroughSubject<Monitor.Trigger, Never>()

    /// Delay of every timer ever scheduled, in order.
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelled = 0
    private var pending: [Int: (delay: TimeInterval, fire: @MainActor () -> Void)] = [:]
    private var allFires: [Int: @MainActor () -> Void] = [:]
    private var next = 0
    /// Runs inside `retry`, as the real connect would change the app state.
    var onRetry: (RetryHarness) -> Void = { _ in }
    private(set) var monitor: Monitor!

    init() {
        snapshot = Monitor.Snapshot(waiting: true, isConnecting: false, pathUsable: true, dashboardID: dashboardA)
        monitor = Monitor(seams: Monitor.Seams(
            snapshot: { [unowned self] in snapshot },
            restoreWouldPrompt: { [unowned self] in wouldPrompt },
            retry: { [unowned self] trigger in
                retries += 1
                triggers.append(trigger)
                onRetry(self)
            },
            now: { [unowned self] in clock },
            schedule: { [unowned self] delay, fire in
                delays.append(delay)
                next += 1
                let id = next
                pending[id] = (delay, fire)
                allFires[id] = fire
                return { [weak self] in
                    guard let self, self.pending.removeValue(forKey: id) != nil else { return }
                    self.cancelled += 1
                }
            },
            changes: changes.eraseToAnyPublisher(),
            events: events.eraseToAnyPublisher()))
    }

    var pendingCount: Int { pending.count }

    /// An app-state change, then the change notice.
    func change(_ edit: (inout Monitor.Snapshot) -> Void) {
        edit(&snapshot)
        changes.send()
    }

    /// Moves the clock by the timer's delay and fires the newest pending timer.
    func fireTimer() {
        guard let id = pending.keys.max(), let entry = pending.removeValue(forKey: id) else { return }
        clock = clock.addingTimeInterval(entry.delay)
        entry.fire()
    }

    /// Fires a timer that was cancelled, as a late callback would.
    func fireFirstTimerEvenIfCancelled() {
        allFires[1]?()
    }

    /// An attempt that fails: connecting, then back to the waiting state.
    func makeRetryFail() {
        onRetry = { harness in harness.change { $0.isConnecting = true } }
    }

    func failConnect() {
        change { $0.isConnecting = false }
    }
}

@MainActor
final class MacOfflineRetryMonitorTests: XCTestCase {
    private func started() -> RetryHarness {
        let harness = RetryHarness()
        harness.monitor.start()
        return harness
    }

    // MARK: - Delays

    func testDelaySequenceIsFiveFifteenThirtyThenSixty() {
        let seen = (0..<7).map { MacOfflineRetryMonitor.delay(afterAttempts: $0) }
        XCTAssertEqual(seen, [5, 15, 30, 60, 60, 60, 60])
    }

    func testWaitingStateArmsTheFirstTimer() {
        let harness = started()
        XCTAssertEqual(harness.delays, [5])
        XCTAssertEqual(harness.retries, 0)
    }

    func testNothingIsArmedOutsideTheWaitingState() {
        let harness = RetryHarness()
        harness.snapshot.waiting = false
        harness.monitor.start()
        XCTAssertEqual(harness.delays, [])
        harness.events.send(.didBecomeActive)
        XCTAssertEqual(harness.retries, 0)
    }

    // MARK: - Backoff

    func testBackoffSurvivesAFailedAttempt() {
        let harness = RetryHarness()
        harness.makeRetryFail()
        harness.monitor.start()
        harness.fireTimer()
        XCTAssertEqual(harness.retries, 1)
        XCTAssertEqual(harness.pendingCount, 0, "no timer runs while the attempt connects")
        harness.failConnect()
        XCTAssertEqual(harness.delays, [5, 15], "a failed attempt must not restart at five seconds")
        harness.fireTimer()
        harness.failConnect()
        harness.fireTimer()
        harness.failConnect()
        harness.fireTimer()
        harness.failConnect()
        XCTAssertEqual(harness.delays, [5, 15, 30, 60, 60])
        XCTAssertEqual(harness.retries, 4)
    }

    func testBackoffSurvivesAConnectingStateThatLeavesTheWaitingPredicate() {
        let harness = RetryHarness()
        harness.onRetry = { harness in
            // The saved-ticket path sets a connection while it connects.
            harness.change { $0.waiting = false; $0.isConnecting = true }
        }
        harness.monitor.start()
        harness.fireTimer()
        harness.change { $0.waiting = true; $0.isConnecting = false }
        XCTAssertEqual(harness.delays, [5, 15])
    }

    func testBackoffResetsWhenTheWaitingStateEnds() {
        let harness = RetryHarness()
        harness.makeRetryFail()
        harness.monitor.start()
        harness.fireTimer()
        harness.failConnect()
        XCTAssertEqual(harness.delays, [5, 15])
        harness.change { $0.waiting = false }
        XCTAssertEqual(harness.pendingCount, 0, "the pending timer is cancelled")
        harness.change { $0.waiting = true }
        XCTAssertEqual(harness.delays, [5, 15, 5], "a new waiting state starts at five seconds")
    }

    // MARK: - Events

    func testDidBecomeActiveStartsOneAttemptAtOnce() {
        let harness = started()
        harness.events.send(.didBecomeActive)
        XCTAssertEqual(harness.triggers, [.didBecomeActive])
    }

    func testDidWakeStartsOneAttemptAtOnce() {
        let harness = started()
        harness.events.send(.didWake)
        XCTAssertEqual(harness.triggers, [.didWake])
    }

    func testPathReturningStartsOneAttemptAtOnce() {
        let harness = started()
        harness.change { $0.pathUsable = false }
        XCTAssertEqual(harness.retries, 0, "the path going away starts nothing")
        harness.change { $0.pathUsable = true }
        XCTAssertEqual(harness.triggers, [.networkReturned])
    }

    func testAnEventAdvancesTheBackoffAndRearmsTheTimer() {
        let harness = started()
        harness.events.send(.didBecomeActive)
        XCTAssertEqual(harness.delays, [5, 15])
        XCTAssertEqual(harness.pendingCount, 1, "one timer is pending, not two")
    }

    // MARK: - Coalescing

    func testTwoTriggersAtTheSameMomentStartOneAttempt() {
        let harness = started()
        harness.events.send(.didBecomeActive)
        harness.events.send(.didWake)
        XCTAssertEqual(harness.retries, 1)
    }

    func testAPathReturnRightAfterAnEventStartsNoSecondAttempt() {
        let harness = started()
        harness.change { $0.pathUsable = false }
        harness.events.send(.didWake)
        harness.change { $0.pathUsable = true }
        XCTAssertEqual(harness.triggers, [.didWake], "the wake attempt covers the path return")
        XCTAssertEqual(harness.pendingCount, 1, "the dropped return still leaves a timer armed")
    }

    func testTheWindowBeforeConnectingStartsIsClosed() {
        // The retry has not set `isConnecting` yet (the biometric path sets it inside a Task).
        let harness = started()
        harness.events.send(.didBecomeActive)
        XCTAssertFalse(harness.snapshot.isConnecting, "precondition: connecting has not started")
        harness.events.send(.didBecomeActive)
        XCTAssertEqual(harness.retries, 1)
    }

    func testALaterTriggerStartsAnotherAttempt() {
        let harness = started()
        harness.events.send(.didBecomeActive)
        harness.clock = harness.clock.addingTimeInterval(MacOfflineRetryMonitor.coalesceWindow + 1)
        harness.events.send(.didBecomeActive)
        XCTAssertEqual(harness.retries, 2)
    }

    func testNoTriggerStartsAnAttemptWhileConnecting() {
        let harness = started()
        harness.change { $0.isConnecting = true }
        harness.events.send(.didBecomeActive)
        harness.events.send(.didWake)
        XCTAssertEqual(harness.retries, 0)
        XCTAssertEqual(harness.pendingCount, 0, "a timer does not run while connecting")
    }

    // MARK: - Path

    func testTheTimerDoesNotRetryWhileThePathIsNotUsable() {
        let harness = started()
        harness.change { $0.pathUsable = false }
        XCTAssertEqual(harness.pendingCount, 0, "the pending timer is cancelled")
        harness.fireTimer()
        XCTAssertEqual(harness.retries, 0)
        harness.fireFirstTimerEvenIfCancelled()
        XCTAssertEqual(harness.retries, 0, "a late timer callback is dropped while the path is down")
    }

    func testATimerThatFiresBeforeThePathChangeNoticeStartsNothing() {
        let harness = started()
        // The app state changed, but the change notice (it hops one main turn) has not reached the monitor yet.
        harness.snapshot.pathUsable = false
        harness.fireTimer()
        XCTAssertEqual(harness.retries, 0, "the timer reads the path itself")
        harness.changes.send()
        XCTAssertEqual(harness.pendingCount, 0, "and nothing is armed while the path is down")
    }

    func testTheTimerRunsAgainOnceThePathIsUsable() {
        let harness = started()
        harness.change { $0.pathUsable = false }
        harness.change { $0.pathUsable = true }
        XCTAssertEqual(harness.retries, 1, "the return starts an attempt")
        XCTAssertEqual(harness.pendingCount, 1, "and arms the next timer")
    }

    // MARK: - Touch ID

    func testNoTimerStaysArmedWhileARestoreWouldPrompt() {
        let harness = RetryHarness()
        harness.wouldPrompt = true
        harness.monitor.start()
        XCTAssertEqual(harness.delays, [], "no poll while the gate is up")
        harness.events.send(.didBecomeActive)
        harness.events.send(.didWake)
        XCTAssertEqual(harness.retries, 0)
        harness.change { $0.pathUsable = false }
        harness.change { $0.pathUsable = true }
        XCTAssertEqual(harness.retries, 0, "a path return is no unlock")
        XCTAssertEqual(harness.pendingCount, 0)
        XCTAssertEqual(harness.delays, [])
    }

    func testAnUnlockRestartsTheAttempts() {
        let harness = RetryHarness()
        harness.wouldPrompt = true
        harness.monitor.start()
        XCTAssertEqual(harness.pendingCount, 0, "precondition")
        // The unlock changes published state (the restore it belongs to sets isConnecting), which reaches evaluate.
        harness.wouldPrompt = false
        harness.changes.send()
        XCTAssertEqual(harness.delays, [5])
        harness.fireTimer()
        XCTAssertEqual(harness.retries, 1)
    }

    func testAGateThatComesUpAfterTheTimerIsArmedEndsItWithoutPolling() {
        let harness = started()
        harness.wouldPrompt = true
        harness.fireTimer()
        XCTAssertEqual(harness.retries, 0)
        XCTAssertEqual(harness.pendingCount, 0, "the blocked timer is not armed again")
        XCTAssertEqual(harness.delays, [5])
    }

    // MARK: - Dashboard

    func testADashboardChangeCancelsThePendingAttempt() {
        let harness = started()
        harness.change { $0.dashboardID = harness.dashboardB }
        XCTAssertEqual(harness.cancelled, 1, "the timer of the old dashboard is cancelled")
        harness.fireFirstTimerEvenIfCancelled()
        XCTAssertEqual(harness.retries, 0, "a late callback of the old timer does nothing")
        XCTAssertEqual(harness.delays, [5, 5], "the new dashboard starts at five seconds")
    }

    func testADashboardChangeResetsTheBackoff() {
        let harness = RetryHarness()
        harness.makeRetryFail()
        harness.monitor.start()
        harness.fireTimer()
        harness.failConnect()
        XCTAssertEqual(harness.delays, [5, 15])
        harness.change { $0.dashboardID = harness.dashboardB }
        XCTAssertEqual(harness.delays, [5, 15, 5])
    }

    func testStopCancelsTheTimerAndIgnoresEvents() {
        let harness = started()
        harness.monitor.stop()
        XCTAssertEqual(harness.pendingCount, 0)
        harness.events.send(.didBecomeActive)
        XCTAssertEqual(harness.retries, 0)
    }
}

/// What the state and the two screens say in the waiting state (D36).
@MainActor
final class MacOfflineRetryPresentationTests: XCTestCase {
    private func makeAppState(connection: Bool = false, savedCopy: Bool = true) throws -> (AppState, SavedDashboard) {
        let suite = HostedTestSupport.makeSuite()
        let defaults = suite.defaults
        addTeardownBlock { @MainActor in HostedTestSupport.dropSuite(suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.showLogin = false
        appState.connection = connection ? HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "ticket") : nil
        if savedCopy {
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
        return (appState, dashboard)
    }

    // MARK: - The waiting predicate

    func testWaitingNeedsTheSavedCopyNoConnectionAndNoSignIn() throws {
        let (appState, _) = try makeAppState()
        XCTAssertNotNil(appState.offlineChatPresentation, "precondition")
        XCTAssertTrue(appState.macIsWaitingForOfflineRetry)

        appState.showLogin = true
        XCTAssertFalse(appState.macIsWaitingForOfflineRetry, "sign-in is on screen")
        appState.showLogin = false

        appState.connection = HermesConnection(baseUrl: "https://one.example", ticket: "t")
        XCTAssertFalse(appState.macIsWaitingForOfflineRetry, "the reconnect path owns a connection")
    }

    func testWaitingNeedsASavedCopy() throws {
        let (appState, _) = try makeAppState(savedCopy: false)
        XCTAssertNil(appState.offlineChatPresentation, "precondition")
        XCTAssertFalse(appState.macIsWaitingForOfflineRetry)
    }

    func testUnreachableIsWaitingWithNothingConnecting() throws {
        let (appState, _) = try makeAppState()
        XCTAssertTrue(appState.macShowsHermesUnreachable)
        appState.isConnecting = true
        XCTAssertTrue(appState.macIsWaitingForOfflineRetry)
        XCTAssertFalse(appState.macShowsHermesUnreachable, "the real loading state stays while connecting")
    }

    // MARK: - Sidebar

    func testSidebarShowsTheFailurePlaceholderInPlaceOfLoading() {
        let unreachable = SessionListPlaceholder.resolve(
            hasRows: false, hasOfflineCopy: false, catalogPhase: .notLoaded, isRefreshing: false,
            hermesUnreachable: true)
        XCTAssertEqual(unreachable, .failed(AppLocalization.string("Can't reach Hermes")))

        let connecting = SessionListPlaceholder.resolve(
            hasRows: false, hasOfflineCopy: false, catalogPhase: .notLoaded, isRefreshing: false,
            hermesUnreachable: false)
        XCTAssertEqual(connecting, .loading)
    }

    func testSidebarKeepsSavedRowsAndAnAnsweredEmptyCatalog() {
        XCTAssertEqual(
            SessionListPlaceholder.resolve(
                hasRows: true, hasOfflineCopy: false, catalogPhase: .notLoaded, isRefreshing: false,
                hermesUnreachable: true),
            .none)
        XCTAssertEqual(
            SessionListPlaceholder.resolve(
                hasRows: false, hasOfflineCopy: false, catalogPhase: .loaded, isRefreshing: false,
                hermesUnreachable: true),
            .empty)
    }

    func testSidebarTryAgainRepairsTheNilConnection() throws {
        let (appState, _) = try makeAppState()
        XCTAssertTrue(appState.macShowsHermesUnreachable, "precondition")
        XCTAssertFalse(appState.showLogin, "precondition")
        appState.macRetrySessionList()
        // The saved-dashboard restore ran: this dashboard has no saved sign-in, so it opens sign-in. A catalog
        // refresh alone would leave this flag unchanged.
        XCTAssertTrue(appState.showLogin, "Try Again re-ran the restore")
    }

    // MARK: - Composer

    func testComposerNoticeHasNoSpinnerAndNoSynchronizingWhenUnreachable() {
        let notice = ComposerBar.stateNoticeContent(turnState: .reconnecting, hermesUnreachable: true)
        XCTAssertFalse(notice.showsProgress)
        XCTAssertEqual(notice.text, AppLocalization.string("Can't reach Hermes"))
    }

    func testComposerNoticeKeepsTheCurrentNoticeOtherwise() {
        let notice = ComposerBar.stateNoticeContent(turnState: .synchronizing, hermesUnreachable: false)
        XCTAssertTrue(notice.showsProgress)
        XCTAssertEqual(notice.text, AppLocalization.string("Synchronizing with Hermes before enabling chat controls"))

        let gateway = ComposerBar.stateNoticeContent(turnState: .unsupportedGateway, hermesUnreachable: false)
        XCTAssertFalse(gateway.showsProgress)
        XCTAssertEqual(gateway.text, AppLocalization.string("Update this Hermes gateway to recover active turns safely."))
    }

    /// The composer redraws only when a `ComposerInputs` value changes. A restore attempt flips `isConnecting`,
    /// which the composer's notice reads through `macShowsHermesUnreachable`.
    func testComposerInputsChangeWhenAnAttemptStartsAndEnds() throws {
        let (appState, _) = try makeAppState()
        XCTAssertTrue(appState.macShowsHermesUnreachable, "precondition: the waiting state")
        let waiting = ComposerInputs(appState)

        appState.isConnecting = true
        XCTAssertNotEqual(waiting, ComposerInputs(appState), "the composer must redraw when an attempt starts")

        appState.isConnecting = false
        XCTAssertEqual(ComposerInputs(appState), waiting, "and again when it ends")
    }

    /// The notice must not depend on other inputs moving with it (the placeholder does today). The inputs carry the
    /// notice's own state, and it follows the attempt.
    func testComposerInputsCarryTheUnreachableState() throws {
        let (appState, _) = try makeAppState()
        XCTAssertTrue(appState.macShowsHermesUnreachable, "precondition: the waiting state")
        XCTAssertEqual(Self.unreachable(in: ComposerInputs(appState)), true, "the waiting state")

        appState.isConnecting = true
        XCTAssertFalse(appState.macShowsHermesUnreachable, "precondition: an attempt is running")
        XCTAssertEqual(Self.unreachable(in: ComposerInputs(appState)), false, "the attempt keeps the loading notice")

        appState.isConnecting = false
        XCTAssertEqual(Self.unreachable(in: ComposerInputs(appState)), true, "the attempt ended")
    }

    /// `hermesUnreachable` of `inputs`, or nil when `ComposerInputs` has no such value. Read by name so that
    /// this test builds, and fails, before the value exists.
    private static func unreachable(in inputs: ComposerInputs) -> Bool? {
        Mirror(reflecting: inputs).children.first { $0.label == "hermesUnreachable" }?.value as? Bool
    }

    // MARK: - Touch ID

    func testRestoreWouldPromptForASavedPasswordThatNeedsBiometricsAndIsNotUnlocked() throws {
        let (appState, dashboard) = try makeAppState()
        XCTAssertFalse(appState.restoreWouldPromptForBiometrics, "no saved password")

        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: dashboard.normalizedURL, username: "u", password: "p", requiresFaceID: false),
            dashboardID: dashboard.id)
        addTeardownBlock { KeychainHelper.clearCredentials(dashboardID: dashboard.id) }
        XCTAssertFalse(appState.restoreWouldPromptForBiometrics, "a password without the gate never prompts")

        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: dashboard.normalizedURL, username: "u", password: "p", requiresFaceID: true),
            dashboardID: dashboard.id)
        XCTAssertTrue(appState.restoreWouldPromptForBiometrics, "the unlock is not held this launch")
    }
}

/// A sign-out ends a restore that the monitor started (D36). `retryFromOfflineChat` re-runs the launch restore at any
/// time, and the restore awaits a ticket: a sign-out in that await must not be undone by the restore's connect.
@MainActor
final class MacOfflineRetrySignOutTests: XCTestCase {
    func testSignOutWhileARestoreWaitsAtItsTicketLeavesNoConnection() async throws {
        let suite = HostedTestSupport.makeSuite()
        let defaults = suite.defaults
        addTeardownBlock { @MainActor in HostedTestSupport.dropSuite(suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        KeychainHelper.saveNativeOAuthTokens(
            NativeOAuthTokenSet(
                accessToken: "access", refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3_600).timeIntervalSince1970,
                provider: "google", userID: "user"),
            dashboardID: dashboard.id)
        addTeardownBlock { KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboard.id) }

        let mintStarted = expectation(description: "the restore waits at the ticket")
        var release: CheckedContinuation<String, Never>?
        var connectCalls = 0
        let lifecycle = ChatResumeLifecycleOperations(
            connectClient: { _ in connectCalls += 1 },
            loadCatalog: { _, _ in [] },
            mintTicket: { _ in
                mintStarted.fulfill()
                return await withCheckedContinuation { release = $0 }
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {})
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: lifecycle,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.offlineChatCacheForTesting.record(
            dashboardID: dashboard.id, profile: "default", sessionID: "saved", title: "Saved",
            messages: [ChatMessage(id: "c1", role: .user, content: "cached", timestamp: "1")], sessions: [])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard.id)
        appState.showLogin = false
        XCTAssertTrue(appState.macShowsHermesUnreachable, "precondition: the waiting state")

        // The monitor's attempt, and the user's sign-out in the middle of it.
        appState.retryFromOfflineChat()
        await fulfillment(of: [mintStarted], timeout: 5)
        appState.signOutDashboard(dashboard.id)
        XCTAssertTrue(appState.showLogin, "precondition: sign-out shows sign-in")

        release?.resume(returning: "late-ticket")
        // Without the fix the restore connects at once, so the wait ends early. With it, the restore returns.
        for _ in 0..<40 where connectCalls == 0 && appState.connection == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(appState.connection, "the restore must not undo the sign-out")
        XCTAssertEqual(connectCalls, 0)
        XCTAssertFalse(appState.isConnected)
        XCTAssertTrue(appState.showLogin, "sign-in stays as sign-out set it")
    }
}
