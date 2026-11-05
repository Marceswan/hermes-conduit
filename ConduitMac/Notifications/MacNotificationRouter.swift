import Foundation

@MainActor
final class MacNotificationRouter: MacNotificationRouting {
    private let activateApp: () -> Void
    private let openSession: (String) -> Void
    private let activeDashboardID: () -> UUID?
    private let activeProfile: () -> String
    private let isConnected: () -> Bool
    private let removeNotifications: ([String]) -> Void
    private var held: MacNotificationPayload?

    init(
        activateApp: @escaping () -> Void, openSession: @escaping (String) -> Void,
        activeDashboardID: @escaping () -> UUID?, activeProfile: @escaping () -> String,
        isConnected: @escaping () -> Bool, removeNotifications: @escaping ([String]) -> Void
    ) {
        self.activateApp = activateApp; self.openSession = openSession
        self.activeDashboardID = activeDashboardID; self.activeProfile = activeProfile
        self.isConnected = isConnected; self.removeNotifications = removeNotifications
    }

    func route(_ payload: MacNotificationPayload) {
        activateApp()
        removeNotifications([
            MacNotificationPolicy.ID.done(payload.sessionKey),
            payload.requestId.map(MacNotificationPolicy.ID.approval),
            payload.requestId.map(MacNotificationPolicy.ID.question),
        ].compactMap { $0 })
        guard isConnected() else { held = payload; return }   // cold launch: wait for Hermes
        open(payload)
    }

    /// Call when the connection state changes; opens a click held at cold launch.
    func connectionChanged() {
        guard isConnected(), let payload = held else { return }
        held = nil
        open(payload)
    }

    private func open(_ payload: MacNotificationPayload) {
        // Another dashboard or profile: only the activation above.
        if let dashboard = payload.dashboardID, let active = activeDashboardID(), dashboard != active { return }
        guard payload.profile == activeProfile() else { return }
        openSession(payload.sessionKey)
    }
}
