import AppKit
import Combine
import UserNotifications

@MainActor
protocol MacNotificationEventSource: AnyObject {
    func start(_ handler: @escaping @MainActor (MacNotificationEvent) -> Void)
    func stop()
}

/// Owns the live wiring. Built once at launch from the app delegate; never
/// under XCTest (tests construct the pieces with fakes).
@MainActor
final class MacNotificationRuntime {
    static let shared = MacNotificationRuntime()

    private(set) var coordinator: MacNotificationCoordinator?
    private let delegate = MacNotificationDelegate()
    private var router: MacNotificationRouter?
    private var handler: MacNotificationActionHandler?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    /// Set by Task 9 (the feed adapter). Nil until the shared base is wired.
    var eventSource: MacNotificationEventSource?

    func start(appState: AppState) {
        guard coordinator == nil else { return }
        let center = UNMacNotificationCenterClient()
        let prefs = MacNotificationPreferences.shared
        let coordinator = MacNotificationCoordinator(
            center: center, preferences: prefs, scheduler: MacTaskScheduler(),
            visibility: { [weak appState] session in
                guard let appState else { return .away }
                return MacNotificationVisibilityProvider.current(for: session, appState: appState)
            }
        )
        let router = MacNotificationRouter(
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { MacSessionTabsActions.isMainChatWindow($0) }?.makeKeyAndOrderFront(nil)
            },
            openSession: { [weak appState] id in _ = appState?.requestOpenSession(id) },
            activeDashboardID: { [weak appState] in appState?.activeDashboardID },
            activeProfile: { [weak appState] in appState?.activeProfile ?? "default" },
            isConnected: { [weak appState] in appState?.isConnected == true },
            removeNotifications: { center.removeDelivered($0); center.removePending($0) }
        )
        let handler = MacNotificationActionHandler(
            gateway: MacHermesNotificationGateway(appState: appState), coordinator: coordinator, router: router,
            removeDelivered: { center.removeDelivered($0) }
        )
        delegate.onAction = { await handler.perform($0) }
        delegate.presentation = { [weak appState] payload in
            guard let appState, let payload else { return [.banner, .list, .sound] }
            let session = MacNotificationSession(sessionId: payload.sessionId, sessionKey: payload.sessionKey, alternateIds: [], profile: payload.profile, dashboardID: payload.dashboardID, title: "")
            return MacNotificationPresentation.options(for: MacNotificationVisibilityProvider.current(for: session, appState: appState), sound: prefs.soundEnabled)
        }
        // The delegate must be set before applicationDidFinishLaunching returns,
        // or a cold-launch click is not delivered.
        // `install` keeps any delegate already in the slot (Sparkle's, say) and
        // forwards what is not ours to it; it runs again on activation in case
        // another component takes the slot later.
        let notificationCenter = UNUserNotificationCenter.current()
        delegate.install(on: notificationCenter)

        self.coordinator = coordinator; self.router = router; self.handler = handler

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.delegate.install(on: notificationCenter) }
        })
        let recheck: (Notification) -> Void = { [weak coordinator] _ in Task { @MainActor in coordinator?.recheckAttention() } }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, .macSessionOpenRequested] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main, using: recheck))
        }
        appState.$activeSessionId.dropFirst().sink { [weak coordinator] _ in Task { @MainActor in coordinator?.recheckAttention() } }.store(in: &cancellables)
        appState.$isConnected.removeDuplicates().sink { [weak router] _ in Task { @MainActor in router?.connectionChanged() } }.store(in: &cancellables)

        eventSource = eventSource ?? MacAgentActivityFeedSource(alternateIDs: { [weak appState] key in
            guard let appState else { return [] }
            return appState.sessions
                .filter { $0.id == key || $0.storedSessionId == key || $0.alternateIds.contains(key) }
                .flatMap { [$0.id] + ($0.storedSessionId.map { [$0] } ?? []) + $0.alternateIds }
        })
        // Under XCTest `AgentActivityFeed.shared` is nil, so the source stays inert.
        eventSource?.start { [weak coordinator] in coordinator?.handle($0) }
    }

    func languageDidChange() { coordinator?.languageDidChange() }
}
