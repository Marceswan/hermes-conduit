import WebKit
import XCTest
@testable import ConduitMac

/// What the Mac HTML preview does with a navigation, and what keeps an
/// agent's script harmless. The decision is upstream's
/// (`HTMLPreviewPage.navigationDecision`); these tests drive the Mac
/// delegate that applies it.
@MainActor
final class MacHTMLPreviewPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        isolateKeychain()
    }

    /// Stands in for the system opener, so a test never launches a browser.
    private final class OpenRecorder {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    private func decide(
        _ url: String,
        type: WKNavigationType,
        isMainFrame: Bool? = nil,
        delegate: MacHTMLPreviewNavigationDelegate
    ) async -> WKNavigationActionPolicy {
        await decidePolicy(url, type: type, isMainFrame: isMainFrame, delegate: delegate)
    }

    // MARK: - Navigation

    func testScriptedRemoteLoadIsCancelled() async {
        let opened = OpenRecorder()
        let policy = await decide("https://evil.example/x", type: .other, delegate: MacHTMLPreviewNavigationDelegate(open: opened.record))
        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(opened.urls, [], "a script moving the page away goes nowhere")
    }

    func testBlankDocumentLoads() async {
        let policy = await decide("about:blank", type: .other, delegate: MacHTMLPreviewNavigationDelegate())
        XCTAssertEqual(policy, .allow)
    }

    func testUserClickOnWebLinkIsCancelledInPlaceAndOpensExternally() async {
        let opened = OpenRecorder()
        let policy = await decide("https://example.com", type: .linkActivated, delegate: MacHTMLPreviewNavigationDelegate(open: opened.record))
        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(opened.urls, [URL(string: "https://example.com")!])
    }

    func testOtherSchemesNeverOpen() async {
        for url in ["tel:123", "file:///etc/hosts", "conduit://chat/abc", "mailto:someone@example.com"] {
            let opened = OpenRecorder()
            let policy = await decide(url, type: .linkActivated, delegate: MacHTMLPreviewNavigationDelegate(open: opened.record))
            XCTAssertEqual(policy, .cancel, url)
            XCTAssertEqual(opened.urls, [], url)
        }
    }

    func testFramedLoadIsCancelledEvenWhenTapped() async {
        let opened = OpenRecorder()
        let policy = await decide(
            "https://example.com/details",
            type: .linkActivated,
            isMainFrame: false,
            delegate: MacHTMLPreviewNavigationDelegate(open: opened.record)
        )
        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(opened.urls, [])
    }

    func testNewWindowRequestReturnsNilAndOpensOnlyATappedWebLink() {
        let cases: [(url: String, type: WKNavigationType, opens: Bool)] = [
            ("https://example.com/new", .linkActivated, true),
            ("https://example.com/new", .other, false),
            ("tel:123", .linkActivated, false),
            ("file:///etc/hosts", .linkActivated, false),
        ]
        for testCase in cases {
            let opened = OpenRecorder()
            let delegate = MacHTMLPreviewNavigationDelegate(open: opened.record)
            let created = delegate.webView(
                WKWebView(),
                createWebViewWith: WKWebViewConfiguration(),
                for: StubNavigationAction(url: testCase.url, type: testCase.type),
                windowFeatures: WKWindowFeatures()
            )
            XCTAssertNil(created, testCase.url)
            XCTAssertEqual(opened.urls, testCase.opens ? [URL(string: testCase.url)!] : [], testCase.url)
        }
    }

    // MARK: - The page

    func testFramedDocumentCarriesUpstreamCSP() {
        XCTAssertTrue(HTMLPreviewPage.contentSecurityPolicy.contains("connect-src data: blob:"))
        let html = HTMLPreviewPage.framed("<p>x</p>", theme: HTMLPreviewTheme(light: true), presentation: .inline)
        XCTAssertTrue(html.contains(#"<meta http-equiv="Content-Security-Policy" content="\#(HTMLPreviewPage.contentSecurityPolicy)">"#))
    }

    func testPageCannotSendDataOff() {
        let policy = HTMLPreviewPage.contentSecurityPolicy
        XCTAssertTrue(policy.contains("connect-src data: blob:"))
        XCTAssertTrue(policy.contains("frame-src 'none'"))
        XCTAssertTrue(policy.contains("worker-src 'none'"))
        XCTAssertTrue(policy.contains("form-action 'none'"))
        XCTAssertTrue(policy.contains("object-src 'none'"))
        XCTAssertFalse(policy.contains("https:") || policy.contains("http:") || policy.contains("*"))
        for presentation in [HTMLPreviewPage.Presentation.inline, .fullScreen] {
            let page = HTMLPreviewPage.framed("<html><head></head><body>x</body></html>", theme: HTMLPreviewTheme(light: true), presentation: presentation)
            XCTAssertTrue(page.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"))
        }
    }

    // MARK: - What keeps an agent's script harmless (#770)

    // The page runs whatever script the agent sent. That is only safe while
    // these hold; loosening one turns the preview into a way into the app.
    func testWebViewKeepsNothingAndOnlyHearsTheHeight() {
        final class Handler: NSObject, WKScriptMessageHandler {
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        for reportsHeight in [true, false] {
            let configuration = HTMLPreviewWebView.configuration(reportsHeight: reportsHeight, handler: Handler())
            XCTAssertFalse(configuration.websiteDataStore.isPersistent)
            XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
        }
        XCTAssertEqual(HTMLPreviewPage.messageHandlerNames(reportsHeight: true), [HTMLPreviewPage.messageHandlerName])
        XCTAssertEqual(HTMLPreviewPage.messageHandlerNames(reportsHeight: false), [])
        XCTAssertNil(HTMLPreviewPage.baseURL, "a file: or https: base gives the page an origin to act from")
    }
}
