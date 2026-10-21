import XCTest
@testable import ConduitMac

/// R17 for the frozen Mac login (ConduitMac/Login/LoginView.swift): the mapping from a discovery answer to the next
/// step must never end in a browser sheet that cannot sign in (B2), and must reach the browser sign-in that a password
/// dashboard also offers (B3). Also the saved sign-in offer (B5), the address refresh on a dashboard switch (M3) and
/// the sign-in defaults (K3).
final class LoginSignInRouteTests: XCTestCase {
    private let password: [String: Any] = ["name": "local", "supports_password": true]
    private let native: [String: Any] = ["name": "github", "supports_password": false]
    private let legacy: [String: Any] = ["name": "okta"]

    private func route(
        _ discovery: AuthProviderDiscoveryResult,
        credentials: Bool,
        nativeCheck: Bool = false
    ) async throws -> LoginSignInRoute {
        try await LoginView.signInRoute(
            for: discovery, credentialsArePresent: credentials, supportsNativeOAuth: { nativeCheck })
    }

    // MARK: B2

    func testUnrecognizedPageIsAnUnexpectedResponseNotABrowserSheet() async {
        do {
            let result = try await route(.unrecognized, credentials: false)
            XCTFail("expected an error, got \(result)")
        } catch {
            XCTAssertEqual(error as? DashboardSignInError, .unrecognizedServer)
            XCTAssertEqual(ConnectionFailureClassifier.classify(error), .unexpectedServerResponse)
        }
    }

    func testProviderListWithNoSignInIsAnUnexpectedResponse() async {
        for providers in [[[String: Any]](), [["name": "x", "supports_session": false]]] {
            do {
                let result = try await route(.providers(providers, authFlows: nil), credentials: false)
                XCTFail("expected an error, got \(result)")
            } catch {
                XCTAssertEqual(error as? DashboardSignInError, .noSignInMethod)
                XCTAssertEqual(ConnectionFailureClassifier.classify(error), .unexpectedServerResponse)
            }
        }
    }

    func testAuthProxyRedirectStillOpensTheBrowser() async throws {
        let result = try await route(.interactiveSignInRequired, credentials: false)
        XCTAssertEqual(result, .browser)
    }

    // MARK: B3

    func testPasswordWithLegacySessionProviderAndNoCredentialsOpensTheBrowser() async throws {
        let result = try await route(.providers([password, legacy], authFlows: nil), credentials: false)
        XCTAssertEqual(result, .browser)
    }

    func testPasswordWithNativeProviderWhenTheNativeCheckFailsOpensTheBrowser() async throws {
        let result = try await route(.providers([password, native], authFlows: nil), credentials: false, nativeCheck: false)
        XCTAssertEqual(result, .browser)
    }

    func testPasswordWithNativeProviderWhenTheNativeCheckPassesOpensNativeSignIn() async throws {
        let result = try await route(.providers([password, native], authFlows: nil), credentials: false, nativeCheck: true)
        XCTAssertEqual(result, .nativeOAuth(provider: "github"))
    }

    func testTypedCredentialsKeepThePasswordPath() async throws {
        for providers in [[password], [password, legacy], [password, native]] {
            let result = try await route(.providers(providers, authFlows: nil), credentials: true, nativeCheck: true)
            XCTAssertEqual(result, .password, "\(providers)")
        }
    }

    func testPasswordOnlyDashboardStaysOnThePasswordPath() async throws {
        let result = try await route(.providers([password], authFlows: nil), credentials: false)
        XCTAssertEqual(result, .password)
    }

    func testSingleSignOnOnlyDashboards() async throws {
        let legacyOnly = try await route(.providers([legacy], authFlows: nil), credentials: false)
        XCTAssertEqual(legacyOnly, .browser)
        let nativeOnly = try await route(.providers([native], authFlows: nil), credentials: true, nativeCheck: true)
        XCTAssertEqual(nativeOnly, .nativeOAuth(provider: "github"))
        let nativeUnsupported = try await route(.providers([native], authFlows: nil), credentials: false, nativeCheck: false)
        XCTAssertEqual(nativeUnsupported, .browser)
    }

    func testAFailedNativeCheckIsAnErrorNotAQuietBrowser() async {
        struct Boom: Error {}
        do {
            _ = try await LoginView.signInRoute(
                for: .providers([native], authFlows: nil), credentialsArePresent: false,
                supportsNativeOAuth: { throw Boom() })
            XCTFail("expected the check error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: B5

    func testSavedSignInOfferNamesTheSensorAndTheKind() {
        let touch = LoginSavedSignInOffer.make(kind: .biometric, biometricKind: .touchID, biometricsAvailable: true)
        XCTAssertEqual(touch?.title, "Signs in with Touch ID")
        let face = LoginSavedSignInOffer.make(kind: .biometric, biometricKind: .faceID, biometricsAvailable: true)
        XCTAssertEqual(face?.title, "Signs in with Face ID")
        XCTAssertEqual(LoginSavedSignInOffer.make(kind: .password, biometricKind: nil, biometricsAvailable: false)?.title,
                       "Saved sign-in")
        XCTAssertEqual(LoginSavedSignInOffer.make(kind: .session, biometricKind: nil, biometricsAvailable: false)?.title,
                       "Saved sign-in")
    }

    func testNoSavedSignInOfferWhenNothingIsSavedOrBiometricsAreGone() {
        XCTAssertNil(LoginSavedSignInOffer.make(kind: .signInNeeded, biometricKind: .touchID, biometricsAvailable: true))
        XCTAssertNil(LoginSavedSignInOffer.make(kind: .biometric, biometricKind: .touchID, biometricsAvailable: false))
    }

    // MARK: M3

    func testAddressFollowsTheDashboardUnlessTheUserTypedOne() {
        // Empty, or still the address the card filled in itself: follow the switch.
        XCTAssertEqual(LoginDashboardAddress.refreshed(current: "", autoFilled: "", dashboardURL: "https://b.example"),
                       "https://b.example")
        XCTAssertEqual(LoginDashboardAddress.refreshed(
            current: "https://a.example", autoFilled: "https://a.example", dashboardURL: "https://b.example"),
                       "https://b.example")
        XCTAssertEqual(LoginDashboardAddress.refreshed(
            current: " https://a.example/ ", autoFilled: "https://a.example", dashboardURL: "https://b.example"),
                       "https://b.example")
        // The user typed another address: keep it.
        XCTAssertNil(LoginDashboardAddress.refreshed(
            current: "https://typed.example", autoFilled: "https://a.example", dashboardURL: "https://b.example"))
        // Nothing to change.
        XCTAssertNil(LoginDashboardAddress.refreshed(
            current: "https://b.example", autoFilled: "https://b.example", dashboardURL: "https://b.example"))
        // No address for the new dashboard.
        XCTAssertNil(LoginDashboardAddress.refreshed(current: "https://a.example", autoFilled: "https://a.example", dashboardURL: ""))
    }

    // MARK: K3

    func testSaveSignInDefaultsToOnAndBiometricsFollowAvailability() {
        XCTAssertTrue(LoginSignInDefaults.saveCredentials)
        XCTAssertTrue(LoginSignInDefaults.useBiometrics(biometricsAvailable: true, saveCredentials: true))
        XCTAssertFalse(LoginSignInDefaults.useBiometrics(biometricsAvailable: false, saveCredentials: true))
        XCTAssertFalse(LoginSignInDefaults.useBiometrics(biometricsAvailable: true, saveCredentials: false))
    }
}
