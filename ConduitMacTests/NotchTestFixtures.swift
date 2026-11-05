import Foundation
@testable import ConduitMac

enum NotchFixtures {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func item(
        _ id: String, kind: AgentActivityItem.Kind = .turn, state: AgentActivityItem.State = .working,
        session: String? = nil, title: String = "Chat", detail: String? = nil,
        since: Date = t0, approval: ApprovalActivity? = nil
    ) -> AgentActivityItem {
        AgentActivityItem(
            id: id, kind: kind, state: state, sessionId: session ?? id, sessionKey: session ?? id,
            profile: "default", dashboardID: "d", title: title, detail: detail,
            startedAt: since, since: since, approval: approval, isActiveSession: false)
    }

    static func approval(
        command: String = "ls", choices: [String]? = nil, allowPermanent: Bool = true, smartDenied: Bool = false
    ) -> ApprovalActivity {
        ApprovalActivity(sessionId: "s", requestId: "r1", command: command, description: "d",
                         choices: choices, allowPermanent: allowPermanent, smartDenied: smartDenied,
                         status: .pending)
    }

    static func approvalItem(_ id: String, session: String, approval: ApprovalActivity? = approval()) -> AgentActivityItem {
        item(id, kind: .approval, state: .needsUser, session: session, title: "Deploy", approval: approval)
    }
}
