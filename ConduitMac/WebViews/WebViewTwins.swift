// Mac twins of upstream WKWebView representables; keep in sync (PORTING_LEDGER).
import SwiftUI
import WebKit

/// Mac twin of the iOS `DashboardTicketBridgeView`: hosts the authenticated
/// WebKit process in the SwiftUI hierarchy. It has no visible UI.
struct DashboardTicketBridgeView: NSViewRepresentable {
    let bridge: DashboardTicketBridge

    func makeNSView(context: Context) -> WKWebView {
        bridge.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// Mac twin of MarkupBlock.swift MarkupWebView; keep in sync (PORTING_LEDGER).
/// The page a block draws in. It takes no touches: the chat scrolls over it
/// and the block handles taps.
struct MarkupWebView: NSViewRepresentable {
    enum Event: Equatable {
        case height(CGFloat)
        case failed(String?)
    }

    let document: MarkupDocument
    let onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Mac has no `isUserInteractionEnabled`: the page declines every hit so
    /// the chat scrolls over it, as on iOS.
    final class PassthroughWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The transparent, hit-test-free page view. The caller adds the message
    /// handler and delegates.
    static func makeConfiguredWebView(configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> WKWebView {
        let view = PassthroughWebView(frame: .zero, configuration: configuration)
        view.makeBackgroundTransparent()
        view.enclosingScrollView?.hasVerticalScroller = false
        return view
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            MarkupMessageProxy(context.coordinator),
            name: MarkupHTML.messageHandlerName
        )
        let view = Self.makeConfiguredWebView(configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.onEvent = onEvent
        context.coordinator.load(document, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.load(document, into: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: MarkupHTML.messageHandlerName)
        view.navigationDelegate = nil
        view.stopLoading()
        coordinator.onEvent = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onEvent: ((Event) -> Void)?
        private var loaded: MarkupDocument?
        private var html = ""
        private var reloads = MarkupReloads()

        /// Loads the page once per document; SwiftUI calls this on every
        /// update, which during a stream is every frame.
        func load(_ document: MarkupDocument, into view: WKWebView) {
            guard document != loaded else { return }
            loaded = document
            reloads = MarkupReloads()
            html = MarkupHTML.page(document, presentation: .inline)
            view.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let height = body["height"] as? Double {
                reloads.pageDrew()
                onEvent?(.height(CGFloat(height)))
            } else if let detail = body["failed"] as? String {
                onEvent?(.failed(detail.isEmpty ? nil : detail))
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebKit can end an off-screen page's process under memory
            // pressure, which leaves the block blank until it reloads. A
            // page that keeps ending it before it draws gets the failure
            // card instead of reloading forever.
            guard !html.isEmpty else { return }
            if reloads.mayReload() {
                webView.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
            } else {
                onEvent?(.failed(nil))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(MarkupHTML.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
        }
    }
}

// Mac twin of MarkupBlock.swift SafeMarkupWebView; keep in sync (PORTING_LEDGER).
struct SafeMarkupWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.makeBackgroundTransparent()
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        return view
    }

    /// A new page while the sheet is open (light or dark switched) reloads.
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        context.coordinator.reloads = MarkupReloads()
        view.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(html: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String
        var reloads = MarkupReloads()

        init(html: String) {
            self.html = html
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Same as the inline page: reload rather than stay blank, a
            // couple of times. This page doesn't report when it has drawn,
            // so the count only starts again with a new page.
            guard reloads.mayReload() else { return }
            webView.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(MarkupHTML.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
        }
    }
}

/// Mac copy of the file-private `RemoteImageHTML` in MarkdownText.swift; keep in sync.
private enum MacRemoteImageHTML {
    static func render(url: String) -> String {
        let source = MarkupHTML.jsonString(url)
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;background:transparent}img{display:block;max-width:100%;height:auto;margin:auto;border-radius:13px}</style>
        </head><body><img id="image" alt="" />
        <script>document.getElementById('image').src=\(source);</script></body></html>
        """
    }
}

// Mac twin of MarkdownText.swift RemoteImageWebView; keep in sync (PORTING_LEDGER).
struct RemoteImageWebView: NSViewRepresentable {
    let url: String
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, failed: $failed) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.makeBackgroundTransparent()
        view.enclosingScrollView?.hasVerticalScroller = false
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(MacRemoteImageHTML.render(url: url), baseURL: URL(string: "https://conduit.local/"))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var height: CGFloat
        @Binding var failed: Bool

        init(height: Binding<CGFloat>, failed: Binding<Bool>) {
            _height = height
            _failed = failed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Image failures do not create a navigation error, so inspect the
            // browser image element after it has had a chance to load.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                webView.evaluateJavaScript("(() => { const i = document.getElementById('image'); return { loaded: !!i && i.complete && i.naturalWidth > 0, height: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) }; })()") { value, _ in
                    guard let result = value as? [String: Any], result["loaded"] as? Bool == true else {
                        self.failed = true
                        return
                    }
                    if let value = result["height"] as? Double { self.height = CGFloat(value) }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed = true }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let host = navigationAction.request.url?.host
            decisionHandler(host == nil || host == "conduit.local" ? .allow : .cancel)
        }
    }
}

// Mac twin of LoginView.swift AuthWebView; keep in sync (PORTING_LEDGER).
struct AuthWebView: NSViewRepresentable {
    let url: String
    let cloudflareAccess: CloudflareAccessCredentials?
    /// Resolves the saved dashboard being signed into AT CAPTURE TIME (on
    /// successful sign-in), so the cookie mirror is written to that
    /// dashboard's scoped record. A closure, not a value: resolving during
    /// view construction would register a dashboard for every render of the
    /// login card, and the binding belongs to the commit moment. Nil
    /// (callers without a registry context, e.g. tests) captures nothing —
    /// no identity, no durable mirror.
    var dashboardIDProvider: (() -> UUID?)? = nil
    /// The dashboard-owned WebKit session store identifier for this sign-in.
    /// Non-nil means the WebView runs inside `WKWebsiteDataStore(
    /// forIdentifier:)` for that identity — never the shared default store —
    /// so sign-in cookies are isolated per dashboard from the first request.
    /// Nil (legacy/test construction) keeps the default store.
    var websiteDataStoreIdentifier: UUID? = nil
    let onTicket: (String, String) -> Void
    /// Classified failure + raw diagnostic detail. The dashboard controls the
    /// detail text (e.g. `payload["error"]`), so it is never rendered — the
    /// login card shows only the fixed copy for the classification.
    let onError: (ConnectionFailure, String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url)
        let config = Self.makeConfiguration(
            normalizedBaseURL: normalized,
            cloudflareAccess: cloudflareAccess,
            websiteDataStoreIdentifier: websiteDataStoreIdentifier,
            ticketHandler: context.coordinator
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        guard let normalized else {
            Self.reportConstructionFailure(onError, detail: AppLocalization.string("dashboard URL failed normalization in AuthWebView"))
            return webView
        }
        if let request = try? Self.dashboardRequest(normalizedBaseURL: normalized, cloudflareAccess: cloudflareAccess) {
            webView.load(request)
        } else {
            Self.reportConstructionFailure(onError, detail: AppLocalization.string("dashboard sign-in request construction failed"))
        }
        return webView
    }

    /// The sign-in page's WebView configuration. Static, so the handler and
    /// script placement stays unit-testable without a SwiftUI `Context`.
    ///
    /// The ticket handler and the proxy-header scripts live in
    /// `DashboardScriptWorld` (#774), not the page world: the dashboard page's
    /// own scripts can then neither read the Cloudflare Access token or the
    /// custom headers, nor post a forged ticket.
    @MainActor
    static func makeConfiguration(
        normalizedBaseURL normalized: String?,
        cloudflareAccess: CloudflareAccessCredentials?,
        websiteDataStoreIdentifier: UUID?,
        ticketHandler: WKScriptMessageHandler
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = DashboardCookiePersistence.webKitStore(for: websiteDataStoreIdentifier)
        config.userContentController.add(ticketHandler, contentWorld: DashboardScriptWorld.world, name: "ticket")
        if let normalized {
            DashboardScriptWorld.installProxyHeaderScripts(
                into: config.userContentController,
                cloudflareAccess: cloudflareAccess,
                normalizedBaseURL: normalized
            )
        }
        return config
    }

    /// Construction-time failures cannot synchronously mutate the owning
    /// view's state: makeNSView runs inside SwiftUI's representable update
    /// pass, and an immediate onError would write LoginView @State mid-render.
    /// Report on the next main-runloop turn instead. Static with an injected
    /// callback so the deferral contract stays unit-testable.
    static func reportConstructionFailure(
        _ onError: @escaping (ConnectionFailure, String) -> Void,
        detail: String,
        failure: ConnectionFailure = .invalidAddress
    ) {
        DispatchQueue.main.async {
            onError(failure, detail)
        }
    }

    /// The dashboard sign-in request the WebView boots with. Extracted so the
    /// service-token header placement on the initial request stays covered by
    /// unit tests without hosting a WKWebView.
    static func dashboardRequest(
        normalizedBaseURL: String,
        cloudflareAccess: CloudflareAccessCredentials?
    ) throws -> URLRequest {
        guard let dashboardURL = URL(string: normalizedBaseURL) else {
            throw ConnectionURLPolicyError.invalidURL
        }
        let loginURL = dashboardURL.appending(path: "login")
        var request = URLRequest(url: loginURL)
        request = request.applyingProxyHeaders(cloudflare: cloudflareAccess)
        return request
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: "ticket",
            contentWorld: DashboardScriptWorld.world
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: AuthWebView
        private var hasDeliveredTicket = false
        private var hasPinnedDashboardOrigin = false
        private weak var authenticatedWebView: WKWebView?

        init(parent: AuthWebView) {
            self.parent = parent
        }

        private var expectedURL: URL? {
            guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(parent.url) else { return nil }
            return URL(string: normalized)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Match the React Native bridge: the dashboard owns the sign-in
            // flow, then a non-login route can use its HttpOnly session cookie
            // to mint a one-time WebSocket ticket.
            guard let expectedURL,
                  AuthWebViewNavigationPolicy.isSignedInDashboardPage(webView.url, expectedDashboardURL: expectedURL) else { return }
            hasPinnedDashboardOrigin = true
            authenticatedWebView = webView
            let js = """
            (async function() {
                try {
                    const response = await fetch('/api/auth/ws-ticket', {
                        method: 'POST',
                        credentials: 'include'
                    });
                    const body = await response.json().catch(() => ({}));
                    window.webkit.messageHandlers.ticket.postMessage(JSON.stringify({
                        type: 'hermes-ticket',
                        status: response.status,
                        ticket: body.ticket || null
                    }));
                } catch (error) {
                    window.webkit.messageHandlers.ticket.postMessage(JSON.stringify({
                        type: 'hermes-ticket',
                        status: 0,
                        error: String(error)
                    }));
                }
            })();
            true;
            """
            webView.evaluateJavaScript(js, in: nil, in: DashboardScriptWorld.world, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ticket", let rawMessage = message.body as? String,
                  message.frameInfo.isMainFrame,
                  let expectedURL,
                  ConnectionURLPolicy.originMatches(
                    scheme: message.frameInfo.securityOrigin.protocol,
                    host: message.frameInfo.securityOrigin.host,
                    port: message.frameInfo.securityOrigin.port,
                    expected: expectedURL
                  ),
                  let data = rawMessage.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["type"] as? String == "hermes-ticket" else { return }

            let status = payload["status"] as? Int ?? 0
            guard status != 401 else { return } // The dashboard is still showing its sign-in route.
            guard let ticket = payload["ticket"] as? String, !ticket.isEmpty else {
                // The classification is Conduit's, never the payload's: a
                // completed dashboard sign-in that fails to mint a ticket is
                // a session-ticket failure regardless of what the payload
                // says. Payload text is carried as diagnostic detail only.
                let detail = payload["error"] as? String
                    ?? AppLocalization.string("Unable to start the Hermes session\(status == 0 ? "" : " (\(status))")")
                parent.onError(.sessionTicketFailure, detail)
                return
            }
            // Persist the HttpOnly dashboard session before dismissing this
            // WebView. The old detached task could lose the cookie race on a
            // cold launch, so the saved one-time ticket had nothing to renew.
            let webView = authenticatedWebView
            Task { @MainActor [weak self, weak webView] in
                guard let self else { return }
                if let webView, let dashboardID = parent.dashboardIDProvider?() {
                    await DashboardCookiePersistence.capture(
                        from: webView.configuration.websiteDataStore.httpCookieStore,
                        for: self.expectedURL,
                        dashboardID: dashboardID
                    )
                }
                self.deliver(ticket: ticket)
            }
        }

        private func deliver(ticket: String) {
            let cleanedTicket = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hasDeliveredTicket, !cleanedTicket.isEmpty,
                  let baseURL = try? ConnectionURLPolicy.normalizedBaseURL(parent.url) else { return }
            hasDeliveredTicket = true
            parent.onTicket(cleanedTicket, baseURL)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // A nil targetFrame is treated as main-frame, matching the
            // historical policy for the initial navigation.
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            switch AuthWebViewNavigationPolicy.decide(
                url: navigationAction.request.url,
                isMainFrame: isMainFrame,
                hasPinnedDashboardOrigin: hasPinnedDashboardOrigin,
                expectedDashboardURL: expectedURL
            ) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            }
        }
    }
}

// Copied from upstream LoginView.swift AuthWebViewNavigationPolicy; keep in sync (PORTING_LEDGER).
// The Mac enum is the frozen copy in ConduitMac/Login/LoginView.swift (decision 2B), which
// has no `isSignedInDashboardPage`, so the member lives here.
extension AuthWebViewNavigationPolicy {
    /// Whether a finished page is the dashboard past its sign-in, where the
    /// session cookie can mint a ticket: on the dashboard's origin and not a
    /// sign-in page there (Hermes' /login, or an auth proxy's own page such
    /// as oauth2-proxy's /oauth2/sign_in), which the user hasn't got past.
    static func isSignedInDashboardPage(_ url: URL?, expectedDashboardURL: URL?) -> Bool {
        guard let url, let expectedDashboardURL,
              ConnectionURLPolicy.originMatches(url, expected: expectedDashboardURL) else { return false }
        return !DashboardSignInRedirect.isSignInPath(url.path)
    }
}

extension WKWebView {
    /// `drawsBackground` is private KVC; skip it if this macOS answers neither
    /// setter (an unknown key raises NSUnknownKeyException). Observed on
    /// macOS 27: only the underscore form responds, and KVC resolves to it.
    func makeBackgroundTransparent() {
        guard responds(to: NSSelectorFromString("setDrawsBackground:"))
            || responds(to: NSSelectorFromString("_setDrawsBackground:")) else { return }
        setValue(false, forKey: "drawsBackground")
    }
}
