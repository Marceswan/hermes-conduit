import Combine
import XCTest
@testable import ConduitMac

final class AgentActivityConnectionDerivationTests: XCTestCase {
    private let t0 = AgentActivityTestSupport.origin

    private func signals(_ connected: Bool, _ connecting: Bool = false, _ creds: Bool = false) -> AgentActivityConnectionSignals {
        .init(isConnected: connected, isConnecting: connecting, hasCredentials: creds)
    }

    func testConnectedWinsOverEverything() {
        XCTAssertEqual(AgentActivityConnection.state(signals(true, true, true), previous: .disconnected(since: t0), now: t0), .connected)
    }

    func testNotConnectedWithCredentialsOrAConnectInProgressIsReconnecting() {
        let later = t0.addingTimeInterval(5)
        XCTAssertEqual(AgentActivityConnection.state(signals(false, false, true), previous: .connected, now: later), .reconnecting(since: later))
        XCTAssertEqual(AgentActivityConnection.state(signals(false, true, false), previous: .connected, now: later), .reconnecting(since: later))
    }

    func testNotConnectedWithNothingToReconnectWithIsDisconnected() {
        let later = t0.addingTimeInterval(5)
        XCTAssertEqual(AgentActivityConnection.state(signals(false), previous: .connected, now: later), .disconnected(since: later))
    }

    func testSinceIsKeptWhileTheKindStaysTheSame() {
        let first = AgentActivityConnectionState.reconnecting(since: t0)
        XCTAssertEqual(AgentActivityConnection.state(signals(false, true, true), previous: first, now: t0.addingTimeInterval(30)), first)
        let moved = AgentActivityConnection.state(signals(false), previous: first, now: t0.addingTimeInterval(30))
        XCTAssertEqual(moved, .disconnected(since: t0.addingTimeInterval(30)))
    }
}

final class AgentActivityReducerGapTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private func approval() -> StreamEvent {
        .approval(sessionId: "rt1", activity: Support.approval(session: "rt1"))
    }

    func testLossEmitsNothingAndRowsClearSilentlyAfterTheGrace() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.stream(approval(), at: 1)
        let emitted = h.payloads.count
        h.send(.connectionLost, at: 10)
        XCTAssertEqual(h.payloads.count, emitted, "a drop emits nothing")
        h.send(.tick, at: 24)
        XCTAssertFalse(h.state.items.isEmpty, "inside the grace")
        h.send(.tick, at: 25)
        XCTAssertTrue(h.state.items.isEmpty)
        XCTAssertEqual(h.payloads.count, emitted, "clearing is silent: no turnFinished, no decisionResolved")
    }

    func testASecondLossDoesNotRestartTheGrace() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.send(.connectionLost, at: 10)
        h.send(.connectionLost, at: 20)
        h.send(.tick, at: 25)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testRestoringInsideTheGraceKeepsTheRows() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.send(.connectionLost, at: 10)
        h.send(.connectionRestored, at: 12)
        h.send(.tick, at: 60)
        XCTAssertNotNil(h.item("turn:rt1"))
        XCTAssertNil(h.state.offlineSince)
    }

    func testAfterARestoreAVanishedTurnFinishesAtOnceWithAGapFlag() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.stream(.messageStart(sessionId: "rt2"), at: 0)
        let starts = h.turnStarts.count
        h.send(.connectionLost, at: 10)
        h.send(.connectionRestored, at: 12)
        h.send(.activeList([Support.row("rt2", "working"), Support.row("rt3", "working")]), at: 13)
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed), "one poll is enough after a gap")
        XCTAssertEqual(h.turnFinishes.map(\.gap), [true])
        XCTAssertEqual(h.item("turn:rt2")?.state, .working)
        XCTAssertNotNil(h.item("turn:rt3"))
        XCTAssertEqual(h.turnStarts.count, starts, "the baseline after a reconnect is silent")
    }

    func testAnOrdinaryFinishAfterTheBaselineIsNotFlaggedAsAGap() {
        var h = AgentActivityHarness()
        h.send(.activeList([Support.row("rt1", "working")]))
        h.send(.activeList([]), at: 4)
        h.send(.activeList([]), at: 8)
        XCTAssertEqual(h.turnFinishes.map(\.gap), [false])
    }

    func testADecisionThatDidNotSurviveTheGapResolvesOnTheFirstPoll() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(approval(), at: 0)
        h.send(.connectionLost, at: 5)
        h.send(.connectionRestored, at: 7)
        h.send(.activeList([Support.row("rt1", "working")]), at: 8)
        XCTAssertNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.withdrawn])
    }

    func testADecisionStillWaitingAfterTheGapSurvives() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(approval(), at: 0)
        h.send(.connectionLost, at: 5)
        h.send(.connectionRestored, at: 7)
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 8)
        XCTAssertNotNil(h.item("approval:q1"))
        XCTAssertTrue(h.resolutions.isEmpty)
    }
}

@MainActor
final class AgentActivityFeedConnectionTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private var sources: FakeActivitySources!
    private var hub: MacStreamEventHub!
    private var pollSleeper: ManualSleeper!
    private var tickSleeper: ManualSleeper!
    private var feed: AgentActivityFeed!
    private var now = AgentActivityTestSupport.origin
    private var received: [AgentActivityEvent] = []
    private var cancellables: Set<AnyCancellable> = []
    private var fixture: MacSharedBaseAppStateFixture?

    override func setUp() async throws {
        sources = FakeActivitySources()
        sources.isConnected = false   // connection state is driven by signals here; no polling
        hub = MacStreamEventHub()
        pollSleeper = ManualSleeper()
        tickSleeper = ManualSleeper()
        now = Support.origin
        received = []
        cancellables = []
        feed = AgentActivityFeed(
            sources: sources, hub: hub, clock: { [unowned self] in self.now },
            pollSleep: pollSleeper.sleep, tickSleep: tickSleeper.sleep)
    }

    override func tearDown() async throws {
        feed.stop()
        pollSleeper.cancelAll()
        tickSleeper.cancelAll()
        cancellables = []
        fixture?.tearDown()
        fixture = nil
        feed = nil
    }

    private func signals(_ connected: Bool, _ connecting: Bool = false, _ creds: Bool = true) -> AgentActivityConnectionSignals {
        .init(isConnected: connected, isConnecting: connecting, hasCredentials: creds)
    }

    func testReconnectingAndDisconnectedAreVisibleAndAvailabilityGoesOffline() {
        feed.start()
        feed.connectionSignalsChanged(signals(true))
        XCTAssertEqual(feed.connection, .connected)
        XCTAssertEqual(feed.availability, .live)
        feed.connectionSignalsChanged(signals(false))
        XCTAssertEqual(feed.connection, .reconnecting(since: now))
        XCTAssertEqual(feed.availability, .offline)
        feed.connectionSignalsChanged(signals(false, false, false))
        XCTAssertEqual(feed.connection, .disconnected(since: now))
        feed.connectionSignalsChanged(signals(true))
        XCTAssertEqual(feed.connection, .connected)
        XCTAssertEqual(feed.availability, .live)
    }

    func testRowsSurviveTheGraceThenClearWithoutEvents() async {
        feed.start()
        feed.connectionSignalsChanged(signals(true))
        hub.publish(.messageStart(sessionId: "s1"))
        feed.events.sink { [unowned self] in self.received.append($0) }.store(in: &cancellables)
        feed.connectionSignalsChanged(signals(false))
        await assertEventually { self.tickSleeper.pending == 1 }
        now = Support.origin.addingTimeInterval(14)
        tickSleeper.fire()
        await assertEventually { self.tickSleeper.requested.count == 2 && self.tickSleeper.pending == 1 }
        XCTAssertEqual(feed.items.map(\.id), ["turn:s1"], "inside the grace the surface does not flash empty")
        now = Support.origin.addingTimeInterval(15)
        tickSleeper.fire()
        await assertEventually { self.feed.items.isEmpty }
        XCTAssertTrue(received.isEmpty, "no turnFinished on disconnect")
    }

    func testBindFollowsAppStateConnectionAndActiveSession() {
        let fixture = MacSharedBaseAppStateFixture()
        self.fixture = fixture
        let appState = fixture.appState
        feed.bind(to: appState)
        feed.start()
        XCTAssertEqual(feed.connection, .disconnected(since: now))

        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "t")
        XCTAssertEqual(feed.connection, .reconnecting(since: now), "credentials but no socket")
        appState.isConnected = true
        XCTAssertEqual(feed.connection, .connected)
        appState.isConnected = false
        XCTAssertEqual(feed.connection, .reconnecting(since: now))
        appState.connection = nil
        XCTAssertEqual(feed.connection, .disconnected(since: now))

        appState.activeSessionId = "s1"
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.first?.isActiveSession, true)
    }
}
