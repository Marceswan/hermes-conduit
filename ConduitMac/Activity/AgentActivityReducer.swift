import Foundation

/// Everything the reducer remembers. A plain value: copy it, compare it, test it.
struct AgentActivityState: Equatable {
    struct Scope: Equatable {
        var profile: String
        var dashboardID: String
    }

    /// Every id one session is known under. Matching is by any of them, the
    /// same rule as `SessionLiveStatusIndex.status(for:)`.
    struct Identity: Equatable {
        var runtimeId: String
        var storedId: String?
        var lineageRootId: String?
        var catalogId: String?
        var alternateIds: Set<String> = []

        var allIds: [String] {
            [runtimeId, storedId, catalogId, lineageRootId].compactMap { $0 } + alternateIds.sorted()
        }
        func matches(_ id: String) -> Bool { allIds.contains(id) }
    }

    /// A poll said `waiting` and no decision content is known yet.
    struct Waiting: Equatable {
        /// Found in the baseline pass: its content is shown but not announced.
        var silent: Bool
        /// The feed has started the `approval.pending` fetch.
        var requested = false
    }

    var scope = Scope(profile: "default", dashboardID: "none")
    var items: [String: AgentActivityItem] = [:]
    /// Keyed by runtime id.
    var identities: [String: Identity] = [:]
    /// Any known id to the latest title.
    var titles: [String: String] = [:]
    /// Item id to consecutive polls that did not show it.
    var misses: [String: Int] = [:]
    /// Runtime id to the last stream event time.
    var lastEventAt: [String: Date] = [:]
    /// Runtime id to a pending-content record.
    var waiting: [String: Waiting] = [:]
    var locallyAnswered: Set<String> = []
    /// True until the first `session.active_list` after start, reconnect or scope reset.
    var baselinePending = true
    /// False when the gateway has no `session.active_list`.
    var pollAuthoritative = true
    var activeSessionId: String?
    var nextTurnSeq = 1
}

enum AgentActivityInput {
    case stream(StreamEvent)
    case activeSession(id: String?)
    case respondStarted(itemId: String)
    case respondFailed(itemId: String, message: String)
    case respondResolved(itemId: String, alreadyResolved: Bool)
    case dismiss(itemId: String)
    case reset(profile: String, dashboardID: String)
    case tick
}

/// `reduce(state, input, now) -> (state, events)`. Pure: no clock, no network, no AppKit.
enum AgentActivityReducer {
    /// Consecutive polls that must omit a working session before its turn finishes.
    static let missesToFinish = 2
    /// New work within this many seconds of a completed finish reopens the same turn.
    static let reopenWindow: TimeInterval = 3
    static let finishedLifetime: TimeInterval = 30
    static let maxFinished = 3
    /// A working turn with no event for this long is dropped when polling is unavailable.
    static let staleSilence: TimeInterval = 600
    /// The gateway blocks a decision for about five minutes; this is the backstop.
    static let decisionMaxAge: TimeInterval = 600
    static let previewLimit = 200

    struct Output {
        var state: AgentActivityState
        var payloads: [AgentActivityEvent.Payload]
    }

    static func reduce(_ state: AgentActivityState, _ input: AgentActivityInput, now: Date) -> Output {
        var engine = Engine(s: state, now: now)
        engine.apply(input)
        return Output(state: engine.s, payloads: engine.out)
    }

    private struct Engine {
        var s: AgentActivityState
        let now: Date
        var out: [AgentActivityEvent.Payload] = []

        enum Source { case stream, poll }

        mutating func apply(_ input: AgentActivityInput) {
            switch input {
            case .stream(let event):
                stream(event)
            case .activeSession(let id):
                s.activeSessionId = id
                for key in Array(s.items.keys) {
                    if let runtime = s.items[key]?.sessionId {
                        let active = isActive(runtime)
                        s.items[key]?.isActiveSession = active
                    }
                }
            case .respondStarted(let itemId):
                guard var item = s.items[itemId] else { return }
                item.failure = nil
                s.items[itemId] = item
                if let request = item.approval?.requestId { s.locallyAnswered.insert(request) }
            case .respondFailed(let itemId, let message):
                guard var item = s.items[itemId] else { return }
                item.failure = message
                s.items[itemId] = item
                if let request = item.approval?.requestId { s.locallyAnswered.remove(request) }
            case .respondResolved(let itemId, let alreadyResolved):
                resolve(itemId, alreadyResolved ? .answeredElsewhere : .answeredHere)
            case .dismiss(let itemId):
                if let item = s.items[itemId], item.isFinished { s.items[itemId] = nil }
            case .reset(let profile, let dashboardID):
                var fresh = AgentActivityState()
                fresh.scope = .init(profile: profile, dashboardID: dashboardID)
                fresh.nextTurnSeq = s.nextTurnSeq
                fresh.activeSessionId = s.activeSessionId
                s = fresh
            case .tick:
                tick()
            }
        }

        // MARK: Identity

        mutating func ensureIdentity(_ runtime: String, stored: String? = nil) {
            var identity = s.identities[runtime] ?? AgentActivityState.Identity(runtimeId: runtime)
            if let stored, !stored.isEmpty { identity.storedId = stored }
            s.identities[runtime] = identity
            refreshKeys(runtime)
        }

        /// The canonical runtime id for any id the session is known under.
        mutating func runtimeID(for id: String) -> String {
            if s.identities[id] != nil { return id }
            if let hit = s.identities.values.first(where: { $0.matches(id) }) { return hit.runtimeId }
            ensureIdentity(id)
            return id
        }

        func sessionKey(_ runtime: String) -> String {
            let identity = s.identities[runtime]
            return identity?.catalogId ?? identity?.storedId ?? identity?.lineageRootId ?? runtime
        }

        func title(_ runtime: String) -> String {
            for id in s.identities[runtime]?.allIds ?? [runtime] {
                if let title = s.titles[id] { return title }
            }
            return ""
        }

        func isActive(_ runtime: String) -> Bool {
            guard let active = s.activeSessionId else { return false }
            return s.identities[runtime]?.matches(active) ?? (active == runtime)
        }

        mutating func refreshKeys(_ runtime: String) {
            let key = sessionKey(runtime)
            for id in Array(s.items.keys) where s.items[id]?.sessionId == runtime {
                s.items[id]?.sessionKey = key
            }
        }

        mutating func touch(_ runtime: String) {
            s.lastEventAt[runtime] = now
            if var turn = s.items["turn:\(runtime)"], turn.isPollOnly {
                turn.isPollOnly = false
                s.items["turn:\(runtime)"] = turn
            }
        }

        func baseItem(id: String, kind: AgentActivityItem.Kind, state: AgentActivityItem.State, runtime: String) -> AgentActivityItem {
            AgentActivityItem(
                id: id, kind: kind, state: state, sessionId: runtime, sessionKey: sessionKey(runtime),
                profile: s.scope.profile, dashboardID: s.scope.dashboardID, title: title(runtime),
                startedAt: now, since: now, isActiveSession: isActive(runtime))
        }

        // MARK: Turns

        mutating func ensureWorkingTurn(_ runtime: String, source: Source, announce: Bool) {
            let id = "turn:\(runtime)"
            if var existing = s.items[id] {
                switch existing.state {
                case .working, .needsUser, .blocked:
                    return
                case .finished(let outcome):
                    let recent = now.timeIntervalSince(existing.since) <= AgentActivityReducer.reopenWindow
                    if source == .poll, recent { return }   // a stale poll must not resurrect a finished turn
                    if source == .stream, recent, outcome == .completed {
                        existing.state = .working
                        existing.since = now
                        existing.detail = nil
                        s.items[id] = existing
                        s.misses[id] = 0
                        return
                    }
                }
            }
            var item = baseItem(id: id, kind: .turn, state: .working, runtime: runtime)
            item.turnSeq = s.nextTurnSeq
            s.nextTurnSeq += 1
            item.isPollOnly = source == .poll && s.lastEventAt[runtime] == nil
            s.items[id] = item
            s.misses[id] = 0
            if announce { out.append(.turnStarted(item)) }
        }

        mutating func finish(_ runtime: String, outcome: AgentActivityItem.Outcome, preview: String?, observedGap: Bool = false) {
            let id = "turn:\(runtime)"
            guard var item = s.items[id], item.state == .working else { return }
            item.state = .finished(outcome)
            item.since = now
            item.detail = nil
            s.items[id] = item
            s.misses[id] = nil
            out.append(.turnFinished(item, outcome: outcome, replyPreview: preview, observedGap: observedGap))
        }

        static func preview(_ content: String?) -> String? {
            guard let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed.count <= AgentActivityReducer.previewLimit
                ? trimmed : String(trimmed.prefix(AgentActivityReducer.previewLimit))
        }

        // MARK: Decisions

        mutating func decision(
            id: String, kind: AgentActivityItem.Kind, runtime: String,
            detail: String?, approval: ApprovalActivity? = nil, questions: Int = 0
        ) -> AgentActivityItem {
            var item = baseItem(id: id, kind: kind, state: .needsUser, runtime: runtime)
            item.detail = detail
            item.approval = approval
            item.openQuestionCount = questions
            if let existing = s.items[id] {
                item.startedAt = existing.startedAt
                item.since = existing.since
                item.failure = existing.failure
            }
            return item
        }

        mutating func addDecision(_ item: AgentActivityItem, announce: Bool) {
            let isNew = s.items[item.id] == nil
            s.items[item.id] = item
            s.misses[item.id] = 0
            if isNew && announce { out.append(.decisionRequested(item)) }
        }

        mutating func resolve(_ id: String, _ reason: AgentActivityEvent.Reason) {
            guard s.items.removeValue(forKey: id) != nil else { return }
            s.misses[id] = nil
            out.append(.decisionResolved(id: id, reason: reason))
        }

        mutating func removeFallbacks(_ runtime: String) {
            resolve("approval:waiting:\(runtime)", .withdrawn)
            resolve("clarify:waiting:\(runtime)", .withdrawn)
        }

        func reason(forCancel raw: String?, requestId: String) -> AgentActivityEvent.Reason {
            switch raw?.lowercased() {
            case "resolved"?: return s.locallyAnswered.contains(requestId) ? .answeredHere : .answeredElsewhere
            case nil, "timeout"?: return .expired
            case "session_closed"?: return .sessionClosed
            default: return .withdrawn
            }
        }

        // MARK: Stream events

        mutating func stream(_ event: StreamEvent) {
            switch event {
            case .messageStart(let sid):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                s.items["turn:\(runtime)"]?.detail = nil

            case .messageDelta(let sid, _), .reasoningDelta(let sid, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)

            case .toolStart(let sid, let toolName, _, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                s.items["turn:\(runtime)"]?.detail = toolName

            case .toolComplete(let sid, let toolName, _, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                if s.items["turn:\(runtime)"]?.detail == toolName { s.items["turn:\(runtime)"]?.detail = nil }

            case .sessionBusy(let sid, let busy):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                if busy {
                    ensureWorkingTurn(runtime, source: .stream, announce: true)
                } else {
                    finish(runtime, outcome: .completed, preview: nil)
                }

            case .messageComplete(let sid, _, let content, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                finish(runtime, outcome: .completed, preview: Self.preview(content))

            case .messageError(let sid, let message):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                finish(runtime, outcome: .failed(message), preview: nil)

            case .messageInterrupted(let sid):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                finish(runtime, outcome: .interrupted, preview: nil)

            case .approval(let sid, let activity):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                removeFallbacks(runtime)
                s.waiting[runtime] = nil
                let id = activity.requestId.map { "approval:\($0)" } ?? "approval:legacy:\(runtime)"
                let detail = activity.description.isEmpty ? activity.command : activity.description
                addDecision(decision(id: id, kind: .approval, runtime: runtime, detail: detail, approval: activity), announce: true)

            case .approvalWithdrawn(let sid, let requestId, let raw):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                resolve("approval:\(requestId)", reason(forCancel: raw, requestId: requestId))

            case .clarify(let sid, let activity):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                let id = "clarify:\(activity.requestId)"
                if activity.isExpired { resolve(id, .expired); break }
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                removeFallbacks(runtime)
                s.waiting[runtime] = nil
                let open = activity.questions.filter(\.isAnswerable)
                let first = (open.first ?? activity.questions.first)?.question
                addDecision(decision(id: id, kind: .clarify, runtime: runtime, detail: first, questions: open.count), announce: true)

            case .clarifyExpire(let sid, let requestId, let raw):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                resolve("clarify:\(requestId)", reason(forCancel: raw, requestId: requestId))

            case .inputPrompt(let sid, let activity):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                removeFallbacks(runtime)
                s.waiting[runtime] = nil
                addDecision(decision(id: "inputPrompt:\(activity.requestId)", kind: .inputPrompt, runtime: runtime, detail: nil), announce: true)

            case .inputPromptExpire(let sid, let requestId, let raw):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                resolve("inputPrompt:\(requestId)", reason(forCancel: raw, requestId: requestId))

            case .sessionTitle(let runtimeId, let stored, let title):
                ensureIdentity(runtimeId, stored: stored)
                let changed = s.titles[runtimeId] != title
                s.titles[runtimeId] = title
                if !stored.isEmpty { s.titles[stored] = title }
                for id in Array(s.items.keys) where s.items[id]?.sessionId == runtimeId { s.items[id]?.title = title }
                if changed { out.append(.titleChanged(sessionKey: sessionKey(runtimeId), title: title)) }

            default:
                break
            }
        }

        // MARK: Tick

        mutating func tick() {
            let finished = s.items.values.filter(\.isFinished).sorted { $0.since > $1.since }
            for (index, item) in finished.enumerated()
            where index >= AgentActivityReducer.maxFinished
                || now.timeIntervalSince(item.since) >= AgentActivityReducer.finishedLifetime {
                s.items[item.id] = nil
            }
            for item in Array(s.items.values) {
                switch item.state {
                case .needsUser:
                    if now.timeIntervalSince(item.since) >= AgentActivityReducer.decisionMaxAge { resolve(item.id, .expired) }
                case .working:
                    guard !s.pollAuthoritative else { continue }
                    let last = s.lastEventAt[item.sessionId ?? ""] ?? item.since
                    if now.timeIntervalSince(last) >= AgentActivityReducer.staleSilence { s.items[item.id] = nil }
                default:
                    break
                }
            }
        }
    }
}
