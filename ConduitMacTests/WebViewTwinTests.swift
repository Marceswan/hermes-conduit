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
        private var outcome: Result<Void, Error>?

        /// Asked when the page's load begins.
        var onStart: (() -> Void)?

        func attach(to webView: WKWebView) {
            webView.navigationDelegate = self
        }

        func load(_ html: String, in webView: WKWebView) async throws {
            attach(to: webView)
            webView.loadHTMLString(html, baseURL: nil)
            try await finished()
        }

        /// Returns at the next finished load, or at once if it finished already.
        func finished() async throws {
            if let outcome { return try outcome.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        private func complete(_ result: Result<Void, Error>) {
            if let continuation {
                continuation.resume(with: result)
                self.continuation = nil
            } else {
                outcome = result
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onStart?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            complete(.success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            complete(.failure(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            complete(.failure(error))
        }
    }

    /// A sign-in page, loaded in the WebView the twin configures.
    private func signInPage(
        recorder: TicketRecorder,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        headerStore: CustomHeaderStore = CustomHeaderStore(load: { [:] }, persist: { _ in })
    ) async throws -> WKWebView {
        let configuration = AuthWebView.makeConfiguration(
            normalizedBaseURL: "https://dash.example.com",
            cloudflareAccess: cloudflareAccess,
            websiteDataStoreIdentifier: nil,
            ticketHandler: recorder,
            // Not the shared store: it caches what it reads for the whole process.
            headerStore: headerStore
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

    /// A proxy header (not the Cloudflare token) is the same: only the isolated
    /// world may hold a script that carries it.
    func testCustomHeaderScriptIsNotInThePageWorld() async throws {
        let store = CustomHeaderStore(load: { [:] }, persist: { _ in })
        XCTAssertTrue(store.setHeaders([CustomHeader(name: "X-Proxy-Auth", value: "header-secret-value")], forServerURL: "https://dash.example.com"))
        let webView = try await signInPage(recorder: TicketRecorder(), headerStore: store)

        let fetchInPage = try await webView.evaluateJavaScript("Function.prototype.toString.call(window.fetch)", contentWorld: .page) as? String
        XCTAssertTrue(fetchInPage?.contains("[native code]") == true, "the page world's fetch is wrapped: \(fetchInPage ?? "nil")")
        let fetchInConduit = try await webView.evaluateJavaScript("Function.prototype.toString.call(window.fetch)", contentWorld: DashboardScriptWorld.world) as? String
        XCTAssertTrue(fetchInConduit?.contains("[native code]") == false, "the header script is not installed in Conduit's world")
    }

    /// `didFinish` asks the dashboard page for a ticket. The script has to run
    /// where the `ticket` handler is, or the message never arrives and the
    /// sign-in never finishes. (A page with no origin cannot fetch, so the
    /// script posts its failure message: that is enough to show the world.)
    func testTicketRequestRunsInTheDashboardWorld() async throws {
        let recorder = TicketRecorder()
        let webView = try await signInPage(recorder: recorder)

        let arrived = expectation(description: "the ticket script posted")
        recorder.onMessage = { arrived.fulfill() }
        AuthWebView.Coordinator.requestTicket(in: webView)
        await fulfillment(of: [arrived], timeout: 10)
        XCTAssertEqual(recorder.worldNames, [DashboardScriptWorld.world.name])
        XCTAssertTrue(recorder.bodies.first?.contains("hermes-ticket") == true, "\(recorder.bodies)")
    }

    /// Dismantling removes the handler from the world it was added to; a
    /// removal in the page world would leave it in place.
    func testDismantleRemovesTheTicketHandlerFromTheDashboardWorld() async throws {
        let recorder = TicketRecorder()
        let webView = try await signInPage(recorder: recorder)
        let before = try await webView.evaluateJavaScript(Self.ticketHandlerProbe, contentWorld: DashboardScriptWorld.world) as? String
        XCTAssertEqual(before, "object")

        let view = AuthWebView(url: "https://dash.example.com", cloudflareAccess: nil, onTicket: { _, _ in }, onError: { _, _ in })
        AuthWebView.dismantleNSView(webView, coordinator: AuthWebView.Coordinator(parent: view))
        try await LoadWaiter().load("<!doctype html><html><body>again</body></html>", in: webView)
        let after = try await webView.evaluateJavaScript(Self.ticketHandlerProbe, contentWorld: DashboardScriptWorld.world) as? String
        XCTAssertEqual(after, "undefined", "the ticket handler is still installed after the sign-in page went")
    }

    // MARK: - AuthWebView store clear (#788, #1058)

    /// Clearing an identified store creates it on disk, in the real app's
    /// WebKit folder. The two ids are fixed, so every run reuses the same two
    /// directories instead of adding two more.
    private static let clearingDashboard = UUID(uuidString: "7E570001-0000-4000-8000-000000000001")!
    private static let otherClearingDashboard = UUID(uuidString: "7E570002-0000-4000-8000-000000000002")!
    private static let idleDashboard = UUID(uuidString: "7E570003-0000-4000-8000-000000000003")!

    /// A web view on the default store: the load decision depends on the
    /// store id the sign-in is given, not on the store the view uses.
    private func storeClearWebView() -> WKWebView {
        let configuration = AuthWebView.makeConfiguration(
            normalizedBaseURL: "https://dash.example.com",
            cloudflareAccess: nil,
            websiteDataStoreIdentifier: nil,
            ticketHandler: TicketRecorder(),
            headerStore: CustomHeaderStore(load: { [:] }, persist: { _ in })
        )
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
    }

    /// Sign Out clears the dashboard's WebKit store over IPC, so the clear can
    /// outlive the tap. A sign-in page that loads at once can have the session
    /// it mints deleted by that late clear. The page waits for the clear.
    func testSignInPageLoadWaitsForAPendingStoreClear() async throws {
        let id = Self.clearingDashboard
        await DashboardCookiePersistence.awaitPendingStoreClear(for: id)
        let webView = storeClearWebView()
        let waiter = LoadWaiter()
        var clearPendingWhenLoadStarted: Bool?
        waiter.onStart = { clearPendingWhenLoadStarted = DashboardCookiePersistence.hasPendingStoreClear(for: id) }

        DashboardCookiePersistence.scheduleWebKitSessionClear(for: id)
        XCTAssertTrue(DashboardCookiePersistence.hasPendingStoreClear(for: id))
        waiter.attach(to: webView)
        AuthWebView.load(URLRequest(url: URL(string: "about:blank")!), into: webView, websiteDataStoreIdentifier: id)
        // The clear runs on this actor and has had no turn yet.
        XCTAssertFalse(webView.isLoading, "the sign-in page started loading while its store was still clearing")

        try await waiter.finished()
        XCTAssertEqual(clearPendingWhenLoadStarted, false, "the load started after the clear was done")
        XCTAssertFalse(DashboardCookiePersistence.hasPendingStoreClear(for: id))
    }

    func testSignInPageLoadsAtOnceWhenNothingIsClearing() async throws {
        let id = Self.idleDashboard
        XCTAssertFalse(DashboardCookiePersistence.hasPendingStoreClear(for: id))
        let webView = storeClearWebView()
        let waiter = LoadWaiter()
        waiter.attach(to: webView)
        AuthWebView.load(URLRequest(url: URL(string: "about:blank")!), into: webView, websiteDataStoreIdentifier: id)
        XCTAssertTrue(webView.isLoading, "no clear is running, so the load starts in this turn")
        try await waiter.finished()
    }

    /// Another dashboard's clear is no reason to wait.
    func testSignInPageDoesNotWaitForAnotherDashboardsClear() async throws {
        let other = Self.otherClearingDashboard
        await DashboardCookiePersistence.awaitPendingStoreClear(for: other)
        DashboardCookiePersistence.scheduleWebKitSessionClear(for: other)
        let webView = storeClearWebView()
        let waiter = LoadWaiter()
        waiter.attach(to: webView)
        AuthWebView.load(URLRequest(url: URL(string: "about:blank")!), into: webView, websiteDataStoreIdentifier: Self.idleDashboard)
        XCTAssertTrue(webView.isLoading, "the other dashboard's clear is no reason to wait")
        try await waiter.finished()
        await DashboardCookiePersistence.awaitPendingStoreClear(for: other)
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
        for delegate in Self.navigationDelegates {
            XCTAssertTrue(class_conformsToProtocol(delegate.type, WKNavigationDelegate.self), "\(delegate.name) is no WKNavigationDelegate")
            XCTAssertTrue(class_respondsToSelector(delegate.type, Self.policySelector), "WebKit would never ask \(delegate.name) before a navigation")
        }
    }

    /// A new navigation delegate in the app is listed above, so its policy
    /// method is checked too.
    func testNoMacNavigationDelegateIsLeftUnchecked() throws {
        // The image holding the app's code (ConduitMac, or ConduitMac.debug.dylib
        // in a debug build).
        let image = try XCTUnwrap(class_getImageName(DashboardTicketBridge.self))
        var count: UInt32 = 0
        let names = try XCTUnwrap(objc_copyClassNamesForImage(image, &count))
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        let listed = Set(Self.navigationDelegates.map { ObjectIdentifier($0.type) })
        var found = 0
        for index in 0 ..< Int(count) {
            guard let type = objc_getClass(names[index]) as? AnyClass,
                  class_conformsToProtocol(type, WKNavigationDelegate.self) else { continue }
            found += 1
            XCTAssertTrue(listed.contains(ObjectIdentifier(type)), "\(NSStringFromClass(type)) is not listed")
        }
        XCTAssertEqual(found, Self.navigationDelegates.count, "the sweep missed a listed delegate")
    }

    private static let navigationDelegates: [(name: String, type: AnyClass)] = [
        ("AuthWebView.Coordinator", AuthWebView.Coordinator.self),
        ("DashboardTicketBridge", DashboardTicketBridge.self),
        ("MarkupWebView.Coordinator", MarkupWebView.Coordinator.self),
        ("SafeMarkupWebView.Coordinator", SafeMarkupWebView.Coordinator.self),
        ("RemoteImageWebView.Coordinator", RemoteImageWebView.Coordinator.self),
        ("HTMLPreviewWebView.Coordinator", HTMLPreviewWebView.Coordinator.self),
        ("MacHTMLPreviewNavigationDelegate", MacHTMLPreviewNavigationDelegate.self),
    ]

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

    // MARK: - Remote image page

    func testRemoteImageViewLoadsOnlyItsOwnPage() async {
        let coordinator = RemoteImageWebView.Coordinator(height: .constant(0), failed: .constant(false))
        let own = await decidePolicy("https://conduit.local/", type: .other, delegate: coordinator)
        XCTAssertEqual(own, .allow)
        let blank = await decidePolicy("about:blank", type: .other, delegate: coordinator)
        XCTAssertEqual(blank, .allow, "a URL with no host is the page's own load")
        for foreign in ["https://evil.example/image.png", "http://conduit.local.evil.example/", "https://example.com/"] {
            let policy = await decidePolicy(foreign, type: .other, delegate: coordinator)
            XCTAssertEqual(policy, .cancel, foreign)
        }
    }

    // MARK: - HTML preview page

    func testHTMLPreviewIsTransparent() {
        for interactive in [true, false] {
            let webView = HTMLPreviewWebView.makeConfiguredWebView(interactive: interactive)
            XCTAssertEqual(webView.value(forKey: "drawsBackground") as? Bool, false, "interactive \(interactive)")
        }
    }

    /// An inline preview sits in the chat, which scrolls over it.
    func testInlineHTMLPreviewTakesNoHits() {
        let webView = HTMLPreviewWebView.makeConfiguredWebView(interactive: false)
        webView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(webView.hitTest(NSPoint(x: 50, y: 50)))
        XCTAssertFalse(webView.acceptsFirstResponder)
    }

    /// The full-screen page is where the page is touched, scrolled and zoomed.
    func testFullScreenHTMLPreviewTakesHits() {
        let webView = HTMLPreviewWebView.makeConfiguredWebView(interactive: true)
        webView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNotNil(webView.hitTest(NSPoint(x: 50, y: 50)))
        XCTAssertTrue(webView.acceptsFirstResponder)
    }
}
