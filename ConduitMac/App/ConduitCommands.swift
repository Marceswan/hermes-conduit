import AppKit
import SwiftUI

struct ConduitCommands: Commands {
    /// The key Hide / Show Sidebar toggles: the one `MacSplitLayout` reads (D6).
    /// Pinned by MacKeyboardMenuTests.
    static let sidebarVisibleKey = MacSidebarState.defaultsKey

    @ObservedObject var appState: AppState
    @AppStorage(ConduitCommands.sidebarVisibleKey) private var sidebarVisible = true
    @AppStorage(HoverAccessibilityEngine.highlightDefaultsKey) private var hoverHighlight = true
    /// The sidebar list's rows in display order; nil while no list is mounted.
    @FocusedValue(\.macSessionOrder) private var sessionOrder

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { Task { await appState.createNewSession() } }
                .keyboardShortcut("n", modifiers: .command)
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
            ForEach(MacSidebarShortcut.allCases) { shortcut in
                Button(shortcut.title) { MacKeyboardActions.selectTab(shortcut.tab, window: NSApp.keyWindow) }
                    .keyboardShortcut(shortcut.key, modifiers: .command)
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
