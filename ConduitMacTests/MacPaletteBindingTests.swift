import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteBindingTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var appSuite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        appSuite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPaletteBindingTests.\(UUID().uuidString)", isDirectory: true)
        // An isolated AppState (same construction as MacSessionTabsBindTests): no
        // saved connection, no network, nothing in the live app's defaults.
        appState = AppState(
            defaults: appSuite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: appSuite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: appSuite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }; windows = []
        appState = nil
        HostedTestSupport.dropSuite(suite)
        HostedTestSupport.dropSuite(appSuite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func window(identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        windows.append(w)
        return w
    }

    func testSnapshotMirrorsAppState() {
        let snap = MacPaletteSnapshot.make(from: appState, defaults: suite.defaults)
        XCTAssertEqual(snap.activeProfile, appState.activeProfile)
        XCTAssertEqual(snap.activeSessionID, appState.activeSessionId)
        XCTAssertEqual(snap.isTurnRunning, appState.isBusy)
        XCTAssertEqual(snap.sessions.map(\.id), appState.activeProfileSessions.filter { !$0.isArchived }.map(\.id))
        XCTAssertEqual(snap.slashCommands, appState.slashCommands)
        XCTAssertTrue(snap.sidebarVisible, "defaults to visible when the key is unset")
        suite.defaults.set(false, forKey: MacSidebarState.defaultsKey)
        XCTAssertFalse(MacPaletteSnapshot.make(from: appState, defaults: suite.defaults).sidebarVisible)
    }

    func testBindIsIdempotentAndInstallsLiveCalls() {
        let store = MacPaletteStore(defaults: suite.defaults)
        store.bind(to: appState)
        store.bind(to: appState)
        XCTAssertEqual(store.snapshot().activeProfile, appState.activeProfile)
    }

    func testOpenSettingsPostsTheNotification() {
        let calls = MacPaletteCalls.live(appState: appState)
        let posted = expectation(forNotification: .macOpenSettingsRequested, object: nil)
        calls.openSettings()
        wait(for: [posted], timeout: 2)
    }

    func testModelPickerCallSetsTheFlag() {
        XCTAssertFalse(appState.showModelPicker)
        MacPaletteCalls.live(appState: appState).openModelPicker()
        XCTAssertTrue(appState.showModelPicker)
    }

    func testInsertSlashPrefillsTheComposerWithTrailingSpace() {
        let before = appState.composerPrefillToken
        MacPaletteCalls.live(appState: appState).insertSlash("title")
        XCTAssertEqual(appState.composerPrefillText, "/title ")
        XCTAssertNotEqual(appState.composerPrefillToken, before)
    }

    func testToggleOnlyInTheMainChatWindowAndNotUnderASheet() {
        let store = MacPaletteStore(defaults: suite.defaults)
        MacPaletteActions.toggle(store: store, window: window(identifier: "com_apple_SwiftUI_Settings_window"))
        XCTAssertFalse(store.isPresented, "a non-chat window ignores Cmd-K")
        MacPaletteActions.toggle(store: store, window: nil)
        XCTAssertFalse(store.isPresented)

        let main = window(identifier: "conduit-primary-AppWindow-1")
        MacPaletteActions.toggle(store: store, window: main)
        XCTAssertTrue(store.isPresented)
        MacPaletteActions.toggle(store: store, window: main)
        XCTAssertFalse(store.isPresented)

        let sheet = window(identifier: nil)
        main.beginSheet(sheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { main.attachedSheet != nil })
        MacPaletteActions.toggle(store: store, window: main)
        XCTAssertFalse(store.isPresented, "nothing opens under a sheet")
        main.endSheet(sheet)
    }
}
