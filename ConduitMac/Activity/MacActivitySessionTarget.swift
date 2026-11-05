import Foundation

/// The chat that a feed row (Home, Dock menu, notch) opens. One rule for all three (D24, fix 2026-10-28).
///
/// A feed item holds two ids. `sessionId` is the runtime id of the live session, as the gateway reported it.
/// `session.resume` does not know a runtime id (it resumes stored ids), and a catalog row lists it only while the
/// row is the local one. `sessionKey` is the durable id: the catalog id, else the stored id the poll reported.
/// The sidebar opens the catalog row's `id`. A feed row therefore carries the durable id and opens it the way a
/// sidebar row does, resolved to the catalog row.
enum MacActivitySessionTarget {
    /// The id a feed row carries: the durable key first, the runtime id when the feed has no key, nil with neither.
    static func openID(of item: AgentActivityItem) -> String? {
        [item.sessionKey, item.sessionId].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The id that the sidebar row of this chat opens. `id` itself when it is a catalog row's id (a Recent row
    /// stays as it is); else the first row that lists it as a stored id or an alias; else the first row that has it
    /// as its lineage root (the tip of a compressed conversation). With no catalog row yet, the id goes through
    /// unchanged for `requestOpenSession` to resume: the durable id when the feed knows one.
    nonisolated static func openableID(_ id: String, in catalog: [SessionSummary]) -> String {
        if catalog.contains(where: { $0.id == id }) { return id }
        let listed = catalog.first { $0.nestingIDs.contains(id) }
            ?? catalog.first { $0.lineageRootId == id }
        return listed?.id ?? id
    }

    /// The route of a sidebar row: `requestOpenSession` with the catalog id.
    @MainActor @discardableResult
    static func open(_ id: String, in appState: AppState) -> Task<Bool, Never> {
        appState.requestOpenSession(openableID(id, in: appState.sessions))
    }
}
