import CoreSpotlight
import XCTest
@testable import ConduitMac

final class MacSpotlightContinuationTests: XCTestCase {
    private let scope = MacSpotlightScope(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"), profile: "work")

    private func info(_ id: String) -> [AnyHashable: Any] { [CSSearchableItemActivityIdentifier: id] }

    func testOwnItemOpensTheSessionOnItsProfile() {
        let raw = MacSpotlightItemID.make(scope: scope, sessionID: "sess.1")
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: scope.dashboardKey),
            .open(.session(id: "sess.1", profile: "work")))
    }

    func testSessionIDWithPipesAndProfileWithSpacesSurvives() {
        let odd = MacSpotlightScope(dashboardID: nil, profile: "My Profile|x")
        let raw = MacSpotlightItemID.make(scope: odd, sessionID: "a|b|c")
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: "none"),
            .open(.session(id: "a|b|c", profile: "My Profile|x")))
    }

    func testForeignDashboardIsReportedNotOpened() {
        let raw = MacSpotlightItemID.make(scope: scope, sessionID: "x")
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: "other"), .foreignDashboard)
    }

    func testMalformedOrMissingIsIgnored() {
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: info("garbage"), currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: [:], currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: nil, currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: [CSSearchableItemActivityIdentifier: 42], currentDashboardKey: "none"), .ignored)
    }

    func testMalformedIsIgnoredEvenWhenTheDashboardWouldMatch() {
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(userInfo: info("conduit|none|p|"), currentDashboardKey: "none"), .ignored)
    }

    func testRawIDEntryPointMatchesTheUserInfoOne() {
        let raw = MacSpotlightItemID.make(scope: scope, sessionID: "sess.1")
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(rawID: raw, currentDashboardKey: scope.dashboardKey),
            MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: scope.dashboardKey))
        XCTAssertEqual(MacSpotlightContinuation.outcome(rawID: "nope", currentDashboardKey: "none"), .ignored)
    }
}

@MainActor
final class MacSpotlightInboxTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var inbox: MacSpotlightInbox!
    private var delivered: [String] = []

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_000)
        delivered = []
        inbox = MacSpotlightInbox(now: { [unowned self] in self.clock })
    }
    override func tearDown() async throws { inbox = nil }

    private func info(_ id: String) -> [AnyHashable: Any] { [CSSearchableItemActivityIdentifier: id] }
    private func activity(_ id: String, type: String = CSSearchableItemActionType) -> NSUserActivity {
        let a = NSUserActivity(activityType: type)
        a.userInfo = info(id)
        return a
    }
    private func attach() { inbox.attach { [unowned self] in self.delivered.append($0) } }

    func testALaunchBeforeAnyWindowIsParkedThenDeliveredOnAttach() {
        XCTAssertTrue(inbox.receive(activity: activity("conduit|none|p|s1")))
        XCTAssertTrue(delivered.isEmpty)
        attach()
        XCTAssertEqual(delivered, ["conduit|none|p|s1"])
        attach()
        XCTAssertEqual(delivered, ["conduit|none|p|s1"], "a parked launch is delivered once")
    }

    func testALaunchAfterAttachIsDeliveredAtOnce() {
        attach()
        inbox.receive(userInfo: info("conduit|none|p|s1"))
        XCTAssertEqual(delivered, ["conduit|none|p|s1"])
    }

    func testBothDoorsFiringForOneClickOpensOnce() {
        attach()
        let raw = "conduit|none|p|s1"
        inbox.receive(activity: activity(raw))
        clock.addTimeInterval(0.05)
        inbox.receive(userInfo: info(raw))
        XCTAssertEqual(delivered, [raw])
    }

    func testBothDoorsFiringBeforeAttachParksOnce() {
        let raw = "conduit|none|p|s1"
        inbox.receive(userInfo: info(raw))
        inbox.receive(activity: activity(raw))
        attach()
        XCTAssertEqual(delivered, [raw])
    }

    func testTheSameResultClickedAgainLaterOpensAgain() {
        attach()
        let raw = "conduit|none|p|s1"
        inbox.receive(userInfo: info(raw))
        clock.addTimeInterval(MacSpotlightInbox.duplicateWindow + 0.1)
        inbox.receive(userInfo: info(raw))
        XCTAssertEqual(delivered, [raw, raw])
    }

    func testADifferentResultInsideTheWindowIsNotADuplicate() {
        attach()
        inbox.receive(userInfo: info("conduit|none|p|s1"))
        inbox.receive(userInfo: info("conduit|none|p|s2"))
        XCTAssertEqual(delivered, ["conduit|none|p|s1", "conduit|none|p|s2"])
    }

    func testOtherActivitiesAreNotClaimed() {
        attach()
        XCTAssertFalse(inbox.receive(activity: activity("conduit|none|p|s1", type: "com.example.handoff")))
        XCTAssertTrue(delivered.isEmpty)
    }

    func testASpotlightActivityWithoutOurIdentifierIsClaimedButDeliversNothing() {
        attach()
        let a = NSUserActivity(activityType: CSSearchableItemActionType)
        a.userInfo = [:]
        XCTAssertTrue(inbox.receive(activity: a))
        XCTAssertTrue(delivered.isEmpty)
    }

    func testTheAppDelegateFeedsTheSharedInboxAndClaimsOnlySpotlightActivities() {
        let shared = MacSpotlightInbox.shared
        shared.reset()
        defer { shared.reset() }
        var seen: [String] = []
        shared.attach { seen.append($0) }
        let delegate = ConduitMacAppDelegate()
        let handled = delegate.application(NSApplication.shared, continue: activity("conduit|none|p|cold1"), restorationHandler: { _ in })
        XCTAssertTrue(handled)
        XCTAssertEqual(seen, ["conduit|none|p|cold1"])
        let other = delegate.application(NSApplication.shared, continue: activity("x", type: "com.example.handoff"), restorationHandler: { _ in })
        XCTAssertFalse(other)
        XCTAssertEqual(seen.count, 1)
    }
}
