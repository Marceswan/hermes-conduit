import AppKit
import Combine
import Foundation
import os

private let offlineRetryLog = Logger(subsystem: "com.milim.relay", category: "OfflineRetry")

/// Retries a launch restore that failed with no connection (D36).
///
/// The waiting state is: the saved copy is on screen, there is no connection, and sign-in is not showing. Nothing
/// else repairs it. The path handler and the reconnect timer both need a connection, and the one automatic retry
/// (`handleScenePhase(.active)`) may not run when the Mac brings the app to the front.
///
/// The monitor retries with `AppState.retryFromOfflineChat()` only. It adds no connect path of its own.
/// - Timer: 5 s, 15 s, 30 s, then 60 s for each later attempt. The position survives the attempt's own connecting
///   transitions. It resets when the waiting state ends or the active dashboard changes.
/// - Events: the app becoming active, the Mac waking, and the network path returning each start one attempt at once.
/// - No timer attempt runs while the network path is not usable.
/// - Triggers close together start one attempt (`coalesceWindow`).
/// - A restore that would ask for Touch ID is never started here.
@MainActor
final class MacOfflineRetryMonitor {
    enum Trigger: String, Equatable {
        case timer
        case didBecomeActive
        case didWake
        case networkReturned
    }

    struct Snapshot: Equatable {
        /// `AppState.macIsWaitingForOfflineRetry`.
        var waiting: Bool
        var isConnecting: Bool
        /// `AppState.networkPathUsable`, fed by the app's one `DeviceConditionsMonitor`.
        var pathUsable: Bool
        var dashboardID: UUID?
    }

    struct Seams {
        var snapshot: @MainActor () -> Snapshot
        /// True when a restore now would ask for Touch ID.
        var restoreWouldPrompt: @MainActor () -> Bool
        var retry: @MainActor (Trigger) -> Void
        var now: @MainActor () -> Date
        /// Runs `fire` after `delay`. The result cancels it.
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
        /// Fires after any input of `snapshot` may have changed. Must deliver after the change has landed.
        var changes: AnyPublisher<Void, Never>
        var events: AnyPublisher<Trigger, Never>
    }

    /// Seconds before the next attempt, by the number of attempts made so far in this waiting state.
    static let delays: [TimeInterval] = [5, 15, 30, 60]

    /// Two triggers closer than this start one attempt. It covers the gap before `isConnecting` is set: the
    /// restore sets it inside a Task for the biometric path.
    static let coalesceWindow: TimeInterval = 3

    static func delay(afterAttempts attempts: Int) -> TimeInterval {
        delays[min(max(attempts, 0), delays.count - 1)]
    }

    private struct Tracked {
        var dashboardID: UUID?
        var attempts = 0
    }

    private let seams: Seams
    private var bindings: Set<AnyCancellable> = []
    private var tracked: Tracked?
    private var cancelTimer: (() -> Void)?
    private var timerToken = 0
    private var lastAttemptAt: Date?
    private var lastPathUsable = true

    init(seams: Seams) {
        self.seams = seams
    }

    var isRunning: Bool { !bindings.isEmpty }

    func start() {
        guard bindings.isEmpty else { return }
        lastPathUsable = seams.snapshot().pathUsable
        seams.changes
            .sink { [weak self] in self?.evaluate() }
            .store(in: &bindings)
        seams.events
            .sink { [weak self] trigger in self?.attempt(trigger, delay: 0) }
            .store(in: &bindings)
        evaluate()
    }

    func stop() {
        bindings.removeAll()
        endWait()
    }

    // MARK: - State

    private func evaluate() {
        let snap = seams.snapshot()
        let pathReturned = !lastPathUsable && snap.pathUsable
        lastPathUsable = snap.pathUsable
        // Connecting without the waiting predicate (the saved-ticket path sets a connection) is still the same
        // waiting state: the backoff position stays.
        guard snap.waiting || (snap.isConnecting && tracked != nil) else {
            endWait()
            return
        }
        track(snap)
        if snap.isConnecting || !snap.pathUsable || !snap.waiting { cancelPending() }
        if pathReturned, snap.waiting, !snap.isConnecting {
            attempt(.networkReturned, delay: 0)
            return
        }
        scheduleIfIdle(snap)
    }

    /// Starts tracking, or restarts it when the active dashboard changed: the pending attempt was for the old one.
    private func track(_ snap: Snapshot) {
        if let tracked, tracked.dashboardID == snap.dashboardID { return }
        cancelPending()
        lastAttemptAt = nil
        tracked = Tracked(dashboardID: snap.dashboardID)
    }

    private func endWait() {
        cancelPending()
        tracked = nil
        lastAttemptAt = nil
    }

    private func cancelPending() {
        timerToken &+= 1
        cancelTimer?()
        cancelTimer = nil
    }

    private func scheduleIfIdle(_ snap: Snapshot) {
        guard cancelTimer == nil, snap.waiting, !snap.isConnecting, snap.pathUsable, let tracked else { return }
        let delay = Self.delay(afterAttempts: tracked.attempts)
        let dashboardID = tracked.dashboardID
        timerToken &+= 1
        let token = timerToken
        cancelTimer = seams.schedule(delay) { [weak self] in
            guard let self, self.timerToken == token else { return }
            self.cancelTimer = nil
            // The dashboard may have changed before the change notice reached `evaluate`.
            guard self.seams.snapshot().dashboardID == dashboardID else {
                self.evaluate()
                return
            }
            self.attempt(.timer, delay: delay)
        }
    }

    // MARK: - Attempts

    private func attempt(_ trigger: Trigger, delay: TimeInterval) {
        let snap = seams.snapshot()
        let isTimer = trigger == .timer
        guard snap.waiting, !snap.isConnecting else { return }
        track(snap)
        // A blocked timer attempt keeps polling at the same delay, with no backoff step.
        func blocked() {
            if isTimer { evaluate() }
        }
        if isTimer, !snap.pathUsable { return }
        if seams.restoreWouldPrompt() { return blocked() }
        let now = seams.now()
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.coalesceWindow { return blocked() }

        lastAttemptAt = now
        tracked?.attempts += 1
        cancelPending()
        offlineRetryLog.notice(
            "Attempt \(self.tracked?.attempts ?? 0, privacy: .public): trigger \(trigger.rawValue, privacy: .public), delay \(delay, privacy: .public) s")
        seams.retry(trigger)
        evaluate()
    }
}

// MARK: - Live sources

extension MacOfflineRetryMonitor.Seams {
    @MainActor
    static func live(appState: AppState) -> Self {
        // @Published emits in willSet: the main-queue hop lets the change land before `snapshot` reads it.
        let changes = Publishers.MergeMany([
            appState.$offlineChatPresentation.map { _ in () }.eraseToAnyPublisher(),
            appState.$connection.map { _ in () }.eraseToAnyPublisher(),
            appState.$showLogin.map { _ in () }.eraseToAnyPublisher(),
            appState.$isConnecting.map { _ in () }.eraseToAnyPublisher(),
            appState.$networkPathUsable.map { _ in () }.eraseToAnyPublisher(),
            appState.$savedDashboardRegistry.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()

        let active = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .map { _ in MacOfflineRetryMonitor.Trigger.didBecomeActive }
        let wake = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .map { _ in MacOfflineRetryMonitor.Trigger.didWake }
        let events = active.merge(with: wake)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()

        return Self(
            snapshot: {
                MacOfflineRetryMonitor.Snapshot(
                    waiting: appState.macIsWaitingForOfflineRetry,
                    isConnecting: appState.isConnecting,
                    pathUsable: appState.networkPathUsable,
                    dashboardID: appState.activeDashboardID)
            },
            restoreWouldPrompt: { appState.restoreWouldPromptForBiometrics },
            retry: { _ in appState.retryFromOfflineChat() },
            now: { Date() },
            schedule: { delay, fire in
                let task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    fire()
                }
                return { task.cancel() }
            },
            changes: changes,
            events: events)
    }
}

/// Starts the monitor at launch, from the app delegate rather than a window. Mirrors `MacBackgroundActivityBootstrap`.
@MainActor
enum MacOfflineRetryBootstrap {
    private(set) static var monitor: MacOfflineRetryMonitor?

    static func start(appState: AppState? = nil) {
        guard monitor == nil else { return }
        let monitor = MacOfflineRetryMonitor(
            seams: .live(appState: appState ?? AppStateRuntimeRegistry.shared.appState))
        monitor.start()
        self.monitor = monitor
    }

    static func stop() {
        monitor?.stop()
        monitor = nil
    }
}

// MARK: - What the screens read

extension AppState {
    /// The launch restore failed with the server unreachable: the saved copy is up, there is no connection, and
    /// sign-in is not showing. Only a new restore repairs this state.
    var macIsWaitingForOfflineRetry: Bool {
        offlineChatPresentation != nil && connection == nil && !showLogin
    }

    /// The waiting state with no attempt running. The sidebar and the composer say so, with no spinner.
    var macShowsHermesUnreachable: Bool {
        macIsWaitingForOfflineRetry && !isConnecting
    }

    /// Try Again in the Chats list. A catalog refresh cannot repair a nil connection, so the waiting state re-runs
    /// the restore.
    func macRetrySessionList() {
        if macShowsHermesUnreachable {
            retryFromOfflineChat()
        } else {
            Task { await refreshSessionCatalog() }
        }
    }
}
