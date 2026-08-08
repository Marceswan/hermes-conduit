//
//  KanbanModels.swift
//  Conduit
//

import Foundation

// MARK: - Kanban

/// Server-owned Kanban board state from the Hermes `kanban` dashboard plugin
/// (`/api/plugins/kanban/*`). Boards are server-wide, not profile-scoped, and
/// column membership/ordering is authoritative on the server: Conduit renders
/// what it receives and never regroups or re-sorts tasks locally.

/// Known task statuses. The server's column list is authoritative for what is
/// displayed; this enum only supplies presentation metadata for names it
/// recognizes. Unknown statuses still render using the raw string.
enum KanbanStatus: String, CaseIterable {
    case triage
    case todo
    case scheduled
    case ready
    case running
    case blocked
    case review
    case done
    case archived

    static func from(_ raw: String?) -> KanbanStatus? {
        guard let raw else { return nil }
        return KanbanStatus(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var displayName: String {
        switch self {
        case .triage: return "Triage"
        case .todo: return "To Do"
        case .scheduled: return "Scheduled"
        case .ready: return "Ready"
        case .running: return "Running"
        case .blocked: return "Blocked"
        case .review: return "Review"
        case .done: return "Done"
        case .archived: return "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .triage: return "tray"
        case .todo: return "circle"
        case .scheduled: return "clock"
        case .ready: return "circle.dashed.inset.filled"
        case .running: return "play.circle"
        case .blocked: return "hand.raised"
        case .review: return "eye"
        case .done: return "checkmark.circle"
        case .archived: return "archivebox"
        }
    }

    /// Statuses a human may move a task into. `running` is dispatcher-only
    /// (the server rejects it with 400 unconditionally); `scheduled`/`review`
    /// are omitted until their PATCH semantics are verified server-side.
    static let moveTargets: [KanbanStatus] = [.triage, .todo, .ready, .blocked, .done, .archived]

    static func moveTargets(excluding current: String) -> [KanbanStatus] {
        let normalized = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return moveTargets.filter { $0.rawValue != normalized }
    }
}

struct KanbanTaskAge: Equatable {
    var createdAgeSeconds: Double?
    var startedAgeSeconds: Double?
    var timeToCompleteSeconds: Double?
}

struct KanbanDiagnostic: Identifiable, Equatable {
    // Diagnostics also carry an `actions` array of suggested recovery actions;
    // those are mutations and intentionally not modeled until the write phase.
    var id: String
    var kind: String
    var severity: String
    var title: String
    var detail: String?
    var count: Int?
    var lastSeenAt: Double?
}

struct KanbanWarningsBadge: Equatable {
    var count: Int
    var kinds: [String]
    var latestAt: Double?
    var highestSeverity: String?
}

struct KanbanProgress: Equatable {
    var done: Int
    var total: Int
}

struct KanbanLinkCounts: Equatable {
    var parents: Int
    var children: Int
}

struct KanbanTaskCard: Identifiable, Equatable {
    var id: String
    var title: String
    var status: String
    var assignee: String?
    var tenant: String?
    var priority: Int
    var createdAt: Double?
    var startedAt: Double?
    var completedAt: Double?
    var workspaceKind: String?
    var branchName: String?
    var projectID: String?
    var blockReason: String?
    var blockKind: String?
    var consecutiveFailures: Int
    var currentRunID: String?
    var sessionID: String?
    var modelOverride: String?
    var providerOverride: String?
    var reasoningEffort: String?
    var goalMode: Bool?
    var skills: [String]
    var age: KanbanTaskAge
    var latestSummary: String?
    var linkCounts: KanbanLinkCounts
    var commentCount: Int
    var progress: KanbanProgress?
    var diagnostics: [KanbanDiagnostic]
    var warnings: KanbanWarningsBadge?

    var kanbanStatus: KanbanStatus? { KanbanStatus.from(status) }
}

struct KanbanColumn: Identifiable, Equatable {
    // Server pre-sorts tasks (priority DESC, created_at ASC). Never re-sort.
    var name: String
    var tasks: [KanbanTaskCard]

    var id: String { name }
    var status: KanbanStatus? { KanbanStatus.from(name) }
}

struct KanbanBoardSnapshot: Equatable {
    var columns: [KanbanColumn]
    var tenants: [String]
    var assignees: [String]
    /// Monotonic cursor for the plugin's task-event feed. Unused for rendering
    /// today; it is the incremental-sync cursor for the events WebSocket phase.
    var latestEventID: Int?
    var serverNow: Double?

    var taskCount: Int { columns.reduce(0) { $0 + $1.tasks.count } }
}

struct KanbanBoardSummary: Identifiable, Equatable {
    var slug: String
    var name: String
    var description: String?
    var icon: String?
    var colorHex: String?
    var projectID: String?
    var projectName: String?
    var isCurrent: Bool
    var counts: [String: Int]
    var total: Int

    var id: String { slug }
}

struct KanbanComment: Identifiable, Equatable {
    var id: String
    var author: String?
    var body: String
    var createdAt: Double?
}

struct KanbanEvent: Identifiable, Equatable {
    var id: String
    var kind: String
    var runID: String?
    var payloadSummary: String?
    var createdAt: Double?
}

struct KanbanRun: Identifiable, Equatable {
    var id: String
    var profile: String?
    var status: String?
    var outcome: String?
    var summary: String?
    var error: String?
    var startedAt: Double?
    var endedAt: Double?
}

struct KanbanChildResult: Identifiable, Equatable {
    var id: String
    var title: String
    var status: String?
    var latestSummary: String?
    var result: String?
}

struct KanbanTaskDetail: Equatable {
    var task: KanbanTaskCard
    var body: String?
    var result: String?
    var comments: [KanbanComment]
    var events: [KanbanEvent]
    var parents: [String]
    var children: [String]
    var childResults: [KanbanChildResult]
    var runs: [KanbanRun]
}

struct KanbanTaskLog: Equatable {
    var exists: Bool
    var sizeBytes: Int
    var content: String
    var truncated: Bool
}
