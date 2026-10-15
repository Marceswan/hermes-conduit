import Foundation

/// Whether transport recovery (reconnect cycles and the post-connect sync) may
/// run while Conduit is not the frontmost app. On Mac the process and its
/// gateway socket outlive the window, and the agent activity feed and
/// notifications need the socket back without the user foregrounding the app.
enum MacTransportRecoveryPolicy {
    static var allowsRecoveryWhileInactive = true
}
