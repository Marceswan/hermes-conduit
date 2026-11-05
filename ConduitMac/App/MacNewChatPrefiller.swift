import AppKit
import Foundation

/// Starts a new chat and puts text in its composer without sending it (D19).
/// Prefill keys the draft on the active session, so it runs only after the
/// new session is active. A refused create (disconnected, connecting, profile
/// switching) leaves the active chat alone.
@MainActor
struct MacNewChatPrefiller {
    var activeSessionId: () -> String?
    var createNewSession: () async -> Void
    var prefill: (String) -> Void
    /// False when the chat that is open now already holds a draft. The create
    /// awaits the gateway, so the user may have opened another chat meanwhile;
    /// a prefill replaces the composer text and must never eat their draft.
    var activeDraftIsEmpty: () -> Bool = { true }

    func run(_ text: String) async -> Bool {
        let before = activeSessionId()
        await createNewSession()
        guard let after = activeSessionId(), after != before else { return false }
        guard activeDraftIsEmpty() else { return false }
        prefill(text)
        return true
    }

    static func live(_ appState: AppState) -> MacNewChatPrefiller {
        MacNewChatPrefiller(
            activeSessionId: { [weak appState] in appState?.activeSessionId },
            createNewSession: { [weak appState] in await appState?.createNewSession() },
            prefill: { [weak appState] in appState?.prefillComposer($0) },
            activeDraftIsEmpty: { [weak appState] in
                guard let appState else { return false }
                let key = ComposerBar.composerDraftKey(for: appState.activeSessionId, profile: appState.activeProfile)
                return appState.composerDraftStore.draft(for: key).text.isEmpty
            }
        )
    }
}

extension AppState {
    /// `createNewSession` refuses while connecting or switching workspace, so
    /// a parked Service or Shortcuts request waits for both, not just
    /// `isConnected`: a refused create would consume the request for nothing.
    var macCanApplyParkedRequest: Bool {
        Self.macCanApplyParkedRequest(isConnected: isConnected, isConnecting: isConnecting, isProfileSwitching: isProfileSwitching)
    }

    static func macCanApplyParkedRequest(isConnected: Bool, isConnecting: Bool, isProfileSwitching: Bool) -> Bool {
        isConnected && !isConnecting && !isProfileSwitching
    }

    /// Task id for the routing modifiers: changes when readiness does.
    var macParkedRequestReadinessKey: String { "\(isConnected):\(isConnecting):\(isProfileSwitching)" }
}

/// Brings the primary Conduit window forward. Shared by Services and the
/// Shortcuts intents (D19).
enum MacWindowActivation {
    @MainActor
    static func bringConduitForward() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { MacPrimaryWindow.isPrimary($0) }
        // Closed while a session window (D21) stayed open: the request is waiting for a main window.
        guard let window else { MacPrimaryWindowOpener.shared.open(); return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
