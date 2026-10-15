import XCTest
@testable import ConduitMac

/// Polls without blocking the main actor: a suspension lets main-actor tasks and
/// Combine hops run, which a run-loop spin inside an async test does not.
@MainActor
func waitForCondition(timeout: TimeInterval = 5, _ predicate: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

@MainActor
func assertEventually(
    _ message: String = "condition not reached", timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line,
    _ predicate: @MainActor () -> Bool
) async {
    let reached = await waitForCondition(timeout: timeout, predicate)
    XCTAssertTrue(reached, message, file: file, line: line)
}

/// A sleeper the test advances by hand: `sleep` records the request and parks
/// until `fire()`. No wall-clock time passes.
@MainActor
final class ManualSleeper {
    private(set) var requested: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []
    var pending: Int { waiters.count }

    func sleep(_ seconds: TimeInterval) async throws {
        requested.append(seconds)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func fire() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    /// Releases every parked sleeper (call from tearDown so no task is left hanging).
    func cancelAll() {
        let all = waiters
        waiters = []
        all.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class FakeActivitySources: AgentActivitySources {
    var isConnected = true
    var rows: [LiveSessionStatus] = []
    var activeError: Error?
    var pendingResults: [String: Result<[ApprovalActivity], Error>] = [:]
    var respondResult: Result<Bool, Error> = .success(true)
    /// nil: no open card for the request.
    var cardResult: Bool?
    var holdResponses = false

    private(set) var activeCalls = 0
    private(set) var pendingCalls: [String] = []
    private(set) var responses: [(session: String, request: String?, choice: String)] = []
    private(set) var cardResponses: [(request: String, choice: String)] = []
    private var gate: CheckedContinuation<Void, Never>?

    func activeSessions() async throws -> [LiveSessionStatus] {
        activeCalls += 1
        if let activeError { throw activeError }
        return rows
    }

    func pendingApprovals(sessionId: String) async throws -> [ApprovalActivity] {
        pendingCalls.append(sessionId)
        switch pendingResults[sessionId] {
        case .success(let list)?: return list
        case .failure(let error)?: throw error
        case nil: return []
        }
    }

    func respondToApproval(sessionId: String, requestId: String?, choice: String) async throws -> Bool {
        responses.append((sessionId, requestId, choice))
        if holdResponses { await withCheckedContinuation { gate = $0 } }
        return try respondResult.get()
    }

    func releaseResponses() {
        holdResponses = false
        gate?.resume()
        gate = nil
    }

    func respondViaActiveCard(requestId: String, choice: String) async -> Bool? {
        cardResponses.append((requestId, choice))
        return cardResult
    }

    func isMethodUnavailable(_ error: Error) -> Bool { AgentActivityRpc.isMethodUnavailable(error) }
}
