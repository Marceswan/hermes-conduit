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

    // MARK: surface style

    func testDefaultSurfaceStyleIsGlass() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        XCTAssertEqual(NotchStatusSettings(defaults: s.defaults).surfaceStyle, .glass)
    }

    func testUnknownStoredSurfaceStyleFallsBackToGlass() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        s.defaults.set("chrome", forKey: NotchStatusSettings.surfaceStyleKey)
        XCTAssertEqual(NotchStatusSettings(defaults: s.defaults).surfaceStyle, .glass)
    }

    func testSettingSurfaceStylePersistsUnderTheDocumentedKey() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let settings = NotchStatusSettings(defaults: s.defaults)
        XCTAssertEqual(NotchStatusSettings.surfaceStyleKey, "conduit.mac.notchStatus.surfaceStyle")
        for style in NotchSurfaceStyle.allCases where style != .glass {
            settings.surfaceStyle = style
            XCTAssertEqual(s.defaults.string(forKey: "conduit.mac.notchStatus.surfaceStyle"), style.rawValue)
            XCTAssertEqual(NotchStatusSettings(defaults: s.defaults).surfaceStyle, style, "reads back after a relaunch")
        }
    }

    func testSurfaceStyleDoesNotTouchTheModeKey() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let settings = NotchStatusSettings(defaults: s.defaults)
        settings.surfaceStyle = .solid
        XCTAssertNil(s.defaults.string(forKey: NotchStatusSettings.key))
        settings.mode = .off
        XCTAssertEqual(settings.surfaceStyle, .solid)
    }

    func testExternalSurfaceStyleWriteIsPickedUp() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let settings = NotchStatusSettings(defaults: s.defaults)
        s.defaults.set("dock", forKey: NotchStatusSettings.surfaceStyleKey)   // what the @AppStorage picker does
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: s.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { settings.surfaceStyle == .dock })
    }
}
