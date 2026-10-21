import ObjectiveC
import XCTest
import WebKit
@testable import ConduitMac

@MainActor
final class WebViewTwinTests: XCTestCase {
    func testMarkupWebViewIsTransparent() {
        let webView = MarkupWebView.makeConfiguredWebView()
        XCTAssertEqual(webView.value(forKey: "drawsBackground") as? Bool, false)
    }

    func testMarkupWebViewTakesNoHits() {
        let webView = MarkupWebView.makeConfiguredWebView()
        webView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(webView.hitTest(NSPoint(x: 50, y: 50)))
    }

    func testAuthWebViewDashboardRequestTargetsLogin() throws {
        let request = try AuthWebView.dashboardRequest(normalizedBaseURL: "https://dash.example.com", cloudflareAccess: nil)
        XCTAssertEqual(request.url?.path, "/login")
    }

    // MARK: - AuthWebView script world (#774)

    /// Counts what the page posts to the `ticket` handler, and from which
    /// world.
    private final class TicketRecorder: NSObject, WKScriptMessageHandler {
        private(set) var worldNames: [String?] = []
        private(set) var bodies: [String] = []
        var onMessage: (() -> Void)?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            worldNames.append(message.world.name)
            bodies.append(message.body as? String ?? "")
            onMessage?()
        }
    }

    /// Resolves when a page has loaded.
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?

        func load(_ html: String, in webView: WKWebView) async throws {
            webView.navigationDelegate = self
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    /// A sign-in page, loaded in the WebView the twin configures.
    private func signInPage(
        recorder: TicketRecorder,
        cloudflareAccess: CloudflareAccessCredentials? = nil
    ) async throws -> WKWebView {
        let configuration = AuthWebView.makeConfiguration(
            normalizedBaseURL: "https://dash.example.com",
            cloudflareAccess: cloudflareAccess,
            websiteDataStoreIdentifier: nil,
            ticketHandler: recorder
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let waiter = LoadWaiter()
        try await waiter.load("<!doctype html><html><body>sign in</body></html>", in: webView)
        return webView
    }

    private static let ticketHandlerProbe = "String(typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ticket))"

    /// The dashboard page's own scripts run in the page world. They must not
    /// see the handler that carries the session ticket, or post a forged one.
    func testTicketHandlerIsInvisibleToThePageWorld() async throws {
        let recorder = TicketRecorder()
        let webView = try await signInPage(recorder: recorder)

        let seenByPage = try await webView.evaluateJavaScript(Self.ticketHandlerProbe, contentWorld: .page) as? String
        XCTAssertEqual(seenByPage, "undefined", "the dashboard page can reach the ticket handler")
        let seenByConduit = try await webView.evaluateJavaScript(Self.ticketHandlerProbe, contentWorld: DashboardScriptWorld.world) as? String
        XCTAssertEqual(seenByConduit, "object", "Conduit's own script world must reach the ticket handler, or sign-in never completes")
    }

    func testTicketPostFromTheDashboardWorldReachesTheHandlerAndOneFromThePageDoesNot() async throws {
        let recorder = TicketRecorder()
        let webView = try await signInPage(recorder: recorder)

        let arrived = expectation(description: "ticket message from Conduit's world")
        recorder.onMessage = { arrived.fulfill() }
        let forged = try await webView.evaluateJavaScript(
            "(function(){ try { window.webkit.messageHandlers.ticket.postMessage('forged'); return 'posted'; } catch (e) { return 'blocked'; } })()",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(forged, "blocked", "a page script can post a forged ticket")
        _ = try await webView.evaluateJavaScript(
            "window.webkit.messageHandlers.ticket.postMessage('genuine'); true;",
            contentWorld: DashboardScriptWorld.world
        )
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(recorder.bodies, ["genuine"])
        XCTAssertEqual(recorder.worldNames, [DashboardScriptWorld.world.name])
    }

    /// The Cloudflare Access script wraps `fetch` with the service token. In
    /// the page world, a page script could read the token back out of it.
    func testProxyHeaderScriptsAreNotInTheTicketPageWorld() async throws {
        let recorder = TicketRecorder()
        let credentials = CloudflareAccessCredentials(clientID: "client-id.access", clientSecret: "secret-value")
        let webView = try await signInPage(recorder: recorder, cloudflareAccess: credentials)

        let fetchInPage = try await webView.evaluateJavaScript("Function.prototype.toString.call(window.fetch)", contentWorld: .page) as? String
        XCTAssertTrue(fetchInPage?.contains("[native code]") == true, "the page world's fetch is wrapped: \(fetchInPage ?? "nil")")
        XCTAssertFalse(fetchInPage?.contains("secret-value") == true)
        let fetchInConduit = try await webView.evaluateJavaScript("Function.prototype.toString.call(window.fetch)", contentWorld: DashboardScriptWorld.world) as? String
        XCTAssertTrue(fetchInConduit?.contains("[native code]") == false, "the header script is not installed in Conduit's world, so sign-in loses the proxy header")
    }

    // MARK: - AuthWebView signed-in detection

    /// Copy of upstream `AuthWebViewNavigationPolicyTests`. An auth proxy's
    /// own sign-in page is not the dashboard: minting a ticket from it
    /// reports a session-ticket failure.
    func testOnlyTheDashboardPastItsSignInPagesCountsAsSignedIn() {
        let dashboard = URL(string: "https://hermes.example")!
        for signedIn in ["https://hermes.example/", "https://hermes.example/chat", "https://hermes.example/docs/login-guide"] {
            XCTAssertTrue(AuthWebViewNavigationPolicy.isSignedInDashboardPage(URL(string: signedIn), expectedDashboardURL: dashboard), signedIn)
        }
        for notYet in [
            // Hermes' own sign-in, and an auth proxy's page on the same origin.
            "https://hermes.example/login?next=%2F",
            "https://hermes.example/oauth2/sign_in?rd=%2Flogin",
            "https://hermes.example/oauth2/start?rd=%2F",
            // The identity provider's page.
            "https://sso.example/authorize",
        ] {
            XCTAssertFalse(AuthWebViewNavigationPolicy.isSignedInDashboardPage(URL(string: notYet), expectedDashboardURL: dashboard), notYet)
        }
        XCTAssertFalse(AuthWebViewNavigationPolicy.isSignedInDashboardPage(nil, expectedDashboardURL: dashboard))
        XCTAssertFalse(AuthWebViewNavigationPolicy.isSignedInDashboardPage(URL(string: "https://hermes.example/chat"), expectedDashboardURL: nil))
    }

    // MARK: - Navigation policy selector (#832)

    /// The selector WebKit asks a delegate about before a navigation.
    private static let policySelector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")

    /// Mac copy of upstream `WebKitNavigationPolicyConformanceTests`. A
    /// policy method that only nearly matches `WKNavigationDelegate` (a
    /// decision handler without `@MainActor @Sendable`, under strict
    /// concurrency) is not exposed to Objective-C: WebKit never calls it, and
    /// every navigation it would cancel is allowed. The default checking
    /// still matches a plain closure, so this pins the selector and the list.
    func testEveryMacNavigationDelegateAnswersThePolicySelector() {
        let delegates: [(name: String, type: AnyClass)] = [
            ("AuthWebView.Coordinator", AuthWebView.Coordinator.self),
            ("DashboardTicketBridge", DashboardTicketBridge.self),
            ("MarkupWebView.Coordinator", MarkupWebView.Coordinator.self),
            ("SafeMarkupWebView.Coordinator", SafeMarkupWebView.Coordinator.self),
        ]
        for delegate in delegates {
            XCTAssertTrue(class_conformsToProtocol(delegate.type, WKNavigationDelegate.self), "\(delegate.name) is no WKNavigationDelegate")
            XCTAssertTrue(class_respondsToSelector(delegate.type, Self.policySelector), "WebKit would never ask \(delegate.name) before a navigation")
        }
    }

    func testAuthWebViewCoordinatorAnswersWithItsNavigationPolicy() async {
        let view = AuthWebView(
            url: "https://hermes.example",
            cloudflareAccess: nil,
            onTicket: { _, _ in },
            onError: { _, _ in }
        )
        let coordinator = AuthWebView.Coordinator(parent: view)
        // Before the dashboard pins, a sign-in may cross to its identity provider.
        let provider = await decidePolicy("https://sso.example/authorize", type: .other, delegate: coordinator)
        XCTAssertEqual(provider, .allow)
        let local = await decidePolicy("file:///etc/hosts", type: .other, delegate: coordinator)
        XCTAssertEqual(local, .cancel)
        let script = await decidePolicy("javascript:alert(1)", type: .other, delegate: coordinator)
        XCTAssertEqual(script, .cancel)
    }

    // MARK: - Markup pages

    /// The page a diagram or formula draws in loads itself and the pinned
    /// renderer files only.
    func testMarkupCoordinatorsCancelForeignNavigationAndAllowTheirOwnPage() async {
        let inline = MarkupWebView.Coordinator()
        let safe = SafeMarkupWebView.Coordinator(html: "<p>x</p>")
        for delegate in [inline, safe] as [WKNavigationDelegate] {
            let foreign = await decidePolicy("https://evil.example/", type: .other, delegate: delegate)
            XCTAssertEqual(foreign, .cancel)
            let ownPage = await decidePolicy("https://conduit.local/", type: .other, delegate: delegate)
            XCTAssertEqual(ownPage, .allow)
            let blank = await decidePolicy("about:blank", type: .other, delegate: delegate)
            XCTAssertEqual(blank, .allow)
            let tapped = await decidePolicy("https://example.com/", type: .linkActivated, delegate: delegate)
            XCTAssertEqual(tapped, .cancel, "a link in a diagram stays out")
        }
    }

    /// A diagram or formula runs a CDN script. Pinned by version and hash,
    /// a file the CDN serves changed does not run (#777).
    func testMermaidAndKatexPagesCarryPinnedIntegrityTags() {
        let diagram = MarkupHTML.page(MarkupDocument(kind: .mermaid, source: "graph TD; A-->B", light: true, fontSize: 0), presentation: .inline)
        XCTAssertTrue(diagram.contains(MarkupHTML.mermaidScript.scriptTag))
        let formula = MarkupHTML.page(MarkupDocument(kind: .math, source: "E = mc^2", light: false, fontSize: 17), presentation: .fullScreen)
        XCTAssertTrue(formula.contains(MarkupHTML.katexScript.scriptTag))
        XCTAssertTrue(formula.contains(MarkupHTML.katexStylesheet.stylesheetTag))
        for resource in [MarkupHTML.mermaidScript, MarkupHTML.katexScript, MarkupHTML.katexStylesheet] {
            XCTAssertTrue(resource.url.hasPrefix("https://cdn.jsdelivr.net/npm/"), resource.url)
            XCTAssertTrue(resource.url.contains("@"), "no version in \(resource.url)")
            XCTAssertTrue(resource.integrity.hasPrefix("sha384-"), resource.url)
        }
        XCTAssertTrue(MarkupHTML.mermaidScript.scriptTag.contains(#"crossorigin="anonymous""#))
        XCTAssertTrue(MarkupHTML.katexStylesheet.stylesheetTag.contains(#"crossorigin="anonymous""#))
    }

    func testRendererNavigationIsLimitedToThePinnedFiles() {
        let fonts = URL(string: MarkupHTML.katexStylesheet.url)!.deletingLastPathComponent().appendingPathComponent("fonts/KaTeX_Main-Regular.woff2")
        for allowed in [MarkupHTML.mermaidScript.url, MarkupHTML.katexScript.url, MarkupHTML.katexStylesheet.url, fonts.absoluteString, "https://conduit.local/", "about:blank"] {
            XCTAssertTrue(MarkupHTML.allowsNavigation(to: URL(string: allowed)), allowed)
        }
        for refused in [
            // Another version or file on the same CDN, so no reference loads around the hashes.
            "https://cdn.jsdelivr.net/npm/mermaid@11.15.0/dist/mermaid.min.js",
            "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/other.js",
            "https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.js",
            "https://cdn.jsdelivr.net/npm/evil@1.0.0/index.js",
            // Another host, a plain-HTTP copy, and the app's own host beyond its root.
            "https://evil.example/npm/mermaid@11.16.0/dist/mermaid.min.js",
            MarkupHTML.mermaidScript.url.replacingOccurrences(of: "https://", with: "http://"),
            "https://conduit.local/x",
            "javascript:alert(1)",
            "data:text/html,<p>x</p>",
            "file:///etc/hosts",
            "about:srcdoc",
        ] {
            XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: refused)), refused)
        }
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: nil))
    }
}
