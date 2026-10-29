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
///
/// `sanitizeReport` returns the same text plus two flags for callers that must not
/// trust a rewritten string (the notch offers inline Allow only on a command that
/// is shown complete and unchanged).
enum MacUntrustedText {
    struct Report: Equatable {
        var text: String
        /// The visible text is shorter than the input (cut at the cap or the scan bound).
        var truncated: Bool
        /// Scalars were dropped (control, format, private-use, unassigned, excess
        /// combining marks, a stray joiner) or an interior line break was flattened, so
        /// the text is not a faithful copy of the input. Collapsing spaces and tabs,
        /// trimming the ends and NFC composition do not count.
        var changed: Bool
    }

    static let ellipsis = "\u{2026}"
    static let maxCombiningMarks = 2
    static let maxJoinersPerSequence = 4
    /// Upper bound on scalars one grapheme can keep (base, marks, joined pictographs with their marks).
    private static let scalarsPerGraphemeBound = 32

    static func sanitize(_ text: String, maxGraphemes: Int) -> String {
        sanitizeReport(text, maxGraphemes: maxGraphemes).text
    }

    static func sanitizeReport(_ text: String, maxGraphemes: Int) -> Report {
        guard maxGraphemes > 0 else { return Report(text: "", truncated: !text.isEmpty, changed: false) }
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
        var pendingBreak = false
        var changed = false
        var keptCount = 0

        for (index, scalar) in scalars.enumerated() {
            if keptCount > keepBound { clipped = true; break }
            if scalar.properties.isWhitespace {
                pendingSpace = lastKept != nil
                if pendingSpace, isLineBreak(scalar) { pendingBreak = true }
                continue
            }
            if scalar.value == 0x200D {
                // Keep a joiner only inside an emoji sequence: pictograph, joiner, pictograph.
                guard !pendingSpace, joiners < maxJoinersPerSequence, let previous = lastKept, isPictographLike(previous),
                      index + 1 < scalars.count, isPictographLike(scalars[index + 1]) else { changed = true; continue }
                kept.append(scalar)
                keptCount += 1
                lastKept = scalar
                marks = 0
                joiners += 1
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                changed = true
                continue
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                if marks > maxCombiningMarks { changed = true; continue }
            default:
                marks = 0
                // A scalar that does not continue a joined sequence ends it.
                if lastKept?.value != 0x200D && !scalar.properties.isEmojiModifier { joiners = 0 }
            }
            if pendingSpace {
                kept.append(" "); keptCount += 1; pendingSpace = false
                // A line break inside the text is shown as a space: not what the sender wrote.
                if pendingBreak { changed = true; pendingBreak = false }
            }
            kept.append(scalar)
            keptCount += 1
            lastKept = scalar
        }

        let characters = Array(String(kept))
        let limit = maxGraphemes
        guard clipped || characters.count > limit else {
            return Report(text: String(characters), truncated: false, changed: changed)
        }
        let head = String(characters.prefix(limit - 1)).trimmingCharacters(in: .whitespaces)
        return Report(text: head + ellipsis, truncated: true, changed: changed)
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private static func isPictographLike(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        return p.isEmojiPresentation || p.isEmojiModifier || scalar.value == 0xFE0F || (p.isEmoji && scalar.value > 0xFF)
    }
}
