import Foundation

/// Cleans text handed over by another app or a Shortcut (D19): plain, trimmed,
/// capped. Shared by the Services provider and the New Conduit Chat intent.
enum MacServiceText {
    static let limit = 20_000
    static let truncationNote = "[truncated]"

    static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        // Walk at most `limit` characters: a multi-megabyte selection must not
        // cost a full grapheme count on the main thread.
        guard let cut = trimmed.index(trimmed.startIndex, offsetBy: limit, limitedBy: trimmed.endIndex),
              cut != trimmed.endIndex else { return trimmed }
        return String(trimmed[..<cut]) + "\n" + truncationNote
    }
}
