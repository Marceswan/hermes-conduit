import AppKit
import SwiftUI

enum MacDetailDestination: Equatable {
    case chat, bots, cron, kanban, home
}

/// Main-area content on Mac. The sidebar tab picker drives which view fills
/// the detail pane; the sidebar itself always lists sessions.
///
/// Chat stays mounted under the other panes (hidden, not removed) so scroll
/// position, the draft and in-flight backfill survive a tab switch. While
/// hidden it contributes no toolbar items, title, composer focus or backdrop
/// animation: upstream chat code reads the route through `MacChatRoute`.
struct MacDetailRouter<Chat: View>: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage private var selectedTabRaw: String
    private let notificationCenter: NotificationCenter
    private let chat: Chat

    /// `defaults` and `notificationCenter` are injectable so tests can host a
    /// router without sharing the tab key or the signal with the live app.
    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        @ViewBuilder chat: () -> Chat
    ) {
        _selectedTabRaw = AppStorage(
            wrappedValue: SidebarTab.sessions.rawValue,
            MacSidebarState.tabDefaultsKey,
            store: defaults
        )
        self.notificationCenter = notificationCenter
        self.chat = chat()
    }

    static func destination(for tab: SidebarTab) -> MacDetailDestination {
        switch tab {
        case .sessions: return .chat
        case .bots: return .bots
        case .cron: return .cron
        case .kanban: return .kanban
        case .home: return .home
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
                .overlay(alignment: .top) { MacChatFindSlot() }   // D23: whole-chat find bar
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
                // The pane's own header names it: on macOS 26+ the toolbar does not show this
                // title (the chat stack removes it, RootView); the Window menu still does.
                .navigationTitle(tab.displayName)
            }
        }
        .onChange(of: destination) { _, new in
            // The hidden chat's composer must not keep first responder.
            if new != .chat { MacChatRoute.resignComposerFocus(in: NSApp.keyWindow) }
        }
        // Explicit opens (row click, Kanban card, deep link), including
        // re-opening the active session, which changes no published state.
        .onReceive(notificationCenter.publisher(for: .macSessionOpenRequested)) { _ in
            returnToChat(openedID: "requested")
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
        case .bots:
            VStack(alignment: .leading, spacing: 12) {
                MacPaneHeader(title: SidebarTab.bots.displayName)
                BotRosterView()
            }
        case .cron: CronList()
        case .kanban: KanbanView()
        case .home: MacHomeView(appState: appState)
        }
    }

    private func returnToChat(openedID: String?) {
        let next = Self.tabAfterOpening(current: tab, openedID: openedID)
        if next != tab { selectedTabRaw = next.rawValue }
    }
}
