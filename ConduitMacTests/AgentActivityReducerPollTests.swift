import XCTest
@testable import ConduitMac

final class AgentActivityReducerPollTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    /// A harness that has already consumed its silent baseline.
    private func baselined(_ rows: [LiveSessionStatus] = []) -> AgentActivityHarness {
        var h = AgentActivityHarness()
        h.send(.activeList(rows))
        return h
    }

    func testBaselineIsSilentButFillsTheItems() {
        var h = AgentActivityHarness()
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]))
        XCTAssertNotNil(h.item("turn:rt1"))
        XCTAssertTrue(h.payloads.isEmpty, "what is already running at start is not news")
        XCTAssertFalse(h.state.baselinePending)
    }

    func testAPollOnlySessionAppearsAfterTheBaselineAndIsMarked() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        let item = h.item("turn:rt1")
        XCTAssertEqual(item?.isPollOnly, true)
        XCTAssertEqual(item?.sessionKey, "st1")
        XCTAssertEqual(h.turnStarts.count, 1)
    }

    func testStreamAndPollMergeIntoOneRow() {
        var h = baselined()
        h.stream(.messageStart(sessionId: "rt1"))
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        XCTAssertEqual(h.state.items.count, 1)
        XCTAssertEqual(h.item("turn:rt1")?.isPollOnly, false)
        XCTAssertEqual(h.turnStarts.count, 1)
    }

    func testOneFlakyPollDoesNotFinishATurnButTwoDo() {
        var h = baselined([Support.row("rt1", "working")])
        h.send(.activeList([]), at: 4)
        XCTAssertEqual(h.item("turn:rt1")?.state, .working, "one miss")
        h.send(.activeList([Support.row("rt1", "working")]), at: 8)
        h.send(.activeList([]), at: 12)
        XCTAssertEqual(h.item("turn:rt1")?.state, .working, "the streak was reset")
        h.send(.activeList([]), at: 16)
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed))
        XCTAssertEqual(h.turnFinishes.count, 1)
        XCTAssertNil(h.turnFinishes[0].preview)
        XCTAssertFalse(h.turnFinishes[0].gap)
    }

    func testIdleCountsAsAMissAndStartingIsNeutral() {
        var h = baselined([Support.row("rt1", "working"), Support.row("rt2", "working")])
        for step in 1...3 {
            h.send(.activeList([Support.row("rt1", "idle"), Support.row("rt2", "starting")]), at: TimeInterval(step * 4))
        }
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed))
        XCTAssertEqual(h.item("turn:rt2")?.state, .working)
    }

    func testAStalePollNeverResurrectsAJustFinishedTurn() {
        var h = baselined()
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.stream(.messageComplete(sessionId: "rt1", messageId: nil, content: "x", reasoning: nil), at: 5)
        h.send(.activeList([Support.row("rt1", "working")]), at: 6)
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed))
        XCTAssertEqual(h.turnStarts.count, 1)
    }

    // MARK: - Waiting sessions

    func testWaitingFetchesOnceThenRaisesRealApprovalsAnnounced() throws {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 4)
        XCTAssertEqual(AgentActivityReducer.fetchTargets(h.state), ["rt1"])
        XCTAssertTrue(h.requests.isEmpty, "no row until the content is known")
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        XCTAssertTrue(AgentActivityReducer.fetchTargets(h.state).isEmpty)
        h.send(.pendingApprovals(runtimeSessionId: "rt1", [Support.approval(session: "rt1", request: "q1")]), at: 5)
        let item = try XCTUnwrap(h.item("approval:q1"))
        XCTAssertEqual(item.approval?.command, "rm -rf build")
        XCTAssertEqual(h.requests.map(\.id), ["approval:q1"])
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 8)
        XCTAssertTrue(AgentActivityReducer.fetchTargets(h.state).isEmpty, "content is known: no second fetch")
        XCTAssertEqual(h.requests.count, 1)
    }

    func testFetchFailureBecomesANoButtonRow() throws {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovalsFailed(runtimeSessionId: "rt1"))
        let item = try XCTUnwrap(h.item("approval:waiting:rt1"))
        XCTAssertEqual(item.kind, .approval)
        XCTAssertNil(item.approval)
        XCTAssertEqual(h.requests.count, 1)
    }

    func testAnEmptyPendingListMeansAnAnswerInConduitRow() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovals(runtimeSessionId: "rt1", []))
        XCTAssertEqual(h.item("clarify:waiting:rt1")?.kind, .clarify)
        XCTAssertNil(h.item("clarify:waiting:rt1")?.approval)
    }

    func testAWaitingSessionFoundInTheBaselineShowsItsContentSilently() {
        var h = AgentActivityHarness()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        XCTAssertEqual(AgentActivityReducer.fetchTargets(h.state), ["rt1"])
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovals(runtimeSessionId: "rt1", [Support.approval(session: "rt1", request: "q1")]))
        XCTAssertNotNil(h.item("approval:q1"))
        XCTAssertTrue(h.requests.isEmpty, "snapshot() carries it; no decisionRequested for what was already pending")
    }

    func testALateFetchResultAfterTheSessionStoppedWaitingIsIgnored() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.activeList([Support.row("rt1", "working")]), at: 4)
        h.send(.pendingApprovals(runtimeSessionId: "rt1", [Support.approval(session: "rt1")]), at: 5)
        XCTAssertNil(h.item("approval:q1"))
    }

    func testAnEventCapturedApprovalNeedsNoFetch() {
        var h = baselined()
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")))
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 4)
        XCTAssertTrue(AgentActivityReducer.fetchTargets(h.state).isEmpty)
    }

    func testAStreamApprovalReplacesTheFallbackRow() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovalsFailed(runtimeSessionId: "rt1"))
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")), at: 2)
        XCTAssertNil(h.item("approval:waiting:rt1"))
        XCTAssertNotNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.id), ["approval:waiting:rt1"])
    }

    func testADecisionWhoseSessionStoppedWaitingResolvesAfterTwoPolls() {
        var h = baselined()
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")))
        h.send(.activeList([Support.row("rt1", "working")]), at: 4)
        XCTAssertNotNil(h.item("approval:q1"), "one miss")
        h.send(.activeList([Support.row("rt1", "working")]), at: 8)
        XCTAssertNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.withdrawn])
    }

    func testADecisionWhoseSessionVanishedIsSessionClosed() {
        var h = baselined()
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")))
        h.send(.activeList([]), at: 4)
        h.send(.activeList([]), at: 8)
        XCTAssertEqual(h.resolutions.map(\.reason), [.sessionClosed])
    }

    // MARK: - Capability and staleness

    func testUnavailableListEndsTheBaselineAndSuspendsMissLogic() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.send(.activeListUnavailable)
        XCTAssertFalse(h.state.baselinePending)
        XCTAssertFalse(h.state.pollAuthoritative)
        h.send(.tick, at: 300)
        XCTAssertEqual(h.item("turn:rt1")?.state, .working)
        h.send(.tick, at: 601)
        XCTAssertNil(h.item("turn:rt1"), "silent for ten minutes with no list to confirm it")
        XCTAssertTrue(h.turnFinishes.isEmpty, "dropped silently, not finished")
    }

    // MARK: - Identity and catalog

    func testIdsInAnyFormYieldOneRow() {
        var h = baselined()
        h.stream(.messageStart(sessionId: "rt1"))
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", alternates: ["old"], title: "Laravel")]), at: 5)
        h.stream(.messageDelta(sessionId: "old", text: "hi"), at: 6)
        XCTAssertEqual(h.state.items.count, 1)
        XCTAssertEqual(h.turnStarts.count, 1)
        XCTAssertEqual(h.item("turn:rt1")?.sessionKey, "cat1")
        XCTAssertEqual(h.item("turn:rt1")?.title, "Laravel")
    }

    func testCatalogTitleAppliesToLaterItemsToo() {
        var h = baselined()
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", title: "Laravel")]))
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        XCTAssertEqual(h.item("turn:rt1")?.title, "Laravel")
    }

    func testACatalogRowThatSharesOnlyAnAliasLearnedFromAnEarlierRowStillMatches() {
        var h = baselined([Support.row("rt1", stored: "st1", "working")])
        h.send(.catalog([
            Support.summary(id: "cat1", stored: "st1", alternates: ["old"], title: "First"),
            Support.summary(id: "cat2", stored: "old", title: "Second"),
            Support.summary(id: "unrelated", stored: "zz", title: "Other"),
        ]))
        XCTAssertEqual(h.item("turn:rt1")?.sessionKey, "cat2", "the later row matched through 'old', learned from the earlier one")
        XCTAssertEqual(h.state.identities.count, 1, "a catalog row for no known session adds no identity")
    }

    func testCatalogRenameUpdatesTheRow() {
        var h = baselined([Support.row("rt1", stored: "st1", "working")])
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", title: "One")]))
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", title: "Two")]))
        XCTAssertEqual(h.item("turn:rt1")?.title, "Two")
    }
}
