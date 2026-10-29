import AppIntents
import Foundation

enum ConduitSessionCatalog {
    static func displayTitle(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? AppLocalization.string("New conversation") : t
    }

    private static func entity(_ s: SessionSummary) -> ConduitSessionEntity {
        ConduitSessionEntity(id: s.id, title: displayTitle(s.title), profile: s.profile)
    }

    static func suggestions(_ sessions: [SessionSummary], limit: Int) -> [ConduitSessionEntity] {
        sessions
            .sorted { ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0) }
            .prefix(limit).map(entity)
    }

    /// Resolves saved ids. An id the catalog does not list still resolves (the
    /// app may have just launched, or the chat is on an unloaded page);
    /// opening it reports "That chat is no longer available." if it is gone.
    static func resolve(_ ids: [String], in sessions: [SessionSummary]) -> [ConduitSessionEntity] {
        ids.map { id in
            if let row = sessions.first(where: { $0.id == id || $0.alternateIds.contains(id) }) { return entity(row) }
            return ConduitSessionEntity(id: id, title: AppLocalization.string("Conduit chat"), profile: nil)
        }
    }

    static func matching(_ text: String, in sessions: [SessionSummary]) -> [ConduitSessionEntity] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = needle.isEmpty ? sessions : sessions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        return suggestions(rows, limit: 50)
    }
}

struct ConduitSessionEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conduit chat")
    static var defaultQuery = ConduitSessionEntityQuery()

    let id: String
    let title: String
    let profile: String?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct ConduitSessionEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ConduitSessionEntity] {
        ConduitSessionCatalog.resolve(identifiers, in: MacIntentDataSource.shared.sessions)
    }

    @MainActor func entities(matching string: String) async throws -> [ConduitSessionEntity] {
        ConduitSessionCatalog.matching(string, in: MacIntentDataSource.shared.sessions)
    }

    @MainActor func suggestedEntities() async throws -> [ConduitSessionEntity] {
        ConduitSessionCatalog.suggestions(MacIntentDataSource.shared.sessions, limit: 25)
    }
}
