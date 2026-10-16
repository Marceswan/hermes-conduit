import Foundation

// Home metrics (D24), pure. Foundation only: no AppKit, SwiftUI, AppState,
// SessionSummary, AgentActivityItem or KanbanBoard, so the D25 widgets can
// fill `MacHomeInput` from their own data and reuse `MacHomeSnapshot.make`.
// Every gateway- or agent-controlled string is sanitized here, once.

// MARK: - Input

enum MacHomeConnectionState: Equatable { case connected, connecting, offline }

struct MacHomeConnection: Equatable {
    var state: MacHomeConnectionState
    var dashboardLabel: String?
    var profileName: String
}

struct MacHomeSession: Equatable, Identifiable {
    var id: String
    var title: String
    var model: String
    var lastActivity: Date?
    var isUnread: Bool
}

struct MacHomeLiveItem: Equatable, Identifiable {
    enum Kind: Equatable { case turn, approval, clarify, inputPrompt }
    var id: String
    /// Dedupe key: one row per session. Falls back to `id`.
    var sessionKey: String?
    /// What the row opens (`requestOpenSession`); nil makes the row inert.
    var openID: String?
    var kind: Kind
    var needsUser: Bool
    var title: String
    var detail: String?
    var since: Date
}

enum MacHomeFeedAvailability: Equatable {
    case live
    /// Live, but the first poll has not finished.
    case loading
    /// The gateway has no `session.active_list`: only this connection's chats.
    case eventsOnly
    case offline
}

struct MacHomeCronJob: Equatable, Identifiable {
    var id: String
    var name: String
    /// Enabled and not finished.
    var isActive: Bool
    /// A completed one-shot: neither active nor paused.
    var isFinished = false
    /// The last run reported an error.
    var hasError: Bool
    var nextRun: Date?
}

struct MacHomeKanbanColumnInput: Equatable {
    var status: String
    var displayName: String
    var sortOrder: Int
    var count: Int
}

enum MacHomeKanbanInput: Equatable {
    case notLoaded
    case unavailable
    case loaded([MacHomeKanbanColumnInput])
}

struct MacHomeRuntime: Equatable {
    var model = ""
    var provider = ""
    var reasoningEffort = ""
    /// 0 to 100.
    var contextPercent: Double = 0
    var contextUsed = 0
    var contextMax = 0
}

struct MacHomeInput: Equatable {
    var now: Date
    /// Changes when the dashboard, profile or connection changes; the view restarts its refresh loop on it.
    var scope: String
    var connection: MacHomeConnection
    var sessions: [MacHomeSession]
    var live: [MacHomeLiveItem]
    var feed: MacHomeFeedAvailability
    /// nil: not loaded (or unavailable).
    var cron: [MacHomeCronJob]?
    /// The cron request failed and nothing from this scope is on hand.
    var cronUnavailable = false
    var kanban: MacHomeKanbanInput
    var runtime: MacHomeRuntime
    var subAgents: Int
    var canStartChat: Bool
}

// MARK: - Output

struct MacHomeLiveRow: Equatable, Identifiable {
    var id: String
    var openID: String?
    var kind: MacHomeLiveItem.Kind
    var needsUser: Bool
    var title: String
    var detail: String?
    var since: Date
}

struct MacHomeTiles: Equatable {
    var sessions: Int
    var activeToday: Int
    var unread: Int
    var needsYou: Int
    var approvals: Int
    var questions: Int
    var working: Int
    var subAgents: Int
}

struct MacHomeModelLine: Equatable {
    var model: String
    var provider: String
    var effort: String
}

struct MacHomeContext: Equatable {
    /// 0 to 100.
    var percent: Double
    var used: Int
    var max: Int
    var isHigh: Bool
}

struct MacHomeRecentRow: Equatable, Identifiable {
    var id: String
    var title: String
    var model: String
    var lastActivity: Date?
    var isUnread: Bool
}

struct MacHomeDay: Equatable, Identifiable {
    var start: Date
    var count: Int
    var isToday: Bool
    var id: Date { start }
}

struct MacHomeKanbanBar: Equatable, Identifiable {
    var id: String
    var name: String
    var count: Int
    /// count / the largest column, 0 to 1.
    var fraction: Double
}

struct MacHomeKanbanSummary: Equatable {
    enum State: Equatable { case notLoaded, unavailable, empty, loaded }
    var state: State
    var bars: [MacHomeKanbanBar]
    var total: Int
    var blocked: Int
}

struct MacHomeCronNext: Equatable {
    var name: String
    var date: Date
}

struct MacHomeCronSummary: Equatable {
    var active: Int
    var paused: Int
    var failing: Int
    var next: MacHomeCronNext?
}

struct MacHomeSnapshot: Equatable {
    static let recentLimit = 8
    static let dayCount = 7
    /// Home's own threshold for the context warning; the app has no named one.
    static let highContextPercent = 85.0

    enum Limit {
        static let title = 80
        static let detail = 120
        static let label = 40
        static let cronName = 60
        static let column = 24
    }

    var scope: String
    var connection: MacHomeConnection
    var feed: MacHomeFeedAvailability
    var canStartChat: Bool
    var needsYou: [MacHomeLiveRow]
    var working: [MacHomeLiveRow]
    var tiles: MacHomeTiles
    var model: MacHomeModelLine?
    var context: MacHomeContext?
    var recent: [MacHomeRecentRow]
    var days: [MacHomeDay]
    var kanban: MacHomeKanbanSummary
    var cron: MacHomeCronSummary?
    var cronUnavailable: Bool

    static func make(_ input: MacHomeInput, calendar: Calendar = .current) -> MacHomeSnapshot {
        let rows = input.feed == .offline ? [] : liveRows(input.live)
        let needsYou = rows.filter(\.needsUser)
        let working = rows.filter { !$0.needsUser }
        let days = dayBuckets(input.sessions, now: input.now, calendar: calendar)
        let waiting = input.feed == .offline ? [] : input.live.filter(\.needsUser)
        let approvals = waiting.filter { $0.kind == .approval }.count
        let questions = waiting.filter { $0.kind == .clarify || $0.kind == .inputPrompt }.count

        let tiles = MacHomeTiles(
            sessions: input.sessions.count,
            activeToday: days.last?.count ?? 0,
            unread: input.sessions.filter(\.isUnread).count,
            // From the un-deduplicated items: a session with three pending approvals
            // is three things waiting on the user, though it is one row.
            needsYou: approvals + questions,
            approvals: approvals,
            questions: questions,
            working: working.count,
            subAgents: max(input.subAgents, 0)
        )

        let connection = MacHomeConnection(
            state: input.connection.state,
            dashboardLabel: input.connection.dashboardLabel.map { clean($0, Limit.label) }.flatMap { $0.isEmpty ? nil : $0 },
            profileName: clean(input.connection.profileName, Limit.label)
        )

        return MacHomeSnapshot(
            scope: input.scope,
            connection: connection,
            feed: input.feed,
            canStartChat: input.canStartChat,
            needsYou: needsYou,
            working: working,
            tiles: tiles,
            model: modelLine(input.runtime),
            context: context(input.runtime),
            recent: recent(input.sessions),
            days: days,
            kanban: kanban(input.kanban),
            cron: cron(input.cron, now: input.now),
            cronUnavailable: input.cron == nil && input.cronUnavailable
        )
    }

    // MARK: Pieces

    private static func clean(_ text: String, _ limit: Int) -> String {
        MacUntrustedText.sanitize(text, maxGraphemes: limit)
    }

    private static func liveRows(_ items: [MacHomeLiveItem]) -> [MacHomeLiveRow] {
        var best: [String: MacHomeLiveItem] = [:]
        var order: [String] = []
        for item in items {
            let key = item.sessionKey ?? item.id
            guard let current = best[key] else {
                best[key] = item
                order.append(key)
                continue
            }
            if prefers(item, over: current) { best[key] = item }
        }
        return order.compactMap { best[$0] }
            .sorted { $0.since != $1.since ? $0.since < $1.since : $0.id < $1.id }
            .map { item in
                let detail = item.detail.map { clean($0, Limit.detail) }
                return MacHomeLiveRow(
                    id: item.id, openID: item.openID, kind: item.kind, needsUser: item.needsUser,
                    title: clean(item.title, Limit.title),
                    detail: (detail?.isEmpty ?? true) ? nil : detail,
                    since: item.since
                )
            }
    }

    /// A needs-you item replaces a working one for the same session; otherwise the older wins.
    private static func prefers(_ a: MacHomeLiveItem, over b: MacHomeLiveItem) -> Bool {
        if a.needsUser != b.needsUser { return a.needsUser }
        if a.since != b.since { return a.since < b.since }
        return a.id < b.id
    }

    private static func recent(_ sessions: [MacHomeSession]) -> [MacHomeRecentRow] {
        let ordered = sessions.sorted { a, b in
            switch (a.lastActivity, b.lastActivity) {
            case let (x?, y?): return x != y ? x > y : a.id < b.id
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.id < b.id
            }
        }
        return ordered.prefix(recentLimit).map {
            MacHomeRecentRow(
                id: $0.id, title: clean($0.title, Limit.title), model: clean($0.model, Limit.label),
                lastActivity: $0.lastActivity, isUnread: $0.isUnread
            )
        }
    }

    private static func dayBuckets(_ sessions: [MacHomeSession], now: Date, calendar: Calendar) -> [MacHomeDay] {
        let today = calendar.startOfDay(for: now)
        var starts: [Date] = []
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            let shifted = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            starts.append(calendar.startOfDay(for: shifted))
        }
        let window = Set(starts)
        var counts: [Date: Int] = [:]
        for session in sessions {
            guard let time = session.lastActivity else { continue }
            let key = calendar.startOfDay(for: time)
            if window.contains(key) { counts[key, default: 0] += 1 }
        }
        return starts.map { MacHomeDay(start: $0, count: counts[$0] ?? 0, isToday: $0 == today) }
    }

    private static func cron(_ jobs: [MacHomeCronJob]?, now: Date) -> MacHomeCronSummary? {
        guard let jobs else { return nil }
        let active = jobs.filter(\.isActive)
        var upcoming: (job: MacHomeCronJob, date: Date)?
        for job in active {
            guard let date = job.nextRun, date >= now else { continue }
            if let current = upcoming {
                let earlier = date != current.date ? date < current.date : job.id < current.job.id
                if !earlier { continue }
            }
            upcoming = (job, date)
        }
        return MacHomeCronSummary(
            active: active.count,
            paused: jobs.filter { !$0.isActive && !$0.isFinished }.count,
            failing: jobs.filter(\.hasError).count,
            next: upcoming.map { MacHomeCronNext(name: clean($0.job.name, Limit.cronName), date: $0.date) }
        )
    }

    private static func kanban(_ input: MacHomeKanbanInput) -> MacHomeKanbanSummary {
        switch input {
        case .notLoaded:
            return MacHomeKanbanSummary(state: .notLoaded, bars: [], total: 0, blocked: 0)
        case .unavailable:
            return MacHomeKanbanSummary(state: .unavailable, bars: [], total: 0, blocked: 0)
        case .loaded(let columns):
            let shown = columns
                .filter { $0.status != "archived" }
                .sorted {
                    $0.sortOrder != $1.sortOrder
                        ? $0.sortOrder < $1.sortOrder
                        : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            let peak = max(shown.map { max($0.count, 0) }.max() ?? 0, 1)
            let bars = shown.map { column -> MacHomeKanbanBar in
                let count = max(column.count, 0)
                let name = clean(column.displayName, Limit.column)
                return MacHomeKanbanBar(
                    id: column.status,
                    name: name.isEmpty ? clean(column.status, Limit.column) : name,
                    count: count,
                    fraction: Double(count) / Double(peak)
                )
            }
            let total = bars.reduce(0) { $0 + $1.count }
            return MacHomeKanbanSummary(
                state: total == 0 ? .empty : .loaded,
                bars: bars,
                total: total,
                blocked: bars.first { $0.id == "blocked" }?.count ?? 0
            )
        }
    }

    private static func context(_ runtime: MacHomeRuntime) -> MacHomeContext? {
        guard runtime.contextMax > 0 || runtime.contextPercent > 0 else { return nil }
        let raw = runtime.contextPercent.isFinite ? runtime.contextPercent : 0
        let percent = min(max(raw, 0), 100)
        return MacHomeContext(
            percent: percent,
            used: max(runtime.contextUsed, 0),
            max: max(runtime.contextMax, 0),
            isHigh: percent >= highContextPercent
        )
    }

    private static func modelLine(_ runtime: MacHomeRuntime) -> MacHomeModelLine? {
        let model = clean(runtime.model, Limit.label)
        guard !model.isEmpty else { return nil }
        return MacHomeModelLine(
            model: model,
            provider: clean(runtime.provider, Limit.label),
            effort: clean(runtime.reasoningEffort, Limit.label)
        )
    }
}

// MARK: - Dates

enum MacHomeDates {
    // Built once: this runs per job on every rebuild. Main-actor use in practice.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let naiveLocal: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// `CronJob.nextRunAt` is a raw String and no fixture pins its format.
    /// Accepts ISO 8601 with a zone, with or without fractional seconds; a
    /// zone-less value is read as the Mac's local time. Anything else is nil.
    static func parse(_ raw: String?) -> Date? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let date = fractional.date(from: text) { return date }
        if let date = plain.date(from: text) { return date }
        // Python's naive isoformat() can carry microseconds: drop the fraction (seconds are enough here).
        var wholeSeconds = text
        if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].allSatisfy(\.isNumber) {
            wholeSeconds = String(text[..<dot])
        }
        // "Local" follows the Mac's zone at call time.
        if naiveLocal.timeZone != TimeZone.current { naiveLocal.timeZone = .current }
        return naiveLocal.date(from: wholeSeconds)
    }
}
