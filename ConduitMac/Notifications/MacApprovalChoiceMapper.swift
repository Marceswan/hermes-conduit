import Foundation

/// Which approval choices a notification may carry. Pure; the gateway's
/// choices are `once`, `session`, `always`, `deny`, built per request.
enum MacApprovalChoiceMapper {
    static let approveChoice = "once"
    static let denyChoice = "deny"

    struct Mapping: Equatable {
        var approve: String?
        var deny: String?
        var isEmpty: Bool { approve == nil && deny == nil }
    }

    static func map(choices: [String]?) -> Mapping {
        // nil: a gateway older than the choices field. The approval card
        // treats it as the full default set, so Approve and Deny are valid.
        guard let choices else { return Mapping(approve: approveChoice, deny: denyChoice) }
        return Mapping(
            approve: choices.contains(approveChoice) ? approveChoice : nil,
            deny: choices.contains(denyChoice) ? denyChoice : nil
        )
    }
}
