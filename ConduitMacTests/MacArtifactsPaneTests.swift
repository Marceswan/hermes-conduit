import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// The Artifacts sidebar pane (D26): its tab, route, shortcut and strip place, and the pane's
/// states. The list's own rules are in `MacArtifactsListTests`.
@MainActor
final class MacArtifactsPaneTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacArtifactsPaneTests.\(UUID().uuidString)", isDirectory: true)
        // Isolated AppState: no saved connection, no network, nothing in the live app's defaults.
        // Its notifier plugin has reported nothing, so it does not offer artifacts.
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

    private func artifactItem(_ fields: [String: Any] = [:]) throws -> ArtifactItem {
        var row: [String: Any] = [
            "kind": "image", "source": "delivered", "name": "map.png", "path": "/root/out/map.png",
            "exists": true, "size": 2048, "session_id": "s1", "session_title": "Weekend trip",
            "message_id": 12, "timestamp": 1_760_000_000.0,
        ]
        row.merge(fields) { _, new in new }
        return try XCTUnwrap(ArtifactItem(row))
    }

    // MARK: tab, route, shortcut, strip

    func testArtifactsTabRoutesToArtifactsPane() {
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .artifacts), .artifacts)
        XCTAssertEqual(SidebarTab.artifacts.rawValue, "Artifacts")
        XCTAssertEqual(SidebarTab.artifacts.icon, "square.grid.2x2")
        XCTAssertEqual(SidebarTab.artifacts.displayName, "Artifacts")
        XCTAssertEqual(SidebarTab.migrated(rawValue: "Artifacts"), .artifacts)
    }

    func testArtifactsIsAPaneNotChat() {
        XCTAssertFalse(MacChatRoute.isChatActive(tabRaw: "Artifacts"))
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: "Artifacts"), SidebarTab.artifacts.displayName)
    }

    func testCtrlCmd6SelectsArtifacts() {
        XCTAssertEqual(MacSidebarShortcut.tab(forKey: "6"), .artifacts)
        XCTAssertEqual(MacSidebarShortcut.artifacts.modifiers, [.control, .command])
        XCTAssertEqual(MacSidebarShortcut.artifacts.title, SidebarTab.artifacts.displayName)
        XCTAssertEqual(MacSidebarShortcut.allCases.last, .artifacts, "numbered after Home, so no existing number moves")
    }

    func testStripOrderEndsWithArtifacts() {
        XCTAssertEqual(MacSidebarTabOrder.strip.last, .artifacts)
        XCTAssertEqual(MacSidebarTabOrder.strip.first, .home, "Home stays leftmost")
    }

    // MARK: show missing

    func testShowMissingDefaultsOffAndHidesMissing() throws {
        // The key is upstream's, so the Mac list and any upstream list share the setting.
        XCTAssertEqual(MacArtifactsList.showMissingKey, "artifacts.showMissing")
        XCTAssertFalse(MacArtifactsList.showMissingDefault)
        let unset = suite.defaults.bool(forKey: MacArtifactsList.showMissingKey)
        XCTAssertFalse(unset, "a defaults suite without the key reads as off")

        var state = MacArtifactsListState()
        let key = ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "")
        let ticket = state.beginReload(key)
        let rows = [
            try artifactItem(),
            try artifactItem(["exists": false, "path": "/root/gone.pdf", "kind": "document", "name": "gone.pdf"]),
            try artifactItem(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                              "name": "Curate", "exists": false]),
        ]
        state.finishReload(.page(ArtifactPage(items: rows, nextBefore: nil)), key: key, ticket: ticket)
        XCTAssertEqual(state.visibleItems(showMissing: unset).map(\.name), ["map.png", "Curate"],
                       "a file gone from the host is hidden; a link has no file to miss")
        XCTAssertEqual(state.visibleItems(showMissing: true).map(\.name), ["map.png", "gone.pdf", "Curate"])
    }

    // MARK: states

    func testUnsupportedPluginShowsUpdateState() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        XCTAssertFalse(appState.supportsArtifacts)
        let w = HostedTestSupport.host(
            MacArtifactsPane().environmentObject(appState).frame(width: 520, height: 520),
            size: NSSize(width: 520, height: 520))
        window = w
        XCTAssertTrue(HostedTestSupport.waitUntil {
            AccessibilityProbe.texts(in: w).contains("Update the Conduit plugin")
        }, "\(AccessibilityProbe.texts(in: w))")
        HostedTestSupport.settle(0.3)
        let texts = AccessibilityProbe.texts(in: w)
        XCTAssertTrue(texts.contains("Artifacts"), "the pane names itself: \(texts)")
        XCTAssertFalse(texts.contains("No Artifacts Yet"), "an unsupported host is not an empty one")
        // A bare spinner shows up under a progress or busy role; the pane has none.
        let isSpinner: (String) -> Bool = { $0.contains("Progress") || $0.contains("Busy") }
        let control = HostedTestSupport.host(ProgressView().frame(width: 80, height: 80), size: NSSize(width: 80, height: 80))
        defer { HostedTestSupport.tearDown(control) }
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.nodes(in: control).map(\.role).contains(where: isSpinner) },
                      "the probe can see a spinner: \(AccessibilityProbe.nodes(in: control).map(\.role))")
        let roles = AccessibilityProbe.nodes(in: w).map(\.role)
        XCTAssertFalse(roles.contains(where: isSpinner), "no spinner while the plugin cannot list: \(roles)")
    }

    // MARK: dashboard switch

    func testDashboardSwitchDropsOtherServerRows() throws {
        let first = UUID()
        let second = UUID()
        let onFirst = ArtifactsListKey(dashboard: first, profile: "default", filter: .all, query: "")
        let onSecond = ArtifactsListKey(dashboard: second, profile: "default", filter: .all, query: "")
        XCTAssertNotEqual(onFirst, onSecond, "every server has a default profile")
        XCTAssertFalse(onSecond.showsRows(of: onFirst))

        var state = MacArtifactsListState()
        let loaded = state.beginReload(onFirst)
        state.finishReload(.page(ArtifactPage(items: [try artifactItem()], nextBefore: 9)), key: onFirst, ticket: loaded)
        XCTAssertEqual(state.items.count, 1)

        // Another filter on the same server keeps the rows up (dimmed) while its own load.
        let images = ArtifactsListKey(dashboard: first, profile: "default", filter: .images, query: "")
        _ = state.beginReload(images)
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.nextBefore, 9)

        // The other server's list never shows this server's rows, not even for a moment.
        let switching = state.beginReload(onSecond)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertNil(state.nextBefore)
        XCTAssertNil(state.loadedKey)
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.visibleItems(showMissing: true).isEmpty)

        // A late answer for the first server is dropped under the second.
        state.finishReload(.page(ArtifactPage(items: [try artifactItem()], nextBefore: nil)), key: images, ticket: loaded)
        XCTAssertTrue(state.items.isEmpty)
        state.finishReload(.page(ArtifactPage(items: [], nextBefore: nil)), key: onSecond, ticket: switching)
        XCTAssertEqual(state.loadedKey, onSecond)
    }

    // MARK: Show in Chat

    func testShowInChatFromPaneOpensSessionAndReturnsToChat() throws {
        suite.defaults.set(SidebarTab.artifacts.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let w = HostedTestSupport.host(
            MacDetailRouter(defaults: suite.defaults, chat: { Color.clear })
                .environmentObject(appState)
                .frame(width: 600, height: 400),
            size: NSSize(width: 600, height: 400))
        window = w
        HostedTestSupport.settle(0.3)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.artifacts.rawValue)

        final class Count: @unchecked Sendable { var value = 0 }
        let posted = Count()
        let observer = NotificationCenter.default.addObserver(
            forName: .macSessionOpenRequested, object: nil, queue: .main
        ) { _ in posted.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let item = try artifactItem(["session_id": "s1", "message_id": 77])
        MacArtifactsPane.showInChat(item, in: appState)

        let reveal = try XCTUnwrap(appState.pendingArtifactReveal)
        XCTAssertEqual(reveal.messageID, item.messageID)
        XCTAssertEqual(reveal.opening, "s1", "the reveal waits for the item's chat, not the open one")
        XCTAssertEqual(posted.value, 1, "the open request reached the router")
        XCTAssertTrue(HostedTestSupport.waitUntil {
            self.suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey) == SidebarTab.sessions.rawValue
        }, "the main pane returns to chat")
    }
}
