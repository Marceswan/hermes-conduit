import Foundation

/// Makes text that an agent, a gateway or a remote user controls safe to put
/// in a banner, a label or an accessibility string. Category-based, not a
/// denylist: NFC-normalizes, drops every scalar in the control (Cc), format
/// (Cf), private-use (Co), unassigned (Cn), line-separator (Zl) and
/// paragraph-separator (Zp) categories, collapses whitespace (newlines, tabs,
/// U+2028/2029, no-break and other spaces) to one space, caps combining marks
/// at two per base scalar, and caps the length by grapheme clusters with an
/// ellipsis. The one Cf scalar kept is the zero-width joiner, and only
/// between two pictographs (emoji sequences).
enum MacUntrustedText {
    static let ellipsis = "\u{2026}"
    static let maxCombiningMarks = 2

    static func sanitize(_ text: String, maxGraphemes: Int) -> String {
        let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var lastKept: Unicode.Scalar?
        var marks = 0
        var pendingSpace = false

        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isWhitespace {
                pendingSpace = lastKept != nil
                continue
            }
            if scalar.value == 0x200D {
                // Keep a joiner only inside an emoji sequence: pictograph, joiner, pictograph.
                guard !pendingSpace, let previous = lastKept, isPictographLike(previous),
                      index + 1 < scalars.count, isPictographLike(scalars[index + 1]) else { continue }
                kept.append(scalar)
                lastKept = scalar
                marks = 0
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
            }
            if pendingSpace { kept.append(" "); pendingSpace = false }
            kept.append(scalar)
            lastKept = scalar
        }

        let characters = Array(String(kept))
        let limit = max(1, maxGraphemes)
        guard characters.count > limit else { return String(characters) }
        return String(characters.prefix(limit - 1)) + ellipsis
    }

    private static func isPictographLike(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        return p.isEmojiPresentation || p.isEmojiModifier || scalar.value == 0xFE0F || (p.isEmoji && scalar.value > 0xFF)
    }
}
