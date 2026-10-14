import XCTest
@testable import ConduitMac

/// `MacSessionTabsStore.bind(to:)` against a real `AppState` built the way
/// `MissingSessionRecoveryTests` builds one: injected defaults, no connection,
/// no network. Every session mutation goes through AppState's own test seams.
///
/// `deleteSession` cannot run here: its transport is the final
/// `DashboardTicketBridge` (a WKWebView request) and it has no override seam,
/// and `sessionMutationID` is `private(set)`. The deletion tests drive the same
/// `sessionMutationID` publisher through `renameSession`'s operation override
/// and remove the row inside it, which is the sequence `deleteSession`
/// produces: the mutation id is set, `removeSessionFromLiveCatalog` runs, the
/// id clears. Group rooms are not driven (`activeRoomSurface` is
/// `private(set)` and opening one needs the gateway); the room half of
/// `isChatSurfaceShowing` is covered by the store's closure tests.
@MainActor
final class MacSessionTabsBindTests: XCTestCase {
    /// Lets the rename seam run a closure from a nonisolated operation.
    private final class Hook: @unchecked Sendable {
        var onStoredRename: (@MainActor () -> Void)?
    }

    private var appSuite: (defaults: UserDefaults, name: String)!
    private var tabsSuite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var store: MacSessionTabsStore!
    private let hook = Hook()

    override func setUp() async throws {
        appSuite = HostedTestSupport.makeSuite()
        tabsSuite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSessionTabsBindTests.\(UUID().uuidString)", isDirectory: true)
        let hook = self.hook
        let operations = SessionRenameOperation.Operations(
            renameRuntime: nil,
            renameStored: { _, _ in await MainActor.run { hook.onStoredRename?() } }
        )
        appState = AppState(
            defaults: appSuite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionRenameOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: appSuite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: appSuite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
        // Mutations publish widget snapshots: keep them out of the real app group.
        appState.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: scratch.appendingPathComponent("widgets", isDirectory: true))
        appState.widgetSnapshotReloadOverride = {}
        appState.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
        store = MacSessionTabsStore(defaults: tabsSuite.defaults, routeDefaults: tabsSuite.defaults)
    }

    override func tearDown() async throws {
        hook.onStoredRename = nil
        store = nil
        appState = nil
        HostedTestSupport.dropSuite(appSuite)
        HostedTestSupport.dropSuite(tabsSuite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Helpers

    private func summary(_ id: String, _ title: String, profile: String = "default", source: SessionSource = .chat) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: nil, alternateIds: [], title: title, model: "",
            updatedLabel: "", profile: profile, source: source, isActive: false,
            isArchived: false, lineageRootId: nil
        )
    }

    /// Runs every main-queue block queued so far, and the blocks those queue.
    private func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { DispatchQueue.main.async { DispatchQueue.main.async { done.resume() } } }
        }
    }

    /// Polls without blocking the main actor: the store's sinks hop through
    /// `DispatchQueue.main`, which a run-loop spin inside an async test does
    /// not service, but a suspension does.
    private func eventually(timeout: TimeInterval = 5, _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func openChat(_ id: String) async {
        appState.activeSessionId = id
        let reached = await eventually { self.store.model.activeID == id }
        XCTAssertTrue(reached, "active tab never became \(id)")
    }

    // MARK: - Tests

    func testActiveSessionChangeAddsATabWithTheSummaryTitle() async {
        appState.sessions = [summary("a", "Alpha"), summary("b", "Beta")]
        store.bind(to: appState)
        await openChat("a")
        await openChat("b")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(store.model.tabs.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(store.model.activeID, "b")
    }

    func testRelaunchRestoreClearsThenReactivatesTheResumedSession() async {
        let seed = MacSessionTabsStore(defaults: tabsSuite.defaults)
        seed.setScope(dashboardID: nil, profile: "default")
        seed.activeSessionChanged("a", title: "Alpha")
        seed.activeSessionChanged("b", title: "Beta")
        appState.sessions = [summary("a", "Alpha"), summary("b", "Beta")]

        store.bind(to: appState)
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"], "the stored scope loads at bind")
        await drain()
        XCTAssertNil(store.model.activeID, "launch has no open session yet: the stored active id is cleared")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])

        await openChat("a")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"], "the resumed session re-selects its tab, no duplicate")
    }

    func testRenameKeepsAndRetitlesTheTab() async {
        appState.sessions = [summary("a", "Alpha")]
        store.bind(to: appState)
        await openChat("a")
        let renamed = await appState.renameSession(appState.sessions[0], to: "Renamed")
        XCTAssertTrue(renamed)
        await drain()
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"])
        XCTAssertEqual(store.model.tabs.map(\.title), ["Renamed"])
    }

    func testArchiveKeepsTheTabEvenForTheOpenChat() async {
        appState.sessions = [summary("a", "Alpha"), summary("b", "Beta")]
        store.bind(to: appState)
        await openChat("a")
        await openChat("b")
        let archivedOther = await appState.archiveSession(appState.sessions[0])
        XCTAssertTrue(archivedOther)
        await drain()
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"], "archived is not deleted")
        XCTAssertEqual(appState.archivedSessions.map(\.id), ["a"])

        let archivedOpen = await appState.archiveSession(appState.sessions[0])
        XCTAssertTrue(archivedOpen)
        await drain()
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(Set(appState.archivedSessions.map(\.id)), ["a", "b"])
    }

    func testDeletionRemovesTheTabAndOnlyThatTab() async {
        appState.sessions = [summary("a", "Alpha"), summary("b", "Beta")]
        store.bind(to: appState)
        await openChat("a")
        await openChat("b")
        let doomed = appState.sessions[0]
        hook.onStoredRename = { [appState] in appState?.removeSessionFromLiveCatalog(doomed) }
        _ = await appState.renameSession(doomed, to: "Gone")  // sessionMutationID set, row removed, id cleared
        let removed = await eventually { self.store.model.tabs.map(\.id) == ["b"] }
        XCTAssertTrue(removed, "tabs: \(store.model.tabs.map(\.id))")
        XCTAssertEqual(store.model.activeID, "b")
    }

    func testDeletedCronSessionRemovesItsTab() async {
        let cron = summary("c1", "Nightly run", source: .cron)
        appState.sessions = [summary("a", "Alpha")]
        appState.cronSessions = [cron]
        store.bind(to: appState)
        await openChat("a")
        await openChat("c1")
        XCTAssertEqual(store.model.tabs.map(\.title), ["Alpha", "Nightly run"], "cron rows get tabs")
        hook.onStoredRename = { [appState] in appState?.removeSessionFromLiveCatalog(cron) }
        _ = await appState.renameSession(cron, to: "Gone")
        let removed = await eventually { self.store.model.tabs.map(\.id) == ["a"] }
        XCTAssertTrue(removed, "tabs: \(store.model.tabs.map(\.id))")
    }

    func testProfileChangeSwapsTheTabScopeAndBack() async {
        appState.sessions = [summary("a", "Alpha")]
        store.bind(to: appState)
        await openChat("a")

        appState.setActiveProfileForTesting("work")
        XCTAssertTrue(store.model.tabs.isEmpty, "the work profile has its own, empty, tab set")
        let defaultKey = MacSessionTabsStore.storageKey(dashboardID: nil, profile: "default")
        XCTAssertNotNil(tabsSuite.defaults.data(forKey: defaultKey), "the outgoing scope was saved")

        appState.setActiveProfileForTesting("default")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"], "switching back restores the default profile's tabs")
        XCTAssertEqual(store.model.tabs.map(\.title), ["Alpha"])
    }

    func testChatSurfaceFollowsTheSidebarPane() {
        store.bind(to: appState)
        XCTAssertTrue(store.isChatSurfaceShowing(), "no stored pane: Sessions")
        for pane in [SidebarTab.bots, .cron, .kanban] {
            tabsSuite.defaults.set(pane.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            XCTAssertFalse(store.isChatSurfaceShowing(), "\(pane) hides the chat")
        }
        tabsSuite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        XCTAssertTrue(store.isChatSurfaceShowing())
    }
}
