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
