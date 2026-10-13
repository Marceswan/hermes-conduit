import AppKit

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
