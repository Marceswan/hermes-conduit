//
//  KanbanBoardSelectionStore.swift
//  Conduit
//

import Foundation

/// Device-local memory of which Kanban board is open per server. Boards are
/// server-wide (not profile-scoped), so the key is the normalized dashboard
/// base URL. Selection is client-side only: Conduit passes `?board=` on every
/// request and never flips the server's current-board pointer.
final class KanbanBoardSelectionStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private var values: [String: String]

    init(defaults: UserDefaults = .standard, storageKey: String = "conduit.kanbanBoard.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        values = Self.decode(defaults.data(forKey: storageKey))
    }

    func selectedBoard(forServer serverKey: String) -> String? {
        values[Self.normalized(serverKey)]
    }

    func setSelectedBoard(_ slug: String?, forServer serverKey: String) {
        let key = Self.normalized(serverKey)
        guard !key.isEmpty else { return }
        if let slug, !slug.isEmpty {
            values[key] = slug
        } else {
            values.removeValue(forKey: key)
        }
        defaults.set(try? JSONEncoder().encode(values), forKey: storageKey)
    }

    private static func normalized(_ serverKey: String) -> String {
        serverKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decode(_ data: Data?) -> [String: String] {
        guard let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }
}
