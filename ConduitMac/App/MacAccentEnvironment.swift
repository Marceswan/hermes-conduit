import AppKit
import SwiftUI

/// The accent picked in Settings > Appearance, as the root of a Mac scene draws it. Ported from ConduitApp.swift
/// (`.tint(.conduitAccent)` and `.environment(\.conduitAccent, accentChoice)`, #697, #702, #750); keep in sync.
///
/// iOS carries the pick in a UIKit trait, so every dynamic accent colour resolves it again when the pick changes.
/// macOS has no custom trait: the dynamic accent colours read the saved pick from `UserDefaults` (Theme.swift), and
/// SwiftUI resolves a dynamic `NSColor` only when its appearance changes, so views that read `Color.conduitAccent`
/// directly keep the old colour after a new pick. Reading the pick as `@AppStorage` here updates the tint and the
/// environment value; `MacAccentRedraw` makes the rest resolve again.
///
/// Not ported: the Watch accent (`shareWatchCallVoices`; no Watch pairs with a Mac) and `WindowAccentTint` (iOS
/// system screens).
struct MacAccentEnvironment: ViewModifier {
    @AppStorage(ConduitAccentChoice.storageKey) private var accentChoice = ConduitAccentChoice.defaultChoice

    func body(content: Content) -> some View {
        content
            .tint(.conduitAccent)
            .environment(\.conduitAccent, accentChoice)
            .onChange(of: accentChoice) { _, _ in MacAccentRedraw.scheduleForAllWindows() }
    }
}

extension View {
    /// The tint and the accent environment of a Mac scene root (`MacAccentEnvironment`).
    func macAccentEnvironment() -> some View {
        modifier(MacAccentEnvironment())
    }
}

/// Makes the SwiftUI content of a window resolve its dynamic colours again, without rebuilding any view. A view
/// rebuild is not an option: the root view owns the sheet state, so Settings would close under the user.
///
/// The window takes the vibrant variant of its own appearance (same light or dark scheme, so SwiftUI's colour
/// scheme and every `onChange(of: colorScheme)` stay as they are), lays out, and takes its own appearance back,
/// all in one run loop turn: nothing is drawn in between.
@MainActor
enum MacAccentRedraw {
    private static var isScheduled = false

    /// One refresh of every window on the next run loop turn; calls made before it runs share it.
    static func scheduleForAllWindows() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async {
            isScheduled = false
            refresh(NSApp.windows)
        }
    }

    static func refresh(_ windows: [NSWindow]) {
        for window in windows {
            guard let content = window.contentView else { continue }
            let own = window.appearance
            let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            window.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
            content.layoutSubtreeIfNeeded()
            window.appearance = own
        }
    }
}
