import XCTest
@testable import ConduitMac

final class MacPaletteMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ranked(_ items: [MacPaletteItem], _ query: String, recents: [String] = []) -> [String] {
        MacPaletteMatcher.rank(items, query: query, recentIDs: recents, now: now).map(\.title)
    }

    func testTierOrderExactPrefixWordStartSubstringFuzzyKeyword() {
        let items = [
            MacPaletteItem.fixture("Zebra", keywords: ["settings"]),       // keyword
            .fixture("Sound effects tab"),                                  // fuzzy s-e-t
            .fixture("Reset"),                                              // substring
            .fixture("Chat Settings"),                                      // word start
            .fixture("Settings"),                                           // prefix
            .fixture("Set"),                                                // exact
        ]
        XCTAssertEqual(ranked(items, "set"),
                       ["Set", "Settings", "Chat Settings", "Reset", "Sound effects tab", "Zebra"])
    }

    func testCaseAndDiacriticInsensitive() {
        let items = [MacPaletteItem.fixture("Caf\u{E9} Menu")]
        XCTAssertEqual(ranked(items, "CAFE"), ["Caf\u{E9} Menu"])
        XCTAssertEqual(ranked([.fixture("cafe")], "Caf\u{E9}"), ["cafe"])
    }

    func testAllTokensMustMatchAndShortFuzzyDoesNot() {
        let items = [MacPaletteItem.fixture("New Chat")]
        XCTAssertEqual(ranked(items, "new ch"), ["New Chat"])
        XCTAssertEqual(ranked(items, "  new   ch  "), ["New Chat"])
        XCTAssertEqual(ranked(items, "new xx"), [])
        XCTAssertEqual(ranked(items, "nc"), [], "fuzzy needs 3 characters")
        XCTAssertEqual(ranked(items, "nch"), ["New Chat"], "3 characters fuzzy-match in order")
        XCTAssertEqual(ranked(items, "hcn"), [], "out of order never matches")
    }

    func testSlashTitleMatchesWithoutItsSlash() {
        let items = [MacPaletteItem.fixture("/model", kind: .slash), .fixture("Model Picker")]
        XCTAssertEqual(ranked(items, "model"), ["/model", "Model Picker"], "exact beats prefix")
    }

    func testKindWeightsBreakTiesWithinATier() {
        let items = ["session", "profile", "slash", "pane", "command"].map { kind in
            MacPaletteItem.fixture("Alpha", kind: MacPaletteKind(rawValue: kind)!, id: "\(kind):x")
        }
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "alpha", recentIDs: [], now: now).map(\.id),
                       ["command:x", "pane:x", "slash:x", "profile:x", "session:x"])
    }

    func testRecencyBoostDecaysAndNeverCrossesATier() {
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 0), 60)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 1), 54)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 9), 6)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 10), 0)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: nil), 0)

        let both = [MacPaletteItem.fixture("Beta one", id: "b"), .fixture("Alpha one", id: "a")]
        XCTAssertEqual(ranked(both, "one", recents: ["b"]), ["Beta one", "Alpha one"], "recent wins a tie")
        let tiers = [MacPaletteItem.fixture("Open", id: "o"), .fixture("Reopen", id: "r")]
        XCTAssertEqual(ranked(tiers, "open", recents: ["r"]), ["Open", "Reopen"], "exact still beats a recent substring")
    }

    func testTieBreaksRecencyThenTitleThenID() {
        let items = [MacPaletteItem.fixture("Same", id: "z"), .fixture("Same", id: "a"), .fixture("Same", id: "m")]
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "same", recentIDs: [], now: now).map(\.id), ["a", "m", "z"])
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "same", recentIDs: ["m"], now: now).map(\.id), ["m", "a", "z"])
    }

    func testDisabledRanksLastWithinItsTier() {
        let items = [MacPaletteItem.fixture("Alpha disabled", id: "d", enabled: false), .fixture("Alpha enabled", id: "e")]
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "alpha", recentIDs: ["d"], now: now).map(\.id), ["e", "d"])
        let tiers = [MacPaletteItem.fixture("Alpha", id: "x", enabled: false), .fixture("Big alpha", id: "y")]
        XCTAssertEqual(MacPaletteMatcher.rank(tiers, query: "alpha", recentIDs: [], now: now).map(\.id), ["x", "y"],
                       "a disabled exact match still beats an enabled word-start match")
    }

    func testSessionActivityBoost() {
        let day: TimeInterval = 86_400
        let items = [
            MacPaletteItem.fixture("Chat plain", kind: .session, id: "session:plain"),
            .fixture("Chat unread", kind: .session, id: "session:unread", unread: true),
            .fixture("Chat fresh", kind: .session, id: "session:fresh", lastActivityAt: now.timeIntervalSince1970 - 3600),
            .fixture("Chat active", kind: .session, id: "session:active", unread: true, active: true,
                     lastActivityAt: now.timeIntervalSince1970 - 60),
            .fixture("Chat old", kind: .session, id: "session:old", lastActivityAt: now.timeIntervalSince1970 - 3 * day),
        ]
        // unread +10, fresh +5, then the zero-boost rows by title: active, old, plain
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "chat", recentIDs: [], now: now).map(\.id),
                       ["session:unread", "session:fresh", "session:active", "session:old", "session:plain"])
    }

    func testCapAtFiftyAndLargeCatalog() {
        let items = (0..<5000).map { MacPaletteItem.fixture("Session \($0)", kind: .session, id: "session:\($0)") }
        let result = MacPaletteMatcher.rank(items, query: "session", recentIDs: [], now: now)
        XCTAssertEqual(result.count, MacPaletteMatcher.rowLimit)
        XCTAssertEqual(MacPaletteMatcher.rowLimit, 50)
    }

    func testEmptyOrWhitespaceQueryRanksNothing() {
        XCTAssertEqual(ranked([.fixture("Alpha")], ""), [])
        XCTAssertEqual(ranked([.fixture("Alpha")], "   "), [])
    }
}
