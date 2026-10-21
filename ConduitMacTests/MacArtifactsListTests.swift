import AppKit
import XCTest
@testable import ConduitMac

enum ArtifactsTestSupport {
    /// The construction MacDashboardSwitcherTests uses: no saved connection, no network, nothing in
    /// the live app's defaults.
    @MainActor
    static func isolatedAppState(defaults: UserDefaults, scratch: URL) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
    }

    /// A row as the host's plugin sends it.
    static func row(_ fields: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "kind": "image", "source": "delivered", "name": "map.png", "path": "/root/out/map.png",
            "exists": true, "size": 2048, "session_id": "s1", "session_title": "Weekend trip",
            "message_id": 12, "timestamp": Date().timeIntervalSince1970,
        ]
        row.merge(fields) { _, new in new }
        return row
    }
}

/// The Mac Artifacts list's rules: the loading state machine (a Mac twin of upstream's
/// `ArtifactsList` state), what Open does for each kind of item, and the copy actions.
@MainActor
final class MacArtifactsListTests: XCTestCase {
    private let key = ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "")

    private func item(_ fields: [String: Any] = [:]) throws -> ArtifactItem {
        var row: [String: Any] = [
            "kind": "image", "source": "delivered", "name": "map.png", "path": "/root/out/map.png",
            "exists": true, "size": 2048, "session_id": "s1", "session_title": "Weekend trip",
            "message_id": 12, "timestamp": 1_760_000_000.0,
        ]
        row.merge(fields) { _, new in new }
        return try XCTUnwrap(ArtifactItem(row))
    }

    private func gone(_ name: String, message: Int) throws -> ArtifactItem {
        try item(["exists": false, "path": "/root/\(name)", "kind": "document", "name": name, "message_id": message])
    }

    private func loaded(_ items: [ArtifactItem], next: Int?) -> MacArtifactsListState {
        var state = MacArtifactsListState()
        let ticket = state.beginReload(key)
        state.finishReload(.page(ArtifactPage(items: items, nextBefore: next)), key: key, ticket: ticket)
        return state
    }

    // MARK: reload

    func testReloadShowsThePageAndRemembersItsKey() throws {
        var state = MacArtifactsListState()
        let ticket = state.beginReload(key)
        XCTAssertTrue(state.isLoading)
        state.finishReload(.page(ArtifactPage(items: [try item()], nextBefore: 4)), key: key, ticket: ticket)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.items.map(\.name), ["map.png"])
        XCTAssertEqual(state.nextBefore, 4)
        XCTAssertEqual(state.loadedKey, key)
        XCTAssertNil(state.failure)
    }

    func testAnOlderReloadNeverOverwritesANewerOne() throws {
        var state = MacArtifactsListState()
        let old = state.beginReload(key)
        let new = state.beginReload(key)
        state.finishReload(.page(ArtifactPage(items: [try item(["name": "old.png", "path": "/old.png"])], nextBefore: nil)),
                           key: key, ticket: old)
        XCTAssertTrue(state.items.isEmpty, "a stale answer is dropped")
        XCTAssertTrue(state.isLoading, "and does not end the newer load")
        state.finishReload(.page(ArtifactPage(items: [try item()], nextBefore: nil)), key: key, ticket: new)
        XCTAssertEqual(state.items.map(\.name), ["map.png"])
        XCTAssertFalse(state.isLoading)
    }

    func testAFailedRefreshKeepsTheListItRefreshed() throws {
        var state = loaded([try item()], next: nil)
        let ticket = state.beginReload(key)
        state.finishReload(.failed("offline"), key: key, ticket: ticket)
        XCTAssertEqual(state.items.map(\.name), ["map.png"])
        XCTAssertNil(state.failure)
        XCTAssertFalse(state.isLoading)
    }

    func testAFailedFirstLoadShowsTheFailure() throws {
        var state = MacArtifactsListState()
        let ticket = state.beginReload(key)
        state.finishReload(.failed("offline"), key: key, ticket: ticket)
        XCTAssertEqual(state.failure, "offline")
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertEqual(state.loadedKey, key, "the failure is for this key, so the spinner stops")
        XCTAssertFalse(state.isLoading)
    }

    func testACancelledReloadEndsItsLoadAndChangesNothing() throws {
        var state = loaded([try item()], next: 3)
        let ticket = state.beginReload(key)
        state.finishReload(.cancelled, key: key, ticket: ticket)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.nextBefore, 3)
        XCTAssertNil(state.failure)
    }

    // MARK: paging

    func testReadingTheNextPageDoesNotSwapTheListForTheSpinner() throws {
        var state = loaded([try item()], next: 5)
        let request = try XCTUnwrap(state.beginNextPage(current: key))
        XCTAssertEqual(request.before, 5)
        XCTAssertFalse(state.isLoading, "isLoading is for a reload; paging on it unmounted the pager (upstream #1068)")
        XCTAssertEqual(state.loadingBefore, 5)
        state.finishNextPage(.page(ArtifactPage(items: [try item(["name": "b.png", "path": "/b.png", "message_id": 3])],
                                                nextBefore: nil)), request: request)
        XCTAssertEqual(state.items.map(\.name), ["map.png", "b.png"])
        XCTAssertNil(state.nextBefore)
        XCTAssertNil(state.loadingBefore)
    }

    func testOneCursorIsReadOnce() throws {
        var state = loaded([try item()], next: 5)
        XCTAssertNotNil(state.beginNextPage(current: key))
        XCTAssertNil(state.beginNextPage(current: key), "the same cursor is already being read")
    }

    func testANewCursorIsNotTurnedAwayByTheOldReadStillUnwinding() throws {
        var state = loaded([try item()], next: 5)
        let first = try XCTUnwrap(state.beginNextPage(current: key))
        // The page the old read would bring is not needed any more: a reload moved the cursor.
        let reload = state.beginReload(key)
        state.finishReload(.page(ArtifactPage(items: [try item()], nextBefore: 8)), key: key, ticket: reload)
        let second = try XCTUnwrap(state.beginNextPage(current: key), "cursor 8 is a new read")
        XCTAssertEqual(second.before, 8)
        state.finishNextPage(.cancelled, request: first)
        XCTAssertEqual(state.loadingBefore, 8, "the old read clears only its own cursor")
        state.finishNextPage(.page(ArtifactPage(items: [], nextBefore: nil)), request: second)
        XCTAssertNil(state.loadingBefore)
    }

    func testAPageFromBeforeAReloadIsDropped() throws {
        var state = loaded([try item()], next: 5)
        let request = try XCTUnwrap(state.beginNextPage(current: key))
        let reload = state.beginReload(key)
        state.finishReload(.page(ArtifactPage(items: [try item()], nextBefore: 8)), key: key, ticket: reload)
        state.finishNextPage(.page(ArtifactPage(items: [try item(["name": "b.png", "path": "/b.png"])], nextBefore: nil)),
                             request: request)
        XCTAssertEqual(state.items.map(\.name), ["map.png"])
        XCTAssertEqual(state.nextBefore, 8)
    }

    func testPagingNeedsTheListsOwnKey() throws {
        var state = loaded([try item()], next: 5)
        let other = ArtifactsListKey(dashboard: nil, profile: "default", filter: .images, query: "")
        XCTAssertNil(state.beginNextPage(current: other), "rows read for another filter do not page for this one")
        var unloaded = MacArtifactsListState()
        XCTAssertNil(unloaded.beginNextPage(current: key))
        _ = state.beginReload(key)
        XCTAssertNil(state.beginNextPage(current: key), "not while a reload is reading")
    }

    func testAPagingFailureOffersTryAgainAndKeepsTheRows() throws {
        var state = loaded([try item()], next: 5)
        let request = try XCTUnwrap(state.beginNextPage(current: key))
        state.finishNextPage(.failed("offline"), request: request)
        XCTAssertEqual(state.failure, "offline")
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.nextBefore, 5)
        XCTAssertNil(state.loadingBefore)
    }

    func testAPageTheFilterEmptiedStillPagesOn() throws {
        // Every row of the first page is a file the host no longer has.
        var state = loaded([try gone("a.pdf", message: 9), try gone("b.pdf", message: 8)], next: 5)
        XCTAssertTrue(state.visibleItems(showMissing: false).isEmpty)
        XCTAssertNotNil(state.nextBefore, "so the pager reads on")
        let request = try XCTUnwrap(state.beginNextPage(current: key))
        state.finishNextPage(.page(ArtifactPage(items: [try item()], nextBefore: nil)), request: request)
        XCTAssertEqual(state.visibleItems(showMissing: false).map(\.name), ["map.png"])
    }

    // MARK: missing files

    func testALinkIsNeverMissing() throws {
        let link = try item(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                             "name": "Curate", "exists": false])
        XCTAssertFalse(MacArtifactsListState.isMissing(link))
        XCTAssertTrue(MacArtifactsListState.isMissing(try gone("a.pdf", message: 1)))
        XCTAssertFalse(MacArtifactsListState.isMissing(try item()))
    }

    // MARK: open

    func testOpenPicksTheViewerForEachKind() throws {
        let link = try item(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                             "name": "Curate"])
        XCTAssertEqual(MacArtifactsList.openAction(for: link), .link(URL(string: "https://curate.example/r")!))
        let page = try item(["kind": "page", "name": "chart.html", "path": "/root/chart.html"])
        XCTAssertEqual(MacArtifactsList.openAction(for: page), .page(path: "/root/chart.html"))
        XCTAssertEqual(MacArtifactsList.openAction(for: try item()), .file(path: "/root/out/map.png"))
        XCTAssertEqual(MacArtifactsList.openAction(for: try gone("a.pdf", message: 1)), .missing,
                       "a file the host lost opens the alert, not a download")
    }

    // MARK: copy

    func testCopyLinkWritesTheURLAndCopyPathWritesTheText() throws {
        let board = NSPasteboard(name: .init("conduit.test.\(UUID())"))
        defer { board.releaseGlobally() }
        let url = try XCTUnwrap(URL(string: "https://curate.example/r?x=1"))
        MacArtifactsList.copyLink(url, to: board)
        XCTAssertEqual((board.readObjects(forClasses: [NSURL.self])?.first as? URL), url)
        XCTAssertEqual(board.string(forType: .string), url.absoluteString, "a text field gets the address too")
        MacArtifactsList.copyPath("/root/out/map.png", to: board)
        XCTAssertEqual(board.string(forType: .string), "/root/out/map.png")
        XCTAssertFalse(board.types?.contains(.URL) ?? false, "copying the path replaced the link")
    }

    // MARK: labels

    func testEveryKindHasAUserFacingLabel() {
        for kind in [ArtifactItem.Kind.image, .video, .audio, .page, .document, .file, .link] {
            XCTAssertFalse(MacArtifactsList.kindLabel(kind).isEmpty)
        }
        XCTAssertEqual(MacArtifactsList.kindLabel(.page), "Page")
    }

    func testDayTitleNamesTodayAndYesterday() throws {
        XCTAssertEqual(MacArtifactsList.dayTitle(Date()), "Today")
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        XCTAssertEqual(MacArtifactsList.dayTitle(yesterday), "Yesterday")
    }
}

/// The list hosted in a window, reading from a fake host. `AppState` cannot be made to report the
/// `artifacts` capability from a test, so the list's `MacArtifactsSource` is swapped.
@MainActor
final class MacArtifactsListHostedTests: XCTestCase {
    private final class Host {
        var paths: [String] = []
        var pages: [[String: Any]] = []
        var failure: Error?
        func request(_ path: String) throws -> [String: Any] {
            paths.append(path)
            if let failure { throw failure }
            guard !pages.isEmpty else { return ["ok": true, "items": [], "next_before": NSNull()] }
            return pages.count > 1 ? pages.removeFirst() : pages[0]
        }
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false
    private let host = Host()

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacArtifactsListHostedTests.\(UUID().uuidString)", isDirectory: true)
        appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func page(_ rows: [[String: Any]], next: Any = NSNull()) -> [String: Any] {
        ["ok": true, "items": rows, "next_before": next]
    }

    private func show(query: String = "", supported: Bool = true) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let source = MacArtifactsSource(
            supported: { _ in supported },
            client: { [host] _ in ArtifactsClient(request: { try host.request($0) }) })
        let view = MacArtifactsList(scope: .profile, chatIsOpen: false, query: query, showInChat: { _ in })
            .environment(\.macArtifactsSource, source)
            .environmentObject(appState)
            .defaultAppStorage(suite.defaults)
            .frame(width: 560, height: 640)
        let w = HostedTestSupport.host(view, size: NSSize(width: 560, height: 640))
        window = w
        return w
    }

    private func texts(_ w: NSWindow) -> [String] { AccessibilityProbe.texts(in: w) }

    private func has(_ w: NSWindow, _ needle: String) -> Bool {
        texts(w).contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    func testLoadedListShowsChipsTilesRowsAndLinks() throws {
        host.pages = [page([
            ArtifactsTestSupport.row(),
            ArtifactsTestSupport.row(["kind": "document", "name": "notes.pdf", "path": "/root/notes.pdf", "message_id": 11]),
            ArtifactsTestSupport.row(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                                      "name": "Curate", "message_id": 10]),
        ])]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "notes.pdf") }, "\(texts(w))")
        let labels = AccessibilityProbe.labels(in: w)
        for chip in ["All", "Images", "Pages", "Files", "Links"] {
            XCTAssertTrue(labels.contains(chip), "chip \(chip): \(labels)")
        }
        XCTAssertTrue(labels.contains("map.png, Image, Weekend trip"), "a tile reads as name, kind and chat: \(labels)")
        XCTAssertTrue(has(w, "Curate"))
        XCTAssertTrue(has(w, "Today"), "the day heading: \(texts(w))")
        // A SwiftUI Menu reports no label (SidebarDensityTests); it is the only menu button.
        XCTAssertEqual(AccessibilityProbe.nodes(in: w).filter { $0.role == "AXMenuButton" }.count, 1,
                       "the More menu is there once the host lists artifacts")
        XCTAssertEqual(host.paths.count, 1)
        XCTAssertFalse(host.paths[0].contains("missing="), "until the step 3 merge the request carries no missing flag")
    }

    func testMissingFilesAreHiddenUntilShowMissingFilesIsOn() throws {
        host.pages = [page([
            ArtifactsTestSupport.row(["kind": "document", "name": "kept.pdf", "path": "/root/kept.pdf"]),
            ArtifactsTestSupport.row(["kind": "document", "name": "gone.pdf", "path": "/root/gone.pdf", "exists": false,
                                      "message_id": 3]),
        ])]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "kept.pdf") }, "\(texts(w))")
        XCTAssertFalse(has(w, "gone.pdf"), "a file the host no longer has is hidden by default")
        suite.defaults.set(true, forKey: MacArtifactsList.showMissingKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "gone.pdf") }, "\(texts(w))")
        XCTAssertTrue(has(w, "No longer on the host"))
    }

    func testAnEmptyListWithHiddenFilesOffersShowMissingFiles() throws {
        host.pages = [page([ArtifactsTestSupport.row(["kind": "document", "name": "gone.pdf", "path": "/root/gone.pdf",
                                                      "exists": false])])]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "No Artifacts Yet") }, "\(texts(w))")
        XCTAssertTrue(has(w, "Files no longer on your Hermes host are hidden."))
        XCTAssertTrue(AccessibilityProbe.labels(in: w).contains("Show Missing Files"))
    }

    func testAFailedLoadShowsTryAgain() throws {
        host.failure = ArtifactsClient.Failure.malformed
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "Artifacts couldn't load") }, "\(texts(w))")
        XCTAssertTrue(AccessibilityProbe.labels(in: w).contains("Try Again"))
        host.failure = nil
        host.pages = [page([ArtifactsTestSupport.row(["kind": "document", "name": "back.pdf", "path": "/root/back.pdf"])])]
        XCTAssertTrue(AccessibilityProbe.press("Try Again", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "back.pdf") }, "\(texts(w))")
    }

    func testTheSearchTextAndAChipReachTheHost() throws {
        host.pages = [page([ArtifactsTestSupport.row(["kind": "document", "name": "a.pdf", "path": "/root/a.pdf"])])]
        let w = try show(query: " road trip ")
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "a.pdf") }, "\(texts(w))")
        XCTAssertTrue(host.paths[0].contains("q=road%20trip"), host.paths[0])
        XCTAssertTrue(AccessibilityProbe.press("Images", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.count >= 2 }, "\(host.paths)")
        XCTAssertTrue(host.paths[1].contains("kind=images"), host.paths[1])
        XCTAssertTrue(host.paths[1].contains("q=road%20trip"), "the chip keeps the search: \(host.paths[1])")
    }

    func testReachingTheEndReadsTheNextPage() throws {
        host.pages = [
            page([ArtifactsTestSupport.row(["kind": "document", "name": "first.pdf", "path": "/root/first.pdf",
                                            "message_id": 9])], next: 9),
            page([ArtifactsTestSupport.row(["kind": "document", "name": "second.pdf", "path": "/root/second.pdf",
                                            "message_id": 4])]),
        ]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "second.pdf") }, "\(texts(w)) \(host.paths)")
        XCTAssertTrue(has(w, "first.pdf"))
        XCTAssertEqual(host.paths.count, 2, "\(host.paths)")
        XCTAssertTrue(host.paths[1].contains("before=9"), host.paths[1])
    }

    func testAnUnsupportedHostLoadsNothing() throws {
        let w = try show(supported: false)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "Update the Conduit plugin") }, "\(texts(w))")
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(host.paths.isEmpty, "no request while the plugin cannot list: \(host.paths)")
        XCTAssertTrue(AccessibilityProbe.nodes(in: w).filter { $0.role == "AXMenuButton" }.isEmpty, "no More menu without artifacts")
    }
}
