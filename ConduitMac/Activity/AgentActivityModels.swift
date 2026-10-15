import Foundation

/// How much the feed can see right now.
enum AgentActivityAvailability: Equatable {
    /// Connected; stream events and the `session.active_list` poll both work.
    case live
    /// Connected, but the gateway has no `session.active_list`: only sessions on this socket show.
    case eventsOnly
    /// Not connected. Rows clear after a grace period; no events are emitted.
    case offline
}

enum AgentActivityRespondResult: Equatable {
    case resolved
    case alreadyResolved
    case failed(String)
}

/// One row of what the agent is doing or waiting for.
struct AgentActivityItem: Identifiable, Equatable {
    /// `kanban` and `cron` are reserved for the notch plan; the shared base never produces them.
    enum Kind: Equatable { case turn, approval, clarify, inputPrompt, kanban, cron }
    enum Outcome: Equatable { case completed, failed(String), interrupted }
    /// `blocked` is reserved for kanban rows.
    enum State: Equatable { case working, needsUser, finished(Outcome), blocked }

    /// `turn:<runtimeId>`, `approval:<queueId>`, `clarify:<requestId>`, `inputPrompt:<requestId>`;
    /// `approval:waiting:<runtimeId>` and `clarify:waiting:<runtimeId>` are the no-content fallbacks.
    let id: String
    var kind: Kind
    var state: State
    /// Runtime id as the gateway reported it; open via `requestOpenSession`.
    var sessionId: String?
    /// Durable id (catalog id, else stored id, else lineage root, else runtime id).
    var sessionKey: String?
    var profile: String
    var dashboardID: String
    /// Session title from the catalog or a `session.title` event; empty when unknown.
    var title: String
    /// Tool name, approval description or command, first clarify question.
    var detail: String?
    /// When the turn or request began.
    var startedAt: Date
    /// When the current state began (for a finished turn, the finish time).
    var since: Date
    /// Per-session turn counter; with `sessionKey` it is the "one Done per turn" dedupe key.
    var turnSeq: Int
    var approval: ApprovalActivity?
    var isActiveSession: Bool
    /// Seen only in `session.active_list`: no stream events for it, so no tool names.
    var isPollOnly: Bool
    /// The last approval response error, if any.
    var failure: String?
    var openQuestionCount: Int

    init(
        id: String, kind: Kind, state: State,
        sessionId: String? = nil, sessionKey: String? = nil,
        profile: String = "default", dashboardID: String = "none",
        title: String = "", detail: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 0), since: Date = Date(timeIntervalSince1970: 0),
        turnSeq: Int = 0, approval: ApprovalActivity? = nil,
        isActiveSession: Bool = false, isPollOnly: Bool = false,
        failure: String? = nil, openQuestionCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.sessionId = sessionId
        self.sessionKey = sessionKey
        self.profile = profile
        self.dashboardID = dashboardID
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.since = since
        self.turnSeq = turnSeq
        self.approval = approval
        self.isActiveSession = isActiveSession
        self.isPollOnly = isPollOnly
        self.failure = failure
        self.openQuestionCount = openQuestionCount
    }

    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    /// 0 needs the user, 1 working, 2 finished.
    var sortRank: Int {
        switch state {
        case .needsUser, .blocked: return 0
        case .working: return 1
        case .finished: return 2
        }
    }

    /// Needs-user and working oldest first; finished newest first; ties by id.
    static func ordered(_ items: [AgentActivityItem]) -> [AgentActivityItem] {
        items.sorted { a, b in
            if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
            if a.since != b.since { return a.sortRank == 2 ? a.since > b.since : a.since < b.since }
            return a.id < b.id
        }
    }
}

/// Something that happened, delivered after `items` already reflects it.
struct AgentActivityEvent: Equatable {
    enum Reason: Equatable {
        /// Answered through `AgentActivityFeed.respond`.
        case answeredHere
        /// The gateway said `resolved` and this feed did not send the answer (another surface, another Mac).
        case answeredElsewhere
        case expired
        case withdrawn
        case sessionClosed
    }

    enum Payload: Equatable {
        case turnStarted(AgentActivityItem)
        case turnFinished(AgentActivityItem, outcome: AgentActivityItem.Outcome, replyPreview: String?, observedGap: Bool)
        /// Approval, clarify, input prompt.
        case decisionRequested(AgentActivityItem)
        case decisionResolved(id: String, reason: Reason)
        case titleChanged(sessionKey: String, title: String)
    }

    /// Monotonic per feed instance; the consumer dedupe key.
    let eventId: UInt64
    let at: Date
    let payload: Payload
}

/// Which approval answers a request offers. Mirrors `ChatView.allows`:
/// explicit `choices` win, else the default set (smart-denied requests offer
/// only once and deny), and `always` also needs `allowPermanent`.
enum AgentActivityApprovalChoices {
    static let once = "once"
    static let session = "session"
    static let always = "always"
    static let deny = "deny"

    static func allowed(for approval: ApprovalActivity) -> [String] {
        let offered = approval.choices ?? (approval.smartDenied ? [once, deny] : [once, session, always, deny])
        return offered.filter { $0 != always || approval.allowPermanent }
    }

    static func isAllowed(_ choice: String, for approval: ApprovalActivity) -> Bool {
        allowed(for: approval).contains(choice)
    }
}
