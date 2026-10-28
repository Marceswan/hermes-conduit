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
    private let screenForID: (UInt32) -> NotchScreenMetrics?
    private let glassAvailable: Bool
    private let reduceTransparency: () -> Bool

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
    /// The display the user last dropped the surface on. It stays there (instead of snapping back to
    /// `NSScreen.main`) while that display is connected and still has a saved dock.
    private var homeDisplayID: UInt32?
    private var lastNextExpiry: Date?
    /// What the panel was last told, so an unchanged style or setting does not touch the window.
    private var appliedFollowsSystem: Bool?

    init(
        settings: NotchStatusSettings = .shared,
        actions: NotchActions = NotchActions(openSession: { _ in }, openPane: { _ in }, newChat: {}, newChatEnabled: { false }, openConduit: {}),
        makeHost: (() -> NotchPanelHosting)? = nil,
        screen: (() -> NotchScreenMetrics?)? = nil,
        scheduler: NotchTimerScheduling? = nil,
        monitor: NotchDismissMonitoring? = nil,
        now: @escaping () -> Date = Date.init,
        dockStore: NotchDockStore = NotchDockStore(),
        connectedScreenIDs: @escaping () -> Set<UInt32> = { Set(MacFloatingPanelEnvironment.live.screens().compactMap(\.id)) },
        screenForID: ((UInt32) -> NotchScreenMetrics?)? = nil,
        glassAvailable: Bool = NotchSurfaceStyle.glassAvailable,
        reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    ) {
        self.settings = settings
        self.actions = actions
        self.screen = screen ?? { NotchScreenMetrics.main() }
        self.scheduler = scheduler ?? TaskTimerScheduler()
        self.monitor = monitor ?? NotchDismissMonitor()
        self.now = now
        self.dockStore = dockStore
        self.connectedScreenIDs = connectedScreenIDs
        self.screenForID = screenForID ?? { NotchScreenMetrics.display(id: $0) }
        self.glassAvailable = glassAvailable
        self.reduceTransparency = reduceTransparency
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
        settings.$mode.dropFirst().removeDuplicates().sink { [weak self] in
            self?.send(.mode($0))
            self?.refreshExpiryTimer()
        }.store(in: &cancellables)
        // @Published emits before the property changes: pass the emitted style along, never re-read `settings`.
        settings.$surfaceStyle.removeDuplicates().sink { [weak self] in self?.surfaceStyleChanged($0) }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.surfaceStyleChanged(self.viewModel.surfaceStyle)
            }.store(in: &cancellables)
        viewModel.$contentHeight.removeDuplicates().sink { [weak self] _ in self?.render() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenParametersChanged() }.store(in: &cancellables)
        viewModel.availability = source.availability
        itemsChanged(source.items)
    }

    func toggleCommandPin() {
        send(.toggleCommandPin)
        isCommandPinned = state.isCommandPinned
        refreshExpiryTimer()
    }

    func screenParametersChanged() { render() }

    // MARK: surface style

    /// Chosen style or Reduce Transparency changed: update what the view draws and what the panel's
    /// appearance is, now if the panel exists, else when it is made.
    private func surfaceStyleChanged(_ style: NotchSurfaceStyle) {
        let reduce = reduceTransparency()
        if viewModel.surfaceStyle != style { viewModel.surfaceStyle = style }
        if viewModel.reduceTransparency != reduce { viewModel.reduceTransparency = reduce }
        if viewModel.glassAvailable != glassAvailable { viewModel.glassAvailable = glassAvailable }
        applyPanelAppearance()
    }

    private func applyPanelAppearance(force: Bool = false) {
        guard let host else { return }
        let follows = viewModel.followsSystemAppearance
        guard force || appliedFollowsSystem != follows else { return }
        appliedFollowsSystem = follows
        host.setPanelAppearance(follows ? nil : NSAppearance(named: .darkAqua))
    }

    /// Go > Reset Agent Status Position, and the double-click on the capsule or grip.
    func resetPosition() {
        if let id = currentScreenID { dockStore.clear(screenID: id) }
        homeDisplayID = nil
        render()
    }

    // MARK: inputs

    private func itemsChanged(_ items: [AgentActivityItem]) {
        let list = NotchRowBuilder.build(items: items, now: now())
        let t = (baselined && !isBaseline) ? NotchItemDiff.transitions(old: lastItems, new: items) : (newDecision: false, newFinish: false)
        isBaseline = false
        lastItems = items
        // @Published publishes on every assignment, equal or not, and each publish re-evaluates the
        // whole panel. Assign only on a real change, so a feed emission that changes nothing the
        // panel shows costs one row build and no view update.
        if viewModel.list != list { viewModel.list = list }
        let ids = Set(list.rows.map(\.id))
        let submitting = viewModel.submitting.intersection(ids)
        if submitting != viewModel.submitting { viewModel.submitting = submitting }
        let failed = viewModel.failedRows.intersection(ids)
        if failed != viewModel.failedRows { viewModel.failedRows = failed }
        lastNextExpiry = list.nextExpiry
        refreshExpiryTimer()
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
        if viewModel.availability != a { viewModel.availability = a }
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

    /// The "done" row expiry timer runs only while something can show it: never in Off mode
    /// (unless Show Agent Status pinned the panel), so Off leaves no timer behind.
    private func refreshExpiryTimer() {
        let live = state.mode != .off || state.isCommandPinned
        scheduleExpiry(live ? lastNextExpiry : nil)
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
        if viewModel.surface != state.surface { viewModel.surface = state.surface }
        if viewModel.buttonsEnabled != state.buttonsEnabled { viewModel.buttonsEnabled = state.buttonsEnabled }
        if isCommandPinned != state.isCommandPinned { isCommandPinned = state.isCommandPinned }
        updateMonitor()
        updateFeedHints()
        guard state.surface != .hidden, let metrics = targetScreen() else {
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
        if viewModel.placement != standard { viewModel.placement = standard }
        if viewModel.layout != layout { viewModel.layout = layout }
        if state.surface == .expanded {
            let enabled = actions.newChatEnabled()
            if viewModel.newChatEnabled != enabled { viewModel.newChatEnabled = enabled }
        }
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

    /// The display the user dropped the surface on while it is connected and keeps a saved dock,
    /// else the main display (follows focus). Without this, a drop on another display is undone by
    /// the next render, which would look up the main display's placement.
    private func targetScreen() -> NotchScreenMetrics? {
        if let home = homeDisplayID, connectedScreenIDs().contains(home), dockStore.dock(forScreen: home) != nil,
           let metrics = screenForID(home) {
            return metrics
        }
        return screen()
    }

    private func makeWiredHost() -> NotchPanelHosting {
        let host = makeHost()
        self.host = host
        applyPanelAppearance(force: true)
        host.onPointerChange = { [weak self] in self?.send($0 ? .hoverEntered : .hoverExited) }
        host.onDockChanged = { [weak self] in self?.dockChanged($0) }
        host.onDragStateChange = { [weak self] in self?.dragStateChanged($0) }
        return host
    }

    /// A drag release: persist per display. The drag-state callback follows and re-renders.
    private func dockChanged(_ dock: MacEdgeDock) {
        dockStore.save(dock)
        if let id = dock.screenID { homeDisplayID = id }
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

    private enum ApprovalDecision {
        case ignore
        /// Not answered: open the session so the user reads the whole request there.
        case review(AgentActivityItem)
        /// What the row showed is no longer what the feed holds; the rows are rebuilt from the live items.
        case stale
        case send(choice: String, itemID: String)
    }

    /// Decides what a button or menu item on an approval row may do. Nothing is parsed from text and
    /// no id is reconstructed: the live item is read back from the feed by the row's exact id and must
    /// still be an approval, waiting, in the same session as the row, with a pending payload. The
    /// choice must be allowed by `AgentActivityApprovalChoices`. Anything but Deny also needs the
    /// command to have been shown in full and unchanged, and the live command to be the one the row
    /// showed (digest), because the feed can replace a command under the same id without an event.
    private func decide(_ action: NotchApprovalAction, on row: NotchRow, recheck: Bool = false) -> ApprovalDecision {
        // On a recheck the row is already marked as submitting by this very click.
        guard recheck || viewModel.canChoose(rowID: row.id), let source else { return .ignore }
        guard let item = source.items.first(where: { $0.id == row.id }),
              item.kind == .approval, item.state == .needsUser,
              item.sessionKey == row.sessionKey,
              let approval = item.approval, approval.status == .pending else { return .ignore }

        guard let choice = action.choice else { return .review(item) }      // Review in Conduit: never answers
        guard AgentActivityApprovalChoices.isAllowed(choice, for: approval) else { return .ignore }
        if choice == AgentActivityApprovalChoices.deny { return .send(choice: choice, itemID: item.id) }

        guard case .approval(_, let shown) = row.inline, !shown.needsReview,
              !NotchApprovalContent.make(approval).needsReview else { return .review(item) }
        guard shown.commandDigest == MacNotificationContent.commandDigest(approval.command) else { return .stale }
        return .send(choice: choice, itemID: item.id)
    }

    private func perform(_ action: NotchApprovalAction, on row: NotchRow) {
        switch decide(action, on: row) {
        case .ignore:
            return
        case .review(let item):
            openSession(of: item)
        case .stale:
            if let source { itemsChanged(source.items) }       // show what the feed holds now; the next click is a fresh decision
        case .send(let choice, let itemID):
            guard let source else { return }
            viewModel.submitting.insert(itemID)
            viewModel.failedRows.remove(itemID)
            send(.interacted)
            Task { @MainActor [weak self] in
                // The task starts on a later main-actor turn: check again, then call the feed with no
                // suspension in between, so the command cannot change after the check.
                guard let self else { return }
                guard case .send(let c, let id) = self.decide(action, on: row, recheck: true), c == choice, id == itemID else {
                    self.viewModel.submitting.remove(itemID)
                    return
                }
                let result = await source.respond(to: id, choice: c)
                self.viewModel.submitting.remove(itemID)
                if case .failed = result { self.viewModel.failedRows.insert(itemID) }
                // .resolved and .alreadyResolved: the feed removes the row itself.
            }
        }
    }

    private func openSession(of item: AgentActivityItem) {
        if let id = MacActivitySessionTarget.openID(of: item) { actions.openSession(id) } else { actions.openConduit() }
    }
}
