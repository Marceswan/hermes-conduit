import Foundation

// Mac twin of Conduit/Services/LiveTurnActivities.swift (R2). ActivityKit is
// unavailable on macOS, so there is no Lock Screen activity: every call is a
// no-op. Members match the call sites in AppState.swift and AuxiliaryViews.swift.
@MainActor
final class LiveTurnActivities {
    static let shared = LiveTurnActivities()
    nonisolated static let enabledDefaultsKey = "conduit.liveActivities.enabled"

    func turnSubmitting(sessionIDs: Set<String>) {}

    func turnStarted(
        sessionIDs: Set<String>,
        primaryID: String,
        title: String,
        profile: String?,
        profileName: String? = nil,
        glowHex: String? = nil
    ) {}

    func observe(_ event: StreamEvent, sessionID: String) {}

    func endAll() {}

    func adoptExisting() {}
}
