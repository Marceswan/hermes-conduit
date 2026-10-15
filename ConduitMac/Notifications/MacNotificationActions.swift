import Foundation
import UserNotifications

enum MacNotificationActionID: Equatable { case open, approve, deny, reply }

struct MacNotificationAction: Equatable {
    var id: MacNotificationActionID
    var userText: String?
    var payload: MacNotificationPayload
    var notificationIdentifier: String

    /// The thin, testable half of the delegate: everything it needs from a
    /// `UNNotificationResponse` (which cannot be built in tests) arrives as values.
    static func make(actionIdentifier: String, userText: String?, userInfo: [AnyHashable: Any], notificationIdentifier: String) -> MacNotificationAction? {
        guard let payload = MacNotificationPayload(userInfo: userInfo) else { return nil }
        let id: MacNotificationActionID
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier, MacNotificationCategories.openAction: id = .open
        case MacNotificationCategories.approveAction: id = .approve
        case MacNotificationCategories.denyAction: id = .deny
        case MacNotificationCategories.replyAction: id = .reply
        default: return nil
        }
        return MacNotificationAction(id: id, userText: userText, payload: payload, notificationIdentifier: notificationIdentifier)
    }
}

@MainActor
protocol MacNotificationRouting: AnyObject {
    func route(_ payload: MacNotificationPayload)
}

/// An approval the feed still holds as pending, looked up by its exact item id.
struct MacPendingApproval: Equatable {
    var itemId: String
    var sessionKey: String
    var command: String
    /// `AgentActivityApprovalChoices.allowed(for:)` for this request.
    var allowedChoices: [String]
}

/// A clarify request the feed still holds as pending.
struct MacPendingQuestion: Equatable {
    var itemId: String
    var sessionKey: String
    /// Derived from the feed's item id by the one shared parser, `MacFeedItemID`.
    var requestId: String
    var openQuestionCount: Int
}

/// The single place a feed item id is turned into a request id (the mapper
/// and the gateway both use it), so the two can never parse differently.
enum MacFeedItemID {
    /// `approval:q1` -> `q1`; `clarify:waiting:rt` -> `waiting:rt`.
    static func requestID(_ itemID: String) -> String {
        for prefix in ["approval:", "clarify:", "inputPrompt:"] where itemID.hasPrefix(prefix) {
            return String(itemID.dropFirst(prefix.count))
        }
        return itemID
    }
}

/// The client-level entry the actions use. It addresses sessions by id, so
/// answering never switches the session the user is looking at. Decisions are
/// addressed by the feed's exact item id and validated against the feed first.
@MainActor
protocol MacNotificationGateway: AnyObject {
    var isConnected: Bool { get }
    var activeDashboardID: UUID? { get }
    var activeProfile: String { get }
    /// Exact-id lookup in the feed: an approval item that is pending. Nil when absent or not pending.
    func pendingApproval(itemId: String) -> MacPendingApproval?
    /// Exact-id lookup in the feed: a clarify item that is pending.
    func pendingQuestion(itemId: String) -> MacPendingQuestion?
    /// Forwards to `AgentActivityFeed.respond(to: itemId, choice:)`.
    func respondToApproval(itemId: String, choice: String) async -> AgentActivityRespondResult
    func sendPrompt(sessionId: String, text: String) async throws
    /// False when the request had already expired.
    func answerClarify(requestId: String, answer: String) async throws -> Bool
}

@MainActor
final class MacHermesNotificationGateway: MacNotificationGateway {
    private weak var appState: AppState?
    init(appState: AppState) { self.appState = appState }

    var isConnected: Bool { appState?.isConnected == true && appState?.client != nil }
    var activeDashboardID: UUID? { appState?.activeDashboardID }
    var activeProfile: String { appState?.activeProfile ?? "default" }

    private func client() throws -> HermesClient {
        guard let client = appState?.client, appState?.isConnected == true else { throw HermesError.invalidResponse }
        return client
    }

    /// The feed item with exactly this id (no trimming, no case folding, no prefix rebuilding).
    private func item(_ itemId: String, kind: AgentActivityItem.Kind) -> AgentActivityItem? {
        AgentActivityFeed.shared?.items.first { $0.id == itemId && $0.kind == kind && $0.state == .needsUser }
    }

    private func sessionKey(of item: AgentActivityItem) -> String { item.sessionKey ?? item.sessionId ?? item.id }

    func pendingApproval(itemId: String) -> MacPendingApproval? {
        guard let item = item(itemId, kind: .approval), let approval = item.approval else { return nil }
        return MacPendingApproval(
            itemId: item.id, sessionKey: sessionKey(of: item), command: approval.command,
            allowedChoices: AgentActivityApprovalChoices.allowed(for: approval))
    }

    func pendingQuestion(itemId: String) -> MacPendingQuestion? {
        guard let item = item(itemId, kind: .clarify) else { return nil }
        return MacPendingQuestion(
            itemId: item.id, sessionKey: sessionKey(of: item),
            requestId: MacFeedItemID.requestID(item.id), openQuestionCount: item.openQuestionCount)
    }

    func respondToApproval(itemId: String, choice: String) async -> AgentActivityRespondResult {
        guard let feed = AgentActivityFeed.shared else { return .failed(AgentActivityRespondFailure.notConnected) }
        return await feed.respond(to: itemId, choice: choice)
    }

    func sendPrompt(sessionId: String, text: String) async throws {
        _ = try await client().sendPrompt(sessionId, text: text)
    }

    func answerClarify(requestId: String, answer: String) async throws -> Bool {
        let outcome = try await client().respondToClarification(requestId: requestId, answer: answer, questionId: nil)
        return !outcome.isExpired
    }
}

@MainActor
final class MacNotificationActionHandler {
    private let gateway: MacNotificationGateway
    private let coordinator: MacNotificationCoordinator
    private let router: MacNotificationRouting
    private let removeDelivered: ([String]) -> Void

    init(gateway: MacNotificationGateway, coordinator: MacNotificationCoordinator, router: MacNotificationRouting, removeDelivered: @escaping ([String]) -> Void) {
        self.gateway = gateway
        self.coordinator = coordinator
        self.router = router
        self.removeDelivered = removeDelivered
    }

    func perform(_ action: MacNotificationAction) async {
        switch action.id {
        case .open:
            router.route(action.payload)
            removeDelivered([action.notificationIdentifier])
        case .approve:
            await decide(action, choice: MacApprovalChoiceMapper.approveChoice)
        case .deny:
            await decide(action, choice: MacApprovalChoiceMapper.denyChoice)
        case .reply:
            await reply(action)
        }
    }

    /// Same dashboard and profile as the connected client, and connected.
    private func canAct(on payload: MacNotificationPayload) -> Bool {
        guard gateway.isConnected else { return false }
        if let dashboard = payload.dashboardID, let active = gateway.activeDashboardID, dashboard != active { return false }
        return payload.profile == gateway.activeProfile
    }

    /// An action is trusted only after the feed confirms it: the exact item id
    /// is still a pending approval, for the same session, and the choice is
    /// one the request offers. Anything stale or mismatched is dropped.
    private func decide(_ action: MacNotificationAction, choice: String) async {
        let payload = action.payload
        // Only these two literals can ever leave this method.
        precondition(choice == "once" || choice == "deny")
        guard payload.kind == .approval, let itemId = payload.itemId else { return }
        guard canAct(on: payload) else { coordinator.postNotice(for: payload, reply: false); return }
        guard let pending = gateway.pendingApproval(itemId: itemId) else {
            removeDelivered([action.notificationIdentifier])   // answered or gone: nothing to act on
            return
        }
        guard pending.sessionKey == payload.sessionKey else { return }
        guard pending.allowedChoices.contains(choice) else { return }
        if choice == MacApprovalChoiceMapper.approveChoice, !MacNotificationContent.commandIsFaithful(pending.command) {
            // The banner could not show the whole command; approve it in the app.
            router.route(payload)
            return
        }
        switch await gateway.respondToApproval(itemId: pending.itemId, choice: choice) {
        case .resolved, .alreadyResolved:
            removeDelivered([action.notificationIdentifier])
        case .failed:
            coordinator.postNotice(for: payload, reply: false)
        }
    }

    private func reply(_ action: MacNotificationAction) async {
        let payload = action.payload
        let text = (action.userText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard canAct(on: payload) else { coordinator.postNotice(for: payload, reply: true); return }
        do {
            switch payload.kind {
            case .done:
                try await gateway.sendPrompt(sessionId: payload.sessionId, text: text)
            case .question:
                guard payload.questionCount == 1, let itemId = payload.itemId else { return }
                guard let pending = gateway.pendingQuestion(itemId: itemId) else {
                    removeDelivered([action.notificationIdentifier])
                    return
                }
                guard pending.sessionKey == payload.sessionKey, pending.openQuestionCount == 1 else { return }
                guard try await gateway.answerClarify(requestId: pending.requestId, answer: text) else {
                    coordinator.postNotice(for: payload, reply: true)
                    return
                }
            default:
                return
            }
            removeDelivered([action.notificationIdentifier])
        } catch {
            coordinator.postNotice(for: payload, reply: true)
        }
    }
}
