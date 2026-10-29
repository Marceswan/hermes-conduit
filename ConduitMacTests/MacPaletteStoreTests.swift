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

    // MARK: - Review round 1

    func testStopResponseAsksFirstAndStopsOnlyWhenConfirmed() {
        current.isTurnRunning = true
        store.present()
        store.query = "stop response"
        store.runSelected()
        XCTAssertEqual(log, [], "the first Return only asks")
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.pendingConfirmation?.confirmTitle, AppLocalization.string("Stop"))
        store.runSelected()
        XCTAssertEqual(log, ["stop"])
        XCTAssertFalse(store.isPresented)
        XCTAssertNil(store.pendingConfirmation)
    }

    func testEscapeTypingAndMovingGoBackFromAConfirmation() {
        current.isTurnRunning = true
        store.present()
        store.query = "stop response"
        store.runSelected()
        XCTAssertNotNil(store.pendingConfirmation)
        store.handleEscape()
        XCTAssertNil(store.pendingConfirmation, "Esc goes back one step")
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.query, "stop response", "and does not clear the query yet")

        store.runSelected()
        store.query = "stop respons"
        XCTAssertNil(store.pendingConfirmation, "typing cancels")
        store.query = "stop response"
        store.runSelected()
        store.move(.down)
        XCTAssertNil(store.pendingConfirmation, "moving cancels")
        store.runSelected()
        store.dismiss()
        XCTAssertNil(store.pendingConfirmation, "closing cancels")
        XCTAssertEqual(log, [], "nothing ran")
    }

    func testProfileSwitchAsksOnlyWhileATurnRuns() {
        store.present()
        store.query = "@work"
        store.runSelected()
        XCTAssertTrue(HostedTestSupport.waitUntil { log == ["profile:work"] }, "idle: no question")

        log = []
        current.isTurnRunning = true
        store.present()
        store.query = "@work"
        store.runSelected()
        XCTAssertEqual(store.pendingConfirmation?.confirmTitle, AppLocalization.string("Switch Profile"))
        HostedTestSupport.settle(0.05)
        XCTAssertEqual(log, [])
        store.runSelected()
        XCTAssertTrue(HostedTestSupport.waitUntil { log == ["profile:work"] })
    }

    func testInsertingASlashCommandAsksBeforeReplacingATypedDraft() {
        var draft = ""
        store.calls.draftText = { draft }
        store.present(); store.query = "/title"; store.runSelected()
        XCTAssertEqual(log, ["insert:title"], "empty draft: fills at once")

        for blank in ["", "  \n "] {
            log = []; draft = blank
            store.present(); store.query = "/title"; store.runSelected()
            XCTAssertEqual(log, ["insert:title"], "blank draft: fills at once")
        }

        log = []; draft = "half-written message"
        store.present(); store.query = "/title"; store.runSelected()
        XCTAssertEqual(log, [], "a typed draft is never replaced without asking")
        XCTAssertEqual(store.pendingConfirmation?.confirmTitle, AppLocalization.string("Replace Draft"))
        store.handleEscape()
        XCTAssertEqual(log, [])
        store.runSelected()
        store.runSelected()
        XCTAssertEqual(log, ["insert:title"])
    }

    func testStateChangingSlashCommandsAskAndSafeOnesDoNot() {
        current.slashCommands = [SlashCommand(name: "status", description: "Show status"),
                                 SlashCommand(name: "undo", description: "Remove the last exchange")]
        store.present(); store.query = "/status"; store.runSelected()
        XCTAssertTrue(HostedTestSupport.waitUntil { log == ["slash:status"] })

        log = []
        store.present(); store.query = "/undo"; store.runSelected()
        XCTAssertEqual(log, [])
        XCTAssertEqual(store.pendingConfirmation?.message, "/undo: Remove the last exchange")
        store.runSelected()
        XCTAssertTrue(HostedTestSupport.waitUntil { log == ["slash:undo"] })
    }

    func testACancelledConfirmationIsNotARecent() {
        current.isTurnRunning = true
        store.present(); store.query = "stop response"; store.runSelected()
        store.dismiss()
        store.present()
        XCTAssertNotEqual(store.sections.first?.title, AppLocalization.string("Recent"), "cancelled: not recorded")
        store.query = "stop response"; store.runSelected(); store.runSelected()
        store.present()
        XCTAssertEqual(store.sections.first?.title, AppLocalization.string("Recent"))
        XCTAssertEqual(store.sections.first?.items.first?.id, "command:stopResponse")
    }

    func testTypingStartsAtTheBestRowButARefreshKeepsTheSelection() {
        current.sessions = [.paletteFixture(id: "s1", title: "Alpha one"), .paletteFixture(id: "s2", title: "Alpha two"),
                            .paletteFixture(id: "s3", title: "Beta alpha")]
        store.present()
        store.query = "#alpha"
        XCTAssertEqual(store.rows.map(\.id), ["session:s1", "session:s2", "session:s3"])
        store.select("session:s3")
        store.refresh()
        XCTAssertEqual(store.selectionID, "session:s3", "a refresh keeps the row")
        store.query = "#alph"
        XCTAssertEqual(store.selectionID, "session:s1", "a new query starts at its best row, not one carried over")
    }

    func testKeystrokesRankTheOpenSnapshotInsteadOfRebuildingIt() {
        var snapshots = 0
        store.snapshot = { [unowned self] in snapshots += 1; return self.current }
        store.present()
        let afterOpen = snapshots
        XCTAssertGreaterThan(afterOpen, 0)
        for query in ["l", "la", "lar", "lara", "#", "#s", "/", "@w"] { store.query = query }
        XCTAssertEqual(snapshots, afterOpen, "no snapshot, provider run or diacritic folding per keystroke")
    }

    func testOnlyAMoveBumpsTheNavigationToken() {
        store.present()
        store.query = "#"
        let start = store.navigationToken
        store.query = "#l"
        XCTAssertEqual(store.navigationToken, start, "typing is not announced")
        store.move(.down)
        XCTAssertEqual(store.navigationToken, start + 1)
    }

    func testThousandsOfSessionsStayResponsivePerKeystroke() {
        current.sessions = (0..<5_000).map {
            .paletteFixture(id: "id-\($0)", title: "Session \($0) about project \($0 % 97)", model: "model-\($0 % 7)")
        }
        let clock = ContinuousClock()
        var open = Duration.zero, typing = Duration.zero
        open = clock.measure { store.present() }
        typing = clock.measure {
            for query in ["s", "se", "ses", "sess", "session 4", "session 42", "#proj", "#project 9"] { store.query = query }
        }
        XCTAssertLessThanOrEqual(store.rows.count, MacPaletteMatcher.rowLimit)
        // Measured at roughly 5 ms per keystroke here; the bound is for a loaded CI machine.
        XCTAssertLessThan(typing, .seconds(2), "8 keystrokes over 5,000 sessions (open took \(open))")
    }
}
