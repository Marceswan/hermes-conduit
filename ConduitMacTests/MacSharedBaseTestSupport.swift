import XCTest
@testable import ConduitMac

/// A real `AppState` built the way `MacSessionTabsBindTests` builds one:
/// injected defaults, no saved connection, no network, widget output kept out
/// of the real app group. Call `tearDown()` from the test's tearDown.
@MainActor
final class MacSharedBaseAppStateFixture {
    let suite = HostedTestSupport.makeSuite()
    let scratch: URL
    let appState: AppState

    init(
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil
    ) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSharedBase.\(UUID().uuidString)", isDirectory: true)
        self.scratch = scratch
        let appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            reconnectScheduler: reconnectScheduler,
            reconnectExecutor: reconnectExecutor,
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
        appState.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: scratch.appendingPathComponent("widgets", isDirectory: true))
        appState.widgetSnapshotReloadOverride = {}
        appState.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
        self.appState = appState
    }

    func tearDown() {
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }
}
