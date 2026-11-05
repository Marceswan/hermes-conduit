import XCTest
@testable import ConduitMac

/// Shared fixtures of the Artifacts tests (`MacArtifactsPaneTests`, `MacArtifactsListTests`,
/// `MacArtifactsListHostedTests`).
enum ArtifactsTestSupport {
    /// The construction MacDashboardSwitcherTests uses: no saved connection, no network, nothing in
    /// the live app's defaults. Its notifier plugin has reported nothing, so it does not offer
    /// artifacts.
    @MainActor
    static func isolatedAppState(defaults: UserDefaults, scratch: URL) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
    }

    /// A row as the host's plugin sends it (a picture from now).
    static func row(_ fields: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "kind": "image", "source": "delivered", "name": "map.png", "path": "/root/out/map.png",
            "exists": true, "size": 2048, "session_id": "s1", "session_title": "Weekend trip",
            "message_id": 12, "timestamp": Date().timeIntervalSince1970,
        ]
        row.merge(fields) { _, new in new }
        return row
    }

    static func item(_ fields: [String: Any] = [:]) throws -> ArtifactItem {
        try XCTUnwrap(ArtifactItem(row(fields)))
    }

    /// A file the host no longer has.
    static func gone(_ name: String, message: Int) throws -> ArtifactItem {
        try item(["exists": false, "path": "/root/\(name)", "kind": "document", "name": name, "message_id": message])
    }

    /// A page answer as the plugin sends it.
    static func response(_ rows: [[String: Any]], next: Any = NSNull()) -> [String: Any] {
        ["ok": true, "items": rows, "next_before": next]
    }
}
