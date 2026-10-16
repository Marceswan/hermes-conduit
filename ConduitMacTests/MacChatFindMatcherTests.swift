import XCTest
@testable import ConduitMac

final class MacChatFindMatcherTests: XCTestCase {
    func testCaseAndDiacriticInsensitive() {
        let hits = MacChatFindMatcher.ranges(of: "cafe", in: "Café CAFÉ cafe")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.first, NSRange(location: 0, length: 4))
    }

    func testAccentedQueryFindsPlainLetters() {
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "café", in: "cafe CAFE").count, 2)
    }

    func testHitsDoNotOverlap() {
        XCTAssertEqual(
            MacChatFindMatcher.ranges(of: "aa", in: "aaaa"),
            [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)]
        )
    }

    func testQueryIsLiteral() {
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "[x](", in: "see [x](y) and [x](z)").count, 2)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "a.c", in: "abc a.c").count, 1)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "*", in: "a*b**c").count, 3)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "\\", in: "a\\b").count, 1)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "(", in: "f(x) g(y)").count, 2)
    }

    func testEmptyAndWhitespaceQueriesMatchNothing() {
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "", in: "abc").isEmpty)
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "   ", in: "a b c").isEmpty)
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "\n", in: "a\nb").isEmpty)
        XCTAssertFalse(MacChatFindMatcher.isSearchable(" \t"))
        XCTAssertTrue(MacChatFindMatcher.isSearchable(" a"))
    }

    func testQueryKeepsInnerAndTrailingSpaces() {
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "a b ", in: "a b c"), [NSRange(location: 0, length: 4)])
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "a b ", in: "a bc").isEmpty)
    }

    func testRangesAreUTF16InNonBMPText() {
        XCTAssertEqual(
            MacChatFindMatcher.ranges(of: "\u{1F600}", in: "x\u{1F600}y\u{1F600}"),
            [NSRange(location: 1, length: 2), NSRange(location: 4, length: 2)]
        )
    }

    func testMatchesAreInEntryOrderWithPerMessageOrdinals() {
        let entries = [
            MacChatFindEntry(id: "m1", text: "foo bar foo"),
            MacChatFindEntry(id: "m2", text: "nothing here"),
            MacChatFindEntry(id: "m3", text: "FOO"),
        ]
        let result = MacChatFindMatcher.matches(of: "foo", in: entries)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.matches.map(\.messageID), ["m1", "m1", "m3"])
        XCTAssertEqual(result.matches.map(\.ordinal), [0, 1, 0])
        XCTAssertEqual(result.matches[1].range, NSRange(location: 8, length: 3))
    }

    func testCapTruncatesAndFlagsOnlyWhenMoreExist() {
        let entries = (1...3).map { MacChatFindEntry(id: "m\($0)", text: "x x x x") }
        let capped = MacChatFindMatcher.matches(of: "x", in: entries, limit: 5)
        XCTAssertEqual(capped.matches.count, 5)
        XCTAssertTrue(capped.truncated)
        let exact = MacChatFindMatcher.matches(of: "x", in: entries, limit: 12)
        XCTAssertEqual(exact.matches.count, 12)
        XCTAssertFalse(exact.truncated, "exactly the limit is not truncation")
        let tail = MacChatFindMatcher.matches(
            of: "x", in: entries + [MacChatFindEntry(id: "m4", text: "none")], limit: 12
        )
        XCTAssertFalse(tail.truncated, "later entries without hits do not flag truncation")
    }

    func testHugeSingleMessageStaysBounded() {
        let entry = MacChatFindEntry(id: "big", text: String(repeating: "needle ", count: 200_000))
        let result = MacChatFindMatcher.matches(of: "needle", in: [entry])
        XCTAssertEqual(result.matches.count, MacChatFindMatcher.defaultLimit)
        XCTAssertTrue(result.truncated)
    }
}
