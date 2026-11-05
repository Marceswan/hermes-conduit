import SwiftUI

/// Home's card grid (D24): equal-width columns that fill the proposed width, one gap
/// between cards in both directions, and equal heights per row (every cell is as tall as
/// the tallest in its row; `uniformRows` makes every row as tall as the tallest of all).
/// The column count is the largest of `columnOptions` whose columns are each at least
/// `minColumnWidth` wide, so a 4-tile row steps 4 -> 2 -> 1 and never leaves an orphan
/// tile. A last row with fewer cards than columns shares the full width among its cards, so a lone
/// last card spans the row. With fewer cards than columns overall the cards share the width. Cards stretch to the
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

    private struct Row {
        var first: Int
        var count: Int
        var cellWidth: CGFloat
        var height: CGFloat
    }

    private struct Plan {
        var columns: Int
        var rows: [Row]
    }

    /// A last row with fewer cards than columns shares the full width among its cards (so a lone
    /// third card spans the row under two columns); every other row uses the equal column width.
    private func plan(width proposed: CGFloat, subviews: Subviews) -> Plan {
        let width = proposed.isFinite ? max(proposed, 0) : idealWidth
        let columns = columnCount(width: width, count: subviews.count)
        var rows: [Row] = []
        var index = 0
        while index < subviews.count {
            let count = min(columns, subviews.count - index)
            let cellWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
            let height = subviews[index..<index + count]
                .map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
            rows.append(Row(first: index, count: count, cellWidth: cellWidth, height: height))
            index += count
        }
        if uniformRows, let tallest = rows.map(\.height).max() {
            for i in rows.indices { rows[i].height = tallest }
        }
        return Plan(columns: columns, rows: rows)
    }

    private var idealWidth: CGFloat {
        let widest = columnOptions.max() ?? 1
        return CGFloat(widest) * minColumnWidth + CGFloat(widest - 1) * spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        let plan = plan(width: width, subviews: subviews)
        let height = plan.rows.reduce(0) { $0 + $1.height } + CGFloat(max(plan.rows.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let plan = plan(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in plan.rows {
            for offset in 0..<row.count {
                subviews[row.first + offset].place(
                    at: CGPoint(x: bounds.minX + CGFloat(offset) * (row.cellWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: row.cellWidth, height: row.height))
            }
            y += row.height + spacing
        }
    }
}
