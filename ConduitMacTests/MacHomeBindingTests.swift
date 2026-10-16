import XCTest
@testable import ConduitMac

@MainActor
final class MacHomeBindingTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var appSuite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        appSuite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacHomeBindingTests.\(UUID().uuidString)", isDirectory: true)
        // Same isolated AppState as MacPaletteBindingTests: no saved connection, no network.
        appState = AppState(
            defaults: appSuite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: appSuite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: appSuite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
    }

    override func tearDown() async throws {
        appState = nil
        HostedTestSupport.dropSuite(suite)
        HostedTestSupport.dropSuite(appSuite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Mappers

    func testLiveItemsKeepOnlyUnfinishedTurnsAndDecisions() {
        let since = Date(timeIntervalSince1970: 1_000)
        let items = [
            AgentActivityItem(id: "turn:r1", kind: .turn, state: .working, sessionId: "r1", sessionKey: "k1", title: "T", detail: "web_search", since: since),
            AgentActivityItem(id: "approval:7", kind: .approval, state: .needsUser, sessionId: "r2", sessionKey: nil, title: "A", since: since),
            AgentActivityItem(id: "clarify:3", kind: .clarify, state: .needsUser, sessionId: nil, sessionKey: "k3", title: "C", since: since),
            AgentActivityItem(id: "turn:r4", kind: .turn, state: .finished(.completed), sessionId: "r4", title: "Done", since: since),
            AgentActivityItem(id: "kanban:1", kind: .kanban, state: .blocked, title: "K", since: since),
            AgentActivityItem(id: "cron:1", kind: .cron, state: .working, title: "Cr", since: since),
        ]
        let mapped = MacHomeBinding.liveItems(items)
        XCTAssertEqual(mapped.map(\.id), ["turn:r1", "approval:7", "clarify:3"])
        XCTAssertEqual(mapped[0].sessionKey, "k1")
        XCTAssertEqual(mapped[0].openID, "r1", "the notch opens sessionId first")
        XCTAssertEqual(mapped[0].detail, "web_search")
        XCTAssertEqual(mapped[1].sessionKey, "r2", "no key falls back to the runtime id")
        XCTAssertTrue(mapped[1].needsUser)
        XCTAssertEqual(mapped[2].openID, "k3", "no runtime id falls back to the key")
        XCTAssertEqual(mapped[2].kind, .clarify)
    }

    func testAnItemWithNoIdentityHasNoOpenID() {
        let item = AgentActivityItem(id: "turn:x", kind: .turn, state: .working, title: "T", since: Date())
        XCTAssertNil(MacHomeBinding.liveItems([item]).first?.openID)
    }

    func testCronJobsMapActiveErrorAndNextRun() {
        let jobs = [
            CronJob(enabled: true, id: "a", lastError: "boom", name: "Nightly", nextRunAt: "2026-10-17T13:00:00Z"),
            CronJob(enabled: false, id: "b", lastError: "  ", name: nil, nextRunAt: "2026-10-17T13:00:00Z"),
            CronJob(enabled: true, id: "c", nextRunAt: "2026-10-17T13:00:00Z", state: "completed"),
            CronJob(enabled: true, id: "d", nextRunAt: "junk"),
        ]
        let mapped = MacHomeBinding.cronJobs(jobs)
        XCTAssertEqual(mapped.map(\.isActive), [true, false, false, true])
        XCTAssertEqual(mapped.map(\.hasError), [true, false, false, false], "blank errors do not count")
        XCTAssertEqual(mapped[0].name, "Nightly")
        XCTAssertEqual(mapped[1].name, "b", "no name falls back to the id")
        XCTAssertNotNil(mapped[0].nextRun)
        XCTAssertNil(mapped[2].nextRun, "a finished one-shot has no next run")
        XCTAssertNil(mapped[3].nextRun, "unparseable stays nil")
    }

    func testCronJobsMarkFinishedOnes() {
        let mapped = MacHomeBinding.cronJobs([
            CronJob(enabled: true, id: "c", state: "completed"),
            CronJob(enabled: false, id: "p"),
        ])
        XCTAssertEqual(mapped.map(\.isFinished), [true, false])
        XCTAssertEqual(mapped.map(\.isActive), [false, false])
    }

    func testSavedBoardSlugIsReadFromTheKanbanPanesKey() {
        let server = "https://dash.example.com/"
        XCTAssertNil(MacHomeBinding.savedBoardSlug(serverIdentity: server, defaults: suite.defaults))
        suite.defaults.set("ops", forKey: KanbanStore.scopedBoardKey(serverIdentity: "https://dash.example.com"))
        XCTAssertEqual(MacHomeBinding.savedBoardSlug(serverIdentity: server, defaults: suite.defaults), "ops",
                       "a trailing slash normalizes to the same key the Kanban pane writes")
        XCTAssertNil(MacHomeBinding.savedBoardSlug(serverIdentity: "https://other.example.com", defaults: suite.defaults))
    }

    // MARK: Input from AppState

    func testInputMirrorsAppState() {
        appState.sessions = [
            .macTestSummary(id: "a", alternateIds: [], title: "Alpha", lastActivityAt: 1_760_000_000),
            .macTestSummary(id: "z", alternateIds: [], title: "Gone", isArchived: true, lastActivityAt: 1_760_000_100),
        ]
        let input = MacHomeBinding.input(appState: appState, feed: nil, kanban: .unavailable, cronLoaded: false, now: Date(timeIntervalSince1970: 1_760_000_500))
        XCTAssertEqual(input.sessions.map(\.id), ["a"], "archived rows are not recents")
        XCTAssertEqual(input.sessions.first?.lastActivity, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(input.connection.state, .offline)
        XCTAssertEqual(input.feed, .offline, "no feed means offline")
        XCTAssertTrue(input.live.isEmpty)
        XCTAssertNil(input.cron, "cron is nil until it has been loaded")
        XCTAssertEqual(input.kanban, .unavailable)
        XCTAssertFalse(input.canStartChat, "no live client: New Chat is off (stricter than the sidebar, whose button stays enabled but does nothing)")
        XCTAssertTrue(input.scope.hasSuffix("|false"))
    }

    func testCronIsPassedOnceLoaded() {
        let input = MacHomeBinding.input(appState: appState, feed: nil, kanban: .notLoaded, cronLoaded: true, now: Date())
        XCTAssertEqual(input.cron?.count, 0)
    }

    // MARK: Refresh

    func testAppearingResetsKanbanAndCronBeforeAnythingIsFetched() async {
        let loader = MacHomeKanbanLoader { _ in
            [MacHomeKanbanColumnInput(status: "todo", displayName: "To Do", sortOrder: 1, count: 3)]
        }
        await loader.load(preferredSlug: nil)
        XCTAssertEqual(loader.state, .loaded([MacHomeKanbanColumnInput(status: "todo", displayName: "To Do", sortOrder: 1, count: 3)]))
        let cron = MacHomeBinding.CronLoadState()
        cron.loaded = true
        // Not connected: the refresh fetches nothing, but a new scope must still forget the old one.
        await MacHomeBinding.refresh(.appeared, appState: appState, feed: nil, kanban: loader, cron: cron, defaults: suite.defaults)
        XCTAssertEqual(loader.state, .notLoaded, "the old dashboard's board must not survive a scope change")
        XCTAssertFalse(cron.loaded)
    }

    // MARK: Actions

    func testOpenSessionUsesTheSidebarRoute() {
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .macSessionOpenRequested, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        MacHomeActions.live(appState: appState, defaults: suite.defaults).openSession("s1")
        XCTAssertEqual(posted, 1, "requestOpenSession posts macSessionOpenRequested, which returns the pane to Sessions")
    }

    func testOpenPaneWritesTheTabKey() {
        MacHomeActions.live(appState: appState, defaults: suite.defaults).openPane(.kanban)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
    }

    // MARK: Cron load state reaches the snapshot

    func testAScopeChangeClearsTheOldCronListWithoutAnyOtherChange() async {
        let cron = MacHomeBinding.CronLoadState()
        cron.loaded = true
        let kanban = MacHomeKanbanLoader { _ in [] }
        let sources = MacHomeBinding.sources(appState: appState, feed: nil, kanban: kanban, defaults: suite.defaults, cron: cron)
        let model = MacHomeModel(sources: sources, calendar: MacHomeTestCalendar.utc, throttle: 0.02, tick: .seconds(3600))
        XCTAssertNotNil(model.snapshot.cron, "precondition: the old scope's cron list is showing")
        // Offline AppState: refresh fetches nothing, so only the .appeared reset can clear cron.
        let task = Task { await model.run() }
        let cleared = await macHomeEventually { model.snapshot.cron == nil }
        XCTAssertTrue(cleared, "a new scope must not keep the previous dashboard's cron list")
        task.cancel()
        await task.value
    }

    func testCronLoadStatePublishesBothFlips() {
        let cron = MacHomeBinding.CronLoadState()
        var fired = 0
        let sink = cron.objectWillChange.sink { fired += 1 }
        defer { sink.cancel() }
        cron.loaded = true
        cron.loaded = false
        XCTAssertEqual(fired, 2, "the reset on .appeared and the set once loaded must both reach Sources.changes")
    }

    func testCronAppearsWithoutWaitingForASlowKanbanFetch() async {
        let cron = MacHomeBinding.CronLoadState()
        let kanban = MacHomeKanbanLoader { _ in
            // Never returns until cancelled: a hung Kanban request.
            try await Task.sleep(for: .seconds(600))
            return []
        }
        let sources = MacHomeBinding.sources(appState: appState, feed: nil, kanban: kanban, defaults: suite.defaults, cron: cron)
        let model = MacHomeModel(sources: sources, calendar: MacHomeTestCalendar.utc, throttle: 0.02, tick: .seconds(3600))
        XCTAssertNil(model.snapshot.cron)
        let slow = Task { await kanban.load(preferredSlug: nil) }
        await macHomeSettle(0.05)
        // What refresh does once loadCronJobs returns, while the Kanban fetch is still in flight.
        cron.loaded = true
        let shown = await macHomeEventually { model.snapshot.cron != nil }
        XCTAssertTrue(shown, "cron must publish on its own, not ride on the Kanban fetch")
        XCTAssertEqual(model.snapshot.kanban.state, .notLoaded)
        slow.cancel()
        await slow.value
    }
}
