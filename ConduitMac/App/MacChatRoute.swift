import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by `AppState.requestOpenSession` (MAC-tagged line) on every
    /// explicit session open, including re-opening the already-active one,
    /// which changes no published state. The router returns to chat on it.
    static let macSessionOpenRequested = Notification.Name("conduit.mac.sessionOpenRequested")
}

/// Route-aware chrome for the chat that `MacDetailRouter` keeps mounted but
/// hidden under Bots / Cron / Kanban. Upstream chat code reads the tab key
/// (`MacSidebarState.tabDefaultsKey`) through these helpers, so a hidden chat
/// contributes no window-toolbar items, title, focus or animation (D6).
enum MacChatRoute {
    static func isChatActive(tabRaw: String?) -> Bool {
        SidebarTab.migrated(rawValue: tabRaw) == .sessions
    }

    /// Window title the chat's NavigationStack applies. Empty while chat is
    /// shown (the session tab strip is the title); the pane name otherwise, so
    /// the hidden stack cannot override the router's title. On macOS 26 and
    /// later the toolbar does not display it (`MacPaneTitle`); the window keeps it
    /// for the Window menu.
    static func navigationTitle(tabRaw: String?) -> String {
        isChatActive(tabRaw: tabRaw) ? "" : SidebarTab.migrated(rawValue: tabRaw).displayName
    }

    /// True while a pane other than chat is shown: the toolbar hides the title.
    static func hidesToolbarTitle(tabRaw: String?) -> Bool { !isChatActive(tabRaw: tabRaw) }

    /// The hidden chat's composer must not keep first responder: keystrokes on
    /// another pane would land in an invisible text view. The focus is held on
    /// the composer and restored when chat returns (`restoreFocusIfHeld`).
    /// Returns true when it resigned. Other responders (sidebar search, pane fields) are untouched.
    @discardableResult
    static func resignComposerFocus(in window: NSWindow?) -> Bool {
        guard let window, let composer = window.firstResponder as? ComposerTextView else { return false }
        composer.resignForRoute()
        return window.firstResponder !== composer
    }
}
