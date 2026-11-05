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
/// all in one run loop turn. It should draw nothing between; the live check (Task 14) confirms it.
///
/// Only windows that show SwiftUI are touched (not open and save panels), and the window gets its own appearance
/// back only if the vibrant one is still set: an appearance that SwiftUI or AppKit set during the layout (a
/// `preferredColorScheme` change in the same transaction) is not overwritten. This depends on how AppKit and
/// SwiftUI handle an appearance change; it is not a documented contract.
@MainActor
enum MacAccentRedraw {
    private static var isScheduled = false
    /// How many times a scheduled refresh ran (tests read it to see that calls share one run).
    private(set) static var scheduledRunCount = 0

    /// One refresh of every window on the next run loop turn; calls made before it runs share it.
    static func scheduleForAllWindows() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async {
            isScheduled = false
            scheduledRunCount += 1
            refresh(NSApp.windows)
        }
    }

    /// Refreshes the windows that show SwiftUI. Returns how many it refreshed.
    @discardableResult
    static func refresh(_ windows: [NSWindow]) -> Int {
        var refreshed = 0
        for window in windows {
            guard let content = window.contentView, showsSwiftUI(content) else { continue }
            let own = window.appearance
            let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let vibrant = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight),
                  own?.name != vibrant.name else { continue }
            window.appearance = vibrant
            content.layoutSubtreeIfNeeded()
            if window.appearance?.name == vibrant.name { window.appearance = own }
            refreshed += 1
        }
        return refreshed
    }

    /// True when the view, or a view below it, is a SwiftUI hosting view (`NSHostingView`, and the hosting
    /// views a scene or a toolbar item makes).
    static func showsSwiftUI(_ view: NSView, depth: Int = 0) -> Bool {
        if String(describing: type(of: view)).contains("HostingView") { return true }
        guard depth < 6 else { return false }
        return view.subviews.contains { showsSwiftUI($0, depth: depth + 1) }
    }
}
