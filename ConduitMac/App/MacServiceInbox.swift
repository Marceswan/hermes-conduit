import Foundation

/// Text a Service handed over, parked until Hermes is connected (D19).
/// One slot, last write wins; dropped when the dashboard or profile changed
/// since it arrived (the text was meant for the other workspace's context).
@MainActor
final class MacServiceInbox: ObservableObject {
    static let shared = MacServiceInbox()

    @Published private(set) var revision = 0

    private var scopeProvider: (() -> String)?
    /// `scope` is nil for text parked before the scope provider was installed
    /// (a Service fired at cold launch); `install(scope:)` stamps it.
    private var pending: (text: String, scope: String?)?

    var hasPending: Bool { pending != nil }

    static func scope(dashboardID: UUID?, profile: String) -> String {
        "\(dashboardID?.uuidString ?? "none").\(profile)"
    }

    /// Installs the live scope source. Text parked earlier is stamped with
    /// the scope in force now, so a later dashboard or profile change drops it.
    func install(scope: @escaping () -> String) {
        scopeProvider = scope
        if let parked = pending, parked.scope == nil {
            pending = (parked.text, scope())
        }
    }

    func submit(_ text: String) {
        pending = (text, scopeProvider?())
        revision += 1
    }

    func take() -> String? {
        defer { pending = nil }
        guard let pending else { return nil }
        if let stamped = pending.scope, stamped != scopeProvider?() { return nil }
        return pending.text
    }

    func discard() { pending = nil }
}
