import XCTest
@testable import ConduitMac

// FIXTURE-SYNTHETIC: quickask-tool-turn.jsonl was written by hand from the
// StreamEventParserTests sample shapes, not recorded from a live gateway.
// Re-record against a live gateway when one is safe to drive.
final class MacQuickAskModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let sid = "rt-1"
    private let stored = "st-1"

    private func started() -> MacQuickAskModel {
        var m = MacQuickAskModel()
        XCTAssertTrue(m.submit("hello", now: t0))
        m.sessionCreated(runtimeID: sid, storedID: stored)
        m.promptStarted()
        return m
    }

    private func delta(_ text: String, _ id: String? = nil) -> StreamEvent {
        .messageDelta(sessionId: id ?? sid, text: text)
    }

    func testSubmitRejectsBlankAndBusy() {
        var m = MacQuickAskModel()
        XCTAssertFalse(m.submit("   \n", now: t0))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.submit(" hi ", now: t0))
        XCTAssertEqual(m.state, .creating)
        XCTAssertEqual(m.lastPrompt, "hi")
        XCTAssertFalse(m.submit("again", now: t0), "no second send while a turn runs")
    }

    func testFirstSubmitCreatesThenFollowUpSendsOnSameSession() {
        var m = started()
        m.apply(delta("A"), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "Answer", reasoning: nil), now: t0)
        XCTAssertEqual(m.state, .done(text: "Answer"))
        XCTAssertTrue(m.submit("more", now: t0))
        XCTAssertEqual(m.state, .sending, "session exists: no second create")
        XCTAssertEqual(m.runtimeID, sid)
        XCTAssertEqual(m.text, "")
    }

    func testDeltasAccumulateAndToolStatusShows() {
        var m = started()
        m.apply(.messageStart(sessionId: sid), now: t0)
        m.apply(delta("Hel"), now: t0)
        m.apply(.toolStart(sessionId: sid, toolName: "web_search", toolInput: nil), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "Hel", status: "web_search"))
        m.apply(.toolComplete(sessionId: sid, toolName: "web_search", toolOutput: nil), now: t0)
        m.apply(delta("lo"), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "Hello", status: nil))
    }

    func testDeltaBeforePromptAcceptedIsKept() {
        var m = MacQuickAskModel()
        _ = m.submit("q", now: t0)
        m.sessionCreated(runtimeID: sid, storedID: stored)
        m.apply(delta("early"), now: t0)          // event beats the sendPrompt result
        m.promptStarted()
        XCTAssertEqual(m.state, .streaming(text: "early", status: nil))
    }

    func testCompletionReplacesSegmentWithFinalContent() {
        var m = started()
        m.apply(.messageStart(sessionId: sid), now: t0)
        m.apply(delta("Hel"), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: "m", content: "Hello!", reasoning: nil), now: t0)
        XCTAssertEqual(m.state, .done(text: "Hello!"))
        var nilContent = started()
        nilContent.apply(delta("Hi"), now: t0)
        nilContent.apply(.messageComplete(sessionId: sid, messageId: nil, content: nil, reasoning: nil), now: t0)
        XCTAssertEqual(nilContent.state, .done(text: "Hi"), "nil content keeps the streamed text")
    }

    func testSecondSegmentAfterCompletionKeepsEarlierTextAndReopensTheTurn() {
        var m = started()
        m.apply(.messageStart(sessionId: sid), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: "1", content: "Let me check.", reasoning: nil), now: t0)
        m.apply(.messageStart(sessionId: sid), now: t0)
        XCTAssertTrue(m.isTurnRunning, "a start after a completion keeps the turn open")
        m.apply(delta("Found it."), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "Let me check.\n\nFound it.", status: nil))
        m.apply(.messageComplete(sessionId: sid, messageId: "2", content: "Found it, done.", reasoning: nil), now: t0)
        XCTAssertEqual(m.state, .done(text: "Let me check.\n\nFound it, done."))
    }

    func testErrorKeepsPartialInterruptEndsWithPartial() {
        var m = started()
        m.apply(delta("part"), now: t0)
        m.apply(.messageError(sessionId: sid, message: "boom"), now: t0)
        XCTAssertEqual(m.state, .failed(message: "boom", partial: "part", kind: .generic))
        XCTAssertTrue(m.canSubmit, "retry is a submit from failed")
        var i = started()
        i.apply(delta("part"), now: t0)
        i.apply(.messageInterrupted(sessionId: sid), now: t0)
        XCTAssertEqual(i.state, .done(text: "part"))
    }

    func testSessionBusyFalseEndsOnlyAStreamingTurn() {
        var m = started()
        m.apply(.sessionBusy(sessionId: sid, busy: false), now: t0)
        XCTAssertEqual(m.state, .done(text: ""), "a streaming turn ends on the idle notice")
        var sending = MacQuickAskModel()
        _ = sending.submit("q", now: t0)
        sending.sessionCreated(runtimeID: sid, storedID: nil)
        sending.apply(.sessionBusy(sessionId: sid, busy: false), now: t0)
        XCTAssertEqual(sending.state, .sending, "an idle notice before the turn starts is not an end")
        var streaming = started()
        streaming.apply(delta("x"), now: t0)
        streaming.apply(.sessionBusy(sessionId: sid, busy: false), now: t0)
        XCTAssertEqual(streaming.state, .done(text: "x"))
    }

    func testNeedsInputFromApprovalClarifyAndPrompt() {
        for event in [StreamEvent.approval(sessionId: sid, activity: .macTestStub),
                      .clarify(sessionId: sid, activity: .macTestStub),
                      .inputPrompt(sessionId: sid, activity: .macTestStub)] {
            var m = started()
            m.apply(delta("partial"), now: t0)
            m.apply(event, now: t0)
            XCTAssertEqual(m.state, .needsInput(text: "partial"))
            m.apply(delta("ignored"), now: t0)
            XCTAssertEqual(m.state, .needsInput(text: "partial"), "the panel never continues past a prompt")
        }
    }

    func testForeignSessionEventsAreIgnored() {
        var m = started()
        m.apply(delta("other", "someone-else"), now: t0)
        m.apply(.messageError(sessionId: "someone-else", message: "x"), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "", status: nil))
    }

    func testRuntimeAndStoredIdsBothMatch() {
        var m = started()
        m.apply(delta("a", stored), now: t0)
        m.apply(delta("b", sid), now: t0)
        XCTAssertEqual(m.text, "ab")
        XCTAssertTrue(m.owns(stored) && m.owns(sid) && !m.owns("zzz"))
        XCTAssertEqual(m.promoteID, stored)
    }

    func testSessionTitleEventLearnsMissingStoredId() {
        var m = MacQuickAskModel()
        _ = m.submit("q", now: t0)
        m.sessionCreated(runtimeID: sid, storedID: nil)
        XCTAssertEqual(m.promoteID, sid)
        m.apply(.sessionTitle(runtimeSessionId: sid, storedSessionId: stored, title: "T"), now: t0)
        XCTAssertEqual(m.promoteID, stored)
    }

    func testFailBeforeStreamingKeepsKindAndPrompt() {
        var m = MacQuickAskModel()
        _ = m.submit("q", now: t0)
        m.fail("limit", kind: .sessionLimit, now: t0)
        XCTAssertEqual(m.state, .failed(message: "limit", partial: "", kind: .sessionLimit))
        XCTAssertEqual(m.lastPrompt, "q")
        XCTAssertNil(m.runtimeID)
        XCTAssertTrue(m.submit("q", now: t0), "retry after a failed create creates again")
        XCTAssertEqual(m.state, .creating)
    }

    func testRestoreWithinWindowKeepsExchange() {
        var m = started()
        m.apply(delta("x"), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "X", reasoning: nil), now: t0)
        m.panelClosed(now: t0.addingTimeInterval(10))
        m.panelOpened(now: t0.addingTimeInterval(10 + 119))
        XCTAssertEqual(m.state, .done(text: "X"))
        XCTAssertEqual(m.runtimeID, sid)
    }

    func testRestoreAfterWindowOpensEmptyAndForgetsSession() {
        var m = started()
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "X", reasoning: nil), now: t0)
        m.panelClosed(now: t0)
        m.panelOpened(now: t0.addingTimeInterval(MacQuickAskModel.restoreWindow + 1))
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.runtimeID)
        XCTAssertFalse(m.owns(sid))
        XCTAssertFalse(m.hasExchange)
    }

    func testEventsDuringHiddenTurnRefreshActivity() {
        var m = started()
        m.panelClosed(now: t0)
        m.apply(delta("late"), now: t0.addingTimeInterval(100))
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "late", reasoning: nil),
                now: t0.addingTimeInterval(200))
        m.panelOpened(now: t0.addingTimeInterval(300))
        XCTAssertEqual(m.state, .done(text: "late"), "120 s counts from the last activity, not the hide")
    }

    func testResetAndDetach() {
        var m = started()
        m.apply(delta("x"), now: t0)
        m.reset()
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.runtimeID)
        var d = started()
        d.detach()
        XCTAssertEqual(d.state, .idle)
        XCTAssertFalse(d.owns(sid), "after promotion the main chat owns the session")
    }

    func testRecordedToolTurnTrace() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quickask-tool-turn.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 4)
        var m = MacQuickAskModel()
        _ = m.submit("trace", now: t0)
        m.sessionCreated(runtimeID: "trace-session", storedID: nil)
        m.promptStarted()
        var sawToolStatus = false
        for line in lines {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let event = StreamEventParser.parse(params: AnyCodable.from(obj)) {
                m.apply(event, now: t0)
                if case .streaming(_, let status?) = m.state, status == "web_search" { sawToolStatus = true }
            }
        }
        XCTAssertTrue(sawToolStatus, "the tool name surfaced as status during the turn")
        XCTAssertEqual(m.state, .done(text: "Let me check.\n\nThe current macOS is macOS 15."))
    }
}

extension ApprovalActivity {
    static var macTestStub: ApprovalActivity {
        ApprovalActivity(
            sessionId: "rt-1", command: "echo hi", description: "Run command", choices: nil,
            allowPermanent: false, smartDenied: false, status: .pending, choice: nil, error: nil)
    }
}

extension ClarifyActivity {
    static var macTestStub: ClarifyActivity {
        ClarifyActivity(requestId: "request", question: "Choose", choices: [])
    }
}

extension InputPromptActivity {
    static var macTestStub: InputPromptActivity {
        InputPromptActivity(requestId: "srq-1", sessionId: "rt-1", kind: .sudo)
    }
}
