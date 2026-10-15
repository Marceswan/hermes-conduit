import XCTest
@testable import ConduitMac

@MainActor
final class MacStreamTapTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!
    private var token: MacStreamEventHub.Token?
    private var seen: [String] = []

    override func setUp() async throws {
        fixture = MacSharedBaseAppStateFixture()
        seen = []
        token = MacStreamEventHub.shared.subscribe { [weak self] event in
            self?.seen.append(Self.label(event))
        }
    }

    override func tearDown() async throws {
        if let token { MacStreamEventHub.shared.unsubscribe(token) }
        token = nil
        fixture.tearDown()
        fixture = nil
    }

    private static func label(_ event: StreamEvent) -> String {
        switch event {
        case .messageStart(let id): return "start:\(id)"
        case .messageDelta(let id, _): return "delta:\(id)"
        case .messageInterrupted(let id): return "interrupted:\(id)"
        case .approval(let id, _): return "approval:\(id)"
        case .sessionTitle(let runtime, _, _): return "title:\(runtime)"
        default: return "other"
        }
    }

    func testEventForAnInactiveSessionReachesTheHubAndLeavesAppStateUntouched() {
        let appState = fixture.appState
        appState.activeSessionId = "active"
        let messagesBefore = appState.messages
        appState.handleStreamEvent(.messageDelta(sessionId: "other", text: "hello"))
        XCTAssertEqual(seen, ["delta:other"])
        XCTAssertEqual(appState.messages, messagesBefore, "AppState still drops events for sessions that are not open")
        XCTAssertFalse(appState.turnState.isRunning)
    }

    func testTheEarlyReturnPathStillPublishes() {
        fixture.appState.handleStreamEvent(.sessionTitle(runtimeSessionId: "r", storedSessionId: "s", title: "T"))
        XCTAssertEqual(seen, ["title:r"], "the tap is the first statement, ahead of the sessionTitle early return")
    }

    func testEveryKindOfEventIsForwarded() {
        let appState = fixture.appState
        let approval = ApprovalActivity(
            sessionId: "other", requestId: "q1", command: "ls", description: "list",
            choices: nil, allowPermanent: true, smartDenied: false, status: .pending)
        appState.handleStreamEvent(.messageStart(sessionId: "other"))
        appState.handleStreamEvent(.approval(sessionId: "other", activity: approval))
        appState.handleStreamEvent(.messageInterrupted(sessionId: "other"))
        XCTAssertEqual(seen, ["start:other", "approval:other", "interrupted:other"])
    }
}
