import SwiftUI

struct ConduitCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage("conduit.ipadPersistentSidebar") private var persistentSidebar = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { Task { await appState.createNewSession() } }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Chat") {
            Button("Stop Response") { Task { await appState.cancelCurrent() } }
                .keyboardShortcut(".", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(persistentSidebar ? "Hide Sidebar" : "Show Sidebar") { persistentSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        TextEditingCommands()
    }
}
