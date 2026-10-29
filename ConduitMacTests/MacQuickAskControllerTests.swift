import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskControllerTests: XCTestCase {
    private final class FakePanel: MacQuickAskPanelHosting {
        var isVisible = false
        var shows = 0, hides = 0
        func show() { isVisible = true; shows += 1 }
        func hide() { isVisible = false; hides += 1 }
        func toggle() { isVisible ? hide() : show() }
    }

    private struct Calls {
        var creates = 0
        var sends: [(String, String)] = []
        var cancels: [String] = []
        var opens: [String] = []
        var activations = 0
        var refreshes = 0
        var order: [String] = []
    }

    private var hub = MacStreamEventHub()
    private var calls = Calls()
    private var clock = Date(timeIntervalSince1970: 5_000)
    private var panel = FakePanel()
    private var connection = MacQuickAskConnection.connected
    private var profile = "default"
    private var createResult: Result<(sessionId: String, storedSessionId: String?, profile: String?), Error> =
        .success(("rt", "st", "default"))
    private var sendResult: Result<PromptSubmissionOutcome, Error> = .success(.accepted)

    private func controller() -> MacQuickAskController {
        calls = Calls()
        hub = MacStreamEventHub()
        let c = MacQuickAskController(hub: hub)
        c.panel = panel
        c.environment = MacQuickAskEnvironment(
            connection: { [unowned self] in connection },
            activeProfile: { [unowned self] in profile },
            createSession: { [unowned self] in calls.creates += 1; return try createResult.get() },
            sendPrompt: { [unowned self] id, text in calls.sends.append((id, text)); return try sendResult.get() },
            cancel: { [unowned self] id in calls.cancels.append(id) },
            openSession: { [unowned self] id in calls.opens.append(id); calls.order.append("open") },
            activateMainWindow: { [unowned self] in calls.activations += 1; calls.order.append("activate") },
            refreshSessions: { [unowned self] in calls.refreshes += 1 },
            now: { [unowned self] in clock })
        c.connectionChanged(connection)
        return c
    }

    private func settle(_ until: @autoclosure () -> Bool) {
        XCTAssertTrue(HostedTestSupport.waitUntil { until() })
    }

    private func isFailed(_ c: MacQuickAskController) -> Bool {
        if case .failed = c.model.state { return true }
        return false
    }

    func testDismissWithoutSendingCreatesNoSession() {
        let c = controller()
        c.show(); c.hide(); c.panelDidDismiss()
        HostedTestSupport.settle(0.05)
        XCTAssertEqual(calls.creates, 0)
    }

    func testFirstReturnCreatesExactlyOneSessionThenSends() {
        let c = controller()
        c.show()
        c.draft = "what is 2+2"
        c.submit()
        settle(c.model.state != .creating && c.model.state != .sending)
        XCTAssertEqual(calls.creates, 1)
        XCTAssertEqual(calls.sends.count, 1)
        XCTAssertEqual(calls.sends.first?.0, "rt")
        XCTAssertEqual(calls.sends.first?.1, "what is 2+2")
        XCTAssertEqual(calls.refreshes, 1)
        XCTAssertEqual(c.draft, "")
    }

    func testFollowUpReusesSessionAndDoesNotCreate() {
        let c = controller()
        c.draft = "one"; c.submit()
        settle(calls.sends.count == 1)
        c.handle(.messageComplete(sessionId: "rt", messageId: nil, content: "A", reasoning: nil))
        c.draft = "two"; c.submit()
        settle(calls.sends.count == 2)
        XCTAssertEqual(calls.creates, 1)
        XCTAssertEqual(calls.sends.last?.0, "rt")
    }

    func testHubEventsReachTheModel() {
        let c = controller()
        c.subscribeToHub()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        hub.publish(.messageDelta(sessionId: "rt", text: "Hi"))
        XCTAssertEqual(c.model.text, "Hi")
        hub.publish(.messageDelta(sessionId: "other", text: "NO"))
        XCTAssertEqual(c.model.text, "Hi")
    }

    func testSubscribeIsIdempotentAndUnsubscribeStopsDelivery() {
        let c = controller()
        c.subscribeToHub(); c.subscribeToHub()
        XCTAssertEqual(hub.subscriberCount, 1)
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.unsubscribeFromHub()
        XCTAssertEqual(hub.subscriberCount, 0)
        hub.publish(.messageDelta(sessionId: "rt", text: "late"))
        XCTAssertEqual(c.model.text, "")
    }

    func testHideKeepsModelAndReopenWithinWindowRestores() {
        let c = controller()
        c.show()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.handle(.messageComplete(sessionId: "rt", messageId: nil, content: "A", reasoning: nil))
        c.hide(); c.panelDidDismiss()
        clock = clock.addingTimeInterval(60)
        c.show()
        XCTAssertEqual(c.model.state, .done(text: "A"))
        XCTAssertEqual(calls.cancels, [], "Esc never stops the turn")
    }

    func testReopenAfterWindowOpensEmpty() {
        let c = controller()
        c.show()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.handle(.messageComplete(sessionId: "rt", messageId: nil, content: "A", reasoning: nil))
        c.hide(); c.panelDidDismiss()
        clock = clock.addingTimeInterval(MacQuickAskModel.restoreWindow + 1)
        c.show()
        XCTAssertEqual(c.model.state, .idle)
    }

    func testNewConversationDiscardsExchange() {
        let c = controller()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.newConversation()
        XCTAssertEqual(c.model.state, .idle)
        c.draft = "q2"; c.submit()
        settle(calls.creates == 2)
    }

    func testNewConversationDuringCreateDropsTheLateSession() {
        let c = controller()
        c.draft = "q"; c.submit()
        c.newConversation()
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(c.model.state, .idle, "a create that lands after Cmd-N must not resurrect the exchange")
        XCTAssertNil(c.model.runtimeID)
    }

    func testPromoteActivatesThenOpensStoredIdOnceAndHides() {
        let c = controller()
        c.show()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.promote()
        XCTAssertEqual(calls.order, ["activate", "open"])
        XCTAssertEqual(calls.opens, ["st"])
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(c.model.state, .idle, "the main chat owns the session now")
        c.promote()
        XCTAssertEqual(calls.opens, ["st"], "a second promote has nothing to open")
    }

    func testPromoteWithNothingToOpenDoesNothing() {
        let c = controller()
        c.promote()
        XCTAssertEqual(calls.activations, 0)
    }

    func testNeedsInputKeepsPanelAndPromoteStillWorks() {
        let c = controller()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.handle(.approval(sessionId: "rt", activity: .macTestStub))
        XCTAssertEqual(c.model.state, .needsInput(text: ""))
        c.promote()
        XCTAssertEqual(calls.opens, ["st"])
    }

    func testSessionLimit4090KeepsPromptAndOffersRetry() {
        let c = controller()
        createResult = .failure(RpcError(code: 4090, message: "max concurrent sessions"))
        c.draft = "keep me"; c.submit()
        settle(isFailed(c))
        guard case .failed(_, _, let kind) = c.model.state else { return XCTFail() }
        XCTAssertEqual(kind, .sessionLimit)
        XCTAssertEqual(c.draft, "keep me", "the typed prompt is preserved")
        XCTAssertEqual(calls.sends.count, 0)
        createResult = .success(("rt", "st", "default"))
        c.retry()
        settle(calls.sends.count == 1)
        XCTAssertEqual(calls.sends.first?.1, "keep me")
    }

    func testClassifySeparatesLimitFromNotOwned() {
        XCTAssertEqual(MacQuickAskController.classify(RpcError(code: 4090, message: "m")).kind, .sessionLimit)
        XCTAssertEqual(MacQuickAskController.classify(RpcError(code: 4090, message: "m", reason: "SESSION_NOT_OWNED")).kind, .generic)
        XCTAssertEqual(MacQuickAskController.classify(HermesError.notConnected).kind, .generic)
    }

    func testSendFailureKeepsPromptAndShowsMessage() {
        let c = controller()
        sendResult = .failure(HermesError.connectionClosed)
        c.draft = "q"; c.submit()
        settle(isFailed(c))
        XCTAssertEqual(c.draft, "q")
        XCTAssertNotNil(c.model.runtimeID, "the session exists; Retry sends on it without a second create")
        sendResult = .success(.accepted)
        c.retry()
        settle(calls.sends.count == 2)
        XCTAssertEqual(calls.creates, 1)
    }

    func testProfileMismatchFailsWithoutSending() {
        let c = controller()
        createResult = .success(("rt", "st", "work"))
        c.draft = "q"; c.submit()
        settle(isFailed(c))
        XCTAssertEqual(calls.sends.count, 0)
        XCTAssertNil(c.model.runtimeID, "a session created in another profile is never adopted")
    }

    func testDisconnectedBlocksSubmit() {
        connection = .disconnected
        let c = controller()
        c.draft = "q"; c.submit()
        XCTAssertEqual(calls.creates, 0)
        XCTAssertEqual(c.draft, "q")
        XCTAssertEqual(c.model.state, .idle)
    }

    func testConnectionLossMidTurnDoesNotCancelAndKeepsPromoteAvailable() {
        let c = controller()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.connectionChanged(.disconnected)
        HostedTestSupport.settle(0.05)
        XCTAssertEqual(calls.cancels, [])
        XCTAssertTrue(c.model.isTurnRunning)
        XCTAssertNotNil(c.model.promoteID)
    }

    func testStopCancelsRunningTurnOnly() {
        let c = controller()
        c.stop()
        HostedTestSupport.settle(0.05)
        XCTAssertEqual(calls.cancels, [])
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.stop()
        settle(calls.cancels == ["rt"])
    }

    func testToggleHidesWhenVisible() {
        let c = controller()
        c.toggle(); XCTAssertTrue(panel.isVisible)
        c.toggle(); XCTAssertFalse(panel.isVisible)
    }

    // MARK: Stream subscription and isolation (review round 1)

    func testIdleControllerIsNotOnTheStream() {
        let c = controller()
        XCTAssertEqual(hub.subscriberCount, 0)
        c.show(); c.hide(); c.panelDidDismiss()
        XCTAssertEqual(hub.subscriberCount, 0, "opening and dismissing without sending subscribes nothing")
    }

    func testSubscribesWhenASessionIsCreatedAndDropsWhenTheExchangeEnds() {
        let c = controller()
        c.show()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        XCTAssertEqual(hub.subscriberCount, 1)
        c.newConversation()
        XCTAssertEqual(hub.subscriberCount, 0)
        c.draft = "again"; c.submit()
        settle(calls.sends.count == 2)
        XCTAssertEqual(hub.subscriberCount, 1)
        c.promote()
        XCTAssertEqual(hub.subscriberCount, 0, "promotion hands the session to the main chat")
    }

    func testReopenAfterTheWindowExpiresDropsTheSubscription() {
        let c = controller()
        c.show()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        c.hide(); c.panelDidDismiss()
        XCTAssertEqual(hub.subscriberCount, 1)
        clock = clock.addingTimeInterval(MacQuickAskModel.restoreWindow + 1)
        c.show()
        XCTAssertEqual(c.model.state, .idle)
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testForeignAndIgnoredEventsDoNotPublishTheModel() {
        let c = controller()
        c.subscribeToHub()
        var publishes = 0
        let sink = c.objectWillChange.sink { publishes += 1 }
        defer { sink.cancel() }
        // Idle: nothing is owned.
        hub.publish(.messageDelta(sessionId: "main-chat", text: "x"))
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        let before = publishes
        for _ in 0..<20 { hub.publish(.messageDelta(sessionId: "main-chat", text: "x")) }
        hub.publish(.sessionBusy(sessionId: "main-chat", busy: false))
        XCTAssertEqual(publishes, before, "a delta of the main chat must not invalidate the panel")
        XCTAssertEqual(c.model.text, "")
        hub.publish(.messageDelta(sessionId: "rt", text: "mine"))
        XCTAssertEqual(c.model.text, "mine")
        XCTAssertGreaterThan(publishes, before)
    }

    func testEventsUnderTheStoredIdReachTheModelAndOtherSessionsDoNot() {
        let c = controller()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        hub.publish(.messageDelta(sessionId: "st", text: "via stored"))
        XCTAssertEqual(c.model.text, "via stored")
        hub.publish(.messageDelta(sessionId: "rt-main", text: " NO"))
        XCTAssertEqual(c.model.text, "via stored")
    }

    func testOpenableIDResolvesARuntimeAliasToTheCatalogRow() {
        let row = SessionSummary(
            id: "stored-1", alternateIds: ["runtime-1"], title: "t", model: "", updatedLabel: "",
            profile: "default", source: .chat, isActive: false, isArchived: false)
        XCTAssertEqual(MacQuickAskController.openableID("runtime-1", in: [row]), "stored-1")
        XCTAssertEqual(MacQuickAskController.openableID("stored-1", in: [row]), "stored-1")
        XCTAssertEqual(MacQuickAskController.openableID("runtime-2", in: [row]), "runtime-2", "no row: the id goes through for resume")
        XCTAssertEqual(MacQuickAskController.openableID("x", in: []), "x")
    }

    func testPanelKeyIsFalseWithoutARealPanel() {
        let c = controller()
        XCTAssertFalse(c.isPanelKey)
    }

    func testChromeStringsFromTheGatewayAreSanitized() {
        let c = controller()
        c.subscribeToHub()
        c.draft = "q"; c.submit()
        settle(calls.sends.count == 1)
        hub.publish(.toolStart(sessionId: "rt", toolName: "term\u{202E}inal\u{200B}\n", toolInput: nil))
        guard case .streaming(_, let status) = c.model.state else { return XCTFail("streaming expected") }
        XCTAssertEqual(status, "terminal")
        hub.publish(.messageError(sessionId: "rt", message: "bad\u{2028}\u{202D}thing\u{0007}"))
        guard case .failed(let message, _, _) = c.model.state else { return XCTFail("failed expected") }
        XCTAssertEqual(message, "bad thing", "U+2028 becomes a space under the unified sanitizer (was dropped by the Quick Ask one)")
    }

    func testProfileNameInTheMismatchMessageIsSanitized() {
        let c = controller()
        createResult = .success(("rt", "st", "ev\u{202E}il\u{200B}"))
        c.draft = "q"; c.submit()
        settle(isFailed(c))
        guard case .failed(let message, _, _) = c.model.state else { return XCTFail("failed expected") }
        XCTAssertTrue(message.contains("evil"), message)
        XCTAssertFalse(message.unicodeScalars.contains("\u{202E}"))
        XCTAssertFalse(message.unicodeScalars.contains("\u{200B}"))
    }
}
