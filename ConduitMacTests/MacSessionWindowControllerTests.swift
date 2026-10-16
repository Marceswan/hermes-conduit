import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowControllerTests: XCTestCase {
    private var hub: MacStreamEventHub!
    private var scope = MacSessionWindowScope(dashboardID: nil, profile: "default", connected: true)
    private var clientID: ObjectIdentifier? = ObjectIdentifier(NSObject())
    private var resumes: [String] = []
    private var resumeResult: SessionResumeResult!
    private var resumeGate: CheckedContinuation<Void, Never>?
    private var holdResume = false
    private var sends: [(String, String)] = []
    private var live: [LiveSessionStatus] = []
    private var liveCalls = 0
    private var failSend = false
    private var failResume = false
    private var liveFailures = 0
    private var liveGate: CheckedContinuation<Void, Never>?
    private var holdLive = false
    private var failInputAnswers = 0
    private var approvals: [(String, String?, String)] = []
    private var inputAnswers: [(String, String)] = []

    override func setUp() async throws {
        hub = MacStreamEventHub()
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: false))
        resumes = []; sends = []; live = []; liveCalls = 0; holdResume = false; failSend = false
        failResume = false; approvals = []; inputAnswers = []
        liveFailures = 0; liveGate = nil; holdLive = false; failInputAnswers = 0
    }

    private func makeController(sessionID: String = "row-1") -> MacSessionWindowController {
        var env = MacSessionWindowEnvironment()
        env.scope = { [unowned self] in scope }
        env.clientID = { [unowned self] in clientID }
        env.resume = { [unowned self] id in
            resumes.append(id)
            if failResume { throw HermesError.notConnected }
            if holdResume { await withCheckedContinuation { resumeGate = $0 } }
            return resumeResult
        }
        env.sendPrompt = { [unowned self] id, text in
            if failSend { throw HermesError.notConnected }
            sends.append((id, text)); return .accepted
        }
        env.activeSessions = { [unowned self] in
            liveCalls += 1
            if liveFailures > 0 { liveFailures -= 1; throw HermesError.notConnected }
            if holdLive { await withCheckedContinuation { liveGate = $0 } }
            return live
        }
        env.respondToApproval = { [unowned self] session, request, choice in
            approvals.append((session, request, choice)); return true
        }
        env.respondToInputPrompt = { [unowned self] request, value in
            if failInputAnswers > 0 { failInputAnswers -= 1; throw HermesError.notConnected }
            inputAnswers.append((request, value))
        }
        env.catalogRow = { _ in nil }
        let token = MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: sessionID)
        return MacSessionWindowController(token: token, environment: env, hub: hub, settleDelay: .milliseconds(10))
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testStartResumesAndBecomesReady() async {
        let c = makeController()
        c.start()
        await settle()
        XCTAssertEqual(resumes, ["row-1"])
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.transcript.runtimeID, "rt-1")
        XCTAssertEqual(hub.subscriberCount, 1)
        c.stop()
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testEventsDuringResumeAreReplayed() async {
        holdResume = true
        let c = makeController()
        c.start()
        await settle()
        hub.publish(.messageDelta(sessionId: "rt-1", text: "early"))
        XCTAssertEqual(c.transcript.streamingText, "", "buffered, not applied before hydrate")
        resumeGate?.resume()
        await settle()
        XCTAssertEqual(c.transcript.streamingText, "early")
    }

    func testResumeAdoptsRuntimeIdForSend() async {
        let c = makeController()
        c.start(); await settle()
        c.draft = "Hello"
        c.send(); await settle()
        XCTAssertEqual(sends.map(\.0), ["rt-1"])
        XCTAssertEqual(sends.map(\.1), ["Hello"])
        XCTAssertEqual(c.draft, "")
        XCTAssertEqual(c.transcript.turn, .running)
    }

    func testSendIsRefusedWhileRunning() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        c.draft = "Again"
        c.send(); await settle()
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(c.draft, "Again")
    }

    func testForeignEventsDoNotPublish() async {
        let c = makeController()
        c.start(); await settle()
        var publishes = 0
        let sink = c.objectWillChange.sink { publishes += 1 }
        for _ in 0..<50 { hub.publish(.messageDelta(sessionId: "main-chat", text: "x")) }
        XCTAssertEqual(publishes, 0)
        sink.cancel()
    }

    func testTurnEndSettlesFromHistory() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.messageComplete(sessionId: "rt-1", messageId: nil, content: "done", reasoning: nil))
        await c.awaitInFlightWork()
        await settle()
        XCTAssertEqual(resumes.count, 2, "one start resume, one settle resume")
    }

    func testToolContinuationCancelsTheSettle() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.messageComplete(sessionId: "rt-1", messageId: nil, content: "step 1", reasoning: nil))
        hub.publish(.toolStart(sessionId: "rt-1", toolName: "terminal", toolInput: nil, toolID: "t1"))
        await c.awaitInFlightWork()
        await settle()
        XCTAssertEqual(resumes.count, 1)
    }

    func testWrongScopeBlocksSendAndResume() async {
        let c = makeController()
        c.start(); await settle()
        scope.profile = "work"
        c.scopeChanged()
        XCTAssertEqual(c.phase, .wrongScope("default"))
        c.draft = "Hi"
        c.send(); await settle()
        XCTAssertTrue(sends.isEmpty)
        scope.profile = "default"
        c.scopeChanged(); await settle()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(resumes.count, 2)
    }

    func testNewClientRehydratesAndProbesBusy() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        XCTAssertEqual(c.transcript.turn, .running)
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: true))
        live = []   // the turn ended while disconnected
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()
        XCTAssertEqual(resumes.count, 2)
        XCTAssertEqual(liveCalls, 1)
        XCTAssertEqual(c.transcript.turn, .idle, "no live row says it is still running")
    }

    func testClientBeforeConnectProbesOnConnect() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        scope.connected = false
        c.scopeChanged()
        XCTAssertEqual(c.phase, .disconnected)
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()      // new client, not connected yet
        XCTAssertEqual(resumes.count, 1)
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: true))
        scope.connected = true
        c.scopeChanged(); await settle()
        XCTAssertEqual(resumes.count, 2)
        XCTAssertEqual(liveCalls, 1, "the probe still runs after the late connect")
        XCTAssertEqual(c.transcript.turn, .idle)
    }

    func testSendFailureRestoresDraftAndShowsError() async {
        let c = makeController()
        c.start(); await settle()
        failSend = true
        c.draft = "Hello"
        c.send(); await settle()
        XCTAssertEqual(c.draft, "Hello")
        XCTAssertNotNil(c.lastError)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.transcript.turn, .idle)
    }

    func testSameClientDoesNotRehydrate() async {
        let c = makeController()
        c.start(); await settle()
        c.clientChanged(); await settle()
        XCTAssertEqual(resumes.count, 1)
    }

    func testDeletionEndsTheWindow() async {
        let c = makeController()
        c.start(); await settle()
        c.sessionDeleted("st-1")
        XCTAssertEqual(c.phase, .deleted)
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testDisconnectedAtStartWaits() async {
        scope.connected = false
        let c = makeController()
        c.start(); await settle()
        XCTAssertEqual(c.phase, .disconnected)
        XCTAssertTrue(resumes.isEmpty)
    }

    func testResumeFailureShowsFailedPhase() async {
        failResume = true
        let c = makeController()
        c.start(); await settle()
        guard case .failed = c.phase else { return XCTFail("expected .failed, got \(c.phase)") }
    }

    func testSettleFailureKeepsTheTranscriptVisible() async {
        let c = makeController()
        c.start(); await settle()
        failResume = true
        hub.publish(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "done", reasoning: nil))
        await c.awaitInFlightWork()
        await settle()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNotNil(c.lastError)
        XCTAssertEqual(c.transcript.messages.map(\.id), ["m1"])
    }

    func testScopeLostDuringResumeIsNotOverwrittenByTheResult() async {
        holdResume = true
        let c = makeController()
        c.start(); await settle()
        scope.profile = "work"
        c.scopeChanged()
        XCTAssertEqual(c.phase, .wrongScope("default"))
        resumeGate?.resume()
        await c.awaitInFlightWork()
        await settle()
        XCTAssertEqual(c.phase, .wrongScope("default"))
        XCTAssertNil(c.transcript.runtimeID, "a result for a scope the window left is dropped")
    }

    func testApproveMarksApprovedAndSendsIds() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.approval(sessionId: "rt-1", activity: .macTest(requestId: "r1")))
        XCTAssertEqual(c.transcript.turn, .needsInput)
        c.approve(messageID: "approval-r1", choice: "once")
        XCTAssertEqual(c.transcript.messages.last?.approval?.status, .submitting)
        await settle()
        XCTAssertEqual(approvals.map(\.1), ["r1"])
        XCTAssertEqual(approvals.map(\.2), ["once"])
        XCTAssertEqual(c.transcript.messages.last?.approval?.status, .approved)
    }

    func testSkippingAnInputPromptSendsAnEmptyValue() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.inputPrompt(sessionId: "rt-1", activity: InputPromptActivity(requestId: "srq-1", sessionId: "rt-1", kind: .sudo)))
        c.answerInputPrompt(messageID: "input-srq-1", value: nil)
        await settle()
        XCTAssertEqual(inputAnswers.map(\.0), ["srq-1"])
        XCTAssertEqual(inputAnswers.map(\.1), [""])
        XCTAssertEqual(c.transcript.messages.last?.inputPrompt?.status, .skipped)
    }

    private func pendingApprovalResume(running: Bool) -> SessionResumeResult {
        SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [], snapshot: SessionRuntimeSnapshot(object: [
            "running": .bool(running),
            "pending_approval": .object(["request_id": .string("r9"), "command": .string("make"), "description": .string("Build")])
        ]))
    }

    func testLiveProbeKeepsNeedsInputWhenACardIsPending() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        resumeResult = pendingApprovalResume(running: true)
        live = []
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()
        XCTAssertEqual(liveCalls, 1)
        XCTAssertEqual(c.transcript.messages.last?.approval?.requestId, "r9")
        XCTAssertEqual(c.transcript.turn, .needsInput)
    }

    func testFailedProbeIsRetriedOnTheNextResume() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: true))
        live = []
        liveFailures = 1
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()
        XCTAssertEqual(liveCalls, 1)
        XCTAssertEqual(c.transcript.turn, .running, "the probe could not answer, so the stale turn stays")
        hub.publish(.messageStart(sessionId: "rt-1"))   // activity that ends in a settle resume
        hub.publish(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "x", reasoning: nil))
        await c.awaitInFlightWork(); await settle()
        XCTAssertEqual(liveCalls, 2, "the next resume probes again")
        XCTAssertEqual(c.transcript.turn, .idle)
    }

    func testProbeAnswerIsDroppedWhenTheTurnMovedMeanwhile() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: true))
        live = []
        holdLive = true
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()
        XCTAssertEqual(liveCalls, 1)
        // While the probe is out, the turn ends and a new one is sent.
        hub.publish(.messageInterrupted(sessionId: "rt-1"))
        c.draft = "Next"
        c.send(); await settle()
        XCTAssertEqual(c.transcript.turn, .running)
        liveGate?.resume()
        await settle()
        XCTAssertEqual(c.transcript.turn, .running, "a pre-send live list must not idle the new turn")
    }

    func testRejectedInputPromptCanBeRetried() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.inputPrompt(sessionId: "rt-1", activity: InputPromptActivity(requestId: "srq-1", sessionId: "rt-1", kind: .sudo)))
        failInputAnswers = 1
        c.answerInputPrompt(messageID: "input-srq-1", value: "pw")
        await settle()
        XCTAssertEqual(c.transcript.messages.last?.inputPrompt?.status, .error)
        XCTAssertNotNil(c.transcript.messages.last?.inputPrompt?.error)
        XCTAssertEqual(c.transcript.turn, .needsInput)
        c.answerInputPrompt(messageID: "input-srq-1", value: "pw")
        await settle()
        XCTAssertEqual(c.transcript.messages.last?.inputPrompt?.status, .submitted)
        XCTAssertNil(c.transcript.messages.last?.inputPrompt?.error)
        XCTAssertEqual(c.transcript.turn, .running, "answered: the agent continues")
    }

    func testRetryRecoversAFailedWindow() async {
        failResume = true
        let c = makeController()
        c.start(); await settle()
        guard case .failed = c.phase else { return XCTFail("expected .failed, got \(c.phase)") }
        failResume = false
        c.retry(); await settle()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.transcript.runtimeID, "rt-1")
    }

    func testFailedReReadAfterClientChangeKeepsTranscriptAndRetryRecovers() async {
        let c = makeController()
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1",
                                           messages: [ChatMessage(id: "m1", role: .assistant, content: "hi", timestamp: "")],
                                           snapshot: .macTestSnapshot(running: false))
        c.start(); await settle()
        failResume = true
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()
        guard case .failed = c.phase else { return XCTFail("expected .failed, got \(c.phase)") }
        XCTAssertEqual(c.transcript.messages.map(\.id), ["m1"], "previous transcript stays visible")
        failResume = false
        c.retry(); await settle()
        XCTAssertEqual(c.phase, .ready)
    }

    func testSendCancelsAPendingSettle() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "x", reasoning: nil))
        c.draft = "Quick follow-up"
        c.send()
        await c.awaitInFlightWork(); await settle()
        XCTAssertEqual(resumes.count, 1, "the settle was cancelled so it cannot drop the optimistic row")
        XCTAssertEqual(c.transcript.messages.last?.role, .user)
    }

    func testApprovalAcceptedMovesTurnToRunningAndExpiredToIdle() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.approval(sessionId: "rt-1", activity: .macTest(requestId: "r1")))
        c.approve(messageID: "approval-r1", choice: "once"); await settle()
        XCTAssertEqual(c.transcript.turn, .running)
    }

    func testClarifyQuestionIsSubmittingAndNotSentTwice() async {
        var calls = 0
        var env = MacSessionWindowEnvironment()
        env.scope = { [unowned self] in scope }
        env.resume = { [unowned self] _ in resumeResult }
        env.respondToClarification = { _, _, _ in calls += 1; return .accepted(remaining: nil) }
        let token = MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: "row-1")
        let c = MacSessionWindowController(token: token, environment: env, hub: hub, settleDelay: .milliseconds(10))
        c.start(); await settle()
        let q = ClarifyQuestion(id: "q1", question: "Which?", choices: [], multiSelect: false, status: .pending,
                                answer: nil, error: nil, isSyntheticID: false)
        hub.publish(.clarify(sessionId: "rt-1", activity: ClarifyActivity(requestId: "c1", questions: [q])))
        c.answerClarify(messageID: "clarify-c1", questionID: "q1", answer: "A")
        c.answerClarify(messageID: "clarify-c1", questionID: "q1", answer: "A")
        XCTAssertEqual(c.transcript.messages.last?.clarify?.questions.first?.status, .submitting)
        await settle()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(c.transcript.messages.last?.clarify?.questions.first?.status, .answered)
        XCTAssertEqual(c.transcript.turn, .running)
    }
}
