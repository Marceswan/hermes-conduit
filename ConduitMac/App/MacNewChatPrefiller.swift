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

    func run(_ text: String) async -> Bool {
        let before = activeSessionId()
        await createNewSession()
        guard let after = activeSessionId(), after != before else { return false }
        prefill(text)
        return true
    }

    static func live(_ appState: AppState) -> MacNewChatPrefiller {
        MacNewChatPrefiller(
            activeSessionId: { [weak appState] in appState?.activeSessionId },
            createNewSession: { [weak appState] in await appState?.createNewSession() },
            prefill: { [weak appState] in appState?.prefillComposer($0) }
        )
    }
}

/// Brings the primary Conduit window forward. Shared by Services and the
/// Shortcuts intents (D19).
enum MacWindowActivation {
    @MainActor
    static func bringConduitForward() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("conduit-primary") ?? false }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}
