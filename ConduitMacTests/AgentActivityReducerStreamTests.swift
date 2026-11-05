import XCTest
@testable import ConduitMac

final class AgentActivityReducerStreamTests: XCTestCase {
    private func approvalEvent(_ session: String = "s1", request: String = "q1") -> StreamEvent {
        .approval(sessionId: session, activity: AgentActivityTestSupport.approval(session: session, request: request))
    }

    // MARK: - Turns

    func testMessageStartRaisesAWorkingTurnOnce() throws {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 5)
        let item = try XCTUnwrap(h.item("turn:s1"))
        XCTAssertEqual(item.kind, .turn)
        XCTAssertEqual(item.state, .working)
        XCTAssertEqual(item.sessionId, "s1")
        XCTAssertEqual(item.turnSeq, 1)
        XCTAssertEqual(item.startedAt, h.origin.addingTimeInterval(5))
        XCTAssertEqual(h.turnStarts.count, 1)
        h.stream(.messageStart(sessionId: "s1"), at: 6)
        XCTAssertEqual(h.turnStarts.count, 1, "already working: no second start")
    }

    func testDeltaToolAndBusyEachRaiseAMissingTurn() {
        for (index, event) in [
            StreamEvent.messageDelta(sessionId: "s1", text: "hi"),
            .reasoningDelta(sessionId: "s1", text: "hm"),
            .toolStart(sessionId: "s1", toolName: "terminal", toolInput: nil),
            .sessionBusy(sessionId: "s1", busy: true),
        ].enumerated() {
            var h = AgentActivityHarness()
            h.stream(event)
            XCTAssertEqual(h.turnStarts.count, 1, "case \(index)")
        }
    }

    func testToolStartSetsDetailAndToolCompleteClearsIt() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.toolStart(sessionId: "s1", toolName: "terminal", toolInput: nil))
        XCTAssertEqual(h.item("turn:s1")?.detail, "terminal")
        h.stream(.toolComplete(sessionId: "s1", toolName: "terminal", toolOutput: nil))
        XCTAssertNil(h.item("turn:s1")?.detail)
    }

    func testCompleteFinishesWithATrimmedPreview() throws {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "  Done!  ", reasoning: nil), at: 12)
        let item = try XCTUnwrap(h.item("turn:s1"))
        XCTAssertEqual(item.state, .finished(.completed))
        XCTAssertEqual(item.startedAt, h.origin)
        XCTAssertEqual(item.since, h.origin.addingTimeInterval(12))
        XCTAssertEqual(h.turnFinishes.count, 1)
        XCTAssertEqual(h.turnFinishes[0].outcome, .completed)
        XCTAssertEqual(h.turnFinishes[0].preview, "Done!")
        XCTAssertFalse(h.turnFinishes[0].gap)
    }

    func testPreviewIsCappedAt200Characters() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: String(repeating: "a", count: 300), reasoning: nil))
        XCTAssertEqual(h.turnFinishes[0].preview?.count, 200)
    }

    func testErrorAndInterruptFinishWithTheirOutcome() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "e"))
        h.stream(.messageStart(sessionId: "i"))
        h.stream(.messageError(sessionId: "e", message: "boom"))
        h.stream(.messageInterrupted(sessionId: "i"))
        XCTAssertEqual(h.item("turn:e")?.state, .finished(.failed("boom")))
        XCTAssertEqual(h.item("turn:i")?.state, .finished(.interrupted))
        XCTAssertEqual(h.turnFinishes.map(\.outcome), [.failed("boom"), .interrupted])
    }

    func testBusyFalseEndsATurnThatNeverCompleted() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.sessionBusy(sessionId: "s1", busy: false))
        XCTAssertEqual(h.item("turn:s1")?.state, .finished(.completed))
        XCTAssertNil(h.turnFinishes[0].preview)
    }

    func testTerminalEventsWithoutAWorkingTurnAreIgnored() {
        var h = AgentActivityHarness()
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "x", reasoning: nil))
        h.stream(.messageError(sessionId: "s1", message: "x"))
        h.stream(.messageInterrupted(sessionId: "s1"))
        h.stream(.sessionBusy(sessionId: "s1", busy: false))
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testNewWorkWithinThreeSecondsReopensTheSameTurn() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "first", reasoning: nil), at: 10)
        h.stream(.messageStart(sessionId: "s1"), at: 12)
        XCTAssertEqual(h.item("turn:s1")?.state, .working)
        XCTAssertEqual(h.item("turn:s1")?.turnSeq, 1)
        XCTAssertEqual(h.item("turn:s1")?.startedAt, h.origin)
        XCTAssertEqual(h.turnStarts.count, 1, "a reopened turn is not a new start")
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "second", reasoning: nil), at: 20)
        XCTAssertEqual(h.turnFinishes.map(\.item.turnSeq), [1, 1], "consumers dedupe on (sessionKey, turnSeq)")
    }

    func testNewWorkAfterTheReopenWindowStartsANewTurn() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "first", reasoning: nil), at: 10)
        h.stream(.messageStart(sessionId: "s1"), at: 14)
        XCTAssertEqual(h.item("turn:s1")?.turnSeq, 2)
        XCTAssertEqual(h.turnStarts.count, 2)
    }

    func testFailedTurnDoesNotReopen() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageError(sessionId: "s1", message: "boom"), at: 1)
        h.stream(.messageStart(sessionId: "s1"), at: 2)
        XCTAssertEqual(h.item("turn:s1")?.turnSeq, 2)
    }

    func testSessionsAreIndependent() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "a"))
        h.stream(.messageStart(sessionId: "b"))
        h.stream(.messageComplete(sessionId: "a", messageId: nil, content: "x", reasoning: nil))
        XCTAssertEqual(h.item("turn:a")?.state, .finished(.completed))
        XCTAssertEqual(h.item("turn:b")?.state, .working)
    }

    func testUnrelatedEventsAreIgnored() {
        var h = AgentActivityHarness()
        h.stream(.contextUpdate(sessionId: "s1", percent: 1, used: 1, max: 2))
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testActiveSessionFlagFollowsTheActiveId() {
        var h = AgentActivityHarness()
        h.send(.activeSession(id: "s1"))
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.messageStart(sessionId: "s2"))
        XCTAssertEqual(h.item("turn:s1")?.isActiveSession, true)
        XCTAssertEqual(h.item("turn:s2")?.isActiveSession, false)
        h.send(.activeSession(id: "s2"))
        XCTAssertEqual(h.item("turn:s1")?.isActiveSession, false)
        XCTAssertEqual(h.item("turn:s2")?.isActiveSession, true)
    }

    // MARK: - Decisions

    func testApprovalRaisesANeedsUserItemWithItsContentAndTheTurn() throws {
        var h = AgentActivityHarness()
        h.stream(approvalEvent())
        let item = try XCTUnwrap(h.item("approval:q1"))
        XCTAssertEqual(item.kind, .approval)
        XCTAssertEqual(item.state, .needsUser)
        XCTAssertEqual(item.approval?.command, "rm -rf build")
        XCTAssertEqual(item.detail, "Delete build output")
        XCTAssertNotNil(h.item("turn:s1"), "a pending approval implies a running turn")
        XCTAssertEqual(h.requests.map(\.id), ["approval:q1"])
    }

    func testReplayedApprovalNeitherDuplicatesTheRowNorRaisesASecondRequest() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent(), at: 0)
        h.stream(approvalEvent(), at: 30)
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(h.state.items.count, 2, "one turn, one approval")
        XCTAssertEqual(h.item("approval:q1")?.since, h.origin, "a replay keeps the original time")
    }

    func testWithdrawalReasonsMapToEventReasons() {
        let table: [(String, AgentActivityEvent.Reason)] = [
            ("resolved", .answeredElsewhere), ("timeout", .expired), ("session_closed", .sessionClosed),
            ("interrupted", .withdrawn), ("shutdown", .withdrawn), ("something-new", .withdrawn),
        ]
        for (raw, expected) in table {
            var h = AgentActivityHarness()
            h.stream(approvalEvent())
            h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: raw))
            XCTAssertNil(h.item("approval:q1"), raw)
            XCTAssertEqual(h.resolutions.map(\.id), ["approval:q1"], raw)
            XCTAssertEqual(h.resolutions.map(\.reason), [expected], raw)
        }
    }

    func testResolvedAfterALocalResponseIsAnsweredHere() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent())
        h.send(.respondStarted(itemId: "approval:q1"))
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.answeredHere])
    }

    func testAFailedResponseForgetsTheLocalClaim() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent())
        h.send(.respondStarted(itemId: "approval:q1"))
        h.send(.respondFailed(itemId: "approval:q1", message: "offline"))
        XCTAssertEqual(h.item("approval:q1")?.failure, "offline")
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.answeredElsewhere])
    }

    func testRespondResolvedRemovesTheItemWithTheRightReason() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent(request: "q1"))
        h.stream(approvalEvent(request: "q2"))
        h.send(.respondResolved(itemId: "approval:q1", alreadyResolved: false))
        h.send(.respondResolved(itemId: "approval:q2", alreadyResolved: true))
        XCTAssertEqual(h.resolutions.map(\.reason), [.answeredHere, .answeredElsewhere])
        // The gateway's own cancel for the same request now finds nothing.
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(h.resolutions.count, 2)
    }

    func testWithdrawalOfAnUnknownRequestDoesNothing() {
        var h = AgentActivityHarness()
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "zzz", reason: "resolved"))
        XCTAssertTrue(h.payloads.isEmpty)
    }

    func testClarifyRaisesWithTheFirstQuestionAndOpenCount() throws {
        var h = AgentActivityHarness()
        let questions = [
            ClarifyQuestion(id: "a", question: "First?", choices: []),
            ClarifyQuestion(id: "b", question: "Second?", choices: []),
            ClarifyQuestion(id: "c", question: "Done?", choices: [], status: .answered),
        ]
        h.stream(.clarify(sessionId: "s1", activity: ClarifyActivity(requestId: "c1", questions: questions)))
        let item = try XCTUnwrap(h.item("clarify:c1"))
        XCTAssertEqual(item.kind, .clarify)
        XCTAssertEqual(item.detail, "First?")
        XCTAssertEqual(item.openQuestionCount, 2)
        h.stream(.clarifyExpire(sessionId: "s1", requestId: "c1", reason: nil))
        XCTAssertNil(h.item("clarify:c1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.expired])
    }

    func testAnAlreadyExpiredClarifyIsNotRaised() {
        var h = AgentActivityHarness()
        let question = ClarifyQuestion(id: "a", question: "First?", choices: [])
        h.stream(.clarify(sessionId: "s1", activity: ClarifyActivity(requestId: "c1", questions: [question], isExpired: true)))
        XCTAssertNil(h.item("clarify:c1"))
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testInputPromptCarriesNoDetailAndExpiresWithItsReason() throws {
        var h = AgentActivityHarness()
        let prompt = InputPromptActivity(requestId: "srq-1", sessionId: "s1", kind: .sudo)
        h.stream(.inputPrompt(sessionId: "s1", activity: prompt))
        let item = try XCTUnwrap(h.item("inputPrompt:srq-1"))
        XCTAssertEqual(item.kind, .inputPrompt)
        XCTAssertNil(item.detail, "sudo and secret prompts never travel as row text")
        h.stream(.inputPromptExpire(sessionId: "s1", requestId: "srq-1", reason: "session_closed"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.sessionClosed])
    }

    // MARK: - Titles

    func testTitleEventUpdatesItemsAndEmitsOnlyOnChange() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.sessionTitle(runtimeSessionId: "s1", storedSessionId: "st1", title: "Laravel"))
        XCTAssertEqual(h.item("turn:s1")?.title, "Laravel")
        XCTAssertEqual(h.item("turn:s1")?.sessionKey, "st1")
        XCTAssertEqual(h.titleChanges.map(\.title), ["Laravel"])
        XCTAssertEqual(h.titleChanges.map(\.key), ["st1"])
        h.stream(.sessionTitle(runtimeSessionId: "s1", storedSessionId: "st1", title: "Laravel"))
        XCTAssertEqual(h.titleChanges.count, 1)
    }

    // MARK: - Tick, dismiss, reset

    func testTickDropsFinishedAfterThirtySecondsAndKeepsThreeNewest() {
        var h = AgentActivityHarness()
        for (index, id) in ["a", "b", "c", "d"].enumerated() {
            h.stream(.messageStart(sessionId: id), at: TimeInterval(index))
            h.stream(.messageComplete(sessionId: id, messageId: nil, content: nil, reasoning: nil), at: TimeInterval(index))
        }
        h.send(.tick, at: 4)
        XCTAssertEqual(Set(h.state.items.keys), ["turn:b", "turn:c", "turn:d"])
        h.send(.tick, at: 40)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testTickExpiresAStuckDecision() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent(), at: 0)
        h.send(.tick, at: 599)
        XCTAssertNotNil(h.item("approval:q1"))
        h.send(.tick, at: 601)
        XCTAssertNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.expired])
    }

    func testDismissRemovesOnlyFinishedItems() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "w"))
        h.stream(.messageStart(sessionId: "f"))
        h.stream(.messageComplete(sessionId: "f", messageId: nil, content: nil, reasoning: nil))
        h.send(.dismiss(itemId: "turn:w"))
        h.send(.dismiss(itemId: "turn:f"))
        XCTAssertNotNil(h.item("turn:w"))
        XCTAssertNil(h.item("turn:f"))
    }

    func testResetClearsEverythingSilentlyAndRearmsTheBaseline() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.state.baselinePending = false
        let before = h.payloads.count
        h.send(.reset(profile: "work", dashboardID: "d1"))
        XCTAssertTrue(h.state.items.isEmpty)
        XCTAssertEqual(h.payloads.count, before, "a scope switch emits nothing")
        XCTAssertEqual(h.state.scope, AgentActivityState.Scope(profile: "work", dashboardID: "d1"))
        XCTAssertTrue(h.state.baselinePending)
        h.stream(.messageStart(sessionId: "s2"))
        XCTAssertEqual(h.item("turn:s2")?.profile, "work")
        XCTAssertEqual(h.item("turn:s2")?.dashboardID, "d1")
    }
}
