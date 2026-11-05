import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowRegistryTests: XCTestCase {
    private func token(_ id: String) -> MacSessionWindowToken {
        MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: id)
    }

    func testTokenCodingRoundTrip() throws {
        let original = MacSessionWindowToken(dashboardID: UUID(), profile: "work", sessionID: "s1")
        let decoded = try JSONDecoder().decode(MacSessionWindowToken.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRequestedTokenAppears() {
        let registry = MacSessionWindowRegistry()
        XCTAssertTrue(registry.request(token("a")))
        XCTAssertTrue(registry.appeared(token("a")))
        XCTAssertEqual(registry.open, [token("a")])
    }

    func testUnrequestedTokenIsRejected() {
        // A window SwiftUI restored at relaunch was never requested in this run.
        let registry = MacSessionWindowRegistry()
        XCTAssertFalse(registry.appeared(token("restored")))
        XCTAssertTrue(registry.open.isEmpty)
    }

    func testCapAllowsReopeningAnOpenToken() {
        let registry = MacSessionWindowRegistry()
        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(registry.request(token(id)))
            XCTAssertTrue(registry.appeared(token(id)))
        }
        XCTAssertTrue(registry.isFull)
        XCTAssertFalse(registry.request(token("e")), "a fifth window is refused")
        XCTAssertTrue(registry.request(token("b")), "an open window is focused, not counted again")
    }

    func testDisappearFreesTheSlotAndForgetsTheRequest() {
        let registry = MacSessionWindowRegistry()
        _ = registry.request(token("a")); _ = registry.appeared(token("a"))
        registry.disappeared(token("a"))
        XCTAssertTrue(registry.open.isEmpty)
        XCTAssertFalse(registry.appeared(token("a")), "closing forgets the request")
    }

    func testPendingRequestsCountTowardTheCap() {
        let registry = MacSessionWindowRegistry()
        for id in ["a", "b", "c", "d"] { XCTAssertTrue(registry.request(token(id))) }
        XCTAssertFalse(registry.request(token("e")))
    }
}
