import Foundation

/// What Home knows about the scheduled jobs. Home-owned: it never reads
/// `AppState.cronJobs` (which keeps the previous scope's list across a dashboard
/// switch) and never writes `AppState.errorMessage` (which the composer renders).
enum MacHomeCronState: Equatable {
    case notLoaded
    case unavailable
    case loaded([MacHomeCronJob])
}

/// Fetches the cron list for Home (D24) with an explicit loading / loaded /
/// unavailable state. Failures are swallowed into `.unavailable`; a generation
/// counter makes a response from a superseded scope or refresh inert.
@MainActor
final class MacHomeCronLoader: ObservableObject {
    typealias Fetch = @MainActor () async throws -> [MacHomeCronJob]

    @Published private(set) var state: MacHomeCronState = .notLoaded

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

    func markUnavailable() {
        generation += 1
        state = .unavailable
    }

    func load() async {
        generation += 1
        let mine = generation
        do {
            let jobs = try await fetch()
            guard mine == generation, !Task.isCancelled else { return }
            state = .loaded(jobs)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            guard mine == generation else { return }
            // A transient failure keeps this scope's last list; a scope change reset it already.
            if case .loaded = state { return }
            state = .unavailable
        }
    }
}
