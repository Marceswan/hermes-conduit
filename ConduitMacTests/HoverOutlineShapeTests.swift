import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

@MainActor
final class HoverOutlineShapeTests: XCTestCase {
    private func rect(_ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: 100, y: 200, width: w, height: h) }

    // MARK: Fallback radius

    func testFallbackRadiusIsHalfTheHeightCappedAt18() {
        XCTAssertEqual(HoverOutlineShape.fallbackRadius(for: rect(120, 20)), 10)
        XCTAssertEqual(HoverOutlineShape.fallbackRadius(for: rect(36, 36)), 18)
        XCTAssertEqual(HoverOutlineShape.fallbackRadius(for: rect(176, 44)), 18, "capped, not a 22 pt capsule")
        XCTAssertEqual(HoverOutlineShape.fallbackRadius(for: rect(300, 160)), 18)
        XCTAssertEqual(HoverOutlineShape.fallbackRadius(for: rect(13, 13)), 6.5)
        XCTAssertEqual(HoverOutlineShape.fallbackRadius(for: rect(40, 10)), 5, "follows the shorter side")
        XCTAssertEqual(HoverOutlineShape.fallbackRadius(for: .zero), 0)
    }

    // MARK: Using the control's own path

    private func roundedPath(_ frame: CGRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    }

    func testReportedPathIsKeptWhenItsBoundsMatchTheFrame() {
        let frame = rect(70, 36)
        let path = roundedPath(frame, radius: 14)
        let shape = HoverOutlineShape.make(frame: frame, axPath: path)
        XCTAssertNotNil(shape.accessibilityPath)
        // Within tolerance counts as a match.
        XCTAssertNotNil(HoverOutlineShape.make(frame: frame.insetBy(dx: 1, dy: 1), axPath: path).accessibilityPath)
    }

    func testReportedPathIsDroppedWhenMissingEmptyOrForAnotherFrame() {
        let frame = rect(70, 36)
        XCTAssertNil(HoverOutlineShape.make(frame: frame, axPath: nil).accessibilityPath)
        XCTAssertNil(HoverOutlineShape.make(frame: frame, axPath: NSBezierPath()).accessibilityPath)
        let glyphOnly = roundedPath(CGRect(x: 120, y: 210, width: 17, height: 17), radius: 4)
        XCTAssertNil(HoverOutlineShape.make(frame: frame, axPath: glyphOnly).accessibilityPath)
    }

    func testOutlinePathIsTranslatedIntoWindowCoordinates() {
        let frame = rect(70, 36)
        let origin = CGPoint(x: frame.minX - 8, y: frame.minY - 8)
        let own = HoverOutlineShape.make(frame: frame, axPath: roundedPath(frame, radius: 14)).path(relativeTo: origin)
        XCTAssertEqual(own.bounds.minX, 8, accuracy: 0.01)
        XCTAssertEqual(own.bounds.minY, 8, accuracy: 0.01)
        XCTAssertEqual(own.bounds.width, 70, accuracy: 0.01)
        let fallback = HoverOutlineShape.make(frame: frame, axPath: nil).path(relativeTo: origin)
        XCTAssertEqual(fallback.bounds.minX, 8, accuracy: 0.01)
        XCTAssertEqual(fallback.bounds.height, 36, accuracy: 0.01)
        XCTAssertGreaterThan(fallback.elementCount, 6, "rounded, not a plain rectangle")
    }

    // MARK: Accent colour

    func testHighlightUsesTheAppAccentNeverSystemBlue() throws {
        func resolved(_ name: NSAppearance.Name) throws -> NSColor {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var color = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                color = HighlightWindow.accentColor.usingColorSpace(.sRGB) ?? .clear
            }
            return color
        }
        let dark = try resolved(.darkAqua)
        let light = try resolved(.aqua)
        // Conduit's amber, as in Theme.swift (0.88/0.67/0.28 dark, 0.55/0.37/0.13 light).
        XCTAssertEqual(dark.redComponent, 0.88, accuracy: 0.02)
        XCTAssertEqual(dark.blueComponent, 0.28, accuracy: 0.02)
        XCTAssertEqual(light.redComponent, 0.55, accuracy: 0.02)
        XCTAssertEqual(light.blueComponent, 0.13, accuracy: 0.02)
        let system = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        XCTAssertNotEqual(dark.redComponent, system?.redComponent)
    }

    // MARK: End to end through SwiftUI's accessibility tree

    /// A SwiftUI control reports the shape it draws: the rounded glass shape of
    /// `conduitGlassControl`, a declared `.contentShape`. The engine reads it.
    func testSnapshotCarriesTheRoundedShapeOfASwiftUIControl() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let wasOn = AccessibilityTreeBoost.isOn
        defer { AccessibilityTreeBoost.set(wasOn) }
        let root = Button { } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
            .conduitGlassControl(cornerRadius: 18)
            .accessibilityLabel("Settings")
            .padding(30)
        let window = HostedTestSupport.host(root.frame(width: 120, height: 120), size: NSSize(width: 120, height: 120))
        defer { HostedTestSupport.tearDown(window) }
        let host = try XCTUnwrap(window.contentView)
        AccessibilityTreeBoost.set(true)
        let start = Date()
        while (host.accessibilityChildren() ?? []).isEmpty, Date().timeIntervalSince(start) < 3 {
            HostedTestSupport.settle(0.01)
        }
        let kid = try XCTUnwrap(((host.accessibilityChildren() ?? []) as [Any]).compactMap { $0 as? NSObject }.first)
        let frame: NSValue? = kid.axValue("accessibilityFrame")
        let r = try XCTUnwrap(frame?.rectValue)
        let snapshot = try XCTUnwrap(HoverAccessibilityEngine.snapshot(at: NSPoint(x: r.midX, y: r.midY), in: window))
        let path = try XCTUnwrap(snapshot.shapePath, "SwiftUI node reports its shape")
        XCTAssertGreaterThan(path.elementCount, 6)
        let shape = HoverOutlineShape.make(frame: snapshot.frame, axPath: snapshot.shapePath)
        XCTAssertNotNil(shape.accessibilityPath, "the path matches the frame, so it is used")
        XCTAssertEqual(snapshot.frame.size.width, 44, accuracy: 0.6)
    }
}
