import SwiftUI

/// Home's card grid (D24): equal-width columns that fill the proposed width, one gap
/// between cards in both directions, and equal heights per row (every cell is as tall as
/// the tallest in its row; `uniformRows` makes every row as tall as the tallest of all).
/// The column count is the largest of `columnOptions` whose columns are each at least
/// `minColumnWidth` wide, so a 4-tile row steps 4 -> 2 -> 1 and never leaves an orphan
/// tile. With fewer cards than columns the cards share the width. Cards stretch to the
/// cell they are given and top-align their content (`MacHomeCard`, `MacHomeTile`).
struct MacHomeGrid: Layout {
    /// Allowed column counts, widest first (for example `[3, 2, 1]`).
    var columnOptions: [Int]
    var minColumnWidth: CGFloat
    var spacing: CGFloat = MacHomeStyle.sectionGap
    var uniformRows = false

    /// The column count for `width`: the largest option that fits, else the smallest option.
    static func columns(width: CGFloat, options: [Int], minColumnWidth: CGFloat, spacing: CGFloat) -> Int {
        let sorted = options.filter { $0 > 0 }.sorted(by: >)
        guard let narrowest = sorted.last else { return 1 }
        return sorted.first { CGFloat($0) * minColumnWidth + CGFloat($0 - 1) * spacing <= width } ?? narrowest
    }

    private func columnCount(width: CGFloat, count: Int) -> Int {
        max(1, min(Self.columns(width: width, options: columnOptions, minColumnWidth: minColumnWidth, spacing: spacing), max(count, 1)))
    }

    private struct Plan {
        var columns: Int
        var columnWidth: CGFloat
        var rowHeights: [CGFloat]
    }

    private func plan(width: CGFloat, subviews: Subviews) -> Plan {
        let columns = columnCount(width: width, count: subviews.count)
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let row = subviews[index..<min(index + columns, subviews.count)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0)
            index += columns
        }
        if uniformRows, let tallest = heights.max() { heights = heights.map { _ in tallest } }
        return Plan(columns: columns, columnWidth: columnWidth, rowHeights: heights)
    }

    private var idealWidth: CGFloat {
        let widest = columnOptions.max() ?? 1
        return CGFloat(widest) * minColumnWidth + CGFloat(widest - 1) * spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? idealWidth
        let plan = plan(width: width, subviews: subviews)
        let height = plan.rowHeights.reduce(0, +) + CGFloat(max(plan.rowHeights.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let plan = plan(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, rowHeight) in plan.rowHeights.enumerated() {
            for column in 0..<plan.columns {
                let index = row * plan.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (plan.columnWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: plan.columnWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }
}
