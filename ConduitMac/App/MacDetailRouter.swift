import SwiftUI

enum MacDetailDestination: Equatable {
    case chat, bots, cron, kanban
}

/// Main-area content on Mac. The sidebar tab picker drives which view fills
/// the detail pane; the sidebar itself always lists sessions.
struct MacDetailRouter<Chat: View>: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("conduit.sidebarTab") private var selectedTabRaw = SidebarTab.sessions.rawValue
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
    static func tabAfterOpening(current: SidebarTab, openedSessionId: String?) -> SidebarTab {
        openedSessionId == nil ? current : .sessions
    }

    var body: some View {
        Group {
            switch Self.destination(for: SidebarTab.migrated(rawValue: selectedTabRaw)) {
            case .chat:
                chat
            case .bots:
                BotRosterView()
            case .cron:
                CronList()
            case .kanban:
                KanbanView()
            }
        }
        .onChange(of: appState.activeSessionId) { _, id in
            returnToChat(openedId: id)
        }
        .onChange(of: appState.activeRoomSurface?.room.roomID) { _, id in
            returnToChat(openedId: id)
        }
    }

    private func returnToChat(openedId: String?) {
        let current = SidebarTab.migrated(rawValue: selectedTabRaw)
        let next = Self.tabAfterOpening(current: current, openedSessionId: openedId)
        if next != current { selectedTabRaw = next.rawValue }
    }
}
