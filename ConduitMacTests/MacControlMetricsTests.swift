import XCTest
@testable import ConduitMac

final class MacControlMetricsTests: XCTestCase {
    func testNamedControlHeights() {
        XCTAssertEqual(MacControlHeight.regular, 36)
        XCTAssertEqual(MacControlHeight.large, 44)
        XCTAssertLessThan(MacControlHeight.regular, MacControlHeight.large)
        // The Mac pane header row (MacPaneHeader.minHeight) and the window-toolbar
        // platter measured on macOS 27 are both a regular control tall.
        XCTAssertEqual(MacControlHeight.toolbarItem, MacControlHeight.regular)
    }

    func testIndicatorRadiusIsConcentricWithTheContainer() {
        XCTAssertEqual(MacTabStripMetrics.indicatorRadius, MacTabStripMetrics.containerRadius - MacTabStripMetrics.inset)
        XCTAssertEqual(MacTabStripMetrics.concentricRadius(outer: 18, inset: 4), 14)
        XCTAssertEqual(MacTabStripMetrics.concentricRadius(outer: 3, inset: 4), 0, "never negative")
    }

    func testContainerHeightIsSegmentPlusInsetOnBothSides() {
        XCTAssertEqual(MacTabStripMetrics.inset, 4)
        XCTAssertEqual(MacTabStripMetrics.containerHeight, MacTabStripMetrics.segmentHeight + 8)
        XCTAssertEqual(MacTabStripMetrics.containerHeight, MacControlHeight.large, "the strip is as tall as a sidebar row")
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
