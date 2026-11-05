import Combine
import XCTest
@testable import ConduitMac

@MainActor
final class AgentActivityApprovalTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private var sources: FakeActivitySources!
    private var hub: MacStreamEventHub!
    private var feed: AgentActivityFeed!
    private var pollSleeper: ManualSleeper!
    private var tickSleeper: ManualSleeper!
    private var received: [AgentActivityEvent] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        sources = FakeActivitySources()
        sources.isConnected = true
        hub = MacStreamEventHub()
        pollSleeper = ManualSleeper()
        tickSleeper = ManualSleeper()
        received = []
        feed = AgentActivityFeed(sources: sources, hub: hub, pollSleep: pollSleeper.sleep, tickSleep: tickSleeper.sleep)
        feed.events.sink { [unowned self] in self.received.append($0) }.store(in: &cancellables)
        feed.start()
        await assertEventually { self.feed.isBaselined }
    }

    override func tearDown() async throws {
        feed.stop()
        pollSleeper.cancelAll()
        tickSleeper.cancelAll()
        cancellables = []
        feed = nil
    }

    private func raise(_ approval: ApprovalActivity) {
        hub.publish(.approval(sessionId: approval.sessionId, activity: approval))
    }

    private var resolutions: [AgentActivityEvent.Reason] {
        received.compactMap { if case .decisionResolved(_, let reason) = $0.payload { return reason } else { return nil } }
    }

    func testRespondSendsTheChoiceThroughTheClientAndRemovesTheRow() async {
        raise(Support.approval())
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .resolved)
        XCTAssertEqual(sources.responses.map(\.choice), ["once"])
        XCTAssertEqual(sources.responses.map(\.session), ["s1"])
        XCTAssertEqual(sources.responses.map { $0.request ?? "" }, ["q1"])
        XCTAssertNil(feed.items.first { $0.id == "approval:q1" })
        XCTAssertEqual(resolutions, [.answeredHere])
    }

    func testNotResolvedMeansAnsweredElsewhere() async {
        raise(Support.approval())
        sources.respondResult = .success(false)
        let result = await feed.respond(to: "approval:q1", choice: "deny")
        XCTAssertEqual(result, .alreadyResolved)
        XCTAssertEqual(resolutions, [.answeredElsewhere])
    }

    func testAnExpiredPromptErrorIsTreatedAsAlreadyResolved() async {
        raise(Support.approval())
        sources.respondResult = .failure(RpcError(code: 4009, message: "no pending approval request"))
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .alreadyResolved)
        XCTAssertEqual(resolutions, [.answeredElsewhere])
    }

    func testATransportErrorKeepsTheRowRecordsTheFailureAndAllowsRetry() async {
        raise(Support.approval())
        sources.respondResult = .failure(RpcError(code: 500, message: "boom"))
        let first = await feed.respond(to: "approval:q1", choice: "once")
        guard case .failed(let message) = first else { return XCTFail("expected failure") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(feed.items.first { $0.id == "approval:q1" }?.failure, message)
        sources.respondResult = .success(true)
        let second = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(second, .resolved)
        XCTAssertNil(feed.items.first { $0.id == "approval:q1" })
    }

    func testAChoiceTheRequestDoesNotOfferIsRefusedBeforeAnyRPC() async {
        raise(Support.approval(request: "smart", smartDenied: true))
        let always = await feed.respond(to: "approval:smart", choice: "always")
        XCTAssertEqual(always, .failed(AgentActivityRespondFailure.choiceNotOffered))
        let session = await feed.respond(to: "approval:smart", choice: "session")
        XCTAssertEqual(session, .failed(AgentActivityRespondFailure.choiceNotOffered))

        raise(Support.approval(request: "nopermanent", allowPermanent: false))
        let blocked = await feed.respond(to: "approval:nopermanent", choice: "always")
        XCTAssertEqual(blocked, .failed(AgentActivityRespondFailure.choiceNotOffered))

        XCTAssertTrue(sources.responses.isEmpty, "no RPC for a refused choice")
        XCTAssertNil(feed.items.first { $0.id == "approval:smart" }?.failure, "a refusal does not mark the row failed")
        XCTAssertTrue(resolutions.isEmpty)
    }

    func testAnUnknownChoiceIsRefused() async {
        raise(Support.approval())
        let result = await feed.respond(to: "approval:q1", choice: "approve")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.choiceNotOffered))
    }

    func testTheActiveSessionsApprovalGoesThroughTheOpenCard() async {
        feed.setActiveSession("s1")
        raise(Support.approval())
        sources.cardResult = true
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .resolved)
        XCTAssertEqual(sources.cardResponses.map(\.choice), ["once"])
        XCTAssertTrue(sources.responses.isEmpty)
    }

    func testWithoutAnOpenCardTheActiveSessionFallsBackToTheClient() async {
        feed.setActiveSession("s1")
        raise(Support.approval())
        sources.cardResult = nil
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .resolved)
        XCTAssertEqual(sources.responses.count, 1)
    }

    func testAFailedCardIsAFailureNotAnAlreadyResolved() async {
        feed.setActiveSession("s1")
        raise(Support.approval())
        sources.cardResult = false
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.sendFailed))
        XCTAssertNotNil(feed.items.first { $0.id == "approval:q1" })
    }

    func testRowsWithoutContentOrUnknownIdsCannotBeAnswered() async {
        let unknown = await feed.respond(to: "approval:nope", choice: "once")
        XCTAssertEqual(unknown, .failed(AgentActivityRespondFailure.notAnswerable))
        hub.publish(.messageStart(sessionId: "s1"))
        let turn = await feed.respond(to: "turn:s1", choice: "once")
        XCTAssertEqual(turn, .failed(AgentActivityRespondFailure.notAnswerable))
    }

    func testAFallbackRowWithoutContentCannotBeAnswered() async {
        sources.rows = [Support.row("rt9", "waiting")]
        sources.pendingResults["rt9"] = .failure(RpcError(code: 500, message: "x"))
        pollSleeper.fire()
        await assertEventually { self.feed.items.contains { $0.id == "approval:waiting:rt9" } }
        let result = await feed.respond(to: "approval:waiting:rt9", choice: "once")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.notAnswerable))
    }

    func testADisconnectedFeedRefusesWithoutAnRPC() async {
        raise(Support.approval())
        sources.isConnected = false
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.notConnected))
        XCTAssertTrue(sources.responses.isEmpty)
    }

    func testTheGatewaysOwnCancelAfterALocalAnswerAddsNothing() async {
        raise(Support.approval())
        _ = await feed.respond(to: "approval:q1", choice: "once")
        hub.publish(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(resolutions, [.answeredHere])
    }

    func testASecondResponseForTheSameRowWhileOneIsInFlightIsRejected() async {
        raise(Support.approval())
        sources.holdResponses = true
        let first = Task { await self.feed.respond(to: "approval:q1", choice: "once") }
        await assertEventually { self.sources.responses.count == 1 }
        let second = await feed.respond(to: "approval:q1", choice: "deny")
        XCTAssertEqual(second, .failed(AgentActivityRespondFailure.inFlight))
        sources.releaseResponses()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .resolved)
        XCTAssertEqual(sources.responses.count, 1)
    }
}
