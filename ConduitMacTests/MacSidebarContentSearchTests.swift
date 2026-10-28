import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// A requester that records each path and answers per path, at once or when the test releases it.
/// No network: `SessionContentSearchModel.Context.request` is the seam the app wires to the dashboard bridge.
@MainActor
private final class FakeSearchRequester {
    var paths: [String] = []
    var responses: [String: Result<[String: Any], Error>] = [:]
    var fallback: Result<[String: Any], Error> = .success(["results": []])
    /// While true, every answer waits for `releaseAll()` (a request that is still running).
    var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func request(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        if holding { await withCheckedContinuation { waiting.append($0) } }
        return try (responses[path] ?? fallback).get()
    }

    func releaseAll() {
        holding = false
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }
}

/// D30: the sidebar search field also finds chats by their message text. The rules and the wiring to
/// `SessionContentSearchModel`; the view is in `MacSidebarContentSearchHostedTests`.
@MainActor
final class MacSidebarContentSearchTests: XCTestCase {
    private let scope = NSObject()
    private let languages = ["de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Fixtures

    private func context(_ stub: FakeSearchRequester, profile: String = "default") -> SessionContentSearchModel.Context {
        SessionContentSearchModel.Context(scope: scope, profile: profile) { path in try await stub.request(path) }
    }

    private func model() -> SessionContentSearchModel {
        // A support of its own: the shared "no route" memory must not carry from one test to the next.
        SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
    }

    private func path(_ query: String, profile: String = "default") -> String {
        SessionContentSearch.path(query: query, profile: profile)
    }

    private func result(_ id: String, snippet: String = "", title: String? = nil, root: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["session_id": id, "snippet": snippet, "role": "user", "source": "cli", "session_started": 1_800_000_000.0]
        if let title { row["title"] = title }
        if let root { row["lineage_root"] = root }
        return row
    }

    private func session(_ id: String, title: String? = nil, stored: String? = nil, root: String? = nil,
                         archived: Bool = false) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: stored, alternateIds: [], title: title ?? id, model: "Hermes", updatedLabel: "",
            profile: "default", source: .chat, isActive: false, isArchived: archived, lineageRootId: root
        )
    }

    private func hits(_ rows: [[String: Any]], query: String = "recycling") -> [SessionContentSearchHit] {
        SessionContentSearch.hits(from: ["results": rows], query: query) ?? []
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Query

    func testTheSearchFieldTextIsTheQuery() {
        XCTAssertEqual(MacSidebarContentSearchRules.query(searchText: "recycling", showingProjects: false), "recycling")
    }

    func testTheProjectsViewHasNoQuery() {
        XCTAssertEqual(MacSidebarContentSearchRules.query(searchText: "recycling", showingProjects: true), "")
    }

    // MARK: Wiring to the model

    func testTypingAsksHermesForTheWordsOnTheActiveProfile() async {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling", profile: "work")] = .success(["results": [result("s1", snippet: "the >>>recycling<<< bins")]])
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: " recycling ", showingProjects: false,
                                            context: context(stub, profile: "work"))
        XCTAssertTrue(model.isSearching, "searching from the first keystroke")
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling", profile: "work")])
        XCTAssertEqual(model.hits.map(\.sessionID), ["s1"])
        XCTAssertFalse(model.isSearching)
    }

    func testAShortQueryAsksNothing() async {
        let stub = FakeSearchRequester()
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: "r", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [])
        XCTAssertFalse(model.isSearching)
    }

    func testTheProjectsViewAsksNothingAndDropsEarlierHits() async {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("s1")]])
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits.count, 1)

        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: true, context: context(stub))
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits, [])
        XCTAssertNil(model.resultsQuery)
        XCTAssertEqual(stub.paths, [path("recycling")], "nothing new was sent")
    }

    func testNoConnectionAsksNothing() async {
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: false, context: nil)
        await model.waitForPendingSearch()
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.hits, [])
    }

    func testAHermesWithoutTheRouteShowsNoSectionAndNoError() async {
        let stub = FakeSearchRequester()
        stub.fallback = .failure(DashboardTicketBridgeError.http(status: 404, detail: "Not Found"))
        let support = SessionContentSearchSupport()
        let model = SessionContentSearchModel(support: support, debounce: .zero)
        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()
        let rows = MacSidebarContentSearchRules.rows(
            model: model, searchText: "recycling", showingProjects: false, listed: [], known: [], allowed: nil
        )
        XCTAssertFalse(MacSidebarContentSearchRules.showsSection(rows: rows, isSearching: model.isSearching))
        XCTAssertTrue(support.isUnsupported(scope), "remembered for the connection")

        // The next words are not asked of that Hermes again.
        MacSidebarContentSearchRules.follow(model, searchText: "compost", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling")])
    }

    func testOtherFailuresShowNothingNew() async {
        let stub = FakeSearchRequester()
        stub.fallback = .failure(DashboardTicketBridgeError.http(status: 500, detail: "Search failed"))
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()
        let rows = MacSidebarContentSearchRules.rows(
            model: model, searchText: "recycling", showingProjects: false, listed: [], known: [], allowed: nil
        )
        XCTAssertEqual(rows, [])
        XCTAssertFalse(MacSidebarContentSearchRules.showsSection(rows: rows, isSearching: model.isSearching))
    }

    // MARK: Rows

    func testRowsAreTheMessageMatchesTheListDoesNotShow() async {
        let stub = FakeSearchRequester()
        let titled = session("s1", title: "Next Recycling Pickup Dates")
        let kitchen = session("s2", title: "Kitchen chat")
        stub.responses[path("recycling")] = .success(["results": [
            result("s1", snippet: "the >>>recycling<<< day"),
            result("s2", snippet: "bins and >>>recycling<<<", title: "Kitchen"),
            result("far", snippet: "old >>>recycling<<< note", title: "From last year"),
        ]])
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()

        let rows = MacSidebarContentSearchRules.rows(
            model: model, searchText: "recycling", showingProjects: false,
            listed: [titled], known: [titled, kitchen], allowed: nil
        )
        // s1 is a title match on screen already. s2 is a listed chat (its own title wins). "far" is older than
        // the list, so Hermes' id and title open and name it.
        XCTAssertEqual(rows.map(\.openID), ["s2", "far"])
        XCTAssertEqual(rows.map(\.title), ["Kitchen chat", "From last year"])
        XCTAssertNotNil(rows.first?.session)
        XCTAssertNil(rows.last?.session)
        XCTAssertTrue(MacSidebarContentSearchRules.showsSection(rows: rows, isSearching: false))
    }

    /// The model drops the old hits when the query changes, but a redraw can come first: rows for another
    /// query never sit under the new words.
    func testRowsWaitForTheCurrentQuery() async {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("s1")]])
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()

        func rows(_ text: String, projects: Bool = false) -> [SessionContentSearchRow] {
            MacSidebarContentSearchRules.rows(model: model, searchText: text, showingProjects: projects,
                                              listed: [], known: [], allowed: nil)
        }
        XCTAssertEqual(rows("recycling").count, 1)
        XCTAssertEqual(rows("  recycling ").count, 1, "the trimmed words are the same query")
        XCTAssertEqual(rows("recyclingx"), [])
        XCTAssertEqual(rows(""), [])
        XCTAssertEqual(rows("recycling", projects: true), [])
    }

    func testRowsFollowTheActiveFilter() async {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("s1"), result("s2"), result("far")]])
        let model = model()
        MacSidebarContentSearchRules.follow(model, searchText: "recycling", showingProjects: false, context: context(stub))
        await model.waitForPendingSearch()
        let s1 = session("s1"), s2 = session("s2")

        // A filter (a source or a status) keeps only the chats it lists.
        let filtered = MacSidebarContentSearchRules.rows(
            model: model, searchText: "recycling", showingProjects: false, listed: [], known: [s1, s2], allowed: [s2]
        )
        XCTAssertEqual(filtered.map(\.openID), ["s2"])

        // No filter: a chat the list does not hold is still found.
        let all = MacSidebarContentSearchRules.rows(
            model: model, searchText: "recycling", showingProjects: false, listed: [], known: [s1, s2], allowed: nil
        )
        XCTAssertEqual(all.map(\.openID), ["s1", "s2", "far"])
    }

    func testTheSectionShowsWhileSearchingAndWhenItHasRows() {
        XCTAssertFalse(MacSidebarContentSearchRules.showsSection(rows: [], isSearching: false))
        XCTAssertTrue(MacSidebarContentSearchRules.showsSection(rows: [], isSearching: true))
        let row = SessionContentSearchRow(hit: hits([result("s1")])[0], session: nil)
        XCTAssertTrue(MacSidebarContentSearchRules.showsSection(rows: [row], isSearching: false))
    }

    // MARK: Opening

    func testAListedChatOpensAsASidebarRowDoes() throws {
        let listed = session("s2", title: "Kitchen chat")
        let row = SessionContentSearchRow(hit: hits([result("s2")])[0], session: listed)
        XCTAssertEqual(MacSidebarContentSearchRules.open(row), .listed(listed))
    }

    func testAChatOlderThanTheListOpensThroughTheLinkRoute() throws {
        let row = SessionContentSearchRow(hit: hits([result("far")])[0], session: nil)
        XCTAssertEqual(MacSidebarContentSearchRules.open(row), .link(id: "far"))
    }

    /// `AppState.openListedSession` is the call a sidebar row makes; it ends in `requestOpenSession`, which
    /// brings the main pane back to chat (D6) with this notification.
    func testOpeningAListedChatReturnsThePaneToChat() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSidebarContentSearchTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)

        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .macSessionOpenRequested, object: nil, queue: nil) { _ in
            posted += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        MacSidebarContentSearchRules.perform(.listed(session("s2")), on: appState)
        XCTAssertEqual(posted, 1)
    }

    // MARK: Text

    func testTitleAndSnippetAreCleanedAndNothingElse() {
        // A right-to-left override and a zero-width space reorder or hide text.
        let hit = hits([result("far", snippet: "a\u{202E}b >>>cat<<<\u{200B}\n   sat", title: "Plan\u{202E}\u{0007} B")])[0]
        let row = SessionContentSearchRow(hit: hit, session: nil)
        XCTAssertEqual(MacSidebarContentSearchText.title(row), "Plan B")
        let snippet = MacSidebarContentSearchText.snippet(hit.snippet)
        XCTAssertEqual(snippet.plainText, "ab cat sat")
        XCTAssertEqual(snippet.runs.filter(\.isMatch).map(\.text), ["cat"])
    }

    func testAnEmptyTitleIsUntitled() {
        let hit = hits([result("far", title: "\u{200B}")])[0]
        XCTAssertEqual(MacSidebarContentSearchText.title(SessionContentSearchRow(hit: hit, session: nil)),
                       AppLocalization.string("Untitled conversation"))
    }

    func testTheSpaceBetweenTwoMatchesStays() {
        let snippet = SessionSearchSnippet.parse(">>>cat<<< >>>dog<<<", query: "")
        XCTAssertEqual(MacSidebarContentSearchText.snippet(snippet).plainText, "cat dog")
    }

    /// Message text can hold Markdown and links. Neither is parsed: the characters stay as they are, and the
    /// drawn string carries no link attribute.
    func testSnippetStaysPlainText() {
        let raw = "see **bold** [here](https://example.com/x) https://example.com/y >>>cat<<<"
        let snippet = MacSidebarContentSearchText.snippet(SessionSearchSnippet.parse(raw, query: ""))
        XCTAssertEqual(snippet.plainText, "see **bold** [here](https://example.com/x) https://example.com/y cat")
        let drawn = MacSidebarContentSearchText.attributed(snippet)
        XCTAssertEqual(String(drawn.characters), snippet.plainText)
        XCTAssertTrue(drawn.runs.allSatisfy { $0.link == nil })
    }

    func testMatchedWordsAreMarkedInTheDrawnSnippet() {
        let snippet = SessionSearchSnippet.parse("the >>>cat<<< sat", query: "")
        let drawn = MacSidebarContentSearchText.attributed(snippet)
        let marked = drawn.runs.filter { $0.foregroundColor != nil }.map { String(drawn[$0.range].characters) }
        XCTAssertEqual(marked, ["cat"])
    }

    func testVoiceOverReadsTheTitleThenTheSnippet() {
        let hit = hits([result("far", snippet: "old >>>recycling<<< note", title: "From last year")])[0]
        let row = SessionContentSearchRow(hit: hit, session: nil)
        XCTAssertEqual(MacSidebarContentSearchText.accessibilityLabel(row), "From last year")
        XCTAssertEqual(MacSidebarContentSearchText.accessibilityValue(hit.snippet), "old recycling note")
    }

    // MARK: Source pins

    /// The Mac file draws text only through `Text(verbatim:)` and the attributed snippet: no
    /// `LocalizedStringKey` (a literal `Text("...")` parses Markdown and builds links), no Markdown parser.
    func testTheViewDrawsPlainTextOnly() throws {
        let text = try source("ConduitMac/Views/MacSidebarContentSearch.swift")
        for banned in ["LocalizedStringKey", "markdown", "Markdown"] {
            // The words may appear in the comments that say why; code lines must not hold them.
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            XCTAssertFalse(code.contains { $0.contains(banned) }, "code line holds \(banned)")
        }
        let textCalls = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains("Text(") }
        XCTAssertFalse(textCalls.isEmpty)
        for line in textCalls {
            XCTAssertTrue(line.contains("Text(verbatim:") || line.contains("Text(MacSidebarContentSearchText.attributed("),
                          "Text call that is neither verbatim nor the attributed snippet: \(line)")
        }
    }

    /// The one upstream edit: one `#if os(macOS) // MAC: search message text (D30)` region in the sessions
    /// list, closed with `#endif // MAC:` and no `#else`.
    func testSidebarViewHoldsOneGatedRegion() throws {
        let lines = try source("Conduit/Views/SidebarView.swift").components(separatedBy: "\n")
        let opens = lines.indices.filter { lines[$0].contains("search message text (D30)") }
        XCTAssertEqual(opens.count, 1)
        guard let open = opens.first else { return }
        XCTAssertEqual(lines[open].trimmingCharacters(in: .whitespaces), "#if os(macOS) // MAC: search message text (D30)")
        guard let close = lines[open...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#endif") }) else {
            return XCTFail("the region is not closed")
        }
        XCTAssertEqual(lines[close].trimmingCharacters(in: .whitespaces), "#endif // MAC:")
        let region = lines[open...close]
        XCTAssertFalse(region.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#else") })
        XCTAssertEqual(region.filter { $0.contains("MacSidebarContentSearch(") }.count, 1)
        XCTAssertLessThanOrEqual(region.count, 10, "the upstream edit stays small")
        // After the Recent section, still inside the list: the title matches come first.
        let recent = try XCTUnwrap(lines.firstIndex { $0.contains("Section(sections.pinned.isEmpty ?") })
        XCTAssertGreaterThan(open, recent)
    }

    // MARK: Strings

    /// The keys are upstream's (V2 Chats), not new: every language, translated.
    func testTheKeysAreInTheCatalogInEveryLanguage() throws {
        let url = repoRoot.appendingPathComponent("Conduit/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(object?["strings"] as? [String: [String: Any]])
        for key in ["In messages", "Searching messages", "Untitled conversation"] {
            let localizations = try XCTUnwrap(strings[key]?["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), Set(languages), key)
            for (language, body) in localizations {
                let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any]
                XCTAssertEqual(unit?["state"] as? String, "translated", "\(key) [\(language)]")
                XCTAssertFalse((unit?["value"] as? String ?? "").isEmpty, "\(key) [\(language)]")
            }
        }
        // The source file asks for these three and no other key.
        let text = try source("ConduitMac/Views/MacSidebarContentSearch.swift")
        let asked = text.components(separatedBy: "AppLocalization.string(\"").dropFirst()
            .compactMap { $0.components(separatedBy: "\"").first }
        XCTAssertEqual(Set(asked), ["In messages", "Searching messages", "Untitled conversation"])
    }
}

// MARK: - The view, in a real window

@MainActor
private final class QueryBox: ObservableObject {
    @Published var text: String
    init(_ text: String) { self.text = text }
}

/// A list shaped like the sessions list: some title-match rows, then the Mac section.
private struct SectionHarness: View {
    @ObservedObject var box: QueryBox
    let model: SessionContentSearchModel
    let context: SessionContentSearchModel.Context?
    var showingProjects = false
    var rowsAbove = 1
    var listed: [SessionSummary] = []
    var allowed: [SessionSummary]?

    var body: some View {
        List {
            ForEach(0..<rowsAbove, id: \.self) { Text(verbatim: "title match \($0)") }
            MacSidebarContentSearch(
                searchText: box.text, showingProjects: showingProjects, listed: listed, allowed: allowed,
                model: model, context: { context }
            )
        }
        .frame(width: 340, height: 600)
    }
}

@MainActor
final class MacSidebarContentSearchHostedTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false
    private let scope = NSObject()

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSidebarContentSearchHostedTests.\(UUID().uuidString)", isDirectory: true)
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

    private func result(_ id: String, snippet: String, title: String) -> [String: Any] {
        ["session_id": id, "snippet": snippet, "title": title, "role": "user", "source": "cli", "session_started": 1_800_000_000.0]
    }

    private func path(_ query: String) -> String { SessionContentSearch.path(query: query, profile: "default") }

    private func host(_ box: QueryBox, stub: FakeSearchRequester, model: SessionContentSearchModel? = nil,
                      rowsAbove: Int = 1, showingProjects: Bool = false,
                      configure: (inout SectionHarness) -> Void = { _ in }) -> SessionContentSearchModel {
        let model = model ?? SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        let context = SessionContentSearchModel.Context(scope: scope, profile: "default") { path in try await stub.request(path) }
        var harness = SectionHarness(box: box, model: model, context: context, showingProjects: showingProjects, rowsAbove: rowsAbove)
        configure(&harness)
        window = HostedTestSupport.host(harness.environmentObject(appState), size: NSSize(width: 340, height: 600))
        return model
    }

    /// One accessibility element of a list row.
    private struct Entry {
        let row: Int
        let role: String?
        let label: String?
        let value: String?
    }

    /// The accessibility labels and values of the list's rows, top to bottom. The rows of a SwiftUI List on
    /// macOS are table cells that the window's accessibility tree does not list, so the table is asked row
    /// by row (a row the table has not drawn is made for the ask).
    private func entries() throws -> [Entry] {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        HostedTestSupport.settle(0.4)
        func table(in view: NSView) -> NSTableView? {
            if let found = view as? NSTableView { return found }
            for sub in view.subviews { if let found = table(in: sub) { return found } }
            return nil
        }
        let table = try XCTUnwrap(table(in: try XCTUnwrap(window?.contentView)), "no table view")
        var result: [Entry] = []
        for row in 0..<table.numberOfRows {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else { continue }
            var seen = Set<ObjectIdentifier>()
            func visit(_ object: NSObject, depth: Int) {
                guard depth < 14, seen.insert(ObjectIdentifier(object)).inserted else { return }
                let role: String? = object.axValue("accessibilityRole")
                let label: String? = object.axValue("accessibilityLabel")
                let raw: Any? = object.axValue("accessibilityValue")
                let value = raw as? String
                if label != nil || value != nil { result.append(Entry(row: row, role: role, label: label, value: value)) }
                let kids: [Any]? = object.axValue("accessibilityChildren")
                for kid in kids ?? [] { if let child = kid as? NSObject { visit(child, depth: depth + 1) } }
                if let view = object as? NSView { for sub in view.subviews { visit(sub, depth: depth + 1) } }
            }
            visit(rowView, depth: 0)
        }
        return result
    }

    /// What a screen reader can read in the list: every label and value.
    private func texts() throws -> [String] {
        try entries().flatMap { [$0.label, $0.value].compactMap { $0 } }
    }

    // MARK: Section

    func testTheSectionShowsTheTitleAndTheSnippetUnderTheHeader() throws {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [
            result("far-1", snippet: "old >>>recycling<<< note", title: "From last year"),
            result("far-2", snippet: "second >>>recycling<<< hit", title: "Kitchen"),
        ]])
        let box = QueryBox("recycling")
        let model = host(box, stub: stub)
        XCTAssertTrue(HostedTestSupport.waitUntil { model.hits.count == 2 })
        HostedTestSupport.settle(0.2)

        let found = try entries()
        let all = found.map { "\($0.row) \($0.role ?? "-")|\($0.label ?? "-")|\($0.value ?? "-")" }.joined(separator: "\n")
        let header = try XCTUnwrap(found.first { $0.label == AppLocalization.string("In messages") || $0.value == AppLocalization.string("In messages") },
                                   "header: \(all)")
        // VoiceOver: the title is the label and the snippet is the value of the same element.
        let first = try XCTUnwrap(found.first { $0.label == "From last year" }, "row: \(all)")
        XCTAssertEqual(first.value, "old recycling note")
        let second = try XCTUnwrap(found.first { $0.label == "Kitchen" }, "row: \(all)")
        XCTAssertEqual(second.value, "second recycling hit")
        // Under the title match and the header, in Hermes' order.
        let match = try XCTUnwrap(found.first { $0.label == "title match 0" || $0.value == "title match 0" }, "title row: \(all)")
        XCTAssertLessThan(match.row, header.row)
        XCTAssertLessThan(header.row, first.row)
        XCTAssertLessThan(first.row, second.row)
    }

    func testNoSectionForABlankOrShortQuery() throws {
        for text in ["", "r", "   "] {
            let stub = FakeSearchRequester()
            let model = host(QueryBox(text), stub: stub)
            HostedTestSupport.settle(0.3)
            XCTAssertEqual(stub.paths, [], text)
            XCTAssertFalse(model.isSearching, text)
            XCTAssertFalse(try texts().contains(AppLocalization.string("In messages")), text)
            if let window { HostedTestSupport.tearDown(window) }
            window = nil
        }
    }

    func testNoSectionInTheProjectsView() throws {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("far-1", snippet: ">>>recycling<<<", title: "From last year")]])
        _ = host(QueryBox("recycling"), stub: stub, showingProjects: true)
        HostedTestSupport.settle(0.4)
        XCTAssertEqual(stub.paths, [])
        XCTAssertFalse(try texts().contains(AppLocalization.string("In messages")))
    }

    func testASearchingStateShowsWhileTheRequestRuns() throws {
        let stub = FakeSearchRequester()
        stub.holding = true
        stub.responses[path("recycling")] = .success(["results": [result("far-1", snippet: ">>>recycling<<< x", title: "From last year")]])
        let model = host(QueryBox("recycling"), stub: stub)
        XCTAssertTrue(HostedTestSupport.waitUntil { !stub.paths.isEmpty })
        XCTAssertTrue(model.isSearching)
        let during = try texts()
        XCTAssertTrue(during.contains(AppLocalization.string("In messages")), "\(during)")
        XCTAssertTrue(during.contains(AppLocalization.string("Searching messages")), "\(during)")
        XCTAssertFalse(during.contains("From last year"))

        stub.releaseAll()
        XCTAssertTrue(HostedTestSupport.waitUntil { !model.isSearching })
        let after = try texts()
        XCTAssertFalse(after.contains(AppLocalization.string("Searching messages")), "\(after)")
        XCTAssertTrue(after.contains(AppLocalization.string("In messages")))
    }

    func testAHermesWithoutTheRouteShowsNothingAtAll() throws {
        let stub = FakeSearchRequester()
        stub.fallback = .failure(DashboardTicketBridgeError.http(status: 404, detail: "Not Found"))
        let model = host(QueryBox("recycling"), stub: stub)
        XCTAssertTrue(HostedTestSupport.waitUntil { !stub.paths.isEmpty && !model.isSearching })
        HostedTestSupport.settle(0.3)
        let all = try texts()
        XCTAssertFalse(all.contains(AppLocalization.string("In messages")), "\(all)")
        XCTAssertFalse(all.contains(AppLocalization.string("Searching messages")), "\(all)")
        XCTAssertNil(appState.errorMessage)
    }

    func testAFailureShowsNothingNew() throws {
        let stub = FakeSearchRequester()
        stub.fallback = .failure(DashboardTicketBridgeError.http(status: 500, detail: "Search failed"))
        let model = host(QueryBox("recycling"), stub: stub)
        XCTAssertTrue(HostedTestSupport.waitUntil { !stub.paths.isEmpty && !model.isSearching })
        HostedTestSupport.settle(0.3)
        XCTAssertFalse(try texts().contains(AppLocalization.string("In messages")))
        XCTAssertNil(appState.errorMessage)
    }

    func testTypingStartsASearchAndClearingTheFieldEndsIt() throws {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("far-1", snippet: "old >>>recycling<<<", title: "From last year")]])
        let box = QueryBox("")
        let model = host(box, stub: stub)
        HostedTestSupport.settle(0.2)
        XCTAssertEqual(stub.paths, [])

        box.text = "recycling"
        XCTAssertTrue(HostedTestSupport.waitUntil { model.hits.count == 1 })
        XCTAssertEqual(stub.paths, [path("recycling")])
        XCTAssertTrue(try texts().contains(AppLocalization.string("In messages")))

        box.text = ""
        XCTAssertTrue(HostedTestSupport.waitUntil { model.hits.isEmpty })
        XCTAssertFalse(try texts().contains(AppLocalization.string("In messages")))
    }

    /// A list that holds more title matches than the window shows: the section sits below the fold. A
    /// list builds only the rows it draws, so a search that waited for the section to be drawn would not
    /// start. It starts from the list, not from the rows.
    func testTheSearchStartsWhileTheSectionIsBelowTheFold() {
        let stub = FakeSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("far-1", snippet: ">>>recycling<<<", title: "From last year")]])
        let model = host(QueryBox("recycling"), stub: stub, rowsAbove: 300)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 5) { model.hits.count == 1 }, "paths: \(stub.paths)")
        XCTAssertEqual(stub.paths, [path("recycling")])
    }
}
