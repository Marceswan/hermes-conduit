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
enum MacHomeCronError: Error { case noConnection }

/// Maps AppState, the activity feed and the Kanban loader into `MacHomeInput`.
@MainActor
enum MacHomeBinding {
    static func makeModel(appState: AppState) -> MacHomeModel {
        MacHomeModel(sources: sources(
            appState: appState, feed: AgentActivityFeed.shared,
            kanban: makeKanbanLoader(appState: appState), cron: makeCronLoader(appState: appState)
        ))
    }

    /// The request `AppState.loadCronJobs` makes (same bridge path or client RPC, same
    /// decoding), into Home-owned state. It does not touch `cronJobs`, `cronJobsLoading`
    /// or `errorMessage`, so a failure here cannot reach the composer.
    static func makeCronLoader(appState: AppState) -> MacHomeCronLoader {
        MacHomeCronLoader { [weak appState] in
            guard let appState else { throw CancellationError() }
            let profile = appState.activeProfile
            let jobs: [CronJob]
            if let bridge = appState.dashboardTicketBridge {
                let result = try await bridge.requestJSON(path: DashboardPath.withExplicitProfile("/api/cron/jobs", profile: profile))
                let values = result["_array"] as? [Any] ?? result["jobs"] as? [Any] ?? []
                jobs = values.compactMap { value -> CronJob? in
                    guard JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                    return try? JSONDecoder().decode(CronJob.self, from: data)
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                guard profile == appState.activeProfile else { throw CancellationError() }
            } else if let client = appState.client {
                jobs = try await client.listCronJobs()
                guard profile == appState.activeProfile, appState.client === client else { throw CancellationError() }
            } else {
                throw MacHomeCronError.noConnection
            }
            return cronJobs(jobs)
        }
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
        cron: MacHomeCronLoader
    ) -> MacHomeModel.Sources {
        var publishers: [AnyPublisher<Void, Never>] = [
            appState.objectWillChange.eraseToAnyPublisher(),
            kanban.objectWillChange.eraseToAnyPublisher(),
            cron.objectWillChange.eraseToAnyPublisher(),
        ]
        if let feed { publishers.append(feed.objectWillChange.eraseToAnyPublisher()) }
        return MacHomeModel.Sources(
            input: { now in
                input(appState: appState, feed: feed, kanban: kanban.state, cron: cron.state, now: now)
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
        cron: MacHomeCronLoader,
        defaults: UserDefaults,
        isAppActive: @MainActor () -> Bool = { NSApplication.shared.isActive }
    ) async {
        // The poll loop is for a Home someone is looking at.
        if reason == .periodic, !isAppActive() { return }
        if reason == .appeared {
            // A new scope (or first appearance): never show the old dashboard's data.
            kanban.reset()
            cron.reset()
        }
        feed?.refreshNow()
        guard appState.isConnected else { return }
        // Cron is Home-owned and error-swallowing: a failure shows "Unavailable" on the card and
        // never reaches AppState.errorMessage (the composer renders it). It runs concurrently
        // with Kanban, so a slow one does not delay the other.
        async let cronLoad: Void = cron.load()
        if let bridge = appState.dashboardTicketBridge {
            await kanban.load(preferredSlug: savedBoardSlug(serverIdentity: bridge.baseURL, defaults: defaults))
        } else {
            kanban.markUnavailable()
        }
        await cronLoad
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
        cron: MacHomeCronState,
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
            cron: { if case .loaded(let jobs) = cron { return jobs } else { return nil } }(),
            cronUnavailable: cron == .unavailable,
            kanban: kanban,
            runtime: MacHomeRuntime(
                model: runtime.model, provider: runtime.provider, reasoningEffort: runtime.reasoningEffort,
                contextPercent: runtime.contextPercent, contextUsed: runtime.contextUsed, contextMax: runtime.contextMax
            ),
            subAgents: appState.activeAgents,
            // Stricter than the sidebar button (upstream's `canTapNewChat`, which can queue a chat):
            // Home calls `createNewSession` at once, a silent no-op without a live client, so Home
            // does not offer a dead button. `macNewChatDisabled` is the gate for such callers; the
            // live-client rule is `macHasLiveGateway`, which it also uses.
            canStartChat: !appState.macNewChatDisabled && appState.macHasLiveGateway
        )
    }

    /// Not private: the Dock badge (D31) reads the feed's availability with Home's rule.
    static func availability(_ feed: AgentActivityFeed?) -> MacHomeFeedAvailability {
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
