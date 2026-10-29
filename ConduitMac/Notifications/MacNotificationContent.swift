import CryptoKit
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
    /// The feed's exact item id (`approval:<id>`, `clarify:<id>`), stored as the
    /// feed produced it. Actions look this exact id up in the feed; ids are never
    /// rebuilt from `requestId` or from any displayed text.
    var itemId: String?
    /// Open questions in a clarify request; Reply exists only for 1.
    var questionCount: Int = 1
    /// SHA-256 of the command the banner showed (approvals only). Approve acts
    /// only while the feed still holds that same command under the item id.
    var commandDigest: String?

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
        if let itemId { routing["item_id"] = itemId }
        if let commandDigest { routing["command_digest"] = commandDigest }
        return [MacNotificationContent.payloadKey: routing]
    }

    init(kind: MacNotificationKind, sessionId: String, sessionKey: String, profile: String, dashboardID: UUID?, requestId: String?, itemId: String? = nil, questionCount: Int = 1, commandDigest: String? = nil) {
        self.kind = kind; self.sessionId = sessionId; self.sessionKey = sessionKey
        self.profile = profile; self.dashboardID = dashboardID; self.requestId = requestId
        self.itemId = itemId
        self.questionCount = questionCount
        self.commandDigest = commandDigest
    }

    init?(userInfo: [AnyHashable: Any]) {
        // Fail closed: a payload that does not name its kind and profile is not
        // ours (or is from another version), and must never default into a
        // kind that can send text or an answer.
        guard let routing = userInfo[MacNotificationContent.payloadKey] as? [String: Any],
              let sessionId = (routing["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty,
              let kind = (routing["kind"] as? String).flatMap(MacNotificationKind.init(rawValue:)),
              let profile = routing["profile"] as? String else { return nil }
        self.kind = kind
        self.sessionId = sessionId
        self.sessionKey = (routing["session_key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionId
        self.profile = profile
        self.dashboardID = (routing["dashboard_id"] as? String).flatMap(UUID.init(uuidString:))
        self.requestId = routing["request_id"] as? String
        self.itemId = routing["item_id"] as? String
        self.commandDigest = routing["command_digest"] as? String
        self.questionCount = (routing["question_count"] as? Int) ?? 1
    }
}

enum MacNotificationContent {
    static let payloadKey = "conduit_mac"
    static let previewLimit = 140
    /// The most of a command the body shows.
    static let commandLimit = 300
    /// Approve is offered inline only for a command up to this long. A banner
    /// clips its body to a few lines, so a longer command could hide its tail
    /// behind the clip; such a command is approved in the app.
    static let inlineApproveLimit = 160
    static let titleLimit = 80

    /// Every agent- or gateway-controlled string goes through here
    /// (`MacUntrustedText`): category-based scalar filtering, whitespace
    /// collapse, a combining-mark cap and a grapheme cap with an ellipsis.
    static func truncated(_ text: String, limit: Int) -> String {
        MacUntrustedText.sanitize(text, maxGraphemes: limit)
    }

    /// The command is short enough to survive the banner's clip, shown in full
    /// and exactly as the gateway sent it (up to edge whitespace). Only then
    /// may a banner offer Approve for it.
    static func commandIsFaithful(_ command: String) -> Bool {
        let shown = truncated(command, limit: inlineApproveLimit)
        return !shown.isEmpty && shown == command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Identifies the exact command a banner showed, for the Approve check.
    static func commandDigest(_ command: String) -> String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func title(for session: MacNotificationSession) -> String {
        let t = truncated(session.title, limit: titleLimit)
        return t.isEmpty ? AppLocalization.string("Conduit") : t
    }

    private static func content(
        session: MacNotificationSession, kind: MacNotificationKind, requestId: String?, itemId: String? = nil, questionCount: Int = 1,
        commandDigest: String? = nil, category: String, body: String, subtitle: String = "", sound: Bool
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
            dashboardID: session.dashboardID, requestId: requestId, itemId: itemId, questionCount: questionCount,
            commandDigest: commandDigest
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

    /// What is being approved comes from the approval payload (command, then
    /// description), never from the session title. The title is fixed; the
    /// session title sits in the subtitle as secondary context. Approve is
    /// offered inline only when the command is shown in full and unaltered.
    static func approval(
        session: MacNotificationSession, requestId: String, description: String, command: String,
        mapping: MacApprovalChoiceMapper.Mapping, itemId: String? = nil, sound: Bool
    ) -> UNNotificationRequest {
        let cmd = truncated(command, limit: commandLimit)
        let desc = truncated(description, limit: previewLimit)
        var effective = mapping
        if !commandIsFaithful(command) { effective.approve = nil }
        let lines = [cmd, desc].filter { !$0.isEmpty }
        let c = content(
            session: session, kind: .approval, requestId: requestId, itemId: itemId, commandDigest: commandDigest(command),
            category: MacNotificationCategories.approvalCategory(for: effective),
            body: lines.joined(separator: "\n"), subtitle: title(for: session), sound: sound
        )
        c.title = AppLocalization.string("Approval needed")
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.approval(requestId), content: c, trigger: nil)
    }

    static func question(session: MacNotificationSession, requestId: String, text: String, openQuestionCount: Int, itemId: String? = nil, sound: Bool) -> UNNotificationRequest {
        let c = content(
            session: session, kind: .question, requestId: requestId, itemId: itemId, questionCount: openQuestionCount,
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
