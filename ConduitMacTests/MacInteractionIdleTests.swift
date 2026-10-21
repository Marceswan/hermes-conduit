import AppKit
import UserNotifications
import XCTest
@testable import ConduitMac

/// The Mac side of `InteractionIdleState` (upstream #847): which signals wake the drifting backdrop on a Mac, and
/// the pieces Ruling R24 added around it.
@MainActor
final class MacInteractionIdleTests: XCTestCase {
    // MARK: Notification names (R4 swap in InteractionIdleState)

    /// A model on a fake clock and a fake timer, so a test decides when the deadline arrives.
    private final class Clock {
        var now: TimeInterval = 0
        var pending: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
    }

    private func makeState(_ clock: Clock, center: NotificationCenter) -> InteractionIdleState {
        InteractionIdleState(
            idleAfter: 10,
            now: { clock.now },
            schedule: { delay, fire in
                clock.pending.append((delay, fire))
                return {}
            },
            notificationCenter: center
        )
    }

    /// Lets the state go idle: the clock passes the deadline and the pending timer fires.
    private func goIdle(_ state: InteractionIdleState, _ clock: Clock) {
        clock.now += 20
        clock.pending.removeLast().fire()
        XCTAssertTrue(state.isIdle)
    }

    func testTheThreeMacSignalsWakeAnIdleState() {
        let signals: [(String, Notification.Name)] = [
            ("app becomes active", NSApplication.didBecomeActiveNotification),
            ("text field changes", NSControl.textDidChangeNotification),
            ("text view changes", NSText.didChangeNotification),
        ]
        for (label, name) in signals {
            let center = NotificationCenter()
            let clock = Clock()
            let state = makeState(clock, center: center)
            goIdle(state, clock)
            center.post(name: name, object: nil)
            XCTAssertTrue(HostedTestSupport.waitUntil { !state.isIdle }, "\(label) wakes the backdrop")
            XCTAssertFalse(clock.pending.isEmpty, "\(label) starts the countdown again")
        }
    }

    func testAnUnrelatedNotificationDoesNotWakeIt() {
        let center = NotificationCenter()
        let clock = Clock()
        let state = makeState(clock, center: center)
        goIdle(state, clock)
        center.post(name: NSWindow.didMoveNotification, object: nil)
        HostedTestSupport.settle(0.1)
        XCTAssertTrue(state.isIdle)
    }

    // MARK: Mouse monitor (R24)

    private final class Counter { var count = 0 }

    private func mouseDown(_ type: NSEvent.EventType = .leftMouseDown, at timestamp: TimeInterval = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// A scroll event stamped `seconds` after system start (the throttle reads `NSEvent.timestamp`).
    private func scroll(at seconds: TimeInterval) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        cg.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testClicksAndScrollsNoteInteractionAndKeysAndMovesDoNot() throws {
        let counter = Counter()
        let monitor = MacInteractionIdleMonitor(note: { counter.count += 1 })
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.isRunning)

        NSApp.sendEvent(try mouseDown(.leftMouseDown))
        XCTAssertEqual(counter.count, 1, "left mouse down")
        NSApp.sendEvent(try mouseDown(.rightMouseDown))
        XCTAssertEqual(counter.count, 2, "right mouse down")
        NSApp.sendEvent(try mouseDown(.otherMouseDown))
        XCTAssertEqual(counter.count, 2, "other buttons are not counted")
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        NSApp.sendEvent(key)
        XCTAssertEqual(counter.count, 2, "keys count through the text-change notifications, not here")
    }

    func testScrollingIsNotedOncePerSecond() throws {
        let counter = Counter()
        let monitor = MacInteractionIdleMonitor(note: { counter.count += 1 })
        monitor.start()
        defer { monitor.stop() }
        NSApp.sendEvent(try scroll(at: 5_000))
        XCTAssertEqual(counter.count, 1, "the first scroll event")
        NSApp.sendEvent(try scroll(at: 5_000.2))
        NSApp.sendEvent(try scroll(at: 5_000.9))
        XCTAssertEqual(counter.count, 1, "a gesture's next events within a second add nothing")
        NSApp.sendEvent(try scroll(at: 5_001.1))
        XCTAssertEqual(counter.count, 2, "a second later it is noted again")
    }

    func testStopRemovesTheMonitorAndStartIsIdempotent() throws {
        let counter = Counter()
        let monitor = MacInteractionIdleMonitor(note: { counter.count += 1 })
        monitor.start()
        monitor.start()
        NSApp.sendEvent(try mouseDown())
        XCTAssertEqual(counter.count, 1, "a second start does not install a second monitor")
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        NSApp.sendEvent(try mouseDown())
        XCTAssertEqual(counter.count, 1, "no note after stop")
        monitor.stop()   // harmless
    }

    func testAClickWakesTheBackdropState() throws {
        let center = NotificationCenter()
        let clock = Clock()
        let state = makeState(clock, center: center)
        goIdle(state, clock)
        let monitor = MacInteractionIdleMonitor(note: { state.noteInteraction() })
        monitor.start()
        defer { monitor.stop() }
        NSApp.sendEvent(try mouseDown())
        XCTAssertFalse(state.isIdle, "a click on a Conduit window wakes the backdrop")
    }

    func testTheAppDelegateRemovesTheMonitorAtQuit() {
        MacInteractionIdleMonitor.shared.start()
        XCTAssertTrue(MacInteractionIdleMonitor.shared.isRunning)
        ConduitMacAppDelegate().applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(MacInteractionIdleMonitor.shared.isRunning)
    }

    func testTheAppDelegateStartsWhatConduitAppDelegateStarts() throws {
        // The launch method is skipped under XCTest (global observers), so the source is checked, like
        // `MacWidgetAppSideTests.testLanguageChangeHandlerRepublishesTheWidgetLanguage`.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("ConduitMac/App/ConduitMacAppDelegate.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(source.range(of: "func applicationDidBecomeActive"))
        let body = source[launch.upperBound..<end.lowerBound]
        for call in ["DeviceConditionsMonitor.shared.start()", "MetricKitReports.shared.start()", "MacInteractionIdleMonitor.shared.start()"] {
            XCTAssertTrue(body.contains(call), "applicationDidFinishLaunching starts \(call)")
        }
        // Both upstream calls exist in ConduitAppDelegate, so the list above does not drift from it.
        let upstream = try String(contentsOf: root.appendingPathComponent("Conduit/ConduitApp.swift"), encoding: .utf8)
        XCTAssertTrue(upstream.contains("DeviceConditionsMonitor.shared.start()"))
        XCTAssertTrue(upstream.contains("MetricKitReports.shared.start()"))
    }

    func testTheAppDelegateRemovesTheContactCardsAtQuit() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("ConduitMac/App/ConduitMacAppDelegate.swift"), encoding: .utf8)
        let terminate = try XCTUnwrap(source.range(of: "func applicationWillTerminate"))
        XCTAssertTrue(source[terminate.upperBound...].prefix(600).contains("RichContactVCard.removeAllFiles()"))
    }

    // MARK: Step timers in front (R24)

    func testAStepTimerIsPresentedInFrontWhateverAnotherDelegateWould() {
        let options = MacNotificationDelegate.presentationOverride(forIdentifier: RichStepsMemory.notificationPrefix + "card-1-2")
        XCTAssertEqual(options, [.banner, .list, .sound])
    }

    func testOtherNotificationsAreLeftToTheNormalPath() {
        for identifier in ["conduit.done.abc", "conduit.approval.1", "session-x", "sparkle-update", ""] {
            XCTAssertNil(MacNotificationDelegate.presentationOverride(forIdentifier: identifier), identifier)
        }
    }
}
