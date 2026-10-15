import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationSettingsViewTests: XCTestCase {
    func testAuthorizationStateMapping() {
        XCTAssertEqual(MacNotificationAuthorizationState(.notDetermined), .notDetermined)
        XCTAssertEqual(MacNotificationAuthorizationState(.denied), .denied)
        XCTAssertEqual(MacNotificationAuthorizationState(.authorized), .allowed)
        XCTAssertEqual(MacNotificationAuthorizationState(.provisional), .allowed)
    }

    func testStatusTextAndSystemSettingsButtonPerState() {
        XCTAssertEqual(MacNotificationAuthorizationState.denied.statusText, "Blocked in System Settings")
        XCTAssertTrue(MacNotificationAuthorizationState.denied.needsSystemSettings)
        XCTAssertFalse(MacNotificationAuthorizationState.allowed.needsSystemSettings)
        XCTAssertFalse(MacNotificationAuthorizationState.notDetermined.needsSystemSettings)
        XCTAssertNotEqual(MacNotificationAuthorizationState.allowed.statusText, MacNotificationAuthorizationState.notDetermined.statusText)
    }

    func testViewHostsInLightAndDarkWithNonEmptyLayout() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let prefs = MacNotificationPreferences(defaults: suite.defaults)
        for scheme in [ColorScheme.light, .dark] {
            for state in [MacNotificationAuthorizationState.allowed, .denied, .notDetermined] {
                let window = HostedTestSupport.host(
                    MacNotificationSettingsView(preferences: prefs, authorization: state).preferredColorScheme(scheme),
                    size: NSSize(width: 520, height: 520)
                )
                defer { HostedTestSupport.tearDown(window) }
                window.contentView?.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(window.contentView?.fittingSize.height ?? 0, 100, "\(scheme) \(state)")
            }
        }
    }

    func testKindTogglesFollowTheMasterToggle() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let prefs = MacNotificationPreferences(defaults: suite.defaults)
        prefs.isEnabled = false
        XCTAssertFalse(MacNotificationSettingsView.kindControlsEnabled(prefs))
        prefs.isEnabled = true
        XCTAssertTrue(MacNotificationSettingsView.kindControlsEnabled(prefs))
    }
}
