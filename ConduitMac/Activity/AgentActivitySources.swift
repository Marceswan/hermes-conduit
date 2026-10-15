import Foundation

/// Everything the feed needs from the gateway, behind a protocol so tests inject a fake.
@MainActor
protocol AgentActivitySources: AnyObject {
    /// A client exists and the socket is up. Nothing else gates the poll.
    var isConnected: Bool { get }
    func activeSessions() async throws -> [LiveSessionStatus]
    func pendingApprovals(sessionId: String) async throws -> [ApprovalActivity]
    /// `approval.respond`. True when the gateway resolved at least one queue entry.
    func respondToApproval(sessionId: String, requestId: String?, choice: String) async throws -> Bool
    /// Answers through the open chat's approval card so its state stays coherent.
    /// nil when no pending card matches `requestId`; false when the card ended in error.
    func respondViaActiveCard(requestId: String, choice: String) async -> Bool?
    func isMethodUnavailable(_ error: Error) -> Bool
}

enum AgentActivityRpc {
    /// Same rule as the private `AppState.isMethodUnavailable`.
    static func isMethodUnavailable(_ error: Error) -> Bool {
        guard let rpc = error as? RpcError else { return false }
        let message = rpc.message.lowercased()
        return rpc.code == -32601 || message.contains("method not found") || message.contains("unknown method")
    }

    /// 4009 / "no pending": the decision is no longer active.
    @MainActor
    static func isExpiredPrompt(_ error: Error) -> Bool {
        AppState.isExpiredPromptError(error)
    }
}

enum AgentActivityPollCadence {
    static let live: TimeInterval = 4
    static let idle: TimeInterval = 15

    /// A gateway that keeps failing is asked less often, up to this ceiling.
    static let maxBackoff: TimeInterval = 60

    /// 4 s while anything is live or a surface is showing; 15 s when idle.
    static func interval(isLive: Bool, panelVisible: Bool) -> TimeInterval {
        isLive || panelVisible ? live : idle
    }

    /// `interval` doubled per consecutive failure (so 4, 8, 16, 32, 60 s while live), never past `maxBackoff`.
    static func interval(isLive: Bool, panelVisible: Bool, failures: Int) -> TimeInterval {
        let base = interval(isLive: isLive, panelVisible: panelVisible)
        guard failures > 0 else { return base }
        return min(base * pow(2, Double(min(failures, 6))), max(maxBackoff, base))
    }
}

/// Production sources over the app's `HermesClient`.
@MainActor
final class AgentActivityLiveSources: AgentActivitySources {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var isConnected: Bool { appState.isConnected && appState.client != nil }

    func activeSessions() async throws -> [LiveSessionStatus] {
        guard let client = appState.client else { throw HermesError.notConnected }
        return try await client.activeSessions()
    }

    func pendingApprovals(sessionId: String) async throws -> [ApprovalActivity] {
        guard let client = appState.client else { throw HermesError.notConnected }
        return try await client.pendingApprovals(sessionId: sessionId)
    }

    func respondToApproval(sessionId: String, requestId: String?, choice: String) async throws -> Bool {
        guard let client = appState.client else { throw HermesError.notConnected }
        return try await client.respondToApproval(sessionId: sessionId, requestId: requestId, choice: choice, profile: nil)
    }

    func respondViaActiveCard(requestId: String, choice: String) async -> Bool? {
        guard let message = appState.messages.first(where: {
            $0.approval?.requestId == requestId && ($0.approval?.status == .pending || $0.approval?.status == .error)
        }) else { return nil }
        await appState.respondToApproval(messageId: message.id, choice: choice)
        return appState.messages.first { $0.id == message.id }?.approval?.status != .error
    }

    func isMethodUnavailable(_ error: Error) -> Bool { AgentActivityRpc.isMethodUnavailable(error) }
}

/// Polls `session.active_list` on its own clock. Not tied to the sidebar and not
/// tied to whether Conduit is frontmost: only to the connection.
@MainActor
final class AgentActivityPoller {
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void

    static let liveSleep: Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    var isLive: () -> Bool = { false }
    var isPanelVisible: () -> Bool = { false }
    var onRows: ([LiveSessionStatus]) -> Void = { _ in }
    var onUnavailable: () -> Void = {}

    private let sources: AgentActivitySources
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var unavailable = false
    /// Consecutive failed polls (method-unavailable and offline do not count); stretches the interval.
    private(set) var failures = 0
    /// Requests are numbered; a response older than one already applied is dropped, so overlapping
    /// polls (the loop plus `refreshNow`) can never apply out of order.
    private var nextSequence = 0
    private var appliedSequence = -1

    init(sources: AgentActivitySources, sleep: @escaping Sleep = AgentActivityPoller.liveSleep) {
        self.sources = sources
        self.sleep = sleep
    }

    var isRunning: Bool { task != nil }

    /// Polls at once, then every `AgentActivityPollCadence.interval`. Idempotent.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollNow()
                let interval = AgentActivityPollCadence.interval(
                    isLive: self.isLive(), panelVisible: self.isPanelVisible(), failures: self.failures)
                do { try await self.sleep(interval) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        discardInFlight()
    }

    /// A new connection probes for `session.active_list` again.
    func resetCapability() {
        unavailable = false
        failures = 0
    }

    /// Responses to requests already sent are ignored (a scope change or stop: they describe the old scope).
    func discardInFlight() {
        appliedSequence = nextSequence - 1
    }

    func pollNow() async {
        guard sources.isConnected, !unavailable else { return }
        let sequence = nextSequence
        nextSequence += 1
        do {
            let rows = try await sources.activeSessions()
            guard !Task.isCancelled, sequence > appliedSequence else { return }
            appliedSequence = sequence
            failures = 0
            onRows(rows)
        } catch is CancellationError {
            return
        } catch {
            // Stop asking a gateway that lacks the method; other failures retry on a longer interval.
            if sources.isMethodUnavailable(error) {
                unavailable = true
                onUnavailable()
            } else if sources.isConnected, sequence > appliedSequence {
                failures += 1
            }
        }
    }
}
