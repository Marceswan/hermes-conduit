import Foundation
@testable import ConduitMac

/// Drives the reducer with a controllable clock and collects what it emits.
struct AgentActivityHarness {
    var state = AgentActivityState()
    var payloads: [AgentActivityEvent.Payload] = []
    let origin = AgentActivityTestSupport.origin

    @discardableResult
    mutating func send(_ input: AgentActivityInput, at seconds: TimeInterval = 0) -> [AgentActivityEvent.Payload] {
        let output = AgentActivityReducer.reduce(state, input, now: origin.addingTimeInterval(seconds))
        state = output.state
        payloads += output.payloads
        return output.payloads
    }

    @discardableResult
    mutating func stream(_ event: StreamEvent, at seconds: TimeInterval = 0) -> [AgentActivityEvent.Payload] {
        send(.stream(event), at: seconds)
    }

    func item(_ id: String) -> AgentActivityItem? { state.items[id] }

    var turnStarts: [AgentActivityItem] {
        payloads.compactMap { if case .turnStarted(let item) = $0 { return item } else { return nil } }
    }

    var turnFinishes: [(item: AgentActivityItem, outcome: AgentActivityItem.Outcome, preview: String?, gap: Bool)] {
        payloads.compactMap {
            if case .turnFinished(let item, let outcome, let preview, let gap) = $0 { return (item, outcome, preview, gap) }
            return nil
        }
    }

    var requests: [AgentActivityItem] {
        payloads.compactMap { if case .decisionRequested(let item) = $0 { return item } else { return nil } }
    }

    var resolutions: [(id: String, reason: AgentActivityEvent.Reason)] {
        payloads.compactMap { if case .decisionResolved(let id, let reason) = $0 { return (id, reason) } else { return nil } }
    }

    var titleChanges: [(key: String, title: String)] {
        payloads.compactMap { if case .titleChanged(let key, let title) = $0 { return (key, title) } else { return nil } }
    }
}
