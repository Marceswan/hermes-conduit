import Foundation

// Mac twin of Conduit/Services/LiveTurnActivities.swift (R2); keep in sync (PORTING_LEDGER). ActivityKit is
// unavailable on macOS, so there is no Lock Screen activity: every call is a
// no-op. Members match the call sites in AppState.swift and AuxiliaryViews.swift.
@MainActor
final class LiveTurnActivities {
    static let shared = LiveTurnActivities()
    nonisolated static let enabledDefaultsKey = "conduit.liveActivities.enabled"
    /// How long a chat must stay out of the live registry before upstream takes its turn as over; AppState waits this long
    /// before its recheck read.
    nonisolated static let registryAbsenceSpan: TimeInterval = 8

    func turnSubmitting(sessionIDs: Set<String>) {}

    func turnStarted(
        sessionIDs: Set<String>,
        primaryID: String,
        title: String,
        profile: String?,
        profileName: String? = nil,
        glowHex: String? = nil,
        dashboardID: String? = nil
    ) {}

    func observe(_ event: StreamEvent, sessionID: String) {}

    func endAll() {}

    /// A `session.active_list` snapshot: no activity runs, so no chat is ever just seen absent.
    @discardableResult
    func reconcile(liveSessionIDs: Set<String>, profile: String, dashboardID: String?, now: Date = Date()) -> Bool {
        false
    }

    func endTurns(ofDashboard dashboardID: String?, keepingThoseOnRelay: Bool = false) {}

    func adoptExisting() {}
}
