import AppKit
import SwiftUI

/// How wide the window toolbar's principal slot makes the session strip (D11).
///
/// A flexible `.principal` toolbar item does not grow into free space: its
/// width is its ideal width (measured on macOS 27, `frame(minWidth: 120,
/// idealWidth: 480, maxWidth: .infinity)` is 480 pt in a 1200 pt window), and
/// an ideal wider than the room moves trailing items to the overflow menu.
/// So the strip asks for exactly the room it is given, and the room is a pure
/// function of the window: its width, and whether and how wide the sidebar
/// column is. Nothing about the toolbar's own layout (platter positions, which
/// items are visible, the search field's width) feeds back into that width.
///
/// Why it cannot oscillate: the 0.1.1 flicker was a feedback loop (the width
/// came from measuring the trailing platters, and the width decided which
/// trailing items fit). `idealWidth(windowWidth:sidebarWidth:)` takes only the
/// window and sidebar widths, which the toolbar's layout cannot change, so the
/// same window gives the same width however the toolbar lays out, whether an
/// item is in overflow or not, and whether the search field is expanded.
///
/// The reserve. The width is the window less the space left of the strip and
/// the space the trailing items need. Both are sized for the largest set the
/// chat toolbar shows: Refresh, the connection status dot, and the window
/// search item squeezed to its smallest. The constants below were measured in
/// the hosted harness on macOS 27 and must be re-checked on each macOS release;
/// `testStripFillsTheToolbarGapWithoutPushingItemsIntoOverflow` and
/// `testToolbarKeepsAllItemsThroughResizeAndSidebarToggle` are the tripwire.
/// The limit: a trailing item beyond those three, wider than the margin less
/// the spacing, or a search field that will not squeeze, pushes an item into
/// the overflow menu and the strip does not give way (the toolbar stays steady;
/// `testAnExtraWideTrailingItemOverflowsButNothingFlickers`). Clicking the
/// search item expands its field and has the same effect while it is focused;
/// the strip's width does not change because of it. The cost is some unused
/// room when fewer trailing items show (for example before the status dot
/// appears).
enum MacToolbarSlot {
    /// The sidebar column's right edge to the strip's left edge: the toggle's
    /// 8 pt offset, the 36 pt toggle platter, then the title area (a 160 pt
    /// `NSToolbarTitleView`, empty or not) with 4 pt either side.
    static let leadingWithSidebar: CGFloat = 212
    /// The window's left edge to the strip's left edge with the sidebar
    /// hidden: the traffic lights and the system toggle take the corner.
    static let leadingWithoutSidebar: CGFloat = 300
    /// A round toolbar button's platter (Refresh, the status dot, the toggle).
    static let roundPlatterWidth: CGFloat = 36
    /// The window search item at its smallest, a magnifier button.
    static let searchPlatterWidth: CGFloat = 36
    /// The toolbar's gap between neighbouring platters.
    static let platterSpacing: CGFloat = 8
    /// The window's right edge to the last platter's right edge.
    static let trailingEdgeInset: CGFloat = 8
    /// Clear space between the strip and the first trailing item. The toolbar
    /// needs about 16 pt; the rest absorbs a few points of difference between
    /// the hosted harness and the live window.
    static let trailingMargin: CGFloat = 24

    /// Refresh, the status dot and the search item with the two gaps between
    /// them, the right-edge inset and the margin before the first of them.
    static var trailingReserve: CGFloat {
        roundPlatterWidth * 2 + searchPlatterWidth + platterSpacing * 2 + trailingEdgeInset + trailingMargin
    }

    /// The strip's ideal width: from its left edge (after the sidebar column
    /// and the toolbar's leading items, or after the traffic lights when the
    /// sidebar is hidden) to the trailing reserve. At least `minWidth`, never
    /// negative, and non-decreasing in `windowWidth`. `sidebarWidth` is the
    /// visible sidebar column's width, zero when it is hidden or absent.
    static func idealWidth(windowWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat {
        let start = sidebarWidth > 0 ? sidebarWidth + leadingWithSidebar : leadingWithoutSidebar
        return max(MacSessionTabMetrics.minWidth, windowWidth - start - trailingReserve)
    }
}

/// Reports the width the toolbar's principal slot gives the strip (see
/// `MacToolbarSlot`): recomputed when the window or its split view resizes
/// (the sidebar toggle and drag), and once when the strip joins a window. It
/// reads only the window's and the sidebar's widths, never the toolbar.
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
            // A strip the toolbar moved to the overflow menu leaves the window.
            // It keeps its width: shrinking it would make the toolbar's layout
            // an input again (shrink, return, grow, leave, ...).
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.roomChanged() }
            })
            // Only this window's split views (the sidebar toggle and drag).
            observers.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSView)?.window === self.window else { return }
                    self.roomChanged()
                }
            })
            // Not inside SwiftUI's update pass that attached the view.
            schedule()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// The width of the visible sidebar column, zero when it is collapsed or there is no split view.
        /// The app's window holds one `NSSplitView` under the theme frame, the navigation split, so the
        /// first one found is the sidebar's; `MacToolbarRealWindowTests` pins that in a window shaped like
        /// the `WindowGroup`'s, and that its width does not move with the strip's.
        static func sidebarWidth(in window: NSWindow) -> CGFloat {
            func findSplit(_ view: NSView, depth: Int) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                guard depth < 8 else { return nil }
                for sub in view.subviews { if let found = findSplit(sub, depth: depth + 1) { return found } }
                return nil
            }
            guard let root = window.contentView?.superview, let split = findSplit(root, depth: 0),
                  let first = split.arrangedSubviews.first, !split.isSubviewCollapsed(first) else { return 0 }
            return first.frame.width
        }

        /// The width the window and sidebar give the strip now.
        private func target() -> CGFloat? {
            guard let window else { return nil }
            return MacToolbarSlot.idealWidth(windowWidth: window.frame.width, sidebarWidth: Self.sidebarWidth(in: window))
        }

        /// The window or the sidebar changed size. A narrower room is given up
        /// at once, inside the resize: the toolbar lays out before the next
        /// run-loop turn, and a strip still asking for the old, wider ideal
        /// would push the trailing items (and itself) into the overflow menu,
        /// where its width is no longer read. A wider room is taken one turn
        /// later, after the toolbar has laid out. Both are the same pure
        /// function of the window; only the timing differs.
        private func roomChanged() {
            if let width = target(), let last, width < last - 0.5 { report(width) }
            schedule()
        }

        private var scheduled = false

        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                if let width = self.target() { self.report(width) }
            }
        }

        private func report(_ width: CGFloat) {
            guard last.map({ abs($0 - width) > 0.5 }) ?? true else { return }
            last = width
            onChange(width)
        }
    }
}
