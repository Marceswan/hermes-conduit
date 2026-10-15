import AppKit
import SwiftUI

enum NotchPalette {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// The solid style and the band beside the hardware notch: black blends into the bezel, in light and dark.
    static let surfaceRGB: RGB = (0, 0, 0)

    /// What the light variants are checked against: standard Liquid Glass in light appearance
    /// over a light desktop (near white) and over a mid-light one. Glass takes its tone from what
    /// is behind it, so these two bracket the lightest and the darkest light-mode case we design for.
    static let lightGlassReferenceRGBs: [RGB] = [(0.95, 0.95, 0.96), (0.80, 0.80, 0.82)]

    /// The ink colours. Each has a dark variant (white-ish, for black and dark glass surfaces) and a light
    /// variant (for the Liquid Glass style when the Mac is in light appearance), both at least 4.5:1
    /// against their surfaces, which covers text (4.5:1) and glyphs (3:1) alike.
    enum Ink: CaseIterable {
        case text, secondary, attention, failure
    }

    static func rgb(_ ink: Ink, dark: Bool) -> RGB {
        switch (ink, dark) {
        case (.text, true): return (1, 1, 1)
        case (.secondary, true): return (0.78, 0.78, 0.80)
        case (.attention, true): return (1.0, 0.78, 0.20)
        case (.failure, true): return (1.0, 0.45, 0.42)
        case (.text, false): return (0.07, 0.07, 0.08)
        case (.secondary, false): return (0.27, 0.27, 0.30)
        case (.attention, false): return (0.45, 0.26, 0.0)
        case (.failure, false): return (0.62, 0.07, 0.07)
        }
    }

    static func color(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }

    /// Resolved against the window's appearance, so the panel's `appearance` (nil for the glass
    /// style, darkAqua for the others) is the one switch that decides which variant draws.
    static func color(_ ink: Ink) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = rgb(ink, dark: dark)
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    static var surface: Color { color(surfaceRGB) }
    static var text: Color { color(.text) }
    static var secondary: Color { color(.secondary) }
    static var attention: Color { color(.attention) }
    static var failure: Color { color(.failure) }

    /// The wash laid beneath `.clear` glass for the Dark glass style: opaque enough to read as the
    /// bezel, thin enough not to be the solid style.
    static let darkGlassDim = Color.black.opacity(0.60)
    /// The dock slab's own tint on its clear glass.
    static let dockGlassTint = Color.black.opacity(0.15)
    /// A lighter wash under the dock slab so the rows stay readable over a bright window.
    static let dockDim = Color.black.opacity(0.40)

    /// WCAG relative-luminance contrast ratio.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func lum(_ c: RGB) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }
        let (hi, lo) = (max(lum(a), lum(b)), min(lum(a), lum(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}

enum NotchMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.82)
    }
}
