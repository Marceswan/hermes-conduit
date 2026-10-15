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
    }

    override func tearDown() async throws {
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = true
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

    func testTurningThePolicyOffRestoresTheSceneGate() {
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = false
        _ = fixture.appState.handleScenePhase(.background)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertTrue(recorder.delays.isEmpty, "with the policy off the iOS rule applies again")
    }
}
