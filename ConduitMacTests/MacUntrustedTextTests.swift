import XCTest
@testable import ConduitMac

final class MacUntrustedTextTests: XCTestCase {
    private func clean(_ text: String, _ max: Int = 200) -> String {
        MacUntrustedText.sanitize(text, maxGraphemes: max)
    }

    func testBidiOverridesEmbeddingsAndIsolatesAreDropped() {
        XCTAssertEqual(clean("rm\u{202E} -rf\u{202A}\u{202B}\u{202C}\u{202D} /\u{2066}x\u{2067}\u{2068}\u{2069}"), "rm -rf /x")
    }

    func testDirectionalMarksAreDropped() {
        XCTAssertEqual(clean("a\u{200E}b\u{200F}c\u{061C}d"), "abcd", "LRM, RLM and ALM")
    }

    func testLineAndParagraphSeparatorsBecomeASpace() {
        XCTAssertEqual(clean("a\u{2028}b\u{2029}c"), "a b c")
        XCTAssertEqual(clean("a\nb\r\nc\td"), "a b c d")
    }

    func testBOMAndZeroWidthCharactersAreDropped() {
        XCTAssertEqual(clean("\u{FEFF}ls\u{200B}-la\u{200C}\u{2060}"), "ls-la")
    }

    func testTagCharactersAreDropped() {
        XCTAssertEqual(clean("ok\u{E0041}\u{E0042}\u{E007F}"), "ok")
    }

    func testPrivateUseAndUnassignedAndOtherControlsAreDropped() {
        XCTAssertEqual(clean("a\u{E000}b\u{0378}c\u{0007}d\u{0000}e\u{007F}f"), "abcdef")
    }

    func testWhitespaceCollapsesAndEdgesTrim() {
        XCTAssertEqual(clean("  a \u{00A0}\u{3000} b  "), "a b")
        XCTAssertEqual(clean(" \n\t "), "")
    }

    func testTextIsNFCNormalized() {
        XCTAssertEqual(clean("e\u{0301}"), "\u{00E9}")
    }

    func testZalgoCombiningMarksAreCappedAtTwoPerBase() {
        let zalgo = "a" + String(repeating: "\u{0301}\u{0316}\u{0489}", count: 10) + "b"
        let result = clean(zalgo)
        XCTAssertLessThanOrEqual(result.unicodeScalars.count, 4, "base, at most two marks, b (NFC may fold the base)")
        XCTAssertEqual(result.count, 2, "two graphemes")
        XCTAssertTrue(result.hasSuffix("b"))
    }

    func testEmojiZWJSequencesArePreserved() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(clean("hi \(family)"), "hi \(family)")
        XCTAssertEqual(clean(family).count, 1)
        let runner = "\u{1F3C3}\u{200D}\u{2640}\u{FE0F}"
        XCTAssertEqual(clean(runner), runner)
    }

    func testZWJOutsideAnEmojiSequenceIsDropped() {
        XCTAssertEqual(clean("r\u{200D}m"), "rm")
        XCTAssertEqual(clean("1\u{200D}2"), "12", "digits are not pictographs")
        XCTAssertEqual(clean("\u{1F468}\u{200D}x"), "\u{1F468}x")
        XCTAssertEqual(clean("\u{1F468} \u{200D}\u{1F469}"), "\u{1F468} \u{1F469}", "a space between does not make a sequence")
    }

    func testLongStringsAreCappedByGraphemesWithAnEllipsis() {
        let result = clean(String(repeating: "z", count: 50), 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.hasSuffix("\u{2026}"))
        XCTAssertEqual(clean(String(repeating: "z", count: 10), 10), String(repeating: "z", count: 10), "exactly at the cap is untouched")
        let emoji = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 20)
        XCTAssertEqual(clean(emoji, 5).count, 5, "a family counts as one grapheme, never split")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(clean("swift test --filter Foo"), "swift test --filter Foo")
        XCTAssertEqual(clean("caf\u{00E9} \u{65E5}\u{672C}\u{8A9E}"), "caf\u{00E9} \u{65E5}\u{672C}\u{8A9E}")
    }
}

final class MacUntrustedTextBoundsTests: XCTestCase {
    private func clean(_ text: String, _ max: Int = 200) -> String {
        MacUntrustedText.sanitize(text, maxGraphemes: max)
    }

    func testAChainOfJoinedPictographsCannotDefeatTheGraphemeCap() {
        // Joined emoji form ONE grapheme, so a long chain would pass a grapheme-count cap untouched.
        let chain = Array(repeating: "\u{1F468}", count: 5000).joined(separator: "\u{200D}")
        XCTAssertEqual(chain.count, 1, "the premise: one grapheme")
        let result = clean(chain, 80)
        XCTAssertLessThanOrEqual(result.count, 80)
        let longest = result.map { $0.unicodeScalars.count }.max() ?? 0
        XCTAssertLessThanOrEqual(longest, 2 * MacUntrustedText.maxJoinersPerSequence + 1, "no grapheme chains more than the joiner cap")
    }

    func testARealisticFamilySequenceIsStillKeptWhole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(clean(family), family)
    }

    func testAHugeInputIsBoundedAndEndsWithAnEllipsis() {
        let huge = String(repeating: "a ", count: 2_000_000)
        let result = clean(huge, 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.hasSuffix("\u{2026}"))
    }

    func testAClippedInputAlwaysShowsAnEllipsisEvenIfWhitespaceFollowsTheKeptPart() {
        let text = String(repeating: "z", count: 100_000) + String(repeating: " ", count: 1_000_000) + "tail"
        let result = clean(text, 10)
        XCTAssertTrue(result.hasSuffix("\u{2026}"))
        XCTAssertEqual(result.count, 10)
    }
}

// Report API (notch): flags for callers that must not trust a rewritten string.
final class MacUntrustedTextReportTests: XCTestCase {
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

    func testLineAndParagraphSeparatorsBecomeASpaceAndCountAsChanged() {
        let r = MacUntrustedText.sanitizeReport("a\u{2028}b\u{2029}c", maxGraphemes: 160)
        XCTAssertEqual(r.text, "a b c")
        XCTAssertTrue(r.changed, "a flattened line break is not a faithful copy, so an approval needs review")
    }

    func testInteriorNewlinesAreChangedButTrailingOnesAreNot() {
        XCTAssertTrue(MacUntrustedText.sanitizeReport("ls\nrm -rf x", maxGraphemes: 160).changed)
        XCTAssertTrue(MacUntrustedText.sanitizeReport("ls\r\nrm", maxGraphemes: 160).changed)
        XCTAssertFalse(MacUntrustedText.sanitizeReport("ls\n", maxGraphemes: 160).changed)
        XCTAssertFalse(MacUntrustedText.sanitizeReport("\n ls\ta", maxGraphemes: 160).changed)
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
