import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// A Keychain in memory, keyed by service and account (the scoped and the legacy query of one record share a key).
private final class MemoryKeychainBackend: KeychainHelper.Backend {
    private var items: [String: Data] = [:]

    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] ?? "")|\(query[kSecAttrAccount as String] ?? "")"
    }

    func data(for query: [String: Any]) -> Data? { items[key(query)] }

    func update(_ data: Data, for query: [String: Any]) -> Int32 {
        guard items[key(query)] != nil else { return errSecItemNotFound }
        items[key(query)] = data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> Int32 {
        items[key(query)] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) { items[key(query)] = nil }

    func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32 { errSecSuccess }
}

/// R17 for the frozen sign-in copies in ConduitMac/Login: outcomes that had no visible way forward.
@MainActor
final class LoginFrozenCopyOutcomeTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false
    override func setUp() async throws {
        // The registry and the saved sign-in records go to the Keychain, outside the defaults suite: keep every
        // read and write of this class off the real one.
        KeychainHelper.useBackendForTesting(MemoryKeychainBackend())
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoginFrozenCopyOutcomeTests.\(UUID().uuidString)", isDirectory: true)
        // Isolated AppState (same construction as MacDashboardSwitcherTests).
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
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func identifiers(of view: some View, expecting: String) throws -> Set<String> {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let w = HostedTestSupport.host(view.frame(width: 640, height: 900), size: NSSize(width: 640, height: 900))
        window = w
        func ids() -> Set<String> { Set(AccessibilityProbe.nodes(in: w).compactMap(\.identifier)) }
        _ = HostedTestSupport.waitUntil { ids().contains(expecting) }
        HostedTestSupport.settle(0.3)
        return ids()
    }

    // MARK: K1

    func testExpiredSignInOffersSignInAgain() throws {
        appState.pendingLoginFailure = .signInExpired
        let ids = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.error.sign-in-again")
        XCTAssertTrue(ids.contains("login.error.sign-in-again"), "\(ids)")
        XCTAssertFalse(ids.contains("login.error.try-again"), "\(ids)")
    }

    func testOtherFailuresStillOfferTryAgain() throws {
        appState.pendingLoginFailure = .presenting(.connectionRefused)
        let ids = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.error.try-again")
        XCTAssertTrue(ids.contains("login.error.try-again"), "\(ids)")
        XCTAssertFalse(ids.contains("login.error.sign-in-again"), "\(ids)")
    }

    // MARK: B5

    func testSavedSignInButtonIsAControlWithItsStatusText() throws {
        let offer = try XCTUnwrap(LoginSavedSignInOffer.make(kind: .biometric, biometricKind: .touchID, biometricsAvailable: true, isConnected: false))
        let view = LoginSavedSignInButton(offer: offer, address: "https://hermes.example", isBusy: false, action: {})
        let ids = try identifiers(of: view, expecting: "login.saved-sign-in")
        XCTAssertTrue(ids.contains("login.saved-sign-in"), "\(ids)")
        let texts = AccessibilityProbe.texts(in: try XCTUnwrap(window))
        XCTAssertTrue(texts.contains { $0.contains("Signs in with Touch ID") }, "\(texts)")
    }

    // MARK: M3

    func testActiveDashboardChangePublishesToTheLoginCard() throws {
        let first = try XCTUnwrap(appState.resolveDashboardID(forURL: "https://a.example.com", registerIfMissing: true))
        let second = try XCTUnwrap(appState.resolveDashboardID(forURL: "https://b.example.com", registerIfMissing: true))
        appState.selectDashboardTarget(first)
        var published = 0
        let token = appState.objectWillChange.sink { published += 1 }
        defer { token.cancel() }
        appState.selectDashboardTarget(second)
        XCTAssertEqual(appState.activeDashboardID, second)
        XCTAssertGreaterThan(published, 0, "a view that reads activeDashboardID is told when it changes")
    }

    func testLoginCardFollowsADashboardSwitchWhileItIsOpen() throws {
        let first = try XCTUnwrap(appState.resolveDashboardID(forURL: "https://a.example.com", registerIfMissing: true))
        let second = try XCTUnwrap(appState.resolveDashboardID(forURL: "https://b.example.com", registerIfMissing: true))
        appState.selectDashboardTarget(first)
        appState.rememberDashboardURL("https://a.example.com")
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let w = HostedTestSupport.host(LoginView().environmentObject(appState).frame(width: 640, height: 900),
                                       size: NSSize(width: 640, height: 900))
        window = w
        func address() -> String? { AccessibilityProbe.nodes(in: w).first { $0.identifier == "login.server-url" }?.value }
        // The card fills the address from the last dashboard when it appears; switch only after that.
        XCTAssertTrue(HostedTestSupport.waitUntil { address() == "https://a.example.com" }, "first fill: \(address() ?? "nil")")
        appState.selectDashboardTarget(second)
        let ok = HostedTestSupport.waitUntil { address()?.contains("b.example.com") == true }
        XCTAssertTrue(ok, "address after the switch: \(address() ?? "nil")")
    }

    // MARK: F4 (LC-A): Add Dashboard over a connected session has a way back

    /// The card is raised over a connected session (Cmd-Shift-D > Add Dashboard sets `showLogin`).
    private func connectSession() throws {
        let id = try XCTUnwrap(appState.resolveDashboardID(forURL: "https://one.example", registerIfMissing: true))
        appState.selectDashboardTarget(id)
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.showLogin = true
    }

    private func cancelNode() -> AccessibilityProbe.Node? {
        window.flatMap { AccessibilityProbe.nodes(in: $0).first { $0.identifier == "login.cancel" } }
    }

    func testConnectedSessionOffersCancelThatClosesTheCardAndKeepsTheSession() throws {
        try connectSession()
        let dashboardID = appState.activeDashboardID
        _ = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.cancel")
        let cancel = try XCTUnwrap(cancelNode(), "a connected session must have a way back from the card")
        XCTAssertEqual(cancel.label, "Cancel", "upstream's add-dashboard string")
        XCTAssertEqual(cancel.isEnabled, true)
        XCTAssertGreaterThan(cancel.frame.width, 20, "a visible control")
        XCTAssertLessThanOrEqual(cancel.frame.maxX, 640, "inside the card, not clipped at the window edge")
        XCTAssertTrue(appState.showLogin)

        XCTAssertTrue(AccessibilityProbe.press("Cancel", in: try XCTUnwrap(window)))

        XCTAssertFalse(appState.showLogin, "Cancel closes the card")
        XCTAssertTrue(appState.isConnected, "Cancel does not touch the running session")
        XCTAssertEqual(appState.activeDashboardID, dashboardID)
        XCTAssertNotNil(appState.client)
    }

    func testNoSessionOffersNoCancel() throws {
        appState.showLogin = true
        XCTAssertFalse(appState.isConnected, "precondition")
        let ids = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.server-url")
        XCTAssertTrue(ids.contains("login.server-url"), "the card is up: \(ids)")
        XCTAssertFalse(ids.contains("login.cancel"), "with no session there is nothing to go back to: \(ids)")
        // R17: the way forward stays. Connect, the address field and the connection help are on the card.
        XCTAssertTrue(ids.contains("login.connect"), "Connect: \(ids)")
        XCTAssertTrue(ids.contains("login.connection-setup"), "Need help connecting?: \(ids)")
    }

    /// Escape, as AppKit sends it to the window's key equivalents.
    private func pressEscape(in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)
        return event.map { window.performKeyEquivalent(with: $0) } ?? false
    }

    func testEscapeClosesTheCardWhenASessionIsConnected() throws {
        try connectSession()
        _ = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.cancel")
        let host = try XCTUnwrap(window)
        host.makeKeyAndOrderFront(nil)
        XCTAssertTrue(appState.showLogin, "precondition")

        _ = pressEscape(in: host)

        XCTAssertTrue(HostedTestSupport.waitUntil { !self.appState.showLogin }, "Esc presses Cancel")
        XCTAssertTrue(appState.isConnected, "the session stays")
    }

    func testEscapeDoesNothingWithNoSessionOrWhileASignInWorks() throws {
        // No session: no Cancel, so Esc leaves the card as it is.
        appState.showLogin = true
        _ = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.server-url")
        var host = try XCTUnwrap(window)
        host.makeKeyAndOrderFront(nil)
        _ = pressEscape(in: host)
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(appState.showLogin, "no session")

        // A sign-in under way: Cancel is disabled, so Esc does not close the card under it.
        HostedTestSupport.tearDown(host)
        window = nil
        try connectSession()
        appState.isConnecting = true
        _ = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.cancel")
        host = try XCTUnwrap(window)
        host.makeKeyAndOrderFront(nil)
        _ = pressEscape(in: host)
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(appState.showLogin, "a sign-in under way")
    }

    func testCancelWaitsForASignInUnderWay() throws {
        try connectSession()
        appState.isConnecting = true
        _ = try identifiers(of: LoginView().environmentObject(appState), expecting: "login.cancel")
        let cancel = try XCTUnwrap(cancelNode())
        XCTAssertEqual(cancel.isEnabled, false, "upstream disables Cancel while a sign-in is working")
    }

    // MARK: B1 (wiring; the sheet itself is covered by AuthWebSignInSheetTests)

    private func loginSource(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("ConduitMac/Login/\(name)"), encoding: .utf8)
    }

    func testEveryBrowserSignInSheetInTheCopiesHasACancelBar() throws {
        for name in ["LoginView.swift", "ConnectionSetupView.swift"] {
            let source = try loginSource(name)
            let sheets = source.components(separatedBy: "AuthWebView(").count - 1
            let bars = source.components(separatedBy: ".asSignInSheet()").count - 1
            XCTAssertGreaterThan(sheets, 0, name)
            XCTAssertEqual(sheets, bars, "\(name): every AuthWebView( must end in .asSignInSheet()")
        }
    }

    func testBrowserSignInFailureClosesTheSheetBeforeShowingTheFailure() throws {
        let source = try loginSource("LoginView.swift")
        let start = try XCTUnwrap(source.range(of: "onError: { classifiedFailure, detail in"))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "failure = .presenting(classifiedFailure)"))
        XCTAssertTrue(tail[..<end.lowerBound].contains("showWebView = false"),
                      "a failure shown under an open sheet is hidden")
    }
}
