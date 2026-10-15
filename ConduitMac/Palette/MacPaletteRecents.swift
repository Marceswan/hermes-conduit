import Foundation

/// The palette's recently run items, most recent first (D18). Pure value type.
struct MacPaletteRecents: Equatable {
    static let limit = 20
    static let shownLimit = 8

    private(set) var ids: [String]

    init(ids: [String] = []) {
        var seen = Set<String>()
        self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(Self.limit))
    }

    mutating func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }

    /// The recents whose item still exists, in recency order. This is how
    /// deleted sessions and slash commands of another profile drop out on
    /// read; the stored list is not rewritten (the session catalog is paged,
    /// so "not loaded" is not "gone").
    func resolved(in items: [MacPaletteItem]) -> [MacPaletteItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}

/// Persists recents per dashboard and profile, in an injected suite.
struct MacPaletteRecentsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func storageKey(dashboardID: UUID?, profile: String) -> String {
        "conduit.mac.palette.recents.\(dashboardID?.uuidString ?? "none").\(profile)"
    }

    func load(dashboardID: UUID?, profile: String) -> MacPaletteRecents {
        MacPaletteRecents(ids: defaults.stringArray(forKey: Self.storageKey(dashboardID: dashboardID, profile: profile)) ?? [])
    }

    func save(_ recents: MacPaletteRecents, dashboardID: UUID?, profile: String) {
        defaults.set(recents.ids, forKey: Self.storageKey(dashboardID: dashboardID, profile: profile))
    }
}
