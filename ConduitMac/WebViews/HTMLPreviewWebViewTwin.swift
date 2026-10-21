// Mac twin of HTMLPreviewBlock.swift HTMLPreviewWebView; keep in sync (PORTING_LEDGER).
import SwiftUI
import WebKit

/// Applies upstream's navigation decision (`HTMLPreviewPage.navigationDecision`)
/// to the page, and opens what it sends out through the R11 path: on the Mac
/// `UIApplication.shared.open` opens a link only when
/// `UIApplication.allowsExternalOpen` (web, mail, System Settings). It has no
/// Mac-only policy.
@MainActor
final class MacHTMLPreviewNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let open: @MainActor (URL) -> Void

    /// `open` is main-actor isolated, as `UIApplication.shared` is.
    init(open: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) }) {
        self.open = open
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let decision = HTMLPreviewPage.navigationDecision(
            url: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            userTapped: navigationAction.navigationType == .linkActivated
        )
        if let url = decision.openExternally { open(url) }
        decisionHandler(decision.allow ? .allow : .cancel)
    }

    /// `target="_blank"` links: no new page, the browser instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let decision = HTMLPreviewPage.navigationDecision(
            url: navigationAction.request.url,
            isMainFrame: true,
            userTapped: navigationAction.navigationType == .linkActivated
        )
        if let url = decision.openExternally { open(url) }
        return nil
    }
}

/// The page an agent's HTML draws in. Nothing it stores outlives it, and
/// its only message to the app is its height.
struct HTMLPreviewWebView: NSViewRepresentable {
    let html: String
    let interactive: Bool
    var onHeight: ((CGFloat) -> Void)? = nil
    var onFailed: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The page view. Mac has no `isUserInteractionEnabled` or `scrollView`:
    /// an inline page sits in the chat, which scrolls over it, so it declines
    /// every hit (and so every scroll-wheel event) and never takes focus. The
    /// full-screen page is touched, scrolled and zoomed.
    final class PreviewWebView: WKWebView {
        var takesInput = true

        override func hitTest(_ point: NSPoint) -> NSView? {
            takesInput ? super.hitTest(point) : nil
        }

        override var acceptsFirstResponder: Bool {
            takesInput && super.acceptsFirstResponder
        }
    }

    /// The transparent page view. The caller adds the delegates.
    static func makeConfiguredWebView(
        interactive: Bool,
        configuration: WKWebViewConfiguration = WKWebViewConfiguration()
    ) -> WKWebView {
        let view = PreviewWebView(frame: .zero, configuration: configuration)
        view.takesInput = interactive
        view.makeBackgroundTransparent()
        return view
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = Self.configuration(
            reportsHeight: onHeight != nil,
            handler: MarkupMessageProxy(context.coordinator)
        )
        let view = Self.makeConfiguredWebView(interactive: interactive, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailed = onFailed
        context.coordinator.load(html, into: view)
        return view
    }

    /// What keeps an agent's script harmless: nothing stored outlives the
    /// page, no window opens on its own, and the only message the app takes
    /// is the height. Tests hold this in place. As upstream's, except
    /// `allowsInlineMediaPlayback`, which macOS does not have (inline is its
    /// default).
    static func configuration(reportsHeight: Bool, handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        for name in HTMLPreviewPage.messageHandlerNames(reportsHeight: reportsHeight) {
            configuration.userContentController.add(handler, name: name)
        }
        return configuration
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onHeight: ((CGFloat) -> Void)?
        var onFailed: (() -> Void)?
        private var html = ""
        private var reloads = MarkupReloads()
        /// Decides every navigation and window request; the web view holds its
        /// delegates weakly, so this object keeps it alive.
        private let navigation: MacHTMLPreviewNavigationDelegate

        /// `navigation` is a seam for tests; a default argument could not make
        /// the main-actor delegate.
        init(navigation: MacHTMLPreviewNavigationDelegate? = nil) {
            self.navigation = navigation ?? MacHTMLPreviewNavigationDelegate()
            super.init()
        }

        /// Loads once per page; SwiftUI calls this on every update.
        func load(_ html: String, into view: WKWebView) {
            guard html != self.html else { return }
            self.html = html
            reloads = MarkupReloads()
            view.loadHTMLString(html, baseURL: HTMLPreviewPage.baseURL)
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
                webView.loadHTMLString(html, baseURL: HTMLPreviewPage.baseURL)
            } else {
                onFailed?()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            navigation.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            navigation.webView(webView, createWebViewWith: configuration, for: navigationAction, windowFeatures: windowFeatures)
        }
    }
}
