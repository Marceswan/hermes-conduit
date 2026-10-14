import Combine
import Foundation

extension SessionSummary {
    /// Tabs match a session by its id or any of its alternate ids.
    func macMatches(_ id: String) -> Bool { self.id == id || alternateIds.contains(id) }
}

/// Spots a deletion without AppState edits: a session mutation (rename,
/// archive or delete) ended and its session, listed when the mutation began,
/// is in neither the live nor the archived list. Archiving moves the row to
/// the archived list; only a delete clears it from both.
struct MacSessionDeletionDetector {
    private var pending: (id: String, wasListed: Bool)?

    mutating func mutationChanged(to id: String?, catalog: [SessionSummary], archived: [SessionSummary]) -> String? {
        if let id {
            pending = (id, catalog.contains { $0.macMatches(id) })
            return nil
        }
        defer { pending = nil }
        guard let pending, pending.wasListed,
              !catalog.contains(where: { $0.macMatches(pending.id) }),
              !archived.contains(where: { $0.macMatches(pending.id) }) else { return nil }
        return pending.id
    }
}

/// The session tabs of the current dashboard and profile (D11).
@MainActor
final class MacSessionTabsStore: ObservableObject {
    static let shared = MacSessionTabsStore()

    @Published private(set) var model = MacSessionTabsModel()

    var openSession: (String) -> Void = { _ in }
    var startNewChat: () -> Void = {}
    var activeChatIsEmpty: () -> Bool = { false }
    var scrollActiveToTop: () -> Void = {}

    private let defaults: UserDefaults
    private var scopeKey: String?
    private var deletionDetector = MacSessionDeletionDetector()
    private var bindings: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func storageKey(dashboardID: UUID?, profile: String) -> String {
        "conduit.mac.sessionTabs.\(dashboardID?.uuidString ?? "none").\(profile)"
    }

    func setScope(dashboardID: UUID?, profile: String) {
        let key = Self.storageKey(dashboardID: dashboardID, profile: profile)
        guard key != scopeKey else { return }
        save()
        scopeKey = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(MacSessionTabsModel.self, from: data) {
            model = stored
            if let active = model.activeID, model.index(of: active) == nil { model.clearActive() }
        } else {
            model = MacSessionTabsModel()
        }
    }

    func activeSessionChanged(_ id: String?, title: String?) {
        if let id { model.open(id, title: title ?? model.tabs.first { $0.id == id }?.title ?? "") }
        else { model.clearActive() }
        save()
    }

    func select(_ id: String) {
        guard model.index(of: id) != nil else { return }
        if model.activeID == id { scrollActiveToTop(); return }
        openSession(id)
    }

    func selectShortcut(_ n: Int) {
        guard let id = model.id(forShortcut: n), id != model.activeID else { return }
        openSession(id)
    }

    func selectNeighbor(_ direction: MacSessionTabsModel.Direction) {
        guard let id = model.neighbor(direction) else { return }
        openSession(id)
    }

    /// nil closes the active tab (Cmd-W).
    func close(_ id: String?) {
        guard let id = id ?? model.activeID else { return }
        if model.tabs.count == 1, model.activeID == id, activeChatIsEmpty() { return }
        switch model.close(id) {
        case .activate(let next): openSession(next)
        case .closedLast: startNewChat()
        case .closedInactive, .notFound: break
        }
        save()
    }

    func reopen() {
        guard let id = model.reopen() else { return }
        save()
        openSession(id)
    }

    func sessionDeleted(_ id: String) {
        model.remove(id)
        save()
    }

    func openFailed(_ id: String) {
        model.markUnavailable(id)
        save()
    }

    /// Re-keys tabs whose id became an alternate id, and refreshes titles.
    /// Never removes a tab: the catalog is paged.
    func catalogChanged(_ sessions: [SessionSummary]) {
        var changed = model
        for tab in model.tabs {
            guard let session = sessions.first(where: { $0.macMatches(tab.id) }) else { continue }
            if session.id != tab.id { changed.rekey(tab.id, to: session.id) }
            changed.updateTitle(session.id, session.title)
        }
        guard changed != model else { return }
        model = changed
        save()
    }

    func bind(to appState: AppState) {
        guard bindings.isEmpty else { return }
        openSession = { [weak appState, weak self] id in
            appState?.dismissSidebarDrawer()
            _ = appState?.requestOpenSession(id) { self?.openFailed(id) }
        }
        startNewChat = { [weak appState] in Task { await appState?.createNewSession() } }
        activeChatIsEmpty = { [weak appState] in appState?.messages.isEmpty ?? false }
        scrollActiveToTop = { [weak appState] in appState?.requestChatScrollToTop() }

        // willSet sinks: use the emitted value for the property that changed.
        appState.$activeProfile
            .sink { [weak self, weak appState] profile in
                self?.setScope(dashboardID: appState?.activeDashboardID, profile: profile)
            }
            .store(in: &bindings)
        // Two dashboards can share a profile name, so a dashboard switch alone fires no profile event.
        appState.$savedDashboardRegistry
            .sink { [weak self, weak appState] registry in
                self?.setScope(dashboardID: registry.activeDashboardID, profile: appState?.activeProfile ?? "default")
            }
            .store(in: &bindings)
        appState.$activeSessionId
            .removeDuplicates()
            .sink { [weak self, weak appState] _ in
                // didSet has run; read the id and summary on the next turn so both are current.
                DispatchQueue.main.async {
                    guard let self, let appState else { return }
                    self.setScope(dashboardID: appState.activeDashboardID, profile: appState.activeProfile)
                    let id = appState.activeSessionId
                    let summary = appState.activeChatSessionSummary
                    // Outside the loaded catalog displayedChatTitle is the previous chat's: keep a known tab's title.
                    let knownTab = id.map { self.model.index(of: $0) != nil } ?? false
                    let title = summary?.title ?? (id == nil || knownTab ? nil : appState.displayedChatTitle)
                    self.activeSessionChanged(summary?.id ?? id, title: title)
                }
            }
            .store(in: &bindings)
        appState.$sessions
            .sink { [weak self] sessions in DispatchQueue.main.async { self?.catalogChanged(sessions) } }
            .store(in: &bindings)
        appState.$sessionMutationID
            .sink { [weak self, weak appState] id in
                DispatchQueue.main.async {
                    guard let self, let appState else { return }
                    if let deleted = self.deletionDetector.mutationChanged(to: id, catalog: appState.sessions, archived: appState.archivedSessions) {
                        self.sessionDeleted(deleted)
                    }
                }
            }
            .store(in: &bindings)
    }

    private func save() {
        guard let scopeKey, let data = try? JSONEncoder().encode(model) else { return }
        defaults.set(data, forKey: scopeKey)
    }
}
