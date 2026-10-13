import Foundation

extension AppState {
    /// Whether the sidebar New Chat button is disabled on Mac.
    ///
    /// Upstream disables it while the read-only saved copy is up, on the
    /// premise that the copy has no live gateway to create a chat on. That
    /// premise only holds while there is no live client. Once the client is
    /// connected (the server answered, e.g. "session not found" for the
    /// restored conversation) a new chat can be created, so the saved copy
    /// must not block it. `createNewSession` enforces the same live-client
    /// requirement.
    static func macNewChatDisabled(
        turnState: TurnState,
        hasSavedCopy: Bool,
        hasLiveGateway: Bool
    ) -> Bool {
        turnState == .synchronizing || (hasSavedCopy && !hasLiveGateway)
    }

    var macNewChatDisabled: Bool {
        Self.macNewChatDisabled(
            turnState: turnState,
            hasSavedCopy: offlineChatPresentation != nil,
            hasLiveGateway: isConnected && !isConnecting && client != nil
        )
    }
}
