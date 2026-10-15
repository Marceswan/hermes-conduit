import XCTest
@testable import ConduitMac

final class MacUntrustedTextQuickAskTests: XCTestCase {
    private func clean(_ raw: String, _ max: Int = 100) -> String {
        MacUntrustedText.sanitize(raw, maxGraphemes: max)
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(clean("terminal"), "terminal")
        XCTAssertEqual(clean("Zoë 日本語 🚀"), "Zoë 日本語 🚀")
    }

    func testBidiControlsAreStripped() {
        XCTAssertEqual(clean("a\u{202E}b\u{202C}c"), "abc")
        XCTAssertEqual(clean("\u{2066}x\u{2069}\u{200E}\u{200F}\u{061C}y"), "xy")
    }

    func testFormatCharactersAreStripped() {
        XCTAssertEqual(clean("a\u{200B}b\u{200D}c\u{FEFF}d\u{00AD}e"), "abcde")
        XCTAssertEqual(clean("t\u{E0041}ag"), "tag", "tag characters are Cf")
    }

    func testLineAndParagraphSeparatorsAreDropped() {
        XCTAssertEqual(clean("a\u{2028}b\u{2029}c"), "abc")
    }

    func testWhitespaceControlsBecomeOneSpaceAndTheEndsAreTrimmed() {
        XCTAssertEqual(clean("  a\n\tb \r\n c  "), "a b c")
        XCTAssertEqual(clean("\n\n"), "")
    }

    func testOtherControlsAreDropped() {
        XCTAssertEqual(clean("a\u{0007}b\u{0000}c\u{001B}[31md"), "abc[31md")
    }

    func testCapsByGraphemeAndEndsInAnEllipsis() {
        XCTAssertEqual(clean("abcdefghij", 5), "abcd\u{2026}")
        XCTAssertEqual(clean("abcde", 5), "abcde")
        XCTAssertEqual(clean("🚀🚀🚀🚀", 3), "🚀🚀\u{2026}", "a grapheme is one unit")
        XCTAssertEqual(clean("abc", 0), "")
    }

    func testVeryLongInputIsBounded() {
        let raw = String(repeating: "x", count: 5_000_000)
        XCTAssertEqual(clean(raw, 20).count, 20)
    }
}
