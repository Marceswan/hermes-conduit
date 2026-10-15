import Foundation

/// Multicast for every parsed `StreamEvent`, fed by the one gated line in
/// `AppState.handleStreamEvent` (Task 5). Mac-only consumers (Quick Ask, the
/// agent activity feed) subscribe here instead of each adding a line to
/// upstream code. Events arrive on the main actor, before AppState's
/// active-session filter, for every session this socket carries.
@MainActor
final class MacStreamEventHub {
    static let shared = MacStreamEventHub()

    typealias Handler = @MainActor (StreamEvent) -> Void

    struct Token: Hashable {
        fileprivate let id: UInt64
    }

    private var entries: [(token: Token, handler: Handler)] = []
    private var nextID: UInt64 = 0

    var subscriberCount: Int { entries.count }

    func subscribe(_ handler: @escaping Handler) -> Token {
        nextID += 1
        let token = Token(id: nextID)
        entries.append((token, handler))
        return token
    }

    func unsubscribe(_ token: Token) {
        entries.removeAll { $0.token == token }
    }

    func publish(_ event: StreamEvent) {
        guard !entries.isEmpty else { return }
        let snapshot = entries
        for entry in snapshot where entries.contains(where: { $0.token == entry.token }) {
            entry.handler(event)
        }
    }
}
