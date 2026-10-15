import SwiftUI

/// Applies a parked intent request once Hermes is connected (D19).
struct MacIntentRouting: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var inbox: MacIntentInbox

    @MainActor
    init(appState: AppState, inbox: MacIntentInbox) {
        self.appState = appState
        self.inbox = inbox
    }

    func body(content: Content) -> some View {
        content
            .task { MacIntentDataSource.shared.bind(to: appState) }
            .task(id: "\(inbox.revision):\(appState.isConnected)") {
                guard appState.isConnected, let request = inbox.take() else { return }
                MacWindowActivation.bringConduitForward()
                await MacIntentRouting.apply(request, appState: appState)
            }
    }

    @MainActor
    static func apply(_ request: MacIntentRequest, appState: AppState) async {
        switch request {
        case .newChat(let profile, let message):
            if let profile, profile != appState.activeProfile {
                await appState.switchProfile(to: profile)
                guard appState.activeProfile == profile else { return }
            }
            if let message, !message.isEmpty {
                _ = await MacNewChatPrefiller.live(appState).run(message)
            } else {
                await appState.createNewSession()
            }
        case .openSession(let id, let profile):
            appState.openAppLink(.session(id: id, profile: profile))
        }
    }
}

extension View {
    @MainActor func macIntentRouting(appState: AppState) -> some View {
        modifier(MacIntentRouting(appState: appState, inbox: .shared))
    }
}
