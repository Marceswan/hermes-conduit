import XCTest
@testable import ConduitMac

final class MacSessionTranscriptTests: XCTestCase {
    private let ts = "2026-10-16T00:00:00Z"

    private func resume(_ id: String, stored: String? = nil, messages: [ChatMessage] = [], running: Bool? = nil) -> SessionResumeResult {
        SessionResumeResult(sessionId: id, storedSessionId: stored, messages: messages,
                            snapshot: .macTestSnapshot(running: running))
    }

    func testPlainTurnStreamsThenCompletes() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageStart(sessionId: "s"), timestamp: ts)
        t.apply(.messageDelta(sessionId: "s", text: "Hel"), timestamp: ts)
        t.apply(.messageDelta(sessionId: "s", text: "lo"), timestamp: ts)
        XCTAssertEqual(t.streamingText, "Hello")
        XCTAssertEqual(t.turn, .running)
        let effect = t.apply(.messageComplete(sessionId: "s", messageId: "m1", content: "Hello!", reasoning: nil), timestamp: ts)
        XCTAssertEqual(effect, .turnEnded)
        XCTAssertEqual(t.messages.map(\.id), ["m1"])
        XCTAssertEqual(t.messages.first?.content, "Hello!")
        XCTAssertEqual(t.streamingText, "")
    }

    func testForeignSessionIsIgnored() {
        var t = MacSessionTranscript(sessionID: "s")
        XCTAssertFalse(t.isRelevant(.messageDelta(sessionId: "other", text: "x")))
        t.apply(.messageDelta(sessionId: "other", text: "x"), timestamp: ts)
        XCTAssertEqual(t, MacSessionTranscript(sessionID: "s"))
    }

    func testAdoptsIdsFromResumeAndTitle() {
        var t = MacSessionTranscript(sessionID: "row")
        t.hydrate(resume("runtime-1", stored: "stored-1"))
        XCTAssertEqual(t.runtimeID, "runtime-1")
        XCTAssertTrue(t.isRelevant(.messageDelta(sessionId: "stored-1", text: "x")))
        t.apply(.sessionTitle(runtimeSessionId: "runtime-2", storedSessionId: "stored-1", title: "Plan"), timestamp: ts)
        XCTAssertEqual(t.title, "Plan")
        XCTAssertTrue(t.isRelevant(.messageDelta(sessionId: "runtime-2", text: "x")))
    }

    func testToolTurnFlushesTextAndCompletesTheTool() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageStart(sessionId: "s"), timestamp: ts)
        t.apply(.messageDelta(sessionId: "s", text: "Checking"), timestamp: ts)
        t.apply(.toolStart(sessionId: "s", toolName: "terminal", toolInput: "ls", toolID: "t1"), timestamp: ts)
        XCTAssertEqual(t.messages.map(\.role), [.assistant, .tool])
        XCTAssertEqual(t.messages.last?.tool?.status, .running)
        t.apply(.toolComplete(sessionId: "s", toolName: "terminal", toolOutput: "a.txt", toolID: "t1"), timestamp: ts)
        XCTAssertEqual(t.messages.last?.tool?.status, .complete)
        XCTAssertEqual(t.messages.last?.tool?.output, "a.txt")
    }

    func testToolCompleteWithoutIdMatchesNewestRunningByName() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.toolStart(sessionId: "s", toolName: "web", toolInput: nil, toolID: nil), timestamp: ts)
        t.apply(.toolStart(sessionId: "s", toolName: "web", toolInput: nil, toolID: nil), timestamp: ts)
        t.apply(.toolComplete(sessionId: "s", toolName: "web", toolOutput: "ok", toolID: nil), timestamp: ts)
        XCTAssertEqual(t.messages.map { $0.tool?.status }, [.running, .complete])
    }

    func testInterruptedAndErrorEndTheTurn() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageDelta(sessionId: "s", text: "partial"), timestamp: ts)
        XCTAssertEqual(t.apply(.messageInterrupted(sessionId: "s"), timestamp: ts), .turnEnded)
        XCTAssertEqual(t.messages.last?.content, "partial")
        XCTAssertEqual(t.turn, .idle)
        XCTAssertEqual(t.apply(.messageError(sessionId: "s", message: "Model busy"), timestamp: ts), .turnEnded)
        XCTAssertEqual(t.messages.last?.role, .system)
    }

    func testBusyFalseEndsTurnOrWaitsForCard() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.sessionBusy(sessionId: "s", busy: true), timestamp: ts)
        XCTAssertEqual(t.turn, .running)
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        XCTAssertEqual(t.turn, .needsInput)
        XCTAssertEqual(t.apply(.sessionBusy(sessionId: "s", busy: false), timestamp: ts), .turnEnded)
        XCTAssertEqual(t.turn, .needsInput, "a pending card keeps needsInput")
    }

    func testApprovalWithdrawnExpiresTheCard() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        t.apply(.approvalWithdrawn(sessionId: "s", requestId: "r1", reason: "timeout"), timestamp: ts)
        XCTAssertEqual(t.messages.last?.approval?.status, .expired)
        XCTAssertEqual(t.messages.last?.approval?.error, "timeout")
    }

    func testHydrateReplacesRowsAndReadsRunning() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageDelta(sessionId: "s", text: "drift"), timestamp: ts)
        let row = ChatMessage(id: "p1", role: .assistant, content: "persisted", timestamp: ts)
        t.hydrate(resume("s", messages: [row], running: true))
        XCTAssertEqual(t.messages.map(\.id), ["p1"])
        XCTAssertEqual(t.streamingText, "")
        XCTAssertEqual(t.turn, .running)
    }

    func testHydrateShowsPendingApproval() {
        var t = MacSessionTranscript(sessionID: "s")
        let snapshot = SessionRuntimeSnapshot(object: [
            "running": .bool(true),
            "pending_approval": .object(["request_id": .string("r9"), "command": .string("make"), "description": .string("Build")])
        ])
        t.hydrate(SessionResumeResult(sessionId: "s", storedSessionId: nil, messages: [], snapshot: snapshot))
        XCTAssertEqual(t.messages.last?.role, .approval)
        XCTAssertEqual(t.messages.last?.approval?.requestId, "r9")
    }

    func testReplayedApprovalDoesNotDuplicate() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        XCTAssertEqual(t.messages.count, 1)
        XCTAssertEqual(Set(t.messages.map(\.id)).count, t.messages.count)
        XCTAssertEqual(t.turn, .needsInput)
    }

    func testReplayedApprovalKeepsSubmitting() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        t.updateMessage(id: "approval-r1") { $0.approval?.status = .submitting }
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        XCTAssertEqual(t.messages.count, 1)
        XCTAssertEqual(t.messages.last?.approval?.status, .submitting)
    }

    func testRepeatedToolStartSameIDKeepsOneRow() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.toolStart(sessionId: "s", toolName: "terminal", toolInput: "ls", toolID: "t1"), timestamp: ts)
        t.apply(.toolStart(sessionId: "s", toolName: "terminal", toolInput: "ls -la", toolID: "t1"), timestamp: ts)
        XCTAssertEqual(t.messages.count, 1)
        XCTAssertEqual(t.messages.last?.tool?.input, "ls -la")
    }

    func testRepeatedMessageCompleteSameIDKeepsOneRow() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageComplete(sessionId: "s", messageId: "m1", content: "a", reasoning: nil), timestamp: ts)
        t.apply(.messageComplete(sessionId: "s", messageId: "m1", content: "b", reasoning: nil), timestamp: ts)
        XCTAssertEqual(t.messages.count, 1)
        XCTAssertEqual(t.messages.last?.content, "b")
    }

    func testExpiringOnlyPendingApprovalReturnsToIdle() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        XCTAssertEqual(t.turn, .needsInput)
        t.apply(.approvalWithdrawn(sessionId: "s", requestId: "r1", reason: "timeout"), timestamp: ts)
        XCTAssertEqual(t.turn, .idle)
    }

    func testClarifyExpiryReturnsToIdle() {
        var t = MacSessionTranscript(sessionID: "s")
        let q = ClarifyQuestion(id: "q1", question: "Which?", choices: [], multiSelect: false, status: .pending,
                                answer: nil, error: nil, isSyntheticID: false)
        t.apply(.clarify(sessionId: "s", activity: ClarifyActivity(requestId: "c1", questions: [q])), timestamp: ts)
        XCTAssertEqual(t.turn, .needsInput)
        t.apply(.clarifyExpire(sessionId: "s", requestId: "c1", reason: nil), timestamp: ts)
        XCTAssertEqual(t.turn, .idle)
    }

    func testMessageStartFlushesExistingText() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageDelta(sessionId: "s", text: "before"), timestamp: ts)
        t.apply(.messageStart(sessionId: "s"), timestamp: ts)
        XCTAssertEqual(t.messages.map(\.role), [.assistant])
        XCTAssertEqual(t.messages.last?.content, "before")
        XCTAssertEqual(t.streamingText, "")
    }

    func testBusyFalseWithoutCardIsIdle() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.sessionBusy(sessionId: "s", busy: true), timestamp: ts)
        XCTAssertEqual(t.apply(.sessionBusy(sessionId: "s", busy: false), timestamp: ts), .turnEnded)
        XCTAssertEqual(t.turn, .idle)
    }

    func testToolCompleteMatchesByIDWhenNamesShared() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.toolStart(sessionId: "s", toolName: "web", toolInput: nil, toolID: "a"), timestamp: ts)
        t.apply(.toolStart(sessionId: "s", toolName: "web", toolInput: nil, toolID: "b"), timestamp: ts)
        t.apply(.toolComplete(sessionId: "s", toolName: "web", toolOutput: "A", toolID: "a"), timestamp: ts)
        XCTAssertEqual(t.messages.map { $0.tool?.status }, [.complete, .running])
        XCTAssertEqual(t.messages.first?.tool?.output, "A")
    }

    func testUserSentAppendsAndRuns() {
        var t = MacSessionTranscript(sessionID: "s")
        t.userSent("Hi", timestamp: ts)
        XCTAssertEqual(t.messages.last?.role, .user)
        XCTAssertEqual(t.messages.last?.content, "Hi")
        XCTAssertEqual(t.turn, .running)
    }
}

extension SessionRuntimeSnapshot {
    /// The parser init MissingSessionRecoveryTests uses (ConduitMacTests/MissingSessionRecoveryTests.swift:53).
    static func macTestSnapshot(running: Bool?) -> SessionRuntimeSnapshot {
        SessionRuntimeSnapshot(object: running.map { ["running": .bool($0)] } ?? [:])
    }
}

extension ApprovalActivity {
    static func macTest(requestId: String) -> ApprovalActivity {
        ApprovalActivity(sessionId: "s", requestId: requestId, command: "rm -rf build", description: "Delete build output",
                         choices: nil, allowPermanent: false, smartDenied: false, status: .pending, choice: nil, error: nil)
    }
}

final class MacSessionTranscriptFixesTests: XCTestCase {
    private let ts = "2026-10-16T00:00:00Z"

    func testUserSentReturnsTheLocalIdAndRemoveMessageDropsIt() {
        var t = MacSessionTranscript(sessionID: "s")
        let id = t.userSent("hi", timestamp: ts)
        XCTAssertEqual(t.messages.map(\.id), [id])
        XCTAssertEqual(t.turn, .running)
        t.removeMessage(id: id)
        XCTAssertTrue(t.messages.isEmpty)
    }

    func testSettleTurnAfterFailedReadIdlesOrWaitsForInput() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageStart(sessionId: "s"), timestamp: ts)
        t.apply(.messageComplete(sessionId: "s", messageId: "m", content: "x", reasoning: nil), timestamp: ts)
        XCTAssertEqual(t.turn, .running)
        t.settleTurnAfterFailedRead()
        XCTAssertEqual(t.turn, .idle)
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r")), timestamp: ts)
        t.apply(.messageDelta(sessionId: "s", text: "y"), timestamp: ts)
        t.settleTurnAfterFailedRead()
        XCTAssertEqual(t.turn, .needsInput)
    }

    func testAdoptRuntimeKeepsRowsAndTakesTheNewIds() {
        var t = MacSessionTranscript(sessionID: "row")
        t.userSent("hi", timestamp: ts)
        t.adoptRuntime(SessionResumeResult(sessionId: "rt-2", storedSessionId: "st", messages: [ChatMessage(id: "x", role: .assistant, content: "old", timestamp: "")],
                                           snapshot: .macTestSnapshot(running: false)))
        XCTAssertEqual(t.runtimeID, "rt-2")
        XCTAssertTrue(t.isRelevant(.messageDelta(sessionId: "rt-2", text: "a")))
        XCTAssertEqual(t.messages.count, 1, "the optimistic row stays; rows are not replaced")
        XCTAssertEqual(t.messages.first?.role, .user)
    }
}
