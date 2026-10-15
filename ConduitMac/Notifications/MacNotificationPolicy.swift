import Foundation

struct MacNotificationVisibility: Equatable {
    var appIsActive: Bool
    var mainWindowKeyAndVisible: Bool
    var chatSurfaceShowing: Bool
    var sessionIsActive: Bool

    /// The user is looking at this session right now.
    var isAttended: Bool { appIsActive && mainWindowKeyAndVisible && chatSurfaceShowing && sessionIsActive }

    static let away = MacNotificationVisibility(appIsActive: false, mainWindowKeyAndVisible: false, chatSurfaceShowing: false, sessionIsActive: false)
}

enum MacNotificationKind: String, Equatable {
    case done, failed, approval, question, notice
}

enum MacNotificationPolicy {
    static let thresholdChoices: [TimeInterval] = [10, 30, 60, 120]
    static let defaultThreshold: TimeInterval = 30
    static let approvalGrace: TimeInterval = 3
    static let burstLimit = 3
    static let burstWindow: TimeInterval = 10

    static func isLongRunning(startedAt: Date, finishedAt: Date, threshold: TimeInterval) -> Bool {
        finishedAt.timeIntervalSince(startedAt) >= threshold
    }

    static func shouldSuppress(_ visibility: MacNotificationVisibility) -> Bool { visibility.isAttended }

    enum ID {
        static func done(_ sessionKey: String) -> String { "conduit.done.\(sessionKey)" }
        static func approval(_ requestId: String) -> String { "conduit.approval.\(requestId)" }
        static func question(_ requestId: String) -> String { "conduit.question.\(requestId)" }
        static func thread(_ sessionKey: String) -> String { "session-\(sessionKey)" }
        static func notice(_ uuid: UUID) -> String { "conduit.notice.\(uuid.uuidString)" }
        static let doneSummary = "conduit.done.summary"
    }
}

/// Process-lifetime memory of what was already announced; the feed may replay
/// after a reconnect.
struct MacNotificationPostedSet {
    enum Slot: Hashable { case done, approval, question }
    private var keys = Set<String>()

    /// True when this (slot, key) is new.
    mutating func insert(_ slot: Slot, _ key: String) -> Bool {
        keys.insert("\(slot)|\(key)").inserted
    }
}

/// More than `burstLimit` Done posts inside `burstWindow` collapse into one
/// summary. The first three post individually; the fourth and later replace
/// the summary with the running count.
struct MacDoneBurstLimiter {
    enum Decision: Equatable { case individual, summary(count: Int) }
    private var stamps: [Date] = []

    mutating func register(at now: Date) -> Decision {
        stamps = stamps.filter { now.timeIntervalSince($0) < MacNotificationPolicy.burstWindow }
        stamps.append(now)
        return stamps.count > MacNotificationPolicy.burstLimit ? .summary(count: stamps.count) : .individual
    }
}
