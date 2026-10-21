import Foundation

// Mac twin of the sidebar New Chat gate (upstream `canTapNewChat`, AppState.swift); keep in sync (PORTING_LEDGER).
extension AppState {
    /// Whether a caller that creates a chat at once may not do so on Mac. The
    /// Notch menu and Home call `createNewSession()` directly, which is a
    /// no-op without a live client and must not start while a reconcile runs.
    /// The sidebar button does not use this: it calls `startNewChat()`, which
    /// can also queue a chat, so it uses `macNewChatButtonDisabled`.
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
    /// recovery's own create) sets it first.
    static func macNewChatDisabled(
        turnState: TurnState,
        hasSavedCopy: Bool,
        hasLiveGateway: Bool,
        isProfileSwitching: Bool = false
    ) -> Bool {
        turnState == .synchronizing
            || isProfileSwitching
            || (hasSavedCopy && !hasLiveGateway)
    }

    var macNewChatDisabled: Bool {
        Self.macNewChatDisabled(
            turnState: turnState,
            hasSavedCopy: offlineChatPresentation != nil,
            hasLiveGateway: isConnected && !isConnecting && client != nil,
            isProfileSwitching: isProfileSwitching
        )
    }
}

extension AppState {
    /// Whether the sidebar New Chat button is disabled on Mac: upstream's rule
    /// (`canTapNewChat`) plus the one Mac reason below.
    ///
    /// Upstream's rule: New Chat does something now. It starts a chat, has
    /// one wait for the connection (while Conduit connects, or synchronizes),
    /// or shows the chat already on its way. It is off while the app's own
    /// New Chat is creating its chat (`isStartingNewChat`), during a call
    /// (nothing to queue) and during a profile switch.
    ///
    /// Mac reason (the same one `macNewChatDisabled` keeps): the saved copy
    /// has no live gateway to create a chat on, so while it is up and the
    /// client is not live the button queues no chat. A chat that already
    /// shows as pending stays reachable. Once the client is live the copy no
    /// longer blocks the button.
    static func macNewChatButtonDisabled(
        canTapNewChat: Bool,
        showsPendingNewChat: Bool,
        hasSavedCopy: Bool,
        hasLiveGateway: Bool
    ) -> Bool {
        if !canTapNewChat { return true }
        return hasSavedCopy && !hasLiveGateway && !showsPendingNewChat
    }

    var macNewChatButtonDisabled: Bool {
        Self.macNewChatButtonDisabled(
            canTapNewChat: canTapNewChat,
            showsPendingNewChat: showsPendingNewChat,
            hasSavedCopy: offlineChatPresentation != nil,
            hasLiveGateway: isConnected && !isConnecting && client != nil
        )
    }
}
