import Foundation
import UserNotifications

/// A thin shim: extract Sendable values from the response and hand them to
/// the tested `MacNotificationAction`. A `UNTextInputNotificationResponse`
/// cannot be built in tests, so this file is verified by the smoke run.
final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onAction: (@MainActor (MacNotificationAction) async -> Void)?
    var presentation: (@MainActor (MacNotificationPayload?) -> UNNotificationPresentationOptions)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let userInfo = response.notification.request.content.userInfo
        let notificationID = response.notification.request.identifier
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor [weak self] in
            defer { done() }
            guard let action = MacNotificationAction.make(actionIdentifier: identifier, userText: text, userInfo: userInfo, notificationIdentifier: notificationID) else { return }
            await self?.onAction?(action)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor [weak self] in
            done(self?.presentation?(MacNotificationPayload(userInfo: userInfo)) ?? [.banner, .list, .sound])
        }
    }
}
