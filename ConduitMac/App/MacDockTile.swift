import AppKit
import Combine

/// The part of the Dock tile that Conduit writes (D31). `NSDockTile` is the live one; tests use a fake.
@MainActor
protocol MacDockTileDisplaying: AnyObject {
    var badgeLabel: String? { get set }
}

extension NSDockTile: MacDockTileDisplaying {}

/// The one writer of the Dock badge (D31): the count of items that wait on the user, the number on the Home "waiting
/// on you" tile. No label while that count is 0, while the feed is offline or while the setting is off. The local
/// notifications (D20) set no badge number, so nothing else writes the tile; `MacDockTests` pins that.
@MainActor
final class MacDockBadge {
    /// Settings > Notifications > On this Mac > Show count on Dock icon.
    nonisolated static let defaultsKey = "conduit.mac.dock.showCount"
    nonisolated static let defaultValue = true

    private let tile: MacDockTileDisplaying
    private let defaults: UserDefaults
    private let snapshot: @MainActor () -> MacDockSnapshot
    private let changes: AnyPublisher<Void, Never>
    private let center: NotificationCenter
    private var subscriptions: Set<AnyCancellable> = []

    /// `changes` says the feed changed (the badge reads `snapshot` again); the setting is read from `defaults`.
    init(
        tile: MacDockTileDisplaying,
        defaults: UserDefaults = .standard,
        snapshot: @escaping @MainActor () -> MacDockSnapshot,
        changes: AnyPublisher<Void, Never>,
        center: NotificationCenter = .default
    ) {
        self.tile = tile
        self.defaults = defaults
        self.snapshot = snapshot
        self.changes = changes
        self.center = center
    }

    /// On unless the user turned it off. Not stored until the user chooses.
    nonisolated static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? defaultValue
    }

    nonisolated static func label(count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

    func start() {
        if subscriptions.isEmpty {
            changes
                .sink { [weak self] in self?.refresh() }
                .store(in: &subscriptions)
            // Any change in the domain lands here; `refresh` writes the tile only when the label differs.
            center.publisher(for: UserDefaults.didChangeNotification, object: defaults)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
        }
        refresh()
    }

    func stop() {
        subscriptions.removeAll()
        show(nil)
    }

    func refresh() {
        show(Self.isEnabled(in: defaults) ? Self.label(count: MacDockContent.waitingCount(snapshot())) : nil)
    }

    /// The tile is written only on a real change.
    private func show(_ label: String?) {
        guard label != tile.badgeLabel else { return }
        tile.badgeLabel = label
    }
}

extension MacDockSnapshot {
    /// The badge's input: the feed's rows and availability, no chats.
    @MainActor
    static func waiting(feed: AgentActivityFeed?) -> MacDockSnapshot {
        MacDockSnapshot(
            feed: MacHomeBinding.availability(feed),
            live: feed.map { MacHomeBinding.liveItems($0.items) } ?? [],
            sessions: []
        )
    }
}

/// Starts the badge owner with the other app-wide bootstraps (the app delegate calls it, not a window).
@MainActor
enum MacDockBootstrap {
    private(set) static var badge: MacDockBadge?

    /// Call after `MacActivityBootstrap.start()`: the badge reads the feed that creates.
    static func start(tile: MacDockTileDisplaying? = nil, defaults: UserDefaults = .standard) {
        guard badge == nil else { return }
        // `objectWillChange` fires before the change lands: read on the next main-queue turn.
        let changes = AgentActivityFeed.shared.map { $0.objectWillChange.receive(on: DispatchQueue.main).eraseToAnyPublisher() }
            ?? Empty<Void, Never>().eraseToAnyPublisher()
        let badge = MacDockBadge(
            tile: tile ?? NSApp.dockTile,
            defaults: defaults,
            snapshot: { MacDockSnapshot.waiting(feed: AgentActivityFeed.shared) },
            changes: changes
        )
        badge.start()
        self.badge = badge
    }

    static func stop() {
        badge?.stop()
        badge = nil
    }
}
