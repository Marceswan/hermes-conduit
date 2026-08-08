//
//  KanbanNormalizer.swift
//  Conduit
//

import Foundation

/// Pure parsing of `/api/plugins/kanban/*` payloads into Kanban models.
/// Mirrors the MessageNormalizer discipline: tolerant of missing or renamed
/// keys, never invents data for absent fields, and never traps on arbitrary
/// payload shapes. Bridge dictionaries enter via `AnyCodable.from(_:)`.
enum KanbanNormalizer {

    // MARK: Board

    static func normalizeBoard(_ payload: AnyCodable) -> KanbanBoardSnapshot? {
        guard let object = payload.objectValue else { return nil }
        let columns = (object["columns"]?.arrayValue ?? []).compactMap(normalizeColumn)
        guard object["columns"]?.arrayValue != nil else { return nil }
        return KanbanBoardSnapshot(
            columns: columns,
            tenants: stringArray(object["tenants"]),
            assignees: stringArray(object["assignees"]),
            latestEventID: object["latest_event_id"]?.intValue ?? object["latestEventId"]?.intValue,
            serverNow: object["now"]?.doubleValue
        )
    }

    static func normalizeColumn(_ item: AnyCodable) -> KanbanColumn? {
        guard let object = item.objectValue else { return nil }
        let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let tasks = (object["tasks"]?.arrayValue ?? []).compactMap(normalizeTaskCard)
        return KanbanColumn(name: name, tasks: tasks)
    }

    static func normalizeTaskCard(_ item: AnyCodable) -> KanbanTaskCard? {
        guard let object = item.objectValue else { return nil }
        let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return nil }

        let ageObject = object["age"]?.objectValue ?? [:]
        let linkObject = object["link_counts"]?.objectValue ?? object["linkCounts"]?.objectValue ?? [:]

        var progress: KanbanProgress?
        if let progressObject = object["progress"]?.objectValue,
           let done = progressObject["done"]?.intValue,
           let total = progressObject["total"]?.intValue {
            progress = KanbanProgress(done: done, total: total)
        }

        var warnings: KanbanWarningsBadge?
        if let warningsObject = object["warnings"]?.objectValue,
           let count = warningsObject["count"]?.intValue {
            warnings = KanbanWarningsBadge(
                count: count,
                kinds: stringArray(warningsObject["kinds"]),
                latestAt: warningsObject["latest_at"]?.doubleValue,
                highestSeverity: warningsObject["highest_severity"]?.stringValue
            )
        }

        return KanbanTaskCard(
            id: id,
            title: firstNonEmptyString([object["title"]]) ?? "Untitled task",
            status: object["status"]?.stringValue?.lowercased() ?? "",
            assignee: firstNonEmptyString([object["assignee"]]),
            tenant: firstNonEmptyString([object["tenant"]]),
            priority: object["priority"]?.intValue ?? 0,
            createdAt: object["created_at"]?.doubleValue,
            startedAt: object["started_at"]?.doubleValue,
            completedAt: object["completed_at"]?.doubleValue,
            workspaceKind: object["workspace_kind"]?.stringValue,
            branchName: firstNonEmptyString([object["branch_name"]]),
            projectID: firstNonEmptyString([object["project_id"]]),
            blockReason: firstNonEmptyString([object["block_reason"]]),
            blockKind: firstNonEmptyString([object["block_kind"]]),
            consecutiveFailures: object["consecutive_failures"]?.intValue ?? 0,
            currentRunID: firstNonEmptyString([object["current_run_id"]]),
            sessionID: firstNonEmptyString([object["session_id"]]),
            modelOverride: firstNonEmptyString([object["model_override"]]),
            providerOverride: firstNonEmptyString([object["provider_override"]]),
            reasoningEffort: firstNonEmptyString([object["reasoning_effort"]]),
            goalMode: object["goal_mode"]?.boolValue,
            skills: stringArray(object["skills"]),
            age: KanbanTaskAge(
                createdAgeSeconds: ageObject["created_age_seconds"]?.doubleValue,
                startedAgeSeconds: ageObject["started_age_seconds"]?.doubleValue,
                timeToCompleteSeconds: ageObject["time_to_complete_seconds"]?.doubleValue
            ),
            latestSummary: firstNonEmptyString([object["latest_summary"], object["latestSummary"]]),
            linkCounts: KanbanLinkCounts(
                parents: linkObject["parents"]?.intValue ?? 0,
                children: linkObject["children"]?.intValue ?? 0
            ),
            commentCount: object["comment_count"]?.intValue ?? object["commentCount"]?.intValue ?? 0,
            progress: progress,
            diagnostics: (object["diagnostics"]?.arrayValue ?? []).enumerated().compactMap { index, item in
                normalizeDiagnostic(item, fallbackID: "\(id)-diagnostic-\(index)")
            },
            warnings: warnings
        )
    }

    static func normalizeDiagnostic(_ item: AnyCodable, fallbackID: String) -> KanbanDiagnostic? {
        guard let object = item.objectValue else { return nil }
        let kind = object["kind"]?.stringValue ?? ""
        let title = firstNonEmptyString([object["title"], object["detail"]]) ?? kind
        guard !kind.isEmpty || !title.isEmpty else { return nil }
        return KanbanDiagnostic(
            id: kind.isEmpty ? fallbackID : "\(fallbackID)-\(kind)",
            kind: kind,
            severity: object["severity"]?.stringValue?.lowercased() ?? "warning",
            title: title,
            detail: firstNonEmptyString([object["detail"]]),
            count: object["count"]?.intValue,
            lastSeenAt: object["last_seen_at"]?.doubleValue
        )
    }

    // MARK: Boards catalog

    static func normalizeBoards(_ payload: AnyCodable) -> (boards: [KanbanBoardSummary], current: String?) {
        let object = payload.objectValue ?? [:]
        let boards = (object["boards"]?.arrayValue ?? []).compactMap(normalizeBoardSummary)
        return (boards, firstNonEmptyString([object["current"]]))
    }

    static func normalizeBoardSummary(_ item: AnyCodable) -> KanbanBoardSummary? {
        guard let object = item.objectValue else { return nil }
        let slug = object["slug"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !slug.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for (key, value) in object["counts"]?.objectValue ?? [:] {
            if let count = value.intValue { counts[key] = count }
        }
        return KanbanBoardSummary(
            slug: slug,
            name: firstNonEmptyString([object["name"]]) ?? slug,
            description: firstNonEmptyString([object["description"]]),
            icon: firstNonEmptyString([object["icon"]]),
            colorHex: firstNonEmptyString([object["color"]]),
            projectID: firstNonEmptyString([object["project_id"]]),
            projectName: firstNonEmptyString([object["project_name"]]),
            isCurrent: object["is_current"]?.boolValue ?? false,
            counts: counts,
            total: object["total"]?.intValue ?? counts.values.reduce(0, +)
        )
    }

    // MARK: Task detail

    static func normalizeTaskDetail(_ payload: AnyCodable) -> KanbanTaskDetail? {
        guard let object = payload.objectValue,
              let taskPayload = object["task"],
              let task = normalizeTaskCard(taskPayload) else { return nil }
        let taskObject = taskPayload.objectValue ?? [:]
        let links = object["links"]?.objectValue ?? [:]
        return KanbanTaskDetail(
            task: task,
            body: firstNonEmptyString([taskObject["body"]]),
            result: firstNonEmptyString([taskObject["result"]]),
            comments: (object["comments"]?.arrayValue ?? []).enumerated().compactMap { index, item in
                normalizeComment(item, fallbackID: "\(task.id)-comment-\(index)")
            },
            events: (object["events"]?.arrayValue ?? []).enumerated().compactMap { index, item in
                normalizeEvent(item, fallbackID: "\(task.id)-event-\(index)")
            },
            parents: stringArray(links["parents"]),
            children: stringArray(links["children"]),
            childResults: (object["child_results"]?.arrayValue ?? []).compactMap(normalizeChildResult),
            runs: (object["runs"]?.arrayValue ?? []).enumerated().compactMap { index, item in
                normalizeRun(item, fallbackID: "\(task.id)-run-\(index)")
            }
        )
    }

    static func normalizeComment(_ item: AnyCodable, fallbackID: String) -> KanbanComment? {
        guard let object = item.objectValue else { return nil }
        let body = firstNonEmptyString([object["body"]]) ?? ""
        guard !body.isEmpty else { return nil }
        return KanbanComment(
            id: identifier(object["id"]) ?? fallbackID,
            author: firstNonEmptyString([object["author"]]),
            body: body,
            createdAt: object["created_at"]?.doubleValue
        )
    }

    static func normalizeEvent(_ item: AnyCodable, fallbackID: String) -> KanbanEvent? {
        guard let object = item.objectValue else { return nil }
        let kind = firstNonEmptyString([object["kind"]]) ?? ""
        guard !kind.isEmpty else { return nil }
        return KanbanEvent(
            id: identifier(object["id"]) ?? fallbackID,
            kind: kind,
            runID: identifier(object["run_id"]),
            payloadSummary: compactPayloadSummary(object["payload"]),
            createdAt: object["created_at"]?.doubleValue
        )
    }

    static func normalizeRun(_ item: AnyCodable, fallbackID: String) -> KanbanRun? {
        guard let object = item.objectValue else { return nil }
        return KanbanRun(
            id: identifier(object["id"]) ?? fallbackID,
            profile: firstNonEmptyString([object["profile"]]),
            status: firstNonEmptyString([object["status"]]),
            outcome: firstNonEmptyString([object["outcome"]]),
            summary: firstNonEmptyString([object["summary"]]),
            error: firstNonEmptyString([object["error"]]),
            startedAt: object["started_at"]?.doubleValue,
            endedAt: object["ended_at"]?.doubleValue
        )
    }

    static func normalizeChildResult(_ item: AnyCodable) -> KanbanChildResult? {
        guard let object = item.objectValue else { return nil }
        guard let id = identifier(object["id"]) else { return nil }
        return KanbanChildResult(
            id: id,
            title: firstNonEmptyString([object["title"]]) ?? id,
            status: firstNonEmptyString([object["status"]]),
            latestSummary: firstNonEmptyString([object["latest_summary"]]),
            result: firstNonEmptyString([object["result"]])
        )
    }

    // MARK: Log

    static func normalizeLog(_ payload: AnyCodable) -> KanbanTaskLog? {
        guard let object = payload.objectValue else { return nil }
        return KanbanTaskLog(
            exists: object["exists"]?.boolValue ?? false,
            sizeBytes: object["size_bytes"]?.intValue ?? 0,
            content: object["content"]?.stringValue ?? "",
            truncated: object["truncated"]?.boolValue ?? false
        )
    }

    // MARK: Display helpers

    /// Compact "3m" / "2h" / "5d" age labels for card rows.
    static func ageLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h" }
        return "\(Int(seconds / 86_400))d"
    }

    // MARK: Private

    /// Event payloads are arbitrary server dictionaries; render a short
    /// human-scannable summary and never fail on unexpected shapes.
    private static func compactPayloadSummary(_ payload: AnyCodable?) -> String? {
        guard let payload else { return nil }
        switch payload {
        case .null:
            return nil
        case .string(let text):
            return text.isEmpty ? nil : text
        case .bool, .number:
            return payload.descriptiveStringValue
        case .array(let items):
            return items.isEmpty ? nil : "\(items.count) items"
        case .object(let object):
            let parts = object
                .sorted { $0.key < $1.key }
                .prefix(4)
                .compactMap { key, value -> String? in
                    switch value {
                    case .array, .object, .null: return nil
                    default: return value.descriptiveStringValue.map { "\(key): \($0.prefix(60))" }
                    }
                }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private static func identifier(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let number = value.doubleValue {
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        return nil
    }

    private static func stringArray(_ value: AnyCodable?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0.stringValue }.filter { !$0.isEmpty }
    }

    private static func firstNonEmptyString(_ values: [AnyCodable?]) -> String? {
        for value in values {
            if let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
