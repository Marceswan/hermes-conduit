import Combine
import Foundation

/// The app calls the palette can make, injected so tests never touch
/// AppState (pattern: `ModelPickerApplyActions`). Live values: Task 5.
struct MacPaletteCalls {
    var openSession: (String) -> Void = { _ in }
    var runSlash: (String) async -> Void = { _ in }
    var insertSlash: (String) -> Void = { _ in }
    var switchProfile: (String) async -> Void = { _ in }
    var openModelPicker: () -> Void = {}
    var selectPane: (SidebarTab) -> Void = { _ in }
    var newChat: () -> Void = {}
    var openSettings: () -> Void = {}
    var toggleSidebar: () -> Void = {}
    var stopResponse: () -> Void = {}
    var searchSessions: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    /// The composer's current text; `insertSlash` replaces it, so a non-empty
    /// draft makes the palette ask first.
    var draftText: () -> String = { "" }
}

enum MacPaletteDispatcher {
    @MainActor
    static func perform(_ action: MacPaletteAction, with calls: MacPaletteCalls) {
        switch action {
        case .openSession(let id): calls.openSession(id)
        case .runSlash(let name): Task { await calls.runSlash(name) }
        case .insertSlash(let name): calls.insertSlash(name)
        case .switchProfile(let name): Task { await calls.switchProfile(name) }
        case .openModelPicker: calls.openModelPicker()
        case .selectPane(let tab): calls.selectPane(tab)
        case .newChat: calls.newChat()
        case .openSettings: calls.openSettings()
        case .toggleSidebar: calls.toggleSidebar()
        case .stopResponse: calls.stopResponse()
        case .searchSessions: calls.searchSessions()
        case .checkForUpdates: calls.checkForUpdates()
        }
    }
}

/// State of the Cmd-K palette (D18): query, sections, selection, running.
@MainActor
final class MacPaletteStore: ObservableObject {
    static let shared = MacPaletteStore()

    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet {
            guard query != oldValue, isPresented else { return }
            cancelPending()
            search(resetSelection: true)
        }
    }
    @Published private(set) var sections: [MacPaletteSection] = []
    @Published private(set) var selectionID: String?
    /// Bumped by `move`: the view speaks the new row for VoiceOver on a
    /// deliberate move, not when typing resets the highlight.
    @Published private(set) var navigationToken = 0
    /// Set while a row waits for its second Return (or a click on Confirm).
    @Published private(set) var pendingConfirmation: MacPaletteConfirmation?

    var snapshot: () -> MacPaletteSnapshot = { .empty }
    var calls = MacPaletteCalls()
    /// Set by `bind(to:)` (MacPaletteBinding.swift); a plain var because an extension cannot store.
    var isBound = false

    private let recentsStore: MacPaletteRecentsStore
    private let now: () -> Date
    private var recents = MacPaletteRecents()
    private var recentsScope: String?
    private var restoreFocus: (() -> Void)?
    private var pendingItem: MacPaletteItem?

    /// Built once per open (and by `refresh()`); keystrokes only rank it. The
    /// provider, the snapshot and the diacritic folding are O(sessions) and
    /// must not run per keystroke on 1,000+ chats.
    private var itemsByID: [String: MacPaletteItem] = [:]
    private var allItems: [MacPaletteItem] = []
    private var allEntries: [MacPaletteMatcher.Entry] = []
    private var scopedEntries: [MacPaletteScope: [MacPaletteMatcher.Entry]] = [:]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.recentsStore = MacPaletteRecentsStore(defaults: defaults)
        self.now = now
    }

    var rows: [MacPaletteItem] { sections.flatMap(\.items) }
    var scope: MacPaletteScope { MacPaletteScope.parse(query).scope }

    // MARK: - Presenting

    func present(restoreFocus: (() -> Void)? = nil) {
        guard !isPresented else { return }
        self.restoreFocus = restoreFocus
        query = ""
        isPresented = true
        selectionID = nil
        refresh()
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        query = ""
        sections = []
        selectionID = nil
        clearPending()
        allItems = []; allEntries = []; itemsByID = [:]; scopedEntries = [:]
        let restore = restoreFocus
        restoreFocus = nil
        restore?()
    }

    func toggle(restoreFocus: (() -> Void)? = nil) {
        isPresented ? dismiss() : present(restoreFocus: restoreFocus)
    }

    /// Esc goes back one step: a pending confirmation, then a non-empty query,
    /// then the palette.
    func handleEscape() {
        if pendingConfirmation != nil { cancelPending(); return }
        if query.isEmpty { dismiss() } else { query = "" }
    }

    // MARK: - Results

    /// Rebuilds the items from the live snapshot, then searches. The selection
    /// stays on its row while that row is still listed.
    func refresh() {
        guard isPresented else { return }
        let current = snapshot()
        loadRecentsIfScopeChanged(current)
        allItems = MacPaletteProvider.items(current)
        itemsByID = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        allEntries = MacPaletteMatcher.index(allItems)
        scopedEntries = [:]
        search(resetSelection: false)
    }

    private func entries(for scope: MacPaletteScope) -> [MacPaletteMatcher.Entry] {
        if scope == .all { return allEntries }
        if let cached = scopedEntries[scope] { return cached }
        let filtered = allEntries.filter { scope.includes($0.item.kind) }
        scopedEntries[scope] = filtered
        return filtered
    }

    private func search(resetSelection: Bool) {
        guard isPresented else { return }
        let parsed = MacPaletteScope.parse(query)
        let scoped = entries(for: parsed.scope)
        let resolvedRecents = recents.resolved(lookup: { itemsByID[$0] }).filter { parsed.scope.includes($0.kind) }
        if !parsed.text.isEmpty {
            let ranked = MacPaletteMatcher.rank(index: scoped, query: parsed.text, recentIDs: resolvedRecents.map(\.id), now: now())
            sections = ranked.isEmpty ? [] : [MacPaletteSection(title: nil, items: ranked)]
        } else if parsed.scope == .all {
            sections = MacPaletteProvider.sections(items: allItems, recents: resolvedRecents)
        } else {
            sections = MacPaletteProvider.capped([MacPaletteSection(title: nil, items: scoped.map(\.item))])
        }
        let enabled = rows.filter(\.isEnabled).map(\.id)
        // A new query starts at its best row: a row carried over from the old
        // query can sit far down the new list, and Return would run it.
        if !resetSelection, let selectionID, enabled.contains(selectionID) { return }
        selectionID = enabled.first
    }

    private func loadRecentsIfScopeChanged(_ s: MacPaletteSnapshot) {
        let key = MacPaletteRecentsStore.storageKey(dashboardID: s.dashboardID, profile: s.activeProfile)
        guard key != recentsScope else { return }
        recentsScope = key
        recents = recentsStore.load(dashboardID: s.dashboardID, profile: s.activeProfile)
    }

    // MARK: - Selection

    func move(_ move: MacSessionCursor.Move) {
        cancelPending()
        let enabled = rows.filter(\.isEnabled).map(\.id)
        guard !enabled.isEmpty else { selectionID = nil; return }
        selectionID = MacSessionCursor.moved(move, from: selectionID, in: enabled) ?? selectionID
        navigationToken &+= 1
    }

    func select(_ id: String) {
        guard rows.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        if selectionID != id { cancelPending() }
        selectionID = id
    }

    // MARK: - Running

    /// Return: confirms a pending row, else runs the selected one.
    func runSelected() {
        if pendingItem != nil { confirmPending(); return }
        guard let selectionID, let item = rows.first(where: { $0.id == selectionID }) else { return }
        run(item)
    }

    /// Runs the row, or (for a row that is hard to undo) asks first and stays
    /// open. Closes first (restoring focus), then performs the action once.
    func run(_ item: MacPaletteItem) {
        guard item.isEnabled, !item.isCurrent else { return }
        let current = snapshot()
        if let confirmation = confirmation(for: item, in: current) {
            pendingItem = item
            pendingConfirmation = confirmation
            if rows.contains(where: { $0.id == item.id }) { selectionID = item.id }
            return
        }
        perform(item, in: current)
    }

    func confirmPending() {
        guard let item = pendingItem else { return }
        clearPending()
        perform(item, in: snapshot())
    }

    func cancelPending() {
        guard pendingConfirmation != nil else { return }
        clearPending()
    }

    private func clearPending() {
        pendingItem = nil
        pendingConfirmation = nil
    }

    private func perform(_ item: MacPaletteItem, in current: MacPaletteSnapshot) {
        recents.record(item.id)
        recentsStore.save(recents, dashboardID: current.dashboardID, profile: current.activeProfile)
        dismiss()
        MacPaletteDispatcher.perform(item.action, with: calls)
    }

    /// Hard-to-undo actions ask first: the row's own confirmation (Stop
    /// Response, state-changing and unknown slash commands), a profile switch
    /// while a turn runs, and a slash command that would replace a typed draft.
    private func confirmation(for item: MacPaletteItem, in current: MacPaletteSnapshot) -> MacPaletteConfirmation? {
        if let own = item.confirmation { return own }
        switch item.action {
        case .switchProfile where current.isTurnRunning:
            return MacPaletteConfirmation(
                title: AppLocalization.string("Switch profile while a response is running?"),
                message: AppLocalization.string("A response is still in progress in this chat. Switching profile moves you out of it."),
                confirmTitle: AppLocalization.string("Switch Profile"))
        case .insertSlash where !calls.draftText().allSatisfy(\.isWhitespace):
            return MacPaletteConfirmation(
                title: AppLocalization.string("Replace your draft?"),
                message: AppLocalization.string("The text in the composer will be replaced with the command. Attachments are kept."),
                confirmTitle: AppLocalization.string("Replace Draft"))
        default:
            return nil
        }
    }
}
