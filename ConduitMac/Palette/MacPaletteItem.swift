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

/// A second step the palette asks for before an action that is hard to undo
/// runs (D18 review round 1). The palette stays open and shows it in place of
/// the list; Return confirms, Esc goes back.
struct MacPaletteConfirmation: Equatable {
    var title: String
    var message: String
    var confirmTitle: String
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
    /// Set for rows that always ask first. Profile switches during a turn and
    /// draft replacement depend on live state and are decided in the store.
    var confirmation: MacPaletteConfirmation?
    var action: MacPaletteAction
}

struct MacPaletteSection: Equatable {
    let title: String?
    let items: [MacPaletteItem]
}
