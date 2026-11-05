import Foundation
@testable import ConduitMac

enum MacHomeTestCalendar {
    /// A fixed Gregorian calendar in UTC, so day buckets do not depend on the machine's zone.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }
}

extension MacHomeInput {
    /// 2026-10-16 15:30 UTC.
    static let referenceNow = MacHomeTestCalendar.date("2026-10-16T15:30:00Z")

    static func fixture(
        now: Date = MacHomeInput.referenceNow,
        scope: String = "dash|default|true",
        connection: MacHomeConnection = MacHomeConnection(state: .connected, dashboardLabel: "prod", profileName: "Default"),
        sessions: [MacHomeSession] = [],
        live: [MacHomeLiveItem] = [],
        feed: MacHomeFeedAvailability = .live,
        cron: [MacHomeCronJob]? = nil,
        kanban: MacHomeKanbanInput = .notLoaded,
        runtime: MacHomeRuntime = MacHomeRuntime(),
        subAgents: Int = 0,
        canStartChat: Bool = true
    ) -> MacHomeInput {
        MacHomeInput(
            now: now, scope: scope, connection: connection, sessions: sessions, live: live, feed: feed,
            cron: cron, kanban: kanban, runtime: runtime, subAgents: subAgents, canStartChat: canStartChat
        )
    }
}

extension MacHomeSession {
    static func fixture(_ id: String, title: String = "", at: Date? = nil, unread: Bool = false, model: String = "") -> MacHomeSession {
        MacHomeSession(id: id, title: title.isEmpty ? "Chat \(id)" : title, model: model, lastActivity: at, isUnread: unread)
    }
}

extension MacHomeLiveItem {
    static func fixture(
        _ id: String,
        session: String? = nil,
        kind: Kind = .turn,
        needsUser: Bool = false,
        title: String = "A chat",
        detail: String? = nil,
        open: String? = "open",
        since: Date = MacHomeInput.referenceNow
    ) -> MacHomeLiveItem {
        MacHomeLiveItem(
            id: id, sessionKey: session, openID: open, kind: kind, needsUser: needsUser,
            title: title, detail: detail, since: since
        )
    }
}
