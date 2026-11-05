import XCTest
@testable import ConduitMac

final class NotchGeometryTests: XCTestCase {
    // Representative values for a 14" notch display. Task 10's smoke item
    // records the real values from hardware; the logic does not depend on them.
    private let mbp14 = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 659, height: 32),
        auxiliaryTopRight: CGRect(x: 853, y: 950, width: 659, height: 32))
    private let mbp16 = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 765, height: 32),
        auxiliaryTopRight: CGRect(x: 963, y: 1085, width: 765, height: 32))
    private let external = NotchScreenMetrics(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0, auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)

    func testNotchScreensYieldNotchRect() {
        guard case .notch(let r) = NotchGeometry.placement(for: mbp14) else { return XCTFail("expected notch") }
        XCTAssertEqual(r, CGRect(x: 659, y: 950, width: 194, height: 32))
        guard case .notch(let r16) = NotchGeometry.placement(for: mbp16) else { return XCTFail("expected notch") }
        XCTAssertEqual(r16.width, 198)
        XCTAssertEqual(r16.maxY, mbp16.frame.maxY)
    }

    func testNoNotchAndEmptyAuxiliaryAreasFallBackToPill() {
        XCTAssertEqual(NotchGeometry.placement(for: external), .pill)
        var mirrored = mbp14
        mirrored.auxiliaryTopLeft = .zero   // mirrored or clamshell: no extra unobscured area
        XCTAssertEqual(NotchGeometry.placement(for: mirrored), .pill)
        var inconsistent = mbp14
        inconsistent.auxiliaryTopRight = CGRect(x: 600, y: 950, width: 100, height: 32)   // maxX <= minX
        XCTAssertEqual(NotchGeometry.placement(for: inconsistent), .pill)
    }

    func testCompactNotchFrameWrapsTheNotchWithWingsAtTheTopEdge() {
        let p = NotchGeometry.placement(for: mbp14)
        let f = NotchGeometry.compactFrame(p, in: mbp14, contentWidth: 0)
        XCTAssertEqual(f.minX, 659 - NotchMetrics.leftWing)
        XCTAssertEqual(f.width, 194 + NotchMetrics.leftWing + NotchMetrics.rightWing)
        XCTAssertEqual(f.height, 32)
        XCTAssertEqual(f.maxY, mbp14.frame.maxY, "top flush with the physical screen edge")
    }

    func testCompactWingsClampToTheUnobscuredAreas() {
        var narrow = mbp14
        narrow.auxiliaryTopLeft = CGRect(x: 0, y: 950, width: 20, height: 32)
        narrow.auxiliaryTopRight = CGRect(x: 214, y: 950, width: 50, height: 32)
        let f = NotchGeometry.compactFrame(NotchGeometry.placement(for: narrow), in: narrow, contentWidth: 0)
        XCTAssertEqual(f.minX, 20 - 20)
        XCTAssertEqual(f.maxX, 214 + 50)
    }

    func testPillIsClampedCenteredAndBelowTheMenuBarOfThatScreen() {
        let p = NotchGeometry.placement(for: external)
        let small = NotchGeometry.compactFrame(p, in: external, contentWidth: 90)
        XCTAssertEqual(small.width, NotchMetrics.pillMinWidth)
        let large = NotchGeometry.compactFrame(p, in: external, contentWidth: 900)
        XCTAssertEqual(large.width, NotchMetrics.pillMaxWidth)
        XCTAssertEqual(large.midX, external.visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(large.height, NotchMetrics.pillHeight)
        XCTAssertEqual(large.maxY, external.visibleFrame.maxY - NotchMetrics.pillGap)
        XCTAssertGreaterThanOrEqual(large.minX, external.frame.minX, "stays on the secondary screen")
    }

    func testExpandedNotchFrameIsTopFlushAndCenteredOnTheNotch() {
        let p = NotchGeometry.placement(for: mbp16)
        let f = NotchGeometry.expandedFrame(p, in: mbp16, height: 300)
        XCTAssertEqual(f.width, NotchMetrics.expandedWidth)
        XCTAssertEqual(f.midX, 864, accuracy: 0.5)
        XCTAssertEqual(f.maxY, mbp16.frame.maxY)
        XCTAssertEqual(f.height, 300)
    }

    func testExpandedPillFrameHangsBelowTheMenuBar() {
        let p = NotchGeometry.placement(for: external)
        let f = NotchGeometry.expandedFrame(p, in: external, height: 300)
        XCTAssertEqual(f.maxY, external.visibleFrame.maxY - NotchMetrics.pillGap)
        XCTAssertEqual(f.midX, external.visibleFrame.midX, accuracy: 0.5)
    }

    func testExpandedHeightClampsToTheScreen() {
        let p = NotchGeometry.placement(for: external)
        let f = NotchGeometry.expandedFrame(p, in: external, height: 5000)
        XCTAssertLessThanOrEqual(f.height, external.visibleFrame.height - 8)
        XCTAssertGreaterThanOrEqual(f.minY, external.visibleFrame.minY)
    }

    func testNotchSizeAccessors() {
        XCTAssertEqual(NotchGeometry.placement(for: mbp14).notchWidth, 194)
        XCTAssertEqual(NotchGeometry.placement(for: mbp14).notchHeight, 32)
        XCTAssertEqual(NotchPlacement.pill.notchHeight, 0)
    }
}
