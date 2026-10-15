import Foundation

/// Display sanitizer for text the agent, the gateway or a chat controls and a Mac surface
/// shows outside the chat transcript: status lines, session titles, commands, descriptions,
/// tool names, error text, reply previews. Shared by the notch, Quick Ask and notifications.
/// The reply body in the chat renders as Markdown like the main chat and is not run through this.
///
/// A hostile or confused agent can put text in a title or a command that reorders what
/// the user reads (bidi controls), hides characters (zero-width and other format
/// characters, tag characters), fakes a second line (newlines, U+2028) or buries a
/// glyph under a stack of combining marks. The rules, by Unicode scalar:
///
/// - NFC-normalize first.
/// - Drop general categories Cc, Cf, Co, Cn, Zl and Zp (bidi controls and isolates, LRM,
///   RLM, ALM, zero-width characters, BOM, soft hyphen, tag characters E0000-E007F,
///   private use, unassigned, U+2028 and U+2029).
/// - Keep ZWJ (U+200D) only between two emoji, so emoji sequences survive.
/// - Tabs, newlines and every space separator (Zs) become one space; runs collapse and the
///   ends are trimmed.
/// - At most two combining marks (Mn, Me) follow a base scalar.
/// - Cap the length by grapheme count and end a cut string with a visible ellipsis.
///
/// Show the result with `Text(verbatim:)` or a `String`-typed `Text`, never as a
/// `LocalizedStringKey`, Markdown or a link.
enum MacUntrustedText {
    /// What `sanitizeReport` found, for callers that must not trust a changed string
    /// (the notch will not offer Allow on a command it did not show faithfully).
    struct Report: Equatable {
        var text: String
        /// The visible text is shorter than the input (cut at the cap).
        var truncated: Bool
        /// Control, invisible or excess combining characters were dropped, so the text is
        /// not a faithful copy of the input (whitespace collapsing does not count).
        var changed: Bool
    }

    static let ellipsis = "\u{2026}"
    static let maxCombiningMarks = 2
    private static let zwj: Unicode.Scalar = "\u{200D}"

    static func sanitize(_ raw: String, maxGraphemes: Int) -> String {
        sanitizeReport(raw, maxGraphemes: maxGraphemes).text
    }

    static func sanitizeReport(_ raw: String, maxGraphemes: Int) -> Report {
        guard maxGraphemes > 0 else { return Report(text: "", truncated: !raw.isEmpty, changed: false) }
        // Bound the work on a very long input: keep a generous prefix, remember that we cut.
        let scanLimit = maxGraphemes * 8 + 16
        var cutInput = false
        var prefix = String.UnicodeScalarView()
        var taken = 0
        for scalar in raw.unicodeScalars {
            if taken >= scanLimit { cutInput = true; break }
            prefix.append(scalar)
            taken += 1
        }
        let scalars = Array(String(prefix).precomposedStringWithCanonicalMapping.unicodeScalars)

        var out = String.UnicodeScalarView()
        var changed = false
        var pendingSpace = false
        var marks = 0
        var previousIsEmoji = false     // the last kept scalar can start a ZWJ sequence

        for (index, scalar) in scalars.enumerated() {
            let category = scalar.properties.generalCategory
            // Line and paragraph separators are dropped (not turned into a space).
            if category == .lineSeparator || category == .paragraphSeparator { changed = true; continue }

            if scalar == zwj {
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                if previousIsEmoji, let next, isEmoji(next) {
                    out.append(scalar)
                    previousIsEmoji = false      // the next emoji restarts the check
                    marks = 0
                } else {
                    changed = true
                }
                continue
            }

            // Tabs, newlines and space separators collapse to one space.
            if scalar.properties.isWhitespace {
                pendingSpace = true
                previousIsEmoji = false
                marks = 0
                continue
            }

            switch category {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                changed = true
                continue
            case .nonspacingMark, .enclosingMark:
                marks += 1
                if marks > maxCombiningMarks { changed = true; continue }
            default:
                marks = 0
            }

            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
            // A combining mark (variation selector 16, keycap) keeps the state of the scalar it follows.
            if category != .nonspacingMark && category != .enclosingMark {
                previousIsEmoji = isEmoji(scalar)
            }
        }

        let text = String(out)
        guard text.count > maxGraphemes || cutInput else {
            return Report(text: text, truncated: false, changed: changed)
        }
        let kept = String(text.prefix(max(maxGraphemes - 1, 0))).trimmingCharacters(in: .whitespaces)
        return Report(text: kept + ellipsis, truncated: true, changed: changed)
    }

    /// A pictographic scalar. ASCII digits, `#` and `*` carry the Emoji property but are not
    /// emoji on their own, so only scalars above ASCII count.
    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x7F && scalar.properties.isEmoji
    }
}
