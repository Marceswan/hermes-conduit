import Foundation
import UserNotifications

/// Conduit's notification categories. `setNotificationCategories` REPLACES the
/// whole set and `HermesCallNotifications.registerCategory` also calls it, so
/// registration reads the current set, drops only Conduit's own identifiers
/// and writes the union back. Re-run on app-language change so the button
/// titles localise.
enum MacNotificationCategories {
    static let done = "CONDUIT_DONE"
    static let open = "CONDUIT_OPEN"
    static let approval = "CONDUIT_APPROVAL"
    static let approvalDenyOnly = "CONDUIT_APPROVAL_DENY"
    static let approvalApproveOnly = "CONDUIT_APPROVAL_APPROVE"
    static let question = "CONDUIT_QUESTION"

    static let openAction = "conduit.action.open"
    static let approveAction = "conduit.action.approve"
    static let denyAction = "conduit.action.deny"
    static let replyAction = "conduit.action.reply"

    static let allIdentifiers: Set<String> = [done, open, approval, approvalDenyOnly, approvalApproveOnly, question]

    static func approvalCategory(for mapping: MacApprovalChoiceMapper.Mapping) -> String {
        switch (mapping.approve != nil, mapping.deny != nil) {
        case (true, true): return approval
        case (false, true): return approvalDenyOnly
        case (true, false): return approvalApproveOnly
        case (false, false): return open
        }
    }

    static func ours() -> Set<UNNotificationCategory> {
        let openButton = UNNotificationAction(identifier: openAction, title: AppLocalization.string("Open"), options: [.foreground])
        let approve = UNNotificationAction(identifier: approveAction, title: AppLocalization.string("Approve"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: AppLocalization.string("Deny"), options: [.authenticationRequired, .destructive])
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: AppLocalization.string("Reply"),
            options: [],
            textInputButtonTitle: AppLocalization.string("Send"),
            textInputPlaceholder: AppLocalization.string("Message")
        )
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        }
        return [
            category(done, [reply, openButton]),
            category(open, [openButton]),
            category(approval, [approve, deny, openButton]),
            category(approvalDenyOnly, [deny, openButton]),
            category(approvalApproveOnly, [approve, openButton]),
            category(question, [reply, openButton]),
        ]
    }

    @MainActor
    static func register(on center: MacNotificationCenterClient) async {
        let existing = await center.categories()
        let foreign = existing.filter { !allIdentifiers.contains($0.identifier) }
        center.setCategories(foreign.union(ours()))
    }
}
