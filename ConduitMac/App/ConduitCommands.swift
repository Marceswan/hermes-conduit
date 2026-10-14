import AppKit
import SwiftUI

struct ConduitCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage("conduit.ipadPersistentSidebar") private var persistentSidebar = true
    @AppStorage(HoverAccessibilityEngine.highlightDefaultsKey) private var hoverHighlight = true
    /// The sidebar list's rows in display order; nil while no list is mounted.
    @FocusedValue(\.macSessionOrder) private var sessionOrder

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { Task { await appState.createNewSession() } }
                .keyboardShortcut("n", modifiers: .command)
        }
        // Cmd-F sits ahead of Edit > Find on purpose: AppKit stops at the
        // first menu item with a matching key equivalent even when it is
        // disabled, and Find is disabled unless a message view is focused.
        CommandGroup(after: .pasteboard) {
            Button("Search Sessions") { MacKeyboardActions.focusSessionSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
        }
        CommandMenu("Chat") {
            Button("Stop Response") { Task { await appState.cancelCurrent() } }
                .keyboardShortcut(".", modifiers: .command)
        }
        CommandMenu("Go") {
            ForEach(MacSidebarShortcut.allCases) { shortcut in
                Button(shortcut.title) { MacKeyboardActions.selectTab(shortcut.tab) }
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
            Button("Message Field") { MacKeyboardActions.focusComposer(window: NSApp.keyWindow) }
                .keyboardShortcut("l", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(persistentSidebar ? "Hide Sidebar" : "Show Sidebar") { persistentSidebar.toggle() }
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
        MacKeyboardActions.openNeighbor(direction, order: sessionOrder, activeID: appState.activeSessionId) { id in
            appState.dismissSidebarDrawer()
            appState.requestOpenSession(id)
        }
    }
}
