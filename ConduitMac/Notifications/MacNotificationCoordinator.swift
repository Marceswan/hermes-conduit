import Foundation
import UserNotifications

@MainActor
final class MacNotificationCoordinator {
    private let center: MacNotificationCenterClient
    private let preferences: MacNotificationPreferences
    private let scheduler: MacNotificationScheduling
    private let visibility: (MacNotificationSession) -> MacNotificationVisibility
    private let now: () -> Date

    // State shared with Task 6 (decisions); kept in this one file.
    private(set) var titles: [String: String] = [:]
    private var turnStarts: [String: Date] = [:]
    private var lastEventID: [String: Int] = [:]
    private var posted = MacNotificationPostedSet()
    private var burst = MacDoneBurstLimiter()
    /// identifier -> session, for everything delivered and not yet removed.
    private var delivered: [String: MacNotificationSession] = [:]
    private var categoriesRegistered = false
    private var chain: Task<Void, Never>?

    init(
        center: MacNotificationCenterClient,
        preferences: MacNotificationPreferences,
        scheduler: MacNotificationScheduling,
        visibility: @escaping (MacNotificationSession) -> MacNotificationVisibility,
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.preferences = preferences
        self.scheduler = scheduler
        self.visibility = visibility
        self.now = now
    }

    // MARK: Entry points

    func handle(_ event: MacNotificationEvent) {
        enqueue { [self] in await process(event) }
    }

    /// Serialises async work so events are processed in arrival order even
    /// when a step awaits (authorization, `add`).
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func drain() async {
        while let current = chain {
            await current.value
            if chain == current { chain = nil; return }
        }
    }

    func languageDidChange() {
        enqueue { [self] in
            await MacNotificationCategories.register(on: center)
            categoriesRegistered = true
        }
    }

    /// Call when attention may have changed (app activation, window key, route
    /// or active session change). Removes what the user is now looking at.
    func recheckAttention() {
        for (identifier, session) in delivered where visibility(session).isAttended {
            center.removeDelivered([identifier])
            center.removePending([identifier])
            delivered[identifier] = nil
        }
        retryHeldDecisions()
    }

    func postNotice(for payload: MacNotificationPayload, reply: Bool) {
        let session = MacNotificationSession(
            sessionId: payload.sessionId, sessionKey: payload.sessionKey, alternateIds: [],
            profile: payload.profile, dashboardID: payload.dashboardID, title: titles[payload.sessionKey] ?? ""
        )
        enqueue { [self] in
            await deliver(.notice, session: session, identifier: nil, suppressible: false) {
                MacNotificationContent.notice(session: session, reply: reply, sound: preferences.soundEnabled)
            }
        }
    }

    // MARK: Processing

    private func process(_ event: MacNotificationEvent) async {
        let key = event.session.sessionKey
        if event.eventId > 0 {
            if let last = lastEventID[key], event.eventId <= last { return }
            lastEventID[key] = event.eventId
        }

        switch event.kind {
        case .sessionTitleChanged(let title):
            titles[key] = title
        case .turnStarted(let turnId, let at):
            turnStarts[turnKey(event.session, turnId)] = at
        case .turnFinished(let turnId, let at, let outcome, let preview, let startedAt, let observedGap):
            await finish(event.session, turnId: turnId, at: at, outcome: outcome, preview: preview, startedAt: startedAt, observedGap: observedGap)
        case .approvalRequested, .questionRequested, .decisionResolved:
            processDecision(event)   // Task 6
        }
    }

    private func turnKey(_ session: MacNotificationSession, _ turnId: String) -> String { "\(session.sessionKey)|\(turnId)" }

    private func finish(_ session: MacNotificationSession, turnId: String, at finishedAt: Date, outcome: MacNotificationEvent.Outcome, preview: String?, startedAt: Date?, observedGap: Bool) async {
        let seenStart = turnStarts.removeValue(forKey: turnKey(session, turnId))
        clearOutstanding(for: session)             // Task 6 hook: the turn is over
        guard outcome != .interrupted, !observedGap, let started = startedAt ?? seenStart else { return }
        guard MacNotificationPolicy.isLongRunning(startedAt: started, finishedAt: finishedAt, threshold: preferences.threshold) else { return }
        guard !toldAlreadyByDecision(session) else { return }        // Task 6 hook
        guard posted.insert(.done, turnId) else { return }
        let kind: MacNotificationKind = outcome == .failed ? .failed : .done
        guard preferences.allows(kind) else { return }
        let sound = preferences.soundEnabled
        // The title can change between the turn event and the post; use the latest.
        var live = session
        live.title = titles[session.sessionKey] ?? session.title
        switch burst.register(at: now()) {
        case .individual:
            await deliver(kind, session: live, identifier: MacNotificationPolicy.ID.done(session.sessionKey)) {
                outcome == .failed
                    ? MacNotificationContent.failed(session: live, turnId: turnId, sound: sound)
                    : MacNotificationContent.done(session: live, turnId: turnId, preview: preview, sound: sound)
            }
        case .summary(let count):
            await deliver(kind, session: session, identifier: MacNotificationPolicy.ID.doneSummary) {
                MacNotificationContent.doneSummary(count: count, sound: sound)
            }
        }
    }

    /// The one place that posts. Suppression is evaluated at post time, before
    /// and again after the authorization await.
    func deliver(
        _ kind: MacNotificationKind, session: MacNotificationSession, identifier: String?, suppressible: Bool = true,
        build: () -> UNNotificationRequest
    ) async {
        guard preferences.allows(kind) else { return }
        let before = visibility(session)
        if suppressible, MacNotificationPolicy.shouldSuppress(before) { return }
        guard await ensureAuthorized(appIsActive: before.appIsActive) else { return }
        if suppressible, MacNotificationPolicy.shouldSuppress(visibility(session)) { return }
        if !categoriesRegistered {
            await MacNotificationCategories.register(on: center)
            categoriesRegistered = true
        }
        let request = build()
        do {
            try await center.add(request)
            delivered[request.identifier] = session
        } catch {
            macNotificationsLogger.error("Notification not posted: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureAuthorized(appIsActive: Bool) async -> Bool {
        switch await center.authorizationStatus() {
        case .authorized, .provisional: return true
        case .notDetermined:
            // The first eligible event while Conduit is inactive asks.
            guard !appIsActive else { return false }
            return await center.requestAuthorization()
        default: return false
        }
    }

    // Task 6 fills these three; Task 5 compiles with the empty versions below.
    private func processDecision(_ event: MacNotificationEvent) {}
    private func clearOutstanding(for session: MacNotificationSession) {}
    private func toldAlreadyByDecision(_ session: MacNotificationSession) -> Bool { false }
    private func retryHeldDecisions() {}
}
