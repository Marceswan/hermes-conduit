import AppKit
import SwiftUI

struct ConduitCommands: Commands {
    /// The key Hide / Show Sidebar toggles: the one `MacSplitLayout` reads (D6).
    /// Pinned by MacKeyboardMenuTests.
    static let sidebarVisibleKey = MacSidebarState.defaultsKey

    @ObservedObject var appState: AppState
    @ObservedObject var tabs: MacSessionTabsStore
    /// Pin state of the notch agent status panel (D16); drives Show / Hide Agent Status.
    @ObservedObject var notch: NotchStatusController
    /// Not observed: the palette publishes on every keystroke, and observing
    /// it here would rebuild the whole menu bar each time.
    let palette: MacPaletteStore
    @ObservedObject var updater: MacUpdater
    @ObservedObject var quickAsk: MacQuickAskHotKeyManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MacQuickAskHotKeyManager.enabledKey) private var quickAskEnabled = true
    @AppStorage(ConduitCommands.sidebarVisibleKey) private var sidebarVisible = true
    @AppStorage(HoverAccessibilityEngine.highlightDefaultsKey) private var hoverHighlight = true
    /// The sidebar list's rows in display order; nil while no list is mounted.
    @FocusedValue(\.macSessionOrder) private var sessionOrder

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        // There is no `Settings` scene (Settings is MainView's sheet, which needs
        // RootView-owned closures), so the app menu has no "Settings..." until
        // this adds it. The D18 observer in RootView does the presenting (D22).
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { MacAppActions.openSettings(window: NSApp.keyWindow) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            // With the Quick Ask panel key, Cmd-N is the panel's "new conversation",
            // never a new chat in the main window (see `MacQuickAskController.isPanelKey`).
            Button("New Chat") {
                if MacQuickAskController.shared.isPanelKey {
                    MacQuickAskController.shared.newConversation()
                } else {
                    // From a session window the new chat is the main window's: it comes forward first.
                    MacAppActions.newChat(window: NSApp.keyWindow) { Task { await appState.createNewSession() } }
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            // A popped-out session (D21): the main window's active tab moves to its own window.
            Button("Open Session in New Window") {
                MacSessionTabsActions.popOutActive(
                    store: tabs, window: NSApp.keyWindow,
                    canPopOut: { MacSessionWindows.canPopOut($0, catalog: appState.sessions) }
                ) { sessionID in
                    MacSessionWindows.open(sessionID, appState: appState) { openWindow(value: $0) }
                }
            }
            .keyboardShortcut("n", modifiers: [.option, .command])
            // Close Tab owns Cmd-W ahead of File > Close; in any other window
            // it performs that window's ordinary close (D11).
            Button("Close Tab") { MacSessionTabsActions.closeTab(store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Closed Tab") { MacSessionTabsActions.reopen(store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("t", modifiers: [.shift, .command])
        }
        // No item here is disabled for a sheet: the menu is not rebuilt when a
        // sheet opens or closes, so a stale disabled item would swallow its key
        // (AppKit stops at the first match). The actions check for a sheet
        // when they run instead (`MacKeyboardActions.commandsBlocked`).
        // One contextual Cmd-F (D10, D23): the whole-chat find bar when focus is
        // in the chat, Search Sessions when focus is in the sidebar. Cmd-G and
        // Cmd-Shift-G step through the hits. All three sit ahead of Edit > Find
        // on purpose: AppKit stops at the first menu item with a matching key
        // equivalent even when it is disabled, and the system Find items are
        // disabled unless a find-capable text view is focused. In a session
        // window (D21) they fall back to the focused message view's own find bar.
        CommandGroup(after: .pasteboard) {
            Button("Find in Chat") { MacKeyboardActions.findOrSearchSessions(window: NSApp.keyWindow) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { MacChatFindActions.next(window: NSApp.keyWindow) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { MacChatFindActions.previous(window: NSApp.keyWindow) }
                .keyboardShortcut("g", modifiers: [.shift, .command])
            // No key equivalent: the way in when Cmd-F lands on the chat.
            Button("Search Sessions") { MacKeyboardActions.searchSessions(window: NSApp.keyWindow) }
            Divider()
        }
        CommandMenu("Chat") {
            // With the Quick Ask panel key, Cmd-. stops only the Quick Ask turn.
            Button("Stop Response") {
                if MacQuickAskController.shared.isPanelKey {
                    MacQuickAskController.shared.stop()
                } else {
                    // From a session window the stop belongs to that window's turn (D21).
                    MacSessionWindows.stopResponse(window: NSApp.keyWindow) {
                        Task { await appState.cancelCurrent() }
                    }
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            Button("Ask About Window\u{2026}") {
                Task { await MacAskAboutWindow.run(appState: appState, window: NSApp.keyWindow) }
            }
            .keyboardShortcut("w", modifiers: [.shift, .command])
            Divider()
            // No key equivalent (the global hotkey is the shortcut) and never
            // `.disabled`: this is the way in when the hotkey could not register.
            Button("Quick Ask") { MacQuickAskController.shared.show() }
            Toggle("Quick Ask Shortcut", isOn: $quickAskEnabled)
                .onChange(of: quickAskEnabled) { _, _ in quickAsk.refresh() }
            if let message = quickAsk.unavailableMessage {
                Text(message)
            }
        }
        CommandMenu("Go") {
            // Never `.disabled`: a stale disabled item would swallow Cmd-K (see
            // the comment above). The action checks the window and any sheet.
            Button("Command Palette") { MacPaletteActions.toggle(store: palette, window: NSApp.keyWindow) }
                .keyboardShortcut("k", modifiers: .command)
            // Opens the saved-dashboards sheet hosted in ConduitMacApp (D22). Never
            // `.disabled`: the action checks the window and any sheet.
            Button("Switch Dashboard\u{2026}") { MacAppActions.switchDashboard(window: NSApp.keyWindow) }
                .keyboardShortcut("d", modifiers: [.shift, .command])
            Divider()
            ForEach(1...8, id: \.self) { n in
                Button("Tab \(n)") { MacSessionTabsActions.selectShortcut(n, store: tabs, window: NSApp.keyWindow) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("Last Tab") { MacSessionTabsActions.selectShortcut(9, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("9", modifiers: .command)
            Button("Next Tab") { MacSessionTabsActions.selectNeighbor(.next, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("]", modifiers: [.shift, .command])
            Button("Previous Tab") { MacSessionTabsActions.selectNeighbor(.previous, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("[", modifiers: [.shift, .command])
            Button("Show Next Tab") { MacSessionTabsActions.selectNeighbor(.next, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { MacSessionTabsActions.selectNeighbor(.previous, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(MacSidebarShortcut.allCases) { shortcut in
                Button(shortcut.title) { MacKeyboardActions.selectTab(shortcut.tab, window: NSApp.keyWindow) }
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            }
            Divider()
            Button("Previous Session") { open(.previous) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(neighbor(.previous) == nil)
            Button("Next Session") { open(.next) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(neighbor(.next) == nil)
            // The same two commands on the arrow keys, listed by direction.
            Button("Session Above") { open(.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(neighbor(.previous) == nil)
            Button("Session Below") { open(.next) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(neighbor(.next) == nil)
            Divider()
            // Notch agent status (D16): no key equivalent, nothing to clash with.
            Button(notch.isCommandPinned ? AppLocalization.string("Hide Agent Status") : AppLocalization.string("Show Agent Status")) { notch.toggleCommandPin() }
            Button("Reset Agent Status Position") { notch.resetPosition() }
            Divider()
            Button("Message Field") { MacKeyboardActions.focusComposer(window: NSApp.keyWindow ?? NSApp.mainWindow) }
                .keyboardShortcut("l", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { MacKeyboardActions.toggleSidebar(window: NSApp.keyWindow) }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Toggle("Highlight Controls on Hover", isOn: $hoverHighlight)
        }
        TextEditingCommands()
    }

    private func neighbor(_ direction: MacSessionNavigation.Direction) -> String? {
        guard let sessionOrder else { return nil }
        return MacSessionNavigation.neighbor(of: appState.activeSessionId, in: sessionOrder, direction: direction)
    }

    private func open(_ direction: MacSessionNavigation.Direction) {
        MacKeyboardActions.openNeighbor(direction, order: sessionOrder, activeID: appState.activeSessionId, window: NSApp.keyWindow) { id in
            appState.dismissSidebarDrawer()
            appState.requestOpenSession(id)
        }
    }
}
