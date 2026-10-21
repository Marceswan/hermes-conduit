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
}
