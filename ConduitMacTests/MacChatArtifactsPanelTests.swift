import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// D33: the open chat's artifacts as a folder tree beside the chat. The tree, the panel's loading
/// rules and its store, the toolbar and menu wiring, and the hosted panel.
@MainActor
final class MacArtifactTreeTests: XCTestCase {
    private func file(_ path: String, name: String? = nil, exists: Bool = true) throws -> ArtifactItem {
        try XCTUnwrap(ArtifactItem(ArtifactsTestSupport.row([
            "kind": "document", "name": name ?? (path as NSString).lastPathComponent, "path": path, "exists": exists,
        ])))
    }

    private func link(_ url: String, name: String) throws -> ArtifactItem {
        try XCTUnwrap(ArtifactItem(ArtifactsTestSupport.row([
            "kind": "link", "source": "link", "name": name, "url": url, "path": NSNull(),
        ])))
    }

    private func names(_ rows: [MacArtifactTree.Row]) -> [String] {
        rows.map { String(repeating: "  ", count: $0.depth) + $0.name }
    }

    func testTheRootIsTheDeepestSharedFolderAndFoldersComeBeforeFiles() throws {
        let tree = MacArtifactTree(items: [
            try file("/home/marc/Documents/Hermes/sweep/task-manifest.json"),
            try file("/home/marc/Documents/Hermes/sweep/UI01/worker-contract.md"),
            try file("/home/marc/Documents/Hermes/sweep/design-brief.md"),
        ])
        XCTAssertEqual(tree.root?.path, "/home/marc/Documents/Hermes/sweep")
        XCTAssertEqual(names(tree.rows(collapsed: [])), [
            "sweep",
            "  UI01",
            "    worker-contract.md",
            "  design-brief.md",
            "  task-manifest.json",
        ])
        XCTAssertEqual(tree.count, 3)
    }

    func testAFolderThatHoldsOnlyOneFolderSharesItsRow() throws {
        let tree = MacArtifactTree(items: [
            try file("/root/out/site/assets/css/app.css"),
            try file("/root/out/notes.md"),
        ])
        XCTAssertEqual(names(tree.rows(collapsed: [])), [
            "out",
            "  site/assets/css",
            "    app.css",
            "  notes.md",
        ])
        let rows = tree.rows(collapsed: [])
        XCTAssertEqual(rows[1].kind, .folder(path: "/root/out/site/assets/css", isExpanded: true),
                       "the merged row is keyed by its deepest folder")
    }

    func testOneFileListsUnderItsOwnFolder() throws {
        let tree = MacArtifactTree(items: [try file("/tmp/report.pdf")])
        XCTAssertEqual(names(tree.rows(collapsed: [])), ["tmp", "  report.pdf"])
    }

    func testFilesWithNoSharedFolderListUnderSlash() throws {
        let tree = MacArtifactTree(items: [try file("/tmp/a.txt"), try file("/home/b.txt")])
        XCTAssertEqual(names(tree.rows(collapsed: [])), ["/", "  home", "    b.txt", "  tmp", "    a.txt"])
        XCTAssertEqual(tree.rows(collapsed: [])[1].kind, .folder(path: "/home", isExpanded: true))
    }

    func testRelativePathsShareFoldersToo() throws {
        let tree = MacArtifactTree(items: [try file("out/a.png"), try file("out/b.png")])
        XCTAssertEqual(tree.root?.path, "out")
        XCTAssertEqual(names(tree.rows(collapsed: [])), ["out", "  a.png", "  b.png"])
        let mixed = MacArtifactTree(items: [try file("out/a.png"), try file("/out/b.png")])
        XCTAssertEqual(mixed.root?.path, "", "an absolute and a relative path share no folder")
    }

    func testNamesSortLikeFinder() throws {
        let tree = MacArtifactTree(items: [try file("/r/f10.md"), try file("/r/f9.md"), try file("/r/F1.md")])
        XCTAssertEqual(names(tree.rows(collapsed: [])), ["r", "  F1.md", "  f9.md", "  f10.md"])
    }

    func testLinksGoInTheirOwnGroupInHostOrder() throws {
        let tree = MacArtifactTree(items: [
            try link("https://b.example/x", name: "Newer"),
            try file("/root/a.md"),
            try link("https://a.example/y", name: "Older"),
        ])
        let rows = tree.rows(collapsed: [])
        XCTAssertEqual(names(rows), ["root", "  a.md", "Links", "  Newer", "  Older"])
        XCTAssertEqual(rows[2].kind, .links(isExpanded: true))
        XCTAssertEqual(tree.count, 3)
        let linksOnly = MacArtifactTree(items: [try link("https://b.example/x", name: "Only")])
        XCTAssertNil(linksOnly.root)
        XCTAssertEqual(names(linksOnly.rows(collapsed: [])), ["Links", "  Only"])
        XCTAssertTrue(MacArtifactTree(items: []).rows(collapsed: []).isEmpty)
    }

    func testACollapsedFolderOrLinksGroupHidesWhatIsUnderIt() throws {
        let tree = MacArtifactTree(items: [
            try file("/r/sub/deep.md"), try file("/r/top.md"), try link("https://a.example", name: "Site"),
        ])
        XCTAssertEqual(names(tree.rows(collapsed: ["/r/sub"])), ["r", "  sub", "  top.md", "Links", "  Site"])
        XCTAssertEqual(tree.rows(collapsed: ["/r/sub"])[1].kind, .folder(path: "/r/sub", isExpanded: false))
        XCTAssertEqual(names(tree.rows(collapsed: ["/r"])), ["r", "Links", "  Site"])
        XCTAssertEqual(names(tree.rows(collapsed: [MacArtifactTree.linksKey])), ["r", "  sub", "    deep.md", "  top.md", "Links"])
    }

    func testRowIDsAreUniqueAcrossFoldersFilesAndLinks() throws {
        let tree = MacArtifactTree(items: [
            try file("/r/a/x.md"), try file("/r/b/x.md"), try link("https://a.example", name: "a"),
        ])
        let ids = tree.rows(collapsed: []).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
    }
}

@MainActor
final class MacChatArtifactsPanelStateTests: XCTestCase {
    private func key(_ ids: [String], dashboard: UUID? = nil, showMissing: Bool = false) -> MacChatArtifactsPanelKey {
        MacChatArtifactsPanelKey(dashboard: dashboard, profile: "default", sessionIDs: ids.sorted(), showMissing: showMissing)
    }

    private func items(_ count: Int) -> [ArtifactItem] {
        (0..<count).compactMap {
            ArtifactItem(ArtifactsTestSupport.row(["name": "f\($0).md", "path": "/r/f\($0).md", "message_id": $0]))
        }
    }

    func testALoadedChatShowsItsRowsCountAndButton() {
        var state = MacChatArtifactsPanelState()
        let chat = key(["s1"])
        XCTAssertFalse(state.showsButton(for: chat))
        let ticket = state.beginReload()
        XCTAssertNil(state.count(for: chat))
        state.finishReload(.items(items(2), truncated: false), key: chat, ticket: ticket)
        XCTAssertEqual(state.rows(for: chat).count, 2)
        XCTAssertEqual(state.count(for: chat), 2)
        XCTAssertTrue(state.showsButton(for: chat))
        XCTAssertFalse(state.isLoading)
    }

    func testAChatWithNoArtifactsShowsNoButton() {
        var state = MacChatArtifactsPanelState()
        let chat = key(["s1"])
        state.finishReload(.items([], truncated: false), key: chat, ticket: state.beginReload())
        XCTAssertFalse(state.showsButton(for: chat))
        XCTAssertEqual(state.count(for: chat), 0)
        XCTAssertFalse(state.showsButton(for: nil))
    }

    func testAnotherChatNeverShowsTheOldRowsButKeepsTheButtonWhileItLoads() {
        var state = MacChatArtifactsPanelState()
        let first = key(["s1"]), second = key(["s2"])
        state.finishReload(.items(items(3), truncated: false), key: first, ticket: state.beginReload())
        let ticket = state.beginReload()
        XCTAssertTrue(state.rows(for: second).isEmpty, "never another chat's rows")
        XCTAssertNil(state.count(for: second))
        XCTAssertTrue(state.showsButton(for: second), "the button stays while the next chat loads")
        state.finishReload(.items([], truncated: false), key: second, ticket: ticket)
        XCTAssertFalse(state.showsButton(for: second), "and goes once it has none")
    }

    func testAnotherServersChatDropsTheButtonAtOnce() {
        var state = MacChatArtifactsPanelState()
        state.finishReload(.items(items(1), truncated: false), key: key(["s1"]), ticket: state.beginReload())
        _ = state.beginReload()
        XCTAssertFalse(state.showsButton(for: key(["s1"], dashboard: UUID())))
    }

    func testTheSameChatKeepsItsRowsWhileItIsReadAgain() {
        var state = MacChatArtifactsPanelState()
        let runtime = key(["rt"])
        state.finishReload(.items(items(2), truncated: false), key: runtime, ticket: state.beginReload())
        // The resume recorded the durable id: one more id, the same chat.
        let both = key(["rt", "durable"])
        _ = state.beginReload()
        XCTAssertEqual(state.rows(for: both).count, 2)
        XCTAssertEqual(state.count(for: both), 2)
        let missing = key(["rt"], showMissing: true)
        XCTAssertEqual(state.rows(for: missing).count, 2, "the missing-files setting is the same chat too")
    }

    func testAnOlderReadNeverOverwritesANewerOne() {
        var state = MacChatArtifactsPanelState()
        let first = key(["s1"]), second = key(["s2"])
        let old = state.beginReload()
        let new = state.beginReload()
        state.finishReload(.items(items(1), truncated: false), key: second, ticket: new)
        state.finishReload(.items(items(5), truncated: false), key: first, ticket: old)
        XCTAssertEqual(state.loadedKey, second)
        XCTAssertEqual(state.items.count, 1)
    }

    func testAFailedRefreshKeepsTheListAndAFailedFirstReadHidesTheButton() {
        var state = MacChatArtifactsPanelState()
        let chat = key(["s1"])
        state.finishReload(.items(items(2), truncated: false), key: chat, ticket: state.beginReload())
        state.finishReload(.failed("offline"), key: chat, ticket: state.beginReload())
        XCTAssertEqual(state.rows(for: chat).count, 2)
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.showsButton(for: chat))
        let other = key(["s2"])
        state.finishReload(.failed("offline"), key: other, ticket: state.beginReload())
        XCTAssertEqual(state.failure, "offline")
        XCTAssertFalse(state.showsButton(for: other))
    }

    func testACancelledReadEndsItsLoadAndChangesNothing() {
        var state = MacChatArtifactsPanelState()
        let chat = key(["s1"])
        state.finishReload(.items(items(2), truncated: false), key: chat, ticket: state.beginReload())
        state.finishReload(.cancelled, key: key(["s2"]), ticket: state.beginReload())
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.loadedKey, chat)
    }

    func testClearDropsTheListAndTheReadInFlight() {
        var state = MacChatArtifactsPanelState()
        let chat = key(["s1"])
        let ticket = state.beginReload()
        state.clear()
        state.finishReload(.items(items(2), truncated: false), key: chat, ticket: ticket)
        XCTAssertNil(state.loadedKey)
        XCTAssertFalse(state.showsButton(for: chat))
    }

    func testTheCountSaysPlusWhenThePanelReadOnlyTheFirstPages() {
        XCTAssertEqual(MacChatArtifactsPanelMetrics.countText(4, truncated: false), "4")
        XCTAssertEqual(MacChatArtifactsPanelMetrics.countText(600, truncated: true), "600+")
    }

    func testThePanelFloatsOverAChatTooNarrowToShareItsWidth() {
        let edge = MacChatArtifactsPanelMetrics.besideMinWidth
        XCTAssertEqual(edge, MacSidebarState.detailMinWidth + MacChatArtifactsPanelMetrics.width
            + MacChatArtifactsPanelMetrics.margin)
        XCTAssertEqual(MacChatArtifactsPanelMetrics.placement(containerWidth: edge), .beside)
        XCTAssertEqual(MacChatArtifactsPanelMetrics.placement(containerWidth: edge - 1), .over)
    }

    // MARK: Reading the host

    private final class Host {
        var paths: [String] = []
        var pages: [[String: Any]] = []
        var failure: Error?

        func request(_ path: String) throws -> [String: Any] {
            paths.append(path)
            if let failure { throw failure }
            guard !pages.isEmpty else { return ArtifactsTestSupport.response([]) }
            return pages.count > 1 ? pages.removeFirst() : pages[0]
        }
    }

    private func page(_ names: [String], next: Any = NSNull()) -> [String: Any] {
        ArtifactsTestSupport.response(names.enumerated().map { index, name in
            ArtifactsTestSupport.row(["name": name, "path": "/r/\(name)", "message_id": index])
        }, next: next)
    }

    func testReadingFollowsEveryPageWithTheChatsIDs() async {
        let host = Host()
        host.pages = [page(["a.md", "b.md"], next: 40), page(["c.md"])]
        let client = ArtifactsClient(request: { try host.request($0) })
        let outcome = await MacChatArtifactsPanelStore.read(key: key(["s2", "s1"]), client: client, maxPages: 10)
        guard case .items(let items, let truncated) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(items.map(\.name), ["a.md", "b.md", "c.md"])
        XCTAssertFalse(truncated)
        XCTAssertEqual(host.paths.count, 2)
        XCTAssertTrue(host.paths.allSatisfy { $0.contains("session_id=s1") && $0.contains("session_id=s2") }, "\(host.paths)")
        XCTAssertTrue(host.paths.allSatisfy { $0.contains("missing=hide") }, "missing files are left out by default")
        XCTAssertTrue(host.paths[1].contains("before=40"), host.paths[1])
    }

    func testAHostThatRepeatsTheCursorEndsTheRead() async {
        let host = Host()
        host.pages = [page(["a.md"], next: 40), page(["b.md"], next: 40)]
        let client = ArtifactsClient(request: { try host.request($0) })
        let outcome = await MacChatArtifactsPanelStore.read(key: key(["s1"]), client: client, maxPages: 10)
        guard case .items(let items, let truncated) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(items.map(\.name), ["a.md", "b.md"])
        XCTAssertFalse(truncated)
        XCTAssertEqual(host.paths.count, 2)
    }

    func testTheReadStopsAfterItsLastPage() async {
        let host = Host()
        host.pages = [page(["a.md"], next: 50), page(["b.md"], next: 40), page(["c.md"], next: 30)]
        let client = ArtifactsClient(request: { try host.request($0) })
        let outcome = await MacChatArtifactsPanelStore.read(key: key(["s1"]), client: client, maxPages: 2)
        guard case .items(let items, let truncated) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(items.map(\.name), ["a.md", "b.md"])
        XCTAssertTrue(truncated)
        XCTAssertEqual(host.paths.count, 2)
    }

    func testAFailedReadSaysWhy() async {
        let host = Host()
        host.failure = URLError(.notConnectedToInternet)
        let client = ArtifactsClient(request: { try host.request($0) })
        let outcome = await MacChatArtifactsPanelStore.read(key: key(["s1"]), client: client, maxPages: 2)
        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(message.isEmpty)
    }
}

/// The store against a fake host, and the toolbar and menu rules that read it.
@MainActor
final class MacChatArtifactsPanelStoreTests: XCTestCase {
    private final class Host {
        var paths: [String] = []
        var rows: [[String: Any]] = [ArtifactsTestSupport.row()]

        func request(_ path: String) throws -> [String: Any] {
            paths.append(path)
            return ArtifactsTestSupport.response(rows)
        }
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private let host = Host()
    private var chatKey: MacChatArtifactsPanelKey? = MacChatArtifactsPanelKey(
        dashboard: nil, profile: "default", sessionIDs: ["s1"], showMissing: false)
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatArtifactsPanelStoreTests.\(UUID().uuidString)", isDirectory: true)
        appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeStore(supported: Bool = true) -> MacChatArtifactsPanelStore {
        let host = host
        let source = MacArtifactsSource(supported: { _ in supported },
                                        client: { _ in ArtifactsClient(request: { try host.request($0) }) })
        return MacChatArtifactsPanelStore(defaults: suite.defaults, source: source, readKey: { [weak self] _ in self?.chatKey })
    }

    private func window(_ identifier: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier(identifier)
        windows.append(w)
        return w
    }

    func testBindingReadsTheOpenChatAndShowsTheButton() {
        let store = makeStore()
        store.bind(to: appState)
        XCTAssertTrue(HostedTestSupport.waitUntil { store.showsButton })
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.sessionIDs, ["s1"])
        XCTAssertEqual(host.paths.count, 1)
        XCTAssertTrue(host.paths[0].contains("session_id=s1"), host.paths[0])
        XCTAssertFalse(store.showsPanel, "the panel is closed until the button opens it")
    }

    func testAChatWithNoArtifactsReadsButShowsNoButton() {
        host.rows = []
        let store = makeStore()
        store.bind(to: appState)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.host.paths.count == 1 && !store.state.isLoading })
        XCTAssertFalse(store.showsButton)
        store.setOpen(true)
        XCTAssertFalse(store.showsPanel, "an open setting shows nothing for a chat with no artifacts")
    }

    func testNoChatReadsNothing() {
        chatKey = nil
        let store = makeStore()
        store.bind(to: appState)
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(host.paths.isEmpty, "an empty id list would read every chat")
        XCTAssertFalse(store.showsButton)
    }

    func testTheDefaultKeyNeedsAChatAndAHostThatListsArtifacts() {
        let supported = MacArtifactsSource(supported: { _ in true })
        XCTAssertTrue(appState.activeChatArtifactSessionIDs.isEmpty)
        XCTAssertNil(MacChatArtifactsPanelStore.key(appState: appState, source: supported, defaults: suite.defaults))
        let unsupported = MacArtifactsSource(supported: { _ in false })
        XCTAssertNil(MacChatArtifactsPanelStore.key(appState: appState, source: unsupported, defaults: suite.defaults))
    }

    func testRefreshReadsTheChatAgain() {
        let store = makeStore()
        store.bind(to: appState)
        XCTAssertTrue(HostedTestSupport.waitUntil { store.showsButton })
        host.rows = [ArtifactsTestSupport.row(), ArtifactsTestSupport.row(["path": "/root/out/b.png", "name": "b.png"])]
        store.reload()
        XCTAssertTrue(HostedTestSupport.waitUntil { store.count == 2 })
        XCTAssertEqual(host.paths.count, 2)
    }

    func testAnotherChatReadsItsOwnList() {
        let store = makeStore()
        store.bind(to: appState)
        XCTAssertTrue(HostedTestSupport.waitUntil { store.showsButton })
        chatKey = MacChatArtifactsPanelKey(dashboard: nil, profile: "default", sessionIDs: ["s9"], showMissing: false)
        host.rows = []
        store.refreshKey()
        XCTAssertTrue(HostedTestSupport.waitUntil { !store.showsButton })
        XCTAssertTrue(host.paths.last?.contains("session_id=s9") == true, "\(host.paths)")
    }

    func testTheOpenSettingIsRememberedForEveryChat() {
        let store = makeStore()
        XCTAssertFalse(store.isOpen, "off by default")
        store.setOpen(true)
        XCTAssertTrue(suite.defaults.bool(forKey: MacChatArtifactsPanelStore.openDefaultsKey))
        XCTAssertTrue(makeStore().isOpen, "a new store reads it back")
        store.toggle()
        XCTAssertFalse(suite.defaults.bool(forKey: MacChatArtifactsPanelStore.openDefaultsKey))
    }

    func testTheMenuItemTogglesThePanelOnlyForAMainWindowChatWithArtifacts() {
        let store = makeStore()
        let main = window("conduit-primary-AppWindow-1")
        XCTAssertFalse(MacAppActions.canToggleChatArtifactsPanel(window: main, tabRaw: "Sessions", panel: store),
                       "no artifacts known yet")
        store.bind(to: appState)
        XCTAssertTrue(HostedTestSupport.waitUntil { store.showsButton })
        XCTAssertTrue(MacAppActions.canToggleChatArtifactsPanel(window: main, tabRaw: "Sessions", panel: store))
        for tab in ["Home", "Artifacts", "Cron"] {
            XCTAssertFalse(MacAppActions.canToggleChatArtifactsPanel(window: main, tabRaw: tab, panel: store), tab)
            XCTAssertFalse(MacAppActions.toggleChatArtifactsPanel(window: main, panel: store, tabRaw: tab), tab)
        }
        let side = window("conduit-session-AppWindow-1")
        XCTAssertFalse(MacAppActions.canToggleChatArtifactsPanel(window: side, tabRaw: "Sessions", panel: store),
                       "a session window's chat is not the main window's")
        XCTAssertFalse(store.isOpen)
        let palette = MacPaletteStore(defaults: suite.defaults)
        XCTAssertTrue(MacAppActions.toggleChatArtifactsPanel(
            window: main, windows: [main], palette: palette, panel: store, tabRaw: "Sessions"))
        XCTAssertTrue(store.isOpen)
        XCTAssertTrue(store.showsPanel)
    }

    // MARK: Wiring

    private func source(of file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(file), encoding: .utf8)
    }

    func testTheChatToolbarAddsTheButtonAndTheChatTakesThePanel() throws {
        let root = try source(of: "Conduit/Views/RootView.swift")
        XCTAssertTrue(root.contains("@ObservedObject private var macArtifactsPanel = MacChatArtifactsPanelStore.shared"))
        XCTAssertTrue(root.contains("""
                    if macArtifactsPanel.showsButton {
                        ToolbarItem(placement: .topBarTrailing) {
                            MacChatArtifactsToolbarButton()
                        }
                    }
        """), "the button is a conditional trailing item")
        XCTAssertTrue(root.contains("""
                            ChatView()
                                .macChatArtifactsPanel()
        """), "the main window's chat takes the panel")
        let app = try source(of: "ConduitMac/App/ConduitMacApp.swift")
        XCTAssertTrue(app.contains(".task { MacChatArtifactsPanelStore.shared.bind(to: appState) }"))
        let commands = try source(of: "ConduitMac/App/ConduitCommands.swift")
        XCTAssertTrue(commands.contains("Button(artifactsPanel.isOpen ? \"Hide Artifacts\" : \"Show Artifacts\")"))
        XCTAssertTrue(commands.contains(
            ".disabled(!MacAppActions.canToggleChatArtifactsPanel(window: NSApp.keyWindow, tabRaw: sidebarTab, panel: artifactsPanel))"))
    }
}

/// The panel itself, hosted with a store that reads a fake host.
@MainActor
final class MacChatArtifactsPanelHostedTests: XCTestCase {
    private final class Host {
        var rows: [[String: Any]] = []
        func request(_ path: String) throws -> [String: Any] { ArtifactsTestSupport.response(rows) }
    }

    @MainActor
    private final class Env {
        var file: GatewayMediaFileResult = .unavailable
        var presented: [URL] = []
        var listed: [[String]] = []
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false
    private let host = Host()
    private let env = Env()

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatArtifactsPanelHostedTests.\(UUID().uuidString)", isDirectory: true)
        appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)
        host.rows = [
            ArtifactsTestSupport.row(["kind": "document", "name": "design-brief.md",
                                      "path": "/home/marc/Hermes/sweep/design-brief.md"]),
            ArtifactsTestSupport.row(["kind": "file", "name": "worker-contract.md",
                                      "path": "/home/marc/Hermes/sweep/UI01/worker-contract.md"]),
            ArtifactsTestSupport.row(["kind": "link", "source": "link", "name": "Docs", "url": "https://docs.example/a",
                                      "path": NSNull()]),
        ]
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func show() throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let host = host, env = env
        let source = MacArtifactsSource(
            supported: { _ in true },
            client: { _ in ArtifactsClient(request: { try host.request($0) }) },
            reader: { _ in MacArtifactsReader(dataURL: { _ in nil }, file: { _ in env.file }) },
            present: { download in
                env.presented.append(download.file)
                return true
            })
        let key = MacChatArtifactsPanelKey(dashboard: nil, profile: "default", sessionIDs: ["s1"], showMissing: false)
        let store = MacChatArtifactsPanelStore(defaults: suite.defaults, source: source, readKey: { _ in key })
        store.bind(to: appState)
        let view = MacChatArtifactsPanel(store: store, showAsList: { env.listed.append($0) })
            .environment(\.macArtifactsSource, source)
            .environmentObject(appState)
            .defaultAppStorage(suite.defaults)
            .frame(width: MacChatArtifactsPanelMetrics.width, height: 480)
        let w = HostedTestSupport.host(view, size: NSSize(width: MacChatArtifactsPanelMetrics.width, height: 480))
        window = w
        return w
    }

    private func texts(_ w: NSWindow) -> [String] { AccessibilityProbe.texts(in: w) }
    private func has(_ w: NSWindow, _ needle: String) -> Bool { texts(w).contains { $0.contains(needle) } }

    private func press(prefix: String, in w: NSWindow) -> Bool {
        guard let label = AccessibilityProbe.labels(in: w).first(where: { $0.hasPrefix(prefix) }) else { return false }
        return AccessibilityProbe.press(label, in: w)
    }

    func testThePanelDrawsTheTreeUnderItsHeader() throws {
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "worker-contract.md") }, "\(texts(w))")
        for needle in ["Artifacts", "3", "sweep", "UI01", "design-brief.md", "Links", "Docs"] {
            XCTAssertTrue(has(w, needle), "\(needle): \(texts(w))")
        }
    }

    func testAFolderClosesAndOpensAgain() throws {
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "worker-contract.md") }, "\(texts(w))")
        XCTAssertTrue(press(prefix: "UI01", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.has(w, "worker-contract.md") }, "\(texts(w))")
        XCTAssertTrue(has(w, "design-brief.md"), "only the folder's own rows go")
        XCTAssertTrue(press(prefix: "UI01", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "worker-contract.md") }, "\(texts(w))")
    }

    func testAFileOpensWithTheListsOpen() throws {
        let directory = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("design-brief.md")
        try Data("# brief".utf8).write(to: file)
        env.file = .downloaded(DashboardDownloadedFile(directory: directory, file: file, mimeType: nil))
        let w = try show()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.has(w, "design-brief.md") }, "\(texts(w))")
        XCTAssertTrue(press(prefix: "design-brief.md", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.env.presented.isEmpty }, "the file goes to the presenter")
        XCTAssertEqual(env.presented, [file])
    }
}
