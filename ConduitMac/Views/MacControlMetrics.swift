import CoreGraphics
import SwiftUI

/// Control heights shared by the Mac chrome, so rows of controls line up.
/// Measured on macOS 27: a standard window-toolbar item is a 36 pt glass
/// platter. Everything drawn inside the window (sidebar rows, pane-header
/// buttons) is a desktop-sized `compact` control instead of upstream's 44 pt
/// touch target, so the sidebar reads as a Mac sidebar next to the toolbar.
enum MacControlHeight {
    /// What the system gives a window-toolbar item (the toolbar platter).
    static let regular: CGFloat = 36
    /// Sidebar rows (Workspace + Settings, New Chat + voice + more + folder),
    /// the tab strip container and the Kanban pane-header buttons.
    static let compact: CGFloat = 32
    /// What the system gives a window-toolbar item. Used for the fallback pill
    /// on macOS before 26, where there is no system platter.
    static let toolbarItem: CGFloat = 36
}

/// Sizes of the sidebar's own parts, proportional to `MacControlHeight.compact`.
enum MacSidebarMetrics {
    /// Corner radius of a compact glass control (upstream: 14 on a 44 pt control).
    static let controlRadius: CGFloat = 12
    /// Symbol size inside a compact control (upstream: 16 to 19).
    static let glyphSize: CGFloat = 13
    /// Workspace avatar in the 32 pt pill (upstream: 28 in a 44 pt pill).
    static let avatarSize: CGFloat = 22
    /// Gap between the controls of one row (upstream: 10).
    static let rowGap: CGFloat = 6
    /// Gap between the sidebar's stacked rows (upstream: 16).
    static let stackGap: CGFloat = 10
    /// Filter chip height and horizontal padding (upstream: 27 pt, 11 pt).
    /// Search pill (Kanban, Cron): 32 pt tall (upstream: 40), 10 pt inset (12), 28 pt filter button (32).
    static let searchPillPadding: CGFloat = 10
    static let searchPillButton: CGFloat = 28
    static let chipHeight: CGFloat = 24
    static let chipPadding: CGFloat = 9
    /// A session card's pitch in the list: card plus its top and bottom inset
    /// (upstream: 56 pt measured in a 340 pt column). The card is the pitch less
    /// `sessionRowInset` on each side.
    static let sessionRowPitch: CGFloat = 48
    static let sessionRowInset: CGFloat = 2
    static let sessionIconSize: CGFloat = 24
    static let sessionCardRadius: CGFloat = 12
    static let sessionCardPaddingH: CGFloat = 10
    static let sessionCardPaddingV: CGFloat = 5
}

/// Geometry of the sidebar tab strip: a rounded container with a uniformly
/// inset selection indicator whose radius is concentric with the container's.
enum MacTabStripMetrics {
    /// Gap between the container edge and the indicator, on all four sides.
    static let inset: CGFloat = 3
    static let containerHeight: CGFloat = MacControlHeight.compact
    static let segmentHeight: CGFloat = containerHeight - 2 * inset
    static let containerRadius: CGFloat = MacSidebarMetrics.controlRadius
    static var indicatorRadius: CGFloat { concentricRadius(outer: containerRadius, inset: inset) }

    /// Radius of a shape inset by `inset` inside one of radius `outer`, so the
    /// two corners share a centre. Never negative.
    static func concentricRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }

    /// Frame of segment `index` (equal widths, no gaps) inside a container of
    /// `containerWidth`, before the indicator inset is applied.
    static func segmentFrame(index: Int, count: Int, containerWidth: CGFloat) -> CGRect {
        guard count > 0 else { return .zero }
        let width = containerWidth / CGFloat(count)
        return CGRect(x: CGFloat(index) * width, y: 0, width: width, height: containerHeight)
    }

    /// Frame of the selection indicator for that segment: the segment inset
    /// uniformly, so it is centred on the segment.
    static func indicatorFrame(index: Int, count: Int, containerWidth: CGFloat) -> CGRect {
        segmentFrame(index: index, count: count, containerWidth: containerWidth)
            .insetBy(dx: inset, dy: inset)
    }
}


extension View {
    /// Draws a fixed-size view (the profile avatar, 28 pt) at `size`, and lays it
    /// out at `size` too: a scale then a frame, because the avatar's own frame
    /// cannot be overridden from outside.
    func macCompactAvatar(from natural: CGFloat, to size: CGFloat) -> some View {
        scaleEffect(size / natural).frame(width: size, height: size)
    }
}
