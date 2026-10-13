import AppKit

/// App-wide hover layer: tooltips from accessibility labels, a pointing
/// hand over controls, and an optional highlight. One local event monitor
/// serves every window, sheets included.
@MainActor
final class HoverAccessibilityEngine {
    static let shared = HoverAccessibilityEngine()
    static let highlightDefaultsKey = "conduit.mac.hoverHighlight"
    static let restDelay: TimeInterval = 0.6
    /// Elements larger than this are containers; never highlight them.
    static let maxHighlightSize = CGSize(width: 480, height: 160)

    private var monitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var restTimer: Timer?
    private let tooltip = TooltipWindow()
    private let highlight = HighlightWindow()

    static func install() { shared.start() }

    /// SwiftUI builds a hosting view's accessibility tree only while an
    /// assistive client is attached; otherwise `accessibilityHitTest` stops at
    /// the hosting view. Setting AXEnhancedUserInterface (via the legacy NSApplication setter selector, undocumented)
    /// once makes SwiftUI populate the tree.
    /// Trade-off: AppKit may slow or skip some window animations while the
    /// flag is on. It is set only when the hover layer is installed and never
    /// toggled per event.
    static func enableSwiftUIAccessibilityTree() {
        let setter = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))
        if NSApp.responds(to: setter) { _ = NSApp.perform(setter, with: NSNumber(value: true)) }
    }

    func start() {
        UserDefaults.standard.register(defaults: [Self.highlightDefaultsKey: true])
        guard monitor == nil else { return }
        Self.enableSwiftUIAccessibilityTree()
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated { (note.object as? NSWindow)?.acceptsMouseMovedEvents = true }
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .mouseExited]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .mouseMoved, let window = event.window, window.isKeyWindow || window.isMainWindow else {
            dismissAll()
            return
        }
        tooltip.hide()
        restTimer?.invalidate()
        let point = NSEvent.mouseLocation
        let snapshot = Self.snapshot(at: point, in: window)
        let decision = snapshot.map {
            HoverTooltipPolicy.decide($0, highlightEnabled: UserDefaults.standard.bool(forKey: Self.highlightDefaultsKey))
        } ?? .none
        if decision.showsPointingHand { NSCursor.pointingHand.set() }
        if decision.highlights, let frame = snapshot?.frame,
           frame.width <= Self.maxHighlightSize.width, frame.height <= Self.maxHighlightSize.height {
            highlight.show(around: frame, over: window)
        } else {
            highlight.hide()
        }
        guard let text = decision.tooltip else { return }
        restTimer = Timer.scheduledTimer(withTimeInterval: Self.restDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tooltip.show(text, near: point) }
        }
    }

    private func dismissAll() {
        restTimer?.invalidate()
        tooltip.hide()
        highlight.hide()
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
