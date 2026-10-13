import CoreGraphics

/// Control heights shared by the Mac chrome, so rows of controls line up.
/// Measured on macOS 27: a standard window-toolbar item is a 36 pt glass
/// platter, which is also the height of the Kanban pane-header buttons and
/// `MacPaneHeader`'s row.
enum MacControlHeight {
    /// Pane-header action buttons and window-toolbar items.
    static let regular: CGFloat = 36
    /// Sidebar rows (Workspace + Settings, New Chat + voice + more + folder).
    /// Matches the 44 pt icon buttons upstream already draws there.
    static let large: CGFloat = 44
    /// What the system gives a window-toolbar item. Used for the fallback pill
    /// on macOS before 26, where there is no system platter.
    static let toolbarItem: CGFloat = 36
}

/// Geometry of the sidebar tab strip: a rounded container with a uniformly
/// inset selection indicator whose radius is concentric with the container's.
enum MacTabStripMetrics {
    /// Gap between the container edge and the indicator, on all four sides.
    static let inset: CGFloat = 4
    static let segmentHeight: CGFloat = MacControlHeight.regular
    static let containerHeight: CGFloat = segmentHeight + 2 * inset
    static let containerRadius: CGFloat = 18
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
