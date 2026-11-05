import Foundation
@testable import ConduitMac

enum AgentActivityTestSupport {
    static let origin = Date(timeIntervalSince1970: 1_000_000)

    static func item(
        _ id: String,
        kind: AgentActivityItem.Kind = .turn,
        state: AgentActivityItem.State = .working,
        since seconds: TimeInterval = 0,
        sessionId: String? = nil
    ) -> AgentActivityItem {
        AgentActivityItem(
            id: id, kind: kind, state: state, sessionId: sessionId,
            startedAt: origin.addingTimeInterval(seconds), since: origin.addingTimeInterval(seconds))
    }

    static func approval(
        session: String = "s1",
        request: String? = "q1",
        command: String = "rm -rf build",
        description: String = "Delete build output",
        choices: [String]? = nil,
        allowPermanent: Bool = true,
        smartDenied: Bool = false
    ) -> ApprovalActivity {
        ApprovalActivity(
            sessionId: session, requestId: request, command: command, description: description,
            choices: choices, allowPermanent: allowPermanent, smartDenied: smartDenied, status: .pending)
    }

    static func summary(
        id: String, stored: String? = nil, alternates: [String] = [],
        title: String, lineage: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: stored, alternateIds: alternates, title: title, model: "",
            updatedLabel: "", profile: "default", source: .chat, isActive: false,
            isArchived: false, lineageRootId: lineage)
    }

    static func row(_ runtime: String, stored: String = "", _ status: String) -> LiveSessionStatus {
        LiveSessionStatus(runtimeSessionId: runtime, storedSessionId: stored, status: status)
    }
}
