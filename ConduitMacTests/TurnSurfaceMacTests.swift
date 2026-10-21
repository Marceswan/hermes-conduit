import XCTest
@testable import ConduitMac

/// Just before a send, Conduit tells the notifier plugin where the message
/// came from (`TurnSurface`, upstream #888). The Mac UIKit shim reports the
/// iPad idiom so that upstream's wide-layout paths run, so the surface of the
/// Mac app must not follow the idiom: Hermes would be told "iPad".
@MainActor
final class TurnSurfaceMacTests: XCTestCase {
    func testTheDeviceOfTheMacAppIsMac() {
        XCTAssertEqual(TurnSurface.device, .mac)
    }

    func testATypedMessageComesFromTheMac() {
        let surface = TurnSurface.message(spoken: false, carPlay: false)
        XCTAssertEqual(surface, TurnSurface(place: .mac, input: .typed))
    }

    func testASpokenMessageComesFromTheMac() {
        let surface = TurnSurface.message(spoken: true, carPlay: false)
        XCTAssertEqual(surface, TurnSurface(place: .mac, input: .spoken))
    }

    func testTheWireValueIsMac() {
        let body = TurnSurface.message(spoken: false, carPlay: false)
            .body(runtimeSessionID: "r1", text: "hi")
        XCTAssertEqual(body["surface"] as? String, "mac")
        XCTAssertEqual(body["input"] as? String, "typed")
    }

    func testTheShortcutSurfaceIsNotChanged() {
        XCTAssertEqual(TurnSurface.shortcut, TurnSurface(place: .siri, input: nil))
    }
}
