import SwiftUI

enum MacDetailDestination: Equatable {
    case chat, bots, cron, kanban
}

/// Main-area content on Mac. The sidebar tab picker drives which view fills
/// the detail pane; the sidebar itself always lists sessions.
///
/// Chat stays mounted under the other panes (hidden, not removed) so scroll
/// position, the draft, focus and in-flight backfill survive a tab switch.
struct MacDetailRouter<Chat: View>: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(MacSidebarState.tabDefaultsKey) private var selectedTabRaw = SidebarTab.sessions.rawValue
    private let chat: Chat

    init(@ViewBuilder chat: () -> Chat) {
        self.chat = chat()
    }

    static func destination(for tab: SidebarTab) -> MacDetailDestination {
        switch tab {
        case .sessions: return .chat
        case .bots: return .bots
        case .cron: return .cron
        case .kanban: return .kanban
        }
    }

    /// Opening a session or a group-chat room returns the main area to chat.
    /// Programmatic opens (Cmd-N, notification deep links, a Kanban card
    /// opening a session) are user-intended, so they return to chat too (R33).
    static func tabAfterOpening(current: SidebarTab, openedID: String?) -> SidebarTab {
        openedID == nil ? current : .sessions
    }

    private var tab: SidebarTab { SidebarTab.migrated(rawValue: selectedTabRaw) }

    var body: some View {
        let destination = Self.destination(for: tab)
        ZStack {
            chat
                .opacity(destination == .chat ? 1 : 0)
                .allowsHitTesting(destination == .chat)
                .accessibilityHidden(destination != .chat)
            if destination != .chat {
                ZStack {
                    ConduitBackdrop(drifts: true)
                    pane(for: destination)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                .navigationTitle(tab.displayName)
            }
        }
        .onChange(of: appState.activeSessionId) { _, id in
            returnToChat(openedID: id)
        }
        .onChange(of: appState.activeRoomSurface?.room.roomID) { _, id in
            returnToChat(openedID: id)
        }
    }

    @ViewBuilder
    private func pane(for destination: MacDetailDestination) -> some View {
        switch destination {
        case .chat: EmptyView()
        case .bots: BotRosterView()
        case .cron: CronList()
        case .kanban: KanbanView()
        }
    }

    private func returnToChat(openedID: String?) {
        let next = Self.tabAfterOpening(current: tab, openedID: openedID)
        if next != tab { selectedTabRaw = next.rawValue }
    }
}
