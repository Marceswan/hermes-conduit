import XCTest
@testable import ConduitMac

final class MacUntrustedTextTests: XCTestCase {
    private func clean(_ s: String, limit: Int = 160) -> String { MacUntrustedText.sanitize(s, maxGraphemes: limit) }

    // MARK: each dropped category

    func testBidiOverridesEmbeddingsAndIsolatesAreRemoved() {
        for scalar in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let r = MacUntrustedText.sanitizeReport("ab\(String(UnicodeScalar(scalar)!))cd", maxGraphemes: 160)
            XCTAssertEqual(r.text, "abcd", String(scalar, radix: 16))
            XCTAssertTrue(r.changed)
        }
        XCTAssertEqual(clean("rm\u{202E} gpj.txt"), "rm gpj.txt")
    }

    func testLRMRLMAndALMAreRemoved() {
        for scalar in [0x200E, 0x200F, 0x061C] {
            XCTAssertEqual(clean("ab\(String(UnicodeScalar(scalar)!))cd"), "abcd", String(scalar, radix: 16))
        }
    }

    func testZeroWidthSoftHyphenWordJoinerAndBOMAreRemoved() {
        XCTAssertEqual(clean("l\u{200B}s\u{200C}-\u{2060}la\u{FEFF}\u{00AD}"), "ls-la")
    }

    func testLineAndParagraphSeparatorsAreDropped() {
        let r = MacUntrustedText.sanitizeReport("a\u{2028}b\u{2029}c", maxGraphemes: 160)
        XCTAssertEqual(r.text, "abc")
        XCTAssertTrue(r.changed, "the text is not a faithful copy, so an approval needs review")
    }

    func testTagCharactersAreRemoved() {
        // "ls" spelled in the tag block is invisible; a flag-tag sequence loses its tags too.
        let tags = String(String.UnicodeScalarView([0xE0001, 0xE006C, 0xE0073, 0xE007F].compactMap(Unicode.Scalar.init)))
        let r = MacUntrustedText.sanitizeReport("ok\(tags)", maxGraphemes: 160)
        XCTAssertEqual(r.text, "ok")
        XCTAssertTrue(r.changed)
    }

    func testControlPrivateUseAndUnassignedAreRemoved() {
        let r = MacUntrustedText.sanitizeReport("a\u{0000}b\u{001B}c\u{007F}d\u{E000}e\u{0378}f", maxGraphemes: 160)
        XCTAssertEqual(r.text, "abcdef")
        XCTAssertTrue(r.changed)
    }

    // MARK: whitespace

    func testTabsNewlinesAndSpaceSeparatorsBecomeOneSpace() {
        XCTAssertEqual(clean("a\tb\nc\r\nd\u{00A0}e\u{2003}f\u{3000}g"), "a b c d e f g")
        XCTAssertEqual(clean("  ls   -la \n"), "ls -la")
        XCTAssertFalse(MacUntrustedText.sanitizeReport("  ls   -la \n", maxGraphemes: 160).changed, "collapsing whitespace is not stripping")
    }

    // MARK: emoji

    func testEmojiZWJSequencesArePreserved() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let r = MacUntrustedText.sanitizeReport("ok \(family)", maxGraphemes: 160)
        XCTAssertEqual(r.text, "ok \(family)")
        XCTAssertFalse(r.changed)
        let heartOnFire = "\u{2764}\u{FE0F}\u{200D}\u{1F525}"
        XCTAssertEqual(clean(heartOnFire), heartOnFire)
    }

    func testZWJOutsideAnEmojiSequenceIsRemoved() {
        for text in ["a\u{200D}b", "\u{1F468}\u{200D}b", "a\u{200D}\u{1F469}", "\u{1F468}\u{200D}", "\u{200D}\u{1F468}", "1\u{200D}2"] {
            let r = MacUntrustedText.sanitizeReport(text, maxGraphemes: 160)
            XCTAssertFalse(r.text.unicodeScalars.contains("\u{200D}"), text)
            XCTAssertTrue(r.changed, text)
        }
    }

    // MARK: Zalgo and normalization

    func testCombiningMarksAreCappedAtTwoPerBase() {
        let zalgo = "e" + String(repeating: "\u{0301}", count: 40) + "x"
        let r = MacUntrustedText.sanitizeReport(zalgo, maxGraphemes: 160)
        XCTAssertEqual(r.text.unicodeScalars.filter { $0.properties.generalCategory == .nonspacingMark }.count, MacUntrustedText.maxCombiningMarks)
        XCTAssertTrue(r.text.hasSuffix("x"))
        XCTAssertTrue(r.changed)
        XCTAssertLessThanOrEqual(r.text.unicodeScalars.count, 4)
    }

    func testNormalCombiningSequencesSurviveAndNFCComposes() {
        XCTAssertEqual(clean("cafe\u{0301}"), "caf\u{00E9}", "NFC composes e + acute")
        XCTAssertFalse(MacUntrustedText.sanitizeReport("cafe\u{0301}", maxGraphemes: 160).changed)
    }

    func testMarksAfterASpaceDoNotEvadeTheCap() {
        let r = MacUntrustedText.sanitizeReport(" " + String(repeating: "\u{0301}", count: 10), maxGraphemes: 160)
        XCTAssertLessThanOrEqual(r.text.unicodeScalars.count, 2)
    }

    // MARK: length

    func testVeryLongStringIsCappedWithAVisibleEllipsis() {
        let r = MacUntrustedText.sanitizeReport("echo " + String(repeating: "A", count: 500_000), maxGraphemes: 160)
        XCTAssertEqual(r.text.count, 160)
        XCTAssertTrue(r.text.hasSuffix(MacUntrustedText.ellipsis))
        XCTAssertTrue(r.truncated)
    }

    func testLengthIsCountedInGraphemesNotScalars() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let r = MacUntrustedText.sanitizeReport(String(repeating: family, count: 20), maxGraphemes: 10)
        XCTAssertEqual(r.text.count, 10)
        XCTAssertTrue(r.text.hasSuffix(MacUntrustedText.ellipsis))
    }

    func testStringExactlyAtTheLimitIsNotTruncated() {
        let r = MacUntrustedText.sanitizeReport(String(repeating: "b", count: 160), maxGraphemes: 160)
        XCTAssertEqual(r.text.count, 160)
        XCTAssertFalse(r.truncated)
    }

    func testNoTrailingSpaceBeforeTheEllipsis() {
        let r = MacUntrustedText.sanitizeReport(String(repeating: "a ", count: 100), maxGraphemes: 11)
        XCTAssertFalse(r.text.dropLast().hasSuffix(" "))
        XCTAssertTrue(r.text.hasSuffix(MacUntrustedText.ellipsis))
    }

    // MARK: no interpretation

    func testMarkdownAndLinksStayLiteralForVerbatimRendering() {
        let text = "[Allow](https://evil.example) **ok** <https://x.example>"
        XCTAssertEqual(clean(text), text, "the sanitizer never interprets Markdown; views render with Text(verbatim:)")
    }

    func testStringAPIAndReportAgree() {
        for raw in ["plain", "a\u{202E}b", String(repeating: "z", count: 400), "e" + String(repeating: "\u{0301}", count: 9), "\u{200B}"] {
            XCTAssertEqual(MacUntrustedText.sanitize(raw, maxGraphemes: 50), MacUntrustedText.sanitizeReport(raw, maxGraphemes: 50).text)
        }
        XCTAssertEqual(MacUntrustedText.sanitize("abc", maxGraphemes: 0), "")
    }

    func testReportFlagsChangedAndTruncatedSeparately() {
        let clean = MacUntrustedText.sanitizeReport("ls -la", maxGraphemes: 50)
        XCTAssertEqual(clean, MacUntrustedText.Report(text: "ls -la", truncated: false, changed: false))
        let hidden = MacUntrustedText.sanitizeReport("l\u{200B}s", maxGraphemes: 50)
        XCTAssertTrue(hidden.changed); XCTAssertFalse(hidden.truncated)
        let long = MacUntrustedText.sanitizeReport(String(repeating: "x", count: 100), maxGraphemes: 10)
        XCTAssertTrue(long.truncated); XCTAssertFalse(long.changed)
    }

    func testEmptyAndInvisibleOnlyInputsBecomeEmpty() {
        XCTAssertEqual(clean("", limit: 10), "")
        XCTAssertEqual(clean("\u{200B}\u{202E} \n", limit: 10), "")
    }
}
