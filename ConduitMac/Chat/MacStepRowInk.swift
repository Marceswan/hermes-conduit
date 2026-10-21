import AppKit

/// Mac ink for text that an NSTextView draws inside a chat step row. SwiftUI text in those rows is
/// recoloured at its call site, but a `SelectableTextView` takes an `NSColor`.
///
/// `NSColor.secondaryLabelColor` is 3.8:1 against the open tool box in light mode and 4.3:1 in dark
/// (Ruling R20 asks for 4.5:1). `ChatStepRowContrastTests` measures this colour against those surfaces.
enum MacStepRowInk {
    /// Black in light appearances and white in dark ones, at 72%: what `Color.primary.opacity(0.85)`
    /// resolves to for the SwiftUI text of the same rows. Explicitly dynamic, because
    /// `NSColor.labelColor.withAlphaComponent(_:)` kept one appearance in a static.
    static let nativeText = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 1 : 0, alpha: 0.72)
    }
}
