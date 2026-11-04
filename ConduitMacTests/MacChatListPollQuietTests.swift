import Combine
import XCTest
@testable import ConduitMac

/// A chat-list poll that reads what is already on screen publishes nothing (D36).
///
/// `SessionList` observes all of `AppState`, so each publish re-evaluates every row. The poll reads
/// the catalog about once a minute while nothing moves, and each read used to write `sessions`,
/// `cronSessions`, the load state, the active title, the voice tags and the projects again, equal
/// values included. The tests below read the same content twice through the catalog seam
/// (`sessionCatalogLoader`) and count `objectWillChange` on the second read.
@MainActor
final class MacChatListPollQuietTests: XCTestCase {
    private final class Box {
        weak var appState: AppState?
        var catalog: [SessionSummary] = []
        var projects: [ProjectSummary] = []
        var projectsError: Error?
        var tags: [String: Any] = [:]
        /// What the dashboard bridge was asked, oldest first.
        var requests: [(method: String, path: String, body: [String: Any]?)] = []
        var loads = 0
        var projectReads = 0
        var tagReads = 0
        /// What `projectsLoading` read while each project read was under way.
        var loadingDuringProjectReads: [Bool] = []
        var now = Date(timeIntervalSince1970: 2_000_000)
        /// How long a catalog read takes on the poll's clock.
        var readTakes: TimeInterval = 0
    }

    private final class Publishes {
        var count = 0
        var token: AnyCancellable?
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        suite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatListPollQuiet.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeAppState(_ box: Box, dashboard: SavedDashboard? = nil) -> AppState {
        var operations = ChatResumeLifecycleOperations()
        operations.loadProjects = { _ in
            box.projectReads += 1
            box.loadingDuringProjectReads.append(box.appState?.projectsLoading ?? false)
            if let error = box.projectsError { throw error }
            return box.projects
        }
        let appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: dashboard.map { SavedDashboardRegistry(activeDashboardID: $0.id, dashboards: [$0]) }
                ?? SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionCatalogLoader: { _ in
                box.loads += 1
                box.now += box.readTakes
                return box.catalog
            },
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
        appState.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: scratch.appendingPathComponent("widgets", isDirectory: true))
        appState.widgetSnapshotReloadOverride = {}
        appState.isConnected = true
        appState.chatSyncNow = { box.now }
        // Not this Mac's Low Power Mode or network.
        appState.deviceConditions = { DeviceConditions() }
        box.appState = appState
        return appState
    }

    private func row(
        _ id: String,
        profile: String,
        title: String? = nil,
        unread: Bool? = nil,
        watermark: Double? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: title ?? id,
            model: "Hermes",
            updatedLabel: "",
            lastActivityAt: 1_900_000,
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            messageCount: 3,
            isUnread: unread,
            readWatermark: watermark,
            lineageRootId: nil
        )
    }

    private func project(_ id: String, title: String, isHome: Bool = false, sessions: Int = 1) -> ProjectSummary {
        ProjectSummary(
            id: id,
            title: title,
            primaryPath: nil,
            icon: nil,
            colorHex: nil,
            isHome: isHome,
            sessionCount: sessions,
            previewSessions: []
        )
    }

    @discardableResult
    private func installClient(_ appState: AppState) -> HermesClient {
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://hermes.test", ticket: "ticket"),
            profile: "default"
        )
        appState.client = client
        return client
    }

    /// A dashboard bridge that answers every request with `{}` and records it in the box. The
    /// requests go out the way they do while the app is in the background (without the page), which
    /// does not depend on WebKit in the test host.
    private func recordingBridge(_ box: Box) -> DashboardTicketBridge {
        let bridge = DashboardTicketBridge(baseURL: "https://hermes.test")
        bridge.webViewCanRun = { false }
        if let cookie = HTTPCookie(properties: [.name: "session", .value: "test", .domain: "hermes.test", .path: "/"]) {
            bridge.backgroundIssuedCookies = [cookie]
        }
        bridge.loadWithoutPageForTesting = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            box.requests.append((request.httpMethod ?? "GET", request.url?.path ?? "", body))
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            return (Data("{}".utf8), response ?? URLResponse())
        }
        return bridge
    }

    private func watch(_ appState: AppState) -> Publishes {
        let publishes = Publishes()
        publishes.token = appState.objectWillChange.sink { [unowned publishes] _ in publishes.count += 1 }
        return publishes
    }

    /// One tick of the Chats list's poll, and the catalog read it asked for.
    private func poll(_ appState: AppState) async {
        await appState.chatListPollTick()
        await appState.leaveCatalogRefreshTask?.value
    }

    // MARK: - The catalog

    func testAPollThatReadsTheSameCatalogPublishesNothing() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        box.catalog = [row("a", profile: profile), row("b", profile: profile), row("c", profile: profile)]
        await appState.loadSessions()
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "b", "c"], "precondition")
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded, "precondition")

        let published = watch(appState)
        box.now += 40
        await poll(appState)

        XCTAssertEqual(box.loads, 2, "the poll read the catalog again")
        XCTAssertEqual(published.count, 0)
    }

    /// The open chat's title and read state are written on every read too.
    func testAPollWithAChatOpenPublishesNothing() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        box.catalog = [row("a", profile: profile, title: "First"), row("b", profile: profile, title: "Second")]
        appState.activeSessionId = "b"
        await appState.loadSessions()
        XCTAssertEqual(appState.activeSessionTitle, "Second", "precondition")

        let published = watch(appState)
        box.now += 40
        await poll(appState)

        XCTAssertEqual(box.loads, 2)
        XCTAssertEqual(published.count, 0)
        XCTAssertEqual(appState.activeSessionTitle, "Second")
    }

    func testARenamedRowStillPublishesAndShows() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        box.catalog = [row("a", profile: profile), row("b", profile: profile)]
        await appState.loadSessions()

        box.catalog = [row("a", profile: profile, title: "Renamed"), row("b", profile: profile)]
        let published = watch(appState)
        box.now += 40
        await poll(appState)

        XCTAssertEqual(appState.sessions.map(\.title), ["Renamed", "b"])
        // The one write of `sessions`: the cron list is equal and the ids are the same.
        XCTAssertEqual(published.count, 1)
    }

    func testAChangedOpenChatTitleStillShows() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        box.catalog = [row("a", profile: profile, title: "Before")]
        appState.activeSessionId = "a"
        await appState.loadSessions()
        XCTAssertEqual(appState.activeSessionTitle, "Before", "precondition")

        box.catalog = [row("a", profile: profile, title: "After")]
        box.now += 40
        await poll(appState)

        XCTAssertEqual(appState.activeSessionTitle, "After")
    }

    // MARK: - What the equal read still does

    // `sessions.didSet` ran the read-state upkeep (`observeChatReadState`) on every read. An equal list
    // is not assigned, so the read runs the upkeep itself. The three tests below read an equal list
    // and check one thing of the upkeep each: `ChatReadState.observe` seeds a row, `observe` lets a
    // pending server value lapse, and `clearHermesFlagsSeenHere` retries the clear of an unread flag.

    /// `observe` seeds a row the ledger lost, and the read publishes once for that change alone.
    func testAnEqualReadStillSeedsALostLedgerRow() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        let listed = row("a", profile: profile)
        box.catalog = [listed, row("b", profile: profile)]
        await appState.loadSessions()
        appState.updateChatReadState { $0.forget(listed, profile: profile) }
        XCTAssertNil(appState.chatReadState.ledger.seenCounts[profile]?["a"], "precondition")

        let published = watch(appState)
        box.now += 40
        await poll(appState)

        XCTAssertEqual(box.loads, 2)
        XCTAssertEqual(appState.chatReadState.ledger.seenCounts[profile]?["a"], 3, "the upkeep seeded the row again")
        // The ledger entry is the one change. The list is equal and is not written.
        XCTAssertEqual(published.count, 1)

        // With nothing left to seed, the upkeep has nothing to publish.
        box.now += 40
        await poll(appState)
        XCTAssertEqual(box.loads, 3)
        XCTAssertEqual(published.count, 1)
    }

    /// `observe` lets a pending server value lapse: a flag write sent 31 s ago that no listing
    /// confirmed no longer outranks the listing. The read publishes once, for that stored change.
    func testAnEqualReadStillExpiresAPendingServerValue() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        let listed = row("a", profile: profile)
        box.catalog = [listed, row("b", profile: profile)]
        await appState.loadSessions()
        let sentAt = Date().addingTimeInterval(-(ChatReadState.pendingServerValueLifetime + 1))
        appState.updateChatReadState { _ = $0.recordServerWrite(listed, profile: profile, unread: true, at: sentAt) }
        XCTAssertEqual(appState.chatReadState.pendingServerValues.count, 1, "precondition")

        let published = watch(appState)
        box.now += 40
        await poll(appState)

        XCTAssertEqual(box.loads, 2)
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "b"], "the list is the equal one")
        XCTAssertTrue(appState.chatReadState.pendingServerValues.isEmpty, "the lapsed value is dropped")
        // The dropped value is the one change. The list is equal and is not written.
        XCTAssertEqual(published.count, 1)

        box.now += 40
        await poll(appState)
        XCTAssertEqual(box.loads, 3)
        XCTAssertEqual(published.count, 1, "nothing is left to drop")
    }

    /// `clearHermesFlagsSeenHere` retries the clear of an unread flag. The user saw the chat before
    /// leaving it, Hermes still flags it unread, and the earlier clear was sent 6 minutes ago and never
    /// confirmed. The upkeep of an equal read lets that attempt lapse and sends the clear again, once.
    func testAnEqualReadStillRetriesAnUnreadFlagClear() async throws {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        appState.installDashboardTicketBridgeForTesting(recordingBridge(box))
        let flagged = row("a", profile: profile, unread: true, watermark: 1_850_000)
        box.catalog = [flagged, row("b", profile: profile)]
        await appState.loadSessions()
        appState.updateChatReadState { $0.markSeen(flagged, profile: profile, at: Date()) }
        let attemptedAt = Date().addingTimeInterval(-(ChatReadState.passiveRewriteInterval + 60))
        appState.updateChatReadState { state in
            let generation = state.recordServerWrite(flagged, profile: profile, unread: false, at: attemptedAt)
            state.discardServerWrite(flagged, profile: profile, generation: generation)
        }
        XCTAssertTrue(appState.chatReadState.pendingServerValues.isEmpty, "precondition")
        XCTAssertFalse(appState.chatReadState.lastWriteAttempts.isEmpty, "precondition: the earlier attempt is on record")

        func flagClears() -> [[String: Any]] {
            box.requests.filter { $0.method == "PATCH" && $0.path == "/api/sessions/a" }.compactMap(\.body)
        }
        let published = watch(appState)
        box.now += 40
        await poll(appState)

        XCTAssertEqual(box.loads, 2)
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "b"], "the list is the equal one")
        // The retry records its write as pending before it sends it.
        let retried = try XCTUnwrap(appState.chatReadState.pendingServerValues.values.first, "the retry recorded its write")
        XCTAssertFalse(retried.unread)
        // That pending write is the one change. The list is equal and is not written.
        XCTAssertEqual(published.count, 1)
        // Each request waits for the web view's cookie store for up to 2 s in the test host: the
        // limit is a cap, not a timing.
        // The send is a task on the main actor: the wait must suspend, not spin the run loop. The
        // limit is a cap, not a timing.
        for _ in 0..<2_000 where flagClears().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(
            flagClears().isEmpty,
            "the clear was sent again; the bridge was asked \(box.requests.map { "\($0.method) \($0.path)" })"
        )
        XCTAssertEqual(flagClears().first?["unread"] as? Bool, false)

        // The clear just recorded holds the next read back: no second write.
        box.now += 40
        await poll(appState)
        XCTAssertEqual(box.loads, 3)
        XCTAssertEqual(appState.chatReadState.pendingServerValues.values.first?.generation, retried.generation)
        XCTAssertEqual(flagClears().count, 1)
        XCTAssertEqual(published.count, 1)
    }

    /// An equal read still records when the catalog loaded: the next read is due from that moment.
    /// The read takes 5 s on the poll's clock, so the moment of the load differs from the moment
    /// the poll asked for it.
    func testAnEqualReadStillRecordsWhenTheCatalogLoaded() async {
        let box = Box()
        box.readTakes = 5
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        let start = box.now
        box.catalog = [row("a", profile: profile)]
        await appState.loadSessions()

        box.now = start.addingTimeInterval(36)
        await poll(appState)
        XCTAssertEqual(box.loads, 2, "precondition: the poll read an equal catalog")

        // Back in the app 6 s after that read landed (11 s after the poll asked for it).
        box.now = start.addingTimeInterval(47)
        appState.chatListBecameActive()
        await appState.leaveCatalogRefreshTask?.value
        XCTAssertEqual(box.loads, 2, "the read that landed at 41 s is younger than 10 s")
    }

    /// The seen moment of a chat on screen moves forward on a listing once a minute. That bookkeeping
    /// is read by `observe` and `markSeen` only: no row shows it, so it does not publish.
    func testASeenMomentRestampedOnScreenPublishesNothing() {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        let listed = row("a", profile: profile)
        let first = Date(timeIntervalSince1970: 3_000_000)
        appState.updateChatReadState { $0.markSeen(listed, profile: profile, at: first) }

        let published = watch(appState)
        let later = first.addingTimeInterval(ChatReadState.seenRestampInterval + 1)
        appState.updateChatReadState { $0.markSeen(listed, profile: profile, at: later) }

        XCTAssertEqual(appState.chatReadState.seenPendingRefresh.values.first, later, "the moment is stored")
        XCTAssertEqual(published.count, 0)

        // A change a row can show still publishes.
        appState.updateChatReadState { $0.markUnread(listed, profile: profile) }
        XCTAssertEqual(published.count, 1)
        XCTAssertTrue(appState.chatReadState.isMarkedUnread(listed, profile: profile))
    }

    /// What a row can show is the ledger, the pending server values and the Desktop record. The seen
    /// moments, the write attempts and the write counter are bookkeeping.
    func testOnlyBookkeepingIsLeftOutOfWhatRowsRead() {
        let listed = row("a", profile: "default")
        let first = Date(timeIntervalSince1970: 3_000_000)
        var state = ChatReadState()
        state.markSeen(listed, profile: "default", at: first)

        var restamped = state
        restamped.markSeen(listed, profile: "default", at: first.addingTimeInterval(ChatReadState.seenRestampInterval + 1))
        XCTAssertNotEqual(state, restamped, "precondition: the state moved")
        XCTAssertTrue(state.readsTheSame(as: restamped))

        var marked = state
        marked.markUnread(listed, profile: "default")
        XCTAssertFalse(state.readsTheSame(as: marked))

        var written = state
        written.recordServerWrite(listed, profile: "default", unread: true, at: first)
        XCTAssertFalse(state.readsTheSame(as: written))

        var viewed = state
        viewed.recordDesktopViews(["a": 10], profile: "default")
        XCTAssertFalse(state.readsTheSame(as: viewed))

        var counted = state
        counted.observe([row("a", profile: "default"), row("b", profile: "default")], profile: "default", now: first)
        XCTAssertFalse(state.readsTheSame(as: counted), "a row seeded in the ledger is a change")
    }

    // MARK: - Projects

    func testProjectsReadWithTheSameContentPublishNothing() async {
        let box = Box()
        let appState = makeAppState(box)
        installClient(appState)
        box.projects = [project("home", title: "Home", isHome: true, sessions: 4), project("p2", title: "Other")]
        await appState.refreshProjects()
        XCTAssertEqual(appState.projects.map(\.id), ["home", "p2"], "precondition")
        XCTAssertTrue(appState.supportsProjects, "precondition")
        XCTAssertFalse(appState.projectsLoading, "precondition")

        let published = watch(appState)
        await appState.refreshProjects()

        XCTAssertEqual(box.projectReads, 2)
        XCTAssertEqual(box.loadingDuringProjectReads, [true, false], "the first load shows its loading state, the next does not")
        XCTAssertEqual(published.count, 0)
        XCTAssertFalse(appState.projectsLoading)
    }

    func testProjectsReadWithNewContentStillPublish() async {
        let box = Box()
        let appState = makeAppState(box)
        installClient(appState)
        box.projects = [project("home", title: "Home", isHome: true), project("p2", title: "Other")]
        await appState.refreshProjects()

        box.projects = [project("home", title: "Home", isHome: true), project("p2", title: "Renamed")]
        let published = watch(appState)
        await appState.refreshProjects()

        XCTAssertEqual(appState.projects.map(\.title), ["Home", "Renamed"])
        // The one write of `projects`: the support flag and the failure flag are unchanged.
        XCTAssertEqual(published.count, 1)
    }

    /// A host without projects answers "unavailable" on every read.
    func testAHostWithoutProjectsPublishesNothingOnTheNextRead() async {
        let box = Box()
        let appState = makeAppState(box)
        installClient(appState)
        box.projectsError = RpcError(code: -32601, message: "method not found")
        await appState.refreshProjects()
        XCTAssertFalse(appState.supportsProjects, "precondition")
        XCTAssertFalse(appState.projectsLoadFailed, "precondition")

        let published = watch(appState)
        await appState.refreshProjects()

        XCTAssertEqual(box.projectReads, 2)
        XCTAssertEqual(published.count, 0)
    }

    /// Try Again after a failed read still shows the loading state.
    func testAFailedProjectsReadShowsLoadingOnRetry() async {
        let box = Box()
        let appState = makeAppState(box)
        installClient(appState)
        box.projectsError = URLError(.timedOut)
        await appState.refreshProjects()
        XCTAssertTrue(appState.projectsLoadFailed, "precondition")

        box.projectsError = nil
        box.projects = [project("home", title: "Home", isHome: true)]
        await appState.refreshProjects()

        XCTAssertEqual(box.loadingDuringProjectReads, [true, true])
        XCTAssertFalse(appState.projectsLoadFailed)
        XCTAssertEqual(appState.projects.map(\.id), ["home"])
    }

    /// A read over the project pages the saved Chats list brought keeps its loading state, also when
    /// Hermes sends the same pages and this client and profile answered before: the answer ends the
    /// seeding, so the pages are not yet Hermes' own.
    func testAReadOverSavedListPagesKeepsTheLoadingFlag() async {
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let box = Box()
        let appState = makeAppState(box, dashboard: dashboard)
        let client = installClient(appState)
        let pages = [project("home", title: "Home", isHome: true, sessions: 4)]
        box.projects = pages
        await appState.refreshProjects()
        XCTAssertEqual(box.loadingDuringProjectReads, [true], "precondition")
        XCTAssertEqual(appState.projects, pages, "precondition")

        // A server change clears the projects and the list, and not what the client answered.
        appState.prepareChatResumeForConnection(to: "https://one.example", dashboardID: UUID())
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: "https://two.example", dashboardID: UUID()), "precondition")
        appState.client = client
        XCTAssertTrue(appState.projects.isEmpty, "precondition")
        XCTAssertFalse(appState.supportsProjects, "precondition")

        // The saved Chats list of the scope brings the same pages.
        appState.offlineChatCacheForTesting.recordChatList(
            SavedChatList.capture(
                sessions: [row("a", profile: appState.activeProfile)],
                cronSessions: [],
                isPinned: { _ in false },
                voiceTags: [:],
                projects: pages,
                supportsProjects: true
            ),
            dashboardID: dashboard.id,
            profile: appState.activeProfile
        )
        appState.presentSavedChatListIfAvailable(dashboardID: dashboard.id)
        XCTAssertTrue(appState.projectsSeededFromSavedList, "precondition")
        XCTAssertEqual(appState.projects, pages, "precondition")
        XCTAssertTrue(appState.supportsProjects, "precondition")

        await appState.refreshProjects()

        XCTAssertEqual(box.projectReads, 2)
        XCTAssertEqual(box.loadingDuringProjectReads, [true, true], "the read over saved pages shows its loading state")
        XCTAssertFalse(appState.projectsSeededFromSavedList, "Hermes' answer ends the seeding, though it is equal")
        XCTAssertEqual(appState.projects, pages)
        XCTAssertFalse(appState.projectsLoading)

        // Now that the pages are Hermes' own, the next read repeats the answer.
        await appState.refreshProjects()
        XCTAssertEqual(box.loadingDuringProjectReads, [true, true, false])
    }

    // MARK: - Voice tags

    func testVoiceTagsReadWithTheSameContentPublishNothing() {
        let box = Box()
        let appState = makeAppState(box)
        let bridge = DashboardTicketBridge(baseURL: "https://hermes.test")
        bridge.webViewCanRun = { false }
        appState.installDashboardTicketBridgeForTesting(bridge)
        box.tags = ["s1": ["kind": "call", "engine": "gemini-live"]]
        appState.voiceHistoryClient = VoiceHistoryClient(request: { _, _, _ in
            box.tagReads += 1
            return ["ok": true, "tags": box.tags]
        })

        // A call returns early while an earlier read's task lives, so a read is started by calling
        // until it runs. A read that starts proves that the one before it has ended.
        func startRead(number: Int) -> Bool {
            HostedTestSupport.waitUntil {
                if box.tagReads < number { appState.refreshVoiceSessionTags(force: true) }
                return box.tagReads >= number
            }
        }
        XCTAssertTrue(startRead(number: 1), "precondition")
        XCTAssertTrue(HostedTestSupport.waitUntil { !appState.voiceSessionTagsByKey.isEmpty }, "precondition")

        // The watch covers the whole second read: the first one's tags have landed, and the second
        // read has not started yet.
        let published = watch(appState)
        XCTAssertTrue(startRead(number: 2))
        XCTAssertTrue(startRead(number: 3), "the third read starts only after the second one ended")

        XCTAssertEqual(published.count, 0)
    }
}
