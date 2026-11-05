import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import ConduitMac

/// D31 fix (2026-10-28): the note, its button and the permission read in Settings > Notifications > On this Mac.
///
/// The notification center is `FakeNotificationCenter`, the link opens through a closure (System Settings never
/// opens), and defaults come from a throwaway suite (the user's domain is never read).
@MainActor
final class MacBadgeSettingsNoteTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
    }

    override func tearDown() async throws {
        HostedTestSupport.dropSuite(suite)
    }

    private let plainPage = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheViewReadsTheBundleIDFromTheMainBundleAndHoldsNoLiteral() throws {
        let view = MacWordingTests.strippingComments(from: try source("ConduitMac/Views/MacNotificationSettingsView.swift"))
        XCTAssertTrue(view.contains("Bundle.main.bundleIdentifier"))
        XCTAssertFalse(view.contains("com.milim"), "no bundle id literal")
        XCTAssertFalse(view.contains("com.meswan"), "no bundle id literal")
    }

    // MARK: Hosted view

    private final class Opened {
        var urls: [URL] = []
    }

    private func settingsView(
        center: FakeNotificationCenter, showsCount: Bool? = nil, bundleID: String? = "com.example.conduit", opened: Opened? = nil
    ) -> NSWindow {
        if let showsCount { suite.defaults.set(showsCount, forKey: MacDockBadge.defaultsKey) }
        let preferences = MacNotificationPreferences(defaults: suite.defaults)
        let log = opened ?? Opened()
        return HostedTestSupport.host(
            MacNotificationSettingsView(
                preferences: preferences, authorization: .allowed, dockDefaults: suite.defaults,
                client: center, requester: MacBadgeOptionRequester(), bundleID: bundleID, openURL: { log.urls.append($0) }
            ),
            size: NSSize(width: 520, height: 640)
        )
    }

    private var noteText: String { AppLocalization.string("Mac.DockBadge.PermissionNote") }
    private var openLabel: String { AppLocalization.string("Open System Settings") }

    private func withAccessibilityTree(_ body: () throws -> Void) throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let boostWasOn = AccessibilityTreeBoost.isOn
        AccessibilityTreeBoost.set(true)
        defer { AccessibilityTreeBoost.set(boostWasOn) }
        try body()
    }

    private func texts(_ window: NSWindow) -> [String] { AccessibilityProbe.texts(in: window) }

    private func showsNote(_ window: NSWindow) -> Bool { texts(window).contains { $0.contains(noteText) } }

    private func hasOpenButton(_ window: NSWindow) -> Bool { AccessibilityProbe.labels(in: window).contains(openLabel) }

    func testTheNoteAndTheButtonShowWhenTheCountIsOnAndBadgesAreNot() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.badge = .notSupported
            let window = settingsView(center: center)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { showsNote(window) }, "the note sits under the toggle")
            XCTAssertTrue(HostedTestSupport.waitUntil { hasOpenButton(window) })
            XCTAssertNotEqual(noteText, "Mac.DockBadge.PermissionNote", "the key resolves")
            XCTAssertTrue(noteText.contains("System Settings > Notifications"))
        }
    }

    func testTheViewAsksAgainOnceAndShowsTheNoteWhenTheRequestChangesNothing() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.badge = .notSupported
            let window = settingsView(center: center)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { center.authorizationRequests == 1 })
            XCTAssertTrue(HostedTestSupport.waitUntil { showsNote(window) })
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            HostedTestSupport.settle(0.3)
            XCTAssertEqual(center.authorizationRequests, 1, "a second activation does not ask again")
        }
    }

    func testNoNoteWhenBadgesAreEnabled() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.badge = .enabled
            let window = settingsView(center: center)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { center.settingsReads > 0 })
            HostedTestSupport.settle(0.3)
            XCTAssertFalse(showsNote(window))
            XCTAssertFalse(hasOpenButton(window))
        }
    }

    func testNoNoteWhileTheCountIsOff() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.badge = .notSupported
            let window = settingsView(center: center, showsCount: false)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { center.settingsReads > 0 })
            HostedTestSupport.settle(0.3)
            XCTAssertFalse(showsNote(window))
            XCTAssertEqual(center.authorizationRequests, 0, "no badge is wanted, so nothing is requested")
        }
    }

    func testTheNoteFollowsTheToggle() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.badge = .notSupported
            let window = settingsView(center: center, showsCount: true)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { showsNote(window) })
            suite.defaults.set(false, forKey: MacDockBadge.defaultsKey)
            XCTAssertTrue(HostedTestSupport.waitUntil { !showsNote(window) }, "the toggle turns the note off")
            suite.defaults.set(true, forKey: MacDockBadge.defaultsKey)
            XCTAssertTrue(HostedTestSupport.waitUntil { showsNote(window) }, "and on again")
        }
    }

    func testNoNoteForAStatusThatIsNotAllowed() throws {
        try withAccessibilityTree {
            for status in [UNAuthorizationStatus.notDetermined, .denied] {
                let center = FakeNotificationCenter()
                center.status = status
                center.badge = .notSupported
                let window = settingsView(center: center)
                defer { HostedTestSupport.tearDown(window) }
                XCTAssertTrue(HostedTestSupport.waitUntil { center.settingsReads > 0 })
                HostedTestSupport.settle(0.3)
                XCTAssertFalse(showsNote(window), "status \(status.rawValue)")
                XCTAssertEqual(center.authorizationRequests, 0, "status \(status.rawValue)")
            }
        }
    }

    func testTheButtonOpensConduitsPageAndNothingElse() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.badge = .notSupported
            let opened = Opened()
            let window = settingsView(center: center, bundleID: "com.example.conduit", opened: opened)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { hasOpenButton(window) })
            XCTAssertTrue(AccessibilityProbe.press(openLabel, in: window))
            XCTAssertEqual(opened.urls.map(\.absoluteString), [plainPage + "?id=com.example.conduit"])
        }
    }

    func testThePermissionIsReadAgainWhenTheAppBecomesActive() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.badge = .notSupported
            let window = settingsView(center: center)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { showsNote(window) })
            let reads = center.settingsReads
            // The user allowed badges in System Settings and came back to Conduit.
            center.badge = .enabled
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            XCTAssertTrue(HostedTestSupport.waitUntil { center.settingsReads > reads }, "the permission is read on activation")
            XCTAssertTrue(HostedTestSupport.waitUntil { !showsNote(window) }, "the note goes away")
            XCTAssertFalse(hasOpenButton(window))
        }
    }

    func testTheDeniedStatusKeepsItsOwnButtonAndGetsNoSecondOne() throws {
        try withAccessibilityTree {
            let center = FakeNotificationCenter()
            center.status = .denied
            let window = settingsView(center: center)
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { center.settingsReads > 0 })
            XCTAssertTrue(HostedTestSupport.waitUntil { hasOpenButton(window) }, "the Status row's button")
            let buttons = AccessibilityProbe.nodes(in: window).filter { $0.label == openLabel }
            XCTAssertEqual(buttons.count, 1)
        }
    }
}
