import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationCoordinatorTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var prefs: MacNotificationPreferences!
    private var center: FakeNotificationCenter!
    private var scheduler: FakeScheduler!
    private var coordinator: MacNotificationCoordinator!
    private var visibility = MacNotificationVisibility.away
    private var clock = Date(timeIntervalSince1970: 2_000_000)
    private var nextEvent = 1

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        prefs = MacNotificationPreferences(defaults: suite.defaults)
        center = FakeNotificationCenter()
        scheduler = FakeScheduler()
        visibility = .away
        clock = Date(timeIntervalSince1970: 2_000_000)
        nextEvent = 1
        coordinator = MacNotificationCoordinator(
            center: center, preferences: prefs, scheduler: scheduler,
            visibility: { [unowned self] _ in self.visibility }, now: { [unowned self] in self.clock }
        )
    }

    override func tearDown() async throws {
        await coordinator.drain()
        coordinator = nil
        HostedTestSupport.dropSuite(suite)
    }

    // MARK: helpers
    private func send(_ kind: MacNotificationEvent.Kind, session: MacNotificationSession = makeSession(), id: Int? = nil) {
        defer { nextEvent += 1 }
        coordinator.handle(MacNotificationEvent(eventId: id ?? nextEvent, session: session, kind: kind))
    }
    private func turn(_ seconds: TimeInterval, turnId: String = "t1", outcome: MacNotificationEvent.Outcome = .completed,
                      preview: String? = "Done.", session: MacNotificationSession = makeSession()) async {
        send(.turnStarted(turnId: turnId, at: clock), session: session)
        send(.turnFinished(turnId: turnId, at: clock.addingTimeInterval(seconds), outcome: outcome, replyPreview: preview), session: session)
        await coordinator.drain()
    }

    // MARK: tests
    func testShortTurnDoesNotNotify() async {
        await turn(29.9)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testThresholdTurnPostsDone() async {
        await turn(30)
        XCTAssertEqual(center.identifiers, ["conduit.done.key-1"])
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_DONE")
        XCTAssertEqual(center.added[0].content.body, "Done.")
    }

    func testThresholdFollowsThePreference() async {
        prefs.threshold = 120
        await turn(60)
        XCTAssertTrue(center.added.isEmpty)
        await turn(120, turnId: "t2")
        XCTAssertEqual(center.added.count, 1)
    }

    func testFailedLongTurnPostsStoppedWithAnError() async {
        await turn(45, outcome: .failed)
        XCTAssertEqual(center.added.first?.content.body, "Stopped with an error")
        XCTAssertEqual(center.added.first?.content.categoryIdentifier, "CONDUIT_OPEN")
    }

    func testFailedShortTurnDoesNotNotify() async {
        await turn(5, outcome: .failed)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testInterruptedNeverNotifiesEvenWhenLong() async {
        await turn(600, outcome: .interrupted)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testFinishWithoutAStartPostsNothing() async {
        send(.turnFinished(turnId: "ghost", at: clock, outcome: .completed, replyPreview: "x"))
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "no start observed, so the duration is unknown")
    }

    func testAttendedSessionIsSuppressedAtPostTime() async {
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        await turn(60)
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testReplayedFinishPostsOnceEvenWithNewEventIds() async {
        send(.turnStarted(turnId: "t1", at: clock))
        let finish = MacNotificationEvent.Kind.turnFinished(turnId: "t1", at: clock.addingTimeInterval(40), outcome: .completed, replyPreview: "x")
        send(finish)
        send(finish)
        send(finish, id: 99)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
    }

    func testStaleEventIdIsDropped() async {
        send(.turnStarted(turnId: "t1", at: clock), id: 10)
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(40), outcome: .completed, replyPreview: "x"), id: 5)
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "an event at or below the last seen id for the session is a replay")
    }

    func testFinishCarriesItsOwnStartSoNoStartEventIsNeeded() async {
        send(.turnFinished(turnId: "t9", at: clock.addingTimeInterval(45), outcome: .completed, replyPreview: "ok", startedAt: clock))
        await coordinator.drain()
        XCTAssertEqual(center.identifiers, ["conduit.done.key-1"], "a turn already running at feed baseline still notifies")
    }

    func testFinishWithAShortOwnStartDoesNotNotify() async {
        send(.turnStarted(turnId: "t9", at: clock.addingTimeInterval(-600)))
        send(.turnFinished(turnId: "t9", at: clock.addingTimeInterval(10), outcome: .completed, replyPreview: "ok", startedAt: clock))
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "the event's startedAt wins over a recorded turnStarted")
    }

    func testObservedGapFinishPostsNothing() async {
        send(.turnFinished(turnId: "t9", at: clock.addingTimeInterval(45), outcome: .completed, replyPreview: "ok", startedAt: clock, observedGap: true))
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "the user never watched this turn end; no Done for it")
    }

    func testUnsequencedEventsAreNotDroppedAsStale() async {
        send(.sessionTitleChanged(title: "A"), id: 10)
        send(.turnFinished(turnId: "t9", at: clock.addingTimeInterval(45), outcome: .completed, replyPreview: "ok", startedAt: clock), id: 0)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1, "eventId 0 is a snapshot item, not a replay")
    }

    func testNewerFinishReplacesTheOlderDoneByIdentifier() async {
        await turn(40, turnId: "t1")
        await turn(40, turnId: "t2")
        XCTAssertEqual(center.identifiers, ["conduit.done.key-1", "conduit.done.key-1"], "same identifier, so the system replaces the older banner")
    }

    func testTitleChangeIsUsedAtPostTime() async {
        send(.sessionTitleChanged(title: "Billing cleanup"))
        await turn(40)
        XCTAssertEqual(center.added.first?.content.title, "Billing cleanup")
    }

    func testSoundPreference() async {
        prefs.soundEnabled = false
        await turn(40)
        XCTAssertNil(center.added.first?.content.sound)
    }

    func testMasterAndKindTogglesGate() async {
        prefs.notifiesDone = false
        await turn(40)
        XCTAssertTrue(center.added.isEmpty)
        prefs.notifiesDone = true
        prefs.isEnabled = false
        await turn(40, turnId: "t2")
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testNoAuthorizationRequestUntilTheFirstEligibleEvent() async {
        center.status = .notDetermined
        await turn(5)
        XCTAssertEqual(center.authorizationRequests, 0, "a short turn is not an eligible event")
        await turn(40, turnId: "t2")
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.added.count, 1)
        await turn(40, turnId: "t3")
        XCTAssertEqual(center.authorizationRequests, 1, "asked once")
    }

    func testUndeterminedWhileTheAppIsActiveButUnattendedDoesNotPrompt() async {
        center.status = .notDetermined
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: false)
        await turn(40)
        XCTAssertEqual(center.authorizationRequests, 0, "the prompt only appears while Conduit is inactive")
        XCTAssertTrue(center.added.isEmpty)
    }

    func testDeniedPostsNothingAndNeverRetries() async {
        center.status = .denied
        await turn(40)
        await turn(40, turnId: "t2")
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testDeclinedPromptPostsNothing() async {
        center.status = .notDetermined
        center.grantOnRequest = false
        await turn(40)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testAddFailureIsSwallowed() async {
        struct Boom: Error {}
        center.addError = Boom()
        await turn(40)
        XCTAssertTrue(center.added.isEmpty)
        center.addError = nil
        await turn(40, turnId: "t2")
        XCTAssertEqual(center.added.count, 1, "the coordinator keeps working")
    }

    func testBurstCollapsesToASummary() async {
        for i in 1...5 {
            let s = makeSession(id: "r\(i)", key: "k\(i)", title: "S\(i)")
            await turn(40, turnId: "t\(i)", session: s)
            clock = clock.addingTimeInterval(1)
        }
        XCTAssertEqual(Array(center.identifiers.prefix(3)), ["conduit.done.k1", "conduit.done.k2", "conduit.done.k3"])
        XCTAssertEqual(Array(center.identifiers.suffix(2)), ["conduit.done.summary", "conduit.done.summary"])
        XCTAssertTrue(center.added.last!.content.title.contains("5"))
    }

    func testBecomingAttendedRemovesDeliveredDone() async {
        await turn(40)
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        coordinator.recheckAttention()
        XCTAssertEqual(center.removedDelivered, ["conduit.done.key-1"])
        XCTAssertEqual(center.removedPending, ["conduit.done.key-1"])
        coordinator.recheckAttention()
        XCTAssertEqual(center.removedDelivered.count, 1, "removed once")
    }

    func testLanguageChangeReRegistersCategoriesWithoutLosingForeignOnes() async {
        let foreign = UNNotificationCategory(identifier: "HERMES_CALL", actions: [], intentIdentifiers: [], options: [])
        center.stored = [foreign]
        coordinator.languageDidChange()
        await coordinator.drain()
        XCTAssertTrue(center.stored.contains { $0.identifier == "HERMES_CALL" })
        XCTAssertTrue(center.stored.contains { $0.identifier == "CONDUIT_DONE" })
    }

    func testCategoriesAreRegisteredBeforeTheFirstPost() async {
        await turn(40)
        XCTAssertTrue(center.stored.contains { $0.identifier == "CONDUIT_DONE" })
    }

    func testNoticeBypassesSuppressionButHonoursTheMasterToggle() async {
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        let payload = MacNotificationPayload(kind: .done, sessionId: "run-1", sessionKey: "key-1", profile: "default", dashboardID: nil, requestId: nil)
        coordinator.postNotice(for: payload, reply: true)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_OPEN")
        prefs.isEnabled = false
        coordinator.postNotice(for: payload, reply: true)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
    }
}
