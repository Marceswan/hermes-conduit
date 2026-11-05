import XCTest
@testable import ConduitMac

/// Mirrors the iOS `CarPlayTransportRecoveryTests` seams: a recording scheduler
/// and executor, no network.
@MainActor
final class MacTransportRecoveryTests: XCTestCase {
    private final class Recorder {
        var delays: [TimeInterval] = []
        var operations: [@MainActor () async -> Void] = []
        var purposes: [ChatResumeSyncPurpose] = []
    }

    private var fixture: MacSharedBaseAppStateFixture!
    private let recorder = Recorder()

    override func setUp() async throws {
        let recorder = self.recorder
        fixture = MacSharedBaseAppStateFixture(
            reconnectScheduler: { delay, operation in
                recorder.delays.append(delay)
                recorder.operations.append(operation)
                return {}
            },
            reconnectExecutor: { purpose in recorder.purposes.append(purpose) })
        fixture.appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        fixture.appState.isConnected = false
        fixture.appState.isConnecting = false
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = true
        // A hosted test run can have a visible window: the tests decide it, none reads the screen.
        MacTransportRecoveryPolicy.windowIsVisible = { false }
    }

    override func tearDown() async throws {
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = true
        MacTransportRecoveryPolicy.windowIsVisible = MacTransportRecoveryPolicy.systemWindowIsVisible
        fixture.tearDown()
        fixture = nil
    }

    func testAReconnectIsScheduledAndRunsWhileTheAppIsInBackground() async {
        _ = fixture.appState.handleScenePhase(.background)
        XCTAssertFalse(fixture.appState.isSceneActive)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertEqual(recorder.delays.count, 1, "an inactive Mac app still schedules recovery")
        await recorder.operations.first?()
        XCTAssertEqual(recorder.purposes.count, 1, "and the cycle runs")
    }

    func testAReconnectIsScheduledWhileInactive() async {
        _ = fixture.appState.handleScenePhase(.inactive)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertEqual(recorder.delays.count, 1)
        await recorder.operations.first?()
        XCTAssertEqual(recorder.purposes.count, 1)
    }

    func testAnActiveSceneStillSchedulesNormally() {
        _ = fixture.appState.handleScenePhase(.active)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertEqual(recorder.delays.count, 1)
    }

    // The scene .inactive/.background branches drop an armed reconnect timer; the Mac must arm it again.

    func testALostSocketIsRearmedWhenTheAppResignsActiveWithATimerPending() {
        _ = fixture.appState.handleScenePhase(.active)
        fixture.appState.scheduleReconnect()
        XCTAssertEqual(recorder.delays.count, 1)
        _ = fixture.appState.handleScenePhase(.inactive)
        XCTAssertEqual(recorder.delays.count, 2, "the inactive branch cancelled the timer and the Mac exemption re-armed it")
        _ = fixture.appState.handleScenePhase(.background)
        XCTAssertEqual(recorder.delays.count, 3, "and again on background")
    }

    func testNothingIsRearmedWhileSignedOut() {
        _ = fixture.appState.handleScenePhase(.active)
        fixture.appState.connection = nil
        _ = fixture.appState.handleScenePhase(.inactive)
        _ = fixture.appState.handleScenePhase(.background)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    func testNothingIsRearmedWhileConnectedOrConnecting() {
        _ = fixture.appState.handleScenePhase(.active)
        fixture.appState.isConnected = true
        _ = fixture.appState.handleScenePhase(.inactive)
        XCTAssertTrue(recorder.delays.isEmpty, "a healthy socket needs no timer")
        fixture.appState.isConnected = false
        fixture.appState.isConnecting = true
        _ = fixture.appState.handleScenePhase(.background)
        XCTAssertTrue(recorder.delays.isEmpty, "a connect already in flight owns the flow")
    }

    /// The re-arm goes through `scheduleReconnect`, so it takes upstream's backoff
    /// (`PollCadence.reconnectDelay`, upstream 14370bc3: exponential from 1 s with jitter, full jitter
    /// and a 60 s cap off screen, an upper-half jitter and an 8 s cap on screen). The scene is
    /// inactive here, so the step is the off-screen one. The test reads the step from that API with
    /// the two inputs pinned (the jitter, and a usable network path, which the real monitor decides
    /// otherwise), instead of a literal that a change of the backoff breaks.
    func testRearmUsesTheBackoffNotAFixedRetry() {
        fixture.appState.reconnectJitter = { 0.75 }
        fixture.appState.deviceConditions = { DeviceConditions() }
        _ = fixture.appState.handleScenePhase(.active)
        _ = fixture.appState.handleScenePhase(.inactive)
        let firstStep = PollCadence.reconnectDelay(attempt: 0, random: 0.75, onScreen: false)
        XCTAssertEqual(recorder.delays, [firstStep], "the first re-arm waits one backoff step")
        XCTAssertGreaterThan(firstStep, 0.1, "and that step is not the 0.1 s of an immediate retry")
    }

    func testTheNextRearmWaitsTheNextBackoffStep() async {
        fixture.appState.reconnectJitter = { 0.75 }
        fixture.appState.deviceConditions = { DeviceConditions() }
        _ = fixture.appState.handleScenePhase(.active)
        _ = fixture.appState.handleScenePhase(.inactive)
        XCTAssertEqual(recorder.delays.count, 1)
        // The cycle runs and does not connect: the backoff step is consumed.
        await recorder.operations.first?()
        XCTAssertEqual(recorder.purposes.count, 1)
        _ = fixture.appState.handleScenePhase(.background)
        XCTAssertEqual(
            recorder.delays.last,
            PollCadence.reconnectDelay(attempt: 1, random: 0.75, onScreen: false),
            "the second wait is the second step of upstream's backoff"
        )
        XCTAssertGreaterThan(recorder.delays.last ?? 0, recorder.delays.first ?? 0)
    }

    // MARK: - A visible window is watched (Ruling R41)

    /// SwiftUI reports the scene `.inactive` whenever another app is active, also while a Conduit
    /// window is on screen (side by side, a second display). Upstream's `reconnectIsWatched` reads
    /// only `isSceneActive`, so the re-arm would use the off-screen backoff (up to 60 s, no
    /// readiness probe). A visible window counts as watched on Mac.
    func testRearmUsesTheOnScreenStepWhileAWindowIsVisibleButTheAppIsInactive() {
        fixture.appState.reconnectJitter = { 0.75 }
        fixture.appState.deviceConditions = { DeviceConditions() }
        MacTransportRecoveryPolicy.windowIsVisible = { true }
        _ = fixture.appState.handleScenePhase(.active)
        _ = fixture.appState.handleScenePhase(.inactive)
        XCTAssertFalse(fixture.appState.isSceneActive, "precondition: another app is active")
        let onScreen = PollCadence.reconnectDelay(attempt: 0, random: 0.75, onScreen: true)
        let offScreen = PollCadence.reconnectDelay(attempt: 0, random: 0.75, onScreen: false)
        XCTAssertNotEqual(onScreen, offScreen, "precondition: the two steps differ for this jitter")
        XCTAssertEqual(recorder.delays, [onScreen], "a visible window gets the on-screen step")
    }

    func testRearmStaysWithinTheOnScreenCapWhileAWindowIsVisible() async {
        fixture.appState.reconnectJitter = { 0.99 }
        fixture.appState.deviceConditions = { DeviceConditions() }
        MacTransportRecoveryPolicy.windowIsVisible = { true }
        _ = fixture.appState.handleScenePhase(.active)
        _ = fixture.appState.handleScenePhase(.inactive)
        // Each cycle runs and does not connect: five steps are consumed.
        for _ in 0..<5 {
            await recorder.operations.last?()
            _ = fixture.appState.handleScenePhase(.background)
        }
        XCTAssertEqual(recorder.delays.count, 6)
        XCTAssertLessThanOrEqual(
            recorder.delays.max() ?? 0, PollCadence.reconnectCapOnScreen,
            "no step is longer than the on-screen cap of 8 s (the off-screen step 5 would be about 31 s)")
        XCTAssertEqual(
            recorder.delays.last, PollCadence.reconnectDelay(attempt: 5, random: 0.99, onScreen: true))
    }

    func testRearmUsesTheOffScreenStepWhenNoWindowIsVisible() {
        fixture.appState.reconnectJitter = { 0.75 }
        fixture.appState.deviceConditions = { DeviceConditions() }
        MacTransportRecoveryPolicy.windowIsVisible = { false }
        _ = fixture.appState.handleScenePhase(.active)
        _ = fixture.appState.handleScenePhase(.inactive)
        XCTAssertEqual(recorder.delays, [PollCadence.reconnectDelay(attempt: 0, random: 0.75, onScreen: false)])
    }

    func testRearmIsOffWhenThePolicyIsOff() {
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = false
        _ = fixture.appState.handleScenePhase(.active)
        _ = fixture.appState.handleScenePhase(.inactive)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    func testTurningThePolicyOffRestoresTheSceneGate() {
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = false
        _ = fixture.appState.handleScenePhase(.background)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertTrue(recorder.delays.isEmpty, "with the policy off the iOS rule applies again")
    }
}
