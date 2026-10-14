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

    /// Every Mac has a hardware keyboard, so Return sends unless the user turns it off.
    /// Checks the registration domain so a stored user choice is left alone.
    func testReturnKeySendsDefaultsOn() {
        MacDefaults.register()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[ComposerReturnKey.preferenceKey] as? Bool, true)
    }

    func testClosingLastWindowDoesNotQuit() {
        XCTAssertFalse(ConduitMacAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    private final class CancelProbe {
        var sawCancellation = false
        var succeeded = false
        var failed = false
    }

    func testCancelStopsOperation() async {
        let task = NativeOAuthPresentationTask()
        let probe = CancelProbe()
        let started = expectation(description: "operation started")
        let observedCancel = expectation(description: "operation observed cancellation")
        task.start(
            operation: {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    probe.sawCancellation = true
                    observedCancel.fulfill()
                    throw CancellationError()
                }
                throw CancellationError()
            },
            onSuccess: { _ in probe.succeeded = true },
            onError: { _ in probe.failed = true }
        )
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [observedCancel], timeout: 5)
        // Let the task's catch/cleanup run before checking the callbacks.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(probe.sawCancellation)
        XCTAssertFalse(probe.succeeded, "no success after cancel")
        XCTAssertFalse(probe.failed, "no error after cancel")
    }

    /// Control: proves the harness can observe callbacks.
    func testUncancelledOperationCallsOnSuccess() async {
        let task = NativeOAuthPresentationTask()
        let called = expectation(description: "onSuccess called")
        let tokens = NativeOAuthTokenSet(accessToken: "a", refreshToken: "r", expiresAt: 0, provider: "p", userID: "u")
        task.start(
            operation: { NativeOAuthLoginResult(tokens: tokens, ticket: "t") },
            onSuccess: { result in
                XCTAssertEqual(result.ticket, "t")
                called.fulfill()
            },
            onError: { _ in XCTFail("unexpected error") }
        )
        await fulfillment(of: [called], timeout: 5)
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
