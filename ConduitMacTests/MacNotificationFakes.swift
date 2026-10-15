import Foundation
import UserNotifications
@testable import ConduitMac

@MainActor
final class FakeNotificationCenter: MacNotificationCenterClient {
    var status: UNAuthorizationStatus = .authorized
    var grantOnRequest = true
    var authorizationRequests = 0
    var added: [UNNotificationRequest] = []
    var addError: Error?
    var removedDelivered: [String] = []
    var removedPending: [String] = []
    var stored: Set<UNNotificationCategory> = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grantOnRequest ? .authorized : .denied
        return grantOnRequest
    }
    func add(_ request: UNNotificationRequest) async throws {
        if let addError { throw addError }
        added.append(request)
    }
    func removeDelivered(_ identifiers: [String]) { removedDelivered += identifiers }
    func removePending(_ identifiers: [String]) { removedPending += identifiers }
    func categories() async -> Set<UNNotificationCategory> { stored }
    func setCategories(_ categories: Set<UNNotificationCategory>) { stored = categories }

    var identifiers: [String] { added.map(\.identifier) }
}

@MainActor
final class FakeScheduler: MacNotificationScheduling {
    struct Job { var delay: TimeInterval; var work: @MainActor () -> Void; var cancelled = false }
    private(set) var jobs: [Job] = []
    var cancelledCount: Int { jobs.filter(\.cancelled).count }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        jobs.append(Job(delay: seconds, work: work))
        let index = jobs.count - 1
        return { [weak self] in self?.jobs[index].cancelled = true }
    }

    /// Runs every job that was not cancelled, once.
    func fireAll() {
        for index in jobs.indices where !jobs[index].cancelled {
            jobs[index].cancelled = true
            jobs[index].work()
        }
    }
}

func makeSession(
    id: String = "run-1", key: String = "key-1", alternates: [String] = [],
    profile: String = "default", dashboard: UUID? = nil, title: String = "Refactor billing"
) -> MacNotificationSession {
    MacNotificationSession(sessionId: id, sessionKey: key, alternateIds: alternates, profile: profile, dashboardID: dashboard, title: title)
}
