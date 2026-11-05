import Foundation
import UserNotifications
import XCTest
@testable import ConduitMac

/// D31 fix (2026-10-28): the Dock count needs the badge permission.
///
/// macOS hides the Dock badge of an app that is registered with `UNUserNotificationCenter` without badge
/// authorization, so the Mac asks for `.alert`, `.badge` and `.sound`, reads `badgeSetting`, tells the user in
/// Settings when badges are not enabled, and asks again once per launch when notifications are already allowed.
/// Nothing here calls the real notification center or opens System Settings: the center is
/// `FakeNotificationCenter`. The Settings note has its own class, `MacBadgeSettingsNoteTests`.
@MainActor
final class MacBadgePermissionTests: XCTestCase {
    private let plainPage = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    // MARK: The options

    func testTheAuthorizationRequestHoldsAlertBadgeAndSound() {
        XCTAssertEqual(MacNotificationAuthorization.options, [.alert, .badge, .sound])
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// One place names the options. A second request with its own list would win or lose by order: the first
    /// request of an app is the one the system records.
    func testOnlyTheCenterClientNamesTheAuthorizationOptions() throws {
        let owner = "ConduitMac/Notifications/MacNotificationCenterClient.swift"
        let files = FileManager.default.enumerator(at: repoRoot.appendingPathComponent("ConduitMac"), includingPropertiesForKeys: nil)
        var seen = 0
        while let item = files?.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            let path = String(item.path.dropFirst(repoRoot.path.count + 1))
            guard path != owner else { continue }
            seen += 1
            let text = MacWordingTests.strippingComments(from: try String(contentsOf: item, encoding: .utf8))
            XCTAssertFalse(text.contains("requestAuthorization(options"), "\(path) names its own authorization options")
            XCTAssertFalse(text.contains("UNAuthorizationOptions"), "\(path) names its own authorization options")
        }
        XCTAssertGreaterThan(seen, 100, "the scan reached the Mac sources")
        let client = MacWordingTests.strippingComments(from: try source(owner))
        XCTAssertTrue(client.contains("requestAuthorization(options: MacNotificationAuthorization.options)"),
                      "the live client asks with the one list")
    }

    // MARK: Reading the permission

    func testReadingTakesTheStatusAndTheBadgeSettingFromTheClient() async {
        let center = FakeNotificationCenter()
        center.status = .provisional
        center.badge = .disabled
        let permission = await MacBadgePermission.read(from: center)
        XCTAssertEqual(permission, MacBadgePermission(status: .provisional, setting: .disabled))
    }

    // MARK: The note

    func testTheNoteShowsOnlyWhenTheCountIsOnNotificationsAreAllowedAndBadgesAreNot() {
        func note(_ status: UNAuthorizationStatus, _ setting: UNNotificationSetting, count: Bool = true) -> Bool {
            MacBadgePermission(status: status, setting: setting).needsNote(showsCount: count)
        }
        XCTAssertTrue(note(.authorized, .notSupported), "allowed, and the badge option was never granted")
        XCTAssertTrue(note(.authorized, .disabled), "allowed, and the badge is switched off")
        XCTAssertTrue(note(.provisional, .notSupported))
        XCTAssertFalse(note(.authorized, .enabled), "nothing to say when badges are on")
        for setting in [UNNotificationSetting.notSupported, .disabled, .enabled] {
            XCTAssertFalse(note(.authorized, setting, count: false), "the count is off: no note (\(setting.rawValue))")
        }
        // Not yet asked: Conduit has no page in System Settings to send the user to, and the Status row says it will ask.
        XCTAssertFalse(note(.notDetermined, .notSupported))
        // Blocked: the Status row already says so and has its own button.
        XCTAssertFalse(note(.denied, .notSupported))
        XCTAssertFalse(note(.denied, .disabled))
    }

    // MARK: Asking again

    func testItAsksAgainOnceWhenNotificationsAreAllowedAndBadgesAreMissing() async {
        let center = FakeNotificationCenter()
        center.status = .authorized
        center.badge = .notSupported
        center.badgeAfterRequest = .enabled
        let requester = MacBadgeOptionRequester()
        let first = await requester.refresh(on: center, wantsBadge: true)
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(first, MacBadgePermission(status: .authorized, setting: .enabled), "the permission is read again after the request")
        // The system took no new option (a later request does not change what was recorded): ask no more this launch.
        center.badge = .notSupported
        center.badgeAfterRequest = nil
        let second = await requester.refresh(on: center, wantsBadge: true)
        XCTAssertEqual(center.authorizationRequests, 1, "at most once per launch")
        XCTAssertEqual(second.setting, .notSupported)
    }

    func testItAsksWhenTheBadgeReadsDisabledToo() async {
        // A never-granted option may read notSupported or disabled: both ask. A request does not prompt (it is
        // an already-answered request) and does not undo a choice.
        let center = FakeNotificationCenter()
        center.badge = .disabled
        _ = await MacBadgeOptionRequester().refresh(on: center, wantsBadge: true)
        XCTAssertEqual(center.authorizationRequests, 1)
    }

    func testItNeverMakesTheFirstRequest() async {
        for status in [UNAuthorizationStatus.notDetermined, .denied, .provisional] {
            let center = FakeNotificationCenter()
            center.status = status
            center.badge = .notSupported
            _ = await MacBadgeOptionRequester().refresh(on: center, wantsBadge: true)
            XCTAssertEqual(center.authorizationRequests, 0, "no request while the status is \(status.rawValue)")
        }
    }

    func testItDoesNotAskWhenBadgesAreAlreadyEnabled() async {
        let center = FakeNotificationCenter()
        center.badge = .enabled
        let permission = await MacBadgeOptionRequester().refresh(on: center, wantsBadge: true)
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertEqual(permission.setting, .enabled)
    }

    func testItDoesNotAskWhileTheCountIsOff() async {
        let center = FakeNotificationCenter()
        center.badge = .notSupported
        let requester = MacBadgeOptionRequester()
        _ = await requester.refresh(on: center, wantsBadge: false)
        XCTAssertEqual(center.authorizationRequests, 0)
        // Turned on later in the same launch: the one request is still available.
        _ = await requester.refresh(on: center, wantsBadge: true)
        XCTAssertEqual(center.authorizationRequests, 1)
    }

    func testTwoRefreshesAtOnceAskOnce() async {
        let center = FakeNotificationCenter()
        center.badge = .notSupported
        let requester = MacBadgeOptionRequester()
        async let one = requester.refresh(on: center, wantsBadge: true)
        async let two = requester.refresh(on: center, wantsBadge: true)
        _ = await (one, two)
        XCTAssertEqual(center.authorizationRequests, 1)
    }

    // MARK: The link

    func testTheLinkOpensConduitsOwnPageByBundleID() {
        XCTAssertEqual(MacNotificationSettingsLink.url(bundleID: "com.example.conduit").absoluteString,
                       plainPage + "?id=com.example.conduit")
        XCTAssertEqual(MacNotificationSettingsLink.url(bundleID: "a b&c=d").absoluteString, plainPage + "?id=a%20b%26c%3Dd",
                       "the id is one query value, whatever it holds")
    }

    func testTheLinkFallsBackToTheNotificationsPageWithoutABundleID() {
        XCTAssertEqual(MacNotificationSettingsLink.url(bundleID: nil).absoluteString, plainPage)
        XCTAssertEqual(MacNotificationSettingsLink.url(bundleID: "").absoluteString, plainPage)
    }

    func testTheLinkHoldsNoBundleIDLiteral() throws {
        let link = MacWordingTests.strippingComments(from: try source("ConduitMac/Notifications/MacBadgePermission.swift"))
        XCTAssertFalse(link.contains("com.milim"), "no bundle id literal")
        XCTAssertFalse(link.contains("com.meswan"), "no bundle id literal")
    }

    // MARK: Wiring

    func testTheRuntimeAsksForTheBadgeOptionAtLaunchAndOnActivation() throws {
        let runtime = MacWordingTests.strippingComments(from: try source("ConduitMac/Notifications/MacNotificationRuntime.swift"))
        XCTAssertTrue(runtime.contains("MacBadgeOptionRequester.shared.refresh(on: center"), "one call, from the live client")
        let opening = "NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in"
        let start = try XCTUnwrap(runtime.range(of: opening), "the activation observer")
        let end = try XCTUnwrap(runtime.range(of: "})", range: start.upperBound..<runtime.endIndex))
        XCTAssertTrue(runtime[start.upperBound..<end.lowerBound].contains("askForBadgeOption()"),
                      "the activation observer asks too (a timer card can make the first request later)")
        // The launch call sits before the observers.
        let ready = try XCTUnwrap(runtime.range(of: "self.coordinator = coordinator"))
        XCTAssertNotNil(runtime.range(of: "askForBadgeOption()", range: ready.upperBound..<start.lowerBound), "the launch call")
    }
}
