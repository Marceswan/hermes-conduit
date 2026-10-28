import Foundation
import UserNotifications

/// The notification permission as the Dock count sees it (D31 fix).
///
/// macOS is thought to hide the Dock badge of an app that is registered for notifications without badge
/// authorization (not stated in Apple's documentation: verify on a live Mac, see D31). So Conduit reads
/// `badgeSetting`, tells the user in Settings when badges are not enabled, and asks again once per launch.
/// This type only reads and decides. `MacDockBadge` stays the one writer of the Dock tile.
struct MacBadgePermission: Equatable {
    var status: UNAuthorizationStatus
    var setting: UNNotificationSetting

    static func read(from client: MacNotificationCenterClient) async -> MacBadgePermission {
        let status = await client.authorizationStatus()
        let setting = await client.badgeSetting()
        return MacBadgePermission(status: status, setting: setting)
    }

    /// Notifications are on and badges are not: Conduit has a page in System Settings to send the user to.
    /// Not yet asked (no page) and blocked (the Status row says so, with its own button) get no note.
    func needsNote(showsCount: Bool) -> Bool {
        guard showsCount, setting != .enabled else { return false }
        return status == .authorized || status == .provisional
    }

    /// Only an app that is already authorized asks again, so the request never shows a first prompt.
    /// A badge that reads `notSupported` (never granted) or `disabled` (never granted, or switched off) both ask:
    /// which one macOS reports for an option the app never asked for is not documented.
    func shouldAskAgain(wantsBadge: Bool) -> Bool {
        wantsBadge && status == .authorized && setting != .enabled
    }
}

/// Asks again, at most once per launch, for the full option set (D31 fix), when notifications are already
/// allowed and badges are not enabled. Apple's documentation says a later request does not prompt again and
/// says nothing about options that were not in the first request: the call may change nothing. The note in
/// Settings is the fallback.
@MainActor
final class MacBadgeOptionRequester {
    static let shared = MacBadgeOptionRequester()

    /// True once the one request of this launch ran.
    private(set) var hasAsked = false

    /// Reads the permission. When the rules above say so, asks once and reads again.
    @discardableResult
    func refresh(on client: MacNotificationCenterClient, wantsBadge: Bool) async -> MacBadgePermission {
        let permission = await MacBadgePermission.read(from: client)
        guard !hasAsked, permission.shouldAskAgain(wantsBadge: wantsBadge) else { return permission }
        // Set before the await: a second refresh that lands meanwhile must not ask again.
        hasAsked = true
        macNotificationsLogger.info("Asking again with the badge option (status \(permission.status.rawValue, privacy: .public), badge setting \(permission.setting.rawValue, privacy: .public))")
        _ = await client.requestAuthorization()
        let after = await MacBadgePermission.read(from: client)
        macNotificationsLogger.info("Asked again: status \(after.status.rawValue, privacy: .public), badge setting \(after.setting.rawValue, privacy: .public)")
        return after
    }
}

/// The System Settings page of Conduit's notifications.
enum MacNotificationSettingsLink {
    static let page = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    private static let idCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Conduit's own page when the bundle id is known, the Notifications page otherwise.
    static func url(bundleID: String?) -> URL {
        guard let bundleID, !bundleID.isEmpty,
              let id = bundleID.addingPercentEncoding(withAllowedCharacters: idCharacters),
              let url = URL(string: page + "?id=" + id) else {
            return URL(string: page)!
        }
        return url
    }
}
