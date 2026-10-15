import AppKit
import Foundation

extension MacPaletteSnapshot {
    /// What the palette reads from AppState. Sessions come from
    /// `activeProfileSessions`, the sidebar's own source (it filters other
    /// profiles' rows and bot chats); unread comes from `isSessionUnread`
    /// because `SessionSummary.isUnread` is optional and not authoritative.
    @MainActor
    static func make(from appState: AppState, defaults: UserDefaults = .standard) -> MacPaletteSnapshot {
        let sessions = appState.activeProfileSessions.filter { !$0.isArchived }
        return MacPaletteSnapshot(
            sessions: sessions,
            unreadSessionIDs: Set(sessions.filter { appState.isSessionUnread($0) }.map(\.id)),
            activeSessionID: appState.activeSessionId,
            slashCommands: appState.slashCommands,
            profiles: appState.profiles,
            activeProfile: appState.activeProfile,
            isTurnRunning: appState.isBusy,
            sidebarVisible: defaults.object(forKey: MacSidebarState.defaultsKey) as? Bool ?? true,
            canCheckForUpdates: MacUpdater.shared.canCheckForUpdates,
            dashboardID: appState.activeDashboardID
        )
    }
}

extension MacPaletteCalls {
    @MainActor
    static func live(appState: AppState, defaults: UserDefaults = .standard) -> MacPaletteCalls {
        var calls = MacPaletteCalls()
        calls.openSession = { [weak appState] id in
            appState?.dismissSidebarDrawer()
            _ = appState?.requestOpenSession(id)
        }
        // A slash command's output lands in the chat transcript and an inserted
        // one in its composer; both live in the chat pane, which stays mounted
        // (hidden) under Bots / Cron / Kanban, so bring it back first.
        calls.runSlash = { [weak appState] name in
            MacKeyboardActions.selectTab(.sessions, window: nil, defaults: defaults)
            await appState?.executeSlashCommand("/" + name)
        }
        // prefillComposer replaces the draft and focuses the composer; the
        // store has already asked the user when the draft held text.
        calls.insertSlash = { [weak appState] name in
            MacKeyboardActions.selectTab(.sessions, window: nil, defaults: defaults)
            appState?.prefillComposer("/" + name + " ")
        }
        calls.draftText = { MacPaletteDraft.composerText(in: NSApp.keyWindow ?? NSApp.mainWindow) }
        calls.switchProfile = { [weak appState] name in await appState?.switchProfile(to: name) }
        calls.openModelPicker = { [weak appState] in appState?.showModelPicker = true }
        calls.selectPane = { tab in MacKeyboardActions.selectTab(tab, window: nil, defaults: defaults) }
        calls.newChat = { [weak appState] in Task { await appState?.createNewSession() } }
        calls.openSettings = { NotificationCenter.default.post(name: .macOpenSettingsRequested, object: nil) }
        calls.toggleSidebar = { MacSidebarState.toggleVisible() }
        calls.stopResponse = { [weak appState] in Task { _ = await appState?.cancelCurrent() } }
        calls.searchSessions = { MacKeyboardActions.focusSessionSearch() }
        calls.checkForUpdates = { MacUpdater.shared.checkForUpdates() }
        return calls
    }
}

/// Reads the composer's live text (the draft store only holds what the
/// composer last saved, on a chat or room change).
enum MacPaletteDraft {
    @MainActor
    static func composerText(in window: NSWindow?) -> String {
        guard let root = window?.contentView else { return "" }
        return composer(in: root)?.string ?? ""
    }

    @MainActor
    private static func composer(in view: NSView) -> ComposerTextView? {
        if let composer = view as? ComposerTextView { return composer }
        for child in view.subviews {
            if let found = composer(in: child) { return found }
        }
        return nil
    }
}

extension MacPaletteStore {
    /// Idempotent; the app calls it once the window appears.
    func bind(to appState: AppState) {
        guard !isBound else { return }
        isBound = true
        snapshot = { [weak appState] in appState.map { MacPaletteSnapshot.make(from: $0) } ?? .empty }
        calls = .live(appState: appState)
    }
}
