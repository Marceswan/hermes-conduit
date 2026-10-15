import XCTest
@testable import ConduitMac

@MainActor
final class AgentActivityPollerTests: XCTestCase {
    private var sources: FakeActivitySources!
    private var sleeper: ManualSleeper!
    private var poller: AgentActivityPoller!
    private var delivered: [[LiveSessionStatus]] = []
    private var unavailableCalls = 0
    private var live = false
    private var panelVisible = false

    override func setUp() async throws {
        sources = FakeActivitySources()
        sleeper = ManualSleeper()
        delivered = []
        unavailableCalls = 0
        live = false
        panelVisible = false
        poller = AgentActivityPoller(sources: sources, sleep: sleeper.sleep)
        poller.isLive = { [unowned self] in self.live }
        poller.isPanelVisible = { [unowned self] in self.panelVisible }
        poller.onRows = { [unowned self] in self.delivered.append($0) }
        poller.onUnavailable = { [unowned self] in self.unavailableCalls += 1 }
    }

    override func tearDown() async throws {
        poller.stop()
        sleeper.cancelAll()
        poller = nil
    }

    func testCadenceTable() {
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: true, panelVisible: false), 4)
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: false, panelVisible: true), 4)
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: true, panelVisible: true), 4)
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: false, panelVisible: false), 15)
    }

    func testFailuresStretchTheIntervalAndCapIt() {
        let table: [(Bool, Int, TimeInterval)] = [
            (true, 0, 4), (true, 1, 8), (true, 2, 16), (true, 3, 32), (true, 4, 60), (true, 40, 60),
            (false, 0, 15), (false, 1, 30), (false, 2, 60), (false, 9, 60),
        ]
        for (live, failures, expected) in table {
            XCTAssertEqual(
                AgentActivityPollCadence.interval(isLive: live, panelVisible: false, failures: failures), expected,
                "live \(live) failures \(failures)")
        }
    }

    func testRepeatedFailuresBackOffAndASuccessRestoresTheCadence() async {
        sources.activeError = RpcError(code: 500, message: "boom")
        poller.start()
        await assertEventually { self.sleeper.requested == [30] }
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [30, 60] }
        XCTAssertEqual(poller.failures, 2)
        sources.activeError = nil
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [30, 60, 15] }
        XCTAssertEqual(poller.failures, 0)
        XCTAssertEqual(delivered.count, 1)
    }

    func testBeingOfflineIsNotAFailure() async {
        sources.isConnected = false
        poller.start()
        await assertEventually { self.sleeper.requested == [15] }
        XCTAssertEqual(poller.failures, 0)
    }

    func testAnOlderResponseThatArrivesLastIsDropped() async {
        sources.holdActive = true
        let first = Task { await poller.pollNow() }
        let second = Task { await poller.pollNow() }
        await assertEventually { self.sources.heldActiveCount == 2 }
        sources.releaseActive(1, rows: [AgentActivityTestSupport.row("new", "working")])
        await assertEventually { self.delivered.count == 1 }
        sources.releaseActive(0, rows: [AgentActivityTestSupport.row("old", "working")])
        await first.value
        await second.value
        XCTAssertEqual(delivered.map { $0.map(\.runtimeSessionId) }, [["new"]])
    }

    func testDiscardInFlightDropsResponsesToRequestsAlreadySent() async {
        sources.holdActive = true
        let inFlight = Task { await poller.pollNow() }
        await assertEventually { self.sources.heldActiveCount == 1 }
        poller.discardInFlight()
        sources.releaseActive(0, rows: [AgentActivityTestSupport.row("stale", "working")])
        await inFlight.value
        XCTAssertTrue(delivered.isEmpty)
        sources.holdActive = false
        await poller.pollNow()
        XCTAssertEqual(delivered.count, 1, "polls started after the discard are applied")
    }

    func testFirstPollRunsAtOnceAndDeliversRows() async {
        sources.rows = [AgentActivityTestSupport.row("rt1", "working")]
        poller.start()
        await assertEventually { self.delivered.count == 1 }
        XCTAssertEqual(delivered[0].map(\.runtimeSessionId), ["rt1"])
    }

    func testTheLoopSleepsForTheCadenceItIsGiven() async {
        poller.start()
        await assertEventually { self.sleeper.requested == [15] }
        live = true
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [15, 4] }
        live = false
        panelVisible = true
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [15, 4, 4] }
        panelVisible = false
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [15, 4, 4, 15] }
    }

    func testNoPollWhileDisconnected() async {
        sources.isConnected = false
        poller.start()
        await assertEventually { self.sleeper.requested.count == 1 }
        XCTAssertEqual(sources.activeCalls, 0)
    }

    func testMethodUnavailableStopsAskingUntilTheCapabilityIsReset() async {
        sources.activeError = RpcError(code: -32601, message: "Method not found")
        poller.start()
        await assertEventually { self.unavailableCalls == 1 }
        await assertEventually { self.sleeper.pending == 1 }
        sleeper.fire()
        await assertEventually { self.sleeper.requested.count == 2 }
        XCTAssertEqual(sources.activeCalls, 1, "no retry loop against a client without the method")
        sources.activeError = nil
        poller.resetCapability()
        sleeper.fire()
        await assertEventually { self.delivered.count == 1 }
        XCTAssertEqual(sources.activeCalls, 2)
    }

    func testOtherErrorsRetryOnTheNextTick() async {
        sources.activeError = RpcError(code: 500, message: "boom")
        poller.start()
        await assertEventually { self.sources.activeCalls == 1 }
        await assertEventually { self.sleeper.pending == 1 }
        XCTAssertEqual(unavailableCalls, 0)
        sleeper.fire()
        await assertEventually { self.sources.activeCalls == 2 }
    }

    func testStartIsIdempotentAndStopEndsTheLoop() async {
        poller.start()
        poller.start()
        await assertEventually { self.sleeper.requested.count == 1 }
        XCTAssertEqual(sources.activeCalls, 1, "one loop, not two")
        XCTAssertTrue(poller.isRunning)
        poller.stop()
        XCTAssertFalse(poller.isRunning)
        sleeper.cancelAll()
        HostedTestSupport.settle(0.05)
        XCTAssertEqual(sources.activeCalls, 1)
    }

    func testMethodUnavailableClassification() {
        XCTAssertTrue(AgentActivityRpc.isMethodUnavailable(RpcError(code: -32601, message: "x")))
        XCTAssertTrue(AgentActivityRpc.isMethodUnavailable(RpcError(code: 1, message: "Method not found")))
        XCTAssertTrue(AgentActivityRpc.isMethodUnavailable(RpcError(code: 1, message: "unknown method session.active_list")))
        XCTAssertFalse(AgentActivityRpc.isMethodUnavailable(RpcError(code: 4009, message: "no pending approval")))
        XCTAssertFalse(AgentActivityRpc.isMethodUnavailable(CancellationError()))
    }

    // MARK: - Independent of the scene

    func testLiveSourcesReportConnectedWhileTheSceneIsInactive() {
        let fixture = MacSharedBaseAppStateFixture()
        defer { fixture.tearDown() }
        let appState = fixture.appState
        let connection = HermesConnection(baseUrl: "https://example.com", ticket: "t")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        _ = appState.handleScenePhase(.background)
        XCTAssertFalse(appState.isSceneActive)
        XCTAssertTrue(AgentActivityLiveSources(appState: appState).isConnected,
                      "the poll must not depend on the app being frontmost")
    }

    func testNoActivityFileConsultsTheSceneState() throws {
        let activity = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConduitMac/Activity", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: activity, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("isSceneActive"), file.lastPathComponent)
            XCTAssertFalse(text.contains("scenePhase"), file.lastPathComponent)
        }
    }
}
