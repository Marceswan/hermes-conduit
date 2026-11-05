import Foundation

/// Pure scoring and ranking for the command palette (D18). No AppKit, no AppState.
enum MacPaletteMatcher {
    static let rowLimit = 50
    static let fuzzyMinimumLength = 3

    /// Highest first. Tier values are 1000 apart so no bonus crosses a tier.
    enum Tier: Int {
        case keyword = 1, fuzzy, substring, wordStart, prefix, exact
    }

    struct Match: Equatable {
        let tier: Tier
        /// Within-tier detail, always below 1000.
        let detail: Int
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func tokens(of query: String) -> [String] {
        normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Slash titles match without their leading "/".
    static func matchTitle(of item: MacPaletteItem) -> String {
        normalize(item.title.hasPrefix("/") ? String(item.title.dropFirst()) : item.title)
    }

    static func recencyBoost(rank: Int?) -> Int {
        guard let rank else { return 0 }
        return max(0, 60 - 6 * rank)
    }

    private static func kindWeight(_ kind: MacPaletteKind) -> Int {
        switch kind {
        case .command, .model: return 30
        case .slash, .pane: return 20
        case .profile: return 10
        case .session: return 0
        }
    }

    private static func activityBoost(_ item: MacPaletteItem, now: Date) -> Int {
        guard item.kind == .session, !item.isActiveSession else { return 0 }
        var boost = item.isUnread ? 10 : 0
        if let last = item.lastActivityAt, now.timeIntervalSince1970 - last <= 86_400 { boost += 5 }
        return boost
    }

    fileprivate static func words(of text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Greedy in-order subsequence. Returns the number of skipped characters
    /// between the first and last matched one, nil when not a subsequence.
    private static func fuzzyGaps(_ query: String, in title: String) -> Int? {
        var needle = query.makeIterator()
        guard var wanted = needle.next() else { return nil }
        var first: Int?, last = 0
        for (offset, character) in title.enumerated() where character == wanted {
            if first == nil { first = offset }
            last = offset
            guard let next = needle.next() else { return last - (first ?? 0) + 1 - query.count }
            wanted = next
        }
        return nil
    }

    /// An item with its match text folded once. The store builds the index when
    /// the palette opens and reuses it for every keystroke, so a query costs
    /// string comparisons only (no per-keystroke diacritic folding or word
    /// splitting over 1,000+ sessions).
    struct Entry {
        let item: MacPaletteItem
        let title: String
        let titleWords: [String]
        let keywords: String

        init(_ item: MacPaletteItem) {
            self.item = item
            title = MacPaletteMatcher.matchTitle(of: item)
            titleWords = MacPaletteMatcher.words(of: title)
            keywords = MacPaletteMatcher.normalize(item.keywords.joined(separator: " "))
        }
    }

    static func index(_ items: [MacPaletteItem]) -> [Entry] { items.map(Entry.init) }

    static func match(tokens: [String], item: MacPaletteItem) -> Match? {
        match(tokens: tokens, entry: Entry(item))
    }

    static func match(tokens: [String], entry: Entry) -> Match? {
        guard !tokens.isEmpty else { return nil }
        let title = entry.title
        let joined = tokens.count == 1 ? tokens[0] : tokens.joined(separator: " ")
        if title == joined { return Match(tier: .exact, detail: 0) }
        if title.hasPrefix(joined) { return Match(tier: .prefix, detail: 0) }
        if tokens.allSatisfy({ token in entry.titleWords.contains { $0.hasPrefix(token) } }) {
            return Match(tier: .wordStart, detail: 0)
        }
        if tokens.allSatisfy({ title.contains($0) }) {
            let position = title.range(of: tokens[0]).map { title.distance(from: title.startIndex, to: $0.lowerBound) } ?? 0
            return Match(tier: .substring, detail: max(0, 100 - position))
        }
        if tokens.count == 1, tokens[0].count >= fuzzyMinimumLength, let gaps = fuzzyGaps(tokens[0], in: title) {
            return Match(tier: .fuzzy, detail: max(0, 150 - gaps * 10))
        }
        if !entry.keywords.isEmpty, tokens.allSatisfy({ entry.keywords.contains($0) }) {
            return Match(tier: .keyword, detail: 0)
        }
        return nil
    }

    /// Matching items, best first, at most `rowLimit`. An empty query ranks
    /// nothing (the provider builds the empty-query sections).
    /// `recentIDs` is most recent first and already limited to existing items.
    static func rank(_ items: [MacPaletteItem], query: String, recentIDs: [String], now: Date) -> [MacPaletteItem] {
        rank(index: index(items), query: query, recentIDs: recentIDs, now: now)
    }

    static func rank(index: [Entry], query: String, recentIDs: [String], now: Date) -> [MacPaletteItem] {
        let tokens = tokens(of: query)
        guard !tokens.isEmpty else { return [] }
        let recentRank = Dictionary(recentIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        struct Scored { let item: MacPaletteItem; let tier: Int; let score: Int; let recent: Int }
        var scored: [Scored] = []
        scored.reserveCapacity(min(index.count, 256))
        for entry in index {
            let item = entry.item
            guard let match = match(tokens: tokens, entry: entry) else { continue }
            let rank = recentRank[item.id]
            let score = match.tier.rawValue * 1000 + match.detail + kindWeight(item.kind)
                + recencyBoost(rank: rank) + activityBoost(item, now: now)
            scored.append(Scored(item: item, tier: match.tier.rawValue, score: score, recent: rank ?? Int.max))
        }
        scored.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.item.isEnabled != b.item.isEnabled { return a.item.isEnabled }
            if a.score != b.score { return a.score > b.score }
            if a.recent != b.recent { return a.recent < b.recent }
            if a.item.title != b.item.title { return a.item.title < b.item.title }
            return a.item.id < b.item.id
        }
        return scored.prefix(rowLimit).map(\.item)
    }
}
