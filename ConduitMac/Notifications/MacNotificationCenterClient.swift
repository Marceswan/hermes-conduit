import Foundation
import OSLog
import UserNotifications

let macNotificationsLogger = Logger(subsystem: "com.milim.conduit.mac", category: "notifications")

/// The slice of `UNUserNotificationCenter` the coordinator needs. Tests inject
/// a fake; the real adapter is built only by `MacNotificationRuntime`.
@MainActor
protocol MacNotificationCenterClient: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removeDelivered(_ identifiers: [String])
    func removePending(_ identifiers: [String])
    func categories() async -> Set<UNNotificationCategory>
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

@MainActor
final class UNMacNotificationCenterClient: MacNotificationCenterClient {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func categories() async -> Set<UNNotificationCategory> { await center.notificationCategories() }
    func setCategories(_ categories: Set<UNNotificationCategory>) { center.setNotificationCategories(categories) }
}

/// Delayed work for the approval grace window. The returned closure cancels.
@MainActor
protocol MacNotificationScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
final class MacTaskScheduler: MacNotificationScheduling {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            work()
        }
        return { task.cancel() }
    }
}
