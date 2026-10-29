import Foundation

// Gate for the Mac callers that create a chat at once: the Notch menu (`NotchActions`) and Home
// (`MacHomeBinding`). They call `createNewSession()`, so they show a disabled state while a chat cannot
// start, rather than drop a click. The sidebar New Chat button, Cmd-N, the Cmd-K palette and the chat that
// opens after the last tab closes do not use it: they call `startNewChat()` and follow upstream's
// `canTapNewChat` as it is (Ruling R39), so a chat is queued at a cold launch while Conduit connects, even
// with the saved copy on screen. Keep this gate in step with `createNewSession` (PORTING_LEDGER).
extension AppState {
    /// Whether a caller that creates a chat at once may not do so on Mac. The
    /// Notch menu and Home call `createNewSession()` directly, which is a
    /// no-op without a live client and must not start while a reconcile runs
    /// or while the app's own New Chat is creating its chat. They cannot
    /// queue a chat as `startNewChat()` does, so they need this stricter gate.
    ///
    /// Upstream disabled New Chat while the read-only saved copy is up, on the
    /// premise that the copy has no live gateway to create a chat on. That
    /// premise only holds while there is no live client. Once the client is
    /// connected (the server answered, e.g. "session not found" for the
    /// restored conversation) a new chat can be created, so the saved copy
    /// must not block it. `createNewSession` enforces the same live-client
    /// requirement, and refuses during a workspace switch, so this is true
    /// then too.
    ///
    /// Reconciliation in flight is covered by `.synchronizing`: every path
    /// that reconciles (resume, `createNewSession`, the missing-session
    /// recovery's own create) sets it first. `startNewChat()` sets
    /// `isStartingNewChat` before the task that sets `.synchronizing` runs,
    /// so the flag closes the gap between the two.
    static func macNewChatDisabled(
        turnState: TurnState,
        hasSavedCopy: Bool,
        hasLiveGateway: Bool,
        isProfileSwitching: Bool = false,
        isStartingNewChat: Bool = false
    ) -> Bool {
        isStartingNewChat
            || turnState == .synchronizing
            || isProfileSwitching
            || (hasSavedCopy && !hasLiveGateway)
    }

    /// A connected client that is not mid-connect: the rule `createNewSession` enforces, and the one
    /// Home uses for its New Chat button (`MacHomeBinding`). The connected flag without a client is
    /// not a live gateway.
    var macHasLiveGateway: Bool {
        isConnected && !isConnecting && client != nil
    }

    /// Whether a caller that creates a chat at once can do it now: not blocked by `macNewChatDisabled` and a
    /// live gateway. `createNewSession()` returns at once without one, so the Notch offers its New Chat only
    /// then, as Home does (`MacHomeBinding`: `!macNewChatDisabled && macHasLiveGateway`).
    var macCanStartChatAtOnce: Bool {
        !macNewChatDisabled && macHasLiveGateway
    }

    var macNewChatDisabled: Bool {
        Self.macNewChatDisabled(
            turnState: turnState,
            hasSavedCopy: offlineChatPresentation != nil,
            hasLiveGateway: macHasLiveGateway,
            isProfileSwitching: isProfileSwitching,
            isStartingNewChat: isStartingNewChat
        )
    }
}
