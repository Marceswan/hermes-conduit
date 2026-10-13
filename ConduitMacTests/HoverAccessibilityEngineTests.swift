import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

@MainActor
final class HoverAccessibilityEngineTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var boostWasOn = false
    private var engines: [HoverAccessibilityEngine] = []

    override func setUp() {
        super.setUp()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() {
        engines.forEach { $0.process(.deactivated); $0.dismissAll() }
        engines = []
        windows.forEach { $0.close() }
        windows = []
        AccessibilityTreeBoost.set(boostWasOn)
        super.tearDown()
    }

    private func show(_ content: NSView, size: NSSize = NSSize(width: 320, height: 200)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    private func screenPoint(of view: NSView) -> NSPoint {
        let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return view.window!.convertPoint(toScreen: inWindow)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Snapshots

    func testNSButtonSnapshotCarriesRoleAndLabel() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let image = try XCTUnwrap(NSImage(systemSymbolName: "xmark", accessibilityDescription: nil))
        let button = NSButton(image: image, target: nil, action: nil)
        button.setAccessibilityLabel("Close Settings")
        button.frame = NSRect(x: 100, y: 80, width: 40, height: 40)
        container.addSubview(button)
        let window = show(container)
        let snapshot = try XCTUnwrap(HoverAccessibilityEngine.snapshot(at: screenPoint(of: button), in: window))
        XCTAssertEqual(snapshot.role, .button)
        XCTAssertEqual(snapshot.label, "Close Settings")
    }

    func testEmptyBackgroundHasNoDecision() {
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200)))
        let point = window.convertPoint(toScreen: NSPoint(x: 160, y: 100))
        let snapshot = HoverAccessibilityEngine.snapshot(at: point, in: window)
        let decision = snapshot.map { HoverTooltipPolicy.decide($0, highlightEnabled: true) } ?? .none
        XCTAssertEqual(decision, .none)
    }

    /// Real-app condition: no assistive client attached, only the engine's boost.
    func testSwiftUIButtonShapesProduceExpectedDecisions() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let avatar = try XCTUnwrap(NSImage(systemSymbolName: "person", accessibilityDescription: nil))
        let root = VStack(spacing: 14) {
            Button { } label: { Image(systemName: "xmark") }.accessibilityLabel("Close Settings")
            Button("Connect") { }
            Button { } label: { Label("Send", systemImage: "paperplane") }.labelStyle(.iconOnly)
            Button { } label: { Image(systemName: "gear") }.help("Settings")
            Button { } label: { Label("New Chat", systemImage: "plus") }
            Button { } label: { Image(nsImage: avatar) }.accessibilityLabel("Avatar")
            Button("Go") { }.accessibilityLabel("Send message")
            Button("Settings") { }.buttonStyle(.plain)
            Button("Retry") { }.buttonStyle(.plain).font(.caption)
            Button { } label: { Image(systemName: "gear") }.buttonStyle(.plain).accessibilityLabel("Settings")
            Button { } label: { Image(nsImage: avatar) }.buttonStyle(.plain).accessibilityLabel("Add")
            Button { } label: { Image(nsImage: avatar).resizable().frame(width: 28, height: 28) }.buttonStyle(.plain).accessibilityLabel("Profile photo")
        }
        .padding(30)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let window = show(host, size: host.frame.size)

        AccessibilityTreeBoost.set(false)
        XCTAssertTrue((host.accessibilityChildren() ?? []).isEmpty, "without the boost SwiftUI exposes no controls")

        // Time from enabling the boost to the controls appearing.
        let start = Date()
        AccessibilityTreeBoost.set(true)
        while (host.accessibilityChildren() ?? []).isEmpty, Date().timeIntervalSince(start) < 3 { spin(0.005) }
        let repopulateMs = Date().timeIntervalSince(start) * 1000
        print("MEASURE tree repopulation after re-enable: \(Int(repopulateMs)) ms")
        XCTAssertLessThan(repopulateMs, 1000)

        let kids = ((host.accessibilityChildren() ?? []) as [Any]).compactMap { $0 as? NSObject }
        XCTAssertEqual(kids.count, 12, "SwiftUI exposed one accessibility node per button")
        var decisions: [HoverDecision] = []
        for kid in kids {
            let frame: NSValue? = kid.axValue("accessibilityFrame")
            let r = try XCTUnwrap(frame?.rectValue)
            let snapshot = HoverAccessibilityEngine.snapshot(at: NSPoint(x: r.midX, y: r.midY), in: window)
            decisions.append(snapshot.map { HoverTooltipPolicy.decide($0, highlightEnabled: true) } ?? .none)
        }
        let control = { (tip: String?) in HoverDecision(tooltip: tip, showsPointingHand: true, highlights: true) }
        // Observed: SwiftUI exposes no visible-text attribute, so a text button
        // ("Connect", plain "Settings", plain caption "Retry", "New Chat") is
        // told from an icon by label-vs-frame width and aspect ratio.
        XCTAssertEqual(decisions, [
            control("Close Settings"), control(nil), control("Send"), control("Settings"),
            control(nil), control("Avatar"), control("Send message"),
            control(nil), control(nil), control("Settings"), control("Add"), control("Profile photo"),
        ])
    }

    // MARK: Boost lifetime

    private func engine(idle: TimeInterval = 2, trailing: TimeInterval = 0.035, now: @escaping () -> TimeInterval = { 0 },
                        hit: @escaping (NSPoint, NSWindow) -> HoverElementSnapshot? = { _, _ in nil },
                        voiceOver: @escaping () -> Bool = { false }) -> HoverAccessibilityEngine {
        let made = HoverAccessibilityEngine(idleInterval: idle, trailingInterval: trailing, environment: .init(
            isAppActive: { true }, isKeyWindow: { _ in true }, pointerLocation: { .zero },
            now: now, hitTest: hit, highlightEnabled: { true }, isVoiceOverEnabled: voiceOver))
        engines.append(made)
        return made
    }

    func testBoostTurnsOnWhileMovingAndOffAfterClick() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(false)
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let engine = engine()
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
        engine.process(.interaction)
        XCTAssertFalse(AccessibilityTreeBoost.isOn)
    }

    func testBoostTurnsOffWhenAppDeactivates() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let engine = engine()
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))
        engine.process(.deactivated)
        XCTAssertFalse(AccessibilityTreeBoost.isOn)
    }

    func testBoostTurnsOffAfterIdleInterval() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let engine = engine(idle: 0.05)
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
        engine.fireIdleTimerForTesting()
        XCTAssertFalse(AccessibilityTreeBoost.isOn)
    }

    func testBoostLeavesAFlagItDidNotSetAlone() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)  // e.g. VoiceOver already attached
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let engine = engine(idle: 0.05)
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))
        engine.process(.interaction)
        XCTAssertTrue(AccessibilityTreeBoost.isOn, "click must not clear a foreign flag")
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))
        engine.fireIdleTimerForTesting()  // idle timeout
        XCTAssertTrue(AccessibilityTreeBoost.isOn, "idle must not clear a foreign flag")
        engine.process(.deactivated)
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
    }

    func testBoostSetByEngineIsClearedAndRestored() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(false)
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let engine = engine()
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
        engine.process(.interaction)
        XCTAssertFalse(AccessibilityTreeBoost.isOn)
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))  // re-acquires after a click
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
        engine.process(.deactivated)
        XCTAssertFalse(AccessibilityTreeBoost.isOn)
    }

    func testBoostIsNeverClearedWhileVoiceOverIsOnAndOwnershipIsGivenUp() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(false)
        var voiceOverOn = false
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        let engine = engine(voiceOver: { voiceOverOn })
        engine.process(.moved(window, NSPoint(x: 5, y: 5)))
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
        voiceOverOn = true  // VoiceOver attaches mid-hover
        engine.process(.interaction)
        XCTAssertTrue(AccessibilityTreeBoost.isOn, "must not clear the flag while VoiceOver is on")
        voiceOverOn = false  // VoiceOver quits: the engine no longer owns the flag
        engine.process(.deactivated)
        XCTAssertTrue(AccessibilityTreeBoost.isOn, "ownership was given up, so the flag is left alone")
    }

    func testBoostRoundTripsBothDirections() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        XCTAssertTrue(AccessibilityTreeBoost.isOn)
        AccessibilityTreeBoost.set(false)
        XCTAssertFalse(AccessibilityTreeBoost.isOn)
    }

    // MARK: Throttling

    func testMovesInsideCachedFrameHitTestOnce() {
        var clock: TimeInterval = 0
        var hits = 0
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let engine = engine(now: { clock }, hit: { _, _ in
            hits += 1
            return HoverElementSnapshot(role: .button, isEnabled: true, frame: frame)
        })
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        engine.process(.moved(window, NSPoint(x: 10, y: 10)))
        clock = 0.1
        engine.process(.moved(window, NSPoint(x: 20, y: 20)))
        XCTAssertEqual(hits, 1)
        clock = 0.5  // cache lifetime (250 ms) elapsed
        engine.process(.moved(window, NSPoint(x: 20, y: 20)))
        XCTAssertEqual(hits, 2)
        clock = 0.6  // outside the frame and past the ~30 Hz spacing
        engine.process(.moved(window, NSPoint(x: 500, y: 500)))
        XCTAssertEqual(hits, 3)
        engine.process(.interaction)  // click invalidates the cache
        engine.process(.moved(window, NSPoint(x: 20, y: 20)))
        XCTAssertEqual(hits, 4)
        engine.dismissAll()
    }

    func testPointerThatRestsOutsideCachedFrameGetsTrailingEvaluation() {
        var clock: TimeInterval = 0
        var hits = 0
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let engine = engine(trailing: 0.03, now: { clock }, hit: { point, _ in
            hits += 1
            return a.contains(point) ? HoverElementSnapshot(role: .button, isEnabled: true, frame: a) : nil
        })
        let window = show(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        engine.process(.moved(window, NSPoint(x: 10, y: 10)))
        XCTAssertEqual(hits, 1)
        XCTAssertTrue(engine.currentDecision.showsPointingHand)
        clock = 0.01  // 10 ms later: coalesced, served from the cache
        engine.process(.moved(window, NSPoint(x: 500, y: 500)))
        XCTAssertEqual(hits, 1)
        XCTAssertTrue(engine.currentDecision.showsPointingHand, "stale until the trailing pass")
        engine.fireTrailingTimerForTesting()  // pointer rests; the trailing evaluation fires
        XCTAssertEqual(hits, 2)
        XCTAssertEqual(engine.currentDecision, .none)
        engine.dismissAll()
    }

    // MARK: Cursor

    func testCursorRevertsWhenHandStopsShowing() {
        var state = HoverCursorState()
        XCTAssertEqual(state.update(showsHand: false), .none)
        XCTAssertEqual(state.update(showsHand: true), .setHand)
        XCTAssertEqual(state.update(showsHand: true), .setHand)
        XCTAssertEqual(state.update(showsHand: false), .setArrow)
        XCTAssertEqual(state.update(showsHand: false), .none)
    }

    // MARK: Overlay lifetime

    func testClosingParentWindowDetachesHighlight() {
        let a = show(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
        let highlight = HighlightWindow()
        highlight.show(around: CGRect(x: 250, y: 250, width: 40, height: 20), over: a)
        XCTAssertTrue(a === highlight.parent)
        a.close()
        XCTAssertNil(highlight.parent)
        XCTAssertFalse(highlight.isVisible)
    }

    func testHighlightReparentsFromWindowAToWindowB() {
        let a = show(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
        let b = show(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
        let highlight = HighlightWindow()
        highlight.show(around: CGRect(x: 250, y: 250, width: 40, height: 20), over: a)
        highlight.show(around: CGRect(x: 250, y: 250, width: 40, height: 20), over: b)
        XCTAssertTrue(b === highlight.parent)
        XCTAssertFalse(a.childWindows?.contains(highlight) ?? false)
        a.close()  // closing the old parent no longer touches the highlight
        XCTAssertTrue(b === highlight.parent)
        highlight.hide()
    }
}
