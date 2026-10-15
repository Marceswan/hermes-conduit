import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchStatusController: ObservableObject {
    static let shared = NotchStatusController()

    @Published private(set) var isCommandPinned = false
    let viewModel = NotchStatusViewModel()

    private let settings: NotchStatusSettings
    private var actions: NotchActions
    private let makeHost: () -> NotchPanelHosting
    private let screen: () -> NotchScreenMetrics?
    private let scheduler: NotchTimerScheduling
    private let monitor: NotchDismissMonitoring
    private let now: () -> Date
    private let dockStore: NotchDockStore
    private let connectedScreenIDs: () -> Set<UInt32>

    private var state: NotchStatusState
    private var host: NotchPanelHosting?
    private var source: NotchActivitySource?
    private var cancellables = Set<AnyCancellable>()
    private var timerCancels: [NotchTimer: () -> Void] = [:]
    private var cancelExpiry: (() -> Void)?
    private var lastItems: [AgentActivityItem] = []
    private var isBaseline = true
    private var baselined = false
    private var monitoring = false
    private var lastPanelVisible = false
    private var lastSurface: NotchSurface = .hidden
    private var isDragging = false
    private var currentScreenID: UInt32?

    init(
        settings: NotchStatusSettings = .shared,
        actions: NotchActions = NotchActions(openSession: { _ in }, openPane: { _ in }, newChat: {}, newChatEnabled: { false }, openConduit: {}),
        makeHost: (() -> NotchPanelHosting)? = nil,
        screen: (() -> NotchScreenMetrics?)? = nil,
        scheduler: NotchTimerScheduling? = nil,
        monitor: NotchDismissMonitoring? = nil,
        now: @escaping () -> Date = Date.init,
        dockStore: NotchDockStore = NotchDockStore(),
        connectedScreenIDs: @escaping () -> Set<UInt32> = { Set(MacFloatingPanelEnvironment.live.screens().compactMap(\.id)) }
    ) {
        self.settings = settings
        self.actions = actions
        self.screen = screen ?? { NotchScreenMetrics.main() }
        self.scheduler = scheduler ?? TaskTimerScheduler()
        self.monitor = monitor ?? NotchDismissMonitor()
        self.now = now
        self.dockStore = dockStore
        self.connectedScreenIDs = connectedScreenIDs
        self.state = NotchStatusState(mode: settings.mode)
        let vm = viewModel
        self.makeHost = makeHost ?? { NotchPanelHost(content: NotchStatusView(model: vm)) }
    }

    // MARK: binding

    /// Production entry (ConduitMacApp). The feed instance belongs to the
    /// shared base; the notch only reads it.
    func bind(to appState: AppState) {
        guard source == nil, let feed = AgentActivityFeed.shared else { return }
        bind(source: FeedNotchSource(feed: feed), actions: .live(appState: appState))
    }

    func bind(source: NotchActivitySource, actions: NotchActions) {
        self.source = source
        self.actions = actions
        cancellables.removeAll()
        wireViewModel()
        // The feed publishes on the main actor already; no hop (a hop would make the first emission asynchronous).
        // @Published emits before the property changes: use the emitted value, never `source.items`, inside a sink.
        source.itemsPublisher.sink { [weak self] in self?.itemsChanged($0) }.store(in: &cancellables)
        source.availabilityPublisher.sink { [weak self] in self?.availabilityChanged($0) }.store(in: &cancellables)
        source.isBaselinedPublisher.sink { [weak self] in self?.baselineChanged($0) }.store(in: &cancellables)
        settings.$mode.dropFirst().removeDuplicates().sink { [weak self] in self?.send(.mode($0)) }.store(in: &cancellables)
        viewModel.$contentHeight.removeDuplicates().sink { [weak self] _ in self?.render() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenParametersChanged() }.store(in: &cancellables)
        viewModel.availability = source.availability
        itemsChanged(source.items)
    }

    func toggleCommandPin() {
        send(.toggleCommandPin)
        isCommandPinned = state.isCommandPinned
    }

    func screenParametersChanged() { render() }

    /// Go > Reset Agent Status Position, and the double-click on the capsule or grip.
    func resetPosition() {
        if let id = currentScreenID { dockStore.clear(screenID: id) }
        render()
    }

    // MARK: inputs

    private func itemsChanged(_ items: [AgentActivityItem]) {
        let list = NotchRowBuilder.build(items: items, now: now())
        let t = (baselined && !isBaseline) ? NotchItemDiff.transitions(old: lastItems, new: items) : (newDecision: false, newFinish: false)
        isBaseline = false
        lastItems = items
        viewModel.list = list
        let ids = Set(list.rows.map(\.id))
        viewModel.submitting.formIntersection(ids)
        viewModel.failedRows.formIntersection(ids)
        scheduleExpiry(list.nextExpiry)
        send(.counts(list.counts, newDecision: t.newDecision, newFinish: t.newFinish))
    }

    /// Latched: the feed's `isBaselined` can flip false again while approval fetches are in flight, and
    /// that must not turn a real new approval into a silent baseline.
    private func baselineChanged(_ done: Bool) {
        guard done, !baselined else { return }
        baselined = true
        isBaseline = true               // what is already pending when the first poll finishes is silent
        itemsChanged(lastItems)
    }

    private func availabilityChanged(_ a: NotchAvailability) {
        viewModel.availability = a
        if a == .offline { send(.online(false)) } else {
            send(.online(true))
            isBaseline = true    // what is already there on (re)connect is a silent baseline
        }
    }

    private func send(_ input: NotchInput) {
        let effects = state.apply(input)
        for effect in effects { run(effect) }
        render()
    }

    private func run(_ effect: NotchEffect) {
        switch effect {
        case .schedule(let timer, let delay):
            timerCancels[timer]?()
            timerCancels[timer] = scheduler.schedule(after: delay) { [weak self] in
                self?.timerCancels[timer] = nil
                self?.send(.timer(timer))
            }
        case .cancel(let timer):
            timerCancels[timer]?(); timerCancels[timer] = nil
        case .announceAttention:
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: viewModel.accessibilitySummary,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func scheduleExpiry(_ at: Date?) {
        cancelExpiry?(); cancelExpiry = nil
        guard let at else { return }
        let delay = max(0, at.timeIntervalSince(now()))
        cancelExpiry = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.itemsChanged(self.lastItems)
        }
    }

    // MARK: rendering

    private func updateFeedHints() {
        let visible = state.surface != .hidden
        if visible != lastPanelVisible { lastPanelVisible = visible; source?.setPanelVisible(visible) }
        if state.surface == .expanded && lastSurface != .expanded { source?.refreshNow() }
        lastSurface = state.surface
    }

    private func render() {
        viewModel.surface = state.surface
        viewModel.buttonsEnabled = state.buttonsEnabled
        isCommandPinned = state.isCommandPinned
        updateMonitor()
        updateFeedHints()
        guard state.surface != .hidden, let metrics = screen() else {
            host?.hide()
            return
        }
        currentScreenID = metrics.id
        let standard = NotchGeometry.placement(for: metrics)
        let dock: MacEdgeDock? = {
            if case .docked(let d) = NotchPlacementResolver.choose(screenID: metrics.id, connectedScreenIDs: connectedScreenIDs(), store: dockStore) { return d }
            return nil
        }()
        let layout = NotchLayout.make(standardIsNotch: standard.notchWidth > 0, dock: dock)
        viewModel.placement = standard
        viewModel.layout = layout
        if state.surface == .expanded { viewModel.newChatEnabled = actions.newChatEnabled() }
        guard !isDragging else { return }          // never move the panel under the user's pointer
        let host = self.host ?? makeWiredHost()
        host.inwardSide = layout.inwardSide
        let wasVisible = host.isVisible
        let contentHeight = viewModel.contentHeight > 0 ? viewModel.contentHeight : 120
        if let dock {
            let size = state.surface == .compact
                ? layout.compactSize(contentLength: 0)
                : layout.expandedSize(contentHeight: contentHeight, screen: metrics.frame)
            host.setDock(dock, size: size)
        } else {
            let frame = state.surface == .compact
                ? NotchGeometry.compactFrame(standard, in: metrics, contentWidth: 0)
                : NotchGeometry.expandedFrame(standard, in: metrics, height: contentHeight)
            host.setFrame(frame, animated: wasVisible)
        }
        if !wasVisible { host.show() }
    }

    private func makeWiredHost() -> NotchPanelHosting {
        let host = makeHost()
        self.host = host
        host.onPointerChange = { [weak self] in self?.send($0 ? .hoverEntered : .hoverExited) }
        host.onDockChanged = { [weak self] in self?.dockChanged($0) }
        host.onDragStateChange = { [weak self] in self?.dragStateChanged($0) }
        return host
    }

    /// A drag release: persist per display. The drag-state callback follows and re-renders.
    private func dockChanged(_ dock: MacEdgeDock) {
        dockStore.save(dock)
    }

    private func dragStateChanged(_ dragging: Bool) {
        isDragging = dragging
        send(.dragging(dragging))      // render() inside send() skips placement while dragging and runs it after the drop
    }

    private func updateMonitor() {
        let wantsMonitor = state.surface == .expanded
        if wantsMonitor && !monitoring {
            monitoring = true
            monitor.start(onDismiss: { [weak self] in self?.send(.dismissRequested) },
                          isOwnWindow: { [weak self] w in w != nil && w === (self?.hostWindow) })
        } else if !wantsMonitor && monitoring {
            monitoring = false
            monitor.stop()
        }
    }

    private var hostWindow: NSWindow? { (host as? NotchPanelHost)?.panelForTesting }

    // MARK: view model actions

    private func wireViewModel() {
        viewModel.onOpenRow = { [weak self] row in
            guard let self else { return }
            switch row.target {
            case .session(let id): self.actions.openSession(id)
            case .kanban: self.actions.openPane(.kanban)
            case .cron: self.actions.openPane(.cron)
            case nil: self.actions.openConduit()
            }
        }
        viewModel.onOpenCron = { [weak self] in self?.actions.openPane(.cron) }
        viewModel.onOpenConduit = { [weak self] in self?.actions.openConduit() }
        viewModel.onOpenMore = { [weak self] in self?.actions.openConduit() }
        viewModel.onNewChat = { [weak self] in
            guard let self, self.actions.newChatEnabled() else { return }
            self.actions.newChat()
        }
        viewModel.onDismissRow = { [weak self] id in self?.source?.dismiss(id) }
        viewModel.onAction = { [weak self] row, action in self?.perform(action, on: row) }
        viewModel.onResetPosition = { [weak self] in self?.resetPosition() }
    }

    /// A button or menu item on an approval row.
    ///
    /// Nothing is parsed from text and no id is reconstructed: the answer goes to the feed under the
    /// exact id of the live item, and only after that item is read back from the feed and checked
    /// (still an approval, still waiting, same session as the row that was clicked, the choice
    /// allowed by `AgentActivityApprovalChoices`, and the command was shown in full).
    private func perform(_ action: NotchApprovalAction, on row: NotchRow) {
        guard viewModel.canChoose(rowID: row.id), let source else { return }
        guard let item = source.items.first(where: { $0.id == row.id }),
              item.kind == .approval, item.state == .needsUser,
              item.sessionKey == row.sessionKey,
              let approval = item.approval, approval.status == .pending else { return }

        let needsReview = NotchApprovalContent.make(approval).needsReview
        guard let choice = action.choice else {
            openSession(of: item)             // Review in Conduit: never answers
            return
        }
        guard AgentActivityApprovalChoices.isAllowed(choice, for: approval) else { return }
        if needsReview && choice != AgentActivityApprovalChoices.deny {
            openSession(of: item)             // the command was not shown in full: Allow opens the session instead
            return
        }

        viewModel.submitting.insert(item.id)
        viewModel.failedRows.remove(item.id)
        send(.interacted)
        let itemID = item.id
        Task { @MainActor [weak self] in
            let result = await source.respond(to: itemID, choice: choice)
            guard let self else { return }
            self.viewModel.submitting.remove(itemID)
            if case .failed = result { self.viewModel.failedRows.insert(itemID) }
            // .resolved and .alreadyResolved: the feed removes the row itself.
        }
    }

    private func openSession(of item: AgentActivityItem) {
        if let id = item.sessionId ?? item.sessionKey { actions.openSession(id) } else { actions.openConduit() }
    }
}
