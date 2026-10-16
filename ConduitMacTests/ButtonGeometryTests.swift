import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

/// Reads real control geometry through the same accessibility tree the hover
/// layer uses, so heights, insets and shapes are checked on what SwiftUI lays
/// out, not on constants.
@MainActor
final class ButtonGeometryTests: XCTestCase {
    struct Node {
        var role: String
        var label: String?
        var identifier: String?
        var frame: CGRect
        var path: NSBezierPath?
    }

    private var boostWasOn = false

    override func setUp() {
        super.setUp()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() {
        AccessibilityTreeBoost.set(boostWasOn)
        super.tearDown()
    }

    /// Hosts `view`, waits for the accessibility tree and returns the
    /// interactive nodes with frames relative to the hosting view's top-left.
    private func controls<V: View>(in view: V, size: NSSize, dark: Bool = true) throws -> [Node] {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { HostedTestSupport.tearDown(window) }
        HostedTestSupport.settle(0.4)
        AccessibilityTreeBoost.set(true)
        let start = Date()
        while (host.accessibilityChildren() ?? []).isEmpty, Date().timeIntervalSince(start) < 3 {
            HostedTestSupport.settle(0.01)
        }
        HostedTestSupport.settle(0.3)
        let content = window.convertToScreen(host.convert(host.bounds, to: nil))
        var nodes: [Node] = []
        func walk(_ element: NSObject, depth: Int) {
            if let rawRole: String = element.axValue("accessibilityRole"),
               HoverTooltipPolicy.interactiveRoles.contains(NSAccessibility.Role(rawValue: rawRole)),
               let frame: NSValue = element.axValue("accessibilityFrame") {
                let r = frame.rectValue
                // Screen space is bottom-left; report top-left relative to the host.
                let rel = CGRect(x: r.minX - content.minX, y: content.maxY - r.maxY, width: r.width, height: r.height)
                nodes.append(Node(role: rawRole, label: element.axValue("accessibilityLabel"),
                                  identifier: element.axValue("accessibilityIdentifier"), frame: rel,
                                  path: element.axValue("accessibilityPath")))
            }
            let kids: [Any]? = element.axValue("accessibilityChildren")
            if depth < 8 { for kid in kids ?? [] { if let o = kid as? NSObject { walk(o, depth: depth + 1) } } }
        }
        for kid in host.accessibilityChildren() ?? [] { if let o = kid as? NSObject { walk(o, depth: 0) } }
        return nodes
    }

    private func isRounded(_ node: Node) -> Bool {
        guard let path = node.path else { return false }
        return path.elementCount > 6  // a plain rectangle is 6 elements
    }

    // MARK: Tab strip

    private func strip(width: CGFloat) throws -> [Node] {
        try controls(in: MacSidebarTabStrip(selectedRaw: .constant("Sessions"))
                        .padding(.horizontal, 14).padding(.vertical, 20),
                     size: NSSize(width: width, height: MacTabStripMetrics.containerHeight + 40))
    }

    /// Strip order (`MacSidebarTabOrder.strip`): Home leftmost.
    private let allNames = ["Home", "Sessions", "Bots", "Cron", "Kanban"]

    func testWideStripShowsFiveEqualSegmentsWithNames() throws {
        let width: CGFloat = 640
        let nodes = try strip(width: width)
        XCTAssertEqual(nodes.map(\.label), allNames)
        let containerWidth = width - 28
        for (index, node) in nodes.enumerated() {
            let expected = MacTabStripMetrics.indicatorFrame(index: index, count: 5, containerWidth: containerWidth)
                .offsetBy(dx: 14, dy: 20)
            XCTAssertEqual(node.frame.minX, expected.minX, accuracy: 0.6, "x of \(node.label ?? "")")
            XCTAssertEqual(node.frame.minY, expected.minY, accuracy: 0.6, "y of \(node.label ?? "")")
            XCTAssertEqual(node.frame.width, expected.width, accuracy: 0.6, "width of \(node.label ?? "")")
            XCTAssertEqual(node.frame.height, MacTabStripMetrics.segmentHeight, accuracy: 0.6)
            XCTAssertTrue(isRounded(node), "indicator shape must be rounded: \(node.label ?? "")")
        }
        XCTAssertTrue(nodes.allSatisfy { $0.identifier == HoverTooltipPolicy.visibleLabelIdentifier },
                      "names are visible, so no tooltip repeats them")
        XCTAssertEqual(nodes.map(\.label), MacSidebarTabOrder.strip.map(\.displayName), "the strip follows its Mac-owned order")
        XCTAssertEqual(try XCTUnwrap(nodes.first).frame.minX - 14, MacTabStripMetrics.inset, accuracy: 0.6, "left inset")
        XCTAssertEqual(width - 14 - (try XCTUnwrap(nodes.last)).frame.maxX, MacTabStripMetrics.inset, accuracy: 0.6, "right inset")
        XCTAssertEqual(try XCTUnwrap(nodes.first).frame.minY - 20, MacTabStripMetrics.inset, accuracy: 0.6, "top inset")
    }

    /// The widest the sidebar column can be dragged (390 pt) is the only column width where the
    /// second step of the ladder shows: four equal name segments (the widest, Sessions, sets the
    /// width) plus the 38 pt Home segment (leftmost) need 338 pt inside the padding.
    func testWidestColumnKeepsTheFourExistingNamesAndCompactsHome() throws {
        let nodes = try strip(width: MacSidebarState.sidebarMaxWidth)
        XCTAssertEqual(nodes.map(\.label), allNames)
        let home = try XCTUnwrap(nodes.first)
        XCTAssertEqual(home.label, "Home", "Home is the leftmost segment")
        let names = nodes.dropFirst()
        XCTAssertTrue(names.allSatisfy { $0.identifier == HoverTooltipPolicy.visibleLabelIdentifier },
                      "Sessions, Bots, Cron and Kanban keep their names at the widest column: \(nodes.map { $0.identifier ?? "nil" })")
        XCTAssertNotEqual(home.identifier, HoverTooltipPolicy.visibleLabelIdentifier, "Home is icon-only and keeps its tooltip")
        XCTAssertEqual(home.frame.width, MacTabStripMetrics.homeSegmentWidth - 2 * MacTabStripMetrics.inset, accuracy: 0.6)
        XCTAssertEqual(home.frame.minX - 14, MacTabStripMetrics.inset, accuracy: 0.6, "left inset")
        let widths = names.map(\.frame.width)
        XCTAssertEqual(try XCTUnwrap(widths.max()) - (try XCTUnwrap(widths.min())), 0, accuracy: 0.6, "the four names stay equal")
        XCTAssertEqual(MacSidebarState.sidebarMaxWidth - 14 - (try XCTUnwrap(nodes.last)).frame.maxX, MacTabStripMetrics.inset, accuracy: 0.6, "right inset")
    }

    /// Spec open question 2, measured: at the default 340 pt column (312 pt inside the padding)
    /// the four names plus a compact Home need 338 pt, so the strip falls to icons. The column
    /// metrics are pinned elsewhere (D6), so the ladder yields instead.
    func testDefaultColumnFallsBackToIconsAndKeepsEveryName() throws {
        let nodes = try strip(width: MacSidebarState.sidebarIdealWidth)
        XCTAssertEqual(nodes.map(\.label), allNames, "icon-only segments keep every name for VoiceOver")
        XCTAssertTrue(nodes.allSatisfy { $0.identifier != HoverTooltipPolicy.visibleLabelIdentifier },
                      "icon-only segments keep their tooltip: \(nodes.map { $0.identifier ?? "nil" })")
        let widths = nodes.map(\.frame.width)
        XCTAssertEqual(try XCTUnwrap(widths.max()) - (try XCTUnwrap(widths.min())), 0, accuracy: 0.6, "equal segments")
        XCTAssertEqual(MacTabStripMetrics.ladder(availableWidth: MacSidebarState.sidebarIdealWidth - 28,
                                                 nameSegmentWidths: MacSidebarTabStrip.nameSegmentWidths), .icons)
    }

    func testLadderStepsAcrossTheColumnRange() {
        let widths = MacSidebarTabStrip.nameSegmentWidths
        let step = { (column: CGFloat) in MacTabStripMetrics.ladder(availableWidth: column - 28, nameSegmentWidths: widths) }
        XCTAssertEqual(step(MacSidebarState.sidebarMinWidth), .icons)
        XCTAssertEqual(step(MacSidebarState.sidebarIdealWidth), .icons)
        XCTAssertEqual(step(MacSidebarState.sidebarMaxWidth), .homeCompact)
        XCTAssertEqual(MacTabStripMetrics.ladder(availableWidth: 640 - 28, nameSegmentWidths: widths), .names)
    }

    func testNarrowStripDropsEverythingToIcons() throws {
        let narrow = try strip(width: 232 + 28)
        XCTAssertEqual(narrow.count, 5)
        XCTAssertEqual(narrow.map(\.label), allNames, "icon-only segments keep every name for VoiceOver")
        XCTAssertTrue(narrow.allSatisfy { $0.identifier != HoverTooltipPolicy.visibleLabelIdentifier },
                      "icon-only segments keep their tooltip")
        let widths = narrow.map(\.frame.width)
        XCTAssertEqual(try XCTUnwrap(widths.max()) - (try XCTUnwrap(widths.min())), 0, accuracy: 0.6, "equal segments")
    }

    /// The ladder is decided from measured text, not from the layout itself, so
    /// the widths it assumes are checked against what SwiftUI would size the
    /// all-names and compact layouts to when asked for their ideal width.
    func testLadderThresholdsMatchTheLaidOutIdealWidths() {
        let strip = MacSidebarTabStrip(selectedRaw: .constant("Sessions"))
        func ideal(_ ladder: MacTabStripMetrics.Ladder) -> CGFloat {
            let host = NSHostingView(rootView: strip.content(ladder).fixedSize(horizontal: true, vertical: false))
            return host.fittingSize.width
        }
        let widths = MacSidebarTabStrip.nameSegmentWidths
        let namesNeed = CGFloat(widths.count) * (widths.values.max() ?? 0)
        let compactNeed = CGFloat(widths.count - 1) * (widths.filter { $0.key != .home }.values.max() ?? 0) + MacTabStripMetrics.homeSegmentWidth
        XCTAssertEqual(ideal(.names), namesNeed, accuracy: 1.0)
        XCTAssertEqual(ideal(.homeCompact), compactNeed, accuracy: 1.0)
    }

    // MARK: Glass controls

    // The two tests below build their own views from `MacControlHeight.compact`: they pin what
    // `conduitGlassControl` reports (shape and size) for any control. The production sidebar and
    // Kanban header sizes are pinned in SidebarDensityTests.

    func testGlassControlsReportTheirOwnShapeAndSize() throws {
        let nodes = try controls(
            in: HStack(spacing: 12) {
                Button { } label: { Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).frame(width: MacControlHeight.compact, height: MacControlHeight.compact) }
                    .conduitGlassControl(cornerRadius: 18).accessibilityLabel("Settings")
                Menu { Button("A") { } } label: { Image(systemName: "ellipsis.circle").frame(width: MacControlHeight.compact, height: MacControlHeight.compact) }
                    .conduitGlassControl(cornerRadius: MacSidebarMetrics.controlRadius)
            }.padding(20),
            size: NSSize(width: 200, height: 100))
        XCTAssertEqual(nodes.count, 2)
        for node in nodes {
            XCTAssertEqual(node.frame.width, MacControlHeight.compact, accuracy: 0.6, "\(node.role) width")
            XCTAssertEqual(node.frame.height, MacControlHeight.compact, accuracy: 0.6, "\(node.role) height")
            XCTAssertTrue(isRounded(node), "\(node.role) shape")
        }
    }

    /// Kanban's header menus were 28 pt tall and its refresh and + buttons 44: a Menu on its
    /// default Mac style ignores the label's frame and a default-style Button adds a bezel
    /// and padding. All five now come out at `MacControlHeight.compact`.
    func testPaneHeaderControlsShareOneHeight() throws {
        let icon = { (name: String) in
            Image(systemName: name).frame(width: MacControlHeight.compact, height: MacControlHeight.compact)
        }
        let nodes = try controls(
            in: HStack(spacing: 8) {
                Menu { Button("A") { } } label: { icon("square.grid.2x2") }.conduitGlassControl(cornerRadius: 14)
                Menu { Button("A") { } } label: { icon("ellipsis.circle") }.conduitGlassControl(cornerRadius: 14)
                Button { } label: { icon("checkmark.circle") }.conduitGlassControl(cornerRadius: 14)
                Button { } label: { icon("arrow.clockwise") }.conduitGlassControl(cornerRadius: 14)
                Button { } label: { icon("plus") }.conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.12))
            }.padding(20),
            size: NSSize(width: 320, height: 80))
        XCTAssertEqual(nodes.count, 5)
        for node in nodes {
            XCTAssertEqual(node.frame.height, MacControlHeight.compact, accuracy: 0.6, "\(node.role)")
            XCTAssertEqual(node.frame.width, MacControlHeight.compact, accuracy: 0.6, "\(node.role)")
        }
    }
}
