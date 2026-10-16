import SwiftUI

/// Home's tokens (D24). Cards are the only glass layer (D7); everything inside is flat.
enum MacHomeStyle {
    static let sectionGap: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = MacSidebarMetrics.sessionCardRadius
    static let tileMinWidth: CGFloat = 150
    static let wideCardMinWidth: CGFloat = 260
    static let rowHeight: CGFloat = MacControlHeight.compact

    // Charts: thin marks, 4 pt rounded data end on a square baseline, 2 pt gaps.
    static let maxBarThickness: CGFloat = 24
    static let chartHeight: CGFloat = 72
    static let barGap: CGFloat = 2
    static let topCornerRadius: CGFloat = 4
    static let meterHeight: CGFloat = 8

    /// System `.secondary` is below 4.5:1 on the window background (MacPaletteContrastTests).
    static let secondaryOpacity = 0.7
    /// Non-text marks need 3:1; pinned by MacHomeContrastTests.
    static let mutedMarkOpacity = 0.5
    static let trackOpacity = 0.12

    static var secondaryText: Color { Color.primary.opacity(secondaryOpacity) }
    static var mutedMark: Color { Color.primary.opacity(mutedMarkOpacity) }
    static var emphasisMark: Color { .conduitAccent }
    static var track: Color { Color.primary.opacity(trackOpacity) }
}
