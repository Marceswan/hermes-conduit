import CoreSpotlight
import XCTest
@testable import ConduitMac

final class MacSpotlightContinuationTests: XCTestCase {
    private let scope = MacSpotlightScope(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"), profile: "work")

    private func info(_ id: String) -> [AnyHashable: Any] { [CSSearchableItemActivityIdentifier: id] }

    func testOwnItemOpensTheSessionOnItsProfile() {
        let raw = MacSpotlightItemID.make(scope: scope, sessionID: "sess.1")
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: scope.dashboardKey),
            .open(.session(id: "sess.1", profile: "work")))
    }

    func testSessionIDWithPipesAndProfileWithSpacesSurvives() {
        let odd = MacSpotlightScope(dashboardID: nil, profile: "My Profile|x")
        let raw = MacSpotlightItemID.make(scope: odd, sessionID: "a|b|c")
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: "none"),
            .open(.session(id: "a|b|c", profile: "My Profile|x")))
    }

    func testForeignDashboardIsReportedNotOpened() {
        let raw = MacSpotlightItemID.make(scope: scope, sessionID: "x")
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: "other"), .foreignDashboard)
    }

    func testMalformedOrMissingIsIgnored() {
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: info("garbage"), currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: [:], currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: nil, currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: [CSSearchableItemActivityIdentifier: 42], currentDashboardKey: "none"), .ignored)
    }

    func testMalformedIsIgnoredEvenWhenTheDashboardWouldMatch() {
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(userInfo: info("conduit|none|p|"), currentDashboardKey: "none"), .ignored)
    }
}
