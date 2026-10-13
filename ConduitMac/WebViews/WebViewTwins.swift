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

// Placeholders until Task 7 makes them real.

struct MarkupWebView: View {
    enum Event: Equatable {
        case height(CGFloat)
        case failed(String?)
    }

    let document: MarkupDocument
    let onEvent: (Event) -> Void
    var body: some View { Color.clear.onAppear { onEvent(.failed("Not yet available on Mac")) } }
}

struct SafeMarkupWebView: View {
    let html: String
    var body: some View { EmptyView() }
}

struct RemoteImageWebView: View {
    let url: String
    @Binding var height: CGFloat
    @Binding var failed: Bool
    var body: some View { Color.clear.onAppear { failed = true } }
}

struct AuthWebView: View {
    let url: String
    let cloudflareAccess: CloudflareAccessCredentials?
    var dashboardIDProvider: (() -> UUID?)? = nil
    var websiteDataStoreIdentifier: UUID? = nil
    let onTicket: (String, String) -> Void
    let onError: (ConnectionFailure, String) -> Void
    var body: some View { EmptyView() }
}
