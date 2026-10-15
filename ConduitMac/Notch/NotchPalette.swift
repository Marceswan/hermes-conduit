import SwiftUI

enum NotchPalette {
    typealias RGB = (r: Double, g: Double, b: Double)
    static let surfaceRGB: RGB = (0, 0, 0)               // black blends into the notch; same in light and dark
    static let textRGB: RGB = (1, 1, 1)
    static let secondaryRGB: RGB = (0.78, 0.78, 0.80)
    static let attentionRGB: RGB = (1.0, 0.78, 0.20)
    static let failureRGB: RGB = (1.0, 0.45, 0.42)

    static func color(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
    static var surface: Color { color(surfaceRGB) }
    static var text: Color { color(textRGB) }
    static var secondary: Color { color(secondaryRGB) }
    static var attention: Color { color(attentionRGB) }
    static var failure: Color { color(failureRGB) }

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
