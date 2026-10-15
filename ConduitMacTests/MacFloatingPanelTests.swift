import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacFloatingPanelTests: XCTestCase {
    private let primary = MacScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 806))
    private let second = MacScreenGeometry(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private var mouse = CGPoint(x: 100, y: 100)
    private var dismissCount = 0
    private var controllers: [MacFloatingPanelController] = []

    override func tearDown() async throws {
        for controller in controllers {
            controller.hide()
            controller.panel.close()
        }
        controllers = []
        dismissCount = 0
    }

    private func make(configure: (inout MacFloatingPanelConfig) -> Void = { _ in }) -> MacFloatingPanelController {
        var config = MacFloatingPanelConfig(
            size: NSSize(width: 600, height: 80),
            placement: .screenCenterTop(fromTop: 100),
            canBecomeKey: true,
            dismissOnResignKey: true,
            onDismiss: { [weak self] in self?.dismissCount += 1 })
        configure(&config)
        let screens = [primary, second]
        let environment = MacFloatingPanelEnvironment(
            screens: { screens },
            mouseLocation: { [unowned self] in self.mouse },
            reduceMotion: { true })
        let controller = MacFloatingPanelController(config: config, environment: environment) { Color.clear }
        controllers.append(controller)
        return controller
    }

    func testPanelStyleAndBehaviourContract() {
        let panel = make().panel
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testCanBecomeKeyFollowsConfig() {
        XCTAssertTrue(make().panel.canBecomeKey)
        XCTAssertFalse(make { $0.canBecomeKey = false }.panel.canBecomeKey)
    }

    func testLevelAndSpacesFollowConfig() {
        let panel = make { $0.level = .statusBar; $0.joinsAllSpaces = false }.panel
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testShowPlacesOnTheMouseScreen() {
        mouse = CGPoint(x: 2000, y: 500)
        let controller = make()
        controller.show()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.isVisible })
        XCTAssertEqual(controller.targetFrame, CGRect(x: 2100, y: 875, width: 600, height: 80))
    }

    func testShowRecomputesPlacementEveryTime() {
        let controller = make()
        controller.show()
        XCTAssertEqual(controller.targetFrame.midX, 720, accuracy: 0.001)
        controller.hide()
        mouse = CGPoint(x: 2000, y: 500)
        controller.show()
        XCTAssertEqual(controller.targetFrame.midX, 2400, accuracy: 0.001)
    }

    func testToggleShowsThenHides() {
        let controller = make()
        controller.toggle()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.isVisible })
        controller.toggle()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(dismissCount, 1)
    }

    func testEscapeHidesOnceEvenWhenAppKitThenResignsKey() {
        let controller = make()
        controller.show()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.isVisible })
        controller.panel.cancelOperation(nil)
        XCTAssertFalse(controller.isVisible)
        controller.panel.resignKey()   // AppKit sends this while ordering a key panel out
        XCTAssertEqual(dismissCount, 1)
    }

    func testEscapeDoesNothingWhenDisabled() {
        let controller = make { $0.dismissOnEscape = false }
        controller.show()
        controller.panel.cancelOperation(nil)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(dismissCount, 0)
    }

    func testResignKeyHidesOnlyWhenConfigured() {
        let hides = make()
        hides.show()
        hides.panel.resignKey()
        XCTAssertFalse(hides.isVisible)

        let stays = make { $0.dismissOnResignKey = false }
        stays.show()
        stays.panel.resignKey()
        XCTAssertTrue(stays.isVisible)
    }

    func testHideWhenNotVisibleDoesNotFireOnDismiss() {
        let controller = make()
        controller.hide()
        XCTAssertEqual(dismissCount, 0)
    }

    func testContentHeightGrowsDownwardWithAFixedTopAndCapsAtMaxHeight() {
        let controller = make { $0.maxHeight = 300 }
        controller.show()
        let top = controller.targetFrame.maxY
        controller.updateContentHeight(200)
        XCTAssertEqual(controller.targetFrame.height, 200)
        XCTAssertEqual(controller.targetFrame.maxY, top)
        controller.updateContentHeight(900)
        XCTAssertEqual(controller.targetFrame.height, 300)
        XCTAssertEqual(controller.targetFrame.maxY, top)
    }

    func testContentHeightBeforeShowIsRememberedForTheNextShow() {
        let controller = make()
        controller.updateContentHeight(240)
        controller.show()
        XCTAssertEqual(controller.targetFrame.height, 240)
    }

    func testMenuBarOverlapReturnsTheFrameUnchanged() {
        let panel = make { $0.allowsMenuBarOverlap = true }.panel
        let screen = NSScreen.screens[0]
        let overlapping = NSRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 40, width: 200, height: 40)
        XCTAssertEqual(panel.constrainFrameRect(overlapping, to: screen), overlapping)
    }

    func testShadowFollowsConfig() {
        XCTAssertTrue(make().panel.hasShadow)
        XCTAssertFalse(make { $0.hasShadow = false }.panel.hasShadow)
    }

    func testContentSizeChangesWidthAndHeightKeepingTopAndCenter() {
        let controller = make()
        controller.show()
        let top = controller.targetFrame.maxY
        let midX = controller.targetFrame.midX
        controller.updateContentSize(CGSize(width: 300, height: 200))
        XCTAssertEqual(controller.targetFrame.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(controller.targetFrame.maxY, top)
        XCTAssertEqual(controller.targetFrame.midX, midX, accuracy: 0.001)
    }

    func testOverlapAllowedPanelMayGrowIntoTheMenuBarBand() {
        // notchAnchored sits flush with screen.frame.maxY, above visibleFrame.maxY.
        let controller = make { $0.placement = .notchAnchored; $0.allowsMenuBarOverlap = true }
        controller.show()
        XCTAssertEqual(controller.targetFrame.maxY, 900)   // primary.frame.maxY, not 876
        controller.updateContentSize(CGSize(width: 600, height: 120))
        XCTAssertEqual(controller.targetFrame.maxY, 900)
    }

    func testMouseCallbacksFire() {
        var entered = 0, exited = 0
        let controller = make { $0.onMouseEntered = { entered += 1 }; $0.onMouseExited = { exited += 1 } }
        controller.show()
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: controller.panel.windowNumber, context: nil,
                                   eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        controller.panel.mouseEntered(with: event(.mouseEntered))
        controller.panel.mouseExited(with: event(.mouseExited))
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(exited, 1)
    }

    func testPlacementFollowsScreenParameterChanges() {
        var screens = [primary]
        let environment = MacFloatingPanelEnvironment(screens: { screens }, mouseLocation: { CGPoint(x: 100, y: 100) }, reduceMotion: { true })
        let controller = MacFloatingPanelController(
            config: MacFloatingPanelConfig(size: NSSize(width: 600, height: 80), placement: .screenCenterTop(fromTop: 100),
                                           canBecomeKey: false, dismissOnResignKey: false),
            environment: environment) { Color.clear }
        controllers.append(controller)
        controller.show()
        XCTAssertEqual(controller.targetFrame.midX, 720, accuracy: 0.001)
        screens = [MacScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(HostedTestSupport.waitUntil { abs(controller.targetFrame.midX - 500) < 0.001 })
    }
}
