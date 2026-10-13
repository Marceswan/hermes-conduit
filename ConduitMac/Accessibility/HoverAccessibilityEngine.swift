import AppKit
import os

/// Pointer-cursor bookkeeping: the hand must be reverted when no longer shown.
struct HoverCursorState {
    enum Action: Equatable { case setHand, setArrow, none }
    private(set) var handActive = false

    mutating func update(showsHand: Bool) -> Action {
        defer { handActive = showsHand }
        if showsHand { return .setHand }
        return handActive ? .setArrow : .none
    }
}

/// One timer reused for every schedule. A fresh `Timer` per mouse move would
/// churn the run loop at event rate.
@MainActor
final class ReusableTimer {
    private var timer: Timer?
    var onFire: () -> Void = {}

    func schedule(after interval: TimeInterval) {
        if let timer {
            timer.fireDate = Date(timeIntervalSinceNow: interval)
            return
        }
        let created = Timer(fire: Date(timeIntervalSinceNow: interval), interval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
                self?.onFire()
            }
        }
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    func cancel() { timer?.fireDate = .distantFuture }
}

/// App-wide hover layer: tooltips from accessibility labels, a pointing
/// hand over controls, and an optional highlight. One local event monitor
/// serves every window, sheets included.
@MainActor
final class HoverAccessibilityEngine {
    enum Input {
        case moved(NSWindow, NSPoint)
        /// Click, key, scroll, pointer exit or live resize.
        case interaction
        /// App or window lost focus.
        case deactivated
    }

    /// Everything the engine reads from the system, injectable for tests.
    struct Environment {
        var isAppActive: @MainActor () -> Bool
        var isKeyWindow: @MainActor (NSWindow) -> Bool
        var pointerLocation: @MainActor () -> NSPoint
        var now: @MainActor () -> TimeInterval
        var hitTest: @MainActor (NSPoint, NSWindow) -> HoverElementSnapshot?
        var highlightEnabled: @MainActor () -> Bool
        var isVoiceOverEnabled: @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }

        static let live = Environment(
            isAppActive: { NSApp.isActive },
            isKeyWindow: { $0.isKeyWindow },
            pointerLocation: { NSEvent.mouseLocation },
            now: { ProcessInfo.processInfo.systemUptime },
            hitTest: { HoverAccessibilityEngine.snapshot(at: $0, in: $1) },
            highlightEnabled: { UserDefaults.standard.bool(forKey: HoverAccessibilityEngine.highlightDefaultsKey) }
        )
    }

    static let shared = HoverAccessibilityEngine()
    static let highlightDefaultsKey = "conduit.mac.hoverHighlight"
    /// Hidden kill switch: `defaults write com.meswan.hermes.mac conduit.mac.hoverTooltipsDisabled -bool YES`.
    static let disabledDefaultsKey = "conduit.mac.hoverTooltipsDisabled"
    static let restDelay: TimeInterval = 0.6
    /// The boost is dropped after this long without pointer movement.
    static let idleInterval: TimeInterval = 2
    /// A cached hit result is trusted for this long while inside its frame.
    static let cacheLifetime: TimeInterval = 0.25
    /// Outside a cached frame, hit tests run at most this often (~30 Hz).
    static let minHitTestSpacing: TimeInterval = 1.0 / 30
    /// A move served from the coalescing window is re-evaluated this long after.
    static let trailingInterval: TimeInterval = 0.035
    /// Elements larger than this are containers; never highlight them.
    static let maxHighlightSize = CGSize(width: 480, height: 160)

    private struct HitCache {
        weak var window: NSWindow?
        var snapshot: HoverElementSnapshot?
        var decision: HoverDecision
        var at: TimeInterval
    }

    private let environment: Environment
    private let idleInterval: TimeInterval
    private let trailingInterval: TimeInterval
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private let restTimer = ReusableTimer()
    private let idleTimer = ReusableTimer()
    private let trailingTimer = ReusableTimer()
    private var trailingTarget: (window: NSWindow, point: NSPoint)?
    /// True only while this engine, not VoiceOver or another client, holds
    /// the flag on, so it never switches off a flag it did not set.
    private var ownsBoost = false
    private var boostFailed = false
    private(set) var currentDecision = HoverDecision.none
    private let tooltip = TooltipWindow()
    private let highlight = HighlightWindow()
    private var cache: HitCache?
    private var cursorState = HoverCursorState()
    private weak var restWindow: NSWindow?
    private static let log = Logger(subsystem: "com.meswan.hermes.mac", category: "hover")

    init(idleInterval: TimeInterval = HoverAccessibilityEngine.idleInterval,
         trailingInterval: TimeInterval = HoverAccessibilityEngine.trailingInterval,
         environment: Environment = .live) {
        self.idleInterval = idleInterval
        self.trailingInterval = trailingInterval
        self.environment = environment
        restTimer.onFire = { [weak self] in self?.restElapsed() }
        idleTimer.onFire = { [weak self] in self?.setBoost(false) }
        trailingTimer.onFire = { [weak self] in self?.trailingEvaluation() }
    }

    static func install() {
        guard !UserDefaults.standard.bool(forKey: disabledDefaultsKey) else { return }
        shared.start()
    }

    func start() {
        UserDefaults.standard.register(defaults: [Self.highlightDefaultsKey: true])
        guard monitor == nil else { return }
        if !AccessibilityTreeBoost.isAvailable {
            Self.log.warning("Accessibility tree boost unavailable; SwiftUI controls may not get hover tooltips")
        }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { (note.object as? NSWindow)?.acceptsMouseMovedEvents = true }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.process(.deactivated) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.process(.deactivated) }
            },
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.process(.interaction) }
            },
        ]
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .mouseExited]
        ) { [weak self] event in
            if event.type == .mouseMoved, let window = event.window {
                self?.process(.moved(window, NSEvent.mouseLocation))
            } else {
                self?.process(.interaction)
            }
            return event
        }
    }

    func process(_ input: Input) {
        switch input {
        case .interaction, .deactivated:
            cache = nil
            trailingTimer.cancel()
            dismissAll()
            setBoost(false)
            if case .deactivated = input { boostFailed = false }
        case let .moved(window, point):
            guard environment.isAppActive(), environment.isKeyWindow(window) else {
                process(.deactivated)
                return
            }
            setBoost(true)
            idleTimer.schedule(after: idleInterval)
            moved(in: window, to: point)
        }
    }

    private func moved(in window: NSWindow, to point: NSPoint) {
        tooltip.hide()
        let (snapshot, decision, servedStale) = lookup(at: point, in: window)
        currentDecision = decision
        if servedStale {
            trailingTarget = (window, point)
            trailingTimer.schedule(after: trailingInterval)
        } else {
            trailingTimer.cancel()
        }
        apply(cursorState.update(showsHand: decision.showsPointingHand))
        if decision.highlights, let frame = snapshot?.frame,
           frame.width <= Self.maxHighlightSize.width, frame.height <= Self.maxHighlightSize.height {
            highlight.show(around: frame, over: window)
        } else {
            highlight.hide()
        }
        if decision.tooltip != nil, let snapshot {
            restWindow = window
            restTimer.schedule(after: Self.restDelay)
        } else {
            restTimer.cancel()
        }
    }

    /// Hit tests only when the cache cannot answer: the pointer left the
    /// cached element's frame, the window changed, or the cache is stale.
    /// `servedStale` is true when the cache answered although the pointer is
    /// outside its frame (30 Hz coalescing); the caller must then schedule a
    /// trailing evaluation so a pointer that comes to rest is not left with
    /// the old control's state.
    private func lookup(at point: NSPoint, in window: NSWindow)
        -> (snapshot: HoverElementSnapshot?, decision: HoverDecision, servedStale: Bool) {
        let now = environment.now()
        if let cache, cache.window === window {
            let age = now - cache.at
            let insideFrame = cache.snapshot?.frame.contains(point) ?? false
            if insideFrame && age < Self.cacheLifetime {
                return (cache.snapshot, cache.decision, false)
            }
            if !insideFrame && age < Self.minHitTestSpacing {
                return (cache.snapshot, cache.decision, true)
            }
        }
        let snapshot = environment.hitTest(point, window)
        let decision = snapshot.map {
            HoverTooltipPolicy.decide($0, highlightEnabled: environment.highlightEnabled())
        } ?? .none
        cache = HitCache(window: window, snapshot: snapshot, decision: decision, at: now)
        return (snapshot, decision, false)
    }

    /// Test hooks: run the timer callbacks directly instead of waiting on the run loop.
    func fireIdleTimerForTesting() { idleTimer.onFire() }
    func fireTrailingTimerForTesting() { trailingTimer.onFire() }

    private func trailingEvaluation() {
        guard let target = trailingTarget, environment.isAppActive(),
              environment.isKeyWindow(target.window) else { return }
        cache = nil  // force a fresh hit test at the latest pointer location
        moved(in: target.window, to: target.point)
    }

    /// The tooltip text is computed here, and only if a fresh lookup at the
    /// pointer still finds the element, in a still-key window of the active app.
    private func restElapsed() {
        guard let window = restWindow, environment.isAppActive(), environment.isKeyWindow(window) else { return }
        let pointer = environment.pointerLocation()
        guard let current = lookup(at: pointer, in: window).snapshot,
              current.frame.contains(pointer),
              let text = HoverTooltipPolicy.tooltipText(current) else { return }
        tooltip.show(text, near: pointer)
    }

    private func setBoost(_ on: Bool) {
        if on {
            guard !boostFailed, !ownsBoost, !AccessibilityTreeBoost.isOn else { return }
            AccessibilityTreeBoost.set(true)
            if AccessibilityTreeBoost.isOn {
                ownsBoost = true
            } else {
                boostFailed = true
                Self.log.error("Accessibility tree boost did not turn on; disabled until next activation")
            }
        } else {
            idleTimer.cancel()
            guard ownsBoost else { return }
            ownsBoost = false
            // VoiceOver may have attached while this engine held the flag.
            // Switching it off would break VoiceOver, so give up ownership.
            guard !environment.isVoiceOverEnabled() else { return }
            AccessibilityTreeBoost.set(false)
            if AccessibilityTreeBoost.isOn {
                boostFailed = true
                Self.log.error("Accessibility tree boost did not turn off; disabled until next activation")
            }
        }
    }

    private func apply(_ action: HoverCursorState.Action) {
        switch action {
        case .setHand: NSCursor.pointingHand.set()
        case .setArrow: NSCursor.arrow.set()
        case .none: break
        }
    }

    func dismissAll() {
        restTimer.cancel()
        tooltip.hide()
        highlight.hide()
        apply(cursorState.update(showsHand: false))
    }

    /// Reads the accessibility element under `screenPoint`, climbing to the
    /// nearest interactive or image ancestor. SwiftUI reports its elements as
    /// `SwiftUI.AccessibilityNode`, which answers the NSObject accessibility
    /// selectors but does not conform to `NSAccessibilityProtocol` (casting
    /// crashes), so every attribute is read dynamically.
    static func snapshot(at screenPoint: NSPoint, in window: NSWindow?) -> HoverElementSnapshot? {
        guard let window else { return nil }
        var current = window.accessibilityHitTest(screenPoint) as? NSObject
        for _ in 0..<4 {
            guard let element = current else { return nil }
            if let snapshot = snapshot(of: element) { return snapshot }
            current = element.axValue("accessibilityParent")
        }
        return nil
    }

    /// Snapshot of `element` itself, or nil when it is not a control or image.
    /// An AppKit hit lands on the control's cell, whose label is auto-derived
    /// (an xmark image reads "Close"), so text attributes come from the cell's
    /// control view, where the app's own labels live.
    static func snapshot(of element: NSObject) -> HoverElementSnapshot? {
        guard let rawRole: String = element.axValue("accessibilityRole") else { return nil }
        let role = NSAccessibility.Role(rawValue: rawRole)
        guard HoverTooltipPolicy.interactiveRoles.contains(role) || role == .image else { return nil }
        let source: NSObject = (element as? NSCell)?.controlView ?? element
        let frame: NSValue? = element.axValue("accessibilityFrame")
        let isSwiftUINode = String(reflecting: type(of: element)).hasPrefix("SwiftUI.")
        let identifier: String? = element.axValue("accessibilityIdentifier")
        return HoverElementSnapshot(
            role: role,
            label: source.axValue("accessibilityLabel"),
            title: source.axValue("accessibilityTitle"),
            help: source.axValue("accessibilityHelp"),
            imageIdentifier: isSwiftUINode ? (identifier ?? "") : nil,
            isEnabled: (element.axValue("accessibilityEnabled") as NSNumber?)?.boolValue ?? true,
            frame: frame?.rectValue ?? .zero
        )
    }
}

extension NSObject {
    /// Reads a zero-argument accessibility getter by name, nil when the
    /// object does not implement it.
    func axValue<T>(_ getter: String) -> T? {
        let selector = Selector(getter == "accessibilityEnabled" ? "isAccessibilityEnabled" : getter)
        guard responds(to: selector) else { return nil }
        return value(forKey: getter) as? T
    }
}
