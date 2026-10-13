import AppKit
import SwiftUI

public extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var link: NSColor { .linkColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}

public extension NSFont {
    /// UIFont.lineHeight: ascender to descender plus leading.
    var lineHeight: CGFloat { ceil(ascender - descender + leading) }
}

public enum UIUserInterfaceStyle: Int, Sendable {
    case unspecified, light, dark
}

/// A value carrying only the appearance, which is all dynamic colors read.
public struct UITraitCollection: Sendable {
    public let userInterfaceStyle: UIUserInterfaceStyle
    public let preferredContentSizeCategory: UIContentSizeCategory

    public init(
        userInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        preferredContentSizeCategory: UIContentSizeCategory = .large
    ) {
        self.userInterfaceStyle = userInterfaceStyle
        self.preferredContentSizeCategory = preferredContentSizeCategory
    }

    public init(preferredContentSizeCategory: UIContentSizeCategory) {
        self.init(userInterfaceStyle: .unspecified, preferredContentSizeCategory: preferredContentSizeCategory)
    }
}

public extension NSFont {
    /// Macs have no Dynamic Type; the traits do not change the size.
    static func preferredFont(forTextStyle style: NSFont.TextStyle, compatibleWith traits: UITraitCollection?) -> NSFont {
        preferredFont(forTextStyle: style)
    }
}

/// UIFontDescriptor.SymbolicTraits names that upstream's attributed-text
/// bridge uses.
public typealias UIFontDescriptor = NSFontDescriptor

public extension NSFontDescriptor.SymbolicTraits {
    static let traitBold = NSFontDescriptor.SymbolicTraits.bold
    static let traitItalic = NSFontDescriptor.SymbolicTraits.italic
}

public extension NSColor {
    /// UIColor(dynamicProvider:): resolves per appearance.
    convenience init(dynamicProvider: @escaping (UITraitCollection) -> NSColor) {
        self.init(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dynamicProvider(UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
        })
    }
}

public extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}
