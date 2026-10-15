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
