import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteStoreTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var store: MacPaletteStore!
    private var log: [String] = []
    private var current = MacPaletteSnapshot.empty

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        store = MacPaletteStore(defaults: suite.defaults, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        log = []
        current = MacPaletteSnapshot(
            sessions: [.paletteFixture(id: "s1", title: "Laravel"), .paletteFixture(id: "s2", title: "Swift")],
            activeSessionID: "s1", slashCommands: [SlashCommand(name: "new", description: "Start over"),
                                                    SlashCommand(name: "title", description: "Rename", argsHint: "<n>")],
            profiles: ["default", "work"], activeProfile: "default"
        )
        store.snapshot = { [unowned self] in self.current }
        var calls = MacPaletteCalls()
        calls.openSession = { [unowned self] in log.append("open:\($0)") }
        calls.runSlash = { [unowned self] name in await MainActor.run { log.append("slash:\(name)") } }
        calls.insertSlash = { [unowned self] in log.append("insert:\($0)") }
        calls.switchProfile = { [unowned self] name in await MainActor.run { log.append("profile:\(name)") } }
        calls.openModelPicker = { [unowned self] in log.append("model") }
        calls.selectPane = { [unowned self] in log.append("pane:\($0.rawValue)") }
        calls.newChat = { [unowned self] in log.append("newChat") }
        calls.openSettings = { [unowned self] in log.append("settings") }
        calls.toggleSidebar = { [unowned self] in log.append("sidebar") }
        calls.stopResponse = { [unowned self] in log.append("stop") }
        calls.searchSessions = { [unowned self] in log.append("search") }
        calls.checkForUpdates = { [unowned self] in log.append("updates") }
        store.calls = calls
    }

    override func tearDown() async throws {
        store = nil
        HostedTestSupport.dropSuite(suite)
    }

    func testDispatcherCallsEachClosureExactlyOnce() {
        let cases: [(MacPaletteAction, String)] = [
            (.openSession("x"), "open:x"), (.insertSlash("t"), "insert:t"), (.openModelPicker, "model"),
            (.selectPane(.bots), "pane:Bots"), (.newChat, "newChat"), (.openSettings, "settings"),
            (.toggleSidebar, "sidebar"), (.stopResponse, "stop"), (.searchSessions, "search"), (.checkForUpdates, "updates"),
        ]
        for (action, expected) in cases {
            log = []
            MacPaletteDispatcher.perform(action, with: store.calls)
            XCTAssertEqual(log, [expected])
        }
    }

    func testAsyncActionsRunToCompletion() {
        MacPaletteDispatcher.perform(.runSlash("new"), with: store.calls)
        MacPaletteDispatcher.perform(.switchProfile("work"), with: store.calls)
        XCTAssertTrue(HostedTestSupport.waitUntil { log.sorted() == ["profile:work", "slash:new"] })
    }

    func testToggleOpensAndClosesAndResetsQuery() {
        store.toggle()
        XCTAssertTrue(store.isPresented)
        store.query = "lara"
        store.toggle()
        XCTAssertFalse(store.isPresented)
        XCTAssertEqual(store.query, "")
    }

    func testPresentShowsEmptyQuerySectionsAndSelectsFirstEnabledRow() {
        store.present()
        XCTAssertEqual(store.sections.first?.title, AppLocalization.string("Commands"))
        XCTAssertEqual(store.selectionID, store.rows.first(where: \.isEnabled)?.id)
    }

    func testTypingRanksAndScopePrefixFilters() {
        store.present()
        store.query = "lara"
        XCTAssertEqual(store.rows.map(\.id), ["session:s1"])
        store.query = "#"
        XCTAssertEqual(store.rows.map(\.id), ["session:s1", "session:s2"])
        store.query = "/"
        XCTAssertEqual(store.rows.map(\.id), ["slash:new", "slash:title"])
        store.query = "@wor"
        XCTAssertEqual(store.rows.map(\.id), ["profile:work"])
        store.query = "   "
        XCTAssertEqual(store.sections.first?.title, AppLocalization.string("Commands"), "whitespace equals empty")
    }

    func testSelectionClampsSkipsDisabledAndStopsAtEnds() {
        current.activeSessionID = nil           // slash rows become disabled
        store.present()
        store.query = "/"
        XCTAssertTrue(store.rows.allSatisfy { !$0.isEnabled })
        XCTAssertNil(store.selectionID)
        store.move(.down); store.move(.up); store.runSelected()   // must not crash or run
        XCTAssertEqual(log, [])

        store.query = ">"
        let first = store.selectionID
        store.move(.up)
        XCTAssertEqual(store.selectionID, first, "no wrap at the top")
        store.move(.last)
        let last = store.rows.last(where: \.isEnabled)?.id
        XCTAssertEqual(store.selectionID, last)
        store.move(.down)
        XCTAssertEqual(store.selectionID, last, "no wrap at the bottom")
        store.move(.first)
        XCTAssertEqual(store.selectionID, first)
    }

    func testSelectionReclampsWhenTheSelectedRowVanishes() {
        store.present()
        store.query = "#"
        store.select("session:s2")
        current.sessions = [.paletteFixture(id: "s1", title: "Laravel")]
        store.refresh()
        XCTAssertEqual(store.selectionID, "session:s1")
        current.sessions = []
        store.refresh()
        XCTAssertNil(store.selectionID)
        store.runSelected()
        XCTAssertEqual(log, [])
    }

    func testEscapeClearsQueryThenCloses() {
        store.present()
        store.query = "lara"
        store.handleEscape()
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.query, "")
        store.handleEscape()
        XCTAssertFalse(store.isPresented)
    }

    func testRunClosesFirstThenCallsOnceAndRecords() {
        var presentedWhenCalled: Bool?
        store.calls.openSession = { [unowned self] id in presentedWhenCalled = store.isPresented; log.append("open:\(id)") }
        store.present()
        store.query = "lara"
        store.runSelected()
        XCTAssertEqual(log, ["open:s1"])
        XCTAssertEqual(presentedWhenCalled, false, "the palette closes before the action runs")
        XCTAssertFalse(store.isPresented)

        store.present()
        XCTAssertEqual(store.sections.first?.title, AppLocalization.string("Recent"))
        XCTAssertEqual(store.sections.first?.items.first?.id, "session:s1")
    }

    func testRunSkipsDisabledAndCurrentProfile() {
        store.present()
        store.query = "@default"
        XCTAssertEqual(store.rows.first?.isCurrent, true)
        store.run(store.rows[0])
        XCTAssertEqual(log, [])
        XCTAssertTrue(store.isPresented)
    }

    func testRestoreFocusRunsOnCloseBeforeTheAction() {
        var order: [String] = []
        store.calls.newChat = { order.append("action") }
        store.present(restoreFocus: { order.append("focus") })
        store.query = "new chat"
        store.runSelected()
        XCTAssertEqual(order, ["focus", "action"])
        order = []
        store.present(restoreFocus: { order.append("focus") })
        store.dismiss()
        store.dismiss()
        XCTAssertEqual(order, ["focus"], "restored once")
    }

    func testRecentsPersistPerProfileScope() {
        store.present(); store.query = "lara"; store.runSelected()
        let other = MacPaletteStore(defaults: suite.defaults)
        other.snapshot = { [unowned self] in self.current }
        other.present()
        XCTAssertEqual(other.sections.first?.items.first?.id, "session:s1")
        current.activeProfile = "work"
        other.dismiss(); other.present()
        XCTAssertNotEqual(other.sections.first?.title, AppLocalization.string("Recent"), "another profile has its own recents")
    }

    func testQueryChangesDoNotBuildResultsWhileClosed() {
        store.query = "lara"            // not presented: no work, no crash
        XCTAssertTrue(store.sections.isEmpty)
    }
}
