import XCTest
@testable import Conduit

final class KanbanNormalizerTests: XCTestCase {

    // MARK: Board

    func testNormalizeBoardPreservesServerColumnOrder() {
        let payload = AnyCodable.object([
            "columns": .array([
                column(name: "triage"), column(name: "todo"), column(name: "scheduled"),
                column(name: "ready"), column(name: "running"), column(name: "blocked"),
                column(name: "review"), column(name: "done")
            ]),
            "tenants": .array([.string("acme")]),
            "assignees": .array([.string("default")]),
            "latest_event_id": .number(412),
            "now": .number(1_754_000_000)
        ])

        let board = KanbanNormalizer.normalizeBoard(payload)

        XCTAssertEqual(
            board?.columns.map(\.name),
            ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]
        )
        XCTAssertEqual(board?.tenants, ["acme"])
        XCTAssertEqual(board?.assignees, ["default"])
        XCTAssertEqual(board?.latestEventID, 412)
        XCTAssertEqual(board?.serverNow, 1_754_000_000)
    }

    func testNormalizeBoardIncludesArchivedColumnWhenPresent() {
        let payload = AnyCodable.object([
            "columns": .array([column(name: "done"), column(name: "archived")])
        ])

        let board = KanbanNormalizer.normalizeBoard(payload)

        XCTAssertEqual(board?.columns.map(\.name), ["done", "archived"])
        XCTAssertEqual(board?.columns.last?.status, .archived)
    }

    func testNormalizeBoardWithoutColumnsReturnsNil() {
        XCTAssertNil(KanbanNormalizer.normalizeBoard(.object(["tenants": .array([])])))
        XCTAssertNil(KanbanNormalizer.normalizeBoard(.string("nope")))
    }

    func testTaskCardPreservesInColumnOrderingFromServer() {
        let payload = column(name: "ready", tasks: [
            task(id: "t_b", title: "Second by priority"),
            task(id: "t_a", title: "First by priority")
        ])

        let normalized = KanbanNormalizer.normalizeColumn(payload)

        XCTAssertEqual(normalized?.tasks.map(\.id), ["t_b", "t_a"])
    }

    // MARK: Task cards

    func testNormalizeTaskCardParsesCoreFields() {
        let payload = AnyCodable.object([
            "id": .string("t_1f2e"),
            "title": .string("Fix reconnect race"),
            "status": .string("running"),
            "assignee": .string("builder"),
            "tenant": .string("acme"),
            "priority": .number(3),
            "created_at": .number(1_753_990_000),
            "started_at": .number(1_753_995_000),
            "workspace_kind": .string("worktree"),
            "branch_name": .string("kanban/t_1f2e"),
            "project_id": .string("p_9"),
            "consecutive_failures": .number(1),
            "session_id": .string("sess-77"),
            "skills": .array([.string("swift"), .string("review")]),
            "age": .object([
                "created_age_seconds": .number(7200),
                "started_age_seconds": .number(120)
            ]),
            "latest_summary": .string("Investigating the ticket mint path."),
            "link_counts": .object(["parents": .number(1), "children": .number(2)]),
            "comment_count": .number(4)
        ])

        let card = KanbanNormalizer.normalizeTaskCard(payload)

        XCTAssertEqual(card?.id, "t_1f2e")
        XCTAssertEqual(card?.title, "Fix reconnect race")
        XCTAssertEqual(card?.kanbanStatus, .running)
        XCTAssertEqual(card?.assignee, "builder")
        XCTAssertEqual(card?.priority, 3)
        XCTAssertEqual(card?.workspaceKind, "worktree")
        XCTAssertEqual(card?.branchName, "kanban/t_1f2e")
        XCTAssertEqual(card?.consecutiveFailures, 1)
        XCTAssertEqual(card?.sessionID, "sess-77")
        XCTAssertEqual(card?.skills, ["swift", "review"])
        XCTAssertEqual(card?.age.createdAgeSeconds, 7200)
        XCTAssertEqual(card?.latestSummary, "Investigating the ticket mint path.")
        XCTAssertEqual(card?.linkCounts, KanbanLinkCounts(parents: 1, children: 2))
        XCTAssertEqual(card?.commentCount, 4)
    }

    func testTaskCardSparsePayloadDoesNotInventData() {
        let payload = AnyCodable.object([
            "id": .string("t_min"),
            "title": .string("Old-server card"),
            "status": .string("todo")
        ])

        let card = KanbanNormalizer.normalizeTaskCard(payload)

        XCTAssertNotNil(card)
        XCTAssertNil(card?.assignee)
        XCTAssertNil(card?.reasoningEffort)
        XCTAssertNil(card?.goalMode)
        XCTAssertNil(card?.progress)
        XCTAssertNil(card?.warnings)
        XCTAssertNil(card?.latestSummary)
        XCTAssertNil(card?.blockReason)
        XCTAssertEqual(card?.diagnostics, [])
        XCTAssertEqual(card?.skills, [])
        XCTAssertEqual(card?.priority, 0)
        XCTAssertEqual(card?.commentCount, 0)
        XCTAssertEqual(card?.linkCounts, KanbanLinkCounts(parents: 0, children: 0))
    }

    func testTaskCardMissingIDReturnsNil() {
        XCTAssertNil(KanbanNormalizer.normalizeTaskCard(.object(["title": .string("Ghost")])))
        XCTAssertNil(KanbanNormalizer.normalizeTaskCard(.object(["id": .string("  ")])))
        XCTAssertNil(KanbanNormalizer.normalizeTaskCard(.string("t_x")))
    }

    func testTaskCardProgressNullVersusObject() {
        let withProgress = KanbanNormalizer.normalizeTaskCard(.object([
            "id": .string("t_p"),
            "progress": .object(["done": .number(3), "total": .number(7)])
        ]))
        let nullProgress = KanbanNormalizer.normalizeTaskCard(.object([
            "id": .string("t_n"),
            "progress": .null
        ]))

        XCTAssertEqual(withProgress?.progress, KanbanProgress(done: 3, total: 7))
        XCTAssertNil(nullProgress?.progress)
    }

    func testTaskCardParsesDiagnosticsAndWarningsBadge() {
        let payload = AnyCodable.object([
            "id": .string("t_d"),
            "diagnostics": .array([
                .object([
                    "kind": .string("stale_heartbeat"),
                    "severity": .string("ERROR"),
                    "title": .string("Worker heartbeat is stale"),
                    "detail": .string("No heartbeat for 300s"),
                    "count": .number(2)
                ])
            ]),
            "warnings": .object([
                "count": .number(2),
                "kinds": .array([.string("stale_heartbeat")]),
                "highest_severity": .string("error")
            ])
        ])

        let card = KanbanNormalizer.normalizeTaskCard(payload)

        XCTAssertEqual(card?.diagnostics.count, 1)
        XCTAssertEqual(card?.diagnostics.first?.severity, "error")
        XCTAssertEqual(card?.diagnostics.first?.detail, "No heartbeat for 300s")
        XCTAssertEqual(card?.warnings?.count, 2)
        XCTAssertEqual(card?.warnings?.highestSeverity, "error")
    }

    // MARK: Boards catalog

    func testNormalizeBoardsParsesCountsCurrentFlagAndCurrentSlug() {
        let payload = AnyCodable.object([
            "boards": .array([
                .object([
                    "slug": .string("default"),
                    "name": .string("Default"),
                    "is_current": .bool(true),
                    "counts": .object(["ready": .number(2), "done": .number(5)]),
                    "total": .number(7)
                ]),
                .object(["slug": .string("ops")])
            ]),
            "current": .string("default")
        ])

        let catalog = KanbanNormalizer.normalizeBoards(payload)

        XCTAssertEqual(catalog.boards.map(\.slug), ["default", "ops"])
        XCTAssertEqual(catalog.current, "default")
        XCTAssertEqual(catalog.boards.first?.isCurrent, true)
        XCTAssertEqual(catalog.boards.first?.counts["ready"], 2)
        XCTAssertEqual(catalog.boards.first?.total, 7)
        XCTAssertEqual(catalog.boards.last?.name, "ops")
        XCTAssertEqual(catalog.boards.last?.total, 0)
    }

    // MARK: Task detail

    func testNormalizeTaskDetailParsesCommentsEventsRunsLinksChildResults() {
        let payload = AnyCodable.object([
            "task": .object([
                "id": .string("t_full"),
                "title": .string("Parent"),
                "status": .string("review"),
                "body": .string("## Goal\nShip it."),
                "result": .string("PR opened.")
            ]),
            "comments": .array([
                .object(["id": .number(9), "author": .string("orchestrator"), "body": .string("Split into two."), "created_at": .number(1_753_990_100)])
            ]),
            "events": .array([
                .object(["id": .number(50), "kind": .string("status"), "payload": .object(["from": .string("ready"), "to": .string("running")])])
            ]),
            "links": .object([
                "parents": .array([.string("t_root")]),
                "children": .array([.string("t_c1"), .string("t_c2")])
            ]),
            "child_results": .array([
                .object(["id": .string("t_c1"), "title": .string("Child one"), "status": .string("done"), "latest_summary": .string("Merged.")])
            ]),
            "runs": .array([
                .object(["id": .string("r_1"), "profile": .string("builder"), "status": .string("done"), "outcome": .string("completed"), "summary": .string("Opened PR #4")])
            ])
        ])

        let detail = KanbanNormalizer.normalizeTaskDetail(payload)

        XCTAssertEqual(detail?.task.id, "t_full")
        XCTAssertEqual(detail?.body, "## Goal\nShip it.")
        XCTAssertEqual(detail?.result, "PR opened.")
        XCTAssertEqual(detail?.comments.count, 1)
        XCTAssertEqual(detail?.comments.first?.id, "9")
        XCTAssertEqual(detail?.comments.first?.author, "orchestrator")
        XCTAssertEqual(detail?.events.first?.kind, "status")
        XCTAssertNotNil(detail?.events.first?.payloadSummary)
        XCTAssertEqual(detail?.parents, ["t_root"])
        XCTAssertEqual(detail?.children, ["t_c1", "t_c2"])
        XCTAssertEqual(detail?.childResults.first?.title, "Child one")
        XCTAssertEqual(detail?.runs.first?.outcome, "completed")
    }

    func testNormalizeTaskDetailWithoutTaskReturnsNil() {
        XCTAssertNil(KanbanNormalizer.normalizeTaskDetail(.object(["comments": .array([])])))
    }

    func testEventWithArbitraryPayloadShapesDoesNotCrash() {
        let payloads: [AnyCodable] = [
            .null,
            .string("plain"),
            .number(4),
            .array([.string("a"), .string("b")]),
            .object(["nested": .object(["deep": .string("x")]), "flag": .bool(true)])
        ]
        for (index, payload) in payloads.enumerated() {
            let event = KanbanNormalizer.normalizeEvent(
                .object(["id": .number(Double(index)), "kind": .string("edited"), "payload": payload]),
                fallbackID: "f-\(index)"
            )
            XCTAssertNotNil(event)
        }
    }

    // MARK: Log + age

    func testNormalizeLogParsesTruncatedFlagAndContent() {
        let payload = AnyCodable.object([
            "task_id": .string("t_log"),
            "exists": .bool(true),
            "size_bytes": .number(120_000),
            "content": .string("worker: claimed"),
            "truncated": .bool(true)
        ])

        let log = KanbanNormalizer.normalizeLog(payload)

        XCTAssertEqual(log?.exists, true)
        XCTAssertEqual(log?.sizeBytes, 120_000)
        XCTAssertEqual(log?.content, "worker: claimed")
        XCTAssertEqual(log?.truncated, true)
    }

    func testAgeLabelFormatsSecondsMinutesHoursDays() {
        XCTAssertEqual(KanbanNormalizer.ageLabel(30), "now")
        XCTAssertEqual(KanbanNormalizer.ageLabel(180), "3m")
        XCTAssertEqual(KanbanNormalizer.ageLabel(7200), "2h")
        XCTAssertEqual(KanbanNormalizer.ageLabel(5 * 86_400), "5d")
        XCTAssertNil(KanbanNormalizer.ageLabel(nil))
        XCTAssertNil(KanbanNormalizer.ageLabel(-5))
    }

    // MARK: Fixtures

    private func column(name: String, tasks: [AnyCodable] = []) -> AnyCodable {
        .object(["name": .string(name), "tasks": .array(tasks)])
    }

    private func task(id: String, title: String) -> AnyCodable {
        .object(["id": .string(id), "title": .string(title), "status": .string("ready")])
    }
}
