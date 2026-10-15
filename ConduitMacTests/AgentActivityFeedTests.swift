import Combine
import XCTest
@testable import ConduitMac

@MainActor
final class AgentActivityFeedTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private var sources: FakeActivitySources!
    private var hub: MacStreamEventHub!
    private var pollSleeper: ManualSleeper!
    private var tickSleeper: ManualSleeper!
    private var feed: AgentActivityFeed!
    private var now = AgentActivityTestSupport.origin
    private var received: [AgentActivityEvent] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        sources = FakeActivitySources()
        hub = MacStreamEventHub()
        pollSleeper = ManualSleeper()
        tickSleeper = ManualSleeper()
        now = Support.origin
        received = []
        cancellables = []
        feed = AgentActivityFeed(
            sources: sources, hub: hub, clock: { [unowned self] in self.now },
            pollSleep: pollSleeper.sleep, tickSleep: tickSleeper.sleep)
        feed.events.sink { [unowned self] in self.received.append($0) }.store(in: &cancellables)
    }

    override func tearDown() async throws {
        feed.stop()
        pollSleeper.cancelAll()
        tickSleeper.cancelAll()
        cancellables = []
        feed = nil
    }

    /// Hub-driven tests do not need the poller to run.
    private func startOffline() {
        sources.isConnected = false
        feed.start()
    }

    private func finish(_ session: String) {
        hub.publish(.messageComplete(sessionId: session, messageId: nil, content: "done", reasoning: nil))
    }

    // MARK: - Events and items

    func testHubEventsBuildItemsAndEvents() {
        startOffline()
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.map(\.id), ["turn:s1"])
        XCTAssertEqual(received.count, 1)
        guard case .turnStarted(let item) = received[0].payload else { return XCTFail("expected turnStarted") }
        XCTAssertEqual(item.id, "turn:s1")
    }

    func testItemsAreUpdatedBeforeTheMatchingEventIsSent() {
        startOffline()
        var countAtEvent: [Int] = []
        feed.events.sink { [unowned self] _ in countAtEvent.append(self.feed.items.count) }.store(in: &cancellables)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(countAtEvent, [1])
    }

    func testEventIdsStartAtOneAndIncreaseByOne() {
        startOffline()
        hub.publish(.messageStart(sessionId: "s1"))
        finish("s1")
        XCTAssertEqual(received.map(\.eventId), [1, 2])
    }

    func testEventTimestampsComeFromTheClock() {
        startOffline()
        now = Support.origin.addingTimeInterval(42)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(received[0].at, Support.origin.addingTimeInterval(42))
    }

    func testSnapshotHoldsPendingWorkAndNotFinishedRows() {
        startOffline()
        hub.publish(.messageStart(sessionId: "a"))
        hub.publish(.messageStart(sessionId: "b"))
        finish("b")
        XCTAssertEqual(feed.snapshot().map(\.id), ["turn:a"])
        XCTAssertEqual(feed.items.count, 2)
    }

    func testDismissRemovesAFinishedRowOnly() {
        startOffline()
        hub.publish(.messageStart(sessionId: "a"))
        hub.publish(.messageStart(sessionId: "b"))
        finish("b")
        feed.dismiss("turn:a")
        feed.dismiss("turn:b")
        XCTAssertEqual(feed.items.map(\.id), ["turn:a"])
    }

    func testActiveSessionFlagAndCatalogTitleFlowIntoItems() {
        startOffline()
        feed.setActiveSession("s1")
        feed.setCatalog([Support.summary(id: "s1", title: "Laravel")])
        hub.publish(.messageStart(sessionId: "s1"))
        hub.publish(.messageStart(sessionId: "s2"))
        XCTAssertEqual(feed.items.first { $0.id == "turn:s1" }?.isActiveSession, true)
        XCTAssertEqual(feed.items.first { $0.id == "turn:s1" }?.title, "Laravel")
        XCTAssertEqual(feed.items.first { $0.id == "turn:s2" }?.isActiveSession, false)
    }

    func testScopeChangeResetsSilentlyAndKeepsTheCatalog() {
        startOffline()
        feed.setCatalog([Support.summary(id: "s1", title: "Laravel")])
        hub.publish(.messageStart(sessionId: "s1"))
        let before = received.count
        feed.setScope(profile: "work", dashboardID: "d1")
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertEqual(received.count, before)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.first?.title, "Laravel")
        XCTAssertEqual(feed.items.first?.profile, "work")
    }

    // MARK: - Lifecycle

    func testStartAndStopAreIdempotentAndStopUnsubscribesAndClears() {
        startOffline()
        feed.start()
        XCTAssertEqual(hub.subscriberCount, 1)
        hub.publish(.messageStart(sessionId: "s1"))
        feed.stop()
        feed.stop()
        XCTAssertEqual(hub.subscriberCount, 0)
        XCTAssertTrue(feed.items.isEmpty)
        let before = received.count
        hub.publish(.messageStart(sessionId: "s2"))
        feed.observe(.messageStart(sessionId: "s3"))
        XCTAssertEqual(received.count, before, "a stopped feed ignores events")
        XCTAssertEqual(feed.availability, .offline)
    }

    func testAvailabilityIsLiveWhenStartedAndConnected() {
        feed.start()
        XCTAssertEqual(feed.availability, .live)
    }

    // MARK: - Poll

    func testPollOnlySessionsAppearAfterTheSilentBaseline() async {
        feed.start()
        await assertEventually { self.feed.isBaselined }
        XCTAssertTrue(received.isEmpty)
        sources.rows = [Support.row("rt1", stored: "st1", "working")]
        pollSleeper.fire()
        await assertEventually { self.feed.items.map(\.id) == ["turn:rt1"] }
        XCTAssertEqual(feed.items.first?.isPollOnly, true)
        guard case .turnStarted = received.last?.payload else { return XCTFail("expected turnStarted") }
    }

    func testRunningRowsFoundInTheBaselineDoNotAnnounce() async {
        sources.rows = [Support.row("rt1", "working")]
        feed.start()
        await assertEventually { self.feed.items.map(\.id) == ["turn:rt1"] }
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(feed.snapshot().map(\.id), ["turn:rt1"])
    }

    func testIsBaselinedIsFalseBeforeTheFirstPoll() async {
        XCTAssertFalse(feed.isBaselined)
        feed.start()
        await assertEventually { self.feed.isBaselined }
    }

    func testAWaitingRowFetchesPendingApprovalsOnceAndRaisesTheDecision() async {
        feed.start()
        await assertEventually { self.feed.isBaselined }
        sources.rows = [Support.row("rt1", "waiting")]
        sources.pendingResults["rt1"] = .success([Support.approval(session: "rt1", request: "q1")])
        pollSleeper.fire()
        await assertEventually { self.feed.items.contains { $0.id == "approval:q1" } }
        XCTAssertEqual(sources.pendingCalls, ["rt1"])
        XCTAssertTrue(received.contains {
            if case .decisionRequested(let item) = $0.payload { return item.id == "approval:q1" }
            return false
        })
        pollSleeper.fire()
        await assertEventually { self.sources.activeCalls == 3 }
        XCTAssertEqual(sources.pendingCalls, ["rt1"], "content is known: no second fetch")
    }

    func testAFailedPendingFetchLeavesANoButtonRow() async {
        feed.start()
        await assertEventually { self.feed.isBaselined }
        sources.rows = [Support.row("rt1", "waiting")]
        sources.pendingResults["rt1"] = .failure(RpcError(code: 500, message: "boom"))
        pollSleeper.fire()
        await assertEventually { self.feed.items.contains { $0.id == "approval:waiting:rt1" } }
        XCTAssertNil(feed.items.first { $0.id == "approval:waiting:rt1" }?.approval)
    }

    func testAnUnsupportedListMeansEventsOnly() async {
        sources.activeError = RpcError(code: -32601, message: "Method not found")
        feed.start()
        await assertEventually { self.feed.availability == .eventsOnly }
        XCTAssertTrue(feed.isBaselined)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.map(\.id), ["turn:s1"], "the tap still serves sessions on this socket")
    }

    func testPanelVisibilityAndLiveWorkShortenTheIdleInterval() async {
        feed.start()
        await assertEventually { self.pollSleeper.requested == [15] }
        feed.setPanelVisible(true)
        pollSleeper.fire()
        await assertEventually { self.pollSleeper.requested == [15, 4] }
        feed.setPanelVisible(false)
        hub.publish(.messageStart(sessionId: "s1"))
        pollSleeper.fire()
        await assertEventually { self.pollSleeper.requested == [15, 4, 4] }
    }

    // MARK: - Ticker

    func testTheTickerDropsFinishedRowsAfterThirtySeconds() async {
        startOffline()
        hub.publish(.messageStart(sessionId: "s1"))
        finish("s1")
        await assertEventually { self.tickSleeper.pending == 1 }
        now = Support.origin.addingTimeInterval(31)
        tickSleeper.fire()
        await assertEventually { self.feed.items.isEmpty }
    }
}
