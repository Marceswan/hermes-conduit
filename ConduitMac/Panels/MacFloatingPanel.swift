import AppKit
import SwiftUI

struct MacFloatingPanelConfig {
    var size: NSSize                       // initial; height may follow content
    var maxHeight: CGFloat = 480
    var placement: MacFloatingPanelPlacement
    var canBecomeKey: Bool                 // Quick Ask true, notch status false
    var dismissOnResignKey: Bool           // Quick Ask true, notch status false
    var dismissOnEscape: Bool = true
    var level: NSWindow.Level = .floating
    var joinsAllSpaces: Bool = true        // plus fullScreenAuxiliary
    var onDismiss: (() -> Void)? = nil
    /// The notch surface sits in the menu bar band; AppKit would push it below.
    var allowsMenuBarOverlap: Bool = false
    var hasShadow: Bool = true
    var onMouseEntered: (() -> Void)? = nil
    var onMouseExited: (() -> Void)? = nil
}

/// What the controller needs from the machine. Injected so placement is testable.
struct MacFloatingPanelEnvironment {
    var screens: () -> [MacScreenGeometry]
    var mouseLocation: () -> CGPoint
    var reduceMotion: () -> Bool

    static let live = MacFloatingPanelEnvironment(
        screens: {
            NSScreen.screens.map {
                MacScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame, safeAreaTop: $0.safeAreaInsets.top)
            }
        },
        mouseLocation: { NSEvent.mouseLocation },
        reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
}

/// A borderless, non-activating panel: showing it never activates Conduit and
/// never takes the front app's menu bar.
final class MacFloatingPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?
    var allowsMenuBarOverlap = false
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsMenuBarOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class MacFloatingPanelController {
    let panel: MacFloatingPanel
    private let config: MacFloatingPanelConfig
    private let environment: MacFloatingPanelEnvironment
    private var contentSize: CGSize
    private var isHiding = false
    private var screenObserver: NSObjectProtocol?
    /// The frame last requested from the panel (before any AppKit adjustment).
    private(set) var targetFrame: CGRect = .zero

    init<Content: View>(
        config: MacFloatingPanelConfig,
        environment: MacFloatingPanelEnvironment = .live,
        @ViewBuilder content: () -> Content
    ) {
        self.config = config
        self.environment = environment
        self.contentSize = config.size
        let panel = MacFloatingPanel(
            contentRect: NSRect(origin: .zero, size: config.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = config.hasShadow
        panel.level = config.level
        panel.collectionBehavior = config.joinsAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
        panel.allowsKey = config.canBecomeKey
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = []   // the controller owns the panel's size
        panel.contentView = hosting
        panel.allowsMenuBarOverlap = config.allowsMenuBarOverlap
        panel.onMouseEntered = config.onMouseEntered
        panel.onMouseExited = config.onMouseExited
        if config.onMouseEntered != nil || config.onMouseExited != nil {
            hosting.addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: panel, userInfo: nil))
        }
        self.panel = panel
        panel.onCancel = { [weak self] in
            guard let self, self.config.dismissOnEscape else { return }
            self.hide()
        }
        panel.onResignKey = { [weak self] in
            guard let self, self.config.dismissOnResignKey else { return }
            self.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Places the panel, orders it front without activating the app, and makes
    /// it key when the config allows it.
    func show() {
        let wasVisible = panel.isVisible
        place()
        let fade = !wasVisible && !environment.reduceMotion()
        if !wasVisible { panel.alphaValue = fade ? 0 : 1 }
        panel.orderFrontRegardless()
        if config.canBecomeKey { panel.makeKey() }
        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        installScreenObserver()
    }

    /// Orders the panel out and fires `onDismiss` once per visible-to-hidden
    /// transition. Re-entrant calls (AppKit's `resignKey` during `orderOut`) are ignored.
    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        removeScreenObserver()
        panel.orderOut(nil)
        config.onDismiss?()
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// The top edge stays fixed; the panel grows downward, clamped to `maxHeight`.
    func updateContentHeight(_ height: CGFloat) {
        resize(to: CGSize(width: contentSize.width, height: height))
    }

    /// Width and height follow the content (compact capsule vs expanded list);
    /// the top edge and the horizontal center stay put.
    func updateContentSize(_ size: CGSize) {
        resize(to: size)
    }

    // MARK: - Geometry

    func resize(to size: CGSize) {
        contentSize = CGSize(width: size.width, height: min(size.height, config.maxHeight))
        guard panel.isVisible, let screen = currentScreen() else { return }
        targetFrame = MacFloatingPanelPlacement.resized(
            targetFrame, to: contentSize, maxHeight: config.maxHeight, within: bounds(of: screen))
        panel.setFrame(targetFrame, display: true)
    }

    func bounds(of screen: MacScreenGeometry) -> CGRect {
        config.allowsMenuBarOverlap ? screen.frame : screen.visibleFrame
    }

    private func place() {
        let screens = environment.screens()
        guard let index = config.placement.targetScreenIndex(mouse: environment.mouseLocation(), screens: screens) else { return }
        let screen = screens[index]
        targetFrame = config.placement.frame(
            panelSize: contentSize, screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaTop)
        panel.setFrame(targetFrame, display: true)
    }

    private func currentScreen() -> MacScreenGeometry? {
        let screens = environment.screens()
        let probe = CGPoint(x: targetFrame.midX, y: targetFrame.maxY - 1)
        return screens.first { $0.frame.contains(probe) }
            ?? config.placement.targetScreenIndex(mouse: environment.mouseLocation(), screens: screens).map { screens[$0] }
    }

    // MARK: - Screen changes

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}
