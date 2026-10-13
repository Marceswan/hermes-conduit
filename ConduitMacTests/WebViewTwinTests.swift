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
}
