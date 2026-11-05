import CoreSpotlight
import Foundation

/// Turns the user activity Spotlight launches Conduit with into a chat link (D19).
enum MacSpotlightContinuation {
    enum Outcome: Equatable {
        case open(ConduitAppLink)
        /// A result indexed under another dashboard: nothing opens.
        case foreignDashboard
        /// Not one of ours, or malformed.
        case ignored
    }

    static func outcome(userInfo: [AnyHashable: Any]?, currentDashboardKey: String) -> Outcome {
        guard let raw = userInfo?[CSSearchableItemActivityIdentifier] as? String else { return .ignored }
        return outcome(rawID: raw, currentDashboardKey: currentDashboardKey)
    }

    static func outcome(rawID: String, currentDashboardKey: String) -> Outcome {
        guard let id = MacSpotlightItemID.parse(rawID) else { return .ignored }
        guard id.dashboardKey == currentDashboardKey else { return .foreignDashboard }
        return .open(.session(id: id.sessionID, profile: id.profile))
    }
}

/// Where a Spotlight launch lands, whichever door it came through (D19).
///
/// SwiftUI's `.onContinueUserActivity` may not fire when Spotlight launches the
/// app cold, so `ConduitMacAppDelegate.application(_:continue:)` feeds the same
/// inbox. A launch that arrives before a window has attached its handler is
/// parked and delivered on attach. If both doors fire for one click, the second
/// delivery of the same identifier inside `duplicateWindow` is dropped, so the
/// chat opens once.
@MainActor
final class MacSpotlightInbox {
    static let shared = MacSpotlightInbox()
    /// No one clicks the same result twice this fast; two doors firing for one
    /// click land within milliseconds of each other.
    static let duplicateWindow: TimeInterval = 1.5

    private let now: () -> Date
    private var handler: ((String) -> Void)?
    private var parked: String?
    private var lastRaw: String?
    private var lastAt: Date?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The AppKit door. True when the activity is a Core Spotlight result
    /// (handled or deduplicated), so the delegate can claim it.
    @discardableResult
    func receive(activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType else { return false }
        receive(userInfo: activity.userInfo)
        return true
    }

    /// The SwiftUI door, and the shared path for both.
    func receive(userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        let stamp = now()
        if raw == lastRaw, let lastAt, stamp.timeIntervalSince(lastAt) < Self.duplicateWindow { return }
        lastRaw = raw
        lastAt = stamp
        if let handler { handler(raw) } else { parked = raw }
    }

    /// Installs the window's handler and delivers a launch that arrived first.
    func attach(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        if let raw = parked {
            parked = nil
            handler(raw)
        }
    }

    /// Tests only: forget the handler, any parked launch and the duplicate memory.
    func reset() {
        handler = nil
        parked = nil
        lastRaw = nil
        lastAt = nil
    }
}
