import Foundation

/// Display sanitizer for every string the gateway or the agent controls and the
/// notch renders (titles, tool names, descriptions, commands, error text).
///
/// A hostile or confused agent can put text in a session title or a command that
/// reorders what the user reads (bidi overrides and isolates), hides characters
/// (zero-width and other format characters) or fakes a second line (newlines). The
/// notch is a small, glanceable approval surface, so the displayed text must be what
/// is there: control and format characters are removed, whitespace runs become one
/// space, and anything longer than the limit ends in a visible ellipsis.
///
/// Render the result with `Text(verbatim:)` so it is never read as Markdown or a link.
enum NotchText {
    struct Result: Equatable {
        var text: String
        /// The visible text is shorter than the input (cut at the limit).
        var truncated: Bool
        /// Control or invisible format characters were dropped, so the visible text is
        /// not a faithful copy of the input (whitespace collapsing does not count).
        var stripped: Bool
    }

    static let ellipsis = "\u{2026}"

    static func sanitize(_ raw: String, limit: Int) -> Result {
        // Bound the work on a very long input: keep a generous prefix, remember that we cut.
        let scanLimit = max(limit, 1) * 8
        var cutInput = false
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var stripped = false
        var scanned = 0
        for scalar in raw.unicodeScalars {
            scanned += 1
            if scanned > scanLimit { cutInput = true; break }
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                stripped = true
                continue
            default:
                break
            }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        let text = String(out)
        guard text.count > limit || cutInput else {
            return Result(text: text, truncated: false, stripped: stripped)
        }
        let kept = String(text.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces)
        return Result(text: kept + ellipsis, truncated: true, stripped: stripped)
    }

    static func clean(_ raw: String, limit: Int) -> String {
        sanitize(raw, limit: limit).text
    }
}
