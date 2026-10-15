import AppKit
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
}
