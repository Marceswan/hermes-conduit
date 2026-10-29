import Foundation

/// The session an event belongs to, as the notification layer needs it. The
/// feed adapter (Task 9, `MacFeedEventMapper`) fills it; nothing here knows about the feed.
struct MacNotificationSession: Equatable, Hashable {
    /// The runtime (live) id the gateway addresses in RPCs.
    var sessionId: String
    /// The durable id, matched through `alternateIds` (spec 2026-09-06).
    var sessionKey: String
    var alternateIds: [String]
    var profile: String
    var dashboardID: UUID?
    var title: String

    var allIDs: Set<String> { Set([sessionId, sessionKey] + alternateIds) }
}

struct MacNotificationEvent: Equatable {
    /// Monotonic per feed (the adapter narrows the feed's `UInt64`). 0 means unsequenced (an item read from `snapshot()`): it is never dropped as stale and the posted-set dedupes it.
    var eventId: Int
    var session: MacNotificationSession
    var kind: Kind

    enum Outcome: Equatable { case completed, failed, interrupted }
    enum Resolution: Equatable { case answered, expired, withdrawn, sessionClosed }

    enum Kind: Equatable {
        case turnStarted(turnId: String, at: Date)
        /// `startedAt` is the feed's own turn start (authoritative; a turn already running at baseline has no `turnStarted`). `observedGap` means the turn ended while the socket was down: never notify.
        case turnFinished(turnId: String, at: Date, outcome: Outcome, replyPreview: String?, startedAt: Date? = nil, observedGap: Bool = false)
        /// `itemId` is the feed's exact item id; actions look it up verbatim.
        case approvalRequested(requestId: String, description: String, command: String, choices: [String]?, allowPermanent: Bool, itemId: String? = nil)
        case questionRequested(requestId: String, firstQuestionText: String, openQuestionCount: Int, itemId: String? = nil)
        case decisionResolved(requestId: String, reason: Resolution)
        case sessionTitleChanged(title: String)
    }
}
