import AppKit
import SwiftUI

/// Mac ink for text in a chat step row that a system style leaves under 4.5:1 (Ruling R20, R43, R44).
/// `ChatStepRowContrastTests` measures these inks against the surfaces they sit on. The `#if os(macOS)
/// // MAC:` regions of the step rows, the tool result and the working line name them, so one value
/// changes in one place.
enum MacStepRowInk {
    // MARK: SwiftUI text and glyphs

    /// The share of the label colour that text keeps: `.secondary` and `.conduitTertiary` are 3.1:1 or
    /// lower on the light card and the open box, and the accent is lower still.
    private static let textOpacity = 0.85
    /// `Color.primary` is the label colour, which is black or white at this alpha.
    private static let labelAlpha = 0.85

    /// Text in place of `.secondary` and `.conduitTertiary`: 6.8:1 on the light card, 6.6:1 on the
    /// open box (rendered, light).
    static let text = Color.primary.opacity(textOpacity)

    /// Chevrons: a glyph needs 3:1.
    static let glyph = Color.primary.opacity(0.6)

    /// Text of a finished or cancelled task, dimmer than an open task. The lowest share, in steps of
    /// 0.05, that holds 4.5:1 on the open box in both appearances (rendered): 0.75 reads 4.74:1 in
    /// light, 0.70 reads 4.14:1.
    static let dimText = Color.primary.opacity(0.75)

    // MARK: NSColor text (NSTextView)

    /// For text that an NSTextView draws, which takes an `NSColor`: the same ink as `text`.
    /// `NSColor.secondaryLabelColor` is 3.8:1 against the open tool box in light mode and 4.3:1 in dark.
    /// Explicitly dynamic, because `NSColor.labelColor.withAlphaComponent(_:)` kept one appearance in
    /// a static.
    static let nativeText = dynamic(light: NSColor(white: 0, alpha: labelAlpha * textOpacity),
                                    dark: NSColor(white: 1, alpha: labelAlpha * textOpacity))

    /// The file and hunk header lines of a diff, dimmer than its context lines (`.tertiaryLabel` is
    /// 2:1 on the open box).
    static let diffHeader = dynamic(light: NSColor(white: 0, alpha: 0.62), dark: NSColor(white: 1, alpha: 0.62))

    /// An added line: a deeper green in light appearances (the system green is 3.1:1 on the open box),
    /// the lighter green of dark ones.
    static let diffAdded = dynamic(light: NSColor(red: 0.05, green: 0.42, blue: 0.14, alpha: 1),
                                   dark: NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1))

    /// A removed line: the same red as an error.
    static let diffRemoved = error

    // MARK: Red

    /// An error in the readable result of an open tool row. The system red is 2.7:1 (light) and
    /// 3.3:1 (dark) on the open box: a deeper red in light appearances, a lighter one in dark.
    static let error = dynamic(light: NSColor(red: 0.7, green: 0.05, blue: 0.05, alpha: 1),
                               dark: NSColor(red: 1, green: 0.62, blue: 0.57, alpha: 1))

    static let errorColor = Color(nsColor: error)

    // MARK: The accent as text

    /// The saved accent as text: a link title in a tool result, the running title of a tool row, the
    /// phrase of the working line. The accent is 3.7:1 (amber, light) on the open box, and some
    /// dark-mode accents are under 4.5:1 too. It moves only as far as it must (`accentInk`), so a pick
    /// that already reads keeps its colour.
    ///
    /// `choice` is the pick to draw: nil reads the saved one (`NSColor.conduitAccent`, which follows
    /// the Settings pick), a value stands for that pick, so a test can run the same provider path
    /// for each of the six.
    static func accentText(choice: ConduitAccentChoice? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let accent: NSColor
            if let choice {
                accent = choice.color(dark: dark)
            } else {
                var resolved = NSColor.conduitAccent
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor.conduitAccent.usingColorSpace(.sRGB) ?? NSColor.conduitAccent
                }
                accent = resolved
            }
            return accentInk(accent: accent, dark: dark)
        }
    }

    static let accentTextColor = Color(nsColor: accentText())

    /// What `accentInk` aims for, as contrast by colour value against the open box. The rendered reading
    /// of the test is lower in light (about 0.76 of this, so 6.2 gives about 4.7) and higher in dark.
    private static let accentTarget: (light: Double, dark: Double) = (6.2, 4.8)
    /// The open box (the 5% card fill and the 6% box fill over white, or over 0.12 gray) as the test
    /// samples it from a render, as relative luminance.
    private static let boxLuminance: (light: Double, dark: Double) = (0.84, 0.055)

    /// `accent` moved toward black (light) or white (dark), by the least amount that reaches
    /// `accentTarget` against the box; unchanged when it already does. Moving a colour toward black
    /// or white keeps its hue. Held apart so a test can run every pick through it.
    static func accentInk(accent: NSColor, dark: Bool) -> NSColor {
        let rgb = accent.usingColorSpace(.sRGB) ?? accent
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let end: CGFloat = dark ? 1 : 0
        let surface = dark ? boxLuminance.dark : boxLuminance.light
        let target = dark ? accentTarget.dark : accentTarget.light

        func moved(_ share: CGFloat) -> NSColor {
            NSColor(red: red + (end - red) * share, green: green + (end - green) * share,
                    blue: blue + (end - blue) * share, alpha: 1)
        }
        func contrast(_ color: NSColor) -> Double {
            let text = luminance(color)
            return (max(text, surface) + 0.05) / (min(text, surface) + 0.05)
        }

        if contrast(moved(0)) >= target { return moved(0) }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if contrast(moved(middle)) >= target { high = middle } else { low = middle }
        }
        return moved(high)
    }

    private static func luminance(_ color: NSColor) -> Double {
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    // MARK: Helper

    /// A colour that follows the appearance. Explicit, so that nothing is frozen in a static.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
