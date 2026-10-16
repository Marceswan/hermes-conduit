import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacDashboardSwitcherTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDashboardSwitcherTests.\(UUID().uuidString)", isDirectory: true)
        // Isolated AppState (same construction as MacPaletteBindingTests): no saved
        // connection, no network, nothing in the live app's defaults.
        appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: store

    func testPresentIsIdempotentAndDismissCloses() {
        let store = MacDashboardSwitcherStore()
        XCTAssertFalse(store.isPresented)
        store.present()
        store.present()
        XCTAssertTrue(store.isPresented)
        store.dismiss()
        XCTAssertFalse(store.isPresented)
        store.dismiss()
        XCTAssertFalse(store.isPresented)
    }

    // MARK: content

    private func hostView(close: @escaping () -> Void) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let view = MacDashboardSwitcherView(close: close).environmentObject(appState)
        let w = HostedTestSupport.host(view.frame(width: 520, height: 520), size: NSSize(width: 520, height: 520))
        window = w
        return w
    }

    func testSheetShowsTheSavedDashboardsPageUnderASheetHeader() throws {
        let w = try hostView(close: {})
        XCTAssertTrue(HostedTestSupport.waitUntil {
            let labels = AccessibilityProbe.labels(in: w)
            return labels.contains("Add Dashboard") && labels.contains("Close Saved Dashboards")
        }, "\(AccessibilityProbe.labels(in: w))")
    }

    func testHeaderCloseCallsCloseOnce() throws {
        var closed = 0
        let w = try hostView(close: { closed += 1 })
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: w).contains("Close Saved Dashboards") })
        XCTAssertTrue(AccessibilityProbe.press("Close Saved Dashboards", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { closed == 1 })
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(closed, 1)
    }

    func testAddDashboardRaisesTheLoginAndClosesTheSheet() throws {
        var closed = 0
        let w = try hostView(close: { closed += 1 })
        // AppState starts on the login surface; start from the signed-in state the sheet is opened in.
        appState.showLogin = false
        XCTAssertFalse(appState.showLogin)
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: w).contains("Add Dashboard") })
        XCTAssertTrue(AccessibilityProbe.press("Add Dashboard", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { closed == 1 })
        XCTAssertTrue(appState.showLogin, "the login surface must not stay hidden under the sheet")
    }

    // MARK: modifier

    func testModifierPresentsOneSheetAndDismissesIt() {
        let store = MacDashboardSwitcherStore()
        let host = HostedTestSupport.host(Color.clear.macDashboardSwitcher(appState: appState, store: store),
                                          size: NSSize(width: 600, height: 600))
        window = host
        store.present()
        XCTAssertTrue(HostedTestSupport.waitUntil { host.attachedSheet != nil }, "the sheet attaches to the window")
        let first = host.attachedSheet
        store.present()
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(host.attachedSheet === first, "presenting again keeps the one sheet")
        store.dismiss()
        XCTAssertTrue(HostedTestSupport.waitUntil { host.attachedSheet == nil })
    }
}
