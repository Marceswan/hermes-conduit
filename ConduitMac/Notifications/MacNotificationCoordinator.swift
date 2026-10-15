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

    private struct Held { var session: MacNotificationSession; var kind: MacNotificationEvent.Kind }
    /// requestId -> cancel closure of the grace job.
    private var graceJobs: [String: () -> Void] = [:]
    /// Decisions whose grace ended while the user was looking: retried when attention leaves.
    private var held: [String: Held] = [:]
    /// sessionKey -> request ids announced (or pending) during the current turn.
    private var outstanding: [String: Set<String>] = [:]

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
        guard outcome != .interrupted, !observedGap, let started = startedAt ?? seenStart,
              MacNotificationPolicy.isLongRunning(startedAt: started, finishedAt: finishedAt, threshold: preferences.threshold) else {
            outstanding[session.sessionKey] = nil
            return
        }
        guard !toldAlreadyByDecision(session) else { return }
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

    // MARK: Decisions (approvals and questions)

    private func processDecision(_ event: MacNotificationEvent) {
        let session = event.session
        switch event.kind {
        case .approvalRequested(let requestId, _, _, _, _):
            guard posted.insert(.approval, requestId) else { return }
            beginDecision(requestId, session: session, kind: event.kind)
        case .questionRequested(let requestId, _, _):
            guard posted.insert(.question, requestId) else { return }
            beginDecision(requestId, session: session, kind: event.kind)
        case .decisionResolved(let requestId, _):
            graceJobs.removeValue(forKey: requestId)?()
            held[requestId] = nil
            outstanding[session.sessionKey]?.remove(requestId)
            let ids = [MacNotificationPolicy.ID.approval(requestId), MacNotificationPolicy.ID.question(requestId)]
            center.removeDelivered(ids)
            center.removePending(ids)
            for id in ids { delivered[id] = nil }
        default:
            break
        }
    }

    private func beginDecision(_ requestId: String, session: MacNotificationSession, kind: MacNotificationEvent.Kind) {
        outstanding[session.sessionKey, default: []].insert(requestId)
        graceJobs[requestId] = scheduler.schedule(after: MacNotificationPolicy.approvalGrace) { [weak self] in
            guard let self else { return }
            self.graceJobs[requestId] = nil
            self.enqueue { await self.postDecision(requestId, session: session, kind: kind) }
        }
    }

    private func postDecision(_ requestId: String, session: MacNotificationSession, kind: MacNotificationEvent.Kind) async {
        // Resolved while the post waited in the chain.
        guard outstanding[session.sessionKey]?.contains(requestId) == true else { return }
        var live = session
        live.title = titles[session.sessionKey] ?? session.title
        let sound = preferences.soundEnabled
        switch kind {
        case .approvalRequested(_, let description, let command, let choices, _):
            let mapping = MacApprovalChoiceMapper.map(choices: choices)
            let did = await postIfNotAttended(.approval, session: live, identifier: MacNotificationPolicy.ID.approval(requestId)) {
                MacNotificationContent.approval(session: live, requestId: requestId, description: description, command: command, mapping: mapping, sound: sound)
            }
            if !did { held[requestId] = Held(session: session, kind: kind) }
        case .questionRequested(_, let text, let count):
            let did = await postIfNotAttended(.question, session: live, identifier: MacNotificationPolicy.ID.question(requestId)) {
                MacNotificationContent.question(session: live, requestId: requestId, text: text, openQuestionCount: count, sound: sound)
            }
            if !did { held[requestId] = Held(session: session, kind: kind) }
        default:
            break
        }
    }

    /// True when the request was added. False means suppressed, disabled or
    /// unauthorized; only the suppressed case is worth retrying, and
    /// `recheckAttention` retries every held decision cheaply.
    private func postIfNotAttended(_ kind: MacNotificationKind, session: MacNotificationSession, identifier: String, build: () -> UNNotificationRequest) async -> Bool {
        let before = delivered[identifier] != nil
        await deliver(kind, session: session, identifier: identifier, build: build)
        return !before && delivered[identifier] != nil
    }

    /// True when a decision announced during this turn is still outstanding
    /// (that banner already told the user). Clears the turn's outstanding set.
    private func toldAlreadyByDecision(_ session: MacNotificationSession) -> Bool {
        defer { outstanding[session.sessionKey] = nil }
        return outstanding[session.sessionKey]?.isEmpty == false
    }

    private func retryHeldDecisions() {
        for (requestId, entry) in held where !visibility(entry.session).isAttended {
            held[requestId] = nil
            enqueue { [self] in await postDecision(requestId, session: entry.session, kind: entry.kind) }
        }
    }
}
