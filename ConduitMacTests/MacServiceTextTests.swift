import XCTest
@testable import ConduitMac

final class MacServiceTextTests: XCTestCase {
    func testNormalizeTrimsAndRejectsEmpty() {
        XCTAssertEqual(MacServiceText.normalize("  hi \n"), "hi")
        XCTAssertNil(MacServiceText.normalize("   \n\t"))
        XCTAssertNil(MacServiceText.normalize(nil))
    }

    func testNormalizeTruncatesAtTheCapWithANote() {
        let long = String(repeating: "a", count: MacServiceText.limit + 500)
        let out = MacServiceText.normalize(long)!
        XCTAssertTrue(out.hasSuffix("\n[truncated]"))
        XCTAssertEqual(out.count, MacServiceText.limit + "\n[truncated]".count)
        let exact = String(repeating: "b", count: MacServiceText.limit)
        XCTAssertEqual(MacServiceText.normalize(exact), exact, "exactly at the cap is not truncated")
    }

    func testNormalizeCountsCharactersNotBytes() {
        let emoji = String(repeating: "\u{1F600}", count: MacServiceText.limit)
        XCTAssertEqual(MacServiceText.normalize(emoji)?.count, MacServiceText.limit)
    }
}
