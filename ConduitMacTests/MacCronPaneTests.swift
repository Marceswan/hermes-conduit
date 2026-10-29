import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacCronPaneTests: XCTestCase {
    private var boostWasOn = false

    override func setUp() {
        super.setUp()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() {
        AccessibilityTreeBoost.set(boostWasOn)
        super.tearDown()
    }

    /// Hosts the Cron tab of the router and returns the "New job" and
    /// "From a blueprint" buttons.
    private func createButtons(in window: NSWindow) -> [AccessibilityProbe.Node] {
        AccessibilityProbe.nodes(in: window).filter {
            $0.role == "AXButton" && ($0.label == "New job" || $0.label == "From a blueprint")
        }
    }

    private func hostCronTab() throws -> (NSWindow, [AccessibilityProbe.Node]) {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.cron.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let window = HostedTestSupport.host(
            MacDetailRouter(defaults: suite.defaults, notificationCenter: NotificationCenter(), chat: { Color.clear })
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .frame(width: 900, height: 600),
            size: NSSize(width: 900, height: 600))
        HostedTestSupport.settle(0.4)
        AccessibilityTreeBoost.set(true)
        _ = HostedTestSupport.waitUntil(timeout: 5) { createButtons(in: window).count == 2 }
        HostedTestSupport.settle(0.2)
        return (window, createButtons(in: window))
    }

    func testCronTabShowsMacCronPane() throws {
        let (window, buttons) = try hostCronTab()
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertEqual(Set(buttons.compactMap(\.label)), ["New job", "From a blueprint"], "\(buttons)")
    }

    func testCreateButtonsDisabledWithoutDashboardBridge() throws {
        let (window, buttons) = try hostCronTab()
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertNil(AppStateRuntimeRegistry.shared.appState.dashboardTicketBridge)
        XCTAssertEqual(buttons.count, 2)
        XCTAssertTrue(buttons.allSatisfy { $0.isEnabled == false }, "\(buttons)")
    }

    /// `AppState.dashboardTicketBridge` is `private(set)`, so the enabled
    /// state is checked on the rule the buttons read.
    func testCreateButtonsEnabledWithDashboardBridge() {
        XCTAssertTrue(MacCronPane.createActionsEnabled(hasDashboardBridge: true, cronJobActionID: nil))
        XCTAssertFalse(MacCronPane.createActionsEnabled(hasDashboardBridge: false, cronJobActionID: nil))
        XCTAssertFalse(MacCronPane.createActionsEnabled(hasDashboardBridge: true, cronJobActionID: "job-1"))
        XCTAssertFalse(MacCronPane.createActionsEnabled(hasDashboardBridge: false, cronJobActionID: "job-1"))
    }

    func testBlueprintCreatedJobOpensDetail() {
        let job = CronJob(enabled: true, id: "made", name: "Made from a blueprint")
        XCTAssertEqual(MacCronPane.jobToOpen(afterGalleryClosedWith: job)?.id, "made")
        XCTAssertNil(MacCronPane.jobToOpen(afterGalleryClosedWith: nil))
    }

    // MARK: Sheet size (the create, edit and gallery sheets share one Mac frame)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testCreateAndGallerySheetsUseTheMacFormSheetSize() throws {
        let text = try source("ConduitMac/Cron/MacCronPane.swift")
        for sheet in ["CronJobEditorSheet(target:", "CronBlueprintGallerySheet"] {
            let range = try XCTUnwrap(text.range(of: sheet), sheet)
            let tail = text[range.upperBound...]
            let chain = tail.prefix(while: { _ in true }).prefix(200)
            XCTAssertTrue(chain.contains(".macFormSheetSize("), "\(sheet) has no .macFormSheetSize within its modifier chain")
        }
    }

    func testEditSheetUsesTheMacFormSheetSize() throws {
        let text = try source("Conduit/Views/SidebarView.swift")
        let range = try XCTUnwrap(text.range(of: "CronJobEditorSheet(target: .edit(job))"))
        let chain = text[range.upperBound...].prefix(300)
        XCTAssertTrue(chain.contains("#if os(macOS) // MAC:"), "no Mac region after the edit sheet")
        XCTAssertTrue(chain.contains(".macFormSheetSize("), "edit sheet has no .macFormSheetSize")
    }
}
