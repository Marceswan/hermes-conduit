import AppKit
import SwiftUI
import WebKit

// A link artifact opens in a sheet inside Conduit (D35). Only link artifacts: a link in a message or
// in a preview still goes to the system browser. No upstream counterpart: upstream hands a link
// artifact to the system.

/// What a page in the sheet may do. Link artifacts are gateway-controlled and the page is any page on
/// the web, so this is stricter than `MacOpenURLPolicy`.
enum MacLinkBrowserPolicy {
    enum Navigation: Equatable {
        case allow
        case cancel
        /// Leaves the sheet, through the app's scheme allowlist (R11).
        case openExternally(URL)
    }

    private static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return !(url.host(percentEncoded: true) ?? "").isEmpty
    }

    /// Anything else keeps the app's link policy.
    static func opensInSheet(_ url: URL) -> Bool {
        isWebAddress(url)
    }

    /// The main frame goes only to web addresses, so the bar always names where the page came from. A
    /// frame can also hold what a page makes itself. No page reaches `conduit:`, System Settings, any
    /// other app or a file, even on a click. Mail leaves on a click only.
    static func navigation(to url: URL?, isMainFrame: Bool, userTapped: Bool) -> Navigation {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "mailto" { return userTapped ? .openExternally(url) : .cancel }
        if isWebAddress(url) { return .allow }
        if !isMainFrame, ["about", "data", "blob"].contains(scheme) { return .allow }
        return .cancel
    }

    /// All that a page can change about its own address without a new page.
    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host(percentEncoded: true)?.lowercased() == b.host(percentEncoded: true)?.lowercased()
            && a.port == b.port
    }

    /// The host and a port that is not the default, percent-encoded so that a look-alike letter of
    /// another alphabet cannot draw as the letter it copies. Never the page's title, which the page
    /// chooses.
    static func address(of url: URL) -> String {
        let host = url.host(percentEncoded: true) ?? url.absoluteString
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }
}

/// The web view of the sheet and what the bar shows of it.
@MainActor
final class MacLinkBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// A message over the page.
    struct Failure: Equatable {
        /// Where Open in Browser goes.
        let url: URL
        /// The system's reason; nil for a page or a file the sheet does not show.
        let message: String?
    }

    /// The host of the page on the screen, not of a load in flight: the old page still draws until the
    /// new one arrives, so naming the new host over it would let a slow load borrow a name.
    @Published private(set) var address: String
    @Published private(set) var fullAddress: String
    @Published private(set) var isNotSecure: Bool
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: Failure?
    @Published private var webViewCanGoBack = false

    let webView: WKWebView
    private let requested: URL
    private let open: @MainActor (URL) -> Void
    /// The page on the screen; nil before the first one arrives and after a page dies.
    private var onScreen: URL?
    private var observations: [NSKeyValueObservation] = []

    /// WebKit asks macOS for the camera or the microphone before it asks the delegate, so a page that
    /// calls these raises the system's dialog under Conduit's name, with the words of Conduit's own
    /// photo and voice features (measured on macOS 27.2). The delegate's refusal comes too late to stop
    /// that, so a page does not get them. No public setting does this, so these are WebKit's own, as
    /// `makeBackgroundTransparent` uses one. A test fails if a later macOS drops one.
    static let settingsTurnedOff = ["mediaDevicesEnabled", "speechRecognitionEnabled", "screenCaptureEnabled"]

    /// The second line if a setting goes: it runs before a page's own scripts, but a frame that is
    /// still loading has a blank document it does not reach, and `frames[0]` can read that one.
    static let removesCaptureScript = """
        delete Navigator.prototype.mediaDevices;
        delete Navigator.prototype.getUserMedia;
        delete Navigator.prototype.webkitGetUserMedia;
        delete window.SpeechRecognition;
        delete window.webkitSpeechRecognition;
        """

    /// Nothing outlives the sheet or is shared with the app or another sheet, no message comes back
    /// from a page, and no window or sound starts by itself. The delegate leaves out the file picker
    /// and the alert, confirm and prompt panels, so a page gets none of them. Tests hold this in place.
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        for key in settingsTurnedOff {
            let setter = "_set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
            guard configuration.preferences.responds(to: NSSelectorFromString(setter)) else { continue }
            configuration.preferences.setValue(false, forKey: key)
        }
        configuration.userContentController.addUserScript(
            WKUserScript(source: removesCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        return configuration
    }

    /// `open` is the R11 path. A seam for tests.
    init(url: URL, open: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) }) {
        requested = url
        self.open = open
        address = MacLinkBrowserPolicy.address(of: url)
        fullAddress = url.absoluteString
        isNotSecure = url.scheme?.lowercased() != "https"
        webView = WKWebView(frame: .zero, configuration: Self.configuration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observations = [
            webView.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = view.isLoading
                    self?.followSameDocument(in: view)
                }
            },
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.followSameDocument(in: view) }
            },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.webViewCanGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateSecurity() }
            },
        ]
    }

    func start() {
        isLoading = true
        webView.load(URLRequest(url: requested))
    }

    /// Takes the page down, so a clip it plays stops with the sheet, whoever still holds the view.
    func close() {
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: the bar

    /// Under a message the page is still there, so Back shows it again.
    var canGoBack: Bool {
        webViewCanGoBack || (failure != nil && onScreen != nil)
    }

    func goBack() {
        if failure != nil, onScreen != nil {
            failure = nil
        } else {
            webView.goBack()
        }
    }

    func goForward() {
        failure = nil
        webView.goForward()
    }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else if failure == nil, onScreen != nil {
            webView.reload()
        } else {
            retry()
        }
    }

    /// A load that failed goes again. A page or a file the sheet does not show would only fail the same
    /// way, so the page under the message loads again instead. A page that died has none, so it loads
    /// itself.
    func retry() {
        let target = failure?.message == nil ? (onScreen ?? failure?.url) : failure?.url
        failure = nil
        webView.load(URLRequest(url: target ?? requested))
    }

    func openInBrowser() {
        open(failure?.url ?? onScreen ?? requested)
    }

    private func arrived(in view: WKWebView) {
        guard let url = view.url else { return }
        onScreen = url
        address = MacLinkBrowserPolicy.address(of: url)
        fullAddress = url.absoluteString
        updateSecurity()
    }

    /// `pushState`, `replaceState` and a fragment change the address with no new page and no delegate
    /// call. `url` also changes as a load starts, over the old page, so a change counts only with no load
    /// in flight, and only on the same origin, so the host in the bar never moves here. A change during
    /// a load comes in when the load ends.
    private func followSameDocument(in view: WKWebView) {
        guard !view.isLoading, let onScreen, let url = view.url,
              MacLinkBrowserPolicy.isSameOrigin(url, onScreen) else { return }
        self.onScreen = url
        fullAddress = url.absoluteString
    }

    private func updateSecurity() {
        guard onScreen != nil else { return }
        isNotSecure = !webView.hasOnlySecureContent
    }

    /// A page's script can call `click()` on its own link, and `navigationType` calls that a link too.
    /// Only this says a person did it. No public property does, so this is WebKit's own, as
    /// `settingsTurnedOff` are. If a later macOS drops it, a mail link stays in the page, and a test fails.
    static func isRealClick(_ action: WKNavigationAction) -> Bool {
        let userInitiated = "_isUserInitiated"
        return action.navigationType == .linkActivated
            && action.responds(to: NSSelectorFromString(userInitiated))
            && action.value(forKey: userInitiated) as? Bool == true
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        // Nothing here saves a file: the browser can.
        if navigationAction.shouldPerformDownload {
            let webAddress = url.flatMap { MacLinkBrowserPolicy.opensInSheet($0) ? $0 : nil }
            failure = Failure(url: webAddress ?? onScreen ?? requested, message: nil)
            decisionHandler(.cancel)
            return
        }
        switch MacLinkBrowserPolicy.navigation(to: url,
                                               isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                               userTapped: Self.isRealClick(navigationAction)) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally(let url):
            open(url)
            decisionHandler(.cancel)
        }
    }

    /// What WebKit can draw draws; the rest would be a download, and nothing here saves a file.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
            return
        }
        if navigationResponse.isForMainFrame {
            failure = Failure(url: navigationResponse.response.url ?? onScreen ?? requested, message: nil)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    /// Here the new page has replaced the old one, also on Back, which may come from the page cache.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
        arrived(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        arrived(in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// `WebKitErrorFrameLoadInterruptedByPolicyChange`: a load this delegate cancelled.
    private static let interruptedByPolicy = (domain: "WebKitErrorDomain", code: 102)

    private func failed(_ error: Error) {
        let error = error as NSError
        // Stop, or a newer load that replaced this one.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == Self.interruptedByPolicy.domain, error.code == Self.interruptedByPolicy.code { return }
        let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        failure = Failure(url: url ?? onScreen ?? requested, message: error.localizedDescription)
    }

    /// The page ended. It does not load again by itself: it may end the same way. Nothing draws now, so
    /// Back has no page under the message to show, only the history if there is one.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = Failure(url: onScreen ?? requested, message: nil)
        onScreen = nil
        isLoading = false
    }

    // MARK: WKUIDelegate

    /// A new window has nowhere to go but this sheet. WebKit asks only after a click: a page's script
    /// cannot open one by itself (`javaScriptCanOpenWindowsAutomatically`), and could go to the same
    /// address in this frame anyway.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, MacLinkBrowserPolicy.opensInSheet(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// Conduit has the microphone and the camera for its own use, and a page does not get them. The
    /// second line behind `removesCaptureScript`: this answers only after macOS has been asked.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

/// The bar and the page. The sheet's way out is the X of `SheetCloseButton`, with Esc and a click behind
/// the sheet, whatever the page shows (D34).
struct MacLinkBrowserView: View {
    @ObservedObject var model: MacLinkBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            ZStack {
                MacLinkBrowserWebView(webView: model.webView)
                if let failure = model.failure {
                    message(failure)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MacFilePreviewSheetMarker())
    }

    private var bar: some View {
        ZStack {
            HStack(spacing: 5) {
                if model.isNotSecure {
                    Image(systemName: "lock.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help(AppLocalization.string("Not secure"))
                        .accessibilityLabel(AppLocalization.string("Not secure"))
                }
                Text(verbatim: model.address)
                    .font(.headline)
                    .lineLimit(1)
                    // The end of a host is the part that names its owner.
                    .truncationMode(.head)
                    .help(model.fullAddress)
                    .accessibilityAddTraits(.isHeader)
            }
            // Clear of the buttons on both sides.
            .padding(.horizontal, 112)
            HStack(spacing: 4) {
                button("chevron.left", AppLocalization.string("Back"), action: model.goBack)
                    .disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                button("chevron.right", AppLocalization.string("Go Forward"), action: model.goForward)
                    .disabled(!model.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                button(model.isLoading ? "stop.fill" : "arrow.clockwise",
                       model.isLoading ? AppLocalization.string("Stop") : AppLocalization.string("Reload"),
                       action: model.reloadOrStop)
                    .keyboardShortcut("r", modifiers: .command)
                Spacer()
                button("arrow.up.right.square", AppLocalization.string("Open in Browser"), action: model.openInBrowser)
            }
            .padding(.leading, 10)
            // Clear of the sheet's X.
            .padding(.trailing, 44)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            if model.isLoading {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(.tint)
                        .frame(width: proxy.size.width * max(model.progress, 0.05))
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .conduitGlassControl(cornerRadius: 13)
        .help(label)
        .accessibilityLabel(label)
    }

    private func message(_ failure: MacLinkBrowserModel.Failure) -> some View {
        ContentUnavailableView {
            Label("Couldn’t load page", systemImage: "globe")
        } description: {
            VStack(spacing: 4) {
                // The address, so the button below says where it goes.
                Text(verbatim: MacLinkBrowserPolicy.address(of: failure.url))
                if let reason = failure.message {
                    Text(verbatim: reason)
                } else {
                    Text("This can’t show here. Open it in your browser.")
                }
            }
        } actions: {
            Button("Open in Browser", action: model.openInBrowser)
            Button("Try Again", action: model.retry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MacLinkBrowserWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor
enum MacLinkBrowser {
    /// Wide enough that a site draws its desktop layout, which most sites start at about 1000 pt.
    static let idealWidth: CGFloat = 1024

    /// False when no window can hold the sheet: the caller opens the link another way.
    static func present(_ url: URL) -> Bool {
        present(url, over: MacFilePreviewSheet.host(key: NSApp.keyWindow, main: NSApp.mainWindow))
    }

    @discardableResult
    static func present(_ url: URL, over window: NSWindow?,
                        open: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) }) -> Bool {
        guard var root = window else { return false }
        while let parent = root.sheetParent { root = parent }
        let size = NSSize(width: min(idealWidth, root.frame.width), height: min(MacFormSheet.idealHeight, root.frame.height))
        let model = MacLinkBrowserModel(url: url, open: open)
        MacFilePreviewSheet.begin(over: window, size: size, ended: { model.close() }) { _ in
            MacLinkBrowserView(model: model)
        }
        model.start()
        return true
    }
}
