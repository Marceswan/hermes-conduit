import Foundation

/// Display sanitizer for short strings the gateway or the agent controls and a
/// Mac surface shows outside the chat transcript (status lines, tool names, error
/// text, profile names in messages). The reply body is not run through this: it
/// renders as Markdown, like the main chat.
///
/// Rules, by Unicode scalar:
/// - Zl and Zp (U+2028, U+2029) are dropped.
/// - Cf is dropped. That covers every bidi control and isolate, LRM, RLM, ALM,
///   zero-width characters, the BOM, the soft hyphen and tag characters.
/// - Tab, newline and other whitespace controls, and every space separator (Zs),
///   become one space; runs of spaces collapse and the ends are trimmed.
/// - Every other Cc is dropped.
/// - The result is cut at `maxGraphemes` characters and a cut string ends in an ellipsis.
///
/// Show the result with `Text(verbatim:)` or a `String`-typed `Text`, never as a
/// `LocalizedStringKey`, Markdown or a link.
enum MacUntrustedText {
    static let ellipsis = "\u{2026}"

    static func sanitize(_ raw: String, maxGraphemes: Int) -> String {
        guard maxGraphemes > 0 else { return "" }
        // Bound the work on a very long input: a generous prefix is plenty to fill the cap.
        let scanLimit = maxGraphemes * 8 + 16
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars.prefix(scanLimit) {
            let category = scalar.properties.generalCategory
            switch category {
            case .lineSeparator, .paragraphSeparator, .format:
                continue
            case .spaceSeparator:
                pendingSpace = true
            case .control:
                if scalar.properties.isWhitespace { pendingSpace = true }
            default:
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            }
        }
        let text = String(out)
        guard text.count > maxGraphemes else { return text }
        let kept = String(text.prefix(max(maxGraphemes - 1, 0))).trimmingCharacters(in: .whitespaces)
        return kept + ellipsis
    }
}
