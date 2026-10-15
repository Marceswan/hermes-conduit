import Combine
import XCTest
@testable import ConduitMac

final class MacFeedEventMapperTests: XCTestCase {
    private typealias S = AgentActivityTestSupport
    private var mapper = MacFeedEventMapper()

    private func event(_ id: UInt64, _ payload: AgentActivityEvent.Payload) -> AgentActivityEvent {
        AgentActivityEvent(eventId: id, at: S.origin, payload: payload)
    }

    private func turnItem(key: String? = "key-1", seq: Int = 2, finishedAfter: TimeInterval? = nil) -> AgentActivityItem {
        var item = S.item("turn:rt", sessionId: "rt")
        item.sessionKey = key
        item.turnSeq = seq
        item.title = "Billing"
        if let finishedAfter { item.since = S.origin.addingTimeInterval(finishedAfter) }
        return item
    }

    private func approvalItem(smartDenied: Bool = false, withContent: Bool = true) -> AgentActivityItem {
        var item = S.item("approval:q1", kind: .approval, state: .needsUser, sessionId: "rt")
        item.sessionKey = "key-1"
        if withContent { item.approval = S.approval(session: "rt", request: "q1", smartDenied: smartDenied) }
        return item
    }

    func testTurnStartedUsesKeyAndSequenceAsTheTurnId() throws {
        let mapped = try XCTUnwrap(mapper.map(event(7, .turnStarted(turnItem()))))
        XCTAssertEqual(mapped.eventId, 7)
        XCTAssertEqual(mapped.session.sessionId, "rt")
        XCTAssertEqual(mapped.session.sessionKey, "key-1")
        XCTAssertEqual(mapped.session.title, "Billing")
        XCTAssertEqual(mapped.kind, .turnStarted(turnId: "key-1:2", at: S.origin))
    }

    func testTurnFinishedCarriesFinishStartOutcomeAndGap() throws {
        let item = turnItem(finishedAfter: 65)
        let mapped = try XCTUnwrap(mapper.map(event(8, .turnFinished(item, outcome: .completed, replyPreview: "All done", observedGap: true))))
        XCTAssertEqual(mapped.kind, .turnFinished(
            turnId: "key-1:2", at: S.origin.addingTimeInterval(65), outcome: .completed, replyPreview: "All done",
            startedAt: S.origin, observedGap: true))
    }

    func testOutcomesMapOneToOne() throws {
        let item = turnItem(finishedAfter: 5)
        func outcome(_ o: AgentActivityItem.Outcome) throws -> MacNotificationEvent.Outcome {
            let mapped = try XCTUnwrap(mapper.map(event(1, .turnFinished(item, outcome: o, replyPreview: nil, observedGap: false))))
            guard case .turnFinished(_, _, let out, _, _, _) = mapped.kind else { throw XCTSkip("not a turnFinished") }
            return out
        }
        XCTAssertEqual(try outcome(.completed), .completed)
        XCTAssertEqual(try outcome(.failed("boom")), .failed)
        XCTAssertEqual(try outcome(.interrupted), .interrupted)
    }

    func testApprovalMapsOnlyTheChoicesTheRequestOffersAndKeepsTheExactItemId() throws {
        let full = try XCTUnwrap(mapper.map(event(1, .decisionRequested(approvalItem()))))
        guard case .approvalRequested(let id, _, let command, let choices, _, let itemId) = full.kind else { return XCTFail("expected approvalRequested") }
        XCTAssertEqual(id, "q1")
        XCTAssertEqual(itemId, "approval:q1", "the feed's exact item id travels with the event")
        XCTAssertEqual(command, "rm -rf build")
        XCTAssertEqual(choices, ["once", "session", "always", "deny"])
        let smart = try XCTUnwrap(mapper.map(event(2, .decisionRequested(approvalItem(smartDenied: true)))))
        guard case .approvalRequested(_, _, _, let smartChoices, _, _) = smart.kind else { return XCTFail("expected approvalRequested") }
        XCTAssertEqual(smartChoices, ["once", "deny"])
    }

    func testApprovalWithoutContentOffersNoChoices() throws {
        let mapped = try XCTUnwrap(mapper.map(event(1, .decisionRequested(approvalItem(withContent: false)))))
        guard case .approvalRequested(_, _, _, let choices, _, _) = mapped.kind else { return XCTFail("expected approvalRequested") }
        XCTAssertEqual(choices, [], "Open only")
    }

    func testClarifyMapsToAQuestionWithItsOpenCountAndItemId() throws {
        var item = S.item("clarify:c1", kind: .clarify, state: .needsUser, sessionId: "rt")
        item.detail = "Which branch?"
        item.openQuestionCount = 1
        let mapped = try XCTUnwrap(mapper.map(event(1, .decisionRequested(item))))
        XCTAssertEqual(mapped.kind, .questionRequested(requestId: "c1", firstQuestionText: "Which branch?", openQuestionCount: 1, itemId: "clarify:c1"))
    }

    func testInputPromptsAndReservedKindsAreIgnored() {
        for kind in [AgentActivityItem.Kind.inputPrompt, .kanban, .cron] {
            XCTAssertNil(mapper.map(event(1, .decisionRequested(S.item("x:1", kind: kind, state: .needsUser)))))
        }
    }

    func testResolvedUsesTheRememberedSessionAndStripsThePrefix() throws {
        _ = mapper.map(event(1, .decisionRequested(approvalItem())))
        let here = try XCTUnwrap(mapper.map(event(2, .decisionResolved(id: "approval:q1", reason: .answeredHere))))
        XCTAssertEqual(here.session.sessionKey, "key-1")
        XCTAssertEqual(here.kind, .decisionResolved(requestId: "q1", reason: .answered))
        let elsewhere = try XCTUnwrap(mapper.map(event(3, .decisionResolved(id: "approval:q1", reason: .answeredElsewhere))))
        XCTAssertEqual(elsewhere.kind, .decisionResolved(requestId: "q1", reason: .answered))
        XCTAssertEqual(try XCTUnwrap(mapper.map(event(4, .decisionResolved(id: "approval:q1", reason: .expired)))).kind,
                       .decisionResolved(requestId: "q1", reason: .expired))
        XCTAssertEqual(try XCTUnwrap(mapper.map(event(5, .decisionResolved(id: "approval:q1", reason: .sessionClosed)))).kind,
                       .decisionResolved(requestId: "q1", reason: .sessionClosed))
    }

    func testResolvedForAnUnseenIdStillClearsByRequestId() throws {
        let mapped = try XCTUnwrap(mapper.map(event(1, .decisionResolved(id: "clarify:c9", reason: .withdrawn))))
        XCTAssertEqual(mapped.kind, .decisionResolved(requestId: "c9", reason: .withdrawn))
    }

    func testTitleChangedBuildsAMinimalSession() throws {
        let mapped = try XCTUnwrap(mapper.map(event(1, .titleChanged(sessionKey: "key-1", title: "Renamed"))))
        XCTAssertEqual(mapped.session.sessionKey, "key-1")
        XCTAssertEqual(mapped.kind, .sessionTitleChanged(title: "Renamed"))
    }

    func testSnapshotItemsAreUnsequencedAndOnlyPendingDecisions() throws {
        let pending = try XCTUnwrap(mapper.map(snapshotItem: approvalItem()))
        XCTAssertEqual(pending.eventId, 0)
        XCTAssertNil(mapper.map(snapshotItem: turnItem()), "a working turn is not replayed; its finish carries its own start")
    }

    func testDashboardIDParsesAUUIDElseNil() throws {
        var item = turnItem()
        item.dashboardID = "none"
        XCTAssertNil(try XCTUnwrap(mapper.map(event(1, .turnStarted(item)))).session.dashboardID)
        let uuid = UUID()
        item.dashboardID = uuid.uuidString
        XCTAssertEqual(try XCTUnwrap(mapper.map(event(2, .turnStarted(item)))).session.dashboardID, uuid)
    }

    func testAlternateIDsComeFromTheInjectedLookup() throws {
        mapper = MacFeedEventMapper(alternateIDs: { $0 == "key-1" ? ["stored-1"] : [] })
        let mapped = try XCTUnwrap(mapper.map(event(1, .turnStarted(turnItem()))))
        XCTAssertEqual(mapped.session.allIDs, ["rt", "key-1", "stored-1"])
    }

    @MainActor
    func testSnapshotAndLiveCopyOfTheSameRequestPostOnce() async throws {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let center = FakeNotificationCenter()
        let scheduler = FakeScheduler()
        let coordinator = MacNotificationCoordinator(
            center: center, preferences: MacNotificationPreferences(defaults: suite.defaults),
            scheduler: scheduler, visibility: { _ in .away })
        let live = try XCTUnwrap(mapper.map(event(5, .decisionRequested(approvalItem()))))
        let snapshot = try XCTUnwrap(mapper.map(snapshotItem: approvalItem()))
        XCTAssertEqual([live.eventId, snapshot.eventId], [5, 0])
        coordinator.handle(live)
        coordinator.handle(snapshot)
        await coordinator.drain()
        scheduler.fireAll()
        await coordinator.drain()
        XCTAssertEqual(center.identifiers, ["conduit.approval.q1"])
    }
}

@MainActor
final class MacAgentActivityFeedSourceTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private var sources: FakeActivitySources!
    private var hub: MacStreamEventHub!
    private var pollSleeper: ManualSleeper!
    private var tickSleeper: ManualSleeper!
    private var feed: AgentActivityFeed!
    private var received: [MacNotificationEvent] = []

    override func setUp() async throws {
        sources = FakeActivitySources()
        hub = MacStreamEventHub()
        pollSleeper = ManualSleeper()
        tickSleeper = ManualSleeper()
        received = []
        feed = AgentActivityFeed(
            sources: sources, hub: hub, clock: { Support.origin },
            pollSleep: pollSleeper.sleep, tickSleep: tickSleeper.sleep)
    }

    override func tearDown() async throws {
        feed.stop()
        pollSleeper.cancelAll()
        tickSleeper.cancelAll()
        feed = nil
    }

    func testLiveFeedEventsReachTheHandlerInOrder() {
        sources.isConnected = false
        feed.start()
        let source = MacAgentActivityFeedSource(feed: feed)
        source.start { [unowned self] in received.append($0) }
        hub.publish(.messageStart(sessionId: "s1"))
        hub.publish(.messageComplete(sessionId: "s1", messageId: nil, content: "done", reasoning: nil))
        XCTAssertEqual(received.count, 2)
        guard case .turnStarted = received.first?.kind else { return XCTFail("expected turnStarted first") }
        guard case .turnFinished(_, _, let outcome, let preview, let startedAt, _) = received.last?.kind else { return XCTFail("expected turnFinished last") }
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(preview, "done")
        XCTAssertNotNil(startedAt, "the finish carries the feed's own start")
        source.stop()
    }

    func testSnapshotDecisionsAreDeliveredOnceAfterBaseline() async {
        sources.rows = [Support.row("rt1", "waiting")]
        sources.pendingResults["rt1"] = .success([Support.approval(session: "rt1", request: "q1")])
        let source = MacAgentActivityFeedSource(feed: feed)
        source.start { [unowned self] in received.append($0) }
        XCTAssertTrue(received.isEmpty, "nothing before the feed is baselined")
        feed.start()
        await assertEventually { self.feed.isBaselined }
        await assertEventually { !self.received.isEmpty }
        let approvals = received.filter { if case .approvalRequested = $0.kind { return true } else { return false } }
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.eventId, 0, "a snapshot item is unsequenced")
        guard case .approvalRequested(let requestId, _, _, _, _, let itemId)? = approvals.first?.kind else { return XCTFail("expected approvalRequested") }
        XCTAssertEqual(requestId, "q1")
        XCTAssertEqual(itemId, "approval:q1")
        source.stop()
    }

    func testStartIsIdempotentAndStopUnsubscribes() {
        sources.isConnected = false
        feed.start()
        let source = MacAgentActivityFeedSource(feed: feed)
        source.start { [unowned self] in received.append($0) }
        source.start { [unowned self] in received.append($0) }
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(received.count, 1, "one handler call per event")
        source.stop()
        hub.publish(.messageStart(sessionId: "s2"))
        XCTAssertEqual(received.count, 1, "a stopped source hears nothing")
    }

    func testNoFeedMeansStartDoesNothing() {
        AgentActivityFeed.shared = nil
        let source = MacAgentActivityFeedSource()
        source.start { [unowned self] in received.append($0) }
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertTrue(received.isEmpty)
        source.stop()
    }
}
