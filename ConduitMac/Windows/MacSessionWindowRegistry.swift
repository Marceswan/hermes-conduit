import Combine
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
    /// Windows whose turn runs now. `MacBackgroundActivity` keeps Conduit awake while this is not empty (D29).
    @Published private(set) var runningTurns: Set<MacSessionWindowToken> = []
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

    /// Forgets a request whose window never appeared (an `openWindow` that produced
    /// nothing), so the slot is not held until relaunch. A window that is open stays.
    func releaseIfUnappeared(_ token: MacSessionWindowToken) {
        guard !open.contains(token) else { return }
        requested.remove(token)
    }

    func disappeared(_ token: MacSessionWindowToken) {
        open.remove(token)
        requested.remove(token)
        runningTurns.remove(token)
    }

    /// Follows one window's turn (D29): running while `transcript.turn` is `.running`. A turn that waits for
    /// the user (`.needsInput`) is not running. The window keeps the returned cancellable until it closes;
    /// cancel it before `disappeared`.
    func trackTurn(of controller: MacSessionWindowController) -> AnyCancellable {
        let token = controller.token
        // @Published emits in willSet: the closure uses the emitted transcript, never `controller.transcript`.
        return controller.$transcript
            .map { $0.turn == .running }
            .removeDuplicates()
            .sink { [weak self] running in
                if running { self?.runningTurns.insert(token) } else { self?.runningTurns.remove(token) }
            }
    }
}
