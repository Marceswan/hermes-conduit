import Foundation

/// Async bounded wait for tests that depend on main-actor tasks. Unlike
/// `HostedTestSupport.waitUntil` (a synchronous run-loop spin), this suspends,
/// so main-actor work keeps running while the test waits.
@MainActor
func macHomeEventually(
    timeout: TimeInterval = 5,
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// For negative assertions: lets queued main-actor work drain.
@MainActor
func macHomeSettle(_ seconds: TimeInterval = 0.1) async {
    try? await Task.sleep(for: .seconds(seconds))
}
