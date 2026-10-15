import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationDecisionTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var prefs: MacNotificationPreferences!
    private var center: FakeNotificationCenter!
    private var scheduler: FakeScheduler!
    private var coordinator: MacNotificationCoordinator!
    private var visibility = MacNotificationVisibility.away
    private var clock = Date(timeIntervalSince1970: 3_000_000)
    private var nextEvent = 1
    private let attended = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        prefs = MacNotificationPreferences(defaults: suite.defaults)
        center = FakeNotificationCenter()
        scheduler = FakeScheduler()
        visibility = .away
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

    private func send(_ kind: MacNotificationEvent.Kind, session: MacNotificationSession = makeSession()) {
        defer { nextEvent += 1 }
        coordinator.handle(MacNotificationEvent(eventId: nextEvent, session: session, kind: kind))
    }
    private func requestApproval(_ id: String = "r1", choices: [String]? = ["once", "session", "always", "deny"]) {
        send(.approvalRequested(requestId: id, description: "Run tests", command: "swift test", choices: choices, allowPermanent: true))
    }
    private func settle() async {
        await coordinator.drain()
        scheduler.fireAll()
        await coordinator.drain()
    }

    func testApprovalWaitsForTheGraceThenPosts() async {
        requestApproval()
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "nothing before the 3 s grace")
        XCTAssertEqual(scheduler.jobs.map(\.delay), [3])
        await settle()
        XCTAssertEqual(center.identifiers, ["conduit.approval.r1"])
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_APPROVAL")
        XCTAssertEqual(center.added[0].content.title, "Approval needed")
        XCTAssertTrue(center.added[0].content.body.hasPrefix("swift test"))
        XCTAssertEqual(center.added[0].content.subtitle, "Refactor billing")
    }

    func testSmartDeniedApprovalStillOffersApproveOnceAndDeny() async {
        requestApproval(choices: ["once", "deny"])
        await settle()
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_APPROVAL")
    }

    func testApprovalWithoutOnceDropsApprove() async {
        requestApproval(choices: ["always", "deny"])
        await settle()
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
    }

    func testApprovalWithATruncatedCommandHasNoInlineApprove() async {
        send(.approvalRequested(requestId: "r1", description: "d", command: String(repeating: "c", count: 500), choices: ["once", "deny"], allowPermanent: false))
        await settle()
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
    }

    func testResolvedInsideTheGraceNeverPosts() async {
        requestApproval()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        await settle()
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(scheduler.cancelledCount, 1)
    }

    func testResolvedAfterDeliveryRemovesTheBanner() async {
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .expired))
        await coordinator.drain()
        XCTAssertTrue(center.removedDelivered.contains("conduit.approval.r1"))
        XCTAssertTrue(center.removedPending.contains("conduit.approval.r1"))
    }

    func testReplayedRequestAfterResolutionDoesNotRepost() async {
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        requestApproval()
        await settle()
        XCTAssertEqual(center.added.count, 1)
    }

    func testDuplicateRequestSchedulesOnce() async {
        requestApproval()
        requestApproval()
        await settle()
        XCTAssertEqual(center.added.count, 1)
    }

    func testSuppressedDecisionPostsWhenTheUserLeaves() async {
        visibility = attended
        requestApproval()
        await settle()
        XCTAssertTrue(center.added.isEmpty, "the user is looking at it")
        visibility = .away
        coordinator.recheckAttention()
        await coordinator.drain()
        XCTAssertEqual(center.identifiers, ["conduit.approval.r1"])
        coordinator.recheckAttention()
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1, "held decisions post once")
    }

    func testHeldDecisionResolvedWhileAttendedNeverPosts() async {
        visibility = attended
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        visibility = .away
        coordinator.recheckAttention()
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty)
    }

    func testQuestionPostsWithReplyForOneAndNotForABatch() async {
        send(.questionRequested(requestId: "q1", firstQuestionText: "Which branch?", openQuestionCount: 1))
        send(.questionRequested(requestId: "q2", firstQuestionText: "Pick one", openQuestionCount: 3))
        await settle()
        let byID = Dictionary(uniqueKeysWithValues: center.added.map { ($0.identifier, $0.content.categoryIdentifier) })
        XCTAssertEqual(byID["conduit.question.q1"], "CONDUIT_QUESTION")
        XCTAssertEqual(byID["conduit.question.q2"], "CONDUIT_OPEN")
    }

    func testQuestionToggleOffPostsNothing() async {
        prefs.notifiesQuestions = false
        send(.questionRequested(requestId: "q1", firstQuestionText: "x", openQuestionCount: 1))
        await settle()
        XCTAssertTrue(center.added.isEmpty)
    }

    func testApprovalToggleOffPostsNothingButApprovalsDoNotNeedAThreshold() async {
        requestApproval()
        await settle()
        XCTAssertEqual(center.added.count, 1, "no 30 s threshold applies to approvals")
        prefs.notifiesApprovals = false
        requestApproval("r2")
        await settle()
        XCTAssertEqual(center.added.count, 1)
    }

    func testNoDoneWhenADecisionAlreadyToldTheUserThisTurn() async {
        send(.turnStarted(turnId: "t1", at: clock))
        requestApproval()
        await settle()
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(90), outcome: .completed, replyPreview: "ok"))
        await coordinator.drain()
        XCTAssertEqual(center.identifiers, ["conduit.approval.r1"], "no Done after the approval banner")
    }

    func testDoneStillPostsWhenTheDecisionWasResolvedBeforeTheTurnEnded() async {
        send(.turnStarted(turnId: "t1", at: clock))
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(90), outcome: .completed, replyPreview: "ok"))
        await coordinator.drain()
        XCTAssertEqual(center.identifiers.last, "conduit.done.key-1")
    }

    func testOutstandingFromAnEarlierTurnDoesNotSuppressTheNextDone() async {
        send(.turnStarted(turnId: "t1", at: clock))
        requestApproval()
        await settle()
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(90), outcome: .completed, replyPreview: "ok"))
        send(.turnStarted(turnId: "t2", at: clock.addingTimeInterval(100)))
        send(.turnFinished(turnId: "t2", at: clock.addingTimeInterval(160), outcome: .completed, replyPreview: "second"))
        await coordinator.drain()
        XCTAssertEqual(center.identifiers.last, "conduit.done.key-1")
    }

    func testDecisionNoticesFromTwoSessionsKeepSeparateThreads() async {
        let other = makeSession(id: "run-2", key: "key-2", title: "Other")
        requestApproval("r1")
        send(.approvalRequested(requestId: "r2", description: "d", command: "c", choices: nil, allowPermanent: false), session: other)
        await settle()
        XCTAssertEqual(Set(center.added.map(\.content.threadIdentifier)), ["session-key-1", "session-key-2"])
    }

    func testTheTitleAtFireTimeIsUsed() async {
        requestApproval()
        send(.sessionTitleChanged(title: "Renamed during grace"))
        await settle()
        XCTAssertEqual(center.added[0].content.subtitle, "Renamed during grace")
    }
}
