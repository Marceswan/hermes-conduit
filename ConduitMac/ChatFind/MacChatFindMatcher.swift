import Foundation

/// One searchable message: its id and the plain text the transcript draws for it.
struct MacChatFindEntry: Equatable {
    let id: String
    let text: String
}

/// One hit. `ordinal` counts hits inside the message from 0 in reading order;
/// `range` is UTF-16, in the entry's projected text.
struct MacChatFindMatch: Equatable, Hashable {
    let messageID: String
    let ordinal: Int
    let range: NSRange
}

/// Pure search (D23): literal, case- and diacritic-insensitive, non-overlapping.
enum MacChatFindMatcher {
    static let defaultLimit = 5_000
    static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// An empty or whitespace-only query matches nothing. Anything else is used
    /// exactly as typed (inner and trailing spaces count).
    static func isSearchable(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func ranges(of query: String, in text: String, limit: Int = .max) -> [NSRange] {
        guard isSearchable(query), !text.isEmpty else { return [] }
        let haystack = text as NSString
        var found: [NSRange] = []
        var from = 0
        while from < haystack.length, found.count < limit {
            let hit = haystack.range(
                of: query,
                options: options,
                range: NSRange(location: from, length: haystack.length - from)
            )
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            found.append(hit)
            from = hit.location + hit.length
        }
        return found
    }

    /// Hits over all entries in entry order. `truncated` is true only when at
    /// least one hit beyond `limit` exists.
    static func matches(
        of query: String,
        in entries: [MacChatFindEntry],
        limit: Int = defaultLimit
    ) -> (matches: [MacChatFindMatch], truncated: Bool) {
        guard isSearchable(query) else { return ([], false) }
        var all: [MacChatFindMatch] = []
        for entry in entries {
            let room = limit - all.count
            let found = ranges(of: query, in: entry.text, limit: room + 1)
            for (ordinal, range) in found.prefix(room).enumerated() {
                all.append(MacChatFindMatch(messageID: entry.id, ordinal: ordinal, range: range))
            }
            if found.count > room { return (all, true) }
        }
        return (all, false)
    }
}
