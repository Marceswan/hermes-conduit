import XCTest
@testable import ConduitMac

final class MacChatFindStateTests: XCTestCase {
    private func match(_ id: String, _ ordinal: Int = 0) -> MacChatFindMatch {
        MacChatFindMatch(messageID: id, ordinal: ordinal, range: NSRange(location: ordinal * 4, length: 3))
    }

    private let order = ["m1": 0, "m2": 1, "m3": 2, "m4": 3]

    private func state(_ matches: [MacChatFindMatch], anchor: MacChatFindState.Anchor = .newest) -> MacChatFindState {
        var s = MacChatFindState()
        s.replace(matches: matches, truncated: false, anchor: anchor)
        return s
    }

    func testFreshQuerySelectsTheNewestMatch() {
        let s = state([match("m1"), match("m2"), match("m3")])
        XCTAssertEqual(s.current, match("m3"))
        XCTAssertEqual(s.position, 3)
        XCTAssertEqual(s.count, 3)
    }

    func testNextAndPreviousWrap() {
        var s = state([match("m1"), match("m2"), match("m3")])
        s.next()
        XCTAssertEqual(s.position, 1, "wraps from last to first")
        s.previous()
        XCTAssertEqual(s.position, 3, "wraps from first to last")
        s.previous()
        XCTAssertEqual(s.position, 2)
    }

    func testStepsDoNothingWithoutMatches() {
        var s = state([])
        s.next(); s.previous()
        XCTAssertNil(s.current)
        XCTAssertNil(s.position)
        XCTAssertEqual(s.count, 0)
    }

    func testNearAnchorStaysOnTheSameMessageWhenItStillMatches() {
        let s = state([match("m1"), match("m2"), match("m4")], anchor: .near(messageID: "m2", order: order))
        XCTAssertEqual(s.current, match("m2"))
    }

    func testNearAnchorMovesToTheNextMessageDownWhenItsMessageNoLongerMatches() {
        let s = state([match("m1"), match("m4")], anchor: .near(messageID: "m2", order: order))
        XCTAssertEqual(s.current, match("m4"))
    }

    func testNearAnchorFallsBackToTheNewestWhenNothingIsBelow() {
        let s = state([match("m1"), match("m2")], anchor: .near(messageID: "m4", order: order))
        XCTAssertEqual(s.current, match("m2"))
    }

    func testNearAnchorWithAnUnknownMessageFallsBackToTheNewest() {
        let s = state([match("m1"), match("m2")], anchor: .near(messageID: "gone", order: order))
        XCTAssertEqual(s.current, match("m2"))
    }

    func testKeepingFindsTheSameMessageAndOrdinal() {
        let old = match("m2", 1)
        let s = state(
            [match("m1"), match("m2", 0), match("m2", 1), match("m3")],
            anchor: .keeping(old, order: order)
        )
        XCTAssertEqual(s.position, 3)
    }

    func testKeepingFallsBackToNearWhenTheHitVanished() {
        let s = state(
            [match("m1"), match("m3")],
            anchor: .keeping(match("m2", 5), order: order)
        )
        XCTAssertEqual(s.current, match("m3"))
    }

    func testReplaceWithNoMatchesClearsTheCursor() {
        var s = state([match("m1")])
        s.replace(matches: [], truncated: false, anchor: .keeping(match("m1"), order: order))
        XCTAssertNil(s.currentIndex)
        XCTAssertNil(s.current)
    }

    func testIndexNeverLeavesTheRangeAfterAShrinkingRefresh() {
        var s = state([match("m1"), match("m2"), match("m3")])
        s.replace(matches: [match("m1")], truncated: false, anchor: .keeping(match("m3"), order: order))
        XCTAssertEqual(s.currentIndex, 0)
        s.next()
        XCTAssertEqual(s.currentIndex, 0)
    }

    func testLabels() {
        var s = state([match("m1"), match("m2")])
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: s), "2 of 2")
        s.previous()
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: s), "1 of 2")
        XCTAssertEqual(MacChatFindLabel.text(query: "", state: s), "", "no query, no label")
        XCTAssertEqual(MacChatFindLabel.text(query: "  ", state: s), "")
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: state([])), "No matches")
        var capped = MacChatFindState()
        capped.replace(matches: [match("m1")], truncated: true, anchor: .newest)
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: capped), "1 of 1+")
    }
}
