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
