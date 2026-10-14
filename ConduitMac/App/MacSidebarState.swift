import SwiftUI

/// Mac-only state for the split-view sidebar column. Shared by the layout
/// (`MacSplitLayout`) and the Toggle Sidebar command so both read one key.
enum MacSidebarState {
    static let defaultsKey = "conduit.mac.sidebarVisible"
    /// Same key as upstream SidebarView's @AppStorage literal.
    static let tabDefaultsKey = "conduit.sidebarTab"

    /// Column metrics. The window minimum must hold the widest sidebar plus
    /// the narrowest detail pane, or the detail clips when the sidebar is
    /// dragged wide (guarded by MacDetailRouterTests).
    static let sidebarMinWidth: CGFloat = 260
    static let sidebarIdealWidth: CGFloat = 340
    static let sidebarMaxWidth: CGFloat = 390
    static let detailMinWidth: CGFloat = 430
    static let windowMinWidth: CGFloat = 820

    static func visibility(isVisible: Bool) -> NavigationSplitViewVisibility {
        isVisible ? .all : .detailOnly
    }

    /// What Hide / Show Sidebar (Ctrl-Cmd-S) does: flips the key `MacSplitLayout`
    /// reads. Shown when the key was never written.
    static func toggleVisible(defaults: UserDefaults = .standard) {
        let shown = defaults.object(forKey: defaultsKey) as? Bool ?? true
        defaults.set(!shown, forKey: defaultsKey)
    }

    static func isVisible(_ visibility: NavigationSplitViewVisibility) -> Bool {
        visibility != .detailOnly
    }
}

/// Native resizable two-column layout for the Mac window: sessions sidebar
/// on the left, `MacDetailRouter` content on the right.
struct MacSplitLayout<Sidebar: View, Chat: View>: View {
    @AppStorage private var sidebarVisible: Bool
    private let sidebar: Sidebar
    private let chat: Chat

    /// `defaults` is injectable so tests can host a layout without sharing the
    /// visibility key with the live app.
    init(defaults: UserDefaults = .standard, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder chat: () -> Chat) {
        _sidebarVisible = AppStorage(wrappedValue: true, MacSidebarState.defaultsKey, store: defaults)
        self.sidebar = sidebar()
        self.chat = chat()
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { MacSidebarState.visibility(isVisible: sidebarVisible) },
                set: { sidebarVisible = MacSidebarState.isVisible($0) }
            )
        ) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: MacSidebarState.sidebarMinWidth,
                    ideal: MacSidebarState.sidebarIdealWidth,
                    max: MacSidebarState.sidebarMaxWidth
                )
        } detail: {
            MacDetailRouter(chat: { chat })
                .frame(minWidth: MacSidebarState.detailMinWidth)
        }
    }
}
