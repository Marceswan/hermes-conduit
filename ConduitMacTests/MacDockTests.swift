import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ConduitMac

/// D31: the Dock badge (the count of items that wait on the user) and the Dock menu.
///
/// The content is pure (`MacDockContent`, over `MacDockSnapshot`), the dock tile sits behind
/// `MacDockTileDisplaying`, and the menu is built from plain closures, so nothing here needs the real Dock.
/// Nothing reads or writes the user's defaults: each test that needs defaults uses a throwaway suite.
@MainActor
final class MacDockTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
    }

    override func tearDown() async throws {
        HostedTestSupport.dropSuite(suite)
    }

    // MARK: Fixtures

    /// A fake dock tile that records every write.
    @MainActor private final class FakeTile: MacDockTileDisplaying {
        private(set) var writes: [String?] = []
        var badgeLabel: String? {
            didSet { writes.append(badgeLabel) }
        }
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    /// A needs-you item for its own session unless `session` says otherwise.
    private func needs(
        _ id: String, session: String? = nil, kind: MacHomeLiveItem.Kind = .approval,
        title: String = "A chat", open: String?? = nil, since: TimeInterval = 100
    ) -> MacHomeLiveItem {
        let key = session ?? id
        return .fixture(id, session: key, kind: kind, needsUser: true, title: title, open: open ?? key, since: at(since))
    }

    private func working(_ id: String) -> MacHomeLiveItem {
        .fixture(id, session: id, kind: .turn, needsUser: false, since: at(100))
    }

    private func snapshot(
        feed: MacHomeFeedAvailability = .live, live: [MacHomeLiveItem] = [], sessions: [MacHomeSession] = []
    ) -> MacDockSnapshot {
        MacDockSnapshot(feed: feed, live: live, sessions: sessions)
    }

    private func recents(_ count: Int) -> [MacHomeSession] {
        (0..<count).map { .fixture("s\($0)", title: "Chat \($0)", at: at(1_000 + Double($0))) }
    }

    private func titles(_ entries: [MacDockEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .item(let item): return item.title
            case .separator: return "--"
            }
        }
    }

    private var newChatTitle: String { AppLocalization.string("New Chat") }
    private var quickAskTitle: String { AppLocalization.string("Quick Ask") }

    // MARK: Count (the same count as the Home tile)

    func testCountIsApprovalsPlusQuestionsPerItem() {
        let live = [
            needs("approval:1", session: "a", kind: .approval),
            needs("approval:2", session: "a", kind: .approval),
            needs("approval:3", session: "a", kind: .approval),
            needs("clarify:1", session: "b", kind: .clarify),
            needs("inputPrompt:1", session: "c", kind: .inputPrompt),
            working("turn:d"),
        ]
        XCTAssertEqual(MacDockContent.waitingCount(snapshot(live: live)), 5,
                       "a session with three approvals is three things waiting; a working turn is none")
    }

    func testCountEqualsTheHomeTileForTheSameInput() {
        let live = [
            needs("approval:1", session: "a"), needs("approval:2", session: "a"),
            needs("clarify:1", session: "b", kind: .clarify), working("turn:c"),
        ]
        for feed in [MacHomeFeedAvailability.live, .loading, .eventsOnly, .offline] {
            let home = MacHomeSnapshot.make(.fixture(live: live, feed: feed), calendar: MacHomeTestCalendar.utc)
            XCTAssertEqual(MacDockContent.waitingCount(snapshot(feed: feed, live: live)), home.tiles.needsYou, "feed \(feed)")
        }
    }

    func testCountIsZeroWhileTheFeedIsOffline() {
        XCTAssertEqual(MacDockContent.waitingCount(snapshot(feed: .offline, live: [needs("approval:1")])), 0)
    }

    func testCountIsZeroWithNothingWaiting() {
        XCTAssertEqual(MacDockContent.waitingCount(snapshot(live: [working("turn:a")])), 0)
        XCTAssertEqual(MacDockContent.waitingCount(snapshot()), 0)
    }

    func testLabelIsNilForZeroAndTheNumberOtherwise() {
        XCTAssertNil(MacDockBadge.label(count: 0))
        XCTAssertNil(MacDockBadge.label(count: -1))
        XCTAssertEqual(MacDockBadge.label(count: 1), "1")
        XCTAssertEqual(MacDockBadge.label(count: 12), "12")
    }

    // MARK: Badge owner

    private final class Source {
        var value = MacDockSnapshot(feed: .live, live: [], sessions: [])
        private(set) var reads = 0

        func read() -> MacDockSnapshot {
            reads += 1
            return value
        }
    }

    private func makeBadge(
        tile: FakeTile, source: Source, changes: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        center: NotificationCenter = NotificationCenter()
    ) -> MacDockBadge {
        MacDockBadge(tile: tile, defaults: suite.defaults, snapshot: { source.read() }, changes: changes, center: center)
    }

    func testTheBadgeShowsTheWaitingCount() {
        let tile = FakeTile()
        let source = Source()
        source.value = snapshot(live: [needs("approval:1"), needs("clarify:1", kind: .clarify)])
        let badge = makeBadge(tile: tile, source: source)
        badge.start()
        XCTAssertEqual(tile.badgeLabel, "2")
        badge.stop()
    }

    func testTheBadgeClearsWhenTheCountReturnsToZero() {
        let tile = FakeTile()
        let source = Source()
        source.value = snapshot(live: [needs("approval:1")])
        let badge = makeBadge(tile: tile, source: source)
        badge.start()
        XCTAssertEqual(tile.badgeLabel, "1")
        source.value = snapshot(live: [])
        badge.refresh()
        XCTAssertNil(tile.badgeLabel)
        badge.stop()
    }

    func testTheBadgeClearsWhenTheFeedGoesOffline() {
        let tile = FakeTile()
        let source = Source()
        source.value = snapshot(live: [needs("approval:1")])
        let badge = makeBadge(tile: tile, source: source)
        badge.start()
        XCTAssertEqual(tile.badgeLabel, "1")
        source.value = snapshot(feed: .offline, live: [needs("approval:1")])
        badge.refresh()
        XCTAssertNil(tile.badgeLabel, "offline shows nothing, as the Home tile does")
        badge.stop()
    }

    func testTheTileIsWrittenOnlyOnARealChange() {
        let tile = FakeTile()
        let source = Source()
        let badge = makeBadge(tile: tile, source: source)
        badge.start()
        badge.refresh()
        XCTAssertEqual(tile.writes.count, 0, "nothing waits and nothing is shown: no write")
        source.value = snapshot(live: [needs("approval:1")])
        badge.refresh()
        badge.refresh()
        badge.refresh()
        XCTAssertEqual(tile.writes, ["1"], "the same count is not written again")
        source.value = snapshot(live: [needs("approval:1"), needs("approval:2")])
        badge.refresh()
        XCTAssertEqual(tile.writes, ["1", "2"])
        source.value = snapshot()
        badge.refresh()
        badge.refresh()
        XCTAssertEqual(tile.writes, ["1", "2", nil])
        badge.stop()
    }

    func testTheSettingIsOnUnlessTheUserTurnsItOff() {
        // The registration domain is shared by every `UserDefaults` in the process, so a suite also sees the
        // registered default; either way nothing stored reads as on.
        XCTAssertTrue(MacDockBadge.isEnabled(in: suite.defaults))
        XCTAssertTrue(MacDockBadge.defaultValue)
        suite.defaults.set(false, forKey: MacDockBadge.defaultsKey)
        XCTAssertFalse(MacDockBadge.isEnabled(in: suite.defaults))
        suite.defaults.set(true, forKey: MacDockBadge.defaultsKey)
        XCTAssertTrue(MacDockBadge.isEnabled(in: suite.defaults))
        suite.defaults.removeObject(forKey: MacDockBadge.defaultsKey)
        XCTAssertTrue(MacDockBadge.isEnabled(in: suite.defaults))
    }

    func testRegisterAddsTheSettingDefaultOn() {
        MacDefaults.register()
        // The registration domain, so a choice the user stored is left alone (as in AppShellTests).
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[MacDockBadge.defaultsKey] as? Bool, true)
        XCTAssertEqual(MacDockBadge.defaultsKey, "conduit.mac.dock.showCount")
    }

    func testTheSettingOffClearsTheBadgeAndOnShowsItAgain() {
        let tile = FakeTile()
        let source = Source()
        source.value = snapshot(live: [needs("approval:1")])
        let center = NotificationCenter()
        let badge = makeBadge(tile: tile, source: source, center: center)
        badge.start()
        XCTAssertEqual(tile.badgeLabel, "1")

        suite.defaults.set(false, forKey: MacDockBadge.defaultsKey)
        center.post(name: UserDefaults.didChangeNotification, object: suite.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { tile.badgeLabel == nil }, "the setting off clears the badge")

        source.value = snapshot(live: [needs("approval:1"), needs("approval:2")])
        badge.refresh()
        XCTAssertNil(tile.badgeLabel, "the count keeps changing while the setting is off; nothing shows")

        suite.defaults.set(true, forKey: MacDockBadge.defaultsKey)
        center.post(name: UserDefaults.didChangeNotification, object: suite.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { tile.badgeLabel == "2" }, "the setting on shows the count now")
        badge.stop()
    }

    func testADefaultsChangeThatIsNotTheSettingDoesNotReadTheFeedAgain() {
        let tile = FakeTile()
        let source = Source()
        let center = NotificationCenter()
        let badge = makeBadge(tile: tile, source: source, center: center)
        badge.start()
        let reads = source.reads
        // The domain also changes for window frames and the sidebar: none of that is the badge's business.
        suite.defaults.set("x", forKey: "conduit.mac.dock.unrelatedKey")
        center.post(name: UserDefaults.didChangeNotification, object: suite.defaults)
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(source.reads, reads)
        badge.stop()
    }

    func testAnOffSettingFromTheStartShowsNothing() {
        suite.defaults.set(false, forKey: MacDockBadge.defaultsKey)
        let tile = FakeTile()
        let source = Source()
        source.value = snapshot(live: [needs("approval:1")])
        let badge = makeBadge(tile: tile, source: source)
        badge.start()
        XCTAssertNil(tile.badgeLabel)
        XCTAssertEqual(tile.writes.count, 0)
        badge.stop()
    }

    func testAChangeFromTheFeedUpdatesTheBadge() {
        let tile = FakeTile()
        let source = Source()
        let changes = PassthroughSubject<Void, Never>()
        let badge = makeBadge(tile: tile, source: source, changes: changes.eraseToAnyPublisher())
        badge.start()
        XCTAssertNil(tile.badgeLabel)
        source.value = snapshot(live: [needs("approval:1")])
        changes.send()
        XCTAssertEqual(tile.badgeLabel, "1")
        badge.stop()
        source.value = snapshot(live: [needs("approval:1"), needs("approval:2")])
        changes.send()
        XCTAssertNil(tile.badgeLabel, "a stopped badge no longer listens")
    }

    func testStopClearsTheBadge() {
        let tile = FakeTile()
        let source = Source()
        source.value = snapshot(live: [needs("approval:1")])
        let badge = makeBadge(tile: tile, source: source)
        badge.start()
        XCTAssertEqual(tile.badgeLabel, "1")
        badge.stop()
        XCTAssertNil(tile.badgeLabel)
    }

    func testTheBadgeOwnerStartsWithTheOtherBootstrapsAndNotUnderXCTest() throws {
        let delegate = try source("ConduitMac/App/ConduitMacAppDelegate.swift")
        XCTAssertTrue(delegate.contains("if !MacDefaults.isRunningUnderXCTest { MacDockBootstrap.start() }"),
                      "the start call is skipped under XCTest, like the other bootstraps")
        let activity = try XCTUnwrap(delegate.range(of: "MacActivityBootstrap.start()"))
        let dock = try XCTUnwrap(delegate.range(of: "MacDockBootstrap.start()"))
        XCTAssertLessThan(activity.lowerBound, dock.lowerBound, "the feed exists before the badge owner reads it")
        XCTAssertTrue(delegate.contains("func applicationDockMenu(_ sender: NSApplication) -> NSMenu?"))
    }

    // MARK: One owner of the Dock badge (D20 sets none)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func swiftSources(under folder: String) -> [(path: String, text: String)] {
        let root = repoRoot.appendingPathComponent(folder)
        var found: [(String, String)] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = files?.nextObject() as? URL {
            guard item.pathExtension == "swift", let text = try? String(contentsOf: item, encoding: .utf8) else { continue }
            found.append((String(item.path.dropFirst(repoRoot.path.count + 1)), MacWordingTests.strippingComments(from: text)))
        }
        return found
    }

    /// The local notifications (D20) set no badge number, so `MacDockBadge` is the only owner. A second writer
    /// (a `UNNotificationContent.badge`, `setBadgeCount`, a second `badgeLabel` write) would fight it: the last
    /// write wins and the count on the icon would be wrong. If this fails, decide the owner in D31 first.
    func testOnlyTheDockBadgeOwnerWritesTheDockTile() {
        let writers = ["badgeLabel", "dockTile", "setBadgeCount", "applicationIconBadgeNumber", ".badge = ", "content.badge"]
        let allowed: Set<String> = ["ConduitMac/App/MacDockTile.swift"]
        for folder in ["ConduitMac", "Conduit", "Shared"] {
            for (path, text) in swiftSources(under: folder) where !allowed.contains(path) {
                for writer in writers {
                    XCTAssertFalse(text.contains(writer), "\(path) uses \(writer): the Dock badge has one owner, MacDockBadge (D31)")
                }
            }
        }
    }

    // MARK: Menu content

    func testMenuHoldsNewChatAndQuickAskFirstWithNothingElseWhenNothingIsWaiting() {
        XCTAssertEqual(titles(MacDockContent.entries(snapshot())), [newChatTitle, quickAskTitle])
    }

    func testMenuOrdersTheGroupsWithOneSeparatorBetweenEach() {
        let entries = MacDockContent.entries(snapshot(
            live: [needs("approval:1", session: "k1", title: "Deploy")],
            sessions: [.fixture("s1", title: "Recent one", at: at(1_000))]
        ))
        XCTAssertEqual(titles(entries), [newChatTitle, quickAskTitle, "--", "Deploy", "--", "Recent one"])
        XCTAssertEqual(entries.first, .item(MacDockItem(title: newChatTitle, action: .newChat)))
        XCTAssertEqual(entries[1], .item(MacDockItem(title: quickAskTitle, action: .quickAsk)))
    }

    func testAnEmptyNeedsYouGroupLeavesOutItsSeparator() {
        let entries = MacDockContent.entries(snapshot(sessions: [.fixture("s1", title: "Recent one", at: at(1_000))]))
        XCTAssertEqual(titles(entries), [newChatTitle, quickAskTitle, "--", "Recent one"])
    }

    func testAnEmptyRecentGroupLeavesOutItsSeparator() {
        let entries = MacDockContent.entries(snapshot(live: [needs("approval:1", title: "Deploy")]))
        XCTAssertEqual(titles(entries), [newChatTitle, quickAskTitle, "--", "Deploy"])
    }

    func testNoMenuEndsOrStartsWithASeparatorOrHoldsTwoInARow() {
        let shapes: [MacDockSnapshot] = [
            snapshot(), snapshot(live: [needs("a")]), snapshot(sessions: recents(2)),
            snapshot(live: [needs("a")], sessions: recents(2)), snapshot(feed: .offline, live: [needs("a")], sessions: recents(3)),
        ]
        for shape in shapes {
            let entries = MacDockContent.entries(shape)
            XCTAssertNotEqual(entries.first, .separator)
            XCTAssertNotEqual(entries.last, .separator)
            for pair in zip(entries, entries.dropFirst()) {
                XCTAssertFalse(pair.0 == .separator && pair.1 == .separator)
            }
        }
    }

    func testNeedsYouGroupHoldsFiveAtMostOldestFirstAndOnePerSession() {
        var live = (0..<7).map { needs("approval:\($0)", session: "k\($0)", title: "Chat \($0)", since: Double(700 - $0)) }
        // A second item of the session that waits longest: one row, as in Home.
        live.append(needs("clarify:x", session: "k6", kind: .clarify, title: "Chat 6", since: 1))
        let entries = MacDockContent.entries(snapshot(live: live))
        XCTAssertEqual(titles(entries), [newChatTitle, quickAskTitle, "--", "Chat 6", "Chat 5", "Chat 4", "Chat 3", "Chat 2"])
    }

    func testWorkingItemsAreNotInTheNeedsYouGroup() {
        let entries = MacDockContent.entries(snapshot(live: [working("turn:a"), needs("approval:1", title: "Deploy")]))
        XCTAssertEqual(titles(entries), [newChatTitle, quickAskTitle, "--", "Deploy"])
    }

    func testNeedsYouRowsOpenTheirSession() {
        let entries = MacDockContent.entries(snapshot(live: [needs("approval:1", session: "k1", title: "Deploy", open: "runtime-1")]))
        XCTAssertEqual(entries.last, .item(MacDockItem(title: "Deploy", action: .openSession("runtime-1"))),
                       "the id Home and the notch open: the item's open id")
    }

    func testANeedsYouRowWithNoSessionToOpenBringsConduitForward() {
        let entries = MacDockContent.entries(snapshot(live: [needs("approval:1", title: "Deploy", open: .some(nil))]))
        XCTAssertEqual(entries.last, .item(MacDockItem(title: "Deploy", action: .openConduit)))
    }

    func testNeedsYouGroupIsLeftOutWhileTheFeedIsOffline() {
        let entries = MacDockContent.entries(snapshot(feed: .offline, live: [needs("approval:1")], sessions: recents(1)))
        XCTAssertEqual(titles(entries), [newChatTitle, quickAskTitle, "--", "Chat 0"])
    }

    func testRecentGroupHoldsFiveMostRecentFirstAndOpensTheChat() {
        let entries = MacDockContent.entries(snapshot(sessions: recents(8)))
        XCTAssertEqual(titles(entries), [newChatTitle, quickAskTitle, "--", "Chat 7", "Chat 6", "Chat 5", "Chat 4", "Chat 3"])
        XCTAssertEqual(entries.last, .item(MacDockItem(title: "Chat 3", action: .openSession("s3"))))
    }

    func testTitlesAreMadeSafe() throws {
        let hostile = "Deploy\u{202E}gnp.exe\nnow\u{0007}\u{200B}!"
        let long = String(repeating: "a", count: 200)
        let entries = MacDockContent.entries(snapshot(
            live: [needs("approval:1", title: hostile)],
            sessions: [.fixture("s1", title: long, at: at(1)), .fixture("s2", title: hostile, at: at(2))]
        ))
        let shown = titles(entries).dropFirst(2).filter { $0 != "--" }
        XCTAssertEqual(shown.count, 3)
        for title in shown {
            XCTAssertEqual(title, MacUntrustedText.sanitize(title, maxGraphemes: MacDockContent.titleLimit), "\(title) is already safe")
            XCTAssertFalse(title.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }, title)
            XCTAssertFalse(title.contains("\n"), title)
            XCTAssertLessThanOrEqual(title.count, MacDockContent.titleLimit)
        }
        XCTAssertEqual(shown.first, "Deploygnp.exe now!")
        let cut = try XCTUnwrap(shown.dropFirst().first { $0.hasPrefix("aaaa") })
        XCTAssertTrue(cut.hasSuffix(MacUntrustedText.ellipsis), "a long title is cut with the ellipsis")
    }

    func testAnEmptyTitleShowsUntitledChat() {
        let entries = MacDockContent.entries(snapshot(
            live: [needs("approval:1", title: " \n ")], sessions: [.fixture("s1", title: " ", at: at(1))]
        ))
        // `MacHomeSession.fixture` fills an empty title, so build the empty one directly.
        let empty = MacDockContent.entries(snapshot(sessions: [MacHomeSession(id: "s9", title: "", model: "", lastActivity: at(1), isUnread: false)]))
        XCTAssertEqual(titles(entries)[3], AppLocalization.string("Untitled chat"))
        XCTAssertEqual(titles(empty).last, AppLocalization.string("Untitled chat"))
    }

    // MARK: AppKit menu

    private final class ActionLog {
        var calls: [String] = []
        var actions: MacDockMenuActions {
            MacDockMenuActions(
                newChat: { [self] in calls.append("newChat") },
                quickAsk: { [self] in calls.append("quickAsk") },
                openSession: { [self] in calls.append("open:\($0)") },
                openConduit: { [self] in calls.append("openConduit") }
            )
        }
    }

    func testTheMenuHasTheEntriesAsItems() {
        let entries = MacDockContent.entries(snapshot(
            live: [needs("approval:1", session: "k1", title: "Deploy")], sessions: [.fixture("s1", title: "Recent one", at: at(1))]
        ))
        let menu = MacDockMenu.menu(for: entries, actions: ActionLog().actions)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "--" : $0.title },
                       [newChatTitle, quickAskTitle, "--", "Deploy", "--", "Recent one"])
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled))
    }

    func testPerformingAnItemRunsItsAction() {
        let log = ActionLog()
        let entries = MacDockContent.entries(snapshot(
            live: [needs("approval:1", session: "k1", title: "Deploy", open: "r1"), needs("approval:2", title: "Lost", open: .some(nil), since: 200)],
            sessions: [.fixture("s1", title: "Recent one", at: at(1))]
        ))
        let menu = MacDockMenu.menu(for: entries, actions: log.actions)
        for index in menu.items.indices where !menu.items[index].isSeparatorItem {
            menu.performActionForItem(at: index)
        }
        XCTAssertEqual(log.calls, ["newChat", "quickAsk", "open:r1", "openConduit", "open:s1"])
    }

    // MARK: Live actions

    private var bringForwardCount = 0

    private func liveActions(appState: AppState, quickAsk: @escaping @MainActor () -> Void = {}) -> MacDockMenuActions {
        bringForwardCount = 0
        return MacDockMenuActions.live(appState: appState, bringForward: { [self] in bringForwardCount += 1 }, showQuickAsk: quickAsk)
    }

    private func makeAppState() -> (appState: AppState, fixture: MacSharedBaseAppStateFixture) {
        let fixture = MacSharedBaseAppStateFixture()
        return (fixture.appState, fixture)
    }

    func testOpenSessionBringsConduitForwardAndTakesTheSidebarRoute() {
        let (appState, fixture) = makeAppState()
        defer { fixture.tearDown() }
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .macSessionOpenRequested, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        liveActions(appState: appState).openSession("s1")
        XCTAssertEqual(bringForwardCount, 1)
        XCTAssertEqual(posted, 1, "requestOpenSession posts macSessionOpenRequested, which returns the pane to Sessions")
    }

    func testOpenConduitBringsConduitForward() {
        let (appState, fixture) = makeAppState()
        defer { fixture.tearDown() }
        liveActions(appState: appState).openConduit()
        XCTAssertEqual(bringForwardCount, 1)
    }

    func testQuickAskShowsThePanelAndLeavesTheMainWindowAlone() {
        let (appState, fixture) = makeAppState()
        defer { fixture.tearDown() }
        var shown = 0
        liveActions(appState: appState, quickAsk: { shown += 1 }).quickAsk()
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(bringForwardCount, 0, "Quick Ask is a panel that never activates Conduit (D15); the main window stays where it is")
    }

    /// New Chat from the Dock goes the File > New Chat way (`MacAppActions.newChat`, Ruling R39): during the connect
    /// it queues one chat, and a second click shows the same chat.
    func testNewChatDuringTheConnectQueuesOneChat() async throws {
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let fixture = MacSharedBaseAppStateFixture()
        defer { fixture.tearDown() }
        let appState = AppState(
            defaults: fixture.suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: fixture.suite.defaults)
        )
        appState.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: fixture.scratch.appendingPathComponent("dock-widgets", isDirectory: true))
        appState.widgetSnapshotReloadOverride = {}
        appState.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
        var creates = 0
        appState.widgetSessionCreatorOverride = { _, _ in
            creates += 1
            return (sessionId: "dock-chat", storedSessionId: "dock-chat", profile: "default")
        }
        _ = appState.handleScenePhase(.active)
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnecting = true
        defer { appState.widgetLaunchCoordinator.supersede() }

        let actions = liveActions(appState: appState)
        actions.newChat()
        actions.newChat()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(bringForwardCount, 2, "each click brings Conduit forward")
        XCTAssertEqual(appState.pendingNewChat, WidgetWorkspaceID(dashboardID: dashboard.id, profile: "default"),
                       "the chat waits for the connection")
        XCTAssertEqual(creates, 0)

        appState.widgetSettledCatalogOwner = WidgetWorkspaceID(dashboardID: dashboard.id, profile: "default")
        appState.isConnecting = false
        appState.isConnected = true
        var created = false
        for _ in 0..<200 where !created {
            created = !appState.showsPendingNewChat && appState.activeSessionId == "dock-chat"
            if !created { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        XCTAssertTrue(created, "the queued chat is created once connected")
        XCTAssertEqual(creates, 1, "two clicks during the connect make one chat")
    }

    // MARK: Snapshot from AppState

    func testTheLiveSnapshotHoldsTheActiveProfilesNonArchivedChatsAndTheFeedsItems() {
        let (appState, fixture) = makeAppState()
        defer { fixture.tearDown() }
        var other = SessionSummary.macTestSummary(id: "o", alternateIds: [], title: "Other profile", lastActivityAt: 3)
        other.profile = "work"
        appState.sessions = [
            .macTestSummary(id: "a", alternateIds: [], title: "Alpha", lastActivityAt: 1),
            .macTestSummary(id: "z", alternateIds: [], title: "Gone", isArchived: true, lastActivityAt: 2),
            other,
        ]
        let snapshot = MacDockSnapshot.make(appState: appState, feed: nil, now: Date())
        XCTAssertEqual(snapshot.sessions.map(\.id), ["a"], "active profile, not archived: the rows Home lists")
        XCTAssertEqual(snapshot.feed, .offline, "no feed means offline")
        XCTAssertTrue(snapshot.live.isEmpty)
        XCTAssertEqual(MacDockSnapshot.waiting(feed: nil), MacDockSnapshot(feed: .offline, live: [], sessions: []))
    }

    func testTheWaitingSnapshotReadsTheFeedsDecisionsAndItsAvailability() {
        let sources = FakeActivitySources()
        let hub = MacStreamEventHub()
        let sleeper = ManualSleeper()
        let feed = AgentActivityFeed(sources: sources, hub: hub, pollSleep: sleeper.sleep, tickSleep: sleeper.sleep)
        XCTAssertEqual(MacDockSnapshot.waiting(feed: feed).feed, .offline, "a feed that was never started is offline")
        feed.start()
        defer {
            feed.stop()
            sleeper.cancelAll()
        }
        hub.publish(.approval(sessionId: "s1", activity: AgentActivityTestSupport.approval(session: "s1", request: "q1")))
        let waiting = MacDockSnapshot.waiting(feed: feed)
        XCTAssertNotEqual(waiting.feed, .offline)
        XCTAssertEqual(MacDockContent.waitingCount(waiting), 1, "one approval waits on the user")
        XCTAssertTrue(waiting.sessions.isEmpty, "the badge needs no session list")
    }

    // MARK: Settings

    func testTheNotificationSettingsHoldTheDockToggle() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let boostWasOn = AccessibilityTreeBoost.isOn
        AccessibilityTreeBoost.set(true)
        defer { AccessibilityTreeBoost.set(boostWasOn) }
        let preferences = MacNotificationPreferences(defaults: suite.defaults)
        let window = HostedTestSupport.host(
            MacNotificationSettingsView(preferences: preferences, authorization: .allowed, dockDefaults: suite.defaults),
            size: NSSize(width: 520, height: 560)
        )
        defer { HostedTestSupport.tearDown(window) }
        let label = AppLocalization.string("Show count on Dock icon")
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.texts(in: window).contains { $0.contains(label) } },
                      "Settings > Notifications > On this Mac has the toggle")
        // The count does not depend on the notification master toggle: it stays enabled when notifications are off.
        preferences.isEnabled = false
        HostedTestSupport.settle(0.3)
        let toggle = AccessibilityProbe.nodes(in: window).first { $0.label == label }
        XCTAssertNotNil(toggle)
        XCTAssertNotEqual(toggle?.isEnabled, false)
    }

    func testTheDockToggleLabelIsCataloguedInAllLanguages() throws {
        let url = repoRoot.appendingPathComponent("Conduit/Localizable.xcstrings")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: [String: Any]])
        let entry = try XCTUnwrap(strings["Show count on Dock icon"], "the key is in the catalog")
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        XCTAssertEqual(Set(localizations.keys),
                       ["en", "de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"])
        for (language, body) in localizations {
            let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any]
            XCTAssertEqual(unit?["state"] as? String, "translated", language)
            XCTAssertFalse((unit?["value"] as? String ?? "").isEmpty, language)
        }
        // The keys the menu reuses are already catalogued.
        for key in ["New Chat", "Quick Ask", "Untitled chat"] { XCTAssertNotNil(strings[key], key) }
    }
}
