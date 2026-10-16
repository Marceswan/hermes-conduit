import Foundation

/// Task counts per Kanban column for Home (D24). Home does not own a
/// `KanbanStore` (that is private to `KanbanView`); the live `Fetch` is built
/// in `MacHomeBinding` over `KanbanService`. A generation counter makes a late
/// response from a previous scope (reset, newer load) inert.
@MainActor
final class MacHomeKanbanLoader: ObservableObject {
    typealias Fetch = @MainActor (_ slug: String?) async throws -> [MacHomeKanbanColumnInput]

    @Published private(set) var state: MacHomeKanbanInput = .notLoaded

    private let fetch: Fetch
    private var generation = 0

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// A new dashboard or profile: forget everything, drop any response still in flight.
    func reset() {
        generation += 1
        state = .notLoaded
    }

    /// No dashboard bridge (or another reason Kanban cannot be asked).
    func markUnavailable() {
        generation += 1
        state = .unavailable
    }

    /// `preferredSlug` is the board the user last selected for this server;
    /// nil or empty asks for the server's current board.
    func load(preferredSlug: String?) async {
        generation += 1
        let mine = generation
        do {
            let columns = try await fetchWithFallback(preferredSlug)
            guard mine == generation else { return }
            state = .loaded(columns)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            guard mine == generation else { return }
            // A transient failure keeps the last board on screen.
            if case .loaded = state { return }
            state = .unavailable
        }
    }

    private func fetchWithFallback(_ slug: String?) async throws -> [MacHomeKanbanColumnInput] {
        guard let slug, !slug.isEmpty else { return try await fetch(nil) }
        do {
            return try await fetch(slug)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            // The saved board may have been deleted: one retry on the current board.
            return try await fetch(nil)
        }
    }
}
