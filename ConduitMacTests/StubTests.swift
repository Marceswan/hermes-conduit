import XCTest
@testable import ConduitMac

@MainActor
final class StubTests: XCTestCase {
    func testCarPlayAwaitConnectionReturnsFalseImmediately() async {
        let appState = AppStateRuntimeRegistry.shared.appState
        let connected = await CarPlayVoiceCoordinator.awaitConnection(of: appState, timeout: .seconds(5))
        XCTAssertFalse(connected)
    }

    func testNativeCallsNeverOfferRinging() {
        XCTAssertFalse(HermesNativeCalls.offersRinging)
    }

    func testNativeCallsAnsweredOnWatchIsNil() {
        XCTAssertNil(HermesNativeCalls.shared.answeredOnWatch(ringID: "x"))
    }
}
