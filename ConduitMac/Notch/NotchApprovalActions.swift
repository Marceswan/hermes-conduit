import Foundation

/// What is being approved, taken from the approval payload only (the gateway's
/// `command` and `description`), sanitized for display. The session title and any
/// reply text are agent-controlled and never stand in for it; the row shows them
/// separately and secondary.
struct NotchApprovalContent: Equatable {
    static let summaryLimit = 120

    /// The payload's description, if any.
    var summary: String?
    /// The payload's command, sanitized and cut at `NotchRowBuilder.commandLimit`.
    var command: String
    /// The displayed text is not the whole, faithful payload (cut short, or invisible or
    /// control characters were dropped, or there is nothing to show). Allow is then not
    /// offered inline: it opens the session, where the full request is on screen.
    var needsReview: Bool

    static func make(_ a: ApprovalActivity) -> NotchApprovalContent {
        let command = MacUntrustedText.sanitize(a.command, limit: NotchRowBuilder.commandLimit)
        let description = MacUntrustedText.sanitize(a.description, limit: summaryLimit)
        let review = command.truncated || command.stripped || command.text.isEmpty
            || description.truncated || description.stripped
        return NotchApprovalContent(
            summary: description.text.isEmpty ? nil : description.text,
            command: command.text, needsReview: review)
    }
}

/// The only things an approval row's buttons can do. Each action maps to a fixed
/// choice string from `AgentActivityApprovalChoices` and a fixed localized label;
/// no label or choice is ever derived from payload text.
enum NotchApprovalAction: Equatable {
    case allowOnce, deny, allowSession, allowAlways
    /// Opens the session instead of answering (used in place of Allow when the command was not shown in full).
    case reviewInConduit

    /// The value sent to `respond(to:choice:)`; nil for `reviewInConduit`.
    var choice: String? {
        switch self {
        case .allowOnce: return AgentActivityApprovalChoices.once
        case .deny: return AgentActivityApprovalChoices.deny
        case .allowSession: return AgentActivityApprovalChoices.session
        case .allowAlways: return AgentActivityApprovalChoices.always
        case .reviewInConduit: return nil
        }
    }

    var label: String {
        switch self {
        case .allowOnce: return AppLocalization.string("Allow once")
        case .deny: return AppLocalization.string("Deny")
        case .allowSession: return AppLocalization.string("Allow for session")
        case .allowAlways: return AppLocalization.string("Always allow")
        case .reviewInConduit: return AppLocalization.string("Review in Conduit")
        }
    }
}

extension NotchApprovalChoices {
    /// The row's buttons. Allow once becomes Review in Conduit when the command was not shown
    /// in full; Deny is always safe and stays.
    func inlineActions(needsReview: Bool) -> [NotchApprovalAction] {
        var out: [NotchApprovalAction] = []
        if once { out.append(needsReview ? .reviewInConduit : .allowOnce) }
        if deny { out.append(.deny) }
        return out
    }

    /// The "more" menu: Allow for session and Always allow, never when the command was not shown in full.
    func menuActions(needsReview: Bool) -> [NotchApprovalAction] {
        guard !needsReview else { return [] }
        var out: [NotchApprovalAction] = []
        if session { out.append(.allowSession) }
        if always { out.append(.allowAlways) }
        return out
    }
}
