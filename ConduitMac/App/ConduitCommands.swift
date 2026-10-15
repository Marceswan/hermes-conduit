import AppKit
import SwiftUI

struct ConduitCommands: Commands {
    /// The key Hide / Show Sidebar toggles: the one `MacSplitLayout` reads (D6).
    /// Pinned by MacKeyboardMenuTests.
    static let sidebarVisibleKey = MacSidebarState.defaultsKey

    @ObservedObject var appState: AppState
    @ObservedObject var tabs: MacSessionTabsStore
    @ObservedObject var palette: MacPaletteStore
    @ObservedObject var updater: MacUpdater
    @AppStorage(ConduitCommands.sidebarVisibleKey) private var sidebarVisible = true
    @AppStorage(HoverAccessibilityEngine.highlightDefaultsKey) private var hoverHighlight = true
    /// The sidebar list's rows in display order; nil while no list is mounted.
    @FocusedValue(\.macSessionOrder) private var sessionOrder

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { Task { await appState.createNewSession() } }
                .keyboardShortcut("n", modifiers: .command)
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
        // One contextual Cmd-F: the find bar of a focused message view, else
        // Search Sessions. It sits ahead of Edit > Find on purpose: AppKit stops
        // at the first menu item with a matching key equivalent even when it
        // is disabled, and Find is disabled unless a message view is focused.
        CommandGroup(after: .pasteboard) {
            Button("Search Sessions") { MacKeyboardActions.findOrSearchSessions(window: NSApp.keyWindow) }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
        }
        CommandMenu("Chat") {
            Button("Stop Response") { Task { await appState.cancelCurrent() } }
                .keyboardShortcut(".", modifiers: .command)
        }
        CommandMenu("Go") {
            // Never `.disabled`: a stale disabled item would swallow Cmd-K (see
            // the comment above). The action checks the window and any sheet.
            Button("Command Palette") { MacPaletteActions.toggle(store: palette, window: NSApp.keyWindow) }
                .keyboardShortcut("k", modifiers: .command)
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
            Button("Message Field") { MacKeyboardActions.focusComposer(window: NSApp.keyWindow ?? NSApp.mainWindow) }
                .keyboardShortcut("l", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { MacSidebarState.toggleVisible() }
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
