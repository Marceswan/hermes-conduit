import AppKit
import SwiftUI

/// How wide the window toolbar leaves for the strip's item (D11).
///
/// A flexible `.principal` toolbar item does not grow into free space: its
/// width is its ideal width (measured on macOS 27, `frame(minWidth: 120,
/// idealWidth: 480, maxWidth: .infinity)` is 480 pt in a 1200 pt window), and
/// an ideal wider than the room moves trailing items to the overflow menu. The
/// room is not the gap between the sidebar toggle and the first trailing item:
/// the toolbar keeps its title area (a 160 pt `NSToolbarTitleView`, empty or
/// not) and the principal item starts after it, 4 pt later. Measured with a
/// 1200 pt window: starts at 356 (title area ends at 352), 700 pt fits, 760 pt
/// pushes Refresh out. So the strip asks for the room between the title area
/// and the NEAREST platter to its right, less a safety margin. It never counts
/// the trailing items: the live toolbar has Refresh, the connection status and
/// the window search item (`.searchable` on the sidebar list), and a count
/// that is one short sizes the strip over the item it missed (the flicker
/// fixed in D11's addendum).
///
/// The 4 pt (`titleGap`) and 24 pt (`trailingMargin`) constants were measured
/// on macOS 27 and must be re-checked on each macOS release. The hosted tests
/// `testStripFillsTheToolbarGapWithoutPushingItemsIntoOverflow` and
/// `testToolbarKeepsAllItemsThroughResizeAndSidebarToggle` are the tripwire:
/// if either fails after an OS update, re-measure these two numbers.
///
/// Why the strip cannot oscillate: see `MacToolbarSlotGovernor`.
enum MacToolbarSlot {
    /// Padding the toolbar keeps between its title area and the principal item.
    static let titleGap: CGFloat = 4
    /// Left unused before the first trailing item.
    static let trailingMargin: CGFloat = 24

    /// The platters right of the strip, nearest first. `strip` is the strip's
    /// own platter (or, when it cannot be found, the reader's frame, which
    /// sits inside it); everything starting at or after its right edge
    /// is a trailing item, the overflow button included.
    static func trailing(of strip: CGRect, among platters: [ToolbarPlatter]) -> [ToolbarPlatter] {
        platters.filter { $0.frame.minX >= strip.maxX - 0.5 }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// A round toolbar button's platter, and the width a collapsed search
    /// item (the magnifier) shrinks to.
    static let roundPlatterWidth: CGFloat = 36

    /// How much narrower the platters in `trailing` can get: the toolbar
    /// squeezes the window search field down to a magnifier before it moves
    /// anything into the overflow menu (measured on macOS 27: 249 pt wide
    /// field to 36 pt as the strip grew, Refresh and the status dot moving
    /// right by the same amount). A platter wider than a round button is taken
    /// to be that kind of item; the governor checks the guess (see `MacToolbarSlotGovernor.Mode`).
    static func compressibleSlack(in trailing: [ToolbarPlatter]) -> CGFloat {
        trailing.reduce(0) { total, platter in
            let extra = platter.frame.width - roundPlatterWidth
            return total + (extra > 4 ? extra : 0)
        }
    }

    /// Room for the strip, in the platters' coordinate space, never negative:
    /// from the toolbar's title area plus `titleGap` (the strip's own left
    /// edge when that area cannot be found) to the nearest trailing platter,
    /// less `trailingMargin`. With every item on the toolbar that nearest
    /// platter is where the trailing items start, whatever their number, and
    /// the answer does not depend on the strip's own width. Zero when nothing
    /// trails the strip (the toolbar has not laid out, or every trailing item
    /// is already in the overflow menu): the strip gives up its room and the
    /// items come back. `optimistic` adds the room the trailing items can
    /// give up by squeezing (`compressibleSlack`). `platters` are all the
    /// toolbar's platters, the strip's own included.
    static func availableWidth(titleEnd: CGFloat?, strip: CGRect, among platters: [ToolbarPlatter], optimistic: Bool = false) -> CGFloat {
        let start = titleEnd.map { $0 + titleGap } ?? strip.minX
        let trailing = trailing(of: strip, among: platters)
        guard let nearest = trailing.first else { return 0 }
        let squeeze = optimistic ? compressibleSlack(in: trailing) : 0
        return max(0, nearest.frame.minX + squeeze - start - trailingMargin)
    }

    /// The toolbar items (spacers and separators aside) that are not on the
    /// toolbar, so are in its overflow menu. `all` is every item, `visible`
    /// the ones on the toolbar.
    static func overflowed(all: [String], visible: [String]) -> [String] {
        let shown = Set(visible)
        return all.filter { !$0.hasPrefix("NSToolbar") && !shown.contains($0) }
    }

    /// How many of `window`'s toolbar items are in the overflow menu. Nil when
    /// the window has no toolbar.
    @MainActor
    static func overflowedItemCount(in window: NSWindow) -> Int? {
        guard let toolbar = window.toolbar else { return nil }
        func shouldShow(_ item: NSToolbarItem) -> Bool {
            if #available(macOS 15.0, *) { return !item.isHidden }
            return true
        }
        let all = toolbar.items.filter(shouldShow).map(\.itemIdentifier.rawValue)
        return overflowed(all: all, visible: toolbar.visibleItems?.map(\.itemIdentifier.rawValue) ?? all).count
    }
}

/// The decisions behind the strip's width, apart from AppKit so they can be
/// tested against a simulated toolbar. The reader feeds it what it sees and
/// does what it says.
///
/// Why the strip cannot oscillate (the 0.1.1 flicker was a loop: the width
/// depended on how many trailing items were on the toolbar, and the width
/// decided how many were):
///
/// 1. The width asked for depends only on where the trailing items start (the
///    nearest platter right of the strip), never on a count of them and never
///    on the strip's own width. With every item on the toolbar the trailing
///    items keep their place when the strip changes, so the answer is a fixed
///    point: measuring again at the new width gives the same width.
/// 2. Whatever the geometry cannot know (the trailing items squeezing, an OS
///    change) is caught by a probation. A growth is probationary until the
///    next measurement. If that shows a toolbar item in the overflow menu, or
///    fewer platters right of the strip than before, the growth is undone (the
///    strip goes back to the width it had) and the governor steps down one
///    `Mode`: optimistic (claims the room squeezable items can give up), then
///    conservative (claims only the room up to the trailing items), then
///    frozen (no growth past the width it came from). Only a change of the
///    room itself (window, sidebar) steps back up.
/// 3. So between two such changes the strip grows through successful
///    probations, each ending in a fixed point (1), and a failed one can
///    happen at most twice before frozen forbids growth. The sequence of
///    widths is finite; no state lets growing and shrinking alternate. Items
///    that stay out even at the smallest strip (not the strip's doing) are
///    learned as a floor, after two equal looks, so they do not hold the strip
///    at its minimum.
struct MacToolbarSlotGovernor {
    /// How far to trust the toolbar to make room by squeezing.
    enum Mode: Equatable {
        case optimistic
        case conservative
        case frozen
    }

    enum Step: Equatable {
        /// Give the strip this width, then measure again.
        case set(CGFloat)
        /// The toolbar has not settled; measure again shortly.
        case recheck
        case keep
    }

    private(set) var mode = Mode.optimistic
    private(set) var ceiling: CGFloat?
    private(set) var last: CGFloat?
    private var floorInOverflow = 0
    private var floorCandidate: Int?
    /// The width before the last growth and how many platters trailed the strip then; nil once verified.
    private var growth: (from: CGFloat, trailing: Int)?

    private mutating func apply(_ width: CGFloat) -> Step {
        guard last.map({ abs($0 - width) > 0.5 }) ?? true else { return .keep }
        last = width
        return .set(width)
    }

    /// The room changed for a reason of its own (window, sidebar): start over.
    mutating func roomChanged() {
        mode = .optimistic
        ceiling = nil
        growth = nil
        floorCandidate = nil
    }

    /// A toolbar item came or went: the platter count a growth is judged by is
    /// stale, so only the overflow menu judges it (a growth stays on probation).
    mutating func itemsChanged() { growth = growth.map { ($0.from, 0) } }

    /// The room shrank by `delta`: give it up before the toolbar lays out.
    mutating func shrink(by delta: CGFloat) -> Step {
        guard let last else { return .keep }
        return apply(max(0, last - delta))
    }

    /// The toolbar moved the strip itself to the overflow menu.
    mutating func stripLeftWindow() -> Step {
        if let growth { return undo(growth) }
        return apply(0)
    }

    private mutating func undo(_ failed: (from: CGFloat, trailing: Int)) -> Step {
        growth = nil
        switch mode {
        case .optimistic: mode = .conservative
        case .conservative, .frozen:
            mode = .frozen
            ceiling = failed.from
        }
        return apply(failed.from)
    }

    /// One measurement of a laid-out toolbar. `inOverflow` is how many items
    /// are in the overflow menu, `trailing` how many platters are right of the
    /// strip, `conservative` and `optimistic` the widths `availableWidth` gives.
    mutating func measured(inOverflow: Int, trailing: Int, conservative: CGFloat, optimistic: CGFloat) -> Step {
        floorInOverflow = min(floorInOverflow, inOverflow)
        let lostPlatter = growth.map { trailing < $0.trailing } ?? false
        if inOverflow > floorInOverflow || lostPlatter {
            if let growth { return undo(growth) }
            if (last ?? 0) > 0.5 {
                floorCandidate = nil
                return apply(0)
            }
            // Out even at the smallest strip: wait for a second equal look.
            guard floorCandidate == inOverflow else {
                floorCandidate = inOverflow
                return .recheck
            }
            floorInOverflow = inOverflow
        }
        floorCandidate = nil
        growth = nil
        var width = mode == .optimistic ? optimistic : conservative
        if let ceiling { width = min(width, ceiling) }
        let before = last ?? 0
        let step = apply(width)
        if case .set = step, width > before + 0.5 { growth = (before, trailing) }
        return step
    }
}

/// Reports the toolbar room around the toolbar item it is attached to. Updates
/// one run-loop turn after a window or split-view resize (so it reads the
/// toolbar's post-layout frames), when its own item moves, when a toolbar item
/// comes or goes, and with a few retries while the toolbar has not laid out.
/// Leaving the window (the toolbar moved the item to the overflow menu)
/// reports zero so the item comes back small. The width itself comes from `MacToolbarSlot.availableWidth`
/// through `MacToolbarSlotGovernor`, which also explains why it cannot oscillate.
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
        private var governor = MacToolbarSlotGovernor()
        private var scheduled = false
        private var retries = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                apply(governor.stripLeftWindow())
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
            // An item added to or removed from the toolbar (the sidebar's search
            // item comes with its column) changes what fits and the platter
            // count a growth is judged by. Look again once the toolbar has laid
            // out. Not a reason to trust the toolbar more (no `roomChanged`):
            // a growth that overflows would otherwise loop through it.
            for name in [NSToolbar.didRemoveItemNotification, NSToolbar.willAddItemNotification] {
                observers.append(center.addObserver(forName: name, object: window.toolbar, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.governor.itemsChanged()
                        self?.schedule(after: 0.15)
                    }
                })
            }
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
            governor.roomChanged()
            let now = Self.detailWidth(in: window)
            if let before = detailWidth, now < before { apply(governor.shrink(by: before - now)) }
            detailWidth = now
            schedule()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// A new width is also a reason to measure again: the strip's frame
        /// does not change when the width stays under the strip's minimum, and
        /// the toolbar may not have been laid out when the last measurement ran.
        private func apply(_ step: MacToolbarSlotGovernor.Step) {
            switch step {
            case .set(let width):
                onChange(width)
                schedule()
            case .recheck: schedule(after: 0.1)
            case .keep: break
            }
        }

        /// One run-loop turn later (or `delay`), coalesced: the toolbar lays out after the notification.
        private func schedule(after delay: TimeInterval = 0) {
            guard !scheduled else { return }
            scheduled = true
            let run = { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.measure()
            }
            if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run) } else { DispatchQueue.main.async(execute: run) }
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
            let strip = platters.first { $0.frame.contains(CGPoint(x: own.midX, y: own.midY)) }?.frame ?? own
            let titleEnd = titleEnd(in: window)
            let conservative = MacToolbarSlot.availableWidth(titleEnd: titleEnd, strip: strip, among: platters)
            // A search field being typed in must not be squeezed out from under the user.
            let squeezable = !MacToolbarSearch.isFocused(in: window)
            let optimistic = squeezable
                ? MacToolbarSlot.availableWidth(titleEnd: titleEnd, strip: strip, among: platters, optimistic: true)
                : conservative
            apply(governor.measured(
                inOverflow: MacToolbarSlot.overflowedItemCount(in: window) ?? 0,
                trailing: MacToolbarSlot.trailing(of: strip, among: platters).count,
                conservative: conservative, optimistic: optimistic))
        }
    }
}
