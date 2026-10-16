import Foundation

/// The matches of the current query and which one is selected (D23). Pure.
struct MacChatFindState: Equatable {
    private(set) var matches: [MacChatFindMatch] = []
    private(set) var currentIndex: Int?
    private(set) var isTruncated = false

    /// Which hit to select after the matches are replaced. `order` maps a
    /// message id to its position in the transcript.
    enum Anchor: Equatable {
        /// A fresh query: the newest hit (the transcript is read from the bottom).
        case newest
        /// A refresh: the same message and ordinal if it still matches, else the nearest.
        case keeping(MacChatFindMatch, order: [String: Int])
        /// The query changed: the first hit at or below this message, else the newest.
        case near(messageID: String, order: [String: Int])
    }

    var count: Int { matches.count }
    var current: MacChatFindMatch? { currentIndex.map { matches[$0] } }
    /// 1-based, for "3 of 12".
    var position: Int? { currentIndex.map { $0 + 1 } }

    mutating func replace(matches: [MacChatFindMatch], truncated: Bool, anchor: Anchor) {
        self.matches = matches
        isTruncated = truncated
        guard !matches.isEmpty else {
            currentIndex = nil
            return
        }
        switch anchor {
        case .newest:
            currentIndex = matches.count - 1
        case .keeping(let old, let order):
            if let same = matches.firstIndex(where: { $0.messageID == old.messageID && $0.ordinal == old.ordinal }) {
                currentIndex = same
            } else {
                currentIndex = Self.nearest(to: old.messageID, in: matches, order: order)
            }
        case .near(let messageID, let order):
            currentIndex = Self.nearest(to: messageID, in: matches, order: order)
        }
    }

    mutating func next() {
        guard let index = currentIndex, !matches.isEmpty else { return }
        currentIndex = (index + 1) % matches.count
    }

    mutating func previous() {
        guard let index = currentIndex, !matches.isEmpty else { return }
        currentIndex = (index - 1 + matches.count) % matches.count
    }

    private static func nearest(to messageID: String, in matches: [MacChatFindMatch], order: [String: Int]) -> Int {
        guard let anchor = order[messageID] else { return matches.count - 1 }
        return matches.firstIndex { (order[$0.messageID] ?? Int.max) >= anchor } ?? matches.count - 1
    }
}

/// The text next to the bar's chevrons.
enum MacChatFindLabel {
    static func text(query: String, state: MacChatFindState) -> String {
        guard MacChatFindMatcher.isSearchable(query) else { return "" }
        guard let position = state.position else { return AppLocalization.string("No matches") }
        if state.isTruncated {
            return String(format: AppLocalization.string("%d of %d+"), position, state.count)
        }
        return String(format: AppLocalization.string("%d of %d"), position, state.count)
    }
}
