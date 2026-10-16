import XCTest
@testable import ConduitMac

final class MacHomeSnapshotTests: XCTestCase {
    private let calendar = MacHomeTestCalendar.utc
    private let now = MacHomeInput.referenceNow

    private func make(_ input: MacHomeInput) -> MacHomeSnapshot {
        MacHomeSnapshot.make(input, calendar: calendar)
    }

    // MARK: Live rows

    func testLiveDedupesPerSessionAndNeedsUserWins() {
        let working = MacHomeLiveItem.fixture("turn:1", session: "s1", kind: .turn, since: now.addingTimeInterval(-600))
        let approval = MacHomeLiveItem.fixture("approval:9", session: "s1", kind: .approval, needsUser: true, since: now.addingTimeInterval(-60))
        let other = MacHomeLiveItem.fixture("turn:2", session: "s2", kind: .turn, since: now.addingTimeInterval(-30))
        let snap = make(.fixture(live: [working, approval, other]))
        XCTAssertEqual(snap.needsYou.map(\.id), ["approval:9"])
        XCTAssertEqual(snap.working.map(\.id), ["turn:2"])
    }

    func testLiveRowsAreOldestFirst() {
        let a = MacHomeLiveItem.fixture("a", session: "a", since: now.addingTimeInterval(-10))
        let b = MacHomeLiveItem.fixture("b", session: "b", since: now.addingTimeInterval(-500))
        let c = MacHomeLiveItem.fixture("c", session: "c", since: now.addingTimeInterval(-500))
        XCTAssertEqual(make(.fixture(live: [a, b, c])).working.map(\.id), ["b", "c", "a"])
    }

    func testOfflineFeedShowsNoLiveRows() {
        let item = MacHomeLiveItem.fixture("a", session: "a", needsUser: true)
        let snap = make(.fixture(live: [item], feed: .offline))
        XCTAssertTrue(snap.needsYou.isEmpty)
        XCTAssertTrue(snap.working.isEmpty)
        XCTAssertEqual(snap.feed, .offline)
    }

    func testLoadingFeedStillShowsRows() {
        let item = MacHomeLiveItem.fixture("a", session: "a")
        XCTAssertEqual(make(.fixture(live: [item], feed: .loading)).working.count, 1)
    }

    func testTilesCountApprovalsAndQuestionsSeparately() {
        let items = [
            MacHomeLiveItem.fixture("a1", session: "a", kind: .approval, needsUser: true),
            MacHomeLiveItem.fixture("c1", session: "b", kind: .clarify, needsUser: true),
            MacHomeLiveItem.fixture("i1", session: "c", kind: .inputPrompt, needsUser: true),
            MacHomeLiveItem.fixture("t1", session: "d"),
        ]
        let tiles = make(.fixture(live: items, subAgents: 2)).tiles
        XCTAssertEqual(tiles.needsYou, 3)
        XCTAssertEqual(tiles.approvals, 1)
        XCTAssertEqual(tiles.questions, 2)
        XCTAssertEqual(tiles.working, 1)
        XCTAssertEqual(tiles.subAgents, 2)
    }

    // MARK: Sessions

    func testRecentIsNewestFirstCappedAndNilActivityLast() {
        var sessions = (0..<12).map { MacHomeSession.fixture("s\($0)", at: now.addingTimeInterval(Double(-$0) * 60)) }
        sessions.append(.fixture("never", at: nil))
        sessions.shuffle()
        let recent = make(.fixture(sessions: sessions)).recent
        XCTAssertEqual(recent.count, MacHomeSnapshot.recentLimit)
        XCTAssertEqual(recent.map(\.id), (0..<8).map { "s\($0)" })
        let few = make(.fixture(sessions: [.fixture("x", at: nil), .fixture("y", at: now)])).recent
        XCTAssertEqual(few.map(\.id), ["y", "x"])
    }

    func testSessionTileCountsUnreadAndToday() {
        let sessions = [
            MacHomeSession.fixture("a", at: MacHomeTestCalendar.date("2026-10-16T00:00:00Z"), unread: true),
            MacHomeSession.fixture("b", at: MacHomeTestCalendar.date("2026-10-15T23:59:59Z")),
            MacHomeSession.fixture("c", at: nil, unread: true),
        ]
        let tiles = make(.fixture(sessions: sessions)).tiles
        XCTAssertEqual(tiles.sessions, 3)
        XCTAssertEqual(tiles.unread, 2)
        XCTAssertEqual(tiles.activeToday, 1)
    }

    func testSevenDaysBucketAtMidnightBoundaries() {
        let sessions = [
            MacHomeSession.fixture("today", at: MacHomeTestCalendar.date("2026-10-16T00:00:00Z")),
            MacHomeSession.fixture("today2", at: MacHomeTestCalendar.date("2026-10-16T15:00:00Z")),
            MacHomeSession.fixture("yesterday", at: MacHomeTestCalendar.date("2026-10-15T23:59:59Z")),
            MacHomeSession.fixture("oldest", at: MacHomeTestCalendar.date("2026-10-10T00:00:00Z")),
            MacHomeSession.fixture("outside", at: MacHomeTestCalendar.date("2026-10-09T23:59:59Z")),
            MacHomeSession.fixture("tomorrow", at: MacHomeTestCalendar.date("2026-10-17T00:00:01Z")),
        ]
        let days = make(.fixture(sessions: sessions)).days
        XCTAssertEqual(days.count, MacHomeSnapshot.dayCount)
        XCTAssertEqual(days.map(\.count), [1, 0, 0, 0, 0, 1, 2])
        XCTAssertEqual(days.map(\.isToday), [false, false, false, false, false, false, true])
        XCTAssertEqual(days.first?.start, MacHomeTestCalendar.date("2026-10-10T00:00:00Z"))
    }

    // MARK: Cron

    func testCronNilStaysNil() {
        XCTAssertNil(make(.fixture(cron: nil)).cron)
    }

    func testCronSummaryPicksSoonestFutureActiveJob() {
        let jobs = [
            MacHomeCronJob(id: "a", name: "Late", isActive: true, hasError: false, nextRun: now.addingTimeInterval(7200)),
            MacHomeCronJob(id: "b", name: "Soon", isActive: true, hasError: true, nextRun: now.addingTimeInterval(600)),
            MacHomeCronJob(id: "c", name: "Overdue", isActive: true, hasError: false, nextRun: now.addingTimeInterval(-600)),
            MacHomeCronJob(id: "d", name: "Paused", isActive: false, hasError: false, nextRun: now.addingTimeInterval(60)),
            MacHomeCronJob(id: "e", name: "Unparsed", isActive: true, hasError: false, nextRun: nil),
        ]
        let cron = try! XCTUnwrap(make(.fixture(cron: jobs)).cron)
        XCTAssertEqual(cron.active, 4)
        XCTAssertEqual(cron.paused, 1)
        XCTAssertEqual(cron.failing, 1)
        XCTAssertEqual(cron.next?.name, "Soon")
        XCTAssertEqual(cron.next?.date, now.addingTimeInterval(600))
    }

    func testCronWithNoUpcomingRunHasNoNext() {
        let jobs = [MacHomeCronJob(id: "a", name: "Old", isActive: true, hasError: false, nextRun: now.addingTimeInterval(-5))]
        XCTAssertNil(make(.fixture(cron: jobs)).cron?.next)
        XCTAssertEqual(make(.fixture(cron: [])).cron?.active, 0)
    }

    // MARK: Kanban

    func testKanbanOrdersSkipsArchivedAndComputesFractions() {
        let columns = [
            MacHomeKanbanColumnInput(status: "done", displayName: "Done", sortOrder: 7, count: 8),
            MacHomeKanbanColumnInput(status: "archived", displayName: "Archived", sortOrder: 8, count: 99),
            MacHomeKanbanColumnInput(status: "todo", displayName: "To Do", sortOrder: 1, count: 4),
            MacHomeKanbanColumnInput(status: "blocked", displayName: "Blocked", sortOrder: 5, count: 2),
        ]
        let kanban = make(.fixture(kanban: .loaded(columns))).kanban
        XCTAssertEqual(kanban.state, .loaded)
        XCTAssertEqual(kanban.bars.map(\.id), ["todo", "blocked", "done"])
        XCTAssertEqual(kanban.bars.map(\.count), [4, 2, 8])
        XCTAssertEqual(kanban.bars.map(\.fraction), [0.5, 0.25, 1.0])
        XCTAssertEqual(kanban.total, 14)
        XCTAssertEqual(kanban.blocked, 2)
    }

    func testKanbanStates() {
        XCTAssertEqual(make(.fixture(kanban: .notLoaded)).kanban.state, .notLoaded)
        XCTAssertEqual(make(.fixture(kanban: .unavailable)).kanban.state, .unavailable)
        let empty = [MacHomeKanbanColumnInput(status: "todo", displayName: "To Do", sortOrder: 1, count: 0)]
        let snap = make(.fixture(kanban: .loaded(empty)))
        XCTAssertEqual(snap.kanban.state, .empty)
        XCTAssertEqual(snap.kanban.bars.map(\.fraction), [0])
    }

    // MARK: Context and model

    func testContextClampsAndFlagsHigh() {
        func context(_ percent: Double, used: Int = 0, max: Int = 0) -> MacHomeContext? {
            make(.fixture(runtime: MacHomeRuntime(contextPercent: percent, contextUsed: used, contextMax: max))).context
        }
        XCTAssertNil(context(0))
        XCTAssertEqual(context(62, used: 124_000, max: 200_000)?.percent, 62)
        XCTAssertEqual(context(62)?.isHigh, false)
        XCTAssertEqual(context(85)?.isHigh, true)
        XCTAssertEqual(context(140)?.percent, 100)
        XCTAssertEqual(context(-5, used: 1, max: 10)?.percent, 0)
        XCTAssertEqual(context(.nan, used: 1, max: 10)?.percent, 0)
        XCTAssertEqual(context(0, used: 5, max: 10)?.percent, 0, "max alone still shows the meter")
    }

    func testModelLineIsHiddenWhenEmpty() {
        XCTAssertNil(make(.fixture()).model)
        let line = make(.fixture(runtime: MacHomeRuntime(model: "opus", provider: "anthropic", reasoningEffort: "high"))).model
        XCTAssertEqual(line?.model, "opus")
        XCTAssertEqual(line?.provider, "anthropic")
        XCTAssertEqual(line?.effort, "high")
    }

    // MARK: Untrusted text

    func testUntrustedStringsAreSanitized() {
        let evil = "A\u{202E}B\nC\u{200B}D"
        let huge = String(repeating: "x", count: 10_000)
        let input = MacHomeInput.fixture(
            connection: MacHomeConnection(state: .connected, dashboardLabel: evil, profileName: evil),
            sessions: [MacHomeSession(id: "s", title: evil + huge, model: evil, lastActivity: now, isUnread: false)],
            live: [MacHomeLiveItem.fixture("a", session: "a", needsUser: true, title: evil, detail: huge)],
            cron: [MacHomeCronJob(id: "c", name: evil + huge, isActive: true, hasError: false, nextRun: now.addingTimeInterval(60))],
            kanban: .loaded([MacHomeKanbanColumnInput(status: "weird", displayName: evil + huge, sortOrder: 100, count: 1)]),
            runtime: MacHomeRuntime(model: evil + huge, provider: evil, reasoningEffort: evil)
        )
        let snap = make(input)
        let strings: [String] = [
            snap.connection.dashboardLabel ?? "", snap.connection.profileName,
            snap.recent[0].title, snap.recent[0].model,
            snap.needsYou[0].title, snap.needsYou[0].detail ?? "",
            snap.cron?.next?.name ?? "", snap.kanban.bars[0].name,
            snap.model?.model ?? "", snap.model?.provider ?? "", snap.model?.effort ?? "",
        ]
        for s in strings {
            XCTAssertFalse(s.contains("\u{202E}"), "bidi override in \(s.prefix(20))")
            XCTAssertFalse(s.contains("\u{200B}"), "zero width in \(s.prefix(20))")
            XCTAssertFalse(s.contains("\n"), "newline in \(s.prefix(20))")
        }
        XCTAssertLessThanOrEqual(snap.recent[0].title.count, 80)
        XCTAssertLessThanOrEqual(snap.needsYou[0].detail?.count ?? 0, 120)
        XCTAssertLessThanOrEqual(snap.cron?.next?.name.count ?? 0, 60)
        XCTAssertLessThanOrEqual(snap.kanban.bars[0].name.count, 24)
        XCTAssertLessThanOrEqual(snap.model?.model.count ?? 0, 40)
    }

    // MARK: Scale

    func testLargeCatalogIsBoundedAndFast() {
        let sessions = (0..<5000).map { MacHomeSession.fixture("s\($0)", at: now.addingTimeInterval(Double(-$0))) }
        let started = Date()
        let snap = make(.fixture(sessions: sessions))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(snap.recent.count, 8)
        XCTAssertEqual(snap.days.count, 7)
        XCTAssertEqual(snap.tiles.sessions, 5000)
    }

    func testPassThroughFields() {
        let snap = make(.fixture(scope: "x|y|false", feed: .eventsOnly, canStartChat: false))
        XCTAssertEqual(snap.scope, "x|y|false")
        XCTAssertEqual(snap.feed, .eventsOnly)
        XCTAssertFalse(snap.canStartChat)
    }

    // MARK: Dates

    func testNextRunDatesParse() {
        let expected = MacHomeTestCalendar.date("2026-10-17T13:00:00Z")
        XCTAssertEqual(MacHomeDates.parse("2026-10-17T13:00:00Z"), expected)
        XCTAssertEqual(MacHomeDates.parse("2026-10-17T09:00:00-04:00"), expected)
        XCTAssertEqual(MacHomeDates.parse("2026-10-17T13:00:00.250Z"), expected.addingTimeInterval(0.25))
        XCTAssertEqual(MacHomeDates.parse("  2026-10-17T13:00:00Z \n"), expected)
        XCTAssertNil(MacHomeDates.parse(nil))
        XCTAssertNil(MacHomeDates.parse(""))
        XCTAssertNil(MacHomeDates.parse("tomorrow at nine"))
    }

    func testZoneLessNextRunIsReadAsLocalTime() throws {
        let parsed = try XCTUnwrap(MacHomeDates.parse("2026-10-17T09:30:00"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 10, 17, 9, 30])
    }

    // MARK: Task 3 additions (tile counts, finished cron, cron date formats)

    func testTilesCountEveryWaitingItemNotJustOnePerSession() {
        let items = [
            MacHomeLiveItem.fixture("a1", session: "a", kind: .approval, needsUser: true),
            MacHomeLiveItem.fixture("a2", session: "a", kind: .approval, needsUser: true),
            MacHomeLiveItem.fixture("c1", session: "a", kind: .clarify, needsUser: true),
            MacHomeLiveItem.fixture("t1", session: "a"),
        ]
        let snap = make(.fixture(live: items))
        XCTAssertEqual(snap.needsYou.count, 1, "one row per session")
        XCTAssertEqual(snap.tiles.approvals, 2)
        XCTAssertEqual(snap.tiles.questions, 1)
        XCTAssertEqual(snap.tiles.needsYou, 3)
        XCTAssertEqual(make(.fixture(live: items, feed: .offline)).tiles.needsYou, 0, "offline shows no live items")
    }

    func testAFinishedCronJobIsNeitherActiveNorPaused() {
        let jobs = [
            MacHomeCronJob(id: "a", name: "A", isActive: true, hasError: false, nextRun: nil),
            MacHomeCronJob(id: "b", name: "B", isActive: false, hasError: false, nextRun: nil),
            MacHomeCronJob(id: "c", name: "C", isActive: false, isFinished: true, hasError: false, nextRun: nil),
        ]
        let cron = make(.fixture(cron: jobs)).cron
        XCTAssertEqual(cron?.active, 1)
        XCTAssertEqual(cron?.paused, 1)
    }

    func testParseAcceptsPythonStyleIsoWithMicroseconds() throws {
        let expected = MacHomeTestCalendar.date("2026-10-17T13:00:00Z")
        XCTAssertEqual(MacHomeDates.parse("2026-10-17T13:00:00+00:00"), expected)
        let micro = try XCTUnwrap(MacHomeDates.parse("2026-10-17T13:00:00.123456+00:00"))
        XCTAssertEqual(micro.timeIntervalSince(expected), 0.123456, accuracy: 0.001)
        let naive = try XCTUnwrap(MacHomeDates.parse("2026-10-17T09:30:00.123456"))
        let parts = Calendar.current.dateComponents([.hour, .minute], from: naive)
        XCTAssertEqual([parts.hour, parts.minute], [9, 30])
    }
}
