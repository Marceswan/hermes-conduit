import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Home's secondary text and chart marks against the window background in
/// light and dark, from the resolved colours (the method of MacPaletteContrastTests).
@MainActor
final class MacHomeContrastTests: XCTestCase {
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

    private func ratio(_ fg: RGBA, on background: RGBA) -> Double {
        let a = luminance(over(fg, background)), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testSecondaryTextClearsFourPointFiveToOne() {
        for dark in [false, true] {
            let window = resolve(.windowBackgroundColor, dark: dark)
            XCTAssertGreaterThanOrEqual(ratio(resolve(MacHomeStyle.secondaryText, dark: dark), on: window), 4.5, dark ? "dark" : "light")
        }
    }

    func testChartMarksClearThreeToOne() {
        for dark in [false, true] {
            let window = resolve(.windowBackgroundColor, dark: dark)
            let name = dark ? "dark" : "light"
            XCTAssertGreaterThanOrEqual(ratio(resolve(MacHomeStyle.emphasisMark, dark: dark), on: window), 3, "emphasis mark, \(name)")
            XCTAssertGreaterThanOrEqual(ratio(resolve(MacHomeStyle.mutedMark, dark: dark), on: window), 3, "muted mark, \(name)")
        }
    }
}
