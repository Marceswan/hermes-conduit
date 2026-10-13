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

    static func isVisible(_ visibility: NavigationSplitViewVisibility) -> Bool {
        visibility != .detailOnly
    }
}

/// Native resizable two-column layout for the Mac window: sessions sidebar
/// on the left, `MacDetailRouter` content on the right.
struct MacSplitLayout<Sidebar: View, Chat: View>: View {
    @AppStorage(MacSidebarState.defaultsKey) private var sidebarVisible = true
    private let sidebar: Sidebar
    private let chat: Chat

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder chat: () -> Chat) {
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
