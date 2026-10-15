import SwiftUI

/// Content treatment for the chat window-toolbar items on Mac.
///
/// From macOS 26 every window-toolbar item sits on a system glass platter
/// (`NSToolbarPlatterView`, 36 pt tall, measured on macOS 27). Upstream also
/// wraps its toolbar controls in `conduitGlassControl` for iOS, where there is
/// no platter, which stacked a second glass layer (a doubled outline) on top
/// of a fixed 40 pt frame. On Mac the controls are plain content and the
/// system supplies the one glass layer; the title pill, which is text rather
/// than an icon, only fixes its height so it matches Refresh and the status
/// button.
struct MacToolbarTitlePill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, 12)
                .frame(height: MacControlHeight.toolbarItem)
        } else {
            // No system platter before macOS 26: a flat fill stands in for it.
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }
}

extension View {
    /// Flat, compact title pill for the Mac window toolbar (D7).
    func macToolbarTitlePill() -> some View { modifier(MacToolbarTitlePill()) }
}

/// The window title on Bots, Cron and Kanban. Those panes keep a title string
/// (`.navigationTitle(pane name)`: Window menu, Mission Control, accessibility)
/// but the pane's own header already names the pane, so on macOS 26 and later
/// the toolbar does not display it (D6). The window's toolbar is owned by the
/// always-mounted chat `NavigationStack` (`RootView.chatNavigationContent`), so
/// the removal and the filler are applied there. Before macOS 26 nothing
/// changes: the pane title shows and there is no filler (the layout that
/// shipped in 0.1.3; the hiding was only verified on 26 and later).
enum MacPaneTitle {
    static var isHidingTitle: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

extension View {
    /// Removes the title from the window toolbar, keeping the window's title
    /// string, while `hidden` (macOS 26 and later; a no-op before, see `MacPaneTitle`).
    @ViewBuilder
    func macHidingToolbarTitle(_ hidden: Bool) -> some View {
        if #available(macOS 26.0, *) {
            toolbar(removing: hidden ? .title : nil)
        } else {
            self
        }
    }
}

/// Keeps the window search item at the trailing edge on Bots, Cron and Kanban.
/// The item follows the title slot: with the pane name removed from the toolbar
/// (`macHidingToolbarTitle`) nothing is left to push it right, so it moved to the
/// leading edge beside the sidebar toggle. A flexible spacer takes the slack.
/// macOS 26 and later only (`ToolbarSpacer`); before that the title is not
/// hidden, so nothing needs filling.
struct MacPaneToolbarFill: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
    }
}
