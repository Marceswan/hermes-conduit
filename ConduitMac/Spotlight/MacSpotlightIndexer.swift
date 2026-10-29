import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The slice of Core Spotlight the indexer uses, so tests inject a fake.
@MainActor
protocol SearchableIndexing: AnyObject {
    func index(_ items: [MacSpotlightItem])
    func delete(ids: [String])
    func delete(domains: [String])
    func deleteAll()
}

/// The real index. Errors are logged, never thrown: Spotlight is best effort.
/// Item building and every Core Spotlight call run on one serial utility queue,
/// off the main thread; the serial order keeps an index followed by a delete
/// of the same id in call order.
@MainActor
final class CoreSpotlightIndex: SearchableIndexing {
    private let queue = DispatchQueue(label: "ai.conduit.mac.spotlight", qos: .utility)

    func index(_ items: [MacSpotlightItem]) {
        guard !items.isEmpty else { return }
        queue.async {
            let converted = items.map(Self.searchableItem(for:))
            CSSearchableIndex.default().indexSearchableItems(converted) { Self.log("index", $0) }
        }
    }

    /// The only place an item becomes a `CSSearchableItem`: title, model and
    /// count line, date. Nothing else is ever set (no `textContent`).
    nonisolated static func searchableItem(for item: MacSpotlightItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = item.title
        attributes.displayName = item.title
        attributes.contentDescription = item.contentDescription
        attributes.contentModificationDate = item.modified
        let searchable = CSSearchableItem(uniqueIdentifier: item.uniqueIdentifier,
                                          domainIdentifier: item.domainIdentifier,
                                          attributeSet: attributes)
        // Core Spotlight drops items after one month by default. The indexer
        // only re-sends rows that changed, so an idle chat would vanish from
        // Spotlight while the snapshot still lists it. Removal is explicit
        // instead (delete, archive, scope change, toggle off).
        searchable.expirationDate = .distantFuture
        return searchable
    }

    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.async {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids) { Self.log("delete ids", $0) }
        }
    }

    func delete(domains: [String]) {
        guard !domains.isEmpty else { return }
        queue.async {
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: domains) { Self.log("delete domains", $0) }
        }
    }

    func deleteAll() {
        queue.async {
            CSSearchableIndex.default().deleteAllSearchableItems { Self.log("delete all", $0) }
        }
    }

    private nonisolated static func log(_ what: String, _ error: Error?) {
        if let error { NSLog("Conduit Spotlight %@ failed: %@", what, error.localizedDescription) }
    }
}

/// Mirrors the loaded session catalog into Spotlight (D19): opt-in, title and
/// metadata only, diff based. A row missing from the loaded page is not a
/// deletion; removals come from `sessionDeleted`, `sessionsArchived`, archive
/// flags, an identity change, scope changes and the cap.
@MainActor
final class MacSpotlightIndexer {
    static let itemCap = 1_000
    static let enabledKey = "conduit.mac.spotlight.enabled"
    static let lastScopeKey = "conduit.mac.spotlight.lastScope"

    private struct Row: Codable, Equatable {
        var title: String
        var at: Double?
    }

    private let index: SearchableIndexing
    private let defaults: UserDefaults
    private var scope: MacSpotlightScope?
    private var snapshot: [String: Row] = [:]

    init(index: SearchableIndexing, defaults: UserDefaults = .standard) {
        self.index = index
        self.defaults = defaults
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Whether `setScope(new)` would do anything.
    func hasScopeChange(to new: MacSpotlightScope?) -> Bool { new != scope || scope == nil }

    func setEnabled(_ on: Bool, catalog: [SessionSummary]) {
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            if let scope { persist(scope: scope) }
            catalogChanged(catalog)
        } else {
            removeAll()
        }
    }

    /// Removes everything Conduit indexed and forgets every snapshot, so a
    /// later index run refills from the catalog instead of trusting a snapshot
    /// of an index that no longer holds the rows.
    func removeAll() {
        index.deleteAll()
        snapshot = [:]
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(MacSpotlightScope.snapshotKeyPrefix)
            && key != Self.enabledKey && key != Self.lastScopeKey {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Self.lastScopeKey)
        if isEnabled, let scope { persist(scope: scope) }
    }

    /// nil means no signed-in dashboard: nothing is indexed and the previous
    /// scope's items go.
    func setScope(_ new: MacSpotlightScope?, catalog: [SessionSummary]) {
        guard hasScopeChange(to: new) else { return }
        let previous = scope ?? lastPersistedScope()
        if let previous, previous != new, isEnabled {
            index.delete(domains: [previous.domainIdentifier])
            defaults.removeObject(forKey: previous.snapshotKey)
        }
        scope = new
        snapshot = [:]
        if let new {
            persist(scope: new)
            snapshot = load(new)
        } else {
            defaults.removeObject(forKey: Self.lastScopeKey)
        }
        catalogChanged(catalog)
    }

    func catalogChanged(_ sessions: [SessionSummary]) {
        guard isEnabled, let scope else { return }
        var removed: [String] = []
        var changed: [MacSpotlightItem] = []
        var addedThisRun: Set<String> = []

        // Rows the catalog itself marks archived.
        for session in sessions where session.isArchived {
            removed += forget(session)
        }

        let newest = sessions
            .filter(MacSpotlightItemFactory.isIndexable)
            .sorted { ($0.lastActivityAt ?? 0, $0.id) > ($1.lastActivityAt ?? 0, $1.id) }
            .prefix(Self.itemCap)
        for session in newest {
            // The same chat under a new primary id: drop the old identity.
            for alternate in session.alternateIds where alternate != session.id {
                if snapshot.removeValue(forKey: alternate) != nil { removed.append(alternate) }
            }
            let row = Row(title: session.title, at: session.lastActivityAt)
            guard snapshot[session.id] != row else { continue }
            if snapshot[session.id] == nil { addedThisRun.insert(session.id) }
            snapshot[session.id] = row
            changed.append(MacSpotlightItemFactory.item(for: session, scope: scope))
        }

        // The cap holds across pages: the oldest indexed rows make room. A row
        // new this run and already the oldest was never sent, so it is
        // dropped without a delete (otherwise every run would re-add and
        // re-delete it).
        if snapshot.count > Self.itemCap {
            let overflow = snapshot
                .sorted { ($0.value.at ?? 0, $0.key) < ($1.value.at ?? 0, $1.key) }
                .prefix(snapshot.count - Self.itemCap)
                .map(\.key)
            for id in overflow {
                snapshot[id] = nil
                if !addedThisRun.contains(id) { removed.append(id) }
            }
            let dropped = Set(overflow.map { MacSpotlightItemID.make(scope: scope, sessionID: $0) })
            changed.removeAll { dropped.contains($0.uniqueIdentifier) }
        }

        guard !changed.isEmpty || !removed.isEmpty else { return }
        if !changed.isEmpty { index.index(changed) }
        if !removed.isEmpty { index.delete(ids: removed.map { MacSpotlightItemID.make(scope: scope, sessionID: $0) }) }
        save(scope)
    }

    /// A confirmed deletion (not a page that no longer lists the row).
    func sessionDeleted(_ id: String) {
        guard isEnabled, let scope, snapshot.removeValue(forKey: id) != nil else { return }
        index.delete(ids: [MacSpotlightItemID.make(scope: scope, sessionID: id)])
        save(scope)
    }

    /// Rows that moved to the archived list leave the live catalog without
    /// being deleted; they must leave Spotlight too.
    func sessionsArchived(_ archived: [SessionSummary]) {
        guard isEnabled, let scope else { return }
        let removed = archived.flatMap { forget($0) }
        guard !removed.isEmpty else { return }
        index.delete(ids: removed.map { MacSpotlightItemID.make(scope: scope, sessionID: $0) })
        save(scope)
    }

    /// Drops a session's primary and alternate ids from the snapshot and
    /// returns the ones that were indexed.
    private func forget(_ session: SessionSummary) -> [String] {
        ([session.id] + session.alternateIds).filter { snapshot.removeValue(forKey: $0) != nil }
    }

    // MARK: Persistence

    private func save(_ scope: MacSpotlightScope) {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: scope.snapshotKey) }
    }

    private func load(_ scope: MacSpotlightScope) -> [String: Row] {
        guard let data = defaults.data(forKey: scope.snapshotKey),
              let rows = try? JSONDecoder().decode([String: Row].self, from: data) else { return [:] }
        return rows
    }

    private func persist(scope: MacSpotlightScope) {
        let stored: [String: String] = ["dashboard": scope.dashboardID?.uuidString ?? "", "profile": scope.profile]
        defaults.set(stored, forKey: Self.lastScopeKey)
    }

    private func lastPersistedScope() -> MacSpotlightScope? {
        guard let stored = defaults.dictionary(forKey: Self.lastScopeKey) as? [String: String],
              let profile = stored["profile"] else { return nil }
        let id = stored["dashboard"].flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
        return MacSpotlightScope(dashboardID: id, profile: profile)
    }
}
