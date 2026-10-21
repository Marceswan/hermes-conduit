// Mac twin of HTMLPreviewBlock.swift HTMLPreviewWebView; minimal (R3). Keep in sync (PORTING_LEDGER).
import SwiftUI
import WebKit

/// The page an agent's HTML draws in. Nothing it stores outlives it, and
/// its only message to the app is its height.
struct HTMLPreviewWebView: NSViewRepresentable {
    let html: String
    let interactive: Bool
    var onHeight: ((CGFloat) -> Void)? = nil
    var onFailed: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if onHeight != nil {
            configuration.userContentController.add(
                MarkupMessageProxy(context.coordinator),
                name: HTMLPreviewPage.messageHandlerName
            )
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Transparent page; the Mac view takes no web scrolling (Task 10 completes the twin).
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailed = onFailed
        context.coordinator.load(html, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailed = onFailed
        context.coordinator.load(html, into: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        // A no-op for the full-screen page, which never added it.
        view.configuration.userContentController.removeScriptMessageHandler(forName: HTMLPreviewPage.messageHandlerName)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        coordinator.onHeight = nil
        coordinator.onFailed = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onHeight: ((CGFloat) -> Void)?
        var onFailed: (() -> Void)?
        private var html = ""
        private var reloads = MarkupReloads()

        /// Loads once per page; SwiftUI calls this on every update.
        func load(_ html: String, into view: WKWebView) {
            guard html != self.html else { return }
            self.html = html
            reloads = MarkupReloads()
            view.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let height = body["height"] as? Double,
                  height.isFinite, height > 0 else { return }
            reloads.pageDrew()
            onHeight?(CGFloat(height))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !html.isEmpty else { return }
            if reloads.mayReload() {
                webView.loadHTMLString(html, baseURL: nil)
            } else {
                onFailed?()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let decision = HTMLPreviewPage.navigationDecision(
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                userTapped: navigationAction.navigationType == .linkActivated
            )
            if let url = decision.openExternally { NSWorkspace.shared.open(url) }
            decisionHandler(decision.allow ? .allow : .cancel)
        }

        /// `target="_blank"` links: no new page, the browser instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let decision = HTMLPreviewPage.navigationDecision(
                url: navigationAction.request.url,
                isMainFrame: true,
                userTapped: navigationAction.navigationType == .linkActivated
            )
            if let url = decision.openExternally { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
