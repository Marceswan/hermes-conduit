import Foundation

/// The `WindowGroup(for:)` value of a session window (D21). Equal tokens are
/// the same window: SwiftUI focuses the open one instead of opening a second.
struct MacSessionWindowToken: Codable, Hashable {
    var dashboardID: UUID?
    var profile: String
    var sessionID: String
}
