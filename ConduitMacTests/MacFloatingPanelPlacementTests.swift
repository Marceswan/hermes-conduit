import XCTest
@testable import ConduitMac

final class MacFloatingPanelPlacementTests: XCTestCase {
    /// Dock 70 pt at the bottom, menu bar 24 pt.
    private let primary = MacScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 806))
    private let right = MacScreenGeometry(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private let below = MacScreenGeometry(
        frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1055))
    /// A 14-inch class notch display to the right of the primary.
    private let notch = MacScreenGeometry(
        frame: CGRect(x: 1440, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1512, height: 950),
        safeAreaTop: 32)
    private let size = CGSize(width: 600, height: 80)

    private func frame(_ placement: MacFloatingPanelPlacement, on screen: MacScreenGeometry, size: CGSize? = nil) -> CGRect {
        placement.frame(panelSize: size ?? self.size, screenFrame: screen.frame,
                        visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaTop)
    }

    func testCenterTopFromTopInPoints() {
        // top = 876 - 100 = 776, so y = 696; x = 720 - 300.
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: primary), CGRect(x: 420, y: 696, width: 600, height: 80))
    }

    func testCenterTopFractionUsesTheVisibleHeight() {
        let f = frame(.screenCenterTopFraction(0.22), on: primary)
        XCTAssertEqual(f.maxY, 876 - 0.22 * 806, accuracy: 0.001)
        XCTAssertEqual(f.midX, 720, accuracy: 0.001)
    }

    func testCenteredInTheVisibleFrameWhenTheDockIsOnTheLeft() {
        let dockLeft = MacScreenGeometry(frame: primary.frame, visibleFrame: CGRect(x: 80, y: 0, width: 1360, height: 876))
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: dockLeft).minX, 80 + 680 - 300)
    }

    func testSecondaryScreenToTheRight() {
        // top = 1055 - 100 = 955, y = 875; x = 1440 + 960 - 300.
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: right), CGRect(x: 2100, y: 875, width: 600, height: 80))
    }

    func testScreenBelowThePrimaryHasNegativeY() {
        // top = -1080 + 1055 - 100 = -125.
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: below), CGRect(x: 660, y: -205, width: 600, height: 80))
    }

    func testPanelTallerThanTheScreenShortensWithTheTopFixed() {
        let f = frame(.screenCenterTop(fromTop: 100), on: primary, size: CGSize(width: 600, height: 2000))
        XCTAssertEqual(f.maxY, 776)
        XCTAssertEqual(f.minY, 70)
    }

    func testPanelWiderThanTheScreenClamps() {
        let f = frame(.screenCenterTop(fromTop: 100), on: primary, size: CGSize(width: 5000, height: 80))
        XCTAssertEqual(f.minX, 0)
        XCTAssertEqual(f.width, 1440)
    }

    func testNotchAnchoredIsFlushWithTheTopAndCentered() {
        let f = frame(.notchAnchored, on: notch, size: CGSize(width: 400, height: 60))
        XCTAssertEqual(f, CGRect(x: 1440 + 756 - 200, y: 982 - 60, width: 400, height: 60))
    }

    func testCustomIsPassedThrough() {
        let custom = MacFloatingPanelPlacement.custom { s in CGRect(x: 1, y: 2, width: s.width, height: s.height) }
        XCTAssertEqual(frame(custom, on: primary), CGRect(x: 1, y: 2, width: 600, height: 80))
    }

    // MARK: - Screen choice

    func testMouseScreenIsChosen() {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 100, y: 100), screens: [primary, right]), 0)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 2000, y: 500), screens: [primary, right]), 1)
    }

    func testMouseOnTheTopEdgeStillCountsAsInsideThatScreen() {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 2000, y: 1080), screens: [primary, right]), 1)
    }

    func testMouseOutsideEveryScreenFallsBackToTheFirst() {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: -5000, y: -5000), screens: [primary, right]), 0)
    }

    func testNoScreensIsNil() {
        XCTAssertNil(MacFloatingPanelPlacement.notchAnchored.targetScreenIndex(mouse: .zero, screens: []))
    }

    func testNotchAnchoredPrefersANotchScreenOverTheMouseScreen() {
        XCTAssertEqual(MacFloatingPanelPlacement.notchAnchored.targetScreenIndex(mouse: CGPoint(x: 100, y: 100), screens: [primary, notch]), 1)
    }

    func testNotchAnchoredWithoutANotchScreenUsesTheMouseScreen() {
        XCTAssertEqual(MacFloatingPanelPlacement.notchAnchored.targetScreenIndex(mouse: CGPoint(x: 2000, y: 500), screens: [primary, right]), 1)
    }

    // MARK: - Resize

    func testResizeGrowsDownKeepingTheTopAndTheCenter() {
        let start = CGRect(x: 420, y: 696, width: 600, height: 80)
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 600, height: 300), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f, CGRect(x: 420, y: 476, width: 600, height: 300))
    }

    func testResizeCapsAtMaxHeight() {
        let start = CGRect(x: 420, y: 696, width: 600, height: 80)
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 600, height: 900), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f.height, 480)
        XCTAssertEqual(f.maxY, 776)
    }

    func testResizeStopsAtTheBottomOfTheVisibleFrame() {
        let start = CGRect(x: 420, y: 70, width: 600, height: 80)   // top = 150
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 600, height: 400), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f.height, 80)
        XCTAssertEqual(f.minY, 70)
    }

    func testResizeWidthKeepsTheCenter() {
        let start = CGRect(x: 420, y: 696, width: 600, height: 80)
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 400, height: 80), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f.minX, 520)
        XCTAssertEqual(f.midX, start.midX)
    }

    // MARK: - Edge docked

    private func dockedPrimary() -> MacScreenGeometry { MacScreenGeometry(frame: primary.frame, visibleFrame: primary.visibleFrame, id: 1) }
    private func dockedRight() -> MacScreenGeometry { MacScreenGeometry(frame: right.frame, visibleFrame: right.visibleFrame, id: 2) }

    func testEdgeDockedFrameUsesTheFullScreenFrame() {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .minY, offset: 0.5, screenID: 1)
        XCTAssertEqual(frame(p, on: primary, size: CGSize(width: 400, height: 60)), CGRect(x: 520, y: 0, width: 400, height: 60))
    }

    func testEdgeDockedTargetsTheSavedScreen() {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .maxY, offset: 0.5, screenID: 2)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 100, y: 100), screens: [dockedPrimary(), dockedRight()]), 1)
    }

    func testEdgeDockedWithoutAScreenIdUsesTheMouseScreen() {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .maxY, offset: 0.5, screenID: nil)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 2000, y: 500), screens: [dockedPrimary(), dockedRight()]), 1)
    }

    func testEdgeDockedFallsBackToTheDefaultWhenTheSavedScreenIsGone() throws {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .minX, offset: 1, screenID: 99)
        let screens = [dockedPrimary(), dockedRight()]
        let resolved = try XCTUnwrap(p.resolve(panelSize: CGSize(width: 400, height: 60), mouse: CGPoint(x: 100, y: 100), screens: screens))
        let expected = MacFloatingPanelPlacement.notchAnchored.frame(
            panelSize: CGSize(width: 400, height: 60), screenFrame: primary.frame,
            visibleFrame: primary.visibleFrame, safeAreaTop: 0)
        XCTAssertEqual(resolved.screenIndex, 0)
        XCTAssertEqual(resolved.frame, expected, "notch-anchored default, not a left-edge dock")
    }

    func testResolveForTheExistingPlacementsMatchesFrame() throws {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        let resolved = try XCTUnwrap(p.resolve(panelSize: size, mouse: CGPoint(x: 2000, y: 500), screens: [primary, right]))
        XCTAssertEqual(resolved.screenIndex, 1)
        XCTAssertEqual(resolved.frame, frame(p, on: right))
        XCTAssertNil(p.resolve(panelSize: size, mouse: .zero, screens: []))
    }
}
