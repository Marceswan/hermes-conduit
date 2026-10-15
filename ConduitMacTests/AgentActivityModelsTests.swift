import XCTest
@testable import ConduitMac

final class AgentActivityModelsTests: XCTestCase {
    private func item(_ id: String, _ state: AgentActivityItem.State, since: TimeInterval) -> AgentActivityItem {
        AgentActivityTestSupport.item(id, state: state, since: since)
    }

    func testOrderingNeedsUserThenWorkingOldestFirstThenFinishedNewestFirst() {
        let ordered = AgentActivityItem.ordered([
            item("f3", .finished(.completed), since: 3),
            item("w1", .working, since: 1),
            item("n5", .needsUser, since: 5),
            item("f9", .finished(.failed("boom")), since: 9),
            item("w0", .working, since: 0),
        ])
        XCTAssertEqual(ordered.map(\.id), ["n5", "w0", "w1", "f9", "f3"])
    }

    func testOrderingBreaksTiesById() {
        let ordered = AgentActivityItem.ordered([item("b", .working, since: 1), item("a", .working, since: 1)])
        XCTAssertEqual(ordered.map(\.id), ["a", "b"])
    }

    func testDefaultChoicesAreTheFullSet() {
        let approval = AgentActivityTestSupport.approval(choices: nil)
        XCTAssertEqual(AgentActivityApprovalChoices.allowed(for: approval), ["once", "session", "always", "deny"])
    }

    func testSmartDeniedOffersOnlyOnceAndDeny() {
        let approval = AgentActivityTestSupport.approval(choices: nil, smartDenied: true)
        XCTAssertEqual(AgentActivityApprovalChoices.allowed(for: approval), ["once", "deny"])
        XCTAssertFalse(AgentActivityApprovalChoices.isAllowed("always", for: approval))
    }

    func testAlwaysIsHiddenWhenPermanentIsNotAllowed() {
        let approval = AgentActivityTestSupport.approval(choices: nil, allowPermanent: false)
        XCTAssertEqual(AgentActivityApprovalChoices.allowed(for: approval), ["once", "session", "deny"])
    }

    func testExplicitChoicesWin() {
        let approval = AgentActivityTestSupport.approval(choices: ["once", "deny"])
        XCTAssertTrue(AgentActivityApprovalChoices.isAllowed("once", for: approval))
        XCTAssertFalse(AgentActivityApprovalChoices.isAllowed("session", for: approval))
    }

    func testUnknownChoiceIsNeverAllowed() {
        XCTAssertFalse(AgentActivityApprovalChoices.isAllowed("approve", for: AgentActivityTestSupport.approval()))
    }
}
