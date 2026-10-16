import Foundation

/// Persisted sidebar destinations. The raw-value migration is explicit so an
/// obsolete Capabilities value can never leave the sidebar without a valid tab.
enum SidebarTab: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case bots = "Bots"
    case cron = "Cron"
    case kanban = "Kanban"
    #if os(macOS) // MAC: Home pane (D24); iOS keeps four tabs
    case home = "Home"
    #endif // MAC:

    var id: String { rawValue }

    /// 本地化显示名; rawValue 仅用于持久化
    var displayName: String {
        switch self {
        case .sessions: return AppLocalization.string("Sessions")
        case .bots: return AppLocalization.string("Bots")
        case .cron: return AppLocalization.string("Cron")
        case .kanban: return AppLocalization.string("Kanban")
        #if os(macOS) // MAC: Home pane (D24)
        case .home: return AppLocalization.string("Home")
        #endif // MAC:
        }
    }

    var icon: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .bots: return "person.2"
        case .cron: return "clock"
        case .kanban: return "rectangle.3.group"
        #if os(macOS) // MAC: Home pane (D24)
        case .home: return "house"
        #endif // MAC:
        }
    }

    static func migrated(rawValue: String?) -> SidebarTab {
        guard let rawValue, let value = SidebarTab(rawValue: rawValue) else {
            return .sessions
        }
        return value
    }
}
