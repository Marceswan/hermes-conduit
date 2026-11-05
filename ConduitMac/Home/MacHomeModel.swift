import Combine
import Foundation

enum MacHomeRefreshReason: Equatable {
    /// The pane appeared, or the connection scope changed.
    case appeared
    /// The poll loop; skipped by the live binding while the app is inactive.
    case periodic
}

/// Turns changes in AppState, the activity feed and the Kanban loader into
/// `MacHomeSnapshot`s for the Home view (D24). Owned by the view, so its
/// subscriptions and polls exist only while Home is the shown pane.
@MainActor
final class MacHomeModel: ObservableObject {
    struct Sources {
        var input: @MainActor (_ now: Date) -> MacHomeInput
        /// Fires (before the change lands) whenever anything Home reads may have changed.
        var changes: AnyPublisher<Void, Never>
        var refresh: @MainActor (_ reason: MacHomeRefreshReason) async -> Void
    }

    @Published private(set) var snapshot: MacHomeSnapshot

    private let sources: Sources
    private let calendar: Calendar
    private let clock: () -> Date
    private let tick: Duration
    private let refreshEvery: Int
    private var changeSubscription: AnyCancellable?

    init(
        sources: Sources,
        calendar: Calendar = .current,
        clock: @escaping () -> Date = Date.init,
        throttle: TimeInterval = 0.5,
        tick: Duration = .seconds(30),
        refreshEvery: Int = 2
    ) {
        self.sources = sources
        self.calendar = calendar
        self.clock = clock
        self.tick = tick
        self.refreshEvery = max(refreshEvery, 1)
        self.snapshot = MacHomeSnapshot.make(sources.input(clock()), calendar: calendar)
        // `objectWillChange` fires before the value lands, so hop to the next
        // run-loop turn first; then coalesce bursts (a streaming turn).
        changeSubscription = sources.changes
            .receive(on: RunLoop.main)
            .throttle(for: .seconds(throttle), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            }
    }

    /// Publishes only when the snapshot differs: AppState publishes constantly.
    func rebuild() {
        let next = MacHomeSnapshot.make(sources.input(clock()), calendar: calendar)
        if next != snapshot { snapshot = next }
    }

    /// The view's `.task(id: scope)`: refresh once, then tick (day rollover, relative
    /// times) and refresh every `refreshEvery` ticks until cancelled.
    func run() async {
        rebuild()
        await sources.refresh(.appeared)
        rebuild()
        var ticks = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: tick) } catch { return }
            rebuild()
            ticks += 1
            if ticks % refreshEvery == 0 {
                await sources.refresh(.periodic)
                if Task.isCancelled { return }
                rebuild()
            }
        }
    }
}
