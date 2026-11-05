import AppKit

enum NotchStyle: Equatable {
    /// Wings around the physical notch: the standard placement on a notch display only.
    case wings
    /// A capsule: the standard placement without a notch, and every docked placement.
    case pill
}

enum NotchAxis: Equatable { case horizontal, vertical }

/// The direction the expanded panel opens: always inward from the docked edge.
enum NotchGrowth: Equatable { case down, up, right, left }

/// Which corners are rounded: the ones facing away from the screen edge.
enum NotchInwardSide: Equatable { case bottom, top, trailing, leading }

struct NotchLayout: Equatable {
    var style: NotchStyle
    var compactAxis: NotchAxis
    var growth: NotchGrowth
    var inwardSide: NotchInwardSide
    /// The docked edge; nil for the standard placement.
    var dockEdge: NSRectEdge?

    var isDocked: Bool { dockEdge != nil }
    /// The drag grip sits next to the docked edge: at the bottom for a bottom dock, else at the top.
    var gripAtBottom: Bool { growth == .up }

    /// Rows are stacked vertically in every layout; only the compact capsule,
    /// the growth direction and the corners change per edge.
    static func make(standardIsNotch: Bool, dock: MacEdgeDock?) -> NotchLayout {
        guard let dock else {
            return NotchLayout(style: standardIsNotch ? .wings : .pill, compactAxis: .horizontal,
                               growth: .down, inwardSide: .bottom, dockEdge: nil)
        }
        switch dock.edge {
        case .minY: return NotchLayout(style: .pill, compactAxis: .horizontal, growth: .up, inwardSide: .top, dockEdge: .minY)
        case .minX: return NotchLayout(style: .pill, compactAxis: .vertical, growth: .right, inwardSide: .trailing, dockEdge: .minX)
        case .maxX: return NotchLayout(style: .pill, compactAxis: .vertical, growth: .left, inwardSide: .leading, dockEdge: .maxX)
        default: return NotchLayout(style: .pill, compactAxis: .horizontal, growth: .down, inwardSide: .bottom, dockEdge: .maxY)
        }
    }

    /// Capsule size for a pill layout (the wings use `NotchGeometry.compactFrame`).
    func compactSize(contentLength: CGFloat) -> CGSize {
        let length = min(max(contentLength, NotchMetrics.pillMinWidth), NotchMetrics.pillMaxWidth)
        return compactAxis == .horizontal
            ? CGSize(width: length, height: NotchMetrics.pillHeight)
            : CGSize(width: NotchMetrics.pillHeight, height: length)
    }

    /// `expandedWidth` wide, content tall, never larger than the screen.
    func expandedSize(contentHeight: CGFloat, screen: CGRect) -> CGSize {
        CGSize(width: min(NotchMetrics.expandedWidth, screen.width),
               height: min(max(contentHeight, NotchMetrics.pillHeight), screen.height - 8))
    }
}
