import Foundation

@MainActor
protocol NotchTimerScheduling {
    /// Returns a cancel closure.
    func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void
}

struct TaskTimerScheduler: NotchTimerScheduling {
    func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(after)) } catch { return }
            fire()
        }
        return { task.cancel() }
    }
}
