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

    /// The same for standard Liquid Glass in dark appearance: a near-black pane and a lifted one
    /// (dark glass over a bright window is the brightest it gets). An approximation, like the light
    /// pair: the system picks the real tone from what is behind the glass.
    static let darkGlassReferenceRGBs: [RGB] = [(0.10, 0.10, 0.11), (0.30, 0.30, 0.32)]

    /// The worst-case backdrop for the washed styles: a white window right behind the panel. The wash
    /// is the only thing between it and the ink, so the contrast the Dark glass and Dock styles
    /// promise is the contrast over this (see `washed(over:alpha:)`).
    static let worstCaseBackdropRGB: RGB = (1, 1, 1)

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
        case (.failure, true): return (1.0, 0.65, 0.63)
        case (.text, false): return (0.07, 0.07, 0.08)
        case (.secondary, false): return (0.27, 0.27, 0.30)
        case (.attention, false): return (0.45, 0.26, 0.0)
        case (.failure, false): return (0.62, 0.07, 0.07)
        }
    }

    /// The label on an Allow / Deny fill (`NotchActionButtonStyle`): black on the light dark-variant
    /// fills, white on the deep light-variant ones. At least 4.5:1 against every fill.
    static func onAccentRGB(dark: Bool) -> RGB { dark ? (0, 0, 0) : (1, 1, 1) }

    static func color(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }

    /// Resolved against the window's appearance, so the panel's `appearance` (nil for the glass
    /// style, darkAqua for the others) is the one switch that decides which variant draws.
    static func color(_ ink: Ink) -> Color { adaptive { rgb(ink, dark: $0) } }

    private static func adaptive(_ pick: @escaping (_ dark: Bool) -> RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = pick(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    /// Resolved the same way as `color(_ ink:)`: the panel's appearance picks the variant.
    static var onAccent: Color { adaptive { onAccentRGB(dark: $0) } }

    static var surface: Color { color(surfaceRGB) }
    static var text: Color { color(.text) }
    static var secondary: Color { color(.secondary) }
    static var attention: Color { color(.attention) }
    static var failure: Color { color(.failure) }

    /// Wash opacities, as numbers so the tests can composite them. Both are sized so every ink holds
    /// 4.5:1 over a white window right behind the panel (`worstCaseBackdropRGB`); the old 0.60 and 0.40
    /// left the secondary ink near 3.4:1 and the failure ink under 3:1 there.
    static let darkGlassDimAlpha = 0.80
    static let dockDimAlpha = 0.75
    /// The dock slab's own tint on its clear glass. Not counted in the contrast checks: it is applied
    /// inside the glass, not as a plain overlay, so it is margin on top of the wash.
    static let dockGlassTintAlpha = 0.15

    /// The wash laid beneath `.clear` glass for the Dark glass style: thick enough that the ink
    /// reads over any window, thin enough that it is not the solid style.
    static let darkGlassDim = Color.black.opacity(darkGlassDimAlpha)
    static let dockGlassTint = Color.black.opacity(dockGlassTintAlpha)
    /// The wash under the dock slab, lighter than Dark glass because the slab's tint adds to it.
    static let dockDim = Color.black.opacity(dockDimAlpha)

    /// What a backdrop looks like through a black wash of `alpha` (sRGB compositing, as the window
    /// server does it).
    static func washed(over backdrop: RGB, alpha: Double) -> RGB {
        (backdrop.r * (1 - alpha), backdrop.g * (1 - alpha), backdrop.b * (1 - alpha))
    }

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
