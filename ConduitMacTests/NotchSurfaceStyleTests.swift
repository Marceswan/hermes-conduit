import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

final class NotchSurfaceStyleTests: XCTestCase {
    private func layout(_ edge: NSRectEdge?) -> NotchLayout {
        NotchLayout.make(standardIsNotch: true, dock: edge.map { MacEdgeDock(edge: $0, offset: 0.5, screenID: 1) })
    }

    // MARK: persistence keys

    func testRawValuesAreStablePersistenceKeys() {
        XCTAssertEqual(NotchSurfaceStyle.allCases.map(\.rawValue), ["glass", "darkGlass", "solid", "dock"])
    }

    func testEveryStyleHasATitleAndAnExplanation() {
        for style in NotchSurfaceStyle.allCases {
            XCTAssertFalse(style.title.isEmpty, style.rawValue)
            XCTAssertFalse(style.explanation.isEmpty, style.rawValue)
        }
    }

    // MARK: effective

    func testGlassStylesFallBackToSolidWhereGlassIsUnavailable() {
        for style in [NotchSurfaceStyle.glass, .darkGlass, .dock] {
            XCTAssertEqual(style.effective(glassAvailable: false), .solid, style.rawValue)
            XCTAssertEqual(style.effective(glassAvailable: true), style, style.rawValue)
        }
        XCTAssertEqual(NotchSurfaceStyle.solid.effective(glassAvailable: false), .solid)
        XCTAssertEqual(NotchSurfaceStyle.solid.effective(glassAvailable: true), .solid)
    }

    func testReduceTransparencyForcesSolid() {
        for style in NotchSurfaceStyle.allCases {
            XCTAssertEqual(style.effective(glassAvailable: true, reduceTransparency: true), .solid, style.rawValue)
            XCTAssertEqual(style.effective(glassAvailable: false, reduceTransparency: true), .solid, style.rawValue)
        }
    }

    func testEffectiveWithoutArgumentsUsesThisMacsAvailability() {
        XCTAssertEqual(NotchSurfaceStyle.glass.effective(), NotchSurfaceStyle.glass.effective(glassAvailable: NotchSurfaceStyle.glassAvailable))
    }

    func testIsGlassIsTrueOnlyForTheGlassStylesThatSurvivedTheFallback() {
        XCTAssertTrue(NotchSurfaceStyle.glass.isGlass(glassAvailable: true))
        XCTAssertTrue(NotchSurfaceStyle.darkGlass.isGlass(glassAvailable: true))
        XCTAssertTrue(NotchSurfaceStyle.dock.isGlass(glassAvailable: true))
        XCTAssertFalse(NotchSurfaceStyle.solid.isGlass(glassAvailable: true))
        XCTAssertFalse(NotchSurfaceStyle.glass.isGlass(glassAvailable: false))
    }

    // MARK: resolved(on:)

    func testTopEdgeIsTheStandardPlacementAndTheTopDock() {
        XCTAssertTrue(layout(nil).isTopEdge)
        XCTAssertTrue(layout(.maxY).isTopEdge)
        XCTAssertFalse(layout(.minY).isTopEdge)
        XCTAssertFalse(layout(.minX).isTopEdge)
        XCTAssertFalse(layout(.maxX).isTopEdge)
    }

    func testDockResolvesToDarkGlassOnTheTopEdgeSoItStaysWeldedToTheBezel() {
        XCTAssertEqual(NotchSurfaceStyle.dock.resolved(on: layout(nil)), .darkGlass)
        XCTAssertEqual(NotchSurfaceStyle.dock.resolved(on: layout(.maxY)), .darkGlass)
    }

    func testDockStaysDockOnTheBottomLeftAndRightEdges() {
        for edge in [NSRectEdge.minY, .minX, .maxX] {
            XCTAssertEqual(NotchSurfaceStyle.dock.resolved(on: layout(edge)), .dock, "\(edge)")
        }
    }

    func testOtherStylesResolveToThemselvesOnEveryEdge() {
        for style in [NotchSurfaceStyle.glass, .darkGlass, .solid] {
            for edge: NSRectEdge? in [nil, .maxY, .minY, .minX, .maxX] {
                XCTAssertEqual(style.resolved(on: layout(edge)), style)
            }
        }
    }

    // MARK: drawn (resolved, then effective, then reduce transparency)

    func testDrawnAppliesEdgeThenAvailabilityThenReduceTransparency() {
        let bottom = layout(.minY), top = layout(nil)
        XCTAssertEqual(NotchSurfaceStyle.dock.drawn(on: bottom, glassAvailable: true, reduceTransparency: false), .dock)
        XCTAssertEqual(NotchSurfaceStyle.dock.drawn(on: top, glassAvailable: true, reduceTransparency: false), .darkGlass)
        XCTAssertEqual(NotchSurfaceStyle.dock.drawn(on: bottom, glassAvailable: false, reduceTransparency: false), .solid)
        XCTAssertEqual(NotchSurfaceStyle.glass.drawn(on: top, glassAvailable: true, reduceTransparency: true), .solid)
        XCTAssertEqual(NotchSurfaceStyle.glass.drawn(on: top, glassAvailable: true, reduceTransparency: false), .glass)
    }

    // MARK: panel appearance

    func testGlassLeavesThePanelAppearanceToTheSystem() {
        XCTAssertNil(NotchSurfaceStyle.glass.panelAppearance(glassAvailable: true, reduceTransparency: false))
    }

    func testEveryOtherStylePinsDarkAqua() {
        for style in [NotchSurfaceStyle.darkGlass, .solid, .dock] {
            XCTAssertEqual(style.panelAppearance(glassAvailable: true, reduceTransparency: false)?.name, .darkAqua, style.rawValue)
        }
    }

    func testGlassPinsDarkAquaWhenItFallsBackToSolidOrReduceTransparencyIsOn() {
        XCTAssertEqual(NotchSurfaceStyle.glass.panelAppearance(glassAvailable: false, reduceTransparency: false)?.name, .darkAqua,
                       "a light palette on a black surface would be unreadable")
        XCTAssertEqual(NotchSurfaceStyle.glass.panelAppearance(glassAvailable: true, reduceTransparency: true)?.name, .darkAqua)
    }

    func testOnlyTheGlassStyleFollowsTheSystemAppearance() {
        XCTAssertTrue(NotchSurfaceStyle.glass.followsSystemAppearance(glassAvailable: true, reduceTransparency: false))
        XCTAssertFalse(NotchSurfaceStyle.glass.followsSystemAppearance(glassAvailable: true, reduceTransparency: true))
        XCTAssertFalse(NotchSurfaceStyle.glass.followsSystemAppearance(glassAvailable: false, reduceTransparency: false))
        for style in [NotchSurfaceStyle.darkGlass, .solid, .dock] {
            XCTAssertFalse(style.followsSystemAppearance(glassAvailable: true, reduceTransparency: false), style.rawValue)
        }
    }

    // MARK: contrast (computed, not eyeballed)

    private typealias RGB = NotchPalette.RGB

    /// One surface the ink can land on, with the appearance that picks the ink variant.
    private struct Backdrop { let name: String; let rgb: RGB; let dark: Bool }

    /// Every surface the panel can show behind the ink, worst case first: the washed styles over a
    /// white window, solid black (also Reduce Transparency, the macOS 14 fallback and the band at the
    /// hardware notch), and system glass in both appearances over its reference tones.
    private func backdrops() -> [Backdrop] {
        var out: [Backdrop] = []
        for style in [NotchSurfaceStyle.darkGlass, .dock] {
            let alpha = style.glassDimAlpha ?? 0
            out.append(Backdrop(name: "\(style.rawValue) over white",
                                rgb: NotchPalette.washed(over: NotchPalette.worstCaseBackdropRGB, alpha: alpha), dark: true))
        }
        out.append(Backdrop(name: "solid", rgb: NotchPalette.surfaceRGB, dark: true))
        for (i, rgb) in NotchPalette.lightGlassReferenceRGBs.enumerated() {
            out.append(Backdrop(name: "glass light #\(i)", rgb: rgb, dark: false))
        }
        for (i, rgb) in NotchPalette.darkGlassReferenceRGBs.enumerated() {
            out.append(Backdrop(name: "glass dark #\(i)", rgb: rgb, dark: true))
        }
        return out
    }

    func testWashedStylesCarryAWashAndTheOthersDoNot() {
        for style in NotchSurfaceStyle.allCases {
            XCTAssertEqual(style.glassDim != nil, style.glassDimAlpha != nil, style.rawValue)
        }
        XCTAssertEqual(NotchSurfaceStyle.darkGlass.glassDimAlpha, NotchPalette.darkGlassDimAlpha)
        XCTAssertEqual(NotchSurfaceStyle.dock.glassDimAlpha, NotchPalette.dockDimAlpha)
    }

    func testWashedMath() {
        let washed = NotchPalette.washed(over: (1, 1, 1), alpha: 0.8)
        XCTAssertEqual(washed.r, 0.2, accuracy: 1e-9)
        XCTAssertEqual(washed.b, 0.2, accuracy: 1e-9)
        XCTAssertTrue(NotchPalette.washed(over: (0.5, 0.5, 0.5), alpha: 0) == (0.5, 0.5, 0.5))
    }

    /// The reported failure: Dark glass over a white window gave the secondary ink about 3.4:1.
    func testPrimaryAndSecondaryTextHold4Point5OverAWhiteWindowForDarkGlassAndDock() {
        for style in [NotchSurfaceStyle.darkGlass, .dock] {
            let backdrop = NotchPalette.washed(over: NotchPalette.worstCaseBackdropRGB, alpha: style.glassDimAlpha ?? 0)
            for ink in [NotchPalette.Ink.text, .secondary] {
                let ratio = NotchPalette.contrast(NotchPalette.rgb(ink, dark: true), backdrop)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(style.rawValue) \(ink) \(ratio)")
            }
        }
    }

    /// Attention and failure are text too (the review note, the "Couldn't send" line).
    func testEveryInkHolds4Point5OnEveryBackdrop() {
        for backdrop in backdrops() {
            for ink in NotchPalette.Ink.allCases {
                let ratio = NotchPalette.contrast(NotchPalette.rgb(ink, dark: backdrop.dark), backdrop.rgb)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(ink) on \(backdrop.name): \(ratio)")
            }
        }
    }

    func testTheWashIsLoadBearing() {
        // Without the wash the dark inks are white-on-white; guards a future change to a thinner wash.
        for style in [NotchSurfaceStyle.darkGlass, .dock] {
            XCTAssertGreaterThanOrEqual(style.glassDimAlpha ?? 0, 0.7, style.rawValue)
        }
    }

    // MARK: Allow / Deny buttons

    /// Non-text contrast (3:1) of the button fill against the surface it sits on, and the label
    /// (4.5:1) against the fill, in every style and both appearances.
    func testActionButtonsHold3To1AgainstEverySurfaceAndTheirLabelsHold4Point5() {
        for backdrop in backdrops() {
            for fill in [NotchPalette.Ink.attention, .failure] {
                let fillRGB = NotchPalette.rgb(fill, dark: backdrop.dark)
                let edge = NotchPalette.contrast(fillRGB, backdrop.rgb)
                XCTAssertGreaterThanOrEqual(edge, 3, "\(fill) fill on \(backdrop.name): \(edge)")
                let label = NotchPalette.contrast(NotchPalette.onAccentRGB(dark: backdrop.dark), fillRGB)
                XCTAssertGreaterThanOrEqual(label, 4.5, "label on \(fill) fill, dark=\(backdrop.dark): \(label)")
            }
        }
    }

    /// The system bordered style was replaced because it draws a grey pad that ignores the tint.
    /// The real button must paint the ink itself, resolved per appearance. The pad is compared with
    /// a plain swatch of the expected ink rendered through the same pipeline (absolute pixel values
    /// shift with the display profile, so the two are read the same way).
    @MainActor
    func testActionButtonStylePaintsTheInkAsItsFillInBothAppearances() throws {
        /// The most common colour that is not the black or white backdrop.
        func dominantColour<V: View>(_ view: V, dark: Bool) throws -> [Double] {
            let w = HostedTestSupport.host(view.padding(20).background(dark ? Color.black : Color.white),
                                           size: NSSize(width: 160, height: 90))
            defer { HostedTestSupport.tearDown(w) }
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            HostedTestSupport.settle(0.3)
            let content = try XCTUnwrap(w.contentView)
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            var histogram: [[Double]: Int] = [:]
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let key = [px.redComponent, px.greenComponent, px.blueComponent].map { ($0 * 100).rounded() / 100 }.map(Double.init)
                    if key == [0, 0, 0] || key == [1, 1, 1] { continue }
                    histogram[key, default: 0] += 1
                }
            }
            let top = try XCTUnwrap(histogram.max { $0.value < $1.value })
            XCTAssertGreaterThan(top.value, 500, "a solid pad, not an edge")
            return top.key
        }
        for fill in [NotchPalette.Ink.attention, .failure] {
            for dark in [true, false] {
                let expected = NotchPalette.rgb(fill, dark: dark)
                let swatch = try dominantColour(Rectangle().fill(Color(.sRGB, red: expected.r, green: expected.g, blue: expected.b))
                    .frame(width: 64, height: 20), dark: dark)
                let pad = try dominantColour(Button {} label: { Color.clear.frame(width: 40, height: 14) }
                    .buttonStyle(NotchActionButtonStyle(fill: fill)), dark: dark)
                for (a, b) in zip(pad, swatch) { XCTAssertEqual(a, b, accuracy: 0.02, "\(fill) dark=\(dark): pad \(pad) vs ink \(swatch)") }
            }
        }
    }
}
