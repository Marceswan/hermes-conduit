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
        guard let raw = userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = MacSpotlightItemID.parse(raw) else { return .ignored }
        guard id.dashboardKey == currentDashboardKey else { return .foreignDashboard }
        return .open(.session(id: id.sessionID, profile: id.profile))
    }
}
