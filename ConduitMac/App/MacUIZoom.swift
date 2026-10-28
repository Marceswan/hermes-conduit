import AppKit
import SwiftUI

/// View > Actual Size, Zoom In, Zoom Out (D27): one zoom level for every
/// Conduit window, saved in the defaults. macOS ignores Dynamic Type
/// (`.dynamicTypeSize` does not change a text style's size on the Mac), so the
/// zoom scales each window's content as a whole (`macUIZoom(_:)`), not its fonts.
/// The window toolbar, sheets, popovers and panels keep their size.
@MainActor
enum MacUIZoom {
    static let defaultsKey = "conduit.mac.uiZoom"
    static let actualSize: Double = 1
    /// Safari's steps from 75% to 200%.
    static let levels: [Double] = [0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2]

    enum Step { case zoomIn, zoomOut, actualSize }

    /// Posted on the main thread just before a new level is stored. A chat
    /// transcript holds its latest message in view across the change
    /// (`NSScrollViewChatSurface.zoomWillChange`).
    static let willChangeNotification = Notification.Name("conduit.mac.uiZoomWillChange")

    /// The level to draw at for a stored value: a missing, damaged or
    /// out-of-range value never draws the window at an unusable size.
    static func scale(_ stored: Double) -> CGFloat {
        guard stored.isFinite, stored > 0 else { return CGFloat(actualSize) }
        return CGFloat(min(max(stored, levels[0]), levels[levels.count - 1]))
    }

    /// The level `step` goes to from `current`, or nil when there is none
    /// (the end of the range, or Actual Size at 100%).
    static func target(of step: Step, from current: Double) -> Double? {
        let level = Double(scale(current))
        switch step {
        case .zoomIn: return levels.first { $0 > level + 0.001 }
        case .zoomOut: return levels.last { $0 < level - 0.001 }
        case .actualSize: return abs(level - actualSize) < 0.001 ? nil : actualSize
        }
    }

    /// Runs a View menu zoom command. At the end of the range, and when the
    /// main window's minimum at the new level would not fit its screen,
    /// nothing changes and `refuse` runs (a beep, as in Safari). `fits` and
    /// `refuse` are optional because a main-actor default closure trips Swift 6 isolation.
    @discardableResult
    static func perform(
        _ step: Step,
        defaults: UserDefaults = .standard,
        fits: ((Double) -> Bool)? = nil,
        refuse: (() -> Void)? = nil
    ) -> Bool {
        let refuse = refuse ?? { NSSound.beep() }
        let current = defaults.object(forKey: defaultsKey) as? Double ?? actualSize
        guard let next = target(of: step, from: current) else {
            if step != .actualSize { refuse() }
            return false
        }
        guard step != .zoomIn || (fits ?? { fitsMainWindow($0) })(next) else {
            refuse()
            return false
        }
        NotificationCenter.default.post(name: willChangeNotification, object: nil)
        defaults.set(next, forKey: defaultsKey)
        return true
    }

    // MARK: - Fit

    /// The main window's minimum at 100%: the sidebar and detail columns (`MacSplitLayout`).
    static var windowMinimum: CGSize {
        CGSize(width: MacSidebarState.windowMinWidth, height: MacSidebarState.windowMinHeight)
    }

    /// True when the window minimum at `level`, with `chrome` (the title bar and
    /// toolbar height) on top, fits in `visible`.
    static func fits(_ level: Double, minimum: CGSize, chrome: CGFloat, in visible: CGSize) -> Bool {
        minimum.width * level <= visible.width && minimum.height * level + chrome <= visible.height
    }

    /// The main chat window, checked against the screen it is on. With no main
    /// window there is nothing to grow, so every level fits.
    static func fitsMainWindow(_ level: Double, windows: [NSWindow]? = nil) -> Bool {
        guard let window = (windows ?? NSApp.windows).first(where: { MacSessionTabsActions.isMainChatWindow($0) && $0.isVisible }),
              let screen = window.screen ?? NSScreen.main else { return true }
        let chrome = max(0, window.frame.height - window.contentLayoutRect.height)
        return fits(level, minimum: windowMinimum, chrome: chrome, in: screen.visibleFrame.size)
    }

    // MARK: - Cmd-=

    private static var monitor: Any?

    /// Zoom In shows Cmd-+ (Safari's shortcut). A menu item matches only one of
    /// "+" and "=" (verified on macOS 27), and "+" also takes Shift-= and the
    /// keypad +, so this monitor takes plain Cmd-= as Zoom In. No menu item
    /// may have Cmd-= (MacKeyboardMenuTests).
    static func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPlainZoomInKey(event) else { return event }
            perform(.zoomIn)
            return nil
        }
    }

    static func isPlainZoomInKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.charactersIgnoringModifiers == "="
    }
}

/// Lays its one subview out at the container's size divided by `scale` and
/// reports the subview's size times `scale`, so the subview's
/// `scaleEffect(scale, anchor: .topLeading)` fills the container exactly and a
/// minimum size inside (a column's, a window's) grows with the zoom.
struct MacZoomLayout: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 / scale },
                                                       height: proposal.height.map { $0 / scale }))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale))
    }
}

extension View {
    /// Draws this view at `scale` (D27). Always the same view tree, at 100%
    /// too, so a zoom change keeps scroll positions, focus and typed text.
    /// The safe area (the toolbar over a column) stays in window points.
    func macUIZoom(_ scale: CGFloat) -> some View {
        MacZoomLayout(scale: scale) {
            self.scaleEffect(scale, anchor: .topLeading)
        }
    }
}
