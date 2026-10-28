import AppKit

enum NotchMainWindow {
    /// Same route `applicationShouldHandleReopen` uses; the notch panel itself
    /// cannot become main, so `canBecomeMain` picks the real window.
    @MainActor static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

struct NotchActions {
    var openSession: (String) -> Void
    var openPane: (SidebarTab) -> Void
    var newChat: () -> Void
    var newChatEnabled: () -> Bool
    var openConduit: () -> Void

    @MainActor static func selectPane(_ tab: SidebarTab, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
    }

    /// `bringToFront` is a seam: a test must not activate the app.
    @MainActor static func live(
        appState: AppState,
        bringToFront: @escaping @MainActor () -> Void = { NotchMainWindow.bringToFront() }
    ) -> NotchActions {
        NotchActions(
            openSession: { id in
                bringToFront()
                MacActivitySessionTarget.open(id, in: appState)   // resumes the session; adds Conduit as a viewer
            },
            openPane: { tab in
                bringToFront()
                selectPane(tab)
            },
            newChat: {
                guard appState.macCanStartChatAtOnce else { return }
                bringToFront()
                Task { await appState.createNewSession() }
            },
            newChatEnabled: { appState.macCanStartChatAtOnce },
            openConduit: { bringToFront() })
    }
}
