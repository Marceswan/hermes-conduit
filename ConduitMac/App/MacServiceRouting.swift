import SwiftUI

/// Applies a parked Service request once Hermes is connected: bring the
/// window forward, start a new chat, put the text in its composer (D19).
struct MacServiceRouting: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var inbox: MacServiceInbox

    init(appState: AppState, inbox: MacServiceInbox = .shared) {
        self.appState = appState
        self.inbox = inbox
    }

    func body(content: Content) -> some View {
        content
            .task {
                inbox.install(scope: { [weak appState] in
                    MacServiceInbox.scope(dashboardID: appState?.activeDashboardID, profile: appState?.activeProfile ?? "")
                })
            }
            .task(id: "\(inbox.revision):\(appState.isConnected)") {
                guard appState.isConnected, let text = inbox.take() else { return }
                MacWindowActivation.bringConduitForward()
                _ = await MacNewChatPrefiller.live(appState).run(text)
            }
    }
}

extension View {
    func macServiceRouting(appState: AppState) -> some View {
        modifier(MacServiceRouting(appState: appState))
    }
}
