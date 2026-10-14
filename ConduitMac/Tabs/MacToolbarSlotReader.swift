import AppKit
import SwiftUI

/// How wide the window toolbar leaves for the strip's item (D11).
///
/// A flexible `.principal` toolbar item does not grow into free space: its
/// width is its ideal width (measured on macOS 27, `frame(minWidth: 120,
/// idealWidth: 480, maxWidth: .infinity)` is 480 pt in a 1200 pt window), and
/// an ideal wider than the room moves the trailing items to the overflow
/// menu. The room is not the gap between the sidebar toggle and Refresh: the
/// toolbar keeps its title area (a 160 pt `NSToolbarTitleView`, empty or not)
/// and the principal item starts after it, with 4 pt between.
/// Measured with a 1200 pt window: starts at 356 (title area ends at 352),
/// 700 pt fits, 760 pt pushes Refresh out. So the strip asks for the room between the title area and the
/// first trailing item, less a safety margin.
enum MacToolbarSlot {
    /// Padding the toolbar keeps between its title area and the principal item.
    static let titleGap: CGFloat = 4
    /// Left unused before the first trailing item.
    static let trailingMargin: CGFloat = 24

    /// Nil when the toolbar has not laid out (no title area or no trailing
    /// platter), so a guess never reaches the toolbar.
    static func availableWidth(titleEnd: CGFloat?, among platters: [ToolbarPlatter]) -> CGFloat? {
        guard let titleEnd else { return nil }
        let start = titleEnd + titleGap
        guard let trailing = platters.map(\.frame.minX).filter({ $0 > start }).min() else { return nil }
        return max(0, trailing - start - trailingMargin)
    }
}

/// Reports the toolbar room around the toolbar item it is attached to. Updates
/// on window and split-view resizes (the sidebar toggle and drag) and when its
/// own item moves.
struct MacToolbarSlotReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []
        private var last: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            let names: [(Notification.Name, AnyObject?)] = [
                (NSWindow.didResizeNotification, window),
                (NSSplitView.didResizeSubviewsNotification, nil),
                (NSView.frameDidChangeNotification, self),
            ]
            for (name, object) in names {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                })
            }
            // The toolbar lays its items out after the view lands in the window.
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// The right edge of the toolbar's title area, in screen coordinates.
        /// By class name: AppKit has no public handle on it. Nil when this
        /// macOS names it differently, and then the strip keeps its default width.
        private func titleEnd(in window: NSWindow) -> CGFloat? {
            guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return nil }
            func find(_ view: NSView, depth: Int) -> NSView? {
                if String(describing: type(of: view)) == "NSToolbarTitleView" { return view }
                guard depth < 6 else { return nil }
                for sub in view.subviews { if let found = find(sub, depth: depth + 1) { return found } }
                return nil
            }
            guard let title = find(titlebar, depth: 0) else { return nil }
            return window.convertToScreen(title.convert(title.bounds, to: nil)).maxX
        }

        private func measure() {
            guard let window, superview != nil else { return }
            let own = window.convertToScreen(convert(bounds, to: nil))
            let platters = ToolbarPlatterGeometry.platters(in: window, near: own)
            let others = platters.filter { !$0.frame.contains(CGPoint(x: own.midX, y: own.midY)) }
            guard let width = MacToolbarSlot.availableWidth(titleEnd: titleEnd(in: window), among: others) else { return }
            guard last.map({ abs($0 - width) > 0.5 }) ?? true else { return }
            last = width
            onChange(width)
        }
    }
}
