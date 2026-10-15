import Foundation

/// Makes text that an agent, a gateway or a remote user controls safe to put
/// in a banner, a label or an accessibility string. Category-based, not a
/// denylist: NFC-normalizes, drops every scalar in the control (Cc), format
/// (Cf), private-use (Co), unassigned (Cn), line-separator (Zl) and
/// paragraph-separator (Zp) categories, collapses whitespace (newlines, tabs,
/// U+2028/2029, no-break and other spaces) to one space, caps combining marks
/// at two per base scalar, and caps the length by grapheme clusters with an
/// ellipsis. The one Cf scalar kept is the zero-width joiner, and only
/// between two pictographs (emoji sequences), at most `maxJoinersPerSequence`
/// in a row (a joined sequence is one grapheme, so without this cap a chain of
/// joined pictographs would defeat the grapheme cap). Scanning stops once far
/// more than the cap has been kept, so a huge input costs a bounded amount of
/// work; the result then ends with the ellipsis. Show the result with
/// `Text(verbatim:)` or a `String`-typed `Text`, never as a `LocalizedStringKey`,
/// Markdown or a link. Shared by the notifications, the notch and Quick Ask.
enum MacUntrustedText {
    static let ellipsis = "\u{2026}"
    static let maxCombiningMarks = 2
    static let maxJoinersPerSequence = 4
    /// Upper bound on scalars one grapheme can keep (base, marks, joined pictographs with their marks).
    private static let scalarsPerGraphemeBound = 32

    static func sanitize(_ text: String, maxGraphemes: Int) -> String {
        guard maxGraphemes > 0 else { return "" }
        let keepBound = maxGraphemes * scalarsPerGraphemeBound + 64
        // Bound the work before normalising: a hostile input can be megabytes. Anything
        // past the prefix is cut, and a cut input always ends in the ellipsis.
        let rawLimit = keepBound * 4
        var clipped = text.unicodeScalars.dropFirst(rawLimit).isEmpty == false
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: text.unicodeScalars.prefix(rawLimit))
        let scalars = Array(String(prefix).precomposedStringWithCanonicalMapping.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var lastKept: Unicode.Scalar?
        var marks = 0
        var joiners = 0
        var pendingSpace = false
        var keptCount = 0

        for (index, scalar) in scalars.enumerated() {
            if keptCount > keepBound { clipped = true; break }
            if scalar.properties.isWhitespace {
                pendingSpace = lastKept != nil
                continue
            }
            if scalar.value == 0x200D {
                // Keep a joiner only inside an emoji sequence: pictograph, joiner, pictograph.
                guard !pendingSpace, joiners < maxJoinersPerSequence, let previous = lastKept, isPictographLike(previous),
                      index + 1 < scalars.count, isPictographLike(scalars[index + 1]) else { continue }
                kept.append(scalar)
                keptCount += 1
                lastKept = scalar
                marks = 0
                joiners += 1
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                continue
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                if marks > maxCombiningMarks { continue }
            default:
                marks = 0
                // A scalar that does not continue a joined sequence ends it.
                if lastKept?.value != 0x200D && !scalar.properties.isEmojiModifier { joiners = 0 }
            }
            if pendingSpace { kept.append(" "); keptCount += 1; pendingSpace = false }
            kept.append(scalar)
            keptCount += 1
            lastKept = scalar
        }

        let characters = Array(String(kept))
        let limit = maxGraphemes
        guard clipped || characters.count > limit else { return String(characters) }
        return String(characters.prefix(limit - 1)) + ellipsis
    }

    private static func isPictographLike(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        return p.isEmojiPresentation || p.isEmojiModifier || scalar.value == 0xFE0F || (p.isEmoji && scalar.value > 0xFF)
    }
}
