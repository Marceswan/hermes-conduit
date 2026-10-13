import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

/// The hover outline of a window-toolbar item follows the system glass
/// platter, not the item's accessibility frame (D7). Measured on macOS 27: a
/// 36 pt round Refresh button reports 40 x 52 (its `NSToolbarItemViewer`) and
/// a title pill's text node reports 133 x 14, so the radius heuristic drew a
/// 40 x 52 rounded rectangle with an 18 pt radius.
@MainActor
final class ToolbarPlatterGeometryTests: XCTestCase {
    private func platter(_ x: CGFloat, _ w: CGFloat, h: CGFloat = 36) -> ToolbarPlatter {
        ToolbarPlatter(frame: CGRect(x: x, y: 900, width: w, height: h), cornerRadius: 18)
    }

    // MARK: Choosing the platter

    func testRoundButtonSlotMapsToItsCirclePlatter() {
        // Refresh: viewer 40 x 52 at x 539, platter 36 x 36 at the same x (8 pt inside vertically).
        let viewer = CGRect(x: 539, y: 892, width: 40, height: 52)
        let refresh = platter(539, 36)
        let status = platter(583, 36)
        XCTAssertEqual(ToolbarPlatterGeometry.platter(for: viewer, among: [status, refresh]), refresh)
    }

    func testStatusSlotWithTheSpacingOnTheOtherSideStillMapsToItsOwnPlatter() {
        // Status: viewer x 579..619, platter x 583..619 (spacing on the left).
        let viewer = CGRect(x: 579, y: 892, width: 40, height: 52)
        XCTAssertEqual(ToolbarPlatterGeometry.platter(for: viewer, among: [platter(539, 36), platter(583, 36)]),
                       platter(583, 36))
    }

    func testTitlePillTextNodeMapsToThePillPlatter() {
        // The SwiftUI menu node is the text only: 133.5 x 14 inside a 157.5 x 36 platter.
        let text = CGRect(x: 385.5, y: 911, width: 133.5, height: 14)
        let pill = platter(373.5, 157.5)
        XCTAssertEqual(ToolbarPlatterGeometry.platter(for: text, among: [pill, platter(539, 36)]), pill)
    }

    func testNoPlatterWhenTheElementIsNotOnOne() {
        let content = CGRect(x: 100, y: 300, width: 44, height: 44)
        XCTAssertNil(ToolbarPlatterGeometry.platter(for: content, among: [platter(539, 36)]))
        XCTAssertNil(ToolbarPlatterGeometry.platter(for: content, among: []))
        XCTAssertNil(ToolbarPlatterGeometry.platter(for: .zero, among: [platter(0, 36)]))
    }

    func testAPlatterMergedAcrossItemsOrTallerThanAToolbarIsRejected() {
        let viewer = CGRect(x: 539, y: 892, width: 40, height: 52)
        XCTAssertNil(ToolbarPlatterGeometry.platter(for: viewer, among: [platter(539, 84)]),
                     "two items on one platter would outline both")
        XCTAssertNil(ToolbarPlatterGeometry.platter(for: viewer, among: [platter(539, 36, h: 120)]),
                     "not a toolbar platter")
    }

    func testTheSmallestContainingPlatterWins() {
        let element = CGRect(x: 560, y: 892, width: 40, height: 52)
        let small = platter(560, 36)
        let wide = platter(540, 64)
        XCTAssertEqual(ToolbarPlatterGeometry.platter(for: element, among: [wide, small]), small)
    }

    // MARK: The outline

    func testPlatterOutlineIsACircleForARoundButton() throws {
        let slot = CGRect(x: 539, y: 892, width: 40, height: 52)
        let shape = HoverOutlineShape.make(frame: slot, axPath: nil, platter: platter(539, 36))
        XCTAssertEqual(shape.frame.size, CGSize(width: 36, height: 36), "not the 40 x 52 slot")
        XCTAssertEqual(shape.cornerRadius, 18)
        let path = shape.path(relativeTo: shape.frame.origin)
        XCTAssertEqual(path.bounds.width, 36, accuracy: 0.01)
        XCTAssertEqual(path.bounds.height, 36, accuracy: 0.01)
        // A circle puts its extreme points at the edge midpoints, so the
        // centre of each edge is on the path and the corner is not.
        XCTAssertTrue(path.contains(NSPoint(x: 18, y: 1)))
        XCTAssertFalse(path.contains(NSPoint(x: 2, y: 2)), "a rounded rectangle with a small radius would contain this")
    }

    func testPlatterOutlineIsACapsuleForAWidePlatter() {
        let pill = ToolbarPlatter(frame: CGRect(x: 373.5, y: 900, width: 157.5, height: 36), cornerRadius: 18)
        let shape = HoverOutlineShape.make(frame: CGRect(x: 385, y: 911, width: 133, height: 14), axPath: nil, platter: pill)
        XCTAssertEqual(shape.frame, pill.frame)
        XCTAssertEqual(shape.cornerRadius, 18, "half the height: a capsule")
    }

    func testPlatterRadiusNeverExceedsHalfTheShorterSide() {
        XCTAssertEqual(HoverOutlineShape.clampedRadius(30, for: CGRect(x: 0, y: 0, width: 80, height: 20)), 10)
        XCTAssertEqual(HoverOutlineShape.clampedRadius(18, for: CGRect(x: 0, y: 0, width: 36, height: 36)), 18)
        XCTAssertEqual(HoverOutlineShape.clampedRadius(-4, for: CGRect(x: 0, y: 0, width: 36, height: 36)), 0)
    }

    func testPlatterWinsOverAReportedPathAndNoPlatterChangesNothing() {
        let frame = CGRect(x: 100, y: 200, width: 133.5, height: 14)
        let rect = NSBezierPath(rect: frame)
        let on = HoverOutlineShape.make(frame: frame, axPath: rect,
                                        platter: ToolbarPlatter(frame: frame.insetBy(dx: -12, dy: -11), cornerRadius: 18))
        XCTAssertNil(on.accessibilityPath, "the sharp 133 x 14 rectangle is not drawn")
        let off = HoverOutlineShape.make(frame: frame, axPath: rect)
        XCTAssertNotNil(off.accessibilityPath)
        XCTAssertNil(off.cornerRadius)
        XCTAssertEqual(off, HoverOutlineShape.make(frame: frame, axPath: rect, platter: nil))
    }

    // MARK: Real toolbar, through the engine's own hit test

    private struct ToolbarRoot: View {
        @State private var query = ""
        var body: some View {
            NavigationStack {
                VStack {
                    Spacer()
                    Button("Content") {}.accessibilityLabel("Content button")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Button("Rename") {}
                        } label: {
                            Text("Evaluate Welcome Thing")
                                .font(.subheadline.weight(.semibold))
                                .macToolbarTitlePill()
                        } primaryAction: {}
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Evaluate Welcome Thing")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {} label: { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)) }
                            .accessibilityLabel("Refresh conversation")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {} label: {
                            ZStack {
                                Circle().fill(.green).frame(width: 9, height: 9)
                                Circle().stroke(.green.opacity(0.38), lineWidth: 1).frame(width: 19, height: 19)
                            }
                        }
                        .accessibilityLabel("Gateway connected")
                    }
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Search sessions")
            }
        }
    }

    /// Hosts the chat toolbar's shape (title pill, Refresh, status, search),
    /// then returns the engine's snapshot for each control by sweeping the
    /// toolbar strip, exactly as the hover engine would meet them.
    private func sweepToolbar() throws -> (window: NSWindow, snapshots: [String: HoverElementSnapshot]) {
        guard #available(macOS 26.0, *) else { throw XCTSkip("system toolbar platters need macOS 26") }
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let controller = NSHostingController(rootView: ToolbarRoot())
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 900, height: 400))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        AccessibilityTreeBoost.set(true)
        HostedTestSupport.settle(1.0)
        var found: [String: HoverElementSnapshot] = [:]
        let stripY = window.frame.maxY - 26
        for x in stride(from: window.frame.minX + 250, to: window.frame.maxX, by: 3) {
            if let snapshot = HoverAccessibilityEngine.snapshot(at: NSPoint(x: x, y: stripY), in: window) {
                let key = snapshot.label.flatMap { $0.isEmpty ? nil : $0 } ?? "role:\(snapshot.role?.rawValue ?? "?")"
                if found[key] == nil { found[key] = snapshot }
            }
        }
        return (window, found)
    }

    func testToolbarControlsOutlineTheirGlassPlatterNotTheirSlot() throws {
        let wasOn = AccessibilityTreeBoost.isOn
        defer { AccessibilityTreeBoost.set(wasOn) }
        let (window, snapshots) = try sweepToolbar()
        defer { HostedTestSupport.tearDown(window) }

        for name in ["Refresh conversation", "Gateway connected"] {
            let snapshot = try XCTUnwrap(snapshots[name], "engine meets \(name)")
            let platter = try XCTUnwrap(snapshot.platter, "\(name) sits on a platter")
            XCTAssertEqual(platter.frame.width, platter.frame.height, accuracy: 0.6, "\(name): round")
            XCTAssertLessThanOrEqual(platter.frame.height, ToolbarPlatterGeometry.maxPlatterHeight)
            XCTAssertGreaterThan(snapshot.frame.height, platter.frame.height, "the slot is taller than the glass (the bug)")
            let shape = HoverOutlineShape.make(frame: snapshot.frame, axPath: snapshot.shapePath, platter: snapshot.platter)
            XCTAssertEqual(shape.cornerRadius ?? 0, platter.frame.height / 2, accuracy: 0.6, "\(name): a circle")
            XCTAssertTrue(snapshot.frame.insetBy(dx: -0.6, dy: -0.6).contains(CGPoint(x: shape.frame.midX, y: shape.frame.midY)))
        }
        // The pill's SwiftUI menu node carries no label of its own.
        let pill = try XCTUnwrap(snapshots.values.first { $0.role == .menuButton }, "engine meets the title pill")
        let pillPlatter = try XCTUnwrap(pill.platter, "the pill sits on a platter")
        XCTAssertEqual(pillPlatter.frame.height, 36, accuracy: 0.6)
        XCTAssertGreaterThan(pillPlatter.frame.width, 100)
        XCTAssertLessThan(pill.frame.height, 20, "its text node alone is what the accessibility tree reports")
        XCTAssertEqual(HoverOutlineShape.make(frame: pill.frame, axPath: pill.shapePath, platter: pill.platter).cornerRadius ?? 0,
                       18, accuracy: 0.6, "a capsule")
    }

    func testContentButtonsAreNotGivenAPlatter() throws {
        let wasOn = AccessibilityTreeBoost.isOn
        defer { AccessibilityTreeBoost.set(wasOn) }
        let (window, _) = try sweepToolbar()
        defer { HostedTestSupport.tearDown(window) }
        // The button sits in the middle of the area below the toolbar.
        var found: HoverElementSnapshot?
        for y in stride(from: window.frame.minY + 20, to: window.frame.maxY - 60, by: 3) where found == nil {
            let hit = HoverAccessibilityEngine.snapshot(at: NSPoint(x: window.frame.midX, y: y), in: window)
            if hit?.label == "Content button" { found = hit }
        }
        let snapshot = try XCTUnwrap(found, "the content button")
        XCTAssertNil(snapshot.platter, "only toolbar items follow a platter; sidebar and content buttons are unchanged")
    }
}
