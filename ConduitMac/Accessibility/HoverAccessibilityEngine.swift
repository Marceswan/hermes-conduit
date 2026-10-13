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
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private let restTimer = ReusableTimer()
    private let idleTimer = ReusableTimer()
    private let tooltip = TooltipWindow()
    private let highlight = HighlightWindow()
    private var cache: HitCache?
    private var cursorState = HoverCursorState()
    private var restSnapshot: HoverElementSnapshot?
    private weak var restWindow: NSWindow?
    private static let log = Logger(subsystem: "com.meswan.hermes.mac", category: "hover")

    init(idleInterval: TimeInterval = HoverAccessibilityEngine.idleInterval,
         environment: Environment = .live) {
        self.idleInterval = idleInterval
        self.environment = environment
        restTimer.onFire = { [weak self] in self?.restElapsed() }
        idleTimer.onFire = { [weak self] in self?.setBoost(false) }
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
            dismissAll()
            setBoost(false)
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
        let (snapshot, decision) = lookup(at: point, in: window)
        apply(cursorState.update(showsHand: decision.showsPointingHand))
        if decision.highlights, let frame = snapshot?.frame,
           frame.width <= Self.maxHighlightSize.width, frame.height <= Self.maxHighlightSize.height {
            highlight.show(around: frame, over: window)
        } else {
            highlight.hide()
        }
        if decision.tooltip != nil, let snapshot {
            restSnapshot = snapshot
            restWindow = window
            restTimer.schedule(after: Self.restDelay)
        } else {
            restTimer.cancel()
        }
    }

    /// Hit tests only when the cache cannot answer: the pointer left the
    /// cached element's frame, the window changed, or the cache is stale.
    private func lookup(at point: NSPoint, in window: NSWindow) -> (HoverElementSnapshot?, HoverDecision) {
        let now = environment.now()
        if let cache, cache.window === window {
            let age = now - cache.at
            let insideFrame = cache.snapshot?.frame.contains(point) ?? false
            if (insideFrame && age < Self.cacheLifetime) || age < Self.minHitTestSpacing {
                return (cache.snapshot, cache.decision)
            }
        }
        let snapshot = environment.hitTest(point, window)
        let decision = snapshot.map {
            HoverTooltipPolicy.decide($0, highlightEnabled: environment.highlightEnabled())
        } ?? .none
        cache = HitCache(window: window, snapshot: snapshot, decision: decision, at: now)
        return (snapshot, decision)
    }

    /// The tooltip text is computed here, and only if the pointer rested on a
    /// still-valid element in a still-key window of the active app.
    private func restElapsed() {
        guard let window = restWindow, let snapshot = restSnapshot,
              environment.isAppActive(), environment.isKeyWindow(window) else { return }
        let pointer = environment.pointerLocation()
        guard snapshot.frame.contains(pointer),
              let text = HoverTooltipPolicy.tooltipText(snapshot) else { return }
        tooltip.show(text, near: pointer)
    }

    private func setBoost(_ on: Bool) {
        if !on { idleTimer.cancel() }
        AccessibilityTreeBoost.set(on)
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
