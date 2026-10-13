import SwiftUI

/// Mac-only state for the split-view sidebar column. Shared by the layout
/// (`MacSplitLayout`) and the Toggle Sidebar command so both read one key.
enum MacSidebarState {
    static let defaultsKey = "conduit.mac.sidebarVisible"

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
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 480)
        } detail: {
            MacDetailRouter(chat: { chat })
        }
    }
}
