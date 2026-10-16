import XCTest
@testable import ConduitMac

final class MacSessionTabsModelTests: XCTestCase {
    private func model(_ ids: [String], active: String? = nil) -> MacSessionTabsModel {
        var m = MacSessionTabsModel()
        for id in ids { m.open(id, title: id.uppercased()) }
        if let active { m.open(active, title: active.uppercased()) }
        return m
    }

    func testOpenAppendsAndActivates() {
        var m = MacSessionTabsModel()
        m.open("a", title: "A")
        m.open("b", title: "B")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(m.activeID, "b")
    }

    func testOpenExistingSelectsWithoutAddingAndRefreshesTitle() {
        var m = model(["a", "b"])
        m.open("a", title: "Renamed")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(m.activeID, "a")
        XCTAssertEqual(m.tabs[0].title, "Renamed")
    }

    func testOpenClearsUnavailable() {
        var m = model(["a"])
        m.markUnavailable("a")
        XCTAssertTrue(m.tabs[0].unavailable)
        m.open("a", title: "A")
        XCTAssertFalse(m.tabs[0].unavailable)
    }

    func testCloseActivePrefersRightNeighbourThenLeft() {
        var m = model(["a", "b", "c"], active: "b")
        XCTAssertEqual(m.close("b"), .activate("c"))
        XCTAssertEqual(m.activeID, "c")
        XCTAssertEqual(m.close("c"), .activate("a"))
        XCTAssertEqual(m.tabs.map(\.id), ["a"])
    }

    func testCloseInactiveKeepsActive() {
        var m = model(["a", "b", "c"], active: "c")
        XCTAssertEqual(m.close("a"), .closedInactive)
        XCTAssertEqual(m.activeID, "c")
    }

    func testCloseLastTab() {
        var m = model(["a"])
        XCTAssertEqual(m.close("a"), .closedLast)
        XCTAssertTrue(m.tabs.isEmpty)
        XCTAssertNil(m.activeID)
    }

    func testCloseUnknownIsNotFound() {
        var m = model(["a"])
        XCTAssertEqual(m.close("zzz"), .notFound)
        XCTAssertEqual(m.tabs.count, 1)
    }

    func testReopenRestoresIndexMostRecentFirst() {
        var m = model(["a", "b", "c"], active: "c")
        _ = m.close("a")
        _ = m.close("b")
        XCTAssertEqual(m.reopen(), "b")
        XCTAssertEqual(m.tabs.map(\.id), ["b", "c"])
        XCTAssertEqual(m.reopen(), "a")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(m.activeID, "a")
        XCTAssertNil(m.reopen())
    }

    func testReopenClampsIndexAndSkipsAlreadyOpen() {
        var m = model(["a", "b", "c"], active: "a")
        _ = m.close("c")          // index 2
        _ = m.close("b")          // index 1
        m.open("c", title: "C")   // c is open again
        XCTAssertEqual(m.reopen(), "b")
        XCTAssertEqual(m.reopen(), nil, "c is already open, so its entry is dropped")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b", "c"])
    }

    func testClosedStackKeepsTen() {
        var m = model((0..<12).map { "s\($0)" })
        for i in 0..<12 { _ = m.close("s\(i)") }
        XCTAssertEqual(m.closed.count, MacSessionTabsModel.closedLimit)
        XCTAssertEqual(m.closed.first?.tab.id, "s11")
    }

    func testShortcutIndexEightThenLast() {
        let m = model((1...10).map { "s\($0)" })
        XCTAssertEqual(m.id(forShortcut: 1), "s1")
        XCTAssertEqual(m.id(forShortcut: 8), "s8")
        XCTAssertEqual(m.id(forShortcut: 9), "s10")
        XCTAssertNil(model(["a", "b"]).id(forShortcut: 5))
        XCTAssertEqual(model(["a", "b"]).id(forShortcut: 9), "b")
        XCTAssertNil(MacSessionTabsModel().id(forShortcut: 9))
    }

    func testNeighbourWraps() {
        let m = model(["a", "b", "c"], active: "c")
        XCTAssertEqual(m.neighbor(.next), "a")
        XCTAssertEqual(m.neighbor(.previous), "b")
        XCTAssertNil(model(["a"]).neighbor(.next), "a single tab has no neighbour")
        XCTAssertNil(MacSessionTabsModel().neighbor(.next))
    }

    func testNeighbourWithNoActiveEntersAtTheEnds() {
        var m = model(["a", "b"])
        m.clearActive()
        XCTAssertEqual(m.neighbor(.next), "a")
        XCTAssertEqual(m.neighbor(.previous), "b")
    }

    func testRemoveDoesNotFeedReopen() {
        var m = model(["a", "b"], active: "a")
        m.remove("a")
        XCTAssertEqual(m.tabs.map(\.id), ["b"])
        XCTAssertNil(m.activeID)
        XCTAssertNil(m.reopen())
    }

    func testRekeyKeepsPositionAndActiveAndMergesDuplicates() {
        var m = model(["draft", "b"], active: "draft")
        m.rekey("draft", to: "real")
        XCTAssertEqual(m.tabs.map(\.id), ["real", "b"])
        XCTAssertEqual(m.activeID, "real")
        var dup = model(["draft", "real"], active: "draft")
        dup.rekey("draft", to: "real")
        XCTAssertEqual(dup.tabs.map(\.id), ["real"], "never two tabs for one session")
        XCTAssertEqual(dup.activeID, "real")
    }

    func testOpenMergesTabsKeyedByTheSessionsOtherIds() {
        var m = model(["runtime", "b", "stored"], active: "b")
        m.open("real", title: "Real", aliases: ["runtime", "stored", "real"])
        XCTAssertEqual(m.tabs.map(\.id), ["real", "b"], "one tab per session, where its first tab was")
        XCTAssertEqual(m.activeID, "real")
        XCTAssertEqual(m.tabs[0].title, "Real")
    }

    func testOpenDropsClosedEntriesUnderTheSessionsOtherIds() {
        var m = model(["runtime", "b"], active: "b")
        _ = m.close("runtime")
        m.open("real", title: "Real", aliases: ["runtime"])
        XCTAssertNil(m.reopen(), "reopen must not bring the session back as a second tab")
    }

    func testCodableRoundTripDropsClosedStack() throws {
        var m = model(["a", "b"], active: "a")
        m.markUnavailable("b")
        _ = m.close("a")
        m.open("a", title: "A")
        let decoded = try JSONDecoder().decode(MacSessionTabsModel.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(decoded.tabs, m.tabs)
        XCTAssertEqual(decoded.activeID, m.activeID)
        XCTAssertTrue(decoded.closed.isEmpty)
    }
}
