import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationPreferencesTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws { HostedTestSupport.dropSuite(suite) }

    func testDefaults() {
        let p = MacNotificationPreferences(defaults: suite.defaults)
        XCTAssertTrue(p.isEnabled)
        XCTAssertTrue(p.notifiesDone && p.notifiesApprovals && p.notifiesQuestions && p.soundEnabled)
        XCTAssertEqual(p.threshold, 30)
    }

    func testChangesPersistUnderTheMacKeys() {
        let p = MacNotificationPreferences(defaults: suite.defaults)
        p.isEnabled = false
        p.threshold = 60
        p.notifiesQuestions = false
        let again = MacNotificationPreferences(defaults: suite.defaults)
        XCTAssertFalse(again.isEnabled)
        XCTAssertEqual(again.threshold, 60)
        XCTAssertFalse(again.notifiesQuestions)
        XCTAssertNotNil(suite.defaults.object(forKey: "conduit.mac.notifications.enabled"))
        XCTAssertNotNil(suite.defaults.object(forKey: "conduit.mac.notifications.thresholdSeconds"))
    }

    func testAStoredThresholdOutsideTheChoicesSnapsToTheDefault() {
        suite.defaults.set(7, forKey: MacNotificationPreferences.Key.threshold)
        XCTAssertEqual(MacNotificationPreferences(defaults: suite.defaults).threshold, 30)
        let p = MacNotificationPreferences(defaults: suite.defaults)
        p.threshold = 45
        XCTAssertEqual(p.threshold, 30, "setting an invalid value snaps instead of storing it")
    }

    func testAllowsFollowsMasterAndKindToggles() {
        let p = MacNotificationPreferences(defaults: suite.defaults)
        XCTAssertTrue(p.allows(.failed))
        p.notifiesDone = false
        XCTAssertFalse(p.allows(.done))
        XCTAssertFalse(p.allows(.failed), "failed is part of the Done toggle")
        XCTAssertTrue(p.allows(.approval))
        XCTAssertTrue(p.allows(.notice))
        p.isEnabled = false
        XCTAssertFalse(p.allows(.approval))
        XCTAssertFalse(p.allows(.notice))
    }
}
