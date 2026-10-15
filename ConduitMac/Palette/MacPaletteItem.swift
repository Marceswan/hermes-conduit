import Foundation

enum MacPaletteKind: String, CaseIterable {
    case session, slash, profile, model, pane, command
}

/// What running a row does. Equatable so tests assert it directly; the store
/// dispatches it through `MacPaletteCalls` (Task 4).
enum MacPaletteAction: Equatable {
    case openSession(String)
    case runSlash(String)
    case insertSlash(String)
    case switchProfile(String)
    case openModelPicker
    case selectPane(SidebarTab)
    case newChat
    case openSettings
    case toggleSidebar
    case stopResponse
    case searchSessions
    case checkForUpdates
}

struct MacPaletteItem: Identifiable, Equatable {
    /// "kind:rawID", stable across rebuilds (recents key on it).
    let id: String
    let kind: MacPaletteKind
    var title: String
    var subtitle: String = ""
    var keywords: [String] = []
    var isEnabled = true
    var disabledReason: String?
    /// The active profile's check row.
    var isCurrent = false
    var isUnread = false
    var isActiveSession = false
    var lastActivityAt: TimeInterval?
    var action: MacPaletteAction
}

struct MacPaletteSection: Equatable {
    let title: String?
    let items: [MacPaletteItem]
}
