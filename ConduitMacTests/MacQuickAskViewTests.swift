import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskViewTests: XCTestCase {
    private var window: NSWindow?
    private var boostWasOn = false

    override func setUp() async throws {
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
    }

    private func controller(connection: MacQuickAskConnection = .connected) -> MacQuickAskController {
        let c = MacQuickAskController(hub: MacStreamEventHub())
        c.connectionChanged(connection)
        return c
    }

    private func host(_ c: MacQuickAskController) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let view = MacQuickAskView(controller: c, onHeight: { _ in }).frame(width: 640)
        let w = HostedTestSupport.host(view, size: NSSize(width: 640, height: 300))
        window = w
        return w
    }

    /// Every accessibility label, title and string value in the window. Static
    /// text carries its string as the value, which `AccessibilityProbe` skips.
    private func labels(_ c: MacQuickAskController) throws -> [String] {
        let w = try host(c)
        HostedTestSupport.settle(0.3)
        return Self.strings(in: w)
    }

    private static func strings(in window: NSWindow) -> [String] {
        guard let host = window.contentView else { return [] }
        var found: [String] = []
        func walk(_ element: NSObject, depth: Int) {
            for getter in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text: String = element.axValue(getter), !text.isEmpty { found.append(text) }
            }
            let kids: [Any]? = element.axValue("accessibilityChildren")
            if depth < 12 { for kid in kids ?? [] { if let o = kid as? NSObject { walk(o, depth: depth + 1) } } }
        }
        for kid in host.accessibilityChildren() ?? [] { if let o = kid as? NSObject { walk(o, depth: 0) } }
        return found
    }

    func testConfigMatchesTheSpec() {
        let config = MacQuickAskPanelConfig.make(onDismiss: {})
        XCTAssertEqual(config.maxHeight, 480)
        XCTAssertTrue(config.canBecomeKey)
        XCTAssertTrue(config.dismissOnResignKey)
        XCTAssertTrue(config.dismissOnEscape)
        XCTAssertFalse(config.isDraggable)
        XCTAssertEqual(config.accessibilityLabel, AppLocalization.string("Quick Ask"))
        guard case .screenCenterTopFraction(let fraction) = config.placement else { return XCTFail() }
        XCTAssertEqual(fraction, 0.22, accuracy: 0.001)
    }

    func testConnectedIdleShowsTheField() throws {
        let l = try labels(controller())
        XCTAssertTrue(l.contains("Ask Hermes"), "\(l)")
        XCTAssertFalse(l.contains("Not connected"))
    }

    func testDisconnectedShowsNotConnectedAndOpenConduit() throws {
        let l = try labels(controller(connection: .disconnected))
        XCTAssertTrue(l.contains("Not connected"), "\(l)")
        XCTAssertTrue(l.contains("Open Conduit"), "\(l)")
    }

    func testReconnectingSaysSo() throws {
        let l = try labels(controller(connection: .connecting))
        XCTAssertTrue(l.contains("Reconnecting"), "\(l)")
    }

    func testNeedsInputOffersOpenInConduit() throws {
        let c = controller()
        c.forceStateForTest(.needsInput(text: "partial"))
        let l = try labels(c)
        XCTAssertTrue(l.contains("Hermes needs your input"), "\(l)")
        XCTAssertTrue(l.contains("Open in Conduit"), "\(l)")
    }

    func testFailedShowsMessageAndRetry() throws {
        let c = controller()
        c.forceStateForTest(.failed(message: "Nope", partial: "", kind: .generic))
        let l = try labels(c)
        XCTAssertTrue(l.contains("Nope"), "\(l)")
        XCTAssertTrue(l.contains("Retry"), "\(l)")
    }

    func testSessionLimitOffersOpenConduit() throws {
        let c = controller()
        c.forceStateForTest(.failed(message: "limit", partial: "", kind: .sessionLimit))
        XCTAssertTrue(try labels(c).contains("Open Conduit"))
    }

    func testConnectionLostDuringTurnShowsNotice() throws {
        let c = controller()
        c.forceStateForTest(.streaming(text: "so far", status: nil))
        c.connectionChanged(.disconnected)
        let l = try labels(c)
        XCTAssertTrue(l.contains { $0.hasPrefix("Connection lost") }, "\(l)")
        XCTAssertTrue(l.contains("Open in Conduit"), "promote stays enabled")
    }

    func testToolStatusShowsWhileStreaming() throws {
        let c = controller()
        c.forceStateForTest(.streaming(text: "x", status: "web_search"))
        XCTAssertTrue(try labels(c).contains("web_search"))
    }

    func testEveryButtonHasAName() throws {
        let c = controller()
        c.forceStateForTest(.streaming(text: "x", status: "web_search"))
        let w = try host(c)
        HostedTestSupport.settle(0.3)
        let buttons = AccessibilityProbe.nodes(in: w).filter { $0.role.contains("Button") }
        XCTAssertFalse(buttons.isEmpty)
        for node in buttons {
            XCTAssertFalse((node.label ?? "").isEmpty, "unnamed button \(node)")
        }
    }

    func testRendersInLightAndDark() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let c = controller()
            c.forceStateForTest(.done(text: "**Hi** there"))
            let w = try host(c)
            w.appearance = NSAppearance(named: name)
            HostedTestSupport.settle()
            let content = try XCTUnwrap(w.contentView)
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            HostedTestSupport.tearDown(w)
            window = nil
        }
    }

    func testInstalledPanelBuildsAHostingPanelWithTheSpecConfig() {
        let c = controller()
        c.installDefaultPanel()
        let panel = c.makePanel(c)
        XCTAssertFalse(panel.isVisible)
    }

    /// The real panel, not a stand-in: it takes key without activating the app,
    /// the field gets first responder, and a reopen focuses it again.
    func testRealPanelTakesKeyAndFocusesTheFieldOnEveryShow() throws {
        let c = controller()
        c.installDefaultPanel()
        let host = try XCTUnwrap(c.makePanel(c) as? MacFloatingPanelController)
        c.panel = host
        defer { host.hide(); host.panel.contentView = nil }
        func fieldIsFocused() -> Bool {
            host.panel.isKeyWindow && host.panel.firstResponder is NSText
        }
        c.show()
        XCTAssertTrue(HostedTestSupport.waitUntil { fieldIsFocused() }, "first show: \(String(describing: host.panel.firstResponder))")
        XCTAssertFalse(host.panel.canBecomeMain)
        c.hide(); c.panelDidDismiss()
        host.panel.makeFirstResponder(host.panel)   // the state a reopened panel can come back in
        c.show()
        XCTAssertTrue(HostedTestSupport.waitUntil { fieldIsFocused() }, "reopen: \(String(describing: host.panel.firstResponder))")
    }
}
