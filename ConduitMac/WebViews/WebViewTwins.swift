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
