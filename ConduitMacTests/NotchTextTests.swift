import XCTest
@testable import ConduitMac

final class NotchTextTests: XCTestCase {
    func testBidiOverridesAndIsolatesAreRemoved() {
        let bidi = "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}\u{061C}"
        let r = NotchText.sanitize("rm\(bidi) -rf /tmp/x\u{202E}txt.", limit: 160)
        XCTAssertEqual(r.text, "rm -rf /tmp/xtxt.")
        XCTAssertTrue(r.stripped)
        for scalar in r.text.unicodeScalars {
            XCTAssertFalse((0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value))
        }
    }

    func testZeroWidthAndOtherInvisibleCharactersAreRemoved() {
        let r = NotchText.sanitize("l\u{200B}s\u{200C} \u{200D}-\u{2060}la\u{FEFF}\u{00AD}", limit: 160)
        XCTAssertEqual(r.text, "ls -la")
        XCTAssertTrue(r.stripped)
    }

    func testControlCharactersAreRemovedButNewlinesAndTabsBecomeOneSpace() {
        let r = NotchText.sanitize("echo\u{0000}hi\u{001B}[31m\nsecond\r\n\tthird\u{2028}fourth\u{0085}", limit: 160)
        XCTAssertEqual(r.text, "echohi[31m second third fourth")
        XCTAssertFalse(r.text.contains("\n"))
        XCTAssertTrue(r.stripped, "NUL and ESC are dropped")
    }

    func testPlainWhitespaceCollapsingIsNotReportedAsStripped() {
        let r = NotchText.sanitize("  ls   -la \n", limit: 160)
        XCTAssertEqual(r.text, "ls -la")
        XCTAssertFalse(r.stripped)
        XCTAssertFalse(r.truncated)
    }

    func testVeryLongStringIsCappedWithAVisibleEllipsis() {
        let r = NotchText.sanitize("echo " + String(repeating: "A", count: 500_000), limit: 160)
        XCTAssertEqual(r.text.count, 160)
        XCTAssertTrue(r.text.hasSuffix(NotchText.ellipsis))
        XCTAssertTrue(r.truncated)
    }

    func testStringExactlyAtTheLimitIsNotTruncated() {
        let r = NotchText.sanitize(String(repeating: "b", count: 160), limit: 160)
        XCTAssertEqual(r.text.count, 160)
        XCTAssertFalse(r.truncated)
        XCTAssertFalse(r.text.hasSuffix(NotchText.ellipsis))
    }

    func testNoTrailingSpaceBeforeTheEllipsis() {
        let r = NotchText.sanitize(String(repeating: "a ", count: 100), limit: 11)
        XCTAssertFalse(r.text.dropLast().hasSuffix(" "))
        XCTAssertTrue(r.text.hasSuffix(NotchText.ellipsis))
    }

    func testMarkdownAndLinksAreLeftAsLiteralTextForVerbatimRendering() {
        let r = NotchText.sanitize("[Allow](https://evil.example) **ok**", limit: 160)
        XCTAssertEqual(r.text, "[Allow](https://evil.example) **ok**", "the sanitizer does not interpret Markdown; the views render with Text(verbatim:)")
    }

    func testEmptyAndInvisibleOnlyInputsBecomeEmpty() {
        XCTAssertEqual(NotchText.clean("", limit: 10), "")
        XCTAssertEqual(NotchText.clean("\u{200B}\u{202E} \n", limit: 10), "")
    }
}
