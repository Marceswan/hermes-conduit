import SwiftUI
import XCTest
@testable import ConduitMac

/// LC-B F5: in the grouped Mac Form a `TextField` title is also the row label, so the placeholder
/// showed at the left in full text color next to the value. The section header already names the field.
@MainActor
final class MacCronEditorFieldTests: XCTestCase {
    private var boostWasOn = false
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
        AccessibilityTreeBoost.set(boostWasOn)
        super.tearDown()
    }

    private func hostEditor() throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let window = HostedTestSupport.host(
            CronJobEditorSheet(target: .create)
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .frame(width: 520, height: 720),
            size: NSSize(width: 520, height: 720))
        windows.append(window)
        HostedTestSupport.settle(0.4)
        AccessibilityTreeBoost.set(true)
        _ = HostedTestSupport.waitUntil(timeout: 5) { !AccessibilityProbe.nodes(in: window).isEmpty }
        HostedTestSupport.settle(0.3)
        return window
    }

    func testNoPlaceholderShowsAsARowLabel() throws {
        let window = try hostEditor()
        let nodes = AccessibilityProbe.nodes(in: window)
        XCTAssertFalse(nodes.isEmpty, "the tree is readable")
        for placeholder in ["Name, like Morning brief", "What Hermes should do each time"] {
            let asText = nodes.filter {
                $0.role == "AXStaticText" && ($0.value == placeholder || $0.label == placeholder)
            }
            XCTAssertTrue(asText.isEmpty, "\(placeholder) is shown as a left label: \(asText)")
        }
    }

    /// The three plain `TextField`s of the editor carry the Mac gate (the blueprint fields keep their labels).
    func testSourceHidesTheLabelsOnMacOnly() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conduit/Views/V2/CronJobEditorSheet.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let marker = "#if os(macOS) // MAC: the section header names the field"
        let gated = source.components(separatedBy: marker)
        XCTAssertEqual(gated.count - 1, 3, "three gated sites")
        for tail in gated.dropFirst() {
            let body = tail.drop(while: { $0 != "\n" }).dropFirst().trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(body.hasPrefix(".labelsHidden()\n"), String(body.prefix(60)))
            XCTAssertTrue(body.dropFirst(".labelsHidden()\n".count).trimmingCharacters(in: .whitespaces).hasPrefix("#endif // MAC:"))
        }
    }
}
