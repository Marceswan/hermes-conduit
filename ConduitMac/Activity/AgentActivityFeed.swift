import Combine
import Foundation

/// What the agent is doing, for any Mac surface: the notch status, notifications,
/// and whatever comes next. Driven by the stream hub (every session on this
/// socket) plus its own `session.active_list` poll. Read-mostly: it never writes
/// AppState; the one write path is approval response (`respond`).
@MainActor
final class AgentActivityFeed: ObservableObject {
    /// Set by `MacActivityBootstrap`.
    static var shared: AgentActivityFeed?

    @Published private(set) var items: [AgentActivityItem] = []
    @Published private(set) var availability: AgentActivityAvailability = .offline
    /// True once the first poll and its approval fetches finished; call `snapshot()` after it.
    @Published private(set) var isBaselined = false
    let events: AnyPublisher<AgentActivityEvent, Never>

    private let subject: PassthroughSubject<AgentActivityEvent, Never>
    let sources: AgentActivitySources
    private let hub: MacStreamEventHub
    private let clock: () -> Date
    private let tickSleep: AgentActivityPoller.Sleep
    let poller: AgentActivityPoller

    private(set) var state = AgentActivityState()
    private var nextEventId: UInt64 = 1
    private var started = false
    private var hubToken: MacStreamEventHub.Token?
    private var fetchTasks: [String: Task<Void, Never>] = [:]
    private var respondInFlight: Set<String> = []
    private var tickTask: Task<Void, Never>?
    private var panelVisible = false
    private var activeListUnsupported = false
    private var catalog: [SessionSummary] = []
    private var activeSessionId: String?

    init(
        sources: AgentActivitySources,
        hub: MacStreamEventHub? = nil,
        clock: @escaping () -> Date = Date.init,
        pollSleep: @escaping AgentActivityPoller.Sleep = AgentActivityPoller.liveSleep,
        tickSleep: @escaping AgentActivityPoller.Sleep = AgentActivityPoller.liveSleep
    ) {
        let subject = PassthroughSubject<AgentActivityEvent, Never>()
        self.subject = subject
        self.events = subject.eraseToAnyPublisher()
        self.sources = sources
        self.hub = hub ?? .shared
        self.clock = clock
        self.tickSleep = tickSleep
        self.poller = AgentActivityPoller(sources: sources, sleep: pollSleep)
        poller.isLive = { [weak self] in self?.hasLiveWork ?? false }
        poller.isPanelVisible = { [weak self] in self?.panelVisible ?? false }
        poller.onRows = { [weak self] rows in self?.apply(.activeList(rows)) }
        poller.onUnavailable = { [weak self] in
            guard let self else { return }
            self.activeListUnsupported = true
            self.apply(.activeListUnavailable)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        hubToken = hub.subscribe { [weak self] event in self?.observe(event) }
        updateAvailability()
        poller.start()
    }

    func stop() {
        guard started else { return }
        started = false
        if let hubToken { hub.unsubscribe(hubToken) }
        hubToken = nil
        poller.stop()
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks = [:]
        tickTask?.cancel()
        tickTask = nil
        apply(.reset(profile: state.scope.profile, dashboardID: state.scope.dashboardID))
        updateAvailability()
    }

    // MARK: - Input

    /// Called for every stream event (via the hub). Ignored while stopped.
    func observe(_ event: StreamEvent) {
        guard started else { return }
        apply(.stream(event))
    }

    func setActiveSession(_ id: String?) {
        activeSessionId = id
        apply(.activeSession(id: id))
    }

    func setCatalog(_ sessions: [SessionSummary]) {
        catalog = sessions
        apply(.catalog(sessions))
    }

    /// A profile or dashboard switch: reset silently and take a new baseline.
    func setScope(profile: String, dashboardID: String) {
        guard state.scope != AgentActivityState.Scope(profile: profile, dashboardID: dashboardID) else { return }
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks = [:]
        apply(.reset(profile: profile, dashboardID: dashboardID))
        apply(.activeSession(id: activeSessionId))
        apply(.catalog(catalog))
        poller.resetCapability()
        activeListUnsupported = false
        refreshNow()
    }

    /// A visible surface shortens the idle poll interval and asks for a fresh poll.
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshNow() }
    }

    func refreshNow() {
        guard started else { return }
        Task { await poller.pollNow() }
    }

    func snapshot() -> [AgentActivityItem] {
        items.filter { !$0.isFinished }
    }

    /// Finished rows only.
    func dismiss(_ id: String) {
        apply(.dismiss(itemId: id))
    }

    func respond(to id: String, choice: String) async -> AgentActivityRespondResult {
        guard let item = state.items[id], item.kind == .approval,
              let approval = item.approval, let requestId = approval.requestId,
              let sessionId = item.sessionId else {
            return .failed(AgentActivityRespondFailure.notAnswerable)
        }
        guard AgentActivityApprovalChoices.isAllowed(choice, for: approval) else {
            return .failed(AgentActivityRespondFailure.choiceNotOffered)
        }
        guard sources.isConnected else { return .failed(AgentActivityRespondFailure.notConnected) }
        guard respondInFlight.insert(id).inserted else { return .failed(AgentActivityRespondFailure.inFlight) }
        defer { respondInFlight.remove(id) }

        apply(.respondStarted(itemId: id))
        do {
            let resolved: Bool
            if item.isActiveSession, let viaCard = await sources.respondViaActiveCard(requestId: requestId, choice: choice) {
                guard viaCard else {
                    apply(.respondFailed(itemId: id, message: AgentActivityRespondFailure.sendFailed))
                    return .failed(AgentActivityRespondFailure.sendFailed)
                }
                resolved = true
            } else {
                resolved = try await sources.respondToApproval(sessionId: sessionId, requestId: requestId, choice: choice)
            }
            apply(.respondResolved(itemId: id, alreadyResolved: !resolved))
            return resolved ? .resolved : .alreadyResolved
        } catch {
            if AgentActivityRpc.isExpiredPrompt(error) {
                apply(.respondResolved(itemId: id, alreadyResolved: true))
                return .alreadyResolved
            }
            let message = UserFacingError.message(for: error)
            apply(.respondFailed(itemId: id, message: message))
            return .failed(message)
        }
    }

    // MARK: - Core

    private var hasLiveWork: Bool { items.contains { !$0.isFinished } }
    private var needsTick: Bool { !state.items.isEmpty }

    func apply(_ input: AgentActivityInput) {
        let output = AgentActivityReducer.reduce(state, input, now: clock())
        state = output.state
        let ordered = AgentActivityItem.ordered(Array(state.items.values))
        if ordered != items { items = ordered }
        let baselined = !state.baselinePending && state.waiting.isEmpty
        if baselined != isBaselined { isBaselined = baselined }
        updateAvailability()
        for payload in output.payloads {
            subject.send(AgentActivityEvent(eventId: nextEventId, at: clock(), payload: payload))
            nextEventId += 1
        }
        startFetches()
        updateTicker()
    }

    func updateAvailability() {
        let next: AgentActivityAvailability
        if !started || !sources.isConnected {
            next = .offline
        } else {
            next = activeListUnsupported ? .eventsOnly : .live
        }
        if next != availability { availability = next }
    }

    /// One `approval.pending` per waiting session whose content is unknown.
    private func startFetches() {
        let targets = AgentActivityReducer.fetchTargets(state)
        guard !targets.isEmpty else { return }
        // Mark every target first, straight through the reducer (no events, no recursion).
        for runtime in targets {
            state = AgentActivityReducer.reduce(state, .fetchRequested(runtimeSessionId: runtime), now: clock()).state
        }
        for runtime in targets {
            fetchTasks[runtime] = Task { [weak self] in
                guard let self else { return }
                do {
                    let list = try await self.sources.pendingApprovals(sessionId: runtime)
                    guard !Task.isCancelled else { return }
                    self.apply(.pendingApprovals(runtimeSessionId: runtime, list))
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.apply(.pendingApprovalsFailed(runtimeSessionId: runtime))
                }
                self.fetchTasks[runtime] = nil
            }
        }
    }

    private func updateTicker() {
        guard started, needsTick, tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let tickSleep = self?.tickSleep else { return }
                do { try await tickSleep(1) } catch { return }
                guard let self else { return }
                self.apply(.tick)
                if !self.needsTick {
                    self.tickTask = nil
                    return
                }
            }
        }
    }
}

/// Stable codes carried in `AgentActivityRespondResult.failed(_)` when no RPC
/// was attempted or the open card failed. Not user-facing: consumers localize them.
enum AgentActivityRespondFailure {
    static let notAnswerable = "not_answerable"
    static let choiceNotOffered = "choice_not_offered"
    static let notConnected = "not_connected"
    static let inFlight = "in_flight"
    static let sendFailed = "send_failed"
}
