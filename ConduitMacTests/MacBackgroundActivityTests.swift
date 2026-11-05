import Combine
import XCTest
@testable import ConduitMac

/// A fake `ProcessInfo`: records each begin and end, in order. No real activity token is taken.
private final class FakeActivityProcess: MacActivityProcess {
    final class Token: NSObject {
        let id: Int
        init(_ id: Int) { self.id = id }
    }

    private(set) var log: [String] = []
    private var next = 0

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol {
        next += 1
        let name = options == .userInitiated ? "call" : options == .userInitiatedAllowingIdleSystemSleep ? "stream" : "other"
        log.append("begin \(name) #\(next)")
        return Token(next)
    }

    func endActivity(_ activity: any NSObjectProtocol) {
        log.append("end #\((activity as? Token)?.id ?? -1)")
    }
}

/// A grace timer that the test fires by hand. Records the delay of each schedule.
@MainActor
private final class ManualSchedule {
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelled = 0
    private var pending: [Int: @MainActor () -> Void] = [:]
    private var next = 0

    var pendingCount: Int { pending.count }

    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        delays.append(delay)
        next += 1
        let id = next
        pending[id] = fire
        return { [weak self] in
            guard let self, self.pending.removeValue(forKey: id) != nil else { return }
            self.cancelled += 1
        }
    }

    /// Fires every pending timer once, as the clock would when the delay is up.
    func fireAll() {
        let due = pending
        pending = [:]
        for (_, fire) in due.sorted(by: { $0.key < $1.key }) { fire() }
    }
}

/// The decision (inputs to level to options) and the holder (one token, a grace before release).
@MainActor
final class MacBackgroundActivityTests: XCTestCase {
    private var process: FakeActivityProcess!
    private var timer: ManualSchedule!
    private var holder: MacBackgroundActivity!

    override func setUp() async throws {
        process = FakeActivityProcess()
        timer = ManualSchedule()
        holder = MacBackgroundActivity(process: process, schedule: { [timer] delay, fire in timer!.schedule(delay, fire) })
    }

    private func inputs(
        main: Bool = false, window: Bool = false, quickAsk: Bool = false, socket: Bool = false, call: Bool = false
    ) -> MacBackgroundActivityInputs {
        MacBackgroundActivityInputs(
            mainTurn: main, sessionWindowTurn: window, quickAskTurn: quickAsk, socketStream: socket, liveCall: call)
    }

    // MARK: Decision

    func testNothingRunningNeedsNoActivity() {
        XCTAssertEqual(inputs().level, .idle)
        XCTAssertNil(MacBackgroundActivityLevel.idle.options)
    }

    func testEachStreamInputNeedsTheStreamLevel() {
        XCTAssertEqual(inputs(main: true).level, .stream)
        XCTAssertEqual(inputs(window: true).level, .stream)
        XCTAssertEqual(inputs(quickAsk: true).level, .stream)
        XCTAssertEqual(inputs(socket: true).level, .stream)
    }

    func testALiveCallNeedsTheCallLevelAndBeatsAStream() {
        XCTAssertEqual(inputs(call: true).level, .call)
        XCTAssertEqual(inputs(main: true, window: true, quickAsk: true, socket: true, call: true).level, .call)
    }

    func testStreamOptionsLetTheSystemSleepWhenIdle() throws {
        let options = try XCTUnwrap(MacBackgroundActivityLevel.stream.options)
        XCTAssertEqual(options, .userInitiatedAllowingIdleSystemSleep)
        XCTAssertFalse(options.contains(.idleSystemSleepDisabled))
    }

    func testCallOptionsStopIdleSystemSleep() throws {
        let options = try XCTUnwrap(MacBackgroundActivityLevel.call.options)
        XCTAssertEqual(options, .userInitiated)
        XCTAssertTrue(options.contains(.idleSystemSleepDisabled))
    }

    /// Info.plist has neither `NSSupportsAutomaticTermination` nor `NSSupportsSuddenTermination` (D29), so the app
    /// opts in to neither. If a later change turns one on, the token already blocks it: both option sets carry
    /// both flags. This pins that, so the holder needs no `disableAutomaticTermination` call of its own.
    func testBothLevelsAlsoBlockAutomaticAndSuddenTermination() throws {
        for level in [MacBackgroundActivityLevel.stream, .call] {
            let options = try XCTUnwrap(level.options)
            XCTAssertTrue(options.contains(.automaticTerminationDisabled), "\(level)")
            XCTAssertTrue(options.contains(.suddenTerminationDisabled), "\(level)")
        }
    }

    /// The main window's `TurnState`: a reply that runs, and the resync that finds out whether one runs, hold the
    /// token. A gateway that cannot report a turn is a steady state, and a dropped connection can last for hours:
    /// neither is a live stream.
    func testOnlyRunningAndSynchronizingTurnStatesHold() {
        XCTAssertTrue(MacBackgroundActivityInputs.turnHolds(.running))
        XCTAssertTrue(MacBackgroundActivityInputs.turnHolds(.synchronizing))
        XCTAssertFalse(MacBackgroundActivityInputs.turnHolds(.idle))
        XCTAssertFalse(MacBackgroundActivityInputs.turnHolds(.reconnecting))
        XCTAssertFalse(MacBackgroundActivityInputs.turnHolds(.unsupportedGateway))
    }

    // MARK: Holder

    func testTheGraceIsFiveSeconds() {
        XCTAssertEqual(MacBackgroundActivity.graceInterval, 5)
    }

    func testAStreamTakesOneTokenAtOnce() {
        holder.update(inputs(main: true))
        XCTAssertEqual(process.log, ["begin stream #1"])
        XCTAssertEqual(holder.heldLevel, .stream)
    }

    func testTheSameLevelAgainTakesNoSecondToken() {
        holder.update(inputs(main: true))
        holder.update(inputs(main: true, window: true))
        holder.update(inputs(window: true))
        XCTAssertEqual(process.log, ["begin stream #1"], "at most one token")
        XCTAssertEqual(timer.pendingCount, 0)
    }

    func testNothingRunningAndNothingHeldDoesNothing() {
        holder.update(inputs())
        XCTAssertTrue(process.log.isEmpty)
        XCTAssertEqual(timer.pendingCount, 0)
        XCTAssertEqual(holder.heldLevel, .idle)
    }

    func testTheTokenIsKeptThroughTheGraceAndEndsAfterIt() {
        holder.update(inputs(main: true))
        holder.update(inputs())
        XCTAssertEqual(timer.delays, [MacBackgroundActivity.graceInterval])
        XCTAssertEqual(process.log, ["begin stream #1"], "still held during the grace")
        XCTAssertEqual(holder.heldLevel, .stream)
        timer.fireAll()
        XCTAssertEqual(process.log, ["begin stream #1", "end #1"])
        XCTAssertEqual(holder.heldLevel, .idle)
    }

    func testWorkThatReturnsInTheGraceKeepsTheTokenAndStartsNoNewOne() {
        holder.update(inputs(main: true))
        holder.update(inputs())
        holder.update(inputs(window: true))
        XCTAssertEqual(timer.cancelled, 1, "the grace is cancelled")
        timer.fireAll()
        XCTAssertEqual(process.log, ["begin stream #1"])
        XCTAssertEqual(holder.heldLevel, .stream)
    }

    func testRepeatedIdleInputsStartOneGrace() {
        holder.update(inputs(main: true))
        holder.update(inputs())
        holder.update(inputs())
        XCTAssertEqual(timer.delays.count, 1)
    }

    func testACallStartingDuringAStreamTakesTheNewTokenBeforeEndingTheOld() {
        holder.update(inputs(main: true))
        holder.update(inputs(main: true, call: true))
        XCTAssertEqual(process.log, ["begin stream #1", "begin call #2", "end #1"])
        XCTAssertEqual(holder.heldLevel, .call)
    }

    func testTheCallEndingWhileAStreamRunsDropsToTheStreamTokenAfterTheGrace() {
        holder.update(inputs(call: true))
        holder.update(inputs(main: true, call: true))
        holder.update(inputs(main: true))
        XCTAssertEqual(process.log, ["begin call #1"], "the call token stays through the grace")
        XCTAssertEqual(holder.heldLevel, .call)
        timer.fireAll()
        XCTAssertEqual(process.log, ["begin call #1", "begin stream #2", "end #1"], "new token first, then the old one ends")
        XCTAssertEqual(holder.heldLevel, .stream)
    }

    func testTheGraceReadsTheInputsAtTheEndNotTheStart() {
        holder.update(inputs(call: true))
        holder.update(inputs())
        holder.update(inputs(main: true))
        timer.fireAll()
        XCTAssertEqual(process.log, ["begin call #1", "begin stream #2", "end #1"])
        timer.fireAll()
        XCTAssertEqual(holder.heldLevel, .stream)
    }

    func testACallReturningInTheGraceKeepsItsToken() {
        holder.update(inputs(call: true))
        holder.update(inputs())
        holder.update(inputs(call: true))
        timer.fireAll()
        XCTAssertEqual(process.log, ["begin call #1"])
    }

    func testAnUpgradeDuringTheGraceIsImmediateAndCancelsTheGrace() {
        holder.update(inputs(main: true))
        holder.update(inputs())
        holder.update(inputs(call: true))
        XCTAssertEqual(process.log, ["begin stream #1", "begin call #2", "end #1"])
        XCTAssertEqual(timer.cancelled, 1)
        timer.fireAll()
        XCTAssertEqual(process.log.count, 3)
    }

    func testReleaseEndsTheTokenAtOnceAndCancelsTheGrace() {
        holder.update(inputs(main: true))
        holder.update(inputs())
        holder.release()
        XCTAssertEqual(process.log, ["begin stream #1", "end #1"])
        XCTAssertEqual(timer.cancelled, 1)
        XCTAssertEqual(holder.heldLevel, .idle)
        timer.fireAll()
        XCTAssertEqual(process.log.count, 2, "the cancelled grace does nothing")
    }

    func testReleaseWithNothingHeldDoesNothing() {
        holder.release()
        XCTAssertTrue(process.log.isEmpty)
    }

    func testTheRealProcessInfoTakesAndEndsAToken() {
        // ProcessInfo conforms to the protocol, so the app code and the tests call the same two methods.
        let real: MacActivityProcess = ProcessInfo.processInfo
        let token = real.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "ConduitMacTests")
        real.endActivity(token)
    }

    // MARK: Monitor

    /// One subject per input, all quiet.
    private struct FakeSources {
        let main = CurrentValueSubject<Bool, Never>(false)
        let window = CurrentValueSubject<Bool, Never>(false)
        let quickAsk = CurrentValueSubject<Bool, Never>(false)
        let socket = CurrentValueSubject<Bool, Never>(false)
        let call = CurrentValueSubject<Bool, Never>(false)

        var sources: MacBackgroundActivityMonitor.Sources {
            .init(
                mainTurn: main.eraseToAnyPublisher(), sessionWindowTurn: window.eraseToAnyPublisher(),
                quickAskTurn: quickAsk.eraseToAnyPublisher(), socketStream: socket.eraseToAnyPublisher(),
                liveCall: call.eraseToAnyPublisher())
        }
    }

    func testTheMonitorFollowsEachSourceIntoTheHolder() {
        let fake = FakeSources()
        let monitor = MacBackgroundActivityMonitor(holder: holder, sources: fake.sources)
        monitor.start()
        XCTAssertTrue(process.log.isEmpty, "all quiet at start")
        fake.quickAsk.send(true)
        XCTAssertEqual(process.log, ["begin stream #1"])
        fake.call.send(true)
        XCTAssertEqual(process.log, ["begin stream #1", "begin call #2", "end #1"])
        fake.call.send(false)
        fake.quickAsk.send(false)
        XCTAssertEqual(process.log.count, 3, "the release waits for the grace")
        timer.fireAll()
        XCTAssertEqual(process.log.last, "end #2")
        XCTAssertEqual(holder.heldLevel, .idle)
    }

    func testASourceThatIsTrueAtStartTakesTheTokenAtStart() {
        let fake = FakeSources()
        fake.main.send(true)
        let monitor = MacBackgroundActivityMonitor(holder: holder, sources: fake.sources)
        monitor.start()
        XCTAssertEqual(process.log, ["begin stream #1"])
    }

    func testStopEndsTheTokenAtOnceAndIgnoresLaterChanges() {
        let fake = FakeSources()
        let monitor = MacBackgroundActivityMonitor(holder: holder, sources: fake.sources)
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        fake.main.send(true)
        monitor.stop()
        XCTAssertEqual(process.log, ["begin stream #1", "end #1"])
        fake.main.send(false)
        fake.main.send(true)
        XCTAssertEqual(process.log.count, 2)
        XCTAssertFalse(monitor.isRunning)
    }

    func testBootstrapStartsOnceAndStopEndsTheToken() {
        let fake = FakeSources()
        defer { MacBackgroundActivityBootstrap.stop() }
        MacBackgroundActivityBootstrap.start(sources: fake.sources, holder: holder)
        let first = MacBackgroundActivityBootstrap.monitor
        MacBackgroundActivityBootstrap.start(sources: fake.sources, holder: holder)
        XCTAssertNotNil(first)
        XCTAssertTrue(MacBackgroundActivityBootstrap.monitor === first, "a second start changes nothing")
        fake.main.send(true)
        XCTAssertEqual(process.log, ["begin stream #1"])
        MacBackgroundActivityBootstrap.stop()
        XCTAssertEqual(process.log, ["begin stream #1", "end #1"])
        XCTAssertNil(MacBackgroundActivityBootstrap.monitor)
    }

    /// The delegate starts the holder outside XCTest only, and ends it at quit. A source check: the delegate
    /// cannot run `applicationDidFinishLaunching` in a test (it starts Sparkle).
    func testTheAppDelegateStartsItOutsideXCTestAndStopsItAtQuit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("ConduitMac/App/ConduitMacAppDelegate.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("if !MacDefaults.isRunningUnderXCTest { MacBackgroundActivityBootstrap.start() }"))
        XCTAssertTrue(source.contains("MacBackgroundActivityBootstrap.stop()"))
        // The feed is one input, so its bootstrap comes first.
        let feedStart = try XCTUnwrap(source.range(of: "MacActivityBootstrap.start()"))
        let holderStart = try XCTUnwrap(source.range(of: "MacBackgroundActivityBootstrap.start()"))
        XCTAssertLessThan(feedStart.lowerBound, holderStart.lowerBound)
    }

    // MARK: Session windows (D21)

    private func windowController(sessionID: String = "row-1") -> MacSessionWindowController {
        let token = MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: sessionID)
        return MacSessionWindowController(token: token, environment: MacSessionWindowEnvironment(), hub: MacStreamEventHub())
    }

    func testARunningSessionWindowTurnIsTrackedUntilItEnds() {
        let registry = MacSessionWindowRegistry()
        let controller = windowController()
        let watch = registry.trackTurn(of: controller)
        XCTAssertTrue(registry.runningTurns.isEmpty)
        controller.handle(.messageStart(sessionId: "row-1"))
        XCTAssertEqual(registry.runningTurns, [controller.token])
        controller.handle(.messageInterrupted(sessionId: "row-1"))
        XCTAssertTrue(registry.runningTurns.isEmpty)
        withExtendedLifetime(watch) {}
    }

    func testAnEventForAnotherChatIsNotThisWindowsTurn() {
        let registry = MacSessionWindowRegistry()
        let controller = windowController()
        let watch = registry.trackTurn(of: controller)
        controller.handle(.messageStart(sessionId: "another-chat"))
        XCTAssertTrue(registry.runningTurns.isEmpty)
        withExtendedLifetime(watch) {}
    }

    func testTwoWindowsAreTrackedApart() {
        let registry = MacSessionWindowRegistry()
        let one = windowController(sessionID: "row-1")
        let two = windowController(sessionID: "row-2")
        let watches = [registry.trackTurn(of: one), registry.trackTurn(of: two)]
        one.handle(.messageStart(sessionId: "row-1"))
        two.handle(.messageStart(sessionId: "row-2"))
        XCTAssertEqual(registry.runningTurns, [one.token, two.token])
        one.handle(.messageInterrupted(sessionId: "row-1"))
        XCTAssertEqual(registry.runningTurns, [two.token], "the other window still runs")
        withExtendedLifetime(watches) {}
    }

    func testClosingAWindowDuringItsTurnForgetsTheTurn() {
        let registry = MacSessionWindowRegistry()
        let controller = windowController()
        _ = registry.request(controller.token)
        _ = registry.appeared(controller.token)
        var watch: AnyCancellable? = registry.trackTurn(of: controller)
        controller.handle(.messageStart(sessionId: "row-1"))
        XCTAssertEqual(registry.runningTurns, [controller.token])
        watch = nil
        registry.disappeared(controller.token)
        XCTAssertTrue(registry.runningTurns.isEmpty)
        controller.handle(.messageDelta(sessionId: "row-1", text: "late"))
        XCTAssertTrue(registry.runningTurns.isEmpty, "a closed window's controller no longer reports")
        XCTAssertNil(watch)
    }

    // MARK: Quick Ask (D15)

    func testQuickAskCountsFromCreatingUntilTheTurnEnds() {
        let controller = MacQuickAskController(hub: MacStreamEventHub())
        var values: [Bool] = []
        let watch = MacBackgroundActivitySources.quickAskTurn(of: controller).sink { values.append($0) }
        let running: [MacQuickAskModel.State] = [.creating, .sending, .streaming(text: "", status: nil)]
        let quiet: [MacQuickAskModel.State] = [
            .idle, .done(text: "x"), .needsInput(text: "x"), .failed(message: "m", partial: "", kind: .generic)]
        for state in running {
            controller.forceStateForTest(.idle)
            controller.forceStateForTest(state)
            XCTAssertEqual(values.last, true, "\(state)")
        }
        for state in quiet {
            controller.forceStateForTest(.creating)
            controller.forceStateForTest(state)
            XCTAssertEqual(values.last, false, "\(state)")
        }
        withExtendedLifetime(watch) {}
    }

    // MARK: Chats on the socket (AgentActivityFeed)

    private func item(
        _ kind: AgentActivityItem.Kind, _ state: AgentActivityItem.State, pollOnly: Bool = false
    ) -> AgentActivityItem {
        AgentActivityItem(id: "\(kind)-\(state)-\(pollOnly)", kind: kind, state: state, isPollOnly: pollOnly)
    }

    func testOnlyAWorkingTurnThatStreamsHereIsASocketStream() {
        let items = CurrentValueSubject<[AgentActivityItem], Never>([])
        var values: [Bool] = []
        let watch = MacBackgroundActivitySources.socketStream(items: items.eraseToAnyPublisher()).sink { values.append($0) }
        XCTAssertEqual(values, [false])
        items.send([item(.turn, .working, pollOnly: true)])
        items.send([item(.turn, .needsUser), item(.approval, .working), item(.turn, .finished(.completed))])
        XCTAssertEqual(values, [false], "a poll-only turn, a waiting turn, an approval and a finished turn hold nothing")
        items.send([item(.turn, .working)])
        XCTAssertEqual(values, [false, true])
        items.send([item(.turn, .working), item(.turn, .finished(.completed))])
        XCTAssertEqual(values, [false, true], "no repeat")
        items.send([])
        XCTAssertEqual(values, [false, true, false])
        withExtendedLifetime(watch) {}
    }

    func testNoFeedMeansNoSocketStream() {
        var values: [Bool] = []
        let watch = MacBackgroundActivitySources.socketStream(items: nil).sink { values.append($0) }
        XCTAssertEqual(values, [false])
        withExtendedLifetime(watch) {}
    }

    // MARK: Live calls

    /// Runs after every main-queue delivery that was queued before it.
    private func pumpMain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testACallIsReadOnEachSurfaceChangeAndAtEachTickWhileASurfaceIsUp() async {
        let surface = CurrentValueSubject<Bool, Never>(false)
        let ticks = PassthroughSubject<Void, Never>()
        var active = false
        var tickSubscriptions = 0
        var values: [Bool] = []
        let watch = MacBackgroundActivitySources.liveCall(
            surface: surface.eraseToAnyPublisher(),
            isActive: { active },
            ticks: { tickSubscriptions += 1; return ticks.eraseToAnyPublisher() }
        ).sink { values.append($0) }
        await pumpMain()
        XCTAssertEqual(values, [false])
        XCTAssertEqual(tickSubscriptions, 0, "no polling while no call screen is up")

        // The call starts: its screen comes up and the phase turns active.
        active = true
        surface.send(true)
        await pumpMain()
        XCTAssertEqual(values, [false, true])
        XCTAssertEqual(tickSubscriptions, 1)

        // The call fails with its screen still up: nothing publishes, the next tick sees it.
        active = false
        ticks.send()
        XCTAssertEqual(values, [false, true, false])

        // The screen closes while the call runs: one last read finds it, and the polling stops.
        active = true
        surface.send(false)
        await pumpMain()
        XCTAssertEqual(values, [false, true, false, true])
        active = false
        ticks.send()
        XCTAssertEqual(values, [false, true, false, true], "no tick is read once the screen is gone")
        withExtendedLifetime(watch) {}
    }

    func testAScreenThatIsUpWithNoCallRunningHoldsNothing() async {
        let surface = CurrentValueSubject<Bool, Never>(true)
        var values: [Bool] = []
        let watch = MacBackgroundActivitySources.liveCall(
            surface: surface.eraseToAnyPublisher(),
            isActive: { false },
            ticks: { Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher() }
        ).sink { values.append($0) }
        await pumpMain()
        XCTAssertEqual(values, [false])
        withExtendedLifetime(watch) {}
    }

    func testACallWithNoScreenIsStillReadAtTheNextChange() async {
        let surface = CurrentValueSubject<Bool, Never>(false)
        var active = true
        var values: [Bool] = []
        let watch = MacBackgroundActivitySources.liveCall(
            surface: surface.eraseToAnyPublisher(),
            isActive: { active },
            ticks: { Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher() }
        ).sink { values.append($0) }
        await pumpMain()
        XCTAssertEqual(values, [true])
        active = false
        surface.send(true)
        surface.send(false)
        await pumpMain()
        XCTAssertEqual(values, [true, false])
        withExtendedLifetime(watch) {}
    }

    // MARK: The real AppState

    func testTheLiveSourcesStartQuietAndASheetWithNoCallHoldsNothing() async {
        let fixture = MacSharedBaseAppStateFixture()
        defer { fixture.tearDown() }
        let appState = fixture.appState
        let sources = MacBackgroundActivityMonitor.Sources.live(
            appState: appState, feed: nil, registry: MacSessionWindowRegistry(),
            quickAsk: MacQuickAskController(hub: MacStreamEventHub()), callPollInterval: 0.05)
        var latest: [String: Bool] = [:]
        var bag = Set<AnyCancellable>()
        sources.mainTurn.sink { latest["main"] = $0 }.store(in: &bag)
        sources.sessionWindowTurn.sink { latest["window"] = $0 }.store(in: &bag)
        sources.quickAskTurn.sink { latest["quickAsk"] = $0 }.store(in: &bag)
        sources.socketStream.sink { latest["socket"] = $0 }.store(in: &bag)
        sources.liveCall.sink { latest["call"] = $0 }.store(in: &bag)
        await pumpMain()
        XCTAssertEqual(latest, ["main": false, "window": false, "quickAsk": false, "socket": false, "call": false])

        // A call screen that is up while no controller runs: a failed or never started call.
        appState.showGeminiLiveSheet = true
        await pumpMain()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(latest["call"], false)
        XCTAssertFalse(appState.isLiveVoiceCallActive)
        appState.showGeminiLiveSheet = false
        bag.removeAll()
    }
}
