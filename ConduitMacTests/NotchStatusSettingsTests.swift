import XCTest
@testable import ConduitMac

@MainActor
final class NotchStatusSettingsTests: XCTestCase {
    func testDefaultIsActiveAgents() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        XCTAssertEqual(NotchStatusSettings(defaults: s.defaults).mode, .activeAgents)
    }

    func testUnknownStoredValueFallsBackToDefault() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        s.defaults.set("sometimes", forKey: NotchStatusSettings.key)
        XCTAssertEqual(NotchStatusSettings(defaults: s.defaults).mode, .activeAgents)
    }

    func testSettingModePersistsUnderTheDocumentedKey() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let settings = NotchStatusSettings(defaults: s.defaults)
        settings.mode = .onlyWhenNeeded
        XCTAssertEqual(s.defaults.string(forKey: "conduit.mac.notchStatus.mode"), "onlyWhenNeeded")
    }

    func testExternalWriteIsPickedUp() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let settings = NotchStatusSettings(defaults: s.defaults)
        s.defaults.set("off", forKey: NotchStatusSettings.key)   // what the @AppStorage picker does
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: s.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { settings.mode == .off })
    }
}
