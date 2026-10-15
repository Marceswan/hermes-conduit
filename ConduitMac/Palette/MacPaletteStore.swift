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
        didSet { if query != oldValue, isPresented { refresh() } }
    }
    @Published private(set) var sections: [MacPaletteSection] = []
    @Published private(set) var selectionID: String?

    var snapshot: () -> MacPaletteSnapshot = { .empty }
    var calls = MacPaletteCalls()
    /// Set by `bind(to:)` (MacPaletteBinding.swift); a plain var because an extension cannot store.
    var isBound = false

    private let recentsStore: MacPaletteRecentsStore
    private let now: () -> Date
    private var recents = MacPaletteRecents()
    private var recentsScope: String?
    private var restoreFocus: (() -> Void)?

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
        let restore = restoreFocus
        restoreFocus = nil
        restore?()
    }

    func toggle(restoreFocus: (() -> Void)? = nil) {
        isPresented ? dismiss() : present(restoreFocus: restoreFocus)
    }

    /// First Esc clears a non-empty query, the second closes.
    func handleEscape() {
        if query.isEmpty { dismiss() } else { query = "" }
    }

    // MARK: - Results

    func refresh() {
        guard isPresented else { return }
        let current = snapshot()
        loadRecentsIfScopeChanged(current)
        let parsed = MacPaletteScope.parse(query)
        let all = MacPaletteProvider.items(current).filter { parsed.scope.includes($0.kind) }
        let resolvedRecents = recents.resolved(in: all)
        if !parsed.text.isEmpty {
            let ranked = MacPaletteMatcher.rank(all, query: parsed.text, recentIDs: resolvedRecents.map(\.id), now: now())
            sections = ranked.isEmpty ? [] : [MacPaletteSection(title: nil, items: ranked)]
        } else if parsed.scope == .all {
            sections = MacPaletteProvider.sections(items: all, recents: resolvedRecents)
        } else {
            sections = MacPaletteProvider.capped([MacPaletteSection(title: nil, items: all)])
        }
        let enabled = rows.filter(\.isEnabled).map(\.id)
        if let selectionID, enabled.contains(selectionID) { return }
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
        let enabled = rows.filter(\.isEnabled).map(\.id)
        guard !enabled.isEmpty else { selectionID = nil; return }
        selectionID = MacSessionCursor.moved(move, from: selectionID, in: enabled) ?? selectionID
    }

    func select(_ id: String) {
        guard rows.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        selectionID = id
    }

    // MARK: - Running

    func runSelected() {
        guard let selectionID, let item = rows.first(where: { $0.id == selectionID }) else { return }
        run(item)
    }

    /// Closes first (restoring focus), then performs the action once.
    func run(_ item: MacPaletteItem) {
        guard item.isEnabled, !item.isCurrent else { return }
        let current = snapshot()
        recents.record(item.id)
        recentsStore.save(recents, dashboardID: current.dashboardID, profile: current.activeProfile)
        dismiss()
        MacPaletteDispatcher.perform(item.action, with: calls)
    }
}
