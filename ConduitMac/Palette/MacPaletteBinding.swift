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
    static func live(appState: AppState) -> MacPaletteCalls {
        var calls = MacPaletteCalls()
        calls.openSession = { [weak appState] id in
            appState?.dismissSidebarDrawer()
            _ = appState?.requestOpenSession(id)
        }
        calls.runSlash = { [weak appState] name in await appState?.executeSlashCommand("/" + name) }
        // prefillComposer replaces the draft and focuses the composer.
        calls.insertSlash = { [weak appState] name in appState?.prefillComposer("/" + name + " ") }
        calls.switchProfile = { [weak appState] name in await appState?.switchProfile(to: name) }
        calls.openModelPicker = { [weak appState] in appState?.showModelPicker = true }
        calls.selectPane = { tab in MacKeyboardActions.selectTab(tab, window: nil) }
        calls.newChat = { [weak appState] in Task { await appState?.createNewSession() } }
        calls.openSettings = { NotificationCenter.default.post(name: .macOpenSettingsRequested, object: nil) }
        calls.toggleSidebar = { MacSidebarState.toggleVisible() }
        calls.stopResponse = { [weak appState] in Task { _ = await appState?.cancelCurrent() } }
        calls.searchSessions = { MacKeyboardActions.focusSessionSearch() }
        calls.checkForUpdates = { MacUpdater.shared.checkForUpdates() }
        return calls
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
