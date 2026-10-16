import Foundation

/// One session tab (D11). `title` is the last known title, shown while the
/// session is outside the loaded catalog.
struct MacSessionTab: Codable, Equatable {
    var id: String
    var title: String
    var unavailable = false
}

/// The Mac session tab strip's state (D11): pure, no AppKit, no AppState.
struct MacSessionTabsModel: Codable, Equatable {
    static let closedLimit = 10

    enum Direction { case previous, next }

    enum CloseResult: Equatable {
        case notFound
        case closedInactive
        /// The active tab closed; this neighbour is now active and must be opened.
        case activate(String)
        /// The only tab closed.
        case closedLast
    }

    struct ClosedTab: Equatable {
        let tab: MacSessionTab
        let index: Int
    }

    private(set) var tabs: [MacSessionTab] = []
    private(set) var activeID: String?
    /// Most recent first. Not persisted.
    private(set) var closed: [ClosedTab] = []

    private enum CodingKeys: String, CodingKey { case tabs, activeID }

    func index(of id: String) -> Int? { tabs.firstIndex { $0.id == id } }

    /// Opening a session selects its tab, adding it at the end when missing.
    /// `aliases` are the session's other ids (runtime, stored, alternate): a
    /// tab under any of them becomes this tab, so one session has one tab.
    mutating func open(_ id: String, title: String, aliases: [String] = []) {
        let others = Set(aliases).subtracting([id])
        if !others.isEmpty {
            let ids = others.union([id])
            if let first = tabs.firstIndex(where: { ids.contains($0.id) }) {
                tabs[first].id = id
                tabs = tabs.enumerated().filter { $0.offset == first || !ids.contains($0.element.id) }.map(\.element)
            }
            closed.removeAll { others.contains($0.tab.id) }
        }
        if let index = index(of: id) {
            tabs[index].title = title
            tabs[index].unavailable = false
        } else {
            tabs.append(MacSessionTab(id: id, title: title))
        }
        activeID = id
    }

    /// No session is active (a room is open, or nothing is open yet).
    mutating func clearActive() { activeID = nil }

    mutating func close(_ id: String) -> CloseResult {
        guard let index = index(of: id) else { return .notFound }
        let tab = tabs.remove(at: index)
        closed.insert(ClosedTab(tab: tab, index: index), at: 0)
        if closed.count > Self.closedLimit { closed.removeLast(closed.count - Self.closedLimit) }
        guard activeID == id else { return .closedInactive }
        guard !tabs.isEmpty else {
            activeID = nil
            return .closedLast
        }
        let next = tabs[min(index, tabs.count - 1)].id
        activeID = next
        return .activate(next)
    }

    /// Reopens the most recent closed tab that is not open again, at its old
    /// index (clamped), and makes it active. Entries already open are dropped.
    mutating func reopen() -> String? {
        while !closed.isEmpty {
            let entry = closed.removeFirst()
            guard index(of: entry.tab.id) == nil else { continue }
            tabs.insert(entry.tab, at: min(entry.index, tabs.count))
            activeID = entry.tab.id
            return entry.tab.id
        }
        return nil
    }

    /// The session was deleted: the tab goes, and reopen cannot bring it back.
    mutating func remove(_ id: String) {
        tabs.removeAll { $0.id == id }
        closed.removeAll { $0.tab.id == id }
        if activeID == id { activeID = nil }
    }

    /// The session's id changed (draft id to gateway id). One tab survives.
    mutating func rekey(_ old: String, to new: String) {
        guard old != new, let index = index(of: old) else { return }
        tabs[index].id = new
        if let duplicate = tabs.indices.first(where: { $0 != index && tabs[$0].id == new }) {
            tabs.remove(at: duplicate)
        }
        if activeID == old { activeID = new }
        closed.removeAll { $0.tab.id == old }
    }

    mutating func markUnavailable(_ id: String) {
        guard let index = index(of: id) else { return }
        tabs[index].unavailable = true
    }

    mutating func updateTitle(_ id: String, _ title: String) {
        guard let index = index(of: id), tabs[index].title != title else { return }
        tabs[index].title = title
    }

    /// Cmd-1 ... Cmd-8 pick that tab; Cmd-9 always picks the last.
    func id(forShortcut n: Int) -> String? {
        guard !tabs.isEmpty else { return nil }
        if n == 9 { return tabs.last?.id }
        guard (1...8).contains(n), n <= tabs.count else { return nil }
        return tabs[n - 1].id
    }

    /// Next / previous tab, wrapping. With no active tab, next enters at the
    /// first and previous at the last. A single tab has no neighbour.
    func neighbor(_ direction: Direction) -> String? {
        guard !tabs.isEmpty else { return nil }
        guard let activeID, let index = index(of: activeID) else {
            return direction == .next ? tabs.first?.id : tabs.last?.id
        }
        guard tabs.count > 1 else { return nil }
        let offset = direction == .next ? 1 : -1
        return tabs[(index + offset + tabs.count) % tabs.count].id
    }
}
