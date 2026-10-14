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
/// and the principal item starts after it, 4 pt later. Measured with a 1200 pt
/// window: starts at 356 (title area ends at 352), 700 pt fits, 760 pt pushes
/// Refresh out. So the strip asks for the room between the title area and the
/// first trailing item, less a safety margin.
///
/// The 4 pt (`titleGap`) and 24 pt (`trailingMargin`) constants were measured
/// on macOS 27 and must be re-checked on each macOS release. The hosted tests
/// `testStripFillsTheToolbarGapWithoutPushingItemsIntoOverflow` and
/// `testToolbarKeepsAllItemsThroughResizeAndSidebarToggle` are the tripwire:
/// if either fails after an OS update, re-measure these two numbers.
enum MacToolbarSlot {
    /// Padding the toolbar keeps between its title area and the principal item.
    static let titleGap: CGFloat = 4
    /// Left unused before the first trailing item.
    static let trailingMargin: CGFloat = 24
    /// Refresh and the connection status. Fewer trailing platters than this
    /// means the toolbar has already pushed one into the overflow menu (or has
    /// not laid out), and the strip must shrink to let it back.
    static let expectedTrailingItems = 2

    /// Room for the strip, in the platters' coordinate space, never negative.
    /// `platters` are all the toolbar's platters, the strip's own included.
    /// The start is the toolbar's title area plus `titleGap`; when that area
    /// cannot be found, the strip's own left edge. Nil when neither is known.
    /// The trailing items are the `expectedTrailingItems` rightmost platters
    /// right of the start: with Refresh pushed into overflow they are the
    /// strip and the status dot, so the answer collapses to the strip's own
    /// left edge and the strip shrinks, instead of the status dot's larger
    /// room keeping Refresh out. Zero when there are fewer than that.
    static func availableWidth(titleEnd: CGFloat?, ownMinX: CGFloat?, among platters: [ToolbarPlatter]) -> CGFloat? {
        guard let start = titleEnd.map({ $0 + titleGap }) ?? ownMinX else { return nil }
        let right = platters.map(\.frame.minX).filter { $0 > start }.sorted(by: >).prefix(expectedTrailingItems)
        guard right.count == expectedTrailingItems, let first = right.last else { return 0 }
        return max(0, first - start - trailingMargin)
    }
}

/// Reports the toolbar room around the toolbar item it is attached to. Updates
/// one run-loop turn after a window or split-view resize (so it reads the
/// toolbar's post-layout frames), when its own item moves, and with a few
/// retries while the toolbar has not laid out. Leaving the window (the toolbar
/// moved the item to the overflow menu) reports zero so the item comes back
/// small.
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
        private var scheduled = false
        private var retries = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(0)
                return
            }
            postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutChanged() }
            })
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
            // Only this window's split views (the sidebar toggle and drag).
            observers.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSView)?.window === self.window else { return }
                    self.layoutChanged()
                }
            })
            retries = 0
            detailWidth = Self.detailWidth(in: window)
            schedule()
        }

        // MARK: Shrinking ahead of the toolbar

        /// The window's width less the visible sidebar column: the room the toolbar has.
        private var detailWidth: CGFloat?

        private static func detailWidth(in window: NSWindow) -> CGFloat {
            func findSplit(_ view: NSView, depth: Int) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                guard depth < 8 else { return nil }
                for sub in view.subviews { if let found = findSplit(sub, depth: depth + 1) { return found } }
                return nil
            }
            var sidebar: CGFloat = 0
            if let root = window.contentView?.superview, let split = findSplit(root, depth: 0),
               let first = split.arrangedSubviews.first, !split.isSubviewCollapsed(first) {
                sidebar = first.frame.width
            }
            return window.frame.width - sidebar
        }

        /// A window or sidebar change. The toolbar lays out before the next
        /// run-loop turn, and an item wider than the room it is left leaves the
        /// window for the overflow menu and cannot be measured again. So the
        /// strip gives up the room the toolbar just lost at once, and the
        /// measurement one turn later, after layout, grows it back.
        private func layoutChanged() {
            guard let window else { return }
            let now = Self.detailWidth(in: window)
            if let before = detailWidth, now < before, let last { report(max(0, last - (before - now))) }
            detailWidth = now
            schedule()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        private func report(_ width: CGFloat) {
            guard last.map({ abs($0 - width) > 0.5 }) ?? true else { return }
            last = width
            onChange(width)
        }

        /// One run-loop turn later, coalesced: the toolbar lays out after the notification.
        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.measure()
            }
        }

        /// The right edge of the toolbar's title area, in screen coordinates.
        /// By class name: AppKit has no public handle on it. Nil when this
        /// macOS names it differently; the strip then measures from its own left edge.
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
            // No platters at all: the toolbar is not laid out yet, or lives in
            // another window (full screen). Keep what we have and look again.
            guard !platters.isEmpty else {
                if retries < 20 {
                    retries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.schedule() }
                }
                return
            }
            retries = 0
            let mine = platters.first { $0.frame.contains(CGPoint(x: own.midX, y: own.midY)) }
            guard let width = MacToolbarSlot.availableWidth(
                titleEnd: titleEnd(in: window), ownMinX: (mine?.frame.minX ?? own.minX) + 1, among: platters) else { return }
            report(width)
        }
    }
}
