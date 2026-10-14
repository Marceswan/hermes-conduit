import AppKit
import SwiftUI

// Keyboard support (D10). Pure mappings and the focus-request plumbing live
// here so the menu (ConduitCommands), the sidebar list modifier and the
// composer twin share one definition and tests can reach it headlessly.

/// Cmd-1 ... Cmd-4: one shortcut per sidebar tab, in tab-strip order.
enum MacSidebarShortcut: CaseIterable, Identifiable {
    case sessions, bots, cron, kanban

    var id: Self { self }

    var tab: SidebarTab {
        switch self {
        case .sessions: return .sessions
        case .bots: return .bots
        case .cron: return .cron
        case .kanban: return .kanban
        }
    }

    /// The digit typed with Command.
    var key: KeyEquivalent {
        switch self {
        case .sessions: return "1"
        case .bots: return "2"
        case .cron: return "3"
        case .kanban: return "4"
        }
    }

    /// Menu title ("Sessions"): the tab's own localized name.
    var title: String { tab.displayName }

    static func tab(forKey character: Character) -> SidebarTab? {
        allCases.first { $0.key.character == character }?.tab
    }
}

/// Previous / next session in the order the sidebar shows them.
enum MacSessionNavigation {
    enum Direction { case previous, next }

    /// The session one step from `activeID` in `ids`, or nil when there is no
    /// step: an empty list, or `activeID` already at that end (no wrap).
    /// When `activeID` is nil or not listed (hidden by the search or a
    /// filter), next enters at the top and previous at the bottom.
    static func neighbor(of activeID: String?, in ids: [String], direction: Direction) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let activeID, let index = ids.firstIndex(of: activeID) else {
            return direction == .next ? ids.first : ids.last
        }
        switch direction {
        case .previous: return index > 0 ? ids[index - 1] : nil
        case .next: return index + 1 < ids.count ? ids[index + 1] : nil
        }
    }
}

/// The keyboard cursor of the sidebar session list: which row Up / Down
/// moved to. Separate from the open session; Return opens the cursor row.
enum MacSessionCursor {
    enum Move { case up, down, first, last }

    /// Where `move` lands, starting from `base` (the cursor, else the open
    /// session). Up / Down stop at the ends. With no usable base, Down picks
    /// the first row and Up the last, as a table view does.
    static func moved(_ move: Move, from base: String?, in ids: [String]) -> String? {
        switch move {
        case .first: return ids.first
        case .last: return ids.last
        case .down: return MacSessionNavigation.neighbor(of: base, in: ids, direction: .next) ?? stay(base, in: ids)
        case .up: return MacSessionNavigation.neighbor(of: base, in: ids, direction: .previous) ?? stay(base, in: ids)
        }
    }

    /// Tabbing into the list shows the cursor on the open session at once, so
    /// the keyboard focus is visible. A click that focuses the list does not:
    /// the ring would sit on the previous session until the new one loads.
    static func showsOnFocus(_ eventType: NSEvent.EventType?) -> Bool {
        eventType == .keyDown
    }

    /// The cursor survives only while its row is still listed.
    static func reconciled(_ cursor: String?, in ids: [String]) -> String? {
        guard let cursor, ids.contains(cursor) else { return nil }
        return cursor
    }

    private static func stay(_ base: String?, in ids: [String]) -> String? {
        guard let base, ids.contains(base) else { return nil }
        return base
    }
}

extension Notification.Name {
    /// Cmd-L. `object` is the window the command ran in; the composer in
    /// that window takes first responder.
    static let macFocusComposerRequested = Notification.Name("conduit.mac.focusComposerRequested")
}

/// Cmd-F bridge to the sidebar's search field. The request is held until the
/// session list consumes it, so a sidebar that was hidden (and so not
/// mounted) when the command ran still focuses its field once it appears.
@MainActor
final class MacFocusRequests: ObservableObject {
    static let shared = MacFocusRequests()
    /// Time the sidebar needs to finish opening before its field can focus.
    static let sidebarRevealDelay: TimeInterval = 0.4

    @Published private(set) var searchToken = 0
    private(set) var searchPending = false
    /// The last request had to show a hidden sidebar, so the field is still
    /// sliding into place when the request arrives.
    private(set) var searchRevealedSidebar = false

    func requestSearch(revealedSidebar: Bool = false) {
        searchPending = true
        searchRevealedSidebar = revealedSidebar
        searchToken += 1
    }

    /// True once per request.
    func consumeSearch() -> Bool {
        defer { searchPending = false }
        return searchPending
    }
}

/// What the menu items do. Defaults and the notification centre are
/// injectable so tests never touch the live app's state.
@MainActor
enum MacKeyboardActions {
    static func selectTab(
        _ tab: SidebarTab,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
    }

    /// Cmd-F. The sidebar always lists sessions on Mac (D6), so only a
    /// hidden sidebar needs changing; the main pane is left where it is.
    static func focusSessionSearch(
        defaults: UserDefaults = .standard,
        requests: MacFocusRequests? = nil
    ) {
        let wasHidden = defaults.object(forKey: MacSidebarState.defaultsKey) as? Bool == false
        defaults.set(true, forKey: MacSidebarState.defaultsKey)
        (requests ?? .shared).requestSearch(revealedSidebar: wasHidden)
    }

    /// Cmd-L. Chat comes back first (it stays mounted under other panes), so
    /// the composer's route logic sees a shown chat and keeps the focus.
    static func focusComposer(
        window: NSWindow?,
        defaults: UserDefaults = .standard,
        center: NotificationCenter = .default
    ) {
        selectTab(.sessions, defaults: defaults)
        center.post(name: .macFocusComposerRequested, object: window)
    }

    /// Previous / next session: the same open a row click performs.
    static func openNeighbor(
        _ direction: MacSessionNavigation.Direction,
        order: [String]?,
        activeID: String?,
        open: (String) -> Void
    ) {
        guard let order, let id = MacSessionNavigation.neighbor(of: activeID, in: order, direction: direction) else { return }
        open(id)
    }
}
