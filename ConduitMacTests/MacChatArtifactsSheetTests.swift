import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Chat > Artifacts... (Task 13): the store, the action, the menu item and the sheet's list scope.
@MainActor
final class MacChatArtifactsSheetTests: XCTestCase {
    private final class Host {
        var paths: [String] = []
        func request(_ path: String) throws -> [String: Any] {
            paths.append(path)
            return ["ok": true, "items": [ArtifactsTestSupport.row()], "next_before": NSNull()]
        }
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false
    private let host = Host()
    private var primaryWindows: [NSWindow] = []

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatArtifactsSheetTests.\(UUID().uuidString)", isDirectory: true)
        appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        primaryWindows.forEach { $0.close() }
        primaryWindows = []
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func primary() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("conduit-primary-AppWindow-1")
        primaryWindows.append(w)
        return w
    }

    private func source() -> MacArtifactsSource {
        MacArtifactsSource(supported: { _ in true },
                           client: { [host] _ in ArtifactsClient(request: { try host.request($0) }) })
    }

    private func source(of file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(file), encoding: .utf8)
    }

    func testPresentStoresSessionIDs() {
        let store = MacChatArtifactsStore()
        XCTAssertNil(store.sessionIDs)
        store.present(sessionIDs: ["s1", "s2"])
        XCTAssertEqual(store.sessionIDs, ["s1", "s2"])
        store.dismiss()
        XCTAssertNil(store.sessionIDs)
    }

    func testMenuItemDisabledWithoutActiveChat() throws {
        XCTAssertTrue(appState.activeChatArtifactSessionIDs.isEmpty)
        XCTAssertFalse(MacAppActions.canShowChatArtifacts(appState: appState, window: primary(), tabRaw: "Sessions"))
        // The action itself refuses too, so an empty list never reads every chat.
        let store = MacChatArtifactsStore()
        XCTAssertFalse(MacAppActions.showChatArtifacts(window: nil, appState: appState, store: store))
        XCTAssertNil(store.sessionIDs)
        // The Chat menu item shows the side panel now (D33); the panel's Show as List opens this sheet.
        let panel = try source(of: "ConduitMac/Artifacts/MacChatArtifactsPanel.swift")
        XCTAssertTrue(panel.contains("MacAppActions.showChatArtifacts(window: NSApp.keyWindow, appState: appState, ids: ids)"))
    }

    func testActionPresentsTheGivenIDsFromTheMainWindow() {
        let store = MacChatArtifactsStore()
        let palette = MacPaletteStore(defaults: suite.defaults)
        XCTAssertTrue(MacAppActions.showChatArtifacts(
            window: primary(), palette: palette, appState: appState, store: store, ids: ["s1", "s2"], tabRaw: "Sessions"))
        XCTAssertEqual(store.sessionIDs, ["s1", "s2"])
        let other = MacChatArtifactsStore()
        XCTAssertFalse(MacAppActions.showChatArtifacts(
            window: nil, palette: palette, appState: appState, store: other, ids: ["s1"], tabRaw: "Sessions"))
        XCTAssertNil(other.sessionIDs, "no chat window: nothing is presented")
    }

    func testSessionWindowIsRefused() {
        let side = primary()
        side.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        let store = MacChatArtifactsStore()
        let palette = MacPaletteStore(defaults: suite.defaults)
        XCTAssertFalse(MacAppActions.canShowChatArtifacts(appState: appState, window: side, tabRaw: "Sessions"))
        XCTAssertFalse(MacAppActions.showChatArtifacts(
            window: side, windows: [side, primary()], palette: palette, appState: appState, store: store,
            ids: ["s1"], tabRaw: "Sessions"), "a session window never shows the main window's chat")
        XCTAssertNil(store.sessionIDs)
    }

    func testOtherTabsAreRefused() {
        let store = MacChatArtifactsStore()
        let palette = MacPaletteStore(defaults: suite.defaults)
        for tab in ["Home", "Artifacts", "Cron"] {
            XCTAssertFalse(MacAppActions.showChatArtifacts(
                window: primary(), palette: palette, appState: appState, store: store, ids: ["s1"], tabRaw: tab), tab)
        }
        XCTAssertNil(store.sessionIDs)
    }

    func testShowInChatClosesTheSheetAndRevealsInTheOpenChat() throws {
        let item = try XCTUnwrap(ArtifactItem(ArtifactsTestSupport.row(["message_id": 12, "session_id": "s2"])))
        var closed = 0
        XCTAssertNil(appState.pendingArtifactReveal)
        MacChatArtifactsView.showInChat(item, appState: appState, close: {
            closed += 1
            XCTAssertNil(self.appState.pendingArtifactReveal, "the sheet closes first")
        })
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(appState.pendingArtifactReveal?.messageID, 12)
        XCTAssertNil(appState.pendingArtifactReveal?.opening, "the open chat, no switch to s2")
    }

    func testSheetScopesToChat() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let view = MacChatArtifactsView(sessionIDs: ["s1", "s2"], close: {})
            .environment(\.macArtifactsSource, source())
            .environmentObject(appState)
            .defaultAppStorage(suite.defaults)
        window = HostedTestSupport.host(view, size: NSSize(width: 520, height: 520))
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.host.paths.isEmpty }, "the list read nothing")
        let path = try XCTUnwrap(host.paths.first)
        XCTAssertTrue(path.contains("session_id=s1") && path.contains("session_id=s2"), path)
        XCTAssertEqual(MacChatArtifactsView.scope(for: ["s1", "s2"]), .chat(["s1", "s2"]))
        let w = try XCTUnwrap(window)
        XCTAssertTrue(AccessibilityProbe.texts(in: w).contains("Artifacts"), "the sheet title")
    }

    func testEmptyIDsShowNoArtifactsAndReadNothing() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let view = MacChatArtifactsView(sessionIDs: [], close: {})
            .environment(\.macArtifactsSource, source())
            .environmentObject(appState)
            .defaultAppStorage(suite.defaults)
        let w = HostedTestSupport.host(view, size: NSSize(width: 520, height: 520))
        window = w
        XCTAssertTrue(HostedTestSupport.waitUntil {
            AccessibilityProbe.texts(in: w).contains { $0.contains("No Artifacts Yet") }
        }, "\(AccessibilityProbe.texts(in: w))")
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(host.paths.isEmpty)
    }
}
