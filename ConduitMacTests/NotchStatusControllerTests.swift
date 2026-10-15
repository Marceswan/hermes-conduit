import Combine
import XCTest
@testable import ConduitMac

@MainActor
final class FakeNotchSource: NotchActivitySource {
    let itemsSubject = CurrentValueSubject<[AgentActivityItem], Never>([])
    let availabilitySubject = CurrentValueSubject<NotchAvailability, Never>(.live)
    var responses: [(id: String, choice: String)] = []
    var result: NotchRespondResult = .resolved
    var dismissed: [String] = []
    let isBaselinedSubject = CurrentValueSubject<Bool, Never>(true)
    var panelVisibleCalls: [Bool] = []
    var refreshCount = 0
    var items: [AgentActivityItem] { itemsSubject.value }
    var isBaselined: Bool { isBaselinedSubject.value }
    var isBaselinedPublisher: AnyPublisher<Bool, Never> { isBaselinedSubject.eraseToAnyPublisher() }
    func setPanelVisible(_ visible: Bool) { panelVisibleCalls.append(visible) }
    func refreshNow() { refreshCount += 1 }
    var itemsPublisher: AnyPublisher<[AgentActivityItem], Never> { itemsSubject.eraseToAnyPublisher() }
    var availability: NotchAvailability { availabilitySubject.value }
    var availabilityPublisher: AnyPublisher<NotchAvailability, Never> { availabilitySubject.eraseToAnyPublisher() }
    func respond(to id: String, choice: String) async -> NotchRespondResult { responses.append((id, choice)); return result }
    func dismiss(_ id: String) { dismissed.append(id) }
}

@MainActor
final class FakeNotchHost: NotchPanelHosting {
    var isVisible = false
    var onPointerChange: ((Bool) -> Void)?
    var onDockChanged: ((MacEdgeDock) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var inwardSide: NotchInwardSide = .bottom
    var frames: [CGRect] = []
    var docks: [(dock: MacEdgeDock, size: CGSize)] = []
    var showCount = 0, hideCount = 0
    func show() { isVisible = true; showCount += 1 }
    func hide() { isVisible = false; hideCount += 1 }
    func setFrame(_ frame: CGRect, animated: Bool) { frames.append(frame) }
    func setDock(_ dock: MacEdgeDock, size: CGSize) { docks.append((dock, size)) }
    func simulateDragBegan() { onDragStateChange?(true) }
    func simulateRelease(_ dock: MacEdgeDock) { onDockChanged?(dock); onDragStateChange?(false) }   // base order: dock first, then drag end
}

@MainActor
final class FakeScheduler: NotchTimerScheduling {
    struct Entry { var after: TimeInterval; var fire: @MainActor () -> Void; var cancelled = false }
    var entries: [Entry] = []
    func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        entries.append(Entry(after: after, fire: fire))
        let i = entries.count - 1
        return { [unowned self] in entries[i].cancelled = true }
    }
    /// Fires the newest uncancelled timer with this delay.
    func fire(after: TimeInterval) {
        guard let i = entries.lastIndex(where: { $0.after == after && !$0.cancelled }) else { return }
        entries[i].cancelled = true
        entries[i].fire()
    }
}

@MainActor
final class FakeMonitor: NotchDismissMonitoring {
    var started = 0, stopped = 0
    var onDismiss: (() -> Void)?
    func start(onDismiss: @escaping () -> Void, isOwnWindow: @escaping (NSWindow?) -> Bool) { started += 1; self.onDismiss = onDismiss }
    func stop() { stopped += 1 }
}

@MainActor
final class NotchStatusControllerTests: XCTestCase {
    typealias F = NotchFixtures

    private struct Rig {
        let controller: NotchStatusController
        let source: FakeNotchSource
        let host: FakeNotchHost
        let scheduler: FakeScheduler
        let monitor: FakeMonitor
        var opened: Box<[String]>, panes: Box<[SidebarTab]>, newChats: Box<Int>
        var screen: Box<NotchScreenMetrics?>
        var newChatEnabled: Box<Bool>
        let suite: (defaults: UserDefaults, name: String)
        var now: Box<Date>
        let dockStore: NotchDockStore
        let connectedIDs: Box<Set<UInt32>>
    }
    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private let notchScreen = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32, auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 659, height: 32),
        auxiliaryTopRight: CGRect(x: 853, y: 950, width: 659, height: 32), id: 1)
    private let externalScreen = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0, auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero, id: 2)

    private func makeRig(mode: NotchMode = .activeAgents, feedBaselined: Bool = true) -> Rig {
        let suite = HostedTestSupport.makeSuite()
        suite.defaults.set(mode.rawValue, forKey: NotchStatusSettings.key)
        let source = FakeNotchSource(), host = FakeNotchHost(), scheduler = FakeScheduler(), monitor = FakeMonitor()
        let opened = Box<[String]>([]), panes = Box<[SidebarTab]>([]), newChats = Box(0)
        let screen = Box<NotchScreenMetrics?>(notchScreen), enabled = Box(true), now = Box(F.t0)
        let dockStore = NotchDockStore(defaults: suite.defaults), connectedIDs = Box<Set<UInt32>>([1, 2])
        let actions = NotchActions(
            openSession: { opened.value.append($0) }, openPane: { panes.value.append($0) },
            newChat: { newChats.value += 1 }, newChatEnabled: { enabled.value }, openConduit: {})
        let controller = NotchStatusController(
            settings: NotchStatusSettings(defaults: suite.defaults), actions: actions,
            makeHost: { host }, screen: { screen.value }, scheduler: scheduler, monitor: monitor, now: { now.value },
            dockStore: dockStore, connectedScreenIDs: { connectedIDs.value })
        source.isBaselinedSubject.send(feedBaselined)   // the real feed starts false and turns true after its first poll
        controller.bind(source: source, actions: actions)
        return Rig(controller: controller, source: source, host: host, scheduler: scheduler, monitor: monitor,
                   opened: opened, panes: panes, newChats: newChats, screen: screen, newChatEnabled: enabled, suite: suite, now: now,
                   dockStore: dockStore, connectedIDs: connectedIDs)
    }

    private func finish(_ r: Rig) { HostedTestSupport.dropSuite(r.suite) }

    /// Polls with `await` so the main-actor respond task can run (a run-loop spin does not service Swift tasks).
    private func eventually(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func testIdleStaysHiddenAndNeverShowsThePanel() {
        let r = makeRig(); defer { finish(r) }
        XCTAssertFalse(r.host.isVisible)
        XCTAssertEqual(r.host.showCount, 0)
    }

    func testWorkingShowsCompactAtTheNotchFrame() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertTrue(r.host.isVisible)
        XCTAssertEqual(r.host.frames.last, NotchGeometry.compactFrame(NotchGeometry.placement(for: notchScreen), in: notchScreen, contentWidth: 0))
    }

    func testStartupBaselineWithAPendingApprovalDoesNotAutoExpand() {
        let rig = makeRig(feedBaselined: false); defer { finish(rig) }               // the feed has not finished its first poll
        rig.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])   // already pending when Conduit started
        rig.source.isBaselinedSubject.send(true)                                     // that is the silent baseline
        XCTAssertEqual(rig.controller.viewModel.surface, .compact)
    }

    func testNothingAutoExpandsBeforeTheFeedIsBaselined() {
        let rig = makeRig(feedBaselined: false); defer { finish(rig) }
        rig.source.itemsSubject.send([])
        rig.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        XCTAssertEqual(rig.controller.viewModel.surface, .compact)
        XCTAssertTrue(rig.controller.viewModel.buttonsEnabled)
    }

    func testLaterBaselineFlipsDoNotSwallowARealNewApproval() {
        let rig = makeRig(); defer { finish(rig) }
        rig.source.itemsSubject.send([F.item("turn:a", session: "s")])
        rig.source.isBaselinedSubject.send(false)   // an approval fetch for a new waiting session is in flight
        rig.source.isBaselinedSubject.send(true)
        rig.source.itemsSubject.send([F.item("turn:a", session: "s"), F.approvalItem("approval:q", session: "s")])
        XCTAssertEqual(rig.controller.viewModel.surface, .expanded, "baseline is latched once")
    }

    func testPanelVisibilityAndExpandRefreshAreForwardedToTheFeed() {
        let rig = makeRig(); defer { finish(rig) }
        rig.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertEqual(rig.source.panelVisibleCalls.last, true)
        rig.host.onPointerChange?(true)
        rig.scheduler.fire(after: 0.2)
        XCTAssertEqual(rig.source.refreshCount, 1, "first expand asks for a fresh poll")
        rig.source.itemsSubject.send([])
        XCTAssertEqual(rig.source.panelVisibleCalls.last, false)
    }

    func testNewApprovalExpandsAndGuardsThenEnablesButtons() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a", session: "s")])
        r.source.itemsSubject.send([F.item("turn:a", session: "s"), F.approvalItem("approval:q", session: "s")])
        XCTAssertEqual(r.controller.viewModel.surface, .expanded)
        XCTAssertFalse(r.controller.viewModel.buttonsEnabled)
        XCTAssertEqual(r.monitor.started, 1)
        r.scheduler.fire(after: 0.6)
        XCTAssertTrue(r.controller.viewModel.buttonsEnabled)
    }

    func testChoosingRoutesThroughTheFeedAndMarksInteraction() async {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.scheduler.fire(after: 0.6)
        let row = r.controller.viewModel.list.rows[0]
        r.controller.viewModel.onAction(row, .allowOnce)
        let got = await eventually { !r.source.responses.isEmpty }; XCTAssertTrue(got)
        XCTAssertEqual(r.source.responses.first?.id, "approval:q")
        XCTAssertEqual(r.source.responses.first?.choice, "once")
        let idle = await eventually { r.controller.viewModel.submitting.isEmpty }; XCTAssertTrue(idle)
        XCTAssertTrue(r.controller.viewModel.failedRows.isEmpty)
    }

    func testChoosingDuringTheClickGuardIsIgnored() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.controller.viewModel.onAction(r.controller.viewModel.list.rows[0], .allowOnce)
        HostedTestSupport.settle(0.05)
        XCTAssertTrue(r.source.responses.isEmpty)
    }

    func testFailedRespondShowsRowErrorAndReenablesButtons() async {
        let r = makeRig(); defer { finish(r) }
        r.source.result = .failed("boom")
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.scheduler.fire(after: 0.6)
        r.controller.viewModel.onAction(r.controller.viewModel.list.rows[0], .deny)
        let failed = await eventually { r.controller.viewModel.failedRows.contains("approval:q") }; XCTAssertTrue(failed)
        XCTAssertTrue(r.controller.viewModel.canChoose(rowID: "approval:q"))
    }

    func testAnsweredElsewhereRacesWithoutAnErrorAndTheRowGoes() async {
        let r = makeRig(); defer { finish(r) }
        r.source.result = .alreadyResolved
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.scheduler.fire(after: 0.6)
        r.controller.viewModel.onAction(r.controller.viewModel.list.rows[0], .allowOnce)
        r.source.itemsSubject.send([])   // the feed drops it
        let idle = await eventually { r.controller.viewModel.submitting.isEmpty }; XCTAssertTrue(idle)
        XCTAssertTrue(r.controller.viewModel.failedRows.isEmpty)
        XCTAssertEqual(r.controller.viewModel.list.rows.count, 0)
    }

    func testRowClicksRouteToSessionKanbanAndCron() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a", session: "s1"),
                                    F.item("kanban:b/t", kind: .kanban, state: .blocked, title: "Fix"),
                                    F.item("cron:j", kind: .cron, state: .working, title: "Nightly", since: F.t0.addingTimeInterval(60))])
        let rows = r.controller.viewModel.list.rows
        r.controller.viewModel.onOpenRow(rows.first { $0.target == .session("s1") }!)
        r.controller.viewModel.onOpenRow(rows.first { $0.target == .kanban }!)
        r.controller.viewModel.onOpenCron()
        XCTAssertEqual(r.opened.value, ["s1"])
        XCTAssertEqual(r.panes.value, [.kanban, .cron])
    }

    func testNewChatHonoursAvailability() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.newChatEnabled.value = false
        r.controller.toggleCommandPin()   // expand: refreshes the flag
        XCTAssertFalse(r.controller.viewModel.newChatEnabled)
        r.controller.viewModel.onNewChat()
        XCTAssertEqual(r.newChats.value, 0)
        r.newChatEnabled.value = true
        r.controller.toggleCommandPin(); r.controller.toggleCommandPin()
        r.controller.viewModel.onNewChat()
        XCTAssertEqual(r.newChats.value, 1)
    }

    func testPointerEventsDriveHoverExpandThroughTheScheduler() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.host.onPointerChange?(true)
        r.scheduler.fire(after: 0.2)
        XCTAssertEqual(r.controller.viewModel.surface, .expanded)
        r.host.onPointerChange?(false)
        r.scheduler.fire(after: 0.4)
        XCTAssertEqual(r.controller.viewModel.surface, .compact)
    }

    func testDismissMonitorCollapsesAndStopsWhenNotExpanded() {
        let r = makeRig(); defer { finish(r) }
        r.controller.toggleCommandPin()
        XCTAssertEqual(r.monitor.started, 1)
        r.monitor.onDismiss?()
        XCTAssertEqual(r.controller.viewModel.surface, .hidden)
        XCTAssertGreaterThanOrEqual(r.monitor.stopped, 1)
    }

    func testShowAgentStatusPinsAndShowsTheEmptyStateEvenWhenOff() {
        let r = makeRig(mode: .off); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertFalse(r.host.isVisible)
        r.controller.toggleCommandPin()
        XCTAssertTrue(r.host.isVisible)
        XCTAssertTrue(r.controller.isCommandPinned)
        r.controller.toggleCommandPin()
        XCTAssertFalse(r.host.isVisible)
    }

    func testOfflineClearsRowsHidesAndPinnedShowsDisconnected() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.source.availabilitySubject.send(.offline)
        r.source.itemsSubject.send([])
        XCTAssertFalse(r.host.isVisible)
        r.controller.toggleCommandPin()
        XCTAssertEqual(r.controller.viewModel.emptyState, .disconnected)
        XCTAssertTrue(r.host.isVisible)
    }

    func testReconnectBaselineDoesNotFlashOrExpand() {
        let r = makeRig(); defer { finish(r) }
        r.source.availabilitySubject.send(.offline)
        r.source.availabilitySubject.send(.live)
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        XCTAssertEqual(r.controller.viewModel.surface, .compact)
    }

    // Review Focus 3.
    func testScreenChangeReanchorsHidesWithNoScreenAndRecovers() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.screen.value = externalScreen
        r.controller.screenParametersChanged()
        XCTAssertEqual(r.host.frames.last, NotchGeometry.compactFrame(.pill, in: externalScreen, contentWidth: 0))
        r.screen.value = nil
        r.controller.screenParametersChanged()
        XCTAssertFalse(r.host.isVisible)
        r.screen.value = notchScreen
        r.controller.screenParametersChanged()
        XCTAssertTrue(r.host.isVisible)
        XCTAssertEqual(r.controller.viewModel.surface, .compact)
    }

    func testSettingsChangeIsAppliedLive() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertTrue(r.host.isVisible)
        r.suite.defaults.set("off", forKey: NotchStatusSettings.key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: r.suite.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { !r.host.isVisible })
    }

    func testFinishedRowsExpireOnSchedule() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.source.itemsSubject.send([F.item("turn:a", state: .finished(.completed), since: F.t0)])
        XCTAssertEqual(r.controller.viewModel.list.rows.count, 1)
        r.now.value = F.t0.addingTimeInterval(31)
        r.scheduler.fire(after: 30)
        XCTAssertEqual(r.controller.viewModel.list.rows.count, 0)
        XCTAssertEqual(r.controller.viewModel.surface, .hidden)
    }

    func testDismissRowGoesToTheFeed() {
        let r = makeRig(); defer { finish(r) }
        r.controller.viewModel.onDismissRow("turn:a")
        XCTAssertEqual(r.source.dismissed, ["turn:a"])
    }

    private func dock(_ edge: NSRectEdge, _ offset: CGFloat = 0.5, screen: UInt32 = 1) -> MacEdgeDock {
        MacEdgeDock(edge: edge, offset: offset, screenID: screen)
    }

    func testSavedDockIsRestoredWhenTheSurfaceFirstAppears() {
        let r = makeRig(); defer { finish(r) }
        r.dockStore.save(dock(.minX, 0.3))
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertEqual(r.host.docks.last?.dock, dock(.minX, 0.3))
        XCTAssertEqual(r.host.docks.last?.size, CGSize(width: NotchMetrics.pillHeight, height: NotchMetrics.pillMinWidth), "left edge: vertical capsule")
        XCTAssertTrue(r.host.frames.isEmpty, "the standard path is not used")
        XCTAssertEqual(r.controller.viewModel.layout.style, .pill)
        XCTAssertEqual(r.controller.viewModel.layout.growth, .right)
    }

    func testReleaseAfterADragPersistsPerDisplayAndRelayouts() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.host.simulateDragBegan()
        r.host.simulateRelease(dock(.minY, 0.25))
        XCTAssertEqual(r.dockStore.dock(forScreen: 1), dock(.minY, 0.25))
        XCTAssertNil(r.dockStore.dock(forScreen: 2), "another display keeps its own placement")
        XCTAssertEqual(r.host.docks.last?.dock, dock(.minY, 0.25))
        XCTAssertEqual(r.controller.viewModel.layout.growth, .up)
    }

    func testSavedDockForADisplayThatIsGoneFallsBackToTheStandardPlacementAndIsKept() {
        let r = makeRig(); defer { finish(r) }
        r.dockStore.save(dock(.maxX, 0.5, screen: 9))
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertTrue(r.host.docks.isEmpty)
        XCTAssertEqual(r.host.frames.last, NotchGeometry.compactFrame(NotchGeometry.placement(for: notchScreen), in: notchScreen, contentWidth: 0))
        XCTAssertNotNil(r.dockStore.dock(forScreen: 9), "applies again when the display returns")
        var back = notchScreen; back.id = 9
        r.screen.value = back
        r.connectedIDs.value = [1, 9]
        r.controller.screenParametersChanged()
        XCTAssertEqual(r.host.docks.last?.dock, dock(.maxX, 0.5, screen: 9))
    }

    func testScreenChangeRestoresTheDockOfTheNewMainDisplay() {
        let r = makeRig(); defer { finish(r) }
        r.dockStore.save(dock(.minY, 0.7, screen: 2))
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertTrue(r.host.docks.isEmpty, "display 1 has no record")
        r.screen.value = externalScreen
        r.controller.screenParametersChanged()
        XCTAssertEqual(r.host.docks.last?.dock, dock(.minY, 0.7, screen: 2))
    }

    func testResetPositionClearsOnlyThisDisplayAndReturnsToTheStandardPlacement() {
        let r = makeRig(); defer { finish(r) }
        r.dockStore.save(dock(.minX, 0.3, screen: 1)); r.dockStore.save(dock(.maxX, 0.6, screen: 2))
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertEqual(r.controller.viewModel.layout.isDocked, true)
        r.controller.resetPosition()
        XCTAssertNil(r.dockStore.dock(forScreen: 1))
        XCTAssertNotNil(r.dockStore.dock(forScreen: 2))
        XCTAssertFalse(r.controller.viewModel.layout.isDocked)
        XCTAssertEqual(r.host.frames.last, NotchGeometry.compactFrame(NotchGeometry.placement(for: notchScreen), in: notchScreen, contentWidth: 0))
    }

    func testDoubleClickHookResetsThePosition() {
        let r = makeRig(); defer { finish(r) }
        r.dockStore.save(dock(.minX, 0.3))
        r.source.itemsSubject.send([F.item("turn:a")])
        r.controller.viewModel.onResetPosition()
        XCTAssertNil(r.dockStore.dock(forScreen: 1))
    }

    func testItemUpdatesDuringADragDoNotMoveThePanel() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        let placementCalls = r.host.frames.count + r.host.docks.count
        r.host.simulateDragBegan()
        r.source.itemsSubject.send([F.item("turn:a"), F.item("turn:b")])
        XCTAssertEqual(r.host.frames.count + r.host.docks.count, placementCalls, "no placement call while dragging")
        XCTAssertEqual(r.controller.viewModel.list.counts.working, 2, "state keeps updating")
        r.host.simulateRelease(dock(.maxY, 0.6))
        XCTAssertEqual(r.host.docks.last?.dock, dock(.maxY, 0.6))
    }

    func testNoAutoExpandMidDragAndHoverResumesAfterTheDrop() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.host.onPointerChange?(true)
        r.host.simulateDragBegan()
        r.scheduler.fire(after: 0.2)
        XCTAssertEqual(r.controller.viewModel.surface, .compact, "the pending hover expand was cancelled")
        r.host.onPointerChange?(false); r.host.onPointerChange?(true)
        r.scheduler.fire(after: 0.2)
        XCTAssertEqual(r.controller.viewModel.surface, .compact, "wobble mid-drag schedules nothing")
        r.host.simulateRelease(dock(.maxY))
        r.scheduler.fire(after: 0.2)
        XCTAssertEqual(r.controller.viewModel.surface, .expanded, "hover resumes once dropped with the pointer over the surface")
    }

    func testAttentionMidDragExpandsAfterTheDrop() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a", session: "s")])
        r.host.simulateDragBegan()
        r.source.itemsSubject.send([F.item("turn:a", session: "s"), F.approvalItem("approval:q", session: "s")])
        XCTAssertEqual(r.controller.viewModel.surface, .compact)
        XCTAssertEqual(r.monitor.started, 0)
        r.host.simulateRelease(dock(.maxY))
        XCTAssertEqual(r.controller.viewModel.surface, .expanded)
        XCTAssertFalse(r.controller.viewModel.buttonsEnabled, "the 600 ms guard starts at the drop")
    }

    func testADragNeverActsOnARow() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a", session: "s1")])
        r.host.simulateDragBegan()
        r.host.simulateRelease(dock(.minX))
        XCTAssertTrue(r.opened.value.isEmpty)
        XCTAssertTrue(r.source.responses.isEmpty)
        XCTAssertTrue(r.source.dismissed.isEmpty)
        XCTAssertEqual(r.newChats.value, 0)
    }

    func testBottomDockOpensUpwardAndLeftDockOpensInwardWithStackedRows() {
        let r = makeRig(); defer { finish(r) }
        r.dockStore.save(dock(.minY, 0.5))
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        let bottom = r.host.docks.last
        XCTAssertEqual(bottom?.size.width, NotchMetrics.expandedWidth)
        XCTAssertEqual(r.controller.viewModel.layout.growth, .up)
        XCTAssertTrue(r.controller.viewModel.layout.gripAtBottom)
        r.dockStore.save(dock(.minX, 0.5))
        r.controller.screenParametersChanged()
        XCTAssertEqual(r.controller.viewModel.layout.growth, .right)
        XCTAssertEqual(r.host.docks.last?.size.width, NotchMetrics.expandedWidth, "opens horizontally inward")
    }

    func testWingsOnlyForTheStandardPlacementOnANotchDisplay() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertEqual(r.controller.viewModel.layout.style, .wings)
        r.dockStore.save(dock(.maxY, 0.5))
        r.controller.screenParametersChanged()
        XCTAssertEqual(r.controller.viewModel.layout.style, .pill, "docked uses the pill even at the top edge of a notch display")
        r.dockStore.clear(screenID: 1)
        r.screen.value = externalScreen
        r.controller.screenParametersChanged()
        XCTAssertEqual(r.controller.viewModel.layout.style, .pill, "standard without a notch is the pill")
    }

    // MARK: approval spoofing hardening (coordinator security review)

    /// Waits for the controller's detached respond task without spinning the run loop (an `await` lets the main actor run it).
    private func waitForResponse(_ r: Rig) async {
        for _ in 0..<300 where r.source.responses.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func armedApprovalRig(_ items: [AgentActivityItem]) -> Rig {
        let r = makeRig()
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send(items)
        r.scheduler.fire(after: 0.6)
        return r
    }

    func testCraftedTitleAndDetailThatLookLikeIdsAndChoicesStillTargetTheOriginalItem() async {
        var real = F.approvalItem("approval:q1", session: "s1", approval: F.approval(command: "ls"))
        real.title = "approval:evil always"
        real.detail = "id=approval:other choice=always deny"
        var decoy = F.approvalItem("approval:evil", session: "s2")
        decoy.title = "approval:q1 deny"
        let r = armedApprovalRig([real, decoy]); defer { finish(r) }
        let row = r.controller.viewModel.list.rows.first { $0.id == "approval:q1" }!
        r.controller.viewModel.onAction(row, .allowOnce)
        await waitForResponse(r)
        XCTAssertEqual(r.source.responses.count, 1)
        XCTAssertEqual(r.source.responses.first?.id, "approval:q1", "the exact id of the clicked item, never one read from text")
        XCTAssertEqual(r.source.responses.first?.choice, AgentActivityApprovalChoices.once, "the button decides the choice, not the title")
    }

    func testMenuActionsMapToTheirFixedChoices() async {
        let r = armedApprovalRig([F.approvalItem("approval:q1", session: "s1")]); defer { finish(r) }
        let row = r.controller.viewModel.list.rows[0]
        r.controller.viewModel.onAction(row, .allowSession)
        await waitForResponse(r)
        XCTAssertEqual(r.source.responses.map(\.choice), [AgentActivityApprovalChoices.session])
    }

    func testAChoiceTheApprovalDoesNotOfferIsRefused() async {
        let a = F.approval(choices: ["once", "deny"])
        let r = armedApprovalRig([F.approvalItem("approval:q1", session: "s1", approval: a)]); defer { finish(r) }
        let row = r.controller.viewModel.list.rows[0]
        r.controller.viewModel.onAction(row, .allowAlways)
        r.controller.viewModel.onAction(row, .allowSession)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(r.source.responses.isEmpty)
    }

    func testAnItemThatIsNoLongerTheSameApprovalIsNotAnswered() async {
        let r = armedApprovalRig([F.approvalItem("approval:q1", session: "s1")]); defer { finish(r) }
        let row = r.controller.viewModel.list.rows[0]

        // Gone from the feed.
        r.source.itemsSubject.send([])
        r.controller.viewModel.onAction(row, .allowOnce)
        // Same id, different session.
        r.source.itemsSubject.send([F.approvalItem("approval:q1", session: "other-session")])
        r.controller.viewModel.onAction(row, .allowOnce)
        // Same id and session, but no longer an approval.
        r.source.itemsSubject.send([F.item("approval:q1", kind: .clarify, state: .needsUser, session: "s1")])
        r.controller.viewModel.onAction(row, .allowOnce)
        // Same id and session, but no longer waiting.
        r.source.itemsSubject.send([F.item("approval:q1", kind: .approval, state: .working, session: "s1", approval: F.approval())])
        r.controller.viewModel.onAction(row, .allowOnce)
        // Waiting, but the approval payload says it is already answered.
        var answered = F.approval(); answered.status = .approved
        r.source.itemsSubject.send([F.approvalItem("approval:q1", session: "s1", approval: answered)])
        r.controller.viewModel.onAction(row, .deny)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(r.source.responses.isEmpty)
    }

    func testAllowOnACommandThatWasNotShownInFullOpensTheSessionInstead() async {
        let long = F.approval(command: "echo " + String(repeating: "A", count: 400))
        let r = armedApprovalRig([F.approvalItem("approval:q1", session: "s1", approval: long)]); defer { finish(r) }
        let row = r.controller.viewModel.list.rows[0]
        r.controller.viewModel.onAction(row, .allowOnce)        // even if a stale view still sends it
        r.controller.viewModel.onAction(row, .allowAlways)
        r.controller.viewModel.onAction(row, .reviewInConduit)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(r.source.responses.isEmpty, "nothing is answered for a command the user could not read in full")
        XCTAssertEqual(r.opened.value, ["s1", "s1", "s1"])
    }

    func testDenyStillWorksForACommandThatWasNotShownInFull() async {
        let long = F.approval(command: "echo " + String(repeating: "A", count: 400))
        let r = armedApprovalRig([F.approvalItem("approval:q1", session: "s1", approval: long)]); defer { finish(r) }
        r.controller.viewModel.onAction(r.controller.viewModel.list.rows[0], .deny)
        await waitForResponse(r)
        XCTAssertEqual(r.source.responses.map(\.choice), [AgentActivityApprovalChoices.deny])
    }
}
