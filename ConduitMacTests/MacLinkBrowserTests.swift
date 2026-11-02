import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ConduitMac

/// What a page in the link browser may do (D35). The rules are pure; the live tests load real pages
/// from a loopback server, and click them with real mouse events, because WebKit decides what a
/// click is.
@MainActor
final class MacLinkBrowserPolicyTests: XCTestCase {
    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    func testOnlyAWebAddressWithAHostOpensInTheSheet() throws {
        for good in ["https://curate.example/r", "http://192.168.1.4:8080/x", "HTTPS://curate.example"] {
            XCTAssertTrue(MacLinkBrowserPolicy.opensInSheet(try url(good)), good)
        }
        for other in ["mailto:a@b.example", "conduit://settings/general", "file:///etc/hosts", "data:text/html,x",
                      "x-apple.systempreferences:com.apple.preference.security", "https:///no-host", "about:blank"] {
            XCTAssertFalse(MacLinkBrowserPolicy.opensInSheet(try url(other)), other)
        }
    }

    func testTheMainFrameGoesOnlyToWebAddresses() throws {
        for good in ["https://curate.example/r", "http://192.168.1.4/x"] {
            // A redirect or a page's own script is not a click.
            for tapped in [true, false] {
                XCTAssertEqual(MacLinkBrowserPolicy.navigation(to: try url(good), isMainFrame: true, userTapped: tapped),
                               .allow, good)
            }
        }
        for bad in ["file:///etc/hosts", "data:text/html,x", "blob:https://a.example/1", "about:blank",
                    "conduit://settings/general", "conduit://session/abc", "x-apple.systempreferences:com.apple",
                    "javascript:alert(1)", "slack://open", "https:///no-host"] {
            for tapped in [true, false] {
                XCTAssertEqual(MacLinkBrowserPolicy.navigation(to: try url(bad), isMainFrame: true, userTapped: tapped),
                               .cancel, "\(bad) tapped: \(tapped)")
            }
        }
        XCTAssertEqual(MacLinkBrowserPolicy.navigation(to: nil, isMainFrame: true, userTapped: true), .cancel)
    }

    func testOnlyAMailLinkTheUserClickedLeavesTheSheet() throws {
        let mail = try url("mailto:a@b.example")
        for isMainFrame in [true, false] {
            XCTAssertEqual(MacLinkBrowserPolicy.navigation(to: mail, isMainFrame: isMainFrame, userTapped: true),
                           .openExternally(mail))
            XCTAssertEqual(MacLinkBrowserPolicy.navigation(to: mail, isMainFrame: isMainFrame, userTapped: false),
                           .cancel, "a script does not open the mail app")
        }
    }

    func testAFrameLoadsWebContentButNeverAnAppOrAFile() throws {
        for good in ["https://a.example/f", "http://a.example/f", "about:blank", "about:srcdoc", "data:text/html,x",
                     "blob:https://a.example/1"] {
            XCTAssertEqual(MacLinkBrowserPolicy.navigation(to: try url(good), isMainFrame: false, userTapped: false),
                           .allow, good)
        }
        for bad in ["file:///etc/hosts", "conduit://settings/general", "slack://open", "x-apple.systempreferences:a"] {
            for tapped in [true, false] {
                XCTAssertEqual(MacLinkBrowserPolicy.navigation(to: try url(bad), isMainFrame: false, userTapped: tapped),
                               .cancel, bad)
            }
        }
    }

    func testTheAddressIsTheRealHostAndItsPort() throws {
        XCTAssertEqual(MacLinkBrowserPolicy.address(of: try url("https://bank.example/login?a=1")), "bank.example")
        XCTAssertEqual(MacLinkBrowserPolicy.address(of: try url("https://bank.example:8443/")), "bank.example:8443")
        XCTAssertEqual(MacLinkBrowserPolicy.address(of: try url("https://bank.example@evil.example/")), "evil.example",
                       "the name before the @ is not the host")
        XCTAssertEqual(MacLinkBrowserPolicy.address(of: try url("https://xn--pple-43d.example/")), "xn--pple-43d.example",
                       "a look-alike name stays in the form that shows it")
        let unicode = MacLinkBrowserPolicy.address(of: try url("https://\u{0430}pple.example/"))
        XCTAssertFalse(unicode.contains("\u{0430}"), "a Cyrillic letter never draws as a Latin one: \(unicode)")
    }

    func testASameOriginIsTheSameSchemeHostAndPort() throws {
        let page = try url("https://a.example:8443/x")
        XCTAssertTrue(MacLinkBrowserPolicy.isSameOrigin(page, try url("https://A.example:8443/y?z=1#f")))
        for other in ["http://a.example:8443/x", "https://b.example:8443/x", "https://a.example/x",
                      "https://a.example.evil.example:8443/x"] {
            XCTAssertFalse(MacLinkBrowserPolicy.isSameOrigin(page, try url(other)), other)
        }
    }

    func testTheConfigurationKeepsNothingAndGivesThePageNoWayIntoTheApp() {
        let configuration = MacLinkBrowserModel.configuration()
        XCTAssertFalse(configuration.websiteDataStore.isPersistent, "no cookie or login outlives the sheet")
        XCTAssertFalse(configuration.websiteDataStore === WKWebsiteDataStore.default(), "and none is shared with the app")
        XCTAssertFalse(MacLinkBrowserModel.configuration().websiteDataStore === configuration.websiteDataStore,
                       "or with another sheet")
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all, "no sound starts by itself")
        XCTAssertTrue(configuration.preferences.isFraudulentWebsiteWarningEnabled)
        for key in MacLinkBrowserModel.settingsTurnedOff {
            XCTAssertEqual(configuration.preferences.value(forKey: key) as? Bool, false,
                           "\(key): the setting a frame's blank document depends on")
        }
        let scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.map(\.source), [MacLinkBrowserModel.removesCaptureScript], "and only this one of the app's runs in a page")
        XCTAssertEqual(scripts.first?.injectionTime, .atDocumentStart, "before the page's own scripts")
        XCTAssertEqual(scripts.first?.isForMainFrameOnly, false, "and in its frames")
    }
}

@MainActor
final class MacLinkBrowserLiveTests: XCTestCase {
    private var server: LoopbackHTTPServer!
    private var windows: [NSWindow] = []
    private var opened: [URL] = []

    nonisolated private static func html(_ body: String, title: String = "Page") -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")],
                             body: Data("<!doctype html><title>\(title)</title><body style='margin:0'>\(body)".utf8))
    }

    /// A row of 200 x 60 links, so that a real click has somewhere to land.
    nonisolated private static let link = "style='display:block;width:200px;height:60px;background:#ccc'"

    override func setUp() async throws {
        opened = []
        server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/":
                return MacLinkBrowserLiveTests.html("""
                <a id=second \(MacLinkBrowserLiveTests.link) href='/second'>second</a>
                <a id=blank \(MacLinkBrowserLiveTests.link) href='/second' target='_blank'>blank</a>
                <a id=mail \(MacLinkBrowserLiveTests.link) href='mailto:a@b.example'>mail</a>
                <a id=app \(MacLinkBrowserLiveTests.link) href='conduit://settings/general'>app</a>
                <a id=save \(MacLinkBrowserLiveTests.link) href='/second' download='s.html'>save</a>
                """)
            case "/second":
                return MacLinkBrowserLiveTests.html("<p id=here>second page</p>", title: "Second")
            case "/clicks-mail-by-itself":
                // In the page's own scripts: `js` runs as a user gesture, so it cannot show this.
                return MacLinkBrowserLiveTests.html("""
                <a id=mail href='mailto:a@b.example'>mail</a>
                <script>
                onload = () => {
                    document.getElementById('mail').click();
                    setTimeout(() => { document.getElementById('mail').click(); document.title = 'clicked'; }, 100);
                };
                </script>
                """)
            case "/slow":
                Thread.sleep(forTimeInterval: 1.5)
                return MacLinkBrowserLiveTests.html("<p>slow page</p>", title: "Slow")
            case "/file":
                return LoopbackHTTPResponse(status: 200, headers: [("Content-Type", "application/octet-stream"),
                                                                   ("Content-Disposition", "attachment; filename=x.bin")],
                                            body: Data([0, 1, 2]))
            default:
                return .status(404)
            }
        }
    }

    override func tearDown() async throws {
        server.stop()
        for window in windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
            HostedTestSupport.tearDown(window)
        }
        windows = []
    }

    private func address(_ path: String = "/", host: String = "127.0.0.1") throws -> URL {
        try XCTUnwrap(URL(string: "http://\(host):\(server.port)\(path)"))
    }

    /// A model whose view is in a window, as a real click needs.
    private func browser(_ path: String = "/") throws -> MacLinkBrowserModel {
        let model = MacLinkBrowserModel(url: try address(path), open: { [unowned self] in self.opened.append($0) })
        let window = HostedTestSupport.host(MacLinkBrowserView(model: model), size: NSSize(width: 800, height: 600))
        window.makeKey()
        windows.append(window)
        model.start()
        return model
    }

    private func loaded(_ model: MacLinkBrowserModel) -> Bool {
        HostedTestSupport.waitUntil(timeout: 10) { !model.isLoading && model.webView.url != nil }
    }

    /// Runs `body` as the body of an async function in the page. Not an async test: spinning the run
    /// loop inside one blocks the main queue, and WebKit's callbacks with it.
    @discardableResult
    private func js(_ body: String, arguments: [String: Any] = [:], in view: WKWebView) throws -> Any? {
        var result: Result<Any, Error>?
        view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result = $0 }
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 15) { result != nil }, "no answer from the page: \(body)")
        return try result?.get()
    }

    /// A real mouse click in the middle of an element.
    private func click(_ id: String, in model: MacLinkBrowserModel) throws {
        let rect = try js("const r = document.getElementById(id).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2];",
                          arguments: ["id": id], in: model.webView) as? [Double]
        let point = try XCTUnwrap(rect)
        let view = model.webView
        let window = try XCTUnwrap(view.window)
        let location = view.convert(NSPoint(x: point[0], y: point[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private func path(of model: MacLinkBrowserModel) -> String? { model.webView.url?.path }

    // MARK: pages

    func testItLoadsThePageAndShowsItsHostAndThatItIsNotSecure() throws {
        let model = try browser()
        XCTAssertEqual(model.address, "127.0.0.1:\(server.port)", "the host shows before anything draws")
        XCTAssertTrue(loaded(model))
        XCTAssertEqual(model.address, "127.0.0.1:\(server.port)")
        XCTAssertTrue(model.isNotSecure, "plain http")
        XCTAssertNil(model.failure)
    }

    func testTheAddressChangesOnlyWhenTheNewPageHasArrived() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        let target = try address("/slow", host: "localhost").absoluteString
        try js("location.href = '\(target)';", in: model.webView)
        HostedTestSupport.settle(0.5)
        XCTAssertEqual(model.address, "127.0.0.1:\(server.port)",
                       "the old page still draws, so the bar must not name the new host over it")
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.address == "localhost:\(self.server.port)" })
    }

    func testAClickedLinkLoadsAndBackAndForwardWork() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        XCTAssertFalse(model.canGoBack)
        try click("second", in: model)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { self.path(of: model) == "/second" && !model.isLoading })
        XCTAssertTrue(model.canGoBack)
        model.goBack()
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { self.path(of: model) == "/" && model.canGoForward })
        model.goForward()
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { self.path(of: model) == "/second" })
        XCTAssertTrue(opened.isEmpty)
    }

    func testANewWindowLinkLoadsInTheSheet() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        try click("blank", in: model)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { self.path(of: model) == "/second" }, "\(String(describing: model.webView.url))")
        XCTAssertTrue(opened.isEmpty, "the browser stays out of it")
    }

    func testAClickedMailLinkGoesToTheSystemAndThePageStays() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        try click("mail", in: model)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { !self.opened.isEmpty })
        XCTAssertEqual(opened, [try XCTUnwrap(URL(string: "mailto:a@b.example"))])
        XCTAssertEqual(path(of: model), "/")
    }

    func testAPageCannotClickItsOwnMailLink() throws {
        let model = try browser("/clicks-mail-by-itself")
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.webView.title == "clicked" },
                      "the page's scripts ran: \(String(describing: model.webView.title))")
        HostedTestSupport.settle(0.5)
        XCTAssertTrue(opened.isEmpty, "the mail app opened with no person: \(opened)")
    }

    func testAPageCannotReachAnAppOrAFileEvenOnAClick() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        try click("app", in: model)
        for script in ["location.href = 'conduit://settings/general'", "location.href = 'file:///etc/hosts'",
                       "location.href = 'x-apple.systempreferences:com.apple.preference.security'",
                       "location.href = 'mailto:a@b.example'", "location.href = 'data:text/html,spoof'",
                       "const f = document.createElement('iframe'); f.src = 'conduit://settings/general'; document.body.append(f)"] {
            try js(script, in: model.webView)
        }
        HostedTestSupport.settle(0.5)
        XCTAssertTrue(opened.isEmpty, "\(opened)")
        XCTAssertEqual(path(of: model), "/")
        XCTAssertEqual(model.address, "127.0.0.1:\(server.port)")
    }

    /// Reads what a page can reach and never calls it: a call raises the real system dialog for the
    /// real app when the camera has not been answered yet, and WebKit asks macOS before the delegate.
    private static let captureSurface = """
        (w) => ['navigator.mediaDevices:' + typeof w.navigator.mediaDevices,
                'navigator.getUserMedia:' + typeof w.navigator.getUserMedia,
                'navigator.webkitGetUserMedia:' + typeof w.navigator.webkitGetUserMedia,
                'SpeechRecognition:' + typeof w.SpeechRecognition,
                'webkitSpeechRecognition:' + typeof w.webkitSpeechRecognition]
        """

    private static let nothingToCall = ["navigator.mediaDevices:undefined", "navigator.getUserMedia:undefined",
                                        "navigator.webkitGetUserMedia:undefined", "SpeechRecognition:undefined",
                                        "webkitSpeechRecognition:undefined"]

    func testAPageHasNothingToCallForTheCameraOrTheMicrophone() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        let surface = try js("return (\(Self.captureSurface))(window);", in: model.webView) as? [String]
        XCTAssertEqual(surface, Self.nothingToCall)
    }

    func testAFrameHasNothingToCallEither() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        // A new frame has a new `navigator`. Read at once, then again when each frame has loaded.
        let makers: [String: String] = [
            "empty": "const f = document.createElement('iframe');",
            "srcdoc": "const f = document.createElement('iframe'); f.srcdoc = '<p>x</p>';",
            "data": "const f = document.createElement('iframe'); f.src = 'data:text/html,<p>x</p>';",
            "blob": "const f = document.createElement('iframe'); f.src = URL.createObjectURL(new Blob(['<p>x</p>'], {type: 'text/html'}));",
            "same origin": "const f = document.createElement('iframe'); f.src = '/second';",
            "object": "const f = document.createElement('object'); f.data = 'about:blank';",
        ]
        for (name, maker) in makers {
            let result = try js("""
                \(maker)
                document.body.append(f);
                const read = \(Self.captureSurface);
                const first = f.contentWindow ? read(f.contentWindow) : null;
                await new Promise(done => setTimeout(done, 300));
                let later = null;
                try { later = f.contentWindow ? read(f.contentWindow) : null; } catch (e) { later = 'cross-origin'; }
                return {first: first, later: later};
                """, in: model.webView) as? [String: Any]
            let first = result?["first"] as? [String]
            let later = result?["later"]
            if let first { XCTAssertEqual(first, Self.nothingToCall, "\(name), at once") }
            if let later = later as? [String] { XCTAssertEqual(later, Self.nothingToCall, "\(name), when loaded") }
            XCTAssertFalse(first == nil && !(later is [String]), "\(name): nothing was read: \(String(describing: result))")
        }
    }

    func testThePageStillGetsTheRefusalBehindThat() throws {
        let model = try browser()
        XCTAssertTrue(model.responds(to: #selector(
            WKUIDelegate.webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:))),
                      "without this WebKit would draw its own prompt")
    }

    func testAPageCannotAskForTheLocation() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        // WebKit refuses at once or holds the request with no answer. Either way a page gets nothing.
        let result = try js("""
            if (!navigator.geolocation) return 'absent';
            return await new Promise(done => {
                setTimeout(() => done('no answer'), 2000);
                navigator.geolocation.getCurrentPosition(() => done('granted'), e => done('refused:' + e.code));
            });
            """, in: model.webView) as? String
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, "granted")
    }

    func testAPageCannotDrawADialogOfTheApp() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        let result = try js("alert('a'); return [confirm('b'), prompt('c')];", in: model.webView) as? [Any]
        XCTAssertEqual(result?.first as? Bool, false)
        XCTAssertTrue(result?.last is NSNull || result?.count == 1, "\(String(describing: result))")
        XCTAssertNil(model.webView.window?.attachedSheet)
        XCTAssertEqual(NSApp.windows.filter { $0.isVisible && $0.className.contains("Alert") }.count, 0)
    }

    func testAPageCannotCloseTheSheet() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        try js("window.close();", in: model.webView)
        HostedTestSupport.settle(0.2)
        XCTAssertEqual(path(of: model), "/")
        XCTAssertNotNil(model.webView.window)
    }

    // MARK: what it cannot show

    func testAFileIsNeverSavedAndTheBrowserIsOffered() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        let target = try address("/file")
        try js("location.href = '\(target.absoluteString)';", in: model.webView)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.failure != nil })
        XCTAssertEqual(model.failure, MacLinkBrowserModel.Failure(url: target, message: nil))
        XCTAssertFalse(model.isLoading)
        model.openInBrowser()
        XCTAssertEqual(opened, [target])
        XCTAssertTrue(model.canGoBack, "the page is still under the message")
        model.goBack()
        XCTAssertNil(model.failure)
        XCTAssertEqual(path(of: model), "/")
        model.openInBrowser()
        XCTAssertEqual(opened, [target, try address()], "the page on the screen, not the file")
    }

    func testADownloadLinkIsNeverSavedAndTheBrowserIsOffered() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        try click("save", in: model)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.failure != nil })
        XCTAssertEqual(model.failure?.url, try address("/second"))
        XCTAssertEqual(path(of: model), "/", "the page stays under the message")
    }

    func testAFailedLoadSaysWhyOffersTheBrowserAndCanTryAgain() throws {
        let port = server.port
        server.stop()
        let target = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        let model = MacLinkBrowserModel(url: target, open: { [unowned self] in self.opened.append($0) })
        let window = HostedTestSupport.host(MacLinkBrowserView(model: model), size: NSSize(width: 800, height: 600))
        windows.append(window)
        model.start()
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.failure != nil })
        XCTAssertEqual(model.failure?.url, target)
        XCTAssertFalse(model.failure?.message?.isEmpty ?? true, "the reason is the system's")
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.address, "127.0.0.1:\(port)")
        model.openInBrowser()
        XCTAssertEqual(opened, [target])
        model.retry()
        XCTAssertNil(model.failure, "the message goes as the new try starts")
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.failure != nil }, "and comes back if it fails again")
    }

    func testStoppingALoadIsNotAFailure() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        let target = try address("/slow").absoluteString
        try js("location.href = '\(target)';", in: model.webView)
        XCTAssertTrue(HostedTestSupport.waitUntil { model.isLoading })
        model.reloadOrStop()
        XCTAssertTrue(HostedTestSupport.waitUntil { !model.isLoading })
        HostedTestSupport.settle(0.2)
        XCTAssertNil(model.failure)
        model.openInBrowser()
        XCTAssertEqual(opened, [try address()], "the page on the screen, not the load that stopped")
    }

    func testAPageThatDiesSaysSo() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        model.webViewWebContentProcessDidTerminate(model.webView)
        XCTAssertEqual(model.failure?.url, model.webView.url)
        XCTAssertFalse(model.isLoading)
    }

    /// Ends the page's process as a crash does, so a test sees what is left of the view. WebKit's own
    /// `_killWebContentProcess` does not tell the delegate, so it cannot show this.
    private func killThePage(of model: MacLinkBrowserModel) throws {
        let key = "_webProcessIdentifier"
        try XCTSkipUnless(model.webView.responds(to: NSSelectorFromString(key)), "this macOS does not name the process")
        let process = try XCTUnwrap(model.webView.value(forKey: key) as? NSNumber).int32Value
        XCTAssertGreaterThan(process, 0)
        XCTAssertEqual(kill(process, SIGKILL), 0, "errno \(errno)")
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.failure != nil })
    }

    private func pageIsAlive(_ model: MacLinkBrowserModel, showing id: String) throws -> Bool {
        try js("return document.getElementById(id) !== null;", arguments: ["id": id], in: model.webView) as? Bool == true
    }

    func testAPageThatDiedLeavesNothingForBackToShow() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        try killThePage(of: model)
        XCTAssertFalse(model.canGoBack, "there is no history, and no page under the message")
        model.retry()
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { model.failure == nil && !model.isLoading && self.path(of: model) == "/" })
        XCTAssertTrue(try pageIsAlive(model, showing: "second"), "Try Again brings the page back")
    }

    func testBackAfterAPageDiedGoesBackInTheHistory() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        try click("second", in: model)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { self.path(of: model) == "/second" && !model.isLoading })
        try killThePage(of: model)
        XCTAssertTrue(model.canGoBack, "the history outlives the page")
        model.goBack()
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { self.path(of: model) == "/" && model.failure == nil && !model.isLoading },
                      "\(String(describing: model.webView.url)), failure: \(String(describing: model.failure))")
        XCTAssertTrue(try pageIsAlive(model, showing: "second"), "the first page draws again")
    }

    func testOpenInBrowserFollowsARouteThePageChangesByItself() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        let steps = [("history.pushState({}, '', '/route/a')", "/route/a"),
                     ("history.replaceState({}, '', '/route/b')", "/route/b"),
                     ("location.hash = 'c'", "/route/b#c")]
        for (script, route) in steps {
            try js(script, in: model.webView)
            let target = try address(route).absoluteString
            XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 5) { model.fullAddress == target },
                          "\(script): \(model.fullAddress)")
        }
        model.openInBrowser()
        XCTAssertEqual(opened, [try address("/route/b#c")])
        XCTAssertEqual(model.address, "127.0.0.1:\(server.port)")
        XCTAssertFalse(model.isLoading)
        // Back inside one document has no new page either.
        model.goBack()
        let back = try address("/route/b").absoluteString
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 5) { model.fullAddress == back }, model.fullAddress)
    }

    func testOpenInBrowserOpensThePageOnTheScreen() throws {
        let model = try browser()
        XCTAssertTrue(loaded(model))
        let start = try address()
        // A load in flight has not drawn: the page on the screen is still the first.
        try js("location.href = '\(try address("/slow").absoluteString)';", in: model.webView)
        HostedTestSupport.settle(0.3)
        model.openInBrowser()
        XCTAssertEqual(opened, [start])
    }

    // MARK: the sheet

    private func sheetParent() -> NSWindow {
        let window = HostedTestSupport.host(Color.clear, size: NSSize(width: 1100, height: 800))
        windows.append(window)
        return window
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func present(over window: NSWindow) throws -> NSWindow {
        let open: @MainActor (URL) -> Void = { [unowned self] in self.opened.append($0) }
        XCTAssertTrue(MacLinkBrowser.present(try address(), over: window, open: open))
        return try XCTUnwrap(window.attachedSheet)
    }

    func testItOpensAsASheetThatClosesLikeAnyPreview() throws {
        let window = sheetParent()
        let sheet = try present(over: window)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.find(WKWebView.self, in: sheet.contentView) != nil })
        XCTAssertTrue(SheetCloseButton.isContentSheet(sheet), "a page cannot take the X, Esc or a click behind away")
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(sheet))
        XCTAssertTrue(SheetEscape.handleEscape(in: sheet))
        XCTAssertTrue(HostedTestSupport.waitUntil { window.attachedSheet == nil })
    }

    func testClosingTheSheetEndsThePage() throws {
        let window = sheetParent()
        let sheet = try present(over: window)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.find(WKWebView.self, in: sheet.contentView)?.url != nil })
        let view = try XCTUnwrap(find(WKWebView.self, in: sheet.contentView))
        window.endSheet(sheet)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 5) { view.url?.absoluteString == "about:blank" },
                      "a page that plays sound stops with the sheet: \(String(describing: view.url))")
        XCTAssertNil(view.navigationDelegate)
        XCTAssertNil(view.uiDelegate)
    }

    func testItOpensOverASheetAlreadyOpen() throws {
        let window = sheetParent()
        let first = try present(over: window)
        let open: @MainActor (URL) -> Void = { _ in }
        XCTAssertTrue(MacLinkBrowser.present(try address("/second"), over: window, open: open))
        XCTAssertNotNil(first.attachedSheet)
    }

    func testWithNoWindowItSaysSoAndTheCallerFallsBack() throws {
        let open: @MainActor (URL) -> Void = { _ in }
        XCTAssertFalse(MacLinkBrowser.present(try address(), over: nil, open: open))
    }

    func testTheSheetIsWideEnoughForADesktopPageButNotWiderThanItsWindow() throws {
        let wide = sheetParent()
        let sheet = try present(over: wide)
        XCTAssertEqual(sheet.contentLayoutRect.width, MacLinkBrowser.idealWidth, accuracy: 1)
        let narrow = HostedTestSupport.host(Color.clear, size: NSSize(width: 700, height: 500))
        windows.append(narrow)
        let small = try present(over: narrow)
        XCTAssertLessThanOrEqual(small.frame.width, 700)
        XCTAssertGreaterThanOrEqual(small.contentLayoutRect.width, MacFilePreviewSheet.minSize.width)
    }

    func testEveryButtonHasANameInTheAppsLanguage() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let boostWasOn = AccessibilityTreeBoost.isOn
        AccessibilityTreeBoost.set(true)
        addTeardownBlock { @MainActor in AccessibilityTreeBoost.set(boostWasOn) }
        preserveStandardDefaults(AppLanguageStore.defaultsKey)
        let store = AppLanguageStore.shared
        let previous = store.selection
        store.select(try XCTUnwrap(AppLanguage(rawValue: "de")))
        addTeardownBlock { @MainActor in store.select(previous) }
        let sheet = try present(over: sheetParent())
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: sheet).contains("Im Browser \u{00F6}ffnen") },
                      "\(AccessibilityProbe.labels(in: sheet))")
        let labels = AccessibilityProbe.labels(in: sheet)
        for word in ["Zur\u{00FC}ck", "Vorw\u{00E4}rts", "Neu laden", "Im Browser \u{00F6}ffnen"] {
            XCTAssertTrue(labels.contains(word), "\(word) is missing: \(labels)")
        }
    }
}
