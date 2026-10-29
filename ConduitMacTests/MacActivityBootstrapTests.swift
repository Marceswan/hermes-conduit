import XCTest
@testable import ConduitMac

@MainActor
final class MacActivityBootstrapTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!

    override func setUp() async throws {
        fixture = MacSharedBaseAppStateFixture()
    }

    override func tearDown() async throws {
        MacActivityBootstrap.stop()
        fixture.tearDown()
        fixture = nil
    }

    func testStartCreatesBindsAndSubscribesTheSharedFeedOnce() {
        let before = MacStreamEventHub.shared.subscriberCount
        MacActivityBootstrap.start(appState: fixture.appState)
        MacActivityBootstrap.start(appState: fixture.appState)
        XCTAssertNotNil(AgentActivityFeed.shared)
        XCTAssertTrue(AgentActivityFeed.shared === MacActivityBootstrap.feed)
        XCTAssertEqual(MacStreamEventHub.shared.subscriberCount, before + 1)
    }

    func testStopTearsItDown() {
        let before = MacStreamEventHub.shared.subscriberCount
        MacActivityBootstrap.start(appState: fixture.appState)
        MacActivityBootstrap.stop()
        XCTAssertNil(AgentActivityFeed.shared)
        XCTAssertNil(MacActivityBootstrap.feed)
        XCTAssertEqual(MacStreamEventHub.shared.subscriberCount, before)
    }

    func testAnEventPublishedByAppStateReachesTheSharedFeed() {
        MacActivityBootstrap.start(appState: fixture.appState)
        fixture.appState.handleStreamEvent(.messageStart(sessionId: "other"))
        XCTAssertEqual(AgentActivityFeed.shared?.items.map(\.id), ["turn:other"],
                       "AppState tap -> hub -> feed, for a session that is not open")
    }
}
