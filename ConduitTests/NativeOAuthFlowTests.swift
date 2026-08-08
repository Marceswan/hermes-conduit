import Foundation
import XCTest
@testable import Conduit

final class NativeOAuthFlowTests: XCTestCase {
    /// RFC 7636 Appendix B reference vector.
    func testPKCEChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            NativeOAuthPKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierIsBase64URLWithRFCCompliantLength() {
        let verifier = NativeOAuthPKCE.makeVerifier()
        // 32 octets -> 43 base64url chars; RFC 7636 requires 43-128.
        XCTAssertEqual(verifier.count, 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy(allowed.contains))
        // Verifiers must be single-use random values, never repeated.
        XCTAssertNotEqual(verifier, NativeOAuthPKCE.makeVerifier())
    }

    func testBearerCredentialsExpiryUsesRefreshSkew() {
        let now = Date().timeIntervalSince1970
        let live = DashboardBearerCredentials(
            baseURL: "https://hermes.example", accessToken: "a", refreshToken: "r",
            expiresAt: now + 600, provider: "nous"
        )
        let expiring = DashboardBearerCredentials(
            baseURL: "https://hermes.example", accessToken: "a", refreshToken: "r",
            expiresAt: now + 60, provider: "nous"
        )
        XCTAssertFalse(live.isExpiring)
        XCTAssertTrue(expiring.isExpiring)
    }

    func testLoopbackListenerCatchesCallbackRedirect() async throws {
        let listener = try await LoopbackRedirectListener.start()
        XCTAssertTrue(listener.redirectURI.hasPrefix("http://127.0.0.1:"))

        let waiter = Task { try await listener.waitForRedirect() }
        // Give the waiter a beat to install its continuation.
        try await Task.sleep(for: .milliseconds(50))

        var request = URLRequest(url: URL(string: "\(listener.redirectURI)?code=gw-code-123&state=st-1")!)
        request.timeoutInterval = 5
        _ = try await URLSession.shared.data(for: request)

        let redirect = try await waiter.value
        XCTAssertEqual(redirect.code, "gw-code-123")
        XCTAssertEqual(redirect.state, "st-1")
    }
}
