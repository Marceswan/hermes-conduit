import SwiftUI

/// Applies a parked Service request once Hermes is connected: bring the
/// window forward, start a new chat, put the text in its composer (D19).
struct MacServiceRouting: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var inbox: MacServiceInbox

    @MainActor
    init(appState: AppState, inbox: MacServiceInbox) {
        self.appState = appState
        self.inbox = inbox
    }

    func body(content: Content) -> some View {
        content
            .task {
                let state = appState
                inbox.install(scope: { [weak state] in
                    MacServiceInbox.scope(dashboardID: state?.activeDashboardID, profile: state?.activeProfile ?? "")
                })
            }
            .task(id: "\(inbox.revision):\(appState.macParkedRequestReadinessKey)") {
                guard appState.macCanApplyParkedRequest, let text = inbox.take() else { return }
                MacWindowActivation.bringConduitForward()
                _ = await MacNewChatPrefiller.live(appState).run(text)
            }
    }
}

extension View {
    @MainActor func macServiceRouting(appState: AppState) -> some View {
        modifier(MacServiceRouting(appState: appState, inbox: .shared))
    }
}
