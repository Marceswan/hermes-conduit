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
/// but the pane's own header already names the pane, so the toolbar does not
/// display it (D6). The window's toolbar is owned by the always-mounted chat
/// `NavigationStack` (`RootView.chatNavigationContent`), so the removal is
/// applied there.
enum MacPaneTitle {
    /// macOS 15 and later can remove the toolbar's title item while the
    /// window keeps its title string (`toolbar(removing: .title)`). macOS 14
    /// cannot, and an `NSWindow.titleVisibility` workaround is overridden by
    /// SwiftUI, so there the title is blank instead: the cost is a blank title
    /// in the Window menu on those panes.
    static var canHideKeepingTitle: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    static func windowTitle(forPane name: String, canHideKeepingTitle: Bool = MacPaneTitle.canHideKeepingTitle) -> String {
        canHideKeepingTitle ? name : ""
    }
}

extension View {
    /// Removes the title from the window toolbar, keeping the window's title
    /// string, while `hidden` (macOS 15 and later; a no-op before, see `MacPaneTitle`).
    @ViewBuilder
    func macHidingToolbarTitle(_ hidden: Bool) -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: hidden ? .title : nil)
        } else {
            self
        }
    }
}

/// Keeps the window search item at the trailing edge on Bots, Cron and Kanban.
/// The item follows the title slot: with the pane name removed from the toolbar
/// (`macHidingToolbarTitle`) nothing is left to push it right, so it moved to the
/// leading edge beside the sidebar toggle. A flexible spacer takes the slack
/// (macOS 26 and later); before that an empty principal item does.
struct MacPaneToolbarFill: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .principal) { Color.clear.frame(minWidth: 1, maxWidth: .infinity, minHeight: 1) }
        }
    }
}
