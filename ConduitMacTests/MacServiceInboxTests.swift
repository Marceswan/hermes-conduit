import XCTest
@testable import ConduitMac

@MainActor
final class MacServiceInboxTests: XCTestCase {
    private var scope = "d1.default"
    private var inbox: MacServiceInbox!

    override func setUp() {
        inbox = MacServiceInbox()
        inbox.install(scope: { [unowned self] in self.scope })
    }

    func testLastWriteWins() {
        inbox.submit("first"); inbox.submit("second")
        XCTAssertEqual(inbox!.take(), "second")
        XCTAssertNil(inbox!.take(), "applied exactly once")
    }

    func testTakeDropsTextParkedForAnotherProfileOrDashboard() {
        inbox.submit("secret")
        scope = "d1.work"
        XCTAssertNil(inbox!.take())
        XCTAssertFalse(inbox.hasPending, "dropped, not kept for later")
        inbox.submit("again")
        scope = "d2.work"
        XCTAssertNil(inbox!.take())
    }

    func testSubmitBumpsRevisionSoTheRouteTaskRearms() {
        let before = inbox.revision
        inbox.submit("a")
        XCTAssertGreaterThan(inbox.revision, before)
    }

    func testDiscardClears() {
        inbox.submit("a"); inbox.discard()
        XCTAssertNil(inbox!.take())
    }

    func testScopeKeyFormat() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(MacServiceInbox.scope(dashboardID: id, profile: "p"), "00000000-0000-0000-0000-000000000001.p")
        XCTAssertEqual(MacServiceInbox.scope(dashboardID: nil, profile: "p"), "none.p")
    }

    func testTextParkedBeforeScopeIsInstalledIsAccepted() {
        let cold = MacServiceInbox()
        cold.submit("cold launch")
        cold.install(scope: { "d1.default" })
        XCTAssertEqual(cold.take(), "cold launch")
    }

    func testTextParkedBeforeScopeIsInstalledStillDropsOnAScopeChangeAfterward() {
        let cold = MacServiceInbox()
        cold.submit("cold launch")
        var current = "d1.default"
        cold.install(scope: { current })
        current = "d1.work"
        XCTAssertNil(cold.take(), "scope stamped at install; a later change drops it")
    }
}
