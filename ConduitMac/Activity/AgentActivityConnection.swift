import Foundation

enum AgentActivityConnectionState: Equatable {
    case connected
    /// Not connected, but credentials exist or a connect is in progress.
    case reconnecting(since: Date)
    /// Not connected and nothing to reconnect with (signed out).
    case disconnected(since: Date)
}

struct AgentActivityConnectionSignals: Equatable {
    var isConnected: Bool
    var isConnecting: Bool
    var hasCredentials: Bool
}

enum AgentActivityConnection {
    /// Pure derivation. `since` is kept while the kind stays the same.
    static func state(
        _ signals: AgentActivityConnectionSignals,
        previous: AgentActivityConnectionState,
        now: Date
    ) -> AgentActivityConnectionState {
        if signals.isConnected { return .connected }
        if signals.hasCredentials || signals.isConnecting {
            if case .reconnecting = previous { return previous }
            return .reconnecting(since: now)
        }
        if case .disconnected = previous { return previous }
        return .disconnected(since: now)
    }
}
