import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskCommandsTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var fixture: MacSharedBaseAppStateFixture?

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }

    override func tearDown() async throws {
        fixture?.tearDown()
        fixture = nil
        HostedTestSupport.dropSuite(suite)
    }

    private final class StubPanel: MacQuickAskPanelHosting {
        var isVisible = false
        func show() { isVisible = true }
        func hide() { isVisible = false }
        func toggle() { isVisible.toggle() }
    }

    private final class NoopRegistrar: MacHotKeyRegistering {
        var failure: MacHotKeyRegistrationError?
        var registered = 0
        var unregisters = 0
        func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws {
            if let failure { throw failure }
            registered += 1
        }
        func unregister() { unregisters += 1 }
    }

    private func manager(_ registrar: NoopRegistrar) -> MacQuickAskHotKeyManager {
        MacQuickAskHotKeyManager(registrar: registrar, defaults: suite.defaults, isUnderTest: false)
    }

    func testHotKeyManagerUsesTheDocumentedDefaultsKey() {
        XCTAssertEqual(MacQuickAskHotKeyManager.enabledKey, "conduit.mac.quickAsk.enabled")
    }

    func testBootstrapWiresHotKeyToTheControllerAndBindsTheHub() {
        let fixture = MacSharedBaseAppStateFixture()
        self.fixture = fixture
        let hub = MacStreamEventHub()
        let controller = MacQuickAskController(hub: hub)
        let panel = StubPanel()
        controller.panel = panel
        let registrar = NoopRegistrar()
        let hotKey = manager(registrar)

        MacQuickAskBootstrap.start(appState: fixture.appState, controller: controller, hotKey: hotKey)

        XCTAssertEqual(hotKey.state, .registered)
        XCTAssertEqual(registrar.registered, 1)
        XCTAssertEqual(hub.subscriberCount, 0, "idle Quick Ask is not on the stream; it subscribes when it owns a session")
        XCTAssertEqual(controller.connection, .disconnected, "a fresh AppState has no connection")
        hotKey.onHotKey()
        XCTAssertTrue(panel.isVisible)
        hotKey.onHotKey()
        XCTAssertFalse(panel.isVisible)
    }

    func testBootstrapIsIdempotent() {
        let fixture = MacSharedBaseAppStateFixture()
        self.fixture = fixture
        let hub = MacStreamEventHub()
        let controller = MacQuickAskController(hub: hub)
        let registrar = NoopRegistrar()
        let hotKey = manager(registrar)
        MacQuickAskBootstrap.start(appState: fixture.appState, controller: controller, hotKey: hotKey)
        MacQuickAskBootstrap.start(appState: fixture.appState, controller: controller, hotKey: hotKey)
        XCTAssertEqual(hub.subscriberCount, 0)
        XCTAssertEqual(registrar.registered, 1)
    }

    func testStopReleasesTheHotKeyAndTheStream() {
        let fixture = MacSharedBaseAppStateFixture()
        self.fixture = fixture
        let hub = MacStreamEventHub()
        let controller = MacQuickAskController(hub: hub)
        let registrar = NoopRegistrar()
        let hotKey = manager(registrar)
        MacQuickAskBootstrap.start(appState: fixture.appState, controller: controller, hotKey: hotKey)
        controller.subscribeToHub()
        MacQuickAskBootstrap.stop(controller: controller, hotKey: hotKey)
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(hotKey.state, .disabled)
        XCTAssertEqual(hub.subscriberCount, 0)
        hotKey.refresh()
        XCTAssertEqual(registrar.registered, 1, "a late activation after terminate does not register again")
        XCTAssertEqual(hotKey.state, .disabled)
    }

    func testMenuCommandOpensPanelEvenWhenRegistrationFailed() {
        let controller = MacQuickAskController(hub: MacStreamEventHub())
        let panel = StubPanel()
        controller.panel = panel
        let registrar = NoopRegistrar()
        registrar.failure = .unavailableOnThisMacOS
        let hotKey = manager(registrar)
        hotKey.refresh()
        XCTAssertEqual(hotKey.state, .unavailable(.unavailableOnThisMacOS))
        controller.show()      // what the Chat > Quick Ask button calls
        XCTAssertTrue(panel.isVisible)
    }

    func testQuickAskMenuItemHasNoGlobalKeyEquivalent() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConduitMac/App/ConduitCommands.swift"), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let index = try XCTUnwrap(lines.firstIndex { $0.contains("Button(\"Quick Ask\")") })
        XCTAssertFalse(lines[index].contains("keyboardShortcut"))
        XCTAssertFalse(lines[index + 1].contains("keyboardShortcut"), "no modifier chained on the next line either")
    }

    func testArtifactsMenuItemSitsAfterAskAboutWindowWithoutAKeyEquivalent() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConduitMac/App/ConduitCommands.swift"), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let ask = try XCTUnwrap(lines.firstIndex { $0.contains("Button(\"Ask About Window") })
        let artifacts = try XCTUnwrap(lines.firstIndex { $0.contains("Button(\"Artifacts\\u{2026}\")") })
        XCTAssertGreaterThan(artifacts, ask)
        XCTAssertLessThan(artifacts - ask, 8, "the next item of the Chat menu")
        XCTAssertFalse(lines[artifacts].contains("keyboardShortcut"))
        XCTAssertFalse(lines[artifacts + 1].contains("keyboardShortcut"), "no modifier chained on the next line either")
    }

    func testMenuHasTheShortcutToggleBoundToTheDefaultsKey() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConduitMac/App/ConduitCommands.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@AppStorage(MacQuickAskHotKeyManager.enabledKey)"))
        XCTAssertTrue(source.contains("Toggle(\"Quick Ask Shortcut\""))
    }
}
