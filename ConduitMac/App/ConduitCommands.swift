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
        // One contextual Cmd-F: the find bar of a focused message view, else
        // Search Sessions. It sits ahead of Edit > Find on purpose: AppKit stops
        // at the first menu item with a matching key equivalent even when it
        // is disabled, and Find is disabled unless a message view is focused.
        CommandGroup(after: .pasteboard) {
            Button("Search Sessions") { MacKeyboardActions.findOrSearchSessions(window: NSApp.keyWindow) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(blocked)
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
                    .disabled(blocked)
            }
            Divider()
            Button("Previous Session") { open(.previous) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(blocked || neighbor(.previous) == nil)
            Button("Next Session") { open(.next) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(blocked || neighbor(.next) == nil)
            // The same two commands on the arrow keys, listed by direction.
            Button("Session Above") { open(.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(blocked || neighbor(.previous) == nil)
            Button("Session Below") { open(.next) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(blocked || neighbor(.next) == nil)
            Divider()
            Button("Message Field") { MacKeyboardActions.focusComposer(window: NSApp.keyWindow ?? NSApp.mainWindow) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(blocked)
        }
        CommandGroup(after: .sidebar) {
            Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Toggle("Highlight Controls on Hover", isOn: $hoverHighlight)
        }
        TextEditingCommands()
    }

    /// A sheet is up on the key window: the commands would act behind it. The
    /// actions check again when they run, since the menu is not rebuilt on a
    /// sheet change.
    private var blocked: Bool { MacKeyboardActions.commandsBlocked(by: NSApp.keyWindow) }

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
