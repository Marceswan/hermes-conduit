import AppKit
import SwiftUI

/// Mac ink for text in a chat step row that a system style leaves under 4.5:1 (Ruling R20).
/// `ChatStepRowContrastTests` measures these colours against the surfaces they sit on.
enum MacStepRowInk {
    /// For text that an NSTextView draws, which takes an `NSColor`. `NSColor.secondaryLabelColor` is
    /// 3.8:1 against the open tool box in light mode and 4.3:1 in dark.
    ///
    /// Black in light appearances and white in dark ones, at 72%: what `Color.primary.opacity(0.85)`
    /// resolves to for the SwiftUI text of the same rows. Explicitly dynamic, because
    /// `NSColor.labelColor.withAlphaComponent(_:)` kept one appearance in a static.
    static let nativeText = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 1 : 0, alpha: 0.72)
    }

    /// An error in the readable result of an open tool row. The system red is 2.7:1 (light) and
    /// 3.3:1 (dark) on the open box: a deeper red in light appearances, a lighter one in dark.
    static let error = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(red: 1, green: 0.55, blue: 0.5, alpha: 1) : NSColor(red: 0.7, green: 0.05, blue: 0.05, alpha: 1)
    }

    static let errorColor = Color(nsColor: error)

    /// The title of a link in the readable result of an open tool row, in the saved accent. The accent
    /// is 3.7:1 (amber, light) on the open box, and some dark-mode accents are under 4.5:1 too, so it
    /// is deepened in light appearances and lightened in dark ones.
    static let linkTitle = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var accent = NSColor.conduitAccent
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor.conduitAccent.usingColorSpace(.sRGB) ?? NSColor.conduitAccent
        }
        return linkTitleInk(accent: accent, dark: dark)
    }

    static let linkTitleColor = Color(nsColor: linkTitle)

    /// `accent` (the accent as drawn in that appearance) moved 25% toward black in light appearances,
    /// 35% toward white in dark ones. Held apart so a test can run every accent choice through it.
    static func linkTitleInk(accent: NSColor, dark: Bool) -> NSColor {
        let rgb = accent.usingColorSpace(.sRGB) ?? accent
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        if dark {
            let toward: CGFloat = 0.35
            return NSColor(red: red + (1 - red) * toward, green: green + (1 - green) * toward,
                           blue: blue + (1 - blue) * toward, alpha: 1)
        }
        let keep: CGFloat = 0.75
        return NSColor(red: red * keep, green: green * keep, blue: blue * keep, alpha: 1)
    }
}
