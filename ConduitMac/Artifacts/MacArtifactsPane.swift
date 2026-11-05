import SwiftUI

/// The Artifacts sidebar pane (D26): what the active profile's chats produced, from every chat.
/// The header, then the search pill (inline: a second `.searchable` crashes NSToolbar, D6), then
/// `MacArtifactsList`. `MacDetailRouter` draws the backdrop and the side padding.
struct MacArtifactsPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""

    init() {}

    var body: some View {
        MacArtifactsList(scope: .profile, chatIsOpen: false, query: query) { item in
            Self.showInChat(item, in: appState)
        }
        .safeAreaInset(edge: .top, spacing: 12) {
            VStack(spacing: 12) {
                MacPaneHeader(title: SidebarTab.artifacts.displayName)
                MacSearchPill(prompt: AppLocalization.string("Search names and chats"), text: $query)
            }
        }
    }

    /// Opens the item's chat and scrolls it to the message the item came from. Opening a session
    /// posts `.macSessionOpenRequested`, which returns the main pane to chat.
    static func showInChat(_ item: ArtifactItem, in appState: AppState) {
        appState.showArtifactInChat(item, chatIsOpen: false)
    }
}
