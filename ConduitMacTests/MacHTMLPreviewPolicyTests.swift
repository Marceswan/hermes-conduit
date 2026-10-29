import WebKit
import XCTest
@testable import ConduitMac

/// What the Mac HTML preview does with a navigation, and what keeps an
/// agent's script harmless. The decision is upstream's
/// (`HTMLPreviewPage.navigationDecision`); these tests drive the Mac
/// delegate that applies it.
@MainActor
final class MacHTMLPreviewPolicyTests: XCTestCase {
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

    // The delegate WebKit really asks is the coordinator, which forwards.
    func testPreviewCoordinatorAppliesTheSameDecision() async {
        let opened = OpenRecorder()
        let coordinator = HTMLPreviewWebView.Coordinator(navigation: MacHTMLPreviewNavigationDelegate(open: opened.record))

        let scripted = await decidePolicy("https://evil.example/x", type: .other, delegate: coordinator)
        XCTAssertEqual(scripted, .cancel)
        let blank = await decidePolicy("about:blank", type: .other, delegate: coordinator)
        XCTAssertEqual(blank, .allow)
        let phone = await decidePolicy("tel:123", type: .linkActivated, delegate: coordinator)
        XCTAssertEqual(phone, .cancel)
        XCTAssertEqual(opened.urls, [])
        let tapped = await decidePolicy("https://example.com", type: .linkActivated, delegate: coordinator)
        XCTAssertEqual(tapped, .cancel)
        XCTAssertEqual(opened.urls, [URL(string: "https://example.com")!])
    }

    func testPreviewCoordinatorNewWindowRequestOpensOnlyATappedWebLink() {
        let opened = OpenRecorder()
        let coordinator = HTMLPreviewWebView.Coordinator(navigation: MacHTMLPreviewNavigationDelegate(open: opened.record))
        func request(_ url: String, _ type: WKNavigationType) -> WKWebView? {
            coordinator.webView(
                WKWebView(),
                createWebViewWith: WKWebViewConfiguration(),
                for: StubNavigationAction(url: url, type: type),
                windowFeatures: WKWindowFeatures()
            )
        }
        XCTAssertNil(request("https://example.com/new", .other))
        XCTAssertNil(request("file:///etc/hosts", .linkActivated))
        XCTAssertEqual(opened.urls, [])
        XCTAssertNil(request("https://example.com/new", .linkActivated))
        XCTAssertEqual(opened.urls, [URL(string: "https://example.com/new")!])
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

    // MARK: - The policy comes first (#1011)

    /// Only HTML whitespace may precede the doctype. Another Unicode space
    /// starts the body, where a policy meta tag would be ignored, so the
    /// policy goes first, once.
    func testUnicodeWhitespaceCannotPrecedeThePolicy() {
        let policyTag = "<meta http-equiv=\"Content-Security-Policy\""
        for prefix in ["\u{00A0}", "\u{2003}", "\u{2028}", " \u{00A0}", "\t\n\u{00A0}"] {
            let document = prefix + "<!doctype html><html><head></head><body><script>1</script></body></html>"
            for presentation in [HTMLPreviewPage.Presentation.inline, .fullScreen] {
                let page = HTMLPreviewPage.framed(document, theme: HTMLPreviewTheme(light: true), presentation: presentation)
                XCTAssertTrue(page.hasPrefix(policyTag), page)
                XCTAssertEqual(page.components(separatedBy: policyTag).count - 1, 1, "the policy is inserted once")
            }
        }
    }

    // A `<head>` after the file's first script, or inside a string or
    // comment, must not let that script run before the policy.
    func testPolicyComesBeforeAnyScriptOfTheFile() {
        let policyTag = "<meta http-equiv=\"Content-Security-Policy\""
        let hostile = [
            "<script>fetch('https://evil.example/')</script><html><head></head><body>chart</body></html>",
            "<script>var s = \"<head>\";</script><body>chart</body>",
            "<!-- <head> --><script>1</script><p>chart</p>",
            "<!doctype html><script>1</script><html><head></head><body>x</body></html>",
        ]
        for document in hostile {
            let page = HTMLPreviewPage.framed(document, theme: HTMLPreviewTheme(light: true), presentation: .inline)
            guard let policy = page.range(of: policyTag), let script = page.range(of: "<script") else {
                XCTFail(page)
                continue
            }
            XCTAssertLessThan(policy.lowerBound, script.lowerBound, page)
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
