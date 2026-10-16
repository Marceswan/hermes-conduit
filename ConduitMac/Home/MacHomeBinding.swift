import AppKit
import Combine
import Foundation

/// Plain closures for what Home's buttons and rows do, so tests inject fakes.
struct MacHomeActions {
    var openSession: (String) -> Void
    var newChat: () -> Void
    var quickAsk: () -> Void
    var openPane: (SidebarTab) -> Void

    @MainActor
    static func live(appState: AppState, defaults: UserDefaults = .standard) -> MacHomeActions {
        MacHomeActions(
            // The two lines a sidebar row runs (ConduitCommands.open); requestOpenSession posts
            // .macSessionOpenRequested and MacDetailRouter returns the pane to Sessions.
            openSession: { [weak appState] id in
                guard let appState else { return }
                appState.dismissSidebarDrawer()
                // A live row can carry only a runtime alias; open the catalog row the sidebar would.
                _ = appState.requestOpenSession(MacQuickAskController.openableID(id, in: appState.sessions))
            },
            newChat: { [weak appState] in
                guard let appState, !appState.macNewChatDisabled else { return }
                Task { await appState.createNewSession() }
            },
            quickAsk: { MacQuickAskController.shared.show() },
            openPane: { tab in defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey) }
        )
    }
}

enum MacHomeKanbanError: Error { case noDashboard }

/// Maps AppState, the activity feed and the Kanban loader into `MacHomeInput`.
@MainActor
enum MacHomeBinding {
    /// Whether this Home session has loaded the cron list yet. Observable so that
    /// flipping it (reset on a scope change, set once loaded) reaches `Sources.changes`
    /// and rebuilds the snapshot without waiting for an unrelated publisher.
    @MainActor
    final class CronLoadState: ObservableObject { @Published var loaded = false }

    static func makeModel(appState: AppState) -> MacHomeModel {
        MacHomeModel(sources: sources(appState: appState, feed: AgentActivityFeed.shared, kanban: makeKanbanLoader(appState: appState)))
    }

    static func makeKanbanLoader(appState: AppState) -> MacHomeKanbanLoader {
        MacHomeKanbanLoader { [weak appState] slug in
            guard let bridge = appState?.dashboardTicketBridge else { throw MacHomeKanbanError.noDashboard }
            let board = try await KanbanService(requester: bridge).fetchBoard(slug: slug, includeArchived: false)
            return board.columns.map { column in
                let presentation = KanbanStatusPresentation.forStatus(column.name)
                return MacHomeKanbanColumnInput(
                    status: column.name, displayName: presentation.displayName,
                    sortOrder: presentation.sortOrder, count: column.tasks.count
                )
            }
        }
    }

    static func sources(
        appState: AppState,
        feed: AgentActivityFeed?,
        kanban: MacHomeKanbanLoader,
        defaults: UserDefaults = .standard,
        cron injectedCron: CronLoadState? = nil
    ) -> MacHomeModel.Sources {
        let cron = injectedCron ?? CronLoadState()
        var publishers: [AnyPublisher<Void, Never>] = [
            appState.objectWillChange.eraseToAnyPublisher(),
            kanban.objectWillChange.eraseToAnyPublisher(),
            cron.objectWillChange.eraseToAnyPublisher(),
        ]
        if let feed { publishers.append(feed.objectWillChange.eraseToAnyPublisher()) }
        return MacHomeModel.Sources(
            input: { now in
                input(appState: appState, feed: feed, kanban: kanban.state, cronLoaded: cron.loaded, now: now)
            },
            changes: Publishers.MergeMany(publishers).eraseToAnyPublisher(),
            refresh: { reason in
                await refresh(reason, appState: appState, feed: feed, kanban: kanban, cron: cron, defaults: defaults)
            }
        )
    }

    // MARK: Refresh

    static func refresh(
        _ reason: MacHomeRefreshReason,
        appState: AppState,
        feed: AgentActivityFeed?,
        kanban: MacHomeKanbanLoader,
        cron: CronLoadState,
        defaults: UserDefaults
    ) async {
        // The poll loop is for a Home someone is looking at.
        if reason == .periodic, !NSApplication.shared.isActive { return }
        if reason == .appeared {
            // A new scope (or first appearance): never show the old dashboard's data.
            kanban.reset()
            cron.loaded = false
        }
        feed?.refreshNow()
        guard appState.isConnected else { return }
        // Failures surface through the shared errorMessage path, like the Cron pane (spec open question 4).
        await appState.loadCronJobs()
        // A superseded run (scope change, leaving Home) must not mark the new scope loaded.
        if Task.isCancelled { return }
        cron.loaded = true
        guard let bridge = appState.dashboardTicketBridge else {
            kanban.markUnavailable()
            return
        }
        await kanban.load(preferredSlug: savedBoardSlug(serverIdentity: bridge.baseURL, defaults: defaults))
    }

    /// The board the user last picked for this server (KanbanStore writes it; Home only reads).
    static func savedBoardSlug(serverIdentity: String, defaults: UserDefaults) -> String? {
        defaults.string(forKey: KanbanStore.scopedBoardKey(serverIdentity: serverIdentity))
    }

    // MARK: Input

    static func input(
        appState: AppState,
        feed: AgentActivityFeed?,
        kanban: MacHomeKanbanInput,
        cronLoaded: Bool,
        now: Date
    ) -> MacHomeInput {
        let state: MacHomeConnectionState = appState.isConnected ? .connected : (appState.isConnecting ? .connecting : .offline)
        let sessions = appState.activeProfileSessions
            .filter { !$0.isArchived }
            .map { session in
                MacHomeSession(
                    id: session.id, title: session.title, model: session.model,
                    lastActivity: session.lastActivityAt.map { Date(timeIntervalSince1970: $0) },
                    isUnread: appState.isSessionUnread(session)
                )
            }
        let runtime = appState.runtime
        return MacHomeInput(
            now: now,
            scope: "\(appState.activeDashboardID?.uuidString ?? "none")|\(appState.activeProfile)|\(appState.isConnected)",
            connection: MacHomeConnection(
                state: state,
                dashboardLabel: appState.savedDashboardRegistry.activeDashboardLabel,
                profileName: appState.profileDisplayName(appState.activeProfile)
            ),
            sessions: sessions,
            live: feed.map { liveItems($0.items) } ?? [],
            feed: availability(feed),
            cron: cronLoaded ? cronJobs(appState.cronJobs) : nil,
            kanban: kanban,
            runtime: MacHomeRuntime(
                model: runtime.model, provider: runtime.provider, reasoningEffort: runtime.reasoningEffort,
                contextPercent: runtime.contextPercent, contextUsed: runtime.contextUsed, contextMax: runtime.contextMax
            ),
            subAgents: appState.activeAgents,
            // Stricter than the sidebar button (`macNewChatDisabled` alone): `createNewSession`
            // is a silent no-op without a live client, so Home does not offer a dead button.
            // The live-client rule is the one `macNewChatDisabled` itself uses (hasLiveGateway).
            canStartChat: !appState.macNewChatDisabled
                && appState.isConnected && !appState.isConnecting && appState.client != nil
        )
    }

    private static func availability(_ feed: AgentActivityFeed?) -> MacHomeFeedAvailability {
        guard let feed else { return .offline }
        switch feed.availability {
        case .offline: return .offline
        case .eventsOnly: return .eventsOnly
        case .live: return feed.isBaselined ? .live : .loading
        }
    }

    /// Unfinished turns and decisions only; Kanban and cron feed rows are the notch plan's.
    static func liveItems(_ items: [AgentActivityItem]) -> [MacHomeLiveItem] {
        items.compactMap { item in
            let kind: MacHomeLiveItem.Kind
            switch item.kind {
            case .turn: kind = .turn
            case .approval: kind = .approval
            case .clarify: kind = .clarify
            case .inputPrompt: kind = .inputPrompt
            case .kanban, .cron: return nil
            }
            let needsUser: Bool
            switch item.state {
            case .needsUser: needsUser = true
            case .working: needsUser = false
            case .blocked, .finished: return nil
            }
            return MacHomeLiveItem(
                id: item.id,
                sessionKey: item.sessionKey ?? item.sessionId,
                // The same id the notch opens (NotchStatusController.openSession(of:)).
                openID: item.sessionId ?? item.sessionKey,
                kind: kind, needsUser: needsUser,
                title: item.title, detail: item.detail, since: item.since
            )
        }
    }

    static func cronJobs(_ jobs: [CronJob]) -> [MacHomeCronJob] {
        jobs.map { job in
            MacHomeCronJob(
                id: job.id,
                name: job.displayName,
                isActive: job.isActive,
                isFinished: job.isFinished,
                hasError: !(job.lastError ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                nextRun: job.isFinished ? nil : MacHomeDates.parse(job.nextRunAt)
            )
        }
    }
}
