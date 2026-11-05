import XCTest
@testable import ConduitMac

final class EdgeDockGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 400, height: 60)

    private func frame(_ edge: NSRectEdge, _ offset: CGFloat, size: CGSize? = nil, on rect: CGRect? = nil) -> CGRect {
        EdgeDockGeometry.frame(for: MacEdgeDock(edge: edge, offset: offset, screenID: nil),
                               panelSize: size ?? self.size, screenFrame: rect ?? screen)
    }

    func testEachEdgeIsFlushAndCenteredAtHalfOffset() {
        XCTAssertEqual(frame(.maxY, 0.5), CGRect(x: 520, y: 840, width: 400, height: 60))
        XCTAssertEqual(frame(.minY, 0.5), CGRect(x: 520, y: 0, width: 400, height: 60))
        XCTAssertEqual(frame(.minX, 0.5), CGRect(x: 0, y: 420, width: 400, height: 60))
        XCTAssertEqual(frame(.maxX, 0.5), CGRect(x: 1040, y: 420, width: 400, height: 60))
    }

    func testOffsetRunsLeftToRightOnTopAndBottomAndTopToBottomOnTheSides() {
        XCTAssertEqual(frame(.maxY, 0).minX, 0)
        XCTAssertEqual(frame(.maxY, 1).maxX, 1440)
        XCTAssertEqual(frame(.minX, 0).maxY, 900)
        XCTAssertEqual(frame(.minX, 1).minY, 0)
    }

    func testOffsetIsClamped() {
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(-3), 0)
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(7), 1)
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(.nan), 0.5)
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(0.25), 0.25)
    }

    func testThePanelNeverLeavesTheScreen() {
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            for offset in [-1, 0, 0.3, 1, 2] as [CGFloat] {
                XCTAssertTrue(screen.contains(frame(edge, offset)), "\(edge) \(offset)")
            }
        }
    }

    func testAPanelLargerThanTheScreenShrinksToIt() {
        let f = frame(.maxY, 0.5, size: CGSize(width: 3000, height: 60))
        XCTAssertEqual(f.width, 1440)
        XCTAssertEqual(f.minX, 0)
    }

    func testScreensAwayFromTheOriginWork() {
        let other = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(frame(.maxY, 0.5, on: other), CGRect(x: 2200, y: 820, width: 400, height: 60))
    }

    func testAChangeOfResolutionRefitsTheSameDock() {
        XCTAssertEqual(frame(.maxY, 1).minX, 1040)
        let smaller = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let refit = frame(.maxY, 1, on: smaller)
        XCTAssertEqual(refit.minX, 600)
        XCTAssertTrue(smaller.contains(refit))
    }

    // MARK: - Snap

    func testNearestEdgeOfThePointer() {
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 720, y: 880), in: screen), .maxY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 720, y: 10), in: screen), .minY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 5, y: 450), in: screen), .minX)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 1435, y: 450), in: screen), .maxX)
    }

    func testTiesPreferTopThenBottomThenLeft() {
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 0, y: 900), in: screen), .maxY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 0, y: 0), in: screen), .minY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 720, y: 450), in: screen), .maxY)
    }

    func testOffsetOfAPanelFrameAlongAnEdgeIsClamped() {
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 520, y: 0, width: 400, height: 60), on: .maxY, in: screen), 0.5)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: -100, y: 0, width: 400, height: 60), on: .maxY, in: screen), 0)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 5000, y: 0, width: 400, height: 60), on: .minY, in: screen), 1)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 0, y: 840, width: 400, height: 60), on: .minX, in: screen), 0)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 0, y: 0, width: 400, height: 60), on: .maxX, in: screen), 1)
    }

    func testAPanelAsLongAsTheEdgeSitsInTheMiddle() {
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 0, y: 0, width: 1440, height: 60), on: .maxY, in: screen), 0.5)
    }

    func testScreenUnderThePointerIsInclusiveThenNearest() {
        let a = MacScreenGeometry(frame: screen, visibleFrame: screen, id: 1)
        let b = MacScreenGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: screen, id: 2)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(containing: CGPoint(x: 100, y: 100), in: [a, b]), 0)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(containing: CGPoint(x: 2000, y: 1080), in: [a, b]), 1)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(containing: CGPoint(x: 1500, y: -40), in: [a, b]), 1, "outside every screen: nearest")
        XCTAssertNil(EdgeDockGeometry.screenIndex(containing: .zero, in: []))
    }

    func testSnapPicksTheScreenTheEdgeTheOffsetAndTheScreenId() throws {
        let a = MacScreenGeometry(frame: screen, visibleFrame: screen, id: 11)
        let b = MacScreenGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: screen, id: 22)
        let dock = try XCTUnwrap(EdgeDockGeometry.snap(
            pointer: CGPoint(x: 2400, y: 1070),
            panelFrame: CGRect(x: 2200, y: 900, width: 400, height: 60),
            screens: [a, b]))
        XCTAssertEqual(dock.edge, .maxY)
        XCTAssertEqual(dock.screenID, 22)
        XCTAssertEqual(dock.offset, (2200 - 1440) / (1920 - 400), accuracy: 0.0001)
        XCTAssertNil(EdgeDockGeometry.snap(pointer: .zero, panelFrame: .zero, screens: []))
    }

    func testScreenLookupByIdReturnsNilWhenGone() {
        let a = MacScreenGeometry(frame: screen, visibleFrame: screen, id: 11)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(for: MacEdgeDock(edge: .maxY, offset: 0, screenID: 11), screens: [a]), 0)
        XCTAssertNil(EdgeDockGeometry.screenIndex(for: MacEdgeDock(edge: .maxY, offset: 0, screenID: 99), screens: [a]))
        XCTAssertNil(EdgeDockGeometry.screenIndex(for: MacEdgeDock(edge: .maxY, offset: 0, screenID: nil), screens: [a]))
    }
}
