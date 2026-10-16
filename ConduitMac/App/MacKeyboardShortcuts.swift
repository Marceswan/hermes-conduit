import AppKit
import SwiftUI

// Keyboard support (D10). Pure mappings and the focus-request plumbing live
// here so the menu (ConduitCommands), the sidebar list modifier and the
// composer twin share one definition and tests can reach it headlessly.

/// Ctrl-Cmd-1 ... Ctrl-Cmd-4: one shortcut per sidebar tab, in tab-strip order.
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

    /// The digit typed with `modifiers`.
    var key: KeyEquivalent {
        switch self {
        case .sessions: return "1"
        case .bots: return "2"
        case .cron: return "3"
        case .kanban: return "4"
        }
    }

    /// Ctrl-Cmd: plain Cmd-digits select session tabs (D11).
    var modifiers: EventModifiers { [.control, .command] }

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
/// session list consumes it, so a sidebar that was not mounted when the
/// command ran still focuses its field once it appears, but only briefly: a
/// list that mounts much later (after login) must not take the keyboard.
@MainActor
final class MacFocusRequests: ObservableObject {
    static let shared = MacFocusRequests()
    /// How long an unconsumed request stays valid.
    static let pendingLifetime: TimeInterval = 1.0

    @Published private(set) var searchToken = 0
    private(set) var searchPending = false
    private var requestedAt = Date.distantPast

    func requestSearch(now: Date = Date()) {
        searchPending = true
        requestedAt = now
        searchToken += 1
    }

    /// A later focus action (Cmd-L, a click elsewhere) supersedes the request:
    /// nothing pending, and any retry in flight stops.
    func cancelSearch() {
        searchPending = false
        searchToken += 1
    }

    /// True once per request, and only while it is fresh.
    func consumeSearch(now: Date = Date()) -> Bool {
        defer { searchPending = false }
        return searchPending && now.timeIntervalSince(requestedAt) <= Self.pendingLifetime
    }

    /// Runs `attempt` again every `interval` while the search field has not
    /// taken the keyboard, for at most `maxAttempts`. It stops early when the
    /// keyboard went somewhere else since the request (the user clicked or
    /// pressed Cmd-L) or another request superseded this one, so a late retry
    /// never pulls focus back. This covers a sidebar that is still opening.
    func retrySearchFocus(
        in window: NSWindow?,
        interval: TimeInterval = 0.1,
        maxAttempts: Int = 8,
        attempt: @escaping () -> Void
    ) {
        let token = searchToken
        let original = window?.firstResponder
        attempt()
        Task { @MainActor [weak self, weak window] in
            for _ in 0..<maxAttempts {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, let window, token == self.searchToken,
                      window.firstResponder === original, !MacToolbarSearch.isFocused(in: window) else { return }
                attempt()
            }
        }
    }
}

/// What the menu items do. Defaults and the notification centre are
/// injectable so tests never touch the live app's state.
@MainActor
enum MacKeyboardActions {
    /// A sheet is attached to the window (or the window is the sheet): the
    /// commands would act on the window behind it. The same holds for a floating panel.
    static func commandsBlocked(by window: NSWindow?) -> Bool {
        // A floating panel (Quick Ask) is not the chat window: the menu's tab,
        // sidebar, search and session shortcuts must not act on the main window
        // from behind it.
        window is MacFloatingPanel || window?.attachedSheet != nil || window?.sheetParent != nil
    }

    static func selectTab(
        _ tab: SidebarTab,
        window: NSWindow? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard !commandsBlocked(by: window) else { return }
        defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
    }

    enum FindOutcome: Equatable {
        case messageFind, searchSessions
    }

    /// The text view whose own find bar Cmd-F should open: the first responder
    /// when it is a find-capable text view that validates the Find action
    /// (message text, `SelectableTextView`; not the composer).
    /// Only while chat is the shown pane and the view is on screen: the hidden
    /// chat under Bots / Cron / Kanban (opacity 0, not AppKit-hidden) can keep
    /// a message view as first responder, and its find bar would be invisible.
    static func findTarget(in responder: NSResponder?, chatActive: Bool = true) -> NSTextView? {
        guard chatActive, let textView = responder as? NSTextView, textView.usesFindBar || textView.usesFindPanel,
              let window = textView.window, window.isVisible, !textView.isHiddenOrHasHiddenAncestor else { return nil }
        return textView.validateUserInterfaceItem(findItem()) ? textView : nil
    }

    private static func findItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        return item
    }

    /// Cmd-F. A focused message view keeps its find bar; everywhere else the
    /// key focuses Search Sessions. Returns what it did (nil: blocked).
    @discardableResult
    static func findOrSearchSessions(
        window: NSWindow?,
        defaults: UserDefaults = .standard,
        requests: MacFocusRequests? = nil
    ) -> FindOutcome? {
        guard !commandsBlocked(by: window) else { return nil }
        let chatActive = MacChatRoute.isChatActive(tabRaw: defaults.string(forKey: MacSidebarState.tabDefaultsKey))
        if let target = findTarget(in: window?.firstResponder, chatActive: chatActive) {
            target.performFindPanelAction(findItem())
            return .messageFind
        }
        focusSessionSearch(defaults: defaults, requests: requests)
        return .searchSessions
    }

    /// The sidebar always lists sessions on Mac (D6), so only a hidden sidebar
    /// needs changing; the main pane is left where it is.
    static func focusSessionSearch(
        defaults: UserDefaults = .standard,
        requests: MacFocusRequests? = nil
    ) {
        defaults.set(true, forKey: MacSidebarState.defaultsKey)
        (requests ?? .shared).requestSearch()
    }

    /// Cmd-L. Chat comes back first (it stays mounted under other panes), so
    /// the composer's route logic sees a shown chat and keeps the focus. With
    /// no window to name it does nothing: an unaddressed request would reach
    /// every composer.
    static func focusComposer(
        window: NSWindow?,
        defaults: UserDefaults = .standard,
        center: NotificationCenter = .default,
        requests: MacFocusRequests? = nil
    ) {
        guard let window, !commandsBlocked(by: window) else { return }
        (requests ?? .shared).cancelSearch()
        // A session window has its own composer; the main pane stays as it is (D21).
        if !MacSessionWindows.isSessionWindow(window) { selectTab(.sessions, defaults: defaults) }
        center.post(name: .macFocusComposerRequested, object: window)
    }

    /// Previous / next session: the same open a row click performs.
    static func openNeighbor(
        _ direction: MacSessionNavigation.Direction,
        order: [String]?,
        activeID: String?,
        window: NSWindow? = nil,
        open: (String) -> Void
    ) {
        guard !commandsBlocked(by: window),
              let order, let id = MacSessionNavigation.neighbor(of: activeID, in: order, direction: direction) else { return }
        open(id)
    }
}

/// What the tab menu items do (D11). The store is injectable for tests; the
/// parameter is optional because a `.shared` default trips Swift 6 isolation.
@MainActor
enum MacSessionTabsActions {
    /// The chat window: SwiftUI names WindowGroup("Conduit", id: "conduit-primary")
    /// windows with that id as the prefix.
    static func isMainChatWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix("conduit-primary") ?? false
    }

    /// Cmd-W: a tab in the chat window, else a real non-chat window's ordinary
    /// close. Under a sheet, or in the sheet itself, nothing happens.
    static func closeTab(store: MacSessionTabsStore? = nil, window: NSWindow?) {
        // A sheet (Settings, pickers) is not a window to close: Esc closes it.
        guard let window, !MacKeyboardActions.commandsBlocked(by: window) else { return }
        guard isMainChatWindow(window) else { window.performClose(nil); return }
        (store ?? .shared).close(nil)
    }

    static func reopen(store: MacSessionTabsStore? = nil, window: NSWindow?) {
        guard isMainChatWindow(window), !MacKeyboardActions.commandsBlocked(by: window) else { return }
        (store ?? .shared).reopen()
    }

    static func selectShortcut(_ n: Int, store: MacSessionTabsStore? = nil, window: NSWindow?) {
        guard isMainChatWindow(window), !MacKeyboardActions.commandsBlocked(by: window) else { return }
        (store ?? .shared).selectShortcut(n)
    }

    static func selectNeighbor(_ direction: MacSessionTabsModel.Direction, store: MacSessionTabsStore? = nil, window: NSWindow?) {
        guard isMainChatWindow(window), !MacKeyboardActions.commandsBlocked(by: window) else { return }
        (store ?? .shared).selectNeighbor(direction)
    }
}

/// What Go > Command Palette does (D18). The store is optional because a
/// `.shared` default argument trips Swift 6 isolation (same as the tabs).
@MainActor
enum MacPaletteActions {
    /// Cmd-K: only in the chat window, never under a sheet. Closing the
    /// palette gives focus back to whatever held it when it opened.
    static func toggle(store: MacPaletteStore? = nil, window: NSWindow?) {
        let store = store ?? .shared
        guard MacSessionTabsActions.isMainChatWindow(window),
              !MacKeyboardActions.commandsBlocked(by: window) else { return }
        store.toggle(restoreFocus: store.isPresented ? nil : focusRestorer(in: window))
    }

    /// The composer takes focus back through the same request Cmd-L sends
    /// (it also returns the chat pane); any other AppKit responder, such as
    /// the session list or the search field, is made first responder again
    /// if it is still on screen. Held weakly: the store keeps this until the
    /// palette closes.
    static func focusRestorer(in window: NSWindow?) -> (() -> Void)? {
        guard let window else { return nil }
        let responder = window.firstResponder
        if responder is ComposerTextView {
            return { [weak window] in MacKeyboardActions.focusComposer(window: window) }
        }
        var target = responder as? NSView
        // A text field edits through the window's shared field editor.
        if let editor = target as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSView {
            target = owner
        }
        guard let view = target, view !== window.contentView else { return nil }
        return { [weak window, weak view] in
            guard let window, let view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return }
            window.makeFirstResponder(view)
        }
    }
}
