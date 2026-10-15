import Foundation
import UserNotifications

/// A thin shim: extract Sendable values from the response and hand them to
/// the tested `MacNotificationAction`. A `UNTextInputNotificationResponse`
/// cannot be built in tests, so this file is verified by the smoke run.
///
/// The center has one delegate. If another component (Sparkle's update
/// notification, for one) already holds the slot, `install(on:)` keeps it as
/// `forward` and hands it every notification that is not Conduit's own.
final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onAction: (@MainActor (MacNotificationAction) async -> Void)?
    var presentation: (@MainActor (MacNotificationPayload?) -> UNNotificationPresentationOptions)?
    /// The delegate this one displaced, if any.
    private(set) var forward: UNUserNotificationCenterDelegate?

    /// Remembers `existing` as the delegate to forward foreign notifications to.
    /// Never remembers itself, and never drops a remembered one for nil.
    func chain(to existing: UNUserNotificationCenterDelegate?) {
        guard let existing, existing !== self else { return }
        forward = existing
    }

    /// Takes the delegate slot without discarding whoever holds it. Idempotent:
    /// call it again whenever the slot may have been taken.
    func install(on center: UNUserNotificationCenter) {
        guard center.delegate !== self else { return }
        chain(to: center.delegate)
        center.delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if MacNotificationPayload(userInfo: userInfo) == nil {
            // Not a Conduit notification.
            if let forward, forward.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                forward.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            } else {
                completionHandler()
            }
            return
        }
        let identifier = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
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
        if MacNotificationPayload(userInfo: userInfo) == nil,
           let forward, forward.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            forward.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            return
        }
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor [weak self] in
            done(self?.presentation?(MacNotificationPayload(userInfo: userInfo)) ?? [.banner, .list, .sound])
        }
    }
}
