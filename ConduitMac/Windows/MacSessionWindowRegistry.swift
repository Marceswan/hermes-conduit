import Foundation

/// Which session windows exist (D21). A window counts from its request until
/// it closes, so four quick opens cannot overshoot the cap. A window that
/// appears without a request in this run is one SwiftUI restored at relaunch;
/// v1 does not restore windows, so the view closes it.
@MainActor
final class MacSessionWindowRegistry: ObservableObject {
    static let shared = MacSessionWindowRegistry()
    static let limit = 4

    @Published private(set) var open: Set<MacSessionWindowToken> = []
    private var requested: Set<MacSessionWindowToken> = []

    var isFull: Bool { requested.union(open).count >= Self.limit }

    /// False at the cap. An already requested or open token is always allowed (it focuses).
    func request(_ token: MacSessionWindowToken) -> Bool {
        if requested.contains(token) || open.contains(token) { return true }
        guard !isFull else { return false }
        requested.insert(token)
        return true
    }

    /// False for a window this run never requested (a restored one).
    func appeared(_ token: MacSessionWindowToken) -> Bool {
        guard requested.contains(token) else { return false }
        open.insert(token)
        return true
    }

    func disappeared(_ token: MacSessionWindowToken) {
        open.remove(token)
        requested.remove(token)
    }
}
