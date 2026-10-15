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
}
