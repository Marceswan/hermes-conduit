import Combine
import CoreSpotlight
import Foundation
import SwiftUI

/// Feeds `AppState`'s catalog, scope, archives and deletions to the indexer (D19).
/// The `...DidChange` methods are the seam tests drive; `bind(to:)` only wires
/// AppState's publishers to them.
@MainActor
final class MacSpotlightBinder {
    static let shared = MacSpotlightBinder()

    let indexer: MacSpotlightIndexer
    private let debounce: TimeInterval
    private var catalog: () -> [SessionSummary]
    private var archived: () -> [SessionSummary]
    private var deletionDetector = MacSessionDeletionDetector()
    private var pendingSync: DispatchWorkItem?
    private var bindings: Set<AnyCancellable> = []

    /// `indexer` nil means the real Core Spotlight index.
    init(indexer: MacSpotlightIndexer? = nil,
         debounce: TimeInterval = 2,
         catalog: @escaping () -> [SessionSummary] = { [] },
         archived: @escaping () -> [SessionSummary] = { [] }) {
        self.indexer = indexer ?? MacSpotlightIndexer(index: CoreSpotlightIndex())
        self.debounce = debounce
        self.catalog = catalog
        self.archived = archived
    }

    /// The live catalog the indexer mirrors, for the Settings toggle.
    var currentCatalog: () -> [SessionSummary] { catalog }

    func catalogDidChange() {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.indexer.catalogChanged(self.catalog())
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func scopeDidChange(_ scope: MacSpotlightScope?) {
        // A registry publish that leaves the scope alone must not eat a
        // pending catalog sync: nothing would reschedule it.
        guard indexer.hasScopeChange(to: scope) else { return }
        pendingSync?.cancel()
        indexer.setScope(scope, catalog: catalog())
    }

    func archivedDidChange() {
        indexer.sessionsArchived(archived())
    }

    /// Deletion is a session mutation that ended with its row gone from both
    /// the live and the archived list. A rename ends with the row still there;
    /// an archive moves it to the archived list. A row missing from a loaded
    /// page never reaches this path.
    func mutationDidChange(to id: String?) {
        if let deleted = deletionDetector.mutationChanged(to: id, catalog: catalog(), archived: archived()) {
            indexer.sessionDeleted(deleted)
        }
    }

    func bind(to appState: AppState) {
        guard bindings.isEmpty else { return }
        catalog = { [weak appState] in appState?.activeProfileSessions ?? [] }
        archived = { [weak appState] in appState?.archivedSessions ?? [] }
        let currentScope: () -> MacSpotlightScope? = { [weak appState] in
            guard let appState else { return nil }
            return MacSpotlightScope(dashboardID: appState.activeDashboardID, profile: appState.activeProfile)
        }
        // These publishers fire in willSet: hop to the next turn so the reads see the new values.
        appState.$activeProfile
            .sink { [weak self] _ in DispatchQueue.main.async { self?.scopeDidChange(currentScope()) } }
            .store(in: &bindings)
        // Two dashboards can share a profile name, so a dashboard switch alone fires no profile event.
        appState.$savedDashboardRegistry
            .sink { [weak self] _ in DispatchQueue.main.async { self?.scopeDidChange(currentScope()) } }
            .store(in: &bindings)
        appState.$sessions
            .sink { [weak self] _ in DispatchQueue.main.async { self?.catalogDidChange() } }
            .store(in: &bindings)
        appState.$archivedSessions
            .sink { [weak self] _ in DispatchQueue.main.async { self?.archivedDidChange() } }
            .store(in: &bindings)
        appState.$sessionMutationID
            .sink { [weak self] id in DispatchQueue.main.async { self?.mutationDidChange(to: id) } }
            .store(in: &bindings)
        scopeDidChange(currentScope())
    }
}

extension View {
    /// Mirrors the session catalog into Spotlight when the user opted in, and
    /// opens a chat when the user picks one of those results (D19). `openLink`
    /// parks the link until Hermes is connected (the app's `pendingExternalLink`).
    /// Two doors feed `MacSpotlightInbox`: this modifier's
    /// `.onContinueUserActivity` and the app delegate's
    /// `application(_:continue:restorationHandler:)`, which covers a cold launch.
    func macSpotlightBinding(appState: AppState, openLink: @escaping (ConduitAppLink) -> Void) -> some View {
        task {
            MacSpotlightBinder.shared.bind(to: appState)
            MacSpotlightInbox.shared.attach { raw in
                let key = appState.activeDashboardID?.uuidString ?? "none"
                switch MacSpotlightContinuation.outcome(rawID: raw, currentDashboardKey: key) {
                case .open(let link):
                    openLink(link)
                case .foreignDashboard:
                    appState.errorMessage = AppLocalization.string("That chat belongs to a different Hermes dashboard.")
                case .ignored:
                    break
                }
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            MacSpotlightInbox.shared.receive(userInfo: activity.userInfo)
        }
    }
}
