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

    /// Whether a tab's session can be popped out. The window resumes with the workspace profile, so
    /// only a session in the workspace catalog works: a Bot Chat (another profile's store, which the
    /// window's resume does not address) or anything else without a catalog row stays in the main window.
    static func canPopOut(_ sessionID: String, catalog: [SessionSummary]) -> Bool {
        catalog.contains { $0.macMatches(sessionID) }
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

    /// Cmd-. (Chat > Stop Response). A session window stops its own turn; it never
    /// cancels the main window's. Any other window stops the main turn.
    static func stopResponse(window: NSWindow?, router: MacSessionWindowStopRouter? = nil, stopMain: () -> Void) {
        guard isSessionWindow(window) else { stopMain(); return }
        _ = (router ?? .shared).stop(in: window)
    }
}

/// Which window's Stop belongs to which session window controller (D21).
@MainActor
final class MacSessionWindowStopRouter {
    static let shared = MacSessionWindowStopRouter()
    private struct Entry { weak var window: NSWindow?; let stop: () -> Void }
    private var entries: [Entry] = []

    func register(window: NSWindow, stop: @escaping () -> Void) {
        unregister(window: window)
        entries.append(Entry(window: window, stop: stop))
    }

    func unregister(window: NSWindow) {
        entries.removeAll { $0.window == nil || $0.window === window }
    }

    /// True when a controller for the window took the request.
    @discardableResult
    func stop(in window: NSWindow?) -> Bool {
        guard let window, let entry = entries.first(where: { $0.window === window }) else { return false }
        entry.stop()
        return true
    }
}

/// Reports the hosting window to the scene (a weak reference; set on attach and detach).
private struct MacSessionWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class Reader: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.onWindow = onWindow }
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
    final class Holder: ObservableObject {
        @Published var controller: MacSessionWindowController?
        weak var window: NSWindow?

        /// Keeps Cmd-. pointed at this window's controller while both exist.
        func syncStopRoute() {
            guard let window else { return }
            if let controller {
                MacSessionWindowStopRouter.shared.register(window: window) { [weak controller] in controller?.stopTurn() }
            } else {
                MacSessionWindowStopRouter.shared.unregister(window: window)
            }
        }
    }

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
        .macAccentEnvironment()
        // The same link policy as the main window (R11).
        .macLinkPolicy(appState: appState)
        .background(MacSessionWindowReader { window in
            holder.window = window
            holder.syncStopRoute()
        })
        .modifier(MacRegisterPrimaryWindowOpener())
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
        holder.syncStopRoute()
    }

    private func disappear() {
        holder.controller?.stop()
        holder.controller = nil
        holder.syncStopRoute()
        if let token { MacSessionWindowRegistry.shared.disappeared(token) }
    }
}
