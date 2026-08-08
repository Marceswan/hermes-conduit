//
//  NativeOAuthFlow.swift
//  Conduit
//
//  RFC 8252 (OAuth 2.0 for Native Apps) sign-in against the Hermes dashboard's
//  gateway-brokered native flow (/auth/native/*). The dashboard's hosted
//  identity provider (the Nous Portal uses Privy) runs bot checks that fail
//  inside an embedded WKWebView, so sign-in happens in a real Safari view
//  controller instead. The gateway brokers the upstream OAuth round trip and
//  hands Conduit bearer tokens directly — no webview, no cookies:
//
//    1. Generate a PKCE pair and open <dashboard>/auth/native/authorize in
//       SFSafariViewController with a loopback redirect_uri served by an
//       in-process listener (the app must stay foreground-active for the
//       listener to run, which is why the browser is presented in-app).
//    2. The gateway completes the portal login and 302s the browser to
//       http://127.0.0.1:<port>/callback?code=...&state=...
//    3. Exchange the code + PKCE verifier at /auth/native/token for
//       access/refresh bearer tokens, stored in the Keychain.
//    4. All dashboard REST and ws-ticket minting then use
//       "Authorization: Bearer" (DashboardTicketBridge bearer mode); tokens
//       rotate via /auth/native/refresh.
//

import CryptoKit
import Foundation
import Network

/// Bearer tokens minted by the dashboard's native OAuth broker.
struct DashboardBearerCredentials: Codable, Equatable {
    let baseURL: String
    var accessToken: String
    var refreshToken: String
    /// Unix seconds — the access token's exp claim, as reported by the gateway.
    var expiresAt: TimeInterval
    let provider: String

    /// Refresh ahead of expiry so an in-flight request never carries a token
    /// that dies mid-request. Mirrors the gateway's 120 s skew.
    var isExpiring: Bool {
        Date().timeIntervalSince1970 >= (expiresAt - 120)
    }
}

enum NativeOAuthError: LocalizedError {
    case unsupported
    case cancelled
    case stateMismatch
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This dashboard does not support native sign-in."
        case .cancelled:
            return "Sign-in was cancelled."
        case .stateMismatch:
            return "Sign-in response failed validation."
        case .failed(let message):
            return message
        }
    }
}

enum NativeOAuthPKCE {
    /// RFC 7636 code_verifier: 32 random octets, base64url without padding.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// S256 code_challenge: BASE64URL(SHA256(ASCII(verifier))).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Thread-safe latch: the first `tryPass()` wins, every later call is refused.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false

    func tryPass() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if passed { return false }
        passed = true
        return true
    }
}

/// One-shot loopback HTTP listener that catches the gateway's
/// `?code=...&state=...` redirect. RFC 8252 §7.3: native redirects go to the
/// loopback interface; the gateway enforces an `http://127.0.0.1` literal.
final class LoopbackRedirectListener: @unchecked Sendable {
    struct Redirect {
        let code: String
        let state: String
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Redirect, Error>?
    private var connections: [NWConnection] = []

    let port: UInt16

    /// Forwards connections to the instance once it exists; NWListener wants
    /// its handlers installed before start(), but the instance can only be
    /// built after the ephemeral port is known.
    private final class ConnectionRelay: @unchecked Sendable {
        weak var target: LoopbackRedirectListener?
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// Bind an ephemeral loopback port and wait for the socket to be ready.
    static func start() async throws -> LoopbackRedirectListener {
        let parameters = NWParameters.tcp
        // Loopback only — never a LAN-reachable socket.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let relay = ConnectionRelay()
        listener.newConnectionHandler = { relay.target?.accept($0) }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // NWListener may fire state updates from its queue concurrently
            // with this setup; the gate guarantees exactly one resume.
            let resumeGate = OneShotGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeGate.tryPass() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumeGate.tryPass() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "conduit.native-oauth.loopback"))
        }
        listener.stateUpdateHandler = nil
        guard port > 0 else {
            listener.cancel()
            throw NativeOAuthError.failed("Could not open the local sign-in listener.")
        }
        let instance = LoopbackRedirectListener(listener: listener, port: port)
        relay.target = instance
        return instance
    }

    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    func waitForRedirect() async throws -> Redirect {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        finish(with: .failure(NativeOAuthError.cancelled))
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: DispatchQueue(label: "conduit.native-oauth.conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.handle(request: request, on: connection)
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        // "GET /callback?code=...&state=... HTTP/1.1"
        let parts = request.split(separator: " ", maxSplits: 2)
        let target = parts.count >= 2 ? String(parts[1]) : ""
        var code: String?
        var state: String?
        if target.hasPrefix("/callback"),
           let components = URLComponents(string: "http://127.0.0.1\(target)") {
            code = components.queryItems?.first(where: { $0.name == "code" })?.value
            state = components.queryItems?.first(where: { $0.name == "state" })?.value
        }

        let delivered = (code?.isEmpty == false)
        let title = delivered ? "Signed in" : "Sign-in error"
        let detail = delivered
            ? "You can return to Conduit."
            : "The sign-in response was missing its code. Return to Conduit and try again."
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <body style="font-family:-apple-system,sans-serif;display:grid;place-items:center;height:90vh;margin:0">
        <div style="text-align:center"><h2>\(title)</h2><p>\(detail)</p></div></body>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        if let code, !code.isEmpty {
            finish(with: .success(Redirect(code: code, state: state ?? "")))
        }
    }

    private func finish(with result: Result<Redirect, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let open = connections
        connections = []
        lock.unlock()
        guard let continuation else { return }
        listener.cancel()
        open.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}

/// Drives one native sign-in against a dashboard. Create per attempt.
@MainActor
final class NativeOAuthFlow {
    struct PendingAuthorization: Identifiable {
        let id = UUID()
        let authorizeURL: URL
        fileprivate let listener: LoopbackRedirectListener
        fileprivate let expectedState: String

        func waitForCode() async throws -> String {
            let redirect = try await listener.waitForRedirect()
            guard redirect.state == expectedState else { throw NativeOAuthError.stateMismatch }
            return redirect.code
        }

        func cancel() { listener.cancel() }
    }

    private let baseURL: String
    private let verifier = NativeOAuthPKCE.makeVerifier()

    init(baseURL: String) throws {
        self.baseURL = try ConnectionURLPolicy.normalizedBaseURL(baseURL)
    }

    /// Whether the dashboard exposes the /auth/native/* broker. A parameter
    /// validation error (400/422) proves the route exists; 404 means an older
    /// gateway, and the caller falls back to the web login sheet.
    static func isSupported(baseURL: String) async -> Bool {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)/auth/native/authorize") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 400 || http.statusCode == 422
    }

    func begin() async throws -> PendingAuthorization {
        let listener = try await LoopbackRedirectListener.start()
        let state = NativeOAuthPKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        var components = URLComponents(string: "\(baseURL)/auth/native/authorize")!
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: NativeOAuthPKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: listener.redirectURI),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else {
            listener.cancel()
            throw NativeOAuthError.failed("Could not build the sign-in URL.")
        }
        return PendingAuthorization(authorizeURL: url, listener: listener, expectedState: state)
    }

    func exchange(code: String) async throws -> DashboardBearerCredentials {
        let body = ["code": code, "code_verifier": verifier]
        let payload = try await Self.postJSON(baseURL: baseURL, path: "/auth/native/token", body: body)
        return try Self.credentials(from: payload, baseURL: baseURL)
    }

    // MARK: - Static REST helpers (also used by DashboardTicketBridge)

    static func refresh(_ current: DashboardBearerCredentials) async throws -> DashboardBearerCredentials {
        let body = ["refresh_token": current.refreshToken, "provider": current.provider]
        do {
            let payload = try await postJSON(baseURL: current.baseURL, path: "/auth/native/refresh", body: body)
            return try credentials(from: payload, baseURL: current.baseURL)
        } catch NativeOAuthError.failed(let message) where message.contains("session_expired") {
            throw DashboardTicketBridgeError.signInRequired
        }
    }

    static func mintWSTicket(baseURL: String, accessToken: String) async throws -> String {
        let payload = try await postJSON(
            baseURL: baseURL,
            path: "/api/auth/ws-ticket",
            body: [:],
            bearer: accessToken
        )
        guard let ticket = payload["ticket"] as? String, !ticket.isEmpty else {
            throw NativeOAuthError.failed("Dashboard did not return a WebSocket ticket.")
        }
        return ticket
    }

    private static func credentials(
        from payload: [String: Any],
        baseURL: String
    ) throws -> DashboardBearerCredentials {
        guard let accessToken = payload["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = payload["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw NativeOAuthError.failed("Dashboard token response was incomplete.")
        }
        let expiresAt = (payload["expires_at"] as? NSNumber)?.doubleValue
            ?? Date().timeIntervalSince1970 + 300
        return DashboardBearerCredentials(
            baseURL: baseURL,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            provider: payload["provider"] as? String ?? ""
        )
    }

    private static func postJSON(
        baseURL: String,
        path: String,
        body: [String: Any],
        bearer: String? = nil
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw NativeOAuthError.failed("Invalid dashboard URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeOAuthError.failed("Dashboard did not respond.")
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                let marker = payload["error"] as? String ?? ""
                throw NativeOAuthError.failed(marker.isEmpty ? "unauthorized (\(http.statusCode))" : marker)
            }
            let detail = (payload["detail"] as? String)
                ?? (payload["error"] as? String)
                ?? "Dashboard request failed (\(http.statusCode))."
            throw NativeOAuthError.failed(detail)
        }
        return payload
    }
}
