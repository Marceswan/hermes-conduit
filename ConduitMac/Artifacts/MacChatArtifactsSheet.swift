import SwiftUI

/// Presentation state of Chat > Artifacts... (Task 13). `sessionIDs` is read once, when the menu
/// item runs: the ids the open chat is known by. nil means no sheet.
@MainActor
final class MacChatArtifactsStore: ObservableObject {
    static let shared = MacChatArtifactsStore()

    @Published private(set) var sessionIDs: [String]?

    init() {}

    func present(sessionIDs: [String]) { self.sessionIDs = sessionIDs }
    func dismiss() { sessionIDs = nil }
}

/// One chat's artifacts in a sheet: the sheet header over `MacArtifactsList`. A Mac twin of
/// upstream's `ChatArtifactsSheet`, without the navigation stack. Needs `AppState` in the
/// environment.
struct MacChatArtifactsView: View {
    @EnvironmentObject private var appState: AppState
    /// Read once: the open chat's ids when the sheet opened.
    let sessionIDs: [String]
    let close: () -> Void

    init(sessionIDs: [String], close: @escaping () -> Void) {
        self.sessionIDs = sessionIDs
        self.close = close
    }

    /// The list's scope for these ids.
    static func scope(for ids: [String]) -> ArtifactScope { .chat(ids) }

    /// Show in Chat: the sheet closes, then the open chat scrolls to the message (no chat switch).
    static func showInChat(_ item: ArtifactItem, appState: AppState, close: () -> Void) {
        close()
        appState.showArtifactInChat(item, chatIsOpen: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(title: AppLocalization.string("Artifacts"), close: close)
            if sessionIDs.isEmpty {
                // An empty id list would read every chat, so the list is never built for it.
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No Artifacts Yet").font(.headline)
                    Text("Files, pages and links from this chat show up here once Hermes has saved it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The list draws no horizontal padding of its own (the pane's router gives it 20 pt).
                MacArtifactsList(scope: Self.scope(for: sessionIDs), chatIsOpen: true) { item in
                    Self.showInChat(item, appState: appState, close: close)
                }
                .padding(.horizontal, 20)
            }
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
        .macFormSheetSize(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 600)
    }
}

private struct MacChatArtifactsModifier: ViewModifier {
    let appState: AppState
    @ObservedObject private var store: MacChatArtifactsStore
    /// The ids of the last presentation, so the sheet keeps its content while it animates out.
    @State private var lastIDs: [String] = []

    init(appState: AppState, store: MacChatArtifactsStore) {
        self.appState = appState
        self._store = ObservedObject(wrappedValue: store)
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { store.sessionIDs != nil },
            set: { if !$0 { store.dismiss() } }
        )) {
            MacChatArtifactsView(sessionIDs: store.sessionIDs ?? lastIDs, close: { store.dismiss() })
                .environmentObject(appState)
        }
        .onChange(of: store.sessionIDs) { _, ids in
            if let ids { lastIDs = ids }
        }
    }
}

extension View {
    /// Hangs the Chat > Artifacts... sheet on this view. Attach it next to `macDashboardSwitcher`.
    func macChatArtifactsSheet(appState: AppState, store: MacChatArtifactsStore? = nil) -> some View {
        modifier(MacChatArtifactsModifier(appState: appState, store: store ?? .shared))
    }
}
