import XCTest
@testable import ConduitMac

final class MacControlMetricsTests: XCTestCase {
    func testNamedControlHeights() {
        XCTAssertEqual(MacControlHeight.regular, 36)
        XCTAssertEqual(MacControlHeight.compact, 32)
        XCTAssertLessThan(MacControlHeight.compact, MacControlHeight.regular)
        // The window-toolbar platter measured on macOS 27 is a regular control tall.
        // Sidebar rows, the tab strip and the pane-header buttons (and the
        // `MacPaneHeader` row) are compact.
        XCTAssertEqual(MacControlHeight.toolbarItem, MacControlHeight.regular)
    }

    func testSidebarMetricsAreProportionalToTheCompactControl() {
        XCTAssertEqual(MacSidebarMetrics.chipHeight, 24)
        XCTAssertGreaterThanOrEqual(MacSidebarMetrics.chipHeight, 24, "hit target")
        XCTAssertLessThan(MacSidebarMetrics.glyphSize, MacControlHeight.compact / 2, "glyph sits inside the control")
        XCTAssertLessThan(MacSidebarMetrics.rowGap, 10, "tighter than upstream's gap")
        XCTAssertLessThan(MacSidebarMetrics.stackGap, 16, "tighter than upstream's gap")
        XCTAssertEqual(MacSidebarMetrics.controlRadius, MacTabStripMetrics.containerRadius)
        XCTAssertLessThan(MacSidebarMetrics.avatarSize, MacControlHeight.compact)
    }

    func testIndicatorRadiusIsConcentricWithTheContainer() {
        XCTAssertEqual(MacTabStripMetrics.indicatorRadius, MacTabStripMetrics.containerRadius - MacTabStripMetrics.inset)
        XCTAssertEqual(MacTabStripMetrics.concentricRadius(outer: 18, inset: 4), 14)
        XCTAssertEqual(MacTabStripMetrics.indicatorRadius, 9, "12 pt container, 3 pt inset")
        XCTAssertEqual(MacTabStripMetrics.concentricRadius(outer: 3, inset: 4), 0, "never negative")
    }

    func testContainerHeightIsSegmentPlusInsetOnBothSides() {
        XCTAssertEqual(MacTabStripMetrics.inset, 3)
        XCTAssertEqual(MacTabStripMetrics.containerHeight, MacTabStripMetrics.segmentHeight + 6)
        XCTAssertEqual(MacTabStripMetrics.segmentHeight, 26)
        XCTAssertGreaterThanOrEqual(MacTabStripMetrics.segmentHeight, 24, "hit target")
        XCTAssertEqual(MacTabStripMetrics.containerHeight, MacControlHeight.compact, "the strip is as tall as a sidebar row")
        XCTAssertEqual(MacTabStripMetrics.homeSegmentWidth, 32 + 2 * MacTabStripMetrics.inset, "an icon-only segment: a 32 pt glyph square plus the inset")
    }

    func testLadderStepsFollowWidthAlone() {
        // Segment widths by tab: the widest of five is 70. Home is found by value, not position.
        let widths: [SidebarTab: CGFloat] = [.home: 62, .sessions: 70, .bots: 60, .cron: 50, .kanban: 66]
        let ladder = { (width: CGFloat) in MacTabStripMetrics.ladder(availableWidth: width, nameSegmentWidths: widths) }
        XCTAssertEqual(ladder(5 * 70), .names)
        XCTAssertEqual(ladder(5 * 70 - 0.5), .homeCompact, "five equal segments need the widest times five")
        let compact = 4 * 70 + MacTabStripMetrics.homeSegmentWidth
        XCTAssertEqual(ladder(compact), .homeCompact)
        XCTAssertEqual(ladder(compact - 0.5), .icons)
        XCTAssertEqual(ladder(0), .icons)
        XCTAssertEqual(ladder(2000), .names)
        // Home's own name never sets the compact step: it is an icon there.
        let longHome: [SidebarTab: CGFloat] = [.home: 120, .sessions: 70, .bots: 60, .cron: 50, .kanban: 66]
        XCTAssertEqual(MacTabStripMetrics.ladder(availableWidth: 4 * 70 + MacTabStripMetrics.homeSegmentWidth,
                                                 nameSegmentWidths: longHome), .homeCompact)
        XCTAssertEqual(MacTabStripMetrics.ladder(availableWidth: 5 * 120 - 0.5, nameSegmentWidths: longHome), .homeCompact,
                       "but it widens the all-names step")
        XCTAssertEqual(MacTabStripMetrics.ladder(availableWidth: 1000, nameSegmentWidths: [.home: 70]), .icons, "one tab has nothing to step")
        XCTAssertEqual(MacTabStripMetrics.nameSegmentWidth(iconWidth: 12, textWidth: 40),
                       12 + MacTabStripMetrics.nameGap + 40 + 2 * MacTabStripMetrics.nameMargin + 2 * MacTabStripMetrics.inset)
    }

    func testStripOrderPutsHomeFirstAndArtifactsLast() {
        XCTAssertEqual(MacSidebarTabOrder.strip, [.home, .sessions, .bots, .cron, .kanban, .artifacts])
        XCTAssertEqual(MacSidebarTabOrder.strip.count, SidebarTab.allCases.count)
        XCTAssertEqual(Set(MacSidebarTabOrder.strip), Set(SidebarTab.allCases), "every tab is on the strip once")
        XCTAssertEqual(Array(MacSidebarTabOrder.strip.dropFirst()), SidebarTab.allCases.filter { $0 != .home },
                       "after Home the strip follows SidebarTab order, which ends with Artifacts (D26)")
        XCTAssertEqual(MacSidebarTabStrip.compactGroups, [[.home], [.sessions, .bots, .cron, .kanban, .artifacts]])
    }

    func testSegmentsAreEqualWidthAndTileTheContainer() {
        let width: CGFloat = 312
        let frames = (0..<4).map { MacTabStripMetrics.segmentFrame(index: $0, count: 4, containerWidth: width) }
        XCTAssertEqual(Set(frames.map(\.width)), [78])
        XCTAssertEqual(frames.first?.minX, 0)
        XCTAssertEqual(frames.last?.maxX, width)
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertEqual(a.maxX, b.minX) }
        XCTAssertEqual(MacTabStripMetrics.segmentFrame(index: 0, count: 0, containerWidth: width), .zero)
    }

    func testIndicatorIsInsetUniformlyAndCenteredOnItsSegment() {
        for index in 0..<4 {
            let segment = MacTabStripMetrics.segmentFrame(index: index, count: 4, containerWidth: 312)
            let indicator = MacTabStripMetrics.indicatorFrame(index: index, count: 4, containerWidth: 312)
            XCTAssertEqual(indicator.minX - segment.minX, MacTabStripMetrics.inset)
            XCTAssertEqual(segment.maxX - indicator.maxX, MacTabStripMetrics.inset)
            XCTAssertEqual(indicator.minY - segment.minY, MacTabStripMetrics.inset)
            XCTAssertEqual(segment.maxY - indicator.maxY, MacTabStripMetrics.inset)
            XCTAssertEqual(indicator.midX, segment.midX)
            XCTAssertEqual(indicator.midY, segment.midY)
            XCTAssertEqual(indicator.height, MacTabStripMetrics.segmentHeight)
        }
    }
}
