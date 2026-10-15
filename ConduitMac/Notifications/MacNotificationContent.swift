import Foundation
import UserNotifications

/// What a notification's tap, button or reply needs to find its session.
/// Lives in `userInfo["conduit_mac"]`; carries ids only, never message text.
struct MacNotificationPayload: Equatable {
    var kind: MacNotificationKind
    var sessionId: String
    var sessionKey: String
    var profile: String
    var dashboardID: UUID?
    var requestId: String?
    /// Open questions in a clarify request; Reply exists only for 1.
    var questionCount: Int = 1

    var userInfo: [AnyHashable: Any] {
        var routing: [String: Any] = [
            "kind": kind.rawValue,
            "session_id": sessionId,
            "session_key": sessionKey,
            "profile": profile,
            "question_count": questionCount,
        ]
        if let dashboardID { routing["dashboard_id"] = dashboardID.uuidString }
        if let requestId { routing["request_id"] = requestId }
        return [MacNotificationContent.payloadKey: routing]
    }

    init(kind: MacNotificationKind, sessionId: String, sessionKey: String, profile: String, dashboardID: UUID?, requestId: String?, questionCount: Int = 1) {
        self.kind = kind; self.sessionId = sessionId; self.sessionKey = sessionKey
        self.profile = profile; self.dashboardID = dashboardID; self.requestId = requestId
        self.questionCount = questionCount
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let routing = userInfo[MacNotificationContent.payloadKey] as? [String: Any],
              let sessionId = (routing["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else { return nil }
        self.kind = (routing["kind"] as? String).flatMap(MacNotificationKind.init(rawValue:)) ?? .done
        self.sessionId = sessionId
        self.sessionKey = (routing["session_key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionId
        self.profile = (routing["profile"] as? String) ?? "default"
        self.dashboardID = (routing["dashboard_id"] as? String).flatMap(UUID.init(uuidString:))
        self.requestId = routing["request_id"] as? String
        self.questionCount = (routing["question_count"] as? Int) ?? 1
    }
}

enum MacNotificationContent {
    static let payloadKey = "conduit_mac"
    static let previewLimit = 140
    static let commandLimit = 80

    /// Whitespace collapsed to single spaces, cut to `limit` characters with an ellipsis.
    static func truncated(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "\u{2026}"
    }

    private static func title(for session: MacNotificationSession) -> String {
        let t = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? AppLocalization.string("Conduit") : t
    }

    private static func content(
        session: MacNotificationSession, kind: MacNotificationKind, requestId: String?, questionCount: Int = 1,
        category: String, body: String, subtitle: String = "", sound: Bool
    ) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title(for: session)
        c.subtitle = subtitle
        c.body = body
        c.categoryIdentifier = category
        c.threadIdentifier = MacNotificationPolicy.ID.thread(session.sessionKey)
        c.interruptionLevel = .active
        if sound { c.sound = .default }
        c.userInfo = MacNotificationPayload(
            kind: kind, sessionId: session.sessionId, sessionKey: session.sessionKey, profile: session.profile,
            dashboardID: session.dashboardID, requestId: requestId, questionCount: questionCount
        ).userInfo
        return c
    }

    static func done(session: MacNotificationSession, turnId: String, preview: String?, sound: Bool) -> UNNotificationRequest {
        let text = truncated(preview ?? "", limit: previewLimit)
        let c = content(session: session, kind: .done, requestId: nil, category: MacNotificationCategories.done,
                        body: text.isEmpty ? AppLocalization.string("Finished") : text, sound: sound)
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.done(session.sessionKey), content: c, trigger: nil)
    }

    static func failed(session: MacNotificationSession, turnId: String, sound: Bool) -> UNNotificationRequest {
        let c = content(session: session, kind: .failed, requestId: nil, category: MacNotificationCategories.open,
                        body: AppLocalization.string("Stopped with an error"), sound: sound)
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.done(session.sessionKey), content: c, trigger: nil)
    }

    static func doneSummary(count finishedCount: Int, sound: Bool) -> UNNotificationRequest {
        let c = UNMutableNotificationContent()
        c.title = AppLocalization.string("\(finishedCount) conversations finished")
        c.categoryIdentifier = MacNotificationCategories.open
        c.interruptionLevel = .active
        if sound { c.sound = .default }
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.doneSummary, content: c, trigger: nil)
    }

    static func approval(
        session: MacNotificationSession, requestId: String, description: String, command: String,
        mapping: MacApprovalChoiceMapper.Mapping, sound: Bool
    ) -> UNNotificationRequest {
        let desc = truncated(description, limit: previewLimit)
        let cmd = truncated(command, limit: commandLimit)
        let c = content(
            session: session, kind: .approval, requestId: requestId,
            category: MacNotificationCategories.approvalCategory(for: mapping),
            body: desc.isEmpty ? cmd : desc, subtitle: desc.isEmpty ? "" : cmd, sound: sound
        )
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.approval(requestId), content: c, trigger: nil)
    }

    static func question(session: MacNotificationSession, requestId: String, text: String, openQuestionCount: Int, sound: Bool) -> UNNotificationRequest {
        let c = content(
            session: session, kind: .question, requestId: requestId, questionCount: openQuestionCount,
            category: openQuestionCount == 1 ? MacNotificationCategories.question : MacNotificationCategories.open,
            body: truncated(text, limit: previewLimit), sound: sound
        )
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.question(requestId), content: c, trigger: nil)
    }

    /// "Couldn't send" after a failed action. `reply` picks the wording.
    static func notice(session: MacNotificationSession, reply: Bool, sound: Bool) -> UNNotificationRequest {
        let body = reply
            ? AppLocalization.string("Couldn't send your reply. Open Conduit.")
            : AppLocalization.string("Couldn't send your answer. Open Conduit.")
        let c = content(session: session, kind: .notice, requestId: nil, category: MacNotificationCategories.open, body: body, sound: sound)
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.notice(UUID()), content: c, trigger: nil)
    }
}
