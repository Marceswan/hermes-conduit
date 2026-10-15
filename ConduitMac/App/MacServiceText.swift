import Foundation

/// Cleans text handed over by another app or a Shortcut (D19): plain, trimmed,
/// capped. Shared by the Services provider and the New Conduit Chat intent.
enum MacServiceText {
    static let limit = 20_000
    static let truncationNote = "[truncated]"

    static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n" + truncationNote
    }
}
