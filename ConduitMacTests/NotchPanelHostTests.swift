import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

final class NotchHitShapeTests: XCTestCase {
    private let b = CGRect(x: 0, y: 0, width: 200, height: 100)

    func testBottomInwardRoundsTheBottomCornersOnly() {
        XCTAssertFalse(NotchHitShape.contains(CGPoint(x: 1, y: 1), in: b, inward: .bottom, radius: 14))
        XCTAssertFalse(NotchHitShape.contains(CGPoint(x: 199, y: 1), in: b, inward: .bottom, radius: 14))
        XCTAssertTrue(NotchHitShape.contains(CGPoint(x: 1, y: 99), in: b, inward: .bottom, radius: 14), "top corners are square")
        XCTAssertTrue(NotchHitShape.contains(CGPoint(x: 100, y: 50), in: b, inward: .bottom, radius: 14))
    }

    func testEachInwardSideRoundsItsOwnCorners() {
        XCTAssertFalse(NotchHitShape.contains(CGPoint(x: 1, y: 99), in: b, inward: .top, radius: 14))
        XCTAssertTrue(NotchHitShape.contains(CGPoint(x: 1, y: 1), in: b, inward: .top, radius: 14))
        XCTAssertFalse(NotchHitShape.contains(CGPoint(x: 199, y: 1), in: b, inward: .trailing, radius: 14))
        XCTAssertTrue(NotchHitShape.contains(CGPoint(x: 1, y: 1), in: b, inward: .trailing, radius: 14))
        XCTAssertFalse(NotchHitShape.contains(CGPoint(x: 1, y: 99), in: b, inward: .leading, radius: 14))
        XCTAssertTrue(NotchHitShape.contains(CGPoint(x: 199, y: 99), in: b, inward: .leading, radius: 14))
    }

    func testPointsOutsideTheBoundsAreNeverHit() {
        XCTAssertFalse(NotchHitShape.contains(CGPoint(x: -1, y: 50), in: b, inward: .bottom, radius: 14))
    }
}

@MainActor
final class NotchPanelHostTests: XCTestCase {
    private let offscreen = CGRect(x: -30000, y: -30000, width: 300, height: 32)

    /// One fake screen far offscreen, so docked placements and snaps never touch a real display.
    private let fakeScreen = MacScreenGeometry(
        frame: CGRect(x: -30000, y: -30000, width: 1600, height: 1000),
        visibleFrame: CGRect(x: -30000, y: -30000, width: 1600, height: 975), safeAreaTop: 0, id: 5)

    private func makeHost() -> NotchPanelHost {
        let screen = fakeScreen
        let environment = MacFloatingPanelEnvironment(
            screens: { [screen] }, mouseLocation: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            reduceMotion: { true })
        return NotchPanelHost(content: Color.black.frame(maxWidth: .infinity, maxHeight: .infinity), environment: environment)
    }

    func testPanelIsNonActivatingNonKeyStatusLevelAndJoinsAllSpaces() {
        let host = makeHost(); defer { host.hide() }
        let panel = host.panelForTesting
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.hasShadow)
        XCTAssertTrue(panel.isDraggable, "the whole surface is the drag handle")
    }

    func testPanelAppearanceIsPinnedOrReleasedOnRequest() {
        let host = makeHost(); defer { host.hide() }
        host.setPanelAppearance(NSAppearance(named: .darkAqua))
        XCTAssertEqual(host.panelForTesting.appearance?.name, .darkAqua)
        host.setPanelAppearance(nil)
        XCTAssertNil(host.panelForTesting.appearance, "nil hands light or dark back to the Mac")
    }

    func testShowDoesNotActivateTheAppAndHideLeavesNoWindowOnScreen() {
        let host = makeHost()
        host.setFrame(offscreen, animated: false)
        let wasActive = NSApp.isActive
        host.show()
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(NSApp.isActive, wasActive)
        host.hide()
        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.panelForTesting.isVisible)
    }

    func testStandardFrameIsHandedToTheBaseAsACustomPlacement() {
        let host = makeHost(); defer { host.hide() }
        host.setFrame(offscreen, animated: false)
        host.show()
        let big = CGRect(x: -30000, y: -30300, width: 380, height: 332)
        host.setFrame(big, animated: false)
        XCTAssertEqual(host.targetFrameForTesting, big)
    }

    func testDockedPlacementIsResolvedByTheBaseFlushWithTheEdge() {
        let host = makeHost(); defer { host.hide() }
        host.setDock(MacEdgeDock(edge: .minX, offset: 0.5, screenID: 5), size: CGSize(width: 28, height: 160))
        host.show()
        XCTAssertEqual(host.targetFrameForTesting.size, CGSize(width: 28, height: 160))
        XCTAssertEqual(host.targetFrameForTesting.minX, fakeScreen.frame.minX, "flush with the screen's left edge")
        XCTAssertEqual(host.panelForTesting.level, .statusBar, "above the Dock, which draws over .floating windows")
    }

    func testMenuBarOverlapIsAllowed() {
        let host = makeHost(); defer { host.hide() }
        let screen = NSScreen.screens[0]
        let top = CGRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 32, width: 200, height: 32)
        XCTAssertEqual(host.panelForTesting.constrainFrameRect(top, to: screen), top, "AppKit must not push it below the menu bar")
    }

    func testPointerEnterAndExitReachTheCallbackWithoutActivation() {
        let host = makeHost(); defer { host.hide() }
        var events: [Bool] = []
        host.onPointerChange = { events.append($0) }
        host.simulatePointerForTesting(inside: true)
        host.simulatePointerForTesting(inside: false)
        XCTAssertEqual(events, [true, false])
    }

    func testDragStateIsReportedOnceAndTheBaseHandlersStillRun() {
        let host = makeHost(); defer { host.hide() }
        var states: [Bool] = []
        var docks: [MacEdgeDock] = []
        host.onDragStateChange = { states.append($0) }
        host.onDockChanged = { docks.append($0) }
        let panel = host.panelForTesting
        panel.onDragMoved?(CGRect(x: -30000, y: -30000, width: 300, height: 32))
        panel.onDragMoved?(CGRect(x: -30001, y: -30000, width: 300, height: 32))
        XCTAssertEqual(states, [true], "first movement past the threshold only")
        panel.onDragEnded?(CGPoint(x: -29990, y: -29500), CGRect(x: -30000, y: -29516, width: 300, height: 32))
        XCTAssertEqual(states, [true, false])
        XCTAssertEqual(docks.count, 1, "the base snapped to an edge and reported it once")
        XCTAssertEqual(docks.first?.edge, .minX)
        XCTAssertEqual(docks.first?.screenID, 5)
    }

    func testHitTestFollowsTheInwardSide() {
        let host = makeHost(); defer { host.hide() }
        host.setFrame(CGRect(x: -30000, y: -30000, width: 200, height: 100), animated: false)
        host.show()
        host.inwardSide = .bottom
        XCTAssertNil(host.hitTestForTesting(CGPoint(x: 1, y: 1)), "rounded bottom-left corner")
        XCTAssertNotNil(host.hitTestForTesting(CGPoint(x: 100, y: 50)))
        host.inwardSide = .top
        XCTAssertNotNil(host.hitTestForTesting(CGPoint(x: 1, y: 1)))
    }
}
