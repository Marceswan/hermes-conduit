import XCTest
@testable import ConduitMac

final class MacApprovalChoiceMapperTests: XCTestCase {
    func testFullSetMapsToOnceAndDeny() {
        let m = MacApprovalChoiceMapper.map(choices: ["once", "session", "always", "deny"])
        XCTAssertEqual(m, .init(approve: "once", deny: "deny"))
    }

    func testSmartDeniedPairMapsToOnceAndDeny() {
        XCTAssertEqual(MacApprovalChoiceMapper.map(choices: ["once", "deny"]), .init(approve: "once", deny: "deny"))
    }

    func testNilChoicesFallBackToTheCardDefaults() {
        XCTAssertEqual(MacApprovalChoiceMapper.map(choices: nil), .init(approve: "once", deny: "deny"))
    }

    func testPermanentOnlyNeverOffersApprove() {
        let m = MacApprovalChoiceMapper.map(choices: ["always", "deny"])
        XCTAssertNil(m.approve, "always is never offered from a notification")
        XCTAssertEqual(m.deny, "deny")
    }

    func testSessionOnlyNeverOffersApprove() {
        XCTAssertNil(MacApprovalChoiceMapper.map(choices: ["session", "deny"]).approve)
    }

    func testDenyAbsentDropsDeny() {
        let m = MacApprovalChoiceMapper.map(choices: ["once"])
        XCTAssertEqual(m.approve, "once")
        XCTAssertNil(m.deny)
    }

    func testEmptyAndUnknownChoicesMapToNothing() {
        XCTAssertTrue(MacApprovalChoiceMapper.map(choices: []).isEmpty)
        XCTAssertTrue(MacApprovalChoiceMapper.map(choices: ["maybe"]).isEmpty)
    }

    func testMatchingIsExactNotCaseFolded() {
        XCTAssertTrue(MacApprovalChoiceMapper.map(choices: ["Once", "DENY"]).isEmpty,
                      "the wire values are lowercase literals; a near-miss must not be sent")
    }
}
