import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// R17 for the frozen sign-in copies in ConduitMac/Login: outcomes that had no visible way forward.
@MainActor
final class LoginFrozenCopyOutcomeTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false
    override func setUp() async throws {
        // The registry and the saved sign-in records go to the Keychain, outside the defaults suite.
        // MacTestKeychainGuard puts a fresh MacTestKeychainBackend in before this method and after the test.
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
