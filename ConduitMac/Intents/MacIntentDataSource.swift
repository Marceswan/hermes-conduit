import Foundation

/// Read access for intent queries to the live catalog. The app owns the only
/// AppState; this holds it weakly and answers empty when the app is not
/// running or not bound yet (entity resolution by id still works without it).
@MainActor
final class MacIntentDataSource {
    static let shared = MacIntentDataSource()

    private weak var appState: AppState?

    var isAvailable: Bool { appState != nil }
    var sessions: [SessionSummary] { appState?.activeProfileSessions ?? [] }
    var activeProfile: String? { appState?.activeProfile }

    func bind(to appState: AppState) { self.appState = appState }
}
