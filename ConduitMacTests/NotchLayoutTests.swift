
import AppKit
import XCTest
@testable import ConduitMac

final class NotchLayoutTests: XCTestCase {
    private func dock(_ edge: NSRectEdge) -> MacEdgeDock { MacEdgeDock(edge: edge, offset: 0.5, screenID: 1) }

    func testStandardPlacementKeepsWingsOnANotchDisplayAndAPillElsewhere() {
        let notch = NotchLayout.make(standardIsNotch: true, dock: nil)
        XCTAssertEqual(notch.style, .wings)
        XCTAssertEqual(notch.compactAxis, .horizontal)
        XCTAssertEqual(notch.growth, .down)
        XCTAssertEqual(notch.inwardSide, .bottom)
        XCTAssertFalse(notch.isDocked)
        XCTAssertEqual(NotchLayout.make(standardIsNotch: false, dock: nil).style, .pill)
    }

    func testTopEdgeIsAHorizontalPillOpeningDown() {
        let l = NotchLayout.make(standardIsNotch: true, dock: dock(.maxY))
        XCTAssertEqual(l.style, .pill)
        XCTAssertEqual(l.compactAxis, .horizontal)
        XCTAssertEqual(l.growth, .down)
        XCTAssertEqual(l.inwardSide, .bottom)
        XCTAssertFalse(l.gripAtBottom)
        XCTAssertTrue(l.isDocked)
    }

    func testBottomEdgeIsAHorizontalPillOpeningUpWithTheGripAtTheBottom() {
        let l = NotchLayout.make(standardIsNotch: true, dock: dock(.minY))
        XCTAssertEqual(l.style, .pill)
        XCTAssertEqual(l.compactAxis, .horizontal)
        XCTAssertEqual(l.growth, .up)
        XCTAssertEqual(l.inwardSide, .top)
        XCTAssertTrue(l.gripAtBottom)
    }

    func testLeftEdgeIsAVerticalPillOpeningRight() {
        let l = NotchLayout.make(standardIsNotch: false, dock: dock(.minX))
        XCTAssertEqual(l.style, .pill)
        XCTAssertEqual(l.compactAxis, .vertical)
        XCTAssertEqual(l.growth, .right)
        XCTAssertEqual(l.inwardSide, .trailing)
    }

    func testRightEdgeIsAVerticalPillOpeningLeft() {
        let l = NotchLayout.make(standardIsNotch: false, dock: dock(.maxX))
        XCTAssertEqual(l.compactAxis, .vertical)
        XCTAssertEqual(l.growth, .left)
        XCTAssertEqual(l.inwardSide, .leading)
    }

    func testEveryDockedEdgeUsesThePillStyleEvenOnANotchDisplay() {
        for edge in [NSRectEdge.maxY, .minY, .minX, .maxX] {
            XCTAssertEqual(NotchLayout.make(standardIsNotch: true, dock: dock(edge)).style, .pill, "\(edge)")
        }
    }

    func testCompactSizeIsHorizontalOrVerticalAndClamped() {
        let h = NotchLayout.make(standardIsNotch: false, dock: dock(.minY))
        XCTAssertEqual(h.compactSize(contentLength: 90), CGSize(width: NotchMetrics.pillMinWidth, height: NotchMetrics.pillHeight))
        XCTAssertEqual(h.compactSize(contentLength: 900), CGSize(width: NotchMetrics.pillMaxWidth, height: NotchMetrics.pillHeight))
        let v = NotchLayout.make(standardIsNotch: false, dock: dock(.minX))
        XCTAssertEqual(v.compactSize(contentLength: 90), CGSize(width: NotchMetrics.pillHeight, height: NotchMetrics.pillMinWidth))
        XCTAssertEqual(v.compactSize(contentLength: 900), CGSize(width: NotchMetrics.pillHeight, height: NotchMetrics.pillMaxWidth))
    }

    func testExpandedSizeIsFixedWidthContentHeightAndNeverLargerThanTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for edge in [NSRectEdge.maxY, .minY, .minX, .maxX] {
            let l = NotchLayout.make(standardIsNotch: false, dock: dock(edge))
            XCTAssertEqual(l.expandedSize(contentHeight: 300, screen: screen), CGSize(width: NotchMetrics.expandedWidth, height: 300))
            XCTAssertEqual(l.expandedSize(contentHeight: 5000, screen: screen).height, 982 - 8)
            XCTAssertEqual(l.expandedSize(contentHeight: 0, screen: screen).height, NotchMetrics.pillHeight)
        }
        let narrow = CGRect(x: 0, y: 0, width: 300, height: 600)
        XCTAssertEqual(NotchLayout.make(standardIsNotch: false, dock: dock(.minX)).expandedSize(contentHeight: 100, screen: narrow).width, 300)
    }
}
