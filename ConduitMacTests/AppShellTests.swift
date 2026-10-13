import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class AppShellTests: XCTestCase {
    func testPersistentSidebarDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: "conduit.ipadPersistentSidebar")
        MacDefaults.register()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "conduit.ipadPersistentSidebar"))
    }

    func testClosingLastWindowDoesNotQuit() {
        XCTAssertFalse(ConduitMacAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testCancelStopsOperation() async {
        let task = NativeOAuthPresentationTask()
        var finished = false
        task.start(
            operation: {
                try await Task.sleep(for: .seconds(30))
                finished = true
                throw CancellationError()
            },
            onSuccess: { _ in XCTFail("no success after cancel") },
            onError: { _ in XCTFail("no error after cancel") }
        )
        task.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished)
    }

    // MARK: openURL policy (R11)

    private final class LinkBox { var links: [ConduitAppLink] = [] }

    private func decide(_ string: String, widget: Bool = false) async -> (MacOpenURLPolicy.Decision, [ConduitAppLink]) {
        let box = LinkBox()
        let result = MacOpenURLPolicy.decision(
            for: URL(string: string)!,
            routeWidgetLaunch: { _ in widget },
            openAppLink: { box.links.append($0) }
        )
        // The in-app link is opened from a MainActor task.
        try? await Task.sleep(for: .milliseconds(50))
        return (result, box.links)
    }

    func testFileURLIsDiscarded() async {
        let decision = await decide("file:///Applications/Calculator.app").0
        XCTAssertEqual(decision, .discarded)
    }

    func testHTTPSIsSystemAction() async {
        let decision = await decide("https://example.com/x").0
        XCTAssertEqual(decision, .systemAction)
    }

    func testWidgetRouteWinsAndIsHandled() async {
        let decision = await decide("file:///x", widget: true).0
        XCTAssertEqual(decision, .handled)
    }

    func testConduitSessionLinkOpensInApp() async {
        let (result, opened) = await decide("conduit://session/abc")
        XCTAssertEqual(result, .handled)
        XCTAssertEqual(opened, [.session(id: "abc")])
    }

    func testUnreadableConduitLinkIsDiscarded() async {
        let (result, opened) = await decide("conduit://nonsense")
        XCTAssertEqual(result, .discarded)
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: OAuth browser launch failure

    func testRefusedAuthorizeURLReportsError() async {
        var errors: [Error] = []
        // Real opener: UIApplication.shared.open refuses file: via the R6 allowlist.
        await SafariAuthenticationView.openAuthorizeURL(URL(string: "file:///etc/passwd")!) { errors.append($0) }
        XCTAssertEqual(errors.count, 1)
        XCTAssertFalse(errors[0].localizedDescription.isEmpty)
    }

    func testOpenReturningFalseReportsError() async {
        var errors: [Error] = []
        await SafariAuthenticationView.openAuthorizeURL(
            URL(string: "https://example.com/authorize")!,
            open: { _ in false },
            onError: { errors.append($0) }
        )
        XCTAssertEqual(errors.count, 1)
    }

    func testOpenSucceedingReportsNoError() async {
        var errors: [Error] = []
        await SafariAuthenticationView.openAuthorizeURL(
            URL(string: "https://example.com/authorize")!,
            open: { _ in true },
            onError: { errors.append($0) }
        )
        XCTAssertTrue(errors.isEmpty)
    }
}
