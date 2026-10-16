import XCTest
@testable import ConduitMac

/// A widget tap reaches the Mac app as a `conduit://widget/v1/...` URL (D25).
/// These use a real AppState with no connection, so the scene is not ready and
/// the coordinator holds the request; that deferral is the behaviour pinned.
@MainActor
final class MacWidgetLaunchRoutingTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!
    private var appState: AppState { fixture.appState }

    override func setUp() {
        super.setUp()
        fixture = MacSharedBaseAppStateFixture()
    }

    override func tearDown() {
        appState.widgetLaunchCoordinator.supersede()
        fixture.tearDown()
        fixture = nil
        super.tearDown()
    }

    private let workspace = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, profile: "default")

    private var reference: WidgetConversationReference {
        WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil, sessionID: "s1", isUnverified: false)
    }

    func testEveryLinkTheExtensionCanEmitIsConsumedAndHeldUntilReady() throws {
        let links: [WidgetLaunchLink?] = [
            WidgetLaunchLink(action: .open, workspace: nil, reference: nil),
            WidgetLaunchLink(action: .open, workspace: workspace, reference: nil),
            WidgetLaunchLink(action: .resume, workspace: workspace, reference: reference),
            WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil),
            WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil),
        ]
        XCTAssertEqual(links.compactMap { $0 }.count, 5)
        for link in links.compactMap({ $0 }) {
            XCTAssertTrue(appState.routeWidgetLaunchURL(link.url), "\(link.url) was not consumed")
            XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest, "\(link.url) was dropped")
            appState.widgetLaunchCoordinator.supersede()
            XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest)
        }
    }

    func testMalformedWidgetUrlIsConsumedWithoutARequest() throws {
        let bad = [
            "conduit://widget/v1/bogus",
            "conduit://widget/v1/newChat",                      // needs a workspace
            "conduit://widget/v2/open",
            "conduit://widget/v1/open?dashboard=not-a-uuid&profile=p",
            "conduit://widget/v1/open?extra=1",
        ]
        for string in bad {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertTrue(appState.routeWidgetLaunchURL(url), "\(string) must be consumed so it cannot reach session-link parsing")
            XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest, "\(string) must not start a launch")
        }
    }

    func testOtherConduitUrlsAreNotConsumed() throws {
        for string in ["conduit://session/abc", "conduit://settings/voice", "https://example.com/widget"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(appState.routeWidgetLaunchURL(url), string)
        }
        XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest)
    }

    func testPolicyHandlesAWidgetUrlBeforeAppLinkParsing() throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let decision = MacOpenURLPolicy.decision(
            for: link.url,
            routeWidgetLaunch: { self.appState.routeWidgetLaunchURL($0) },
            openAppLink: { _ in XCTFail("a widget URL must not become an app link") }
        )
        XCTAssertEqual(decision, .handled)
        XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest)
    }

    func testANewTapSupersedesAnOlderOne() throws {
        let first = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let second = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        XCTAssertTrue(appState.routeWidgetLaunchURL(first.url))
        XCTAssertTrue(appState.routeWidgetLaunchURL(second.url))
        XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest)
        appState.widgetLaunchCoordinator.supersede()
        XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest)
    }
}
