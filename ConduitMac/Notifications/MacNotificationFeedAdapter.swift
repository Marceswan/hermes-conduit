import Combine
import Foundation

struct MacFeedEventMapper {
    private let alternateIDs: (String) -> [String]
    private var sessions: [String: MacNotificationSession] = [:]

    init(alternateIDs: @escaping (String) -> [String] = { _ in [] }) {
        self.alternateIDs = alternateIDs
    }

    mutating func map(_ event: AgentActivityEvent) -> MacNotificationEvent? {
        let id = Int(clamping: event.eventId)
        switch event.payload {
        case .turnStarted(let item):
            let session = session(for: item)
            return MacNotificationEvent(eventId: id, session: session, kind: .turnStarted(turnId: turnId(item), at: item.startedAt))
        case .turnFinished(let item, let outcome, let preview, let observedGap):
            let session = session(for: item)
            let mapped: MacNotificationEvent.Outcome
            switch outcome {
            case .completed: mapped = .completed
            case .failed: mapped = .failed
            case .interrupted: mapped = .interrupted
            }
            return MacNotificationEvent(eventId: id, session: session, kind: .turnFinished(
                turnId: turnId(item), at: item.since, outcome: mapped, replyPreview: preview,
                startedAt: item.startedAt, observedGap: observedGap))
        case .decisionRequested(let item):
            return decision(item, eventId: id)
        case .decisionResolved(let itemID, let reason):
            let session = sessions.removeValue(forKey: itemID)
                ?? MacNotificationSession(sessionId: "", sessionKey: "", alternateIds: [], profile: "", dashboardID: nil, title: "")
            let mapped: MacNotificationEvent.Resolution
            switch reason {
            case .answeredHere, .answeredElsewhere: mapped = .answered
            case .expired: mapped = .expired
            case .withdrawn: mapped = .withdrawn
            case .sessionClosed: mapped = .sessionClosed
            }
            return MacNotificationEvent(eventId: id, session: session, kind: .decisionResolved(requestId: MacFeedItemID.requestID(itemID), reason: mapped))
        case .titleChanged(let key, let title):
            let session = MacNotificationSession(sessionId: key, sessionKey: key, alternateIds: alternateIDs(key), profile: "", dashboardID: nil, title: title)
            return MacNotificationEvent(eventId: id, session: session, kind: .sessionTitleChanged(title: title))
        }
    }

    /// A pending decision read from `AgentActivityFeed.snapshot()`: unsequenced (`eventId` 0).
    mutating func map(snapshotItem item: AgentActivityItem) -> MacNotificationEvent? {
        guard item.state == .needsUser else { return nil }
        return decision(item, eventId: 0)
    }

    private mutating func decision(_ item: AgentActivityItem, eventId: Int) -> MacNotificationEvent? {
        let session = session(for: item)
        let requestId = MacFeedItemID.requestID(item.id)
        switch item.kind {
        case .approval:
            sessions[item.id] = session
            let approval = item.approval
            return MacNotificationEvent(eventId: eventId, session: session, kind: .approvalRequested(
                requestId: requestId,
                description: approval?.description ?? item.detail ?? "",
                command: approval?.command ?? "",
                choices: approval.map(AgentActivityApprovalChoices.allowed(for:)) ?? [],
                allowPermanent: approval?.allowPermanent ?? false,
                itemId: item.id))
        case .clarify:
            sessions[item.id] = session
            return MacNotificationEvent(eventId: eventId, session: session, kind: .questionRequested(
                requestId: requestId, firstQuestionText: item.detail ?? "", openQuestionCount: item.openQuestionCount,
                itemId: item.id))
        case .turn, .inputPrompt, .kanban, .cron:
            return nil
        }
    }

    private func turnId(_ item: AgentActivityItem) -> String {
        "\(item.sessionKey ?? item.sessionId ?? item.id):\(item.turnSeq)"
    }

    private func session(for item: AgentActivityItem) -> MacNotificationSession {
        let sessionId = item.sessionId ?? item.sessionKey ?? item.id
        let key = item.sessionKey ?? sessionId
        return MacNotificationSession(
            sessionId: sessionId, sessionKey: key, alternateIds: alternateIDs(key), profile: item.profile,
            dashboardID: UUID(uuidString: item.dashboardID), title: item.title)
    }
}

@MainActor
final class MacAgentActivityFeedSource: MacNotificationEventSource {
    private let explicitFeed: AgentActivityFeed?
    private var mapper: MacFeedEventMapper
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(feed: AgentActivityFeed? = nil, alternateIDs: @escaping (String) -> [String] = { _ in [] }) {
        self.explicitFeed = feed
        self.mapper = MacFeedEventMapper(alternateIDs: alternateIDs)
    }

    func start(_ handler: @escaping @MainActor (MacNotificationEvent) -> Void) {
        guard !started, let feed = explicitFeed ?? AgentActivityFeed.shared else { return }
        started = true
        feed.events
            .sink { [weak self] event in
                guard let self, let mapped = mapper.map(event) else { return }
                handler(mapped)
            }
            .store(in: &cancellables)
        // What was already pending (an approval raised before this Mac looked)
        // comes from the snapshot, once the feed's first poll has finished.
        feed.$isBaselined
            .filter { $0 }
            .first()
            .sink { [weak self, weak feed] _ in
                guard let self, let feed else { return }
                for item in feed.snapshot() {
                    if let mapped = mapper.map(snapshotItem: item) { handler(mapped) }
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        started = false
    }
}
