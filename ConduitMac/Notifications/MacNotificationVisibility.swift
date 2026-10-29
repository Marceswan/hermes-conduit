import AppKit
import UserNotifications

enum MacNotificationVisibilityRules {
    static func evaluate(
        appIsActive: Bool, windowIsKey: Bool, windowIsVisible: Bool, hasAttachedSheet: Bool,
        chatTabShowing: Bool, roomShowing: Bool, activeSessionIDs: Set<String>, session: MacNotificationSession
    ) -> MacNotificationVisibility {
        MacNotificationVisibility(
            appIsActive: appIsActive,
            mainWindowKeyAndVisible: windowIsKey && windowIsVisible,
            chatSurfaceShowing: chatTabShowing && !roomShowing && !hasAttachedSheet,
            sessionIsActive: !activeSessionIDs.isDisjoint(with: session.allIDs)
        )
    }
}

enum MacNotificationPresentation {
    static func options(for visibility: MacNotificationVisibility, sound: Bool) -> UNNotificationPresentationOptions {
        if MacNotificationPolicy.shouldSuppress(visibility) { return [] }
        return sound ? [.banner, .list, .sound] : [.banner, .list]
    }
}

@MainActor
enum MacNotificationVisibilityProvider {
    /// NSApp.isActive plus the key window, never scenePhase (PLAN2_INPUTS).
    static func current(for session: MacNotificationSession, appState: AppState, defaults: UserDefaults = .standard) -> MacNotificationVisibility {
        let window = NSApp.windows.first { MacSessionTabsActions.isMainChatWindow($0) }
        return MacNotificationVisibilityRules.evaluate(
            appIsActive: NSApp.isActive,
            windowIsKey: window?.isKeyWindow ?? false,
            windowIsVisible: (window?.occlusionState.contains(.visible) ?? false) && window?.isMiniaturized == false,
            hasAttachedSheet: window?.attachedSheet != nil,
            chatTabShowing: MacChatRoute.isChatActive(tabRaw: defaults.string(forKey: MacSidebarState.tabDefaultsKey)),
            roomShowing: appState.activeRoomSurface != nil,
            activeSessionIDs: appState.activeSessionId.map { [$0] } ?? [],
            session: session
        )
    }
}
