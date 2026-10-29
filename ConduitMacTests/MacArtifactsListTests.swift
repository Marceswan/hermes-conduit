import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ConduitMac

/// The Mac Artifacts list's rules: the loading state machine (the Mac side of upstream's
/// `ArtifactsList` state), what Open does for each kind of item, and the copy actions.
@MainActor
final class MacArtifactsListTests: XCTestCase {
    private let key = ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "")

    private func item(_ fields: [String: Any] = [:]) throws -> ArtifactItem {
        try ArtifactsTestSupport.item(fields)
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
        XCTAssertEqual(state.loadingBefore, 8, "the old read does not clear the cursor of the read that replaced it")
        state.finishNextPage(.page(ArtifactPage(items: [], nextBefore: nil)), request: second)
        XCTAssertNil(state.loadingBefore)
    }

    func testAReloadThatReturnsTheSameCursorReadsItAgain() throws {
        var state = loaded([try item()], next: 5)
        let stale = try XCTUnwrap(state.beginNextPage(current: key))
        let reload = state.beginReload(key)
        XCTAssertNil(state.loadingBefore, "the read in flight is stale: the reload drops its cursor")
        state.finishReload(.page(ArtifactPage(items: [try item()], nextBefore: 5)), key: key, ticket: reload)
        let again = try XCTUnwrap(state.beginNextPage(current: key), "the same cursor 5 is read again for the new list")
        XCTAssertEqual(again.before, 5)
        state.finishNextPage(.cancelled, request: stale)
        XCTAssertEqual(state.loadingBefore, 5, "the stale read does not clear it")
        XCTAssertNil(state.beginNextPage(current: key), "so the cursor is not read twice at once")
        state.finishNextPage(.page(ArtifactPage(items: [], nextBefore: nil)), request: again)
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

    func testAHostThatRepeatsTheCursorEndsTheList() throws {
        var state = loaded([try item()], next: 5)
        let request = try XCTUnwrap(state.beginNextPage(current: key))
        // The cursor that was just read comes back: nothing is older, and a pager waiting on an
        // id that does not change would otherwise show its spinner for ever.
        state.finishNextPage(.page(ArtifactPage(items: [], nextBefore: 5)), request: request)
        XCTAssertNil(state.nextBefore)
        XCTAssertNil(state.beginNextPage(current: key))
        XCTAssertEqual(state.items.count, 1)
    }

    func testAPageTheFilterEmptiedStillPagesOn() throws {
        // Every row of the first page is a file the host no longer has, and the page is read
        // with the missing files hidden: the parse leaves it empty but keeps the cursor.
        let response = ArtifactsTestSupport.response(
            [ArtifactsTestSupport.row(["exists": false, "path": "/root/a.pdf", "kind": "document", "name": "a.pdf"])], next: 5)
        var state = loaded(try ArtifactsClient.parse(response, showMissing: false).items, next: 5)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertEqual(state.nextBefore, 5, "so the pager reads on")
        let request = try XCTUnwrap(state.beginNextPage(current: key))
        state.finishNextPage(.page(ArtifactPage(items: [try item()], nextBefore: nil)), request: request)
        XCTAssertEqual(state.items.map(\.name), ["map.png"])
    }

    // MARK: missing files

    func testALinkIsNeverMissing() throws {
        let link = try item(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                             "name": "Curate", "exists": false])
        XCTAssertTrue(link.exists, "the model says a link has no file to miss (upstream #1068)")
        XCTAssertFalse(try ArtifactsTestSupport.gone("a.pdf", message: 1).exists)
    }

    // MARK: open

    func testOpenPicksTheViewerForEachKind() throws {
        let link = try item(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                             "name": "Curate"])
        XCTAssertEqual(MacArtifactsList.openAction(for: link), .link(URL(string: "https://curate.example/r")!))
        let page = try item(["kind": "page", "name": "chart.html", "path": "/root/chart.html"])
        XCTAssertEqual(MacArtifactsList.openAction(for: page), .page(path: "/root/chart.html"))
        XCTAssertEqual(MacArtifactsList.openAction(for: try item()), .file(path: "/root/out/map.png"))
        XCTAssertEqual(MacArtifactsList.openAction(for: try ArtifactsTestSupport.gone("a.pdf", message: 1)), .missing,
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
/// `artifacts` capability, to change its dashboard or to open a file from a test, so the list's
/// `MacArtifactsSource` is swapped.
@MainActor
final class MacArtifactsListHostedTests: XCTestCase {
    /// The fake plugin: records each request and can hold the ones a test picks.
    @MainActor
    private final class Host {
        var paths: [String] = []
        var pages: [[String: Any]] = []
        var failure: Error?
        var holds: (String) -> Bool = { _ in false }
        var held: [CheckedContinuation<Void, Never>] = []

        func request(_ path: String) async throws -> [String: Any] {
            paths.append(path)
            if holds(path) { await withCheckedContinuation { held.append($0) } }
            if let failure { throw failure }
            guard !pages.isEmpty else { return ArtifactsTestSupport.response([]) }
            return pages.count > 1 ? pages.removeFirst() : pages[0]
        }

        func release() {
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }
    }

    /// What the swapped source answers; a test changes it, then calls `render()` for the view to
    /// read the new `supported` and `dashboard`.
    @MainActor
    private final class Env {
        var supported = true
        var dashboard: UUID?
        var dataURLs: [String: String] = [:]
        var file: GatewayMediaFileResult = .unavailable
        var holdFile = false
        var heldFile: CheckedContinuation<Void, Never>?
        var presented: [URL] = []
        var presentResult = true
        var presentedDataURLs: [String] = []
        var presentDataURLResult = true
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var hosting: NSHostingView<AnyView>?
    private var boostWasOn = false
    private let host = Host()
    private let env = Env()
    private var query = ""

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacArtifactsListHostedTests.\(UUID().uuidString)", isDirectory: true)
        appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)
    }

    override func tearDown() async throws {
        host.release()
        env.heldFile?.resume()
        AccessibilityTreeBoost.set(boostWasOn)
        if let window {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            HostedTestSupport.tearDown(window)
        }
        window = nil
        hosting = nil
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeView() -> AnyView {
        let host = host, env = env
        let source = MacArtifactsSource(
            supported: { _ in env.supported },
            client: { _ in ArtifactsClient(request: { try await host.request($0) }) },
            dashboardID: { _ in env.dashboard },
            reader: { _ in
                MacArtifactsReader(
                    dataURL: { env.dataURLs[$0] },
                    file: { _ in
                        if env.holdFile { await withCheckedContinuation { env.heldFile = $0 } }
                        return env.file
                    })
            },
            present: { download in
                env.presented.append(download.file)
                return env.presentResult
            },
            presentDataURL: { dataURL, _ in
                env.presentedDataURLs.append(dataURL)
                return env.presentDataURLResult
            })
        return AnyView(
            MacArtifactsList(scope: .profile, chatIsOpen: false, query: query, showInChat: { _ in })
                .environment(\.macArtifactsSource, source)
                .environmentObject(appState)
                .defaultAppStorage(suite.defaults)
                .frame(width: 560, height: 640))
    }

    private func show(query: String = "", supported: Bool = true) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        self.query = query
        env.supported = supported
        let w = HostedTestSupport.host(makeView(), size: NSSize(width: 560, height: 640))
        hosting = w.contentView as? NSHostingView<AnyView>
        window = w
        return w
    }

    /// Hands the view the current `Env`, as a change of a published `AppState` value would.
    private func render() {
        hosting?.rootView = makeView()
    }

    private func texts(_ w: NSWindow) -> [String] { AccessibilityProbe.texts(in: w) }

    private func has(_ w: NSWindow, _ needle: String) -> Bool {
        texts(w).contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func press(prefix: String, in w: NSWindow) -> Bool {
        guard let label = AccessibilityProbe.labels(in: w).first(where: { $0.hasPrefix(prefix) }) else { return false }
        return AccessibilityProbe.press(label, in: w)
    }

    private func document(_ name: String, message: Int = 11) -> [String: Any] {
        ArtifactsTestSupport.row(["kind": "document", "name": name, "path": "/root/\(name)", "message_id": message])
    }

    // MARK: states

    func testLoadedListShowsChipsTilesRowsAndLinks() throws {
        host.pages = [ArtifactsTestSupport.response([
            ArtifactsTestSupport.row(),
            document("notes.pdf"),
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
        XCTAssertTrue(host.paths[0].contains("missing=hide"), "Show Missing Files is off by default: \(host.paths[0])")
    }

    func testMissingFilesAreHiddenUntilShowMissingFilesIsOn() throws {
        // An older plugin: it lists the gone file whatever it is asked.
        host.pages = [ArtifactsTestSupport.response([
            document("kept.pdf"),
            ArtifactsTestSupport.row(["kind": "document", "name": "gone.pdf", "path": "/root/gone.pdf", "exists": false,
                                      "message_id": 3]),
        ])]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "kept.pdf") }, "\(texts(w))")
        XCTAssertFalse(has(w, "gone.pdf"), "a file the host no longer has is hidden by default")
        suite.defaults.set(true, forKey: ArtifactsClient.showMissingKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "gone.pdf") }, "\(texts(w))")
        XCTAssertTrue(has(w, "No longer on the host"))
        XCTAssertEqual(host.paths.count, 2, "the toggle reads the list again: \(host.paths)")
        XCTAssertFalse(host.paths[1].contains("missing="), "and asks for everything: \(host.paths[1])")
    }

    func testAnEmptyListWithHiddenFilesOffersShowMissingFiles() throws {
        host.pages = [ArtifactsTestSupport.response([
            ArtifactsTestSupport.row(["kind": "document", "name": "gone.pdf", "path": "/root/gone.pdf", "exists": false])])]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "No Artifacts Yet") }, "\(texts(w))")
        XCTAssertTrue(has(w, "Files no longer on your Hermes host are hidden."))
        XCTAssertTrue(AccessibilityProbe.labels(in: w).contains("Show Missing Files"))
        XCTAssertTrue(AccessibilityProbe.press("Show Missing Files", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "gone.pdf") }, "\(texts(w))")
        XCTAssertTrue(suite.defaults.bool(forKey: ArtifactsClient.showMissingKey))
    }

    func testAFailedLoadShowsTryAgain() throws {
        host.failure = ArtifactsClient.Failure.malformed
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "Artifacts couldn't load") }, "\(texts(w))")
        XCTAssertTrue(AccessibilityProbe.labels(in: w).contains("Try Again"))
        host.failure = nil
        host.pages = [ArtifactsTestSupport.response([document("back.pdf")])]
        XCTAssertTrue(AccessibilityProbe.press("Try Again", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "back.pdf") }, "\(texts(w))")
    }

    func testTheSearchTextAndAChipReachTheHost() throws {
        host.pages = [ArtifactsTestSupport.response([document("a.pdf")])]
        let w = try show(query: " road trip ")
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "a.pdf") }, "\(texts(w))")
        XCTAssertTrue(host.paths[0].contains("q=road%20trip"), host.paths[0])
        XCTAssertTrue(AccessibilityProbe.press("Images", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.count >= 2 }, "\(host.paths)")
        XCTAssertTrue(host.paths[1].contains("kind=images"), host.paths[1])
        XCTAssertTrue(host.paths[1].contains("q=road%20trip"), "the chip keeps the search: \(host.paths[1])")
    }

    func testAnUnsupportedHostLoadsNothingUntilItReports() throws {
        host.pages = [ArtifactsTestSupport.response([document("late.pdf")])]
        let w = try show(supported: false)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "Update the Conduit plugin") }, "\(texts(w))")
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(host.paths.isEmpty, "no request while the plugin cannot list: \(host.paths)")
        XCTAssertTrue(AccessibilityProbe.nodes(in: w).filter { $0.role == "AXMenuButton" }.isEmpty, "no More menu without artifacts")
        // The plugin's report lands after the pane opened (upstream's list would stay here).
        env.supported = true
        render()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "late.pdf") }, "\(texts(w))")
        XCTAssertEqual(host.paths.count, 1)
    }

    // MARK: paging

    func testReachingTheEndReadsTheNextPage() throws {
        host.pages = [
            ArtifactsTestSupport.response([document("first.pdf", message: 9)], next: 9),
            ArtifactsTestSupport.response([document("second.pdf", message: 4)]),
        ]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "second.pdf") }, "\(texts(w)) \(host.paths)")
        XCTAssertTrue(has(w, "first.pdf"))
        XCTAssertEqual(host.paths.count, 2, "\(host.paths)")
        XCTAssertTrue(host.paths[1].contains("before=9"), host.paths[1])
    }

    func testAHostThatRepeatsTheCursorEndsTheListWithoutALoop() throws {
        host.pages = [ArtifactsTestSupport.response([document("only.pdf", message: 9)], next: 9)]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.count == 2 }, "\(host.paths)")
        HostedTestSupport.settle(0.5)
        XCTAssertEqual(host.paths.count, 2, "no third request: \(host.paths)")
        let isSpinner: (String) -> Bool = { $0.contains("Progress") || $0.contains("Busy") }
        XCTAssertFalse(AccessibilityProbe.nodes(in: w).map(\.role).contains(where: isSpinner), "the pager is gone")
        XCTAssertTrue(has(w, "only.pdf"))
    }

    func testThePagerRestartsWhenAReloadReturnsTheSameCursor() throws {
        // The pager's read (before=9) is still out when the chip starts a reload whose first page
        // has the same cursor: the old read is stale, and the list must still read on.
        host.holds = { $0.contains("before=9") && !$0.contains("kind=images") }
        host.pages = [ArtifactsTestSupport.response([document("first.pdf", message: 9)], next: 9)]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.count == 2 }, "\(host.paths)")
        XCTAssertTrue(host.paths[1].contains("before=9"))
        XCTAssertTrue(AccessibilityProbe.press("Images", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.contains { $0.contains("kind=images") && !$0.contains("before=") } },
                      "\(host.paths)")
        host.release()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.contains { $0.contains("kind=images") && $0.contains("before=9") } },
                      "the pager reads the images list on: \(host.paths)")
    }

    // MARK: dashboard

    func testADashboardSwitchDropsTheOldServersRows() throws {
        host.pages = [ArtifactsTestSupport.response([document("first-server.pdf")])]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "first-server.pdf") }, "\(texts(w))")
        // The other server answers slowly: its list is empty, not the first server's.
        host.holds = { _ in true }
        host.pages = [ArtifactsTestSupport.response([document("second-server.pdf")])]
        env.dashboard = UUID()
        render()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.count == 2 }, "\(host.paths)")
        HostedTestSupport.settle(0.3)
        XCTAssertFalse(has(w, "first-server.pdf"), "no row of the old server under the new one: \(texts(w))")
        host.release()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "second-server.pdf") }, "\(texts(w))")
    }

    func testADashboardSwitchCancelsAnOpenInFlight() throws {
        host.pages = [ArtifactsTestSupport.response([document("notes.pdf")])]
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "notes.pdf") }, "\(texts(w))")
        env.holdFile = true
        env.file = .downloaded(try download("notes.pdf"))
        XCTAssertTrue(press(prefix: "notes.pdf", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.env.heldFile != nil }, "the download started")
        env.dashboard = UUID()
        render()
        HostedTestSupport.settle(0.2)
        env.heldFile?.resume()
        env.heldFile = nil
        HostedTestSupport.settle(0.4)
        XCTAssertTrue(env.presented.isEmpty, "a file read for the old server is not shown under the new one")
        XCTAssertNil(window?.attachedSheet, "and the switch does not end in an alert about the old server's file")
    }

    // MARK: open

    private func download(_ name: String) throws -> DashboardDownloadedFile {
        let directory = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        return DashboardDownloadedFile(directory: directory, file: file, mimeType: nil)
    }

    private func dataURL(_ text: String, mime: String = "text/html") -> String {
        "data:\(mime);base64," + Data(text.utf8).base64EncodedString()
    }

    private func alertAppears(over w: NSWindow, saying text: String) -> Bool {
        HostedTestSupport.waitUntil {
            guard let sheet = w.attachedSheet else { return false }
            return AccessibilityProbe.texts(in: sheet).contains { $0.contains(text) }
        }
    }

    func testAPageOpensInTheSheet() throws {
        host.pages = [ArtifactsTestSupport.response([
            ArtifactsTestSupport.row(["kind": "page", "name": "chart.html", "path": "/root/chart.html"])])]
        env.dataURLs["/root/chart.html"] = dataURL("<html><body>hello</body></html>")
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "chart.html") }, "\(texts(w))")
        XCTAssertTrue(press(prefix: "chart.html", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { w.attachedSheet != nil }, "the page opens in a sheet")
        let sheet = try XCTUnwrap(w.attachedSheet)
        func webView(in view: NSView?) -> WKWebView? {
            guard let view else { return nil }
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        XCTAssertTrue(HostedTestSupport.waitUntil { webView(in: sheet.contentView) != nil },
                      "the sheet draws the page in a web view")
        XCTAssertTrue(env.presented.isEmpty, "a page is drawn, not revealed")
    }

    func testAPageThatCannotBeDrawnOpensAsAFile() throws {
        host.pages = [ArtifactsTestSupport.response([
            ArtifactsTestSupport.row(["kind": "page", "name": "big.html", "path": "/root/big.html"])])]
        // Not UTF-8: `HTMLPreviewPage.decodedDocument` refuses it.
        env.dataURLs["/root/big.html"] = "data:text/html;base64," + Data([0xFF, 0xFE, 0xFA]).base64EncodedString()
        let file = try download("big.html")
        env.file = .downloaded(file)
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "big.html") }, "\(texts(w))")
        XCTAssertTrue(press(prefix: "big.html", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.env.presented.isEmpty }, "it is revealed instead")
        XCTAssertEqual(env.presented, [file.file])
        XCTAssertNil(w.attachedSheet)
    }

    func testAFileGoesToThePresenterAndAFileOverTheLimitShowsTheAlert() throws {
        host.pages = [ArtifactsTestSupport.response([document("notes.pdf")])]
        let file = try download("notes.pdf")
        env.file = .downloaded(file)
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "notes.pdf") }, "\(texts(w))")
        XCTAssertTrue(press(prefix: "notes.pdf", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.env.presented.isEmpty })
        XCTAssertEqual(env.presented, [file.file])
        XCTAssertNil(w.attachedSheet, "no alert when the file shows")

        env.file = .tooLarge
        XCTAssertTrue(press(prefix: "notes.pdf", in: w))
        XCTAssertTrue(alertAppears(over: w, saying: "Too large to open on this Mac"),
                      "\(String(describing: w.attachedSheet.map { AccessibilityProbe.texts(in: $0) }))")
    }

    func testAFileThePresenterRefusesFallsBackToItsDataURL() throws {
        host.pages = [ArtifactsTestSupport.response([document("notes.pdf")])]
        env.file = .downloaded(try download("notes.pdf"))
        env.presentResult = false
        env.dataURLs["/root/notes.pdf"] = dataURL("pdf bytes", mime: "application/pdf")
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "notes.pdf") }, "\(texts(w))")
        XCTAssertTrue(press(prefix: "notes.pdf", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.env.presentedDataURLs.isEmpty }, "the data URL is the fallback")
        XCTAssertEqual(env.presentedDataURLs, [dataURL("pdf bytes", mime: "application/pdf")])
        XCTAssertNil(w.attachedSheet)
    }

    func testAFileThatCannotBeReadAtAllSaysSo() throws {
        host.pages = [ArtifactsTestSupport.response([document("notes.pdf")])]
        env.file = .unavailable
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "notes.pdf") }, "\(texts(w))")
        XCTAssertTrue(press(prefix: "notes.pdf", in: w))
        XCTAssertTrue(alertAppears(over: w, saying: "This file is no longer on your Hermes host."),
                      "no silent end: \(String(describing: w.attachedSheet.map { AccessibilityProbe.texts(in: $0) }))")
        XCTAssertTrue(env.presented.isEmpty)
    }
}
