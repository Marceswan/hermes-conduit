//
//  DashboardTicketBridge.swift
//  Conduit
//
//  Keeps the dashboard's HttpOnly session cookie inside WebKit and mints a
//  fresh, single-use WebSocket ticket whenever Hermes needs to reconnect.
//

import Foundation
import SwiftUI
import WebKit
import Security

/// WebKit normally persists durable cookies itself, but dashboard deployments
/// often issue a session cookie. Mirror the authenticated dashboard cookies in
/// Keychain and restore them before the cold-launch bridge loads. Values stay
/// device-local and are cleared with the saved connection on explicit sign-out.
@MainActor
enum DashboardCookiePersistence {
    private struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresDate: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
        let sameSitePolicy: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expiresDate = cookie.expiresDate
            isSecure = cookie.isSecure
            isHTTPOnly = cookie.isHTTPOnly
            sameSitePolicy = cookie.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .secure: isSecure ? "TRUE" : "FALSE"
            ]
            if let expiresDate { properties[.expires] = expiresDate }
            if isHTTPOnly { properties[.init("HttpOnly")] = "TRUE" }
            if let sameSitePolicy { properties[.sameSitePolicy] = sameSitePolicy }
            return HTTPCookie(properties: properties)
        }
    }

    static func restore(into cookieStore: WKHTTPCookieStore) async {
        guard let data = KeychainHelper.loadDashboardCookies(),
              let saved = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return }
        for cookie in saved.compactMap(\.cookie) {
            await cookieStore.setCookie(cookie)
        }
    }

    /// URLSession and WebKit maintain separate cookie stores. Copy the native
    /// password-login session into WebKit before the bridge loads its first
    /// dashboard request, keeping the existing dashboard API path authenticated.
    static func restoreNativeCookies(into cookieStore: WKHTTPCookieStore, for baseURL: String) async {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        for cookie in cookies where cookieMatchesHost(cookie, host: host) {
            await cookieStore.setCookie(cookie)
        }
    }

    static func capture(from cookieStore: WKHTTPCookieStore, for url: URL?) async {
        guard let host = url?.host?.lowercased() else { return }
        let cookies = await cookieStore.allCookies().filter { cookie in
            cookieMatchesHost(cookie, host: host)
        }
        guard let data = try? JSONEncoder().encode(cookies.map(StoredCookie.init)) else { return }
        KeychainHelper.saveDashboardCookies(data)
    }

    private static func cookieMatchesHost(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix(".\(domain)")
    }
}

enum DashboardTicketBridgeError: LocalizedError {
    case notReady
    case signInRequired
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The dashboard session is still loading."
        case .signInRequired:
            return "Dashboard sign-in has expired."
        case .requestFailed(let message):
            return message
        }
    }
}

/// WKUserContentController retains its message handlers strongly, which would
/// cycle bridge -> webView -> configuration -> contentController -> bridge.
/// This proxy is what the controller retains; it holds the bridge weakly, so
/// the bridge deallocates naturally and needs no main-actor work in deinit.
@MainActor
private final class WeakScriptMessageForwarder: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class DashboardTicketBridge: NSObject {
    let baseURL: String
    let webView: WKWebView

    private var isReady = false
    private var requestID = 0
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Native-OAuth bearer session (RFC 8252 sign-in via NativeOAuthFlow).
    /// When present, all dashboard REST goes through URLSession with an
    /// `Authorization: Bearer` header and the WebKit cookie machinery below
    /// stays idle — there is no cookie session to preserve.
    private var bearerCredentials: DashboardBearerCredentials?
    private var bearerRefreshTask: Task<DashboardBearerCredentials, Error>?

    var usesBearerAuth: Bool { bearerCredentials != nil }

    init(baseURL: String) {
        self.baseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? ""
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakScriptMessageForwarder(self), name: "dashboard-response")
        webView.navigationDelegate = self
        if let stored = KeychainHelper.loadBearerCredentials(), stored.baseURL == self.baseURL {
            bearerCredentials = stored
            isReady = true
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await DashboardCookiePersistence.restore(into: self.webView.configuration.websiteDataStore.httpCookieStore)
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL
            )
            self.loadDashboardSession()
        }
    }

    func reload() {
        if bearerCredentials != nil {
            // No page to reload in bearer mode; rotate the token instead so
            // mintTicket's reload-and-retry loop still makes forward progress.
            Task { [weak self] in _ = try? await self?.refreshBearerCredentials() }
            return
        }
        isReady = false
        rejectPending(with: DashboardTicketBridgeError.notReady)
        Task { [weak self] in
            guard let self else { return }
            await DashboardCookiePersistence.restore(into: self.webView.configuration.websiteDataStore.httpCookieStore)
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL
            )
            self.loadDashboardSession()
        }
    }

    func mintTicket() async throws -> String {
        // A freshly restored session cookie can reach WebKit's cookie store a
        // moment before its network process. A first 401 is therefore not
        // enough evidence to erase the durable session and force a login.
        for attempt in 0..<3 {
            try await waitUntilReady()
            do {
                let response = try await requestJSON(path: "/api/auth/ws-ticket", method: "POST")
                guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
                    throw DashboardTicketBridgeError.requestFailed("Dashboard did not return a WebSocket ticket.")
                }
                return ticket
            } catch DashboardTicketBridgeError.signInRequired where attempt < 2 {
                reload()
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        throw DashboardTicketBridgeError.signInRequired
    }

    private func waitUntilReady() async throws {
        for _ in 0..<30 where !isReady {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard isReady else { throw DashboardTicketBridgeError.notReady }
    }

    /// Requests authenticated dashboard JSON through the same WebKit cookie
    /// jar that the sign-in flow owns. This intentionally avoids duplicating
    /// HttpOnly session handling in URLSession.
    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        if bearerCredentials != nil {
            return try await bearerRequestJSON(
                path: path,
                method: method,
                body: body,
                timeoutMilliseconds: timeoutMilliseconds,
                maxResponseBytes: maxResponseBytes
            )
        }
        for _ in 0..<30 where !isReady {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard isReady else { throw DashboardTicketBridgeError.notReady }

        requestID += 1
        let id = requestID
        let pathLiteral = try javaScriptLiteral(path)
        let methodLiteral = try javaScriptLiteral(method)
        let bodyLiteral = try body.map(javaScriptLiteral) ?? "null"
        let timeout = max(1_000, timeoutMilliseconds)
        let responseLimit = max(1_024, maxResponseBytes)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            let script = """
            (async function() {
                try {
                    const requestBody = \(bodyLiteral);
                    const controller = new AbortController();
                    const timeout = setTimeout(() => controller.abort(), \(timeout));
                    const response = await fetch(\(pathLiteral), {
                        method: \(methodLiteral),
                        credentials: 'include',
                        headers: requestBody === null
                            ? { Accept: 'application/json' }
                            : { Accept: 'application/json', 'Content-Type': 'application/json' },
                        body: requestBody === null ? undefined : JSON.stringify(requestBody),
                        signal: controller.signal
                    });
                    const declaredLength = Number(response.headers.get('content-length') || 0);
                    if (declaredLength > \(responseLimit)) throw new Error('response_too_large');
                    const text = await (async function() {
                        if (!response.body || typeof response.body.getReader !== 'function') {
                            if (!Number.isFinite(declaredLength) || declaredLength <= 0) throw new Error('bounded_response_unavailable');
                            return response.text();
                        }
                        const reader = response.body.getReader();
                        const decoder = new TextDecoder();
                        let totalBytes = 0;
                        let result = '';
                        while (true) {
                            const chunk = await reader.read();
                            if (chunk.done) {
                                result += decoder.decode();
                                return result;
                            }
                            totalBytes += chunk.value.byteLength;
                            if (totalBytes > \(responseLimit)) {
                                await reader.cancel();
                                throw new Error('response_too_large');
                            }
                            result += decoder.decode(chunk.value, { stream: true });
                        }
                    })();
                    clearTimeout(timeout);
                    let body = null;
                    try { body = text ? JSON.parse(text) : null; } catch (_) { body = text; }
                    const normalizedBody = Array.isArray(body) ? { _array: body } : (body && typeof body === 'object' ? body : { value: body });
                    window.webkit.messageHandlers['dashboard-response'].postMessage(JSON.stringify({
                        type: 'dashboard-response', id: \(id), ok: response.ok,
                        status: response.status, body: normalizedBody,
                        error: !response.ok && body && typeof body === 'object'
                            ? (body.error || body.message || body.detail) : null
                    }));
                } catch (error) {
                    window.webkit.messageHandlers['dashboard-response'].postMessage(JSON.stringify({
                        type: 'dashboard-response', id: \(id), ok: false, status: 0, error: String(error)
                    }));
                }
            })();
            true;
            """
            webView.evaluateJavaScript(script) { _, error in
                guard let error, let pending = self.pendingRequests.removeValue(forKey: id) else { return }
                pending.resume(throwing: error)
            }
        }
    }

    // MARK: - Bearer (native OAuth) transport

    /// URLSession twin of the WebKit fetch path: same response-shape contract
    /// ({_array:...} wrapping, {value:...} for scalars), same signInRequired
    /// semantics on 401/403, with one transparent token refresh + retry.
    private func bearerRequestJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        timeoutMilliseconds: Int,
        maxResponseBytes: Int,
        allowRefresh: Bool = true
    ) async throws -> [String: Any] {
        guard var credentials = bearerCredentials else {
            throw DashboardTicketBridgeError.signInRequired
        }
        if credentials.isExpiring {
            credentials = try await refreshBearerCredentials()
        }
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw DashboardTicketBridgeError.requestFailed("Could not encode dashboard request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Double(max(1_000, timeoutMilliseconds)) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardTicketBridgeError.requestFailed("Dashboard did not respond.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            guard allowRefresh else { throw DashboardTicketBridgeError.signInRequired }
            _ = try await refreshBearerCredentials()
            return try await bearerRequestJSON(
                path: path,
                method: method,
                body: body,
                timeoutMilliseconds: timeoutMilliseconds,
                maxResponseBytes: maxResponseBytes,
                allowRefresh: false
            )
        }
        guard data.count <= max(1_024, maxResponseBytes) else {
            throw DashboardTicketBridgeError.requestFailed("response_too_large")
        }

        let decoded = try? JSONSerialization.jsonObject(with: data)
        let normalized: [String: Any]
        switch decoded {
        case let object as [String: Any]:
            normalized = object
        case let array as [Any]:
            normalized = ["_array": array]
        case let other?:
            normalized = ["value": other]
        default:
            normalized = [:]
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (normalized["error"] as? String)
                ?? (normalized["message"] as? String)
                ?? (normalized["detail"] as? String)
                ?? "Dashboard request failed (\(http.statusCode))."
            throw DashboardTicketBridgeError.requestFailed(detail)
        }
        return normalized
    }

    /// Rotate via /auth/native/refresh, deduplicating concurrent callers onto
    /// one network round trip. A rejected refresh token surfaces as
    /// signInRequired — AppState's recovery path then clears the stored
    /// credentials and shows the login screen.
    private func refreshBearerCredentials() async throws -> DashboardBearerCredentials {
        if let bearerRefreshTask {
            return try await bearerRefreshTask.value
        }
        guard let current = bearerCredentials else {
            throw DashboardTicketBridgeError.signInRequired
        }
        let task = Task<DashboardBearerCredentials, Error> {
            try await NativeOAuthFlow.refresh(current)
        }
        bearerRefreshTask = task
        defer { bearerRefreshTask = nil }
        do {
            let refreshed = try await task.value
            bearerCredentials = refreshed
            KeychainHelper.saveBearerCredentials(refreshed)
            return refreshed
        } catch is DashboardTicketBridgeError {
            throw DashboardTicketBridgeError.signInRequired
        } catch let error as NativeOAuthError {
            throw DashboardTicketBridgeError.requestFailed(error.localizedDescription)
        }
    }

    private func javaScriptLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let literal = String(data: data, encoding: .utf8) else {
            throw DashboardTicketBridgeError.requestFailed("Could not encode dashboard request.")
        }
        return literal
    }

    private func loadDashboardSession() {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)/api/status") else { return }
        webView.load(URLRequest(url: url))
    }

    private func rejectPending(with error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }
}

extension DashboardTicketBridge: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard ConnectionURLPolicy.isAllowedTransport(navigationAction.request.url) else {
            decisionHandler(.cancel)
            return
        }
        if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
            decisionHandler(.allow)
            return
        }
        guard let expectedURL = URL(string: baseURL),
              ConnectionURLPolicy.originMatches(navigationAction.request.url, expected: expectedURL) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A redirect back to /login means the HttpOnly dashboard session is no
        // longer valid; never attempt to mint a misleading gateway ticket.
        guard let expectedURL = URL(string: baseURL),
              ConnectionURLPolicy.originMatches(webView.url, expected: expectedURL) else {
            isReady = false
            rejectPending(with: DashboardTicketBridgeError.requestFailed("Dashboard navigation left the configured origin."))
            return
        }
        isReady = !(webView.url?.path.contains("/login") ?? true)
        if !isReady {
            rejectPending(with: DashboardTicketBridgeError.signInRequired)
        } else {
            Task { @MainActor in
                await DashboardCookiePersistence.capture(
                    from: webView.configuration.websiteDataStore.httpCookieStore,
                    for: expectedURL
                )
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isReady = false
        rejectPending(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isReady = false
        rejectPending(with: error)
    }
}

extension DashboardTicketBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dashboard-response", let raw = message.body as? String,
              message.frameInfo.isMainFrame,
              let expectedURL = URL(string: baseURL),
              ConnectionURLPolicy.originMatches(
                scheme: message.frameInfo.securityOrigin.protocol,
                host: message.frameInfo.securityOrigin.host,
                port: message.frameInfo.securityOrigin.port,
                expected: expectedURL
              ),
              let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["type"] as? String == "dashboard-response",
              let id = payload["id"] as? Int,
              let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if payload["ok"] as? Bool == true {
            continuation.resume(returning: payload["body"] as? [String: Any] ?? [:])
            return
        }

        let status = payload["status"] as? Int ?? 0
        if status == 401 || status == 403 {
            continuation.resume(throwing: DashboardTicketBridgeError.signInRequired)
            return
        }
        let detail = payload["error"] as? String ?? "Dashboard request failed (\(status))."
        continuation.resume(throwing: DashboardTicketBridgeError.requestFailed(detail))
    }
}

/// Hosts the authenticated WebKit process in the SwiftUI hierarchy. It has no
/// visible UI; its only job is preserving the dashboard's HttpOnly session for
/// fresh WebSocket tickets after a reconnect or cold launch.
struct DashboardTicketBridgeView: UIViewRepresentable {
    let bridge: DashboardTicketBridge

    func makeUIView(context: Context) -> WKWebView {
        bridge.webView.isUserInteractionEnabled = false
        return bridge.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
