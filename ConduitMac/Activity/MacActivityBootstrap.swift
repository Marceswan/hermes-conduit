import Foundation

/// Creates the one app-wide `AgentActivityFeed`. Called from the app delegate at
/// launch, not from a window, so it keeps running after the last window closes.
@MainActor
enum MacActivityBootstrap {
    private(set) static var feed: AgentActivityFeed?

    static func start(appState: AppState? = nil) {
        guard feed == nil else { return }
        let appState = appState ?? AppStateRuntimeRegistry.shared.appState
        let feed = AgentActivityFeed(sources: AgentActivityLiveSources(appState: appState))
        feed.bind(to: appState)
        feed.start()
        AgentActivityFeed.shared = feed
        self.feed = feed
    }

    static func stop() {
        feed?.stop()
        feed = nil
        AgentActivityFeed.shared = nil
    }
}
