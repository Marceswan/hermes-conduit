import AppKit
import SwiftUI

/// Opening session windows (D21) and the scene's content.
@MainActor
enum MacSessionWindows {
    static let sceneID = "conduit-session"
    /// How long a requested window may take to appear before its slot is given back.
    static let defaultGraceDelay: Duration = .seconds(10)

    static func isSessionWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix(sceneID) ?? false
    }

    static func token(for sessionID: String, appState: AppState) -> MacSessionWindowToken {
        MacSessionWindowToken(dashboardID: appState.activeDashboardID, profile: appState.activeProfile,
                              sessionID: MacQuickAskController.openableID(sessionID, in: appState.sessions))
    }

    /// False at the cap (and it beeps). Opens or focuses the window. If the window has
    /// not appeared once `graceDelay` has passed, its request is released.
    @discardableResult
    static func open(_ sessionID: String, appState: AppState, registry: MacSessionWindowRegistry? = nil,
                     graceDelay: Duration = defaultGraceDelay,
                     openWindow: (MacSessionWindowToken) -> Void) -> Bool {
        let registry = registry ?? .shared
        let token = token(for: sessionID, appState: appState)
        guard registry.request(token) else {
            NSSound.beep()
            return false
        }
        openWindow(token)
        Task { @MainActor in
            try? await Task.sleep(for: graceDelay)
            registry.releaseIfUnappeared(token)
        }
        return true
    }
}

/// The `WindowGroup(for:)` content. Shares the main window's look (locale,
/// tint, colour scheme) but not `rootContent`: that claims external URL
/// events (`handlesExternalEvents`), which must stay with the main window.
struct MacSessionWindowScene: View {
    let token: MacSessionWindowToken?
    @ObservedObject private var appState = AppStateRuntimeRegistry.shared.appState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @StateObject private var holder = Holder()
    @Environment(\.dismissWindow) private var dismissWindow

    @MainActor
    final class Holder: ObservableObject { @Published var controller: MacSessionWindowController? }

    var body: some View {
        Group {
            if let controller = holder.controller {
                MacSessionWindowView(controller: controller)
            } else {
                Color.clear
            }
        }
        .environmentObject(appState)
        .environment(\.locale, appLanguage.resolvedLocale)
        .preferredColorScheme(appState.themePreference.colorScheme)
        .tint(.conduitAccent)
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
    }

    private func appear() {
        guard let token, MacSessionWindowRegistry.shared.appeared(token) else {
            dismissWindow()   // restored at relaunch, or no value: v1 does not restore windows
            return
        }
        guard holder.controller == nil else { return }
        let controller = MacSessionWindowController(token: token,
                                                    environment: MacSessionWindowController.environment(for: appState, token: token))
        controller.bind(to: appState, tabs: .shared)
        controller.start()
        holder.controller = controller
    }

    private func disappear() {
        holder.controller?.stop()
        holder.controller = nil
        if let token { MacSessionWindowRegistry.shared.disappeared(token) }
    }
}
