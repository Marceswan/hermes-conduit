import AppKit

/// Whether transport recovery (reconnect cycles and the post-connect sync) may
/// run while Conduit is not the frontmost app. On Mac the process and its
/// gateway socket outlive the window, and the agent activity feed and
/// notifications need the socket back without the user foregrounding the app.
enum MacTransportRecoveryPolicy {
    static var allowsRecoveryWhileInactive = true

    /// Whether a Conduit window is on screen: not hidden, not minimized, not fully covered
    /// (`NSApp.occlusionState`). `AppState.reconnectIsWatched` counts it as someone looking at
    /// Conduit even while another app is active, when SwiftUI reports the scene `.inactive`.
    /// Tests replace `windowIsVisible`.
    @MainActor static let systemWindowIsVisible: () -> Bool = { NSApp.occlusionState.contains(.visible) }
    @MainActor static var windowIsVisible: () -> Bool = MacTransportRecoveryPolicy.systemWindowIsVisible
}
