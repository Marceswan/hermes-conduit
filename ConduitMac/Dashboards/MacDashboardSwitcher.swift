import SwiftUI

/// Presentation state of the Cmd-Shift-D dashboard switcher (D22). The sheet
/// itself is `MacDashboardSwitcherView` hosted by `macDashboardSwitcher`.
@MainActor
final class MacDashboardSwitcherStore: ObservableObject {
    static let shared = MacDashboardSwitcherStore()

    @Published private(set) var isPresented = false

    init() {}

    func present() { isPresented = true }
    func dismiss() { isPresented = false }
}

/// The existing Saved Dashboards settings page, unchanged, under a sheet
/// header. Every behaviour (Switch, Sign In, sign out, remove, Add Dashboard,
/// closing when the login surface takes over) is the page's own; this view
/// only frames it. Needs `AppState` in the environment.
struct MacDashboardSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    let close: () -> Void

    init(close: @escaping () -> Void) {
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(title: AppLocalization.string("Saved Dashboards"), close: close)
            SavedDashboardsSettingsDetail(close: close)
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
        .macFormSheetSize(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 520)
    }
}

private struct MacDashboardSwitcherModifier: ViewModifier {
    let appState: AppState
    @ObservedObject private var store: MacDashboardSwitcherStore

    init(appState: AppState, store: MacDashboardSwitcherStore) {
        self.appState = appState
        self._store = ObservedObject(wrappedValue: store)
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { store.isPresented },
            set: { if !$0 { store.dismiss() } }
        )) {
            MacDashboardSwitcherView(close: { store.dismiss() })
                .environmentObject(appState)
        }
    }
}

extension View {
    /// Hangs the Cmd-Shift-D sheet on this view. Attach it to `RootView` in
    /// `ConduitMacApp.rootContent`, after the environment and tint modifiers
    /// (the sheet inherits them), so it also shows over the login screen.
    func macDashboardSwitcher(appState: AppState, store: MacDashboardSwitcherStore? = nil) -> some View {
        modifier(MacDashboardSwitcherModifier(appState: appState, store: store ?? .shared))
    }
}
