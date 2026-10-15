import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// WCAG contrast of the palette's text in light and dark, computed from the
/// colours the rows use (resolved in each appearance), not from pixels.
@MainActor
final class MacPaletteContrastTests: XCTestCase {
    private struct RGBA { var r, g, b, a: Double }

    private func resolve(_ color: Color, dark: Bool) -> RGBA {
        var out = RGBA(r: 0, g: 0, b: 0, a: 1)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            out = RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
        }
        return out
    }

    private func resolve(_ color: NSColor, dark: Bool) -> RGBA {
        var out = RGBA(r: 0, g: 0, b: 0, a: 1)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? .black
            out = RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
        }
        return out
    }

    private func over(_ fg: RGBA, _ bg: RGBA) -> RGBA {
        RGBA(r: fg.r * fg.a + bg.r * (1 - fg.a), g: fg.g * fg.a + bg.g * (1 - fg.a), b: fg.b * fg.a + bg.b * (1 - fg.a), a: 1)
    }

    private func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func ratio(_ text: RGBA, on background: RGBA) -> Double {
        let a = luminance(over(text, background)), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testPaletteTextClearsFourPointFiveToOneInLightAndDark() {
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let window = resolve(.windowBackgroundColor, dark: dark)
            let accent = resolve(.conduitAccent, dark: dark)
            let name = dark ? "dark" : "light"

            let selectedTitle = resolve(MacPaletteRow.selectedText(scheme), dark: dark)
            let selectedSubtitle = resolve(MacPaletteRow.selectedText(scheme).opacity(MacPaletteRow.selectedSecondaryOpacity), dark: dark)
            let secondary = resolve(MacPaletteRow.secondaryText, dark: dark)
            let primary = resolve(.primary, dark: dark)

            XCTAssertGreaterThanOrEqual(ratio(primary, on: window), 4.5, "title on the panel, \(name)")
            XCTAssertGreaterThanOrEqual(ratio(secondary, on: window), 4.5, "subtitle, reason and headers on the panel, \(name)")
            XCTAssertGreaterThanOrEqual(ratio(selectedTitle, on: accent), 4.5, "title on the selected row, \(name)")
            XCTAssertGreaterThanOrEqual(ratio(selectedSubtitle, on: accent), 4.5, "subtitle on the selected row, \(name)")
        }
    }

    func testTheSystemSecondaryColourWasBelowTheTarget() {
        // Why the palette does not use `.secondary`: it is the reason for the
        // explicit opacity above. Documents the finding; goes red if macOS
        // changes the system colour enough that `.secondary` would do.
        let window = resolve(.windowBackgroundColor, dark: false)
        let system = resolve(.secondaryLabelColor, dark: false)
        XCTAssertLessThan(ratio(system, on: window), 4.5)
    }
}
