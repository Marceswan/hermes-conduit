import XCTest
@testable import Conduit

@MainActor
final class KanbanBoardServiceTests: XCTestCase {

    // MARK: classify

    func testClassifyPluginNotFoundDetailMapsToUnavailable() {
        let result = KanbanBoardService.classify(DashboardTicketBridgeError.requestFailed("Plugin not found"))
        XCTAssertEqual(result, .unavailable)
    }

    func testClassifyBareStatus404MapsToUnavailable() {
        let result = KanbanBoardService.classify(DashboardTicketBridgeError.requestFailed("Dashboard request failed (404)."))
        XCTAssertEqual(result, .unavailable)
    }

    func testClassifySignInRequiredMapsToSignInState() {
        XCTAssertEqual(KanbanBoardService.classify(DashboardTicketBridgeError.signInRequired), .signInRequired)
    }

    func testClassifyNotReadyIsRetryableNotUnavailable() {
        let result = KanbanBoardService.classify(DashboardTicketBridgeError.notReady)
        if case .failed = result {
            // Retryable — correct.
        } else {
            XCTFail("notReady must classify as a transient failure, got \(result)")
        }
    }

    func testClassifyGenericFailureKeepsRetryableFailed() {
        let result = KanbanBoardService.classify(DashboardTicketBridgeError.requestFailed("The request timed out."))
        XCTAssertEqual(result, .failed("The request timed out."))
    }

    // MARK: Loading

    func testLoadBoardSuccessSetsAvailableAndSnapshot() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7))
        let service = makeService(requester: requester)

        await service.loadBoard()

        XCTAssertEqual(service.availability, .available)
        XCTAssertEqual(service.snapshot?.columns.map(\.name), ["ready", "done"])
        XCTAssertEqual(service.snapshot?.latestEventID, 7)
    }

    func testQuietRefreshFailureRetainsPreviousSnapshot() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7))
        let service = makeService(requester: requester)
        await service.loadBoard()

        requester.results["/api/plugins/kanban/board"] = .failure(DashboardTicketBridgeError.requestFailed("The request timed out."))
        await service.loadBoard(quiet: true)

        XCTAssertEqual(service.availability, .available)
        XCTAssertNotNil(service.snapshot)
    }

    func testQuietRefreshSkipsPublishWhenEventCursorUnchanged() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7))
        let service = makeService(requester: requester)
        await service.loadBoard()
        let first = service.snapshot

        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7, columnName: "blocked"))
        await service.loadBoard(quiet: true)

        XCTAssertEqual(service.snapshot, first)
    }

    func testUnavailableWithPersistedSlugRetriesServerDefaultAndClearsSelection() async {
        let defaults = makeDefaults()
        let store = KanbanBoardSelectionStore(defaults: defaults)
        store.setSelectedBoard("gone-board", forServer: "https://h.example")

        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/board?board="] = .failure(DashboardTicketBridgeError.requestFailed("Board not found"))
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let service = KanbanBoardService(requester: requester, selectionStore: store, serverKey: "https://h.example")

        await service.loadBoard()

        XCTAssertEqual(service.availability, .available)
        XCTAssertNil(service.selectedBoardSlug)
        XCTAssertNil(store.selectedBoard(forServer: "https://h.example"))
    }

    func testSelectBoardPersistsSlugAndAppendsEncodedQuery() async {
        let defaults = makeDefaults()
        let store = KanbanBoardSelectionStore(defaults: defaults)
        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let service = KanbanBoardService(requester: requester, selectionStore: store, serverKey: "https://h.example")

        await service.selectBoard("ops-board")

        XCTAssertEqual(store.selectedBoard(forServer: "https://h.example"), "ops-board")
        XCTAssertTrue(requester.requestedPaths.contains("/api/plugins/kanban/board?board=ops-board"))
    }

    func testTaskPathRejectsUnsafeTaskID() {
        XCTAssertNil(KanbanPath.task(id: "t_x/../y", board: nil))
        XCTAssertNil(KanbanPath.task(id: "t_x?board=evil", board: nil))
        XCTAssertNil(KanbanPath.task(id: "", board: nil))
        XCTAssertEqual(KanbanPath.task(id: "t_1f2e", board: nil), "/api/plugins/kanban/tasks/t_1f2e")
    }

    func testLogRequestUsesReducedMaxResponseBytes() async throws {
        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/tasks/t_1/log"] = .success([
            "exists": true, "size_bytes": 10, "content": "x", "truncated": false
        ])
        let service = makeService(requester: requester)

        _ = try await service.loadTaskLog("t_1")

        XCTAssertEqual(requester.maxResponseBytesByPath.first(where: { $0.key.contains("/log") })?.value, 1024 * 1024)
    }

    // MARK: Mutations

    func testMoveTaskPatchesStatusAndReloadsBoard() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let moved = await service.moveTask("t_1", to: "done")

        XCTAssertTrue(moved)
        let patch = requester.requests.first(where: { $0.method == "PATCH" })
        XCTAssertEqual(patch?.path, "/api/plugins/kanban/tasks/t_1")
        XCTAssertEqual(patch?.body?["status"] as? String, "done")
        XCTAssertNil(patch?.body?["block_reason"])
        XCTAssertTrue(requester.requests.contains { $0.method == "GET" && $0.path == "/api/plugins/kanban/board" })
        XCTAssertNotNil(service.snapshot)
        XCTAssertNil(service.mutatingTaskID)
    }

    func testMoveTaskWithBoardSelectedAppendsBoardQuery() async {
        let defaults = makeDefaults()
        let store = KanbanBoardSelectionStore(defaults: defaults)
        store.setSelectedBoard("ops-board", forServer: "https://h.example")
        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = KanbanBoardService(requester: requester, selectionStore: store, serverKey: "https://h.example", dispatchNudgeDelay: .zero)

        _ = await service.moveTask("t_1", to: "ready")

        XCTAssertEqual(
            requester.requests.first(where: { $0.method == "PATCH" })?.path,
            "/api/plugins/kanban/tasks/t_1?board=ops-board"
        )
    }

    func testMoveTaskRejectsRunningTarget() async {
        let requester = StubKanbanRequester()
        let service = makeService(requester: requester)

        let moved = await service.moveTask("t_1", to: "running")

        XCTAssertFalse(moved)
        XCTAssertTrue(requester.requests.isEmpty)
    }

    func testMoveToBlockedIncludesTrimmedReasonAndOmitsEmpty() async {
        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        _ = await service.moveTask("t_1", to: "blocked", blockReason: "  waiting on schema  ")
        _ = await service.moveTask("t_1", to: "blocked", blockReason: "   ")

        let patches = requester.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.count, 2)
        XCTAssertEqual(patches[0].body?["block_reason"] as? String, "waiting on schema")
        XCTAssertNil(patches[1].body?["block_reason"])
    }

    func testMoveTaskRefusedSurfacesServerMessageVerbatim() async {
        let refusal = "Cannot move to ready: blocked by parent t_2 (Design schema)"
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let service = makeService(requester: requester)
        await service.loadBoard()
        let before = service.snapshot
        requester.results["/api/plugins/kanban/tasks/t_1"] = .failure(DashboardTicketBridgeError.requestFailed(refusal))

        let moved = await service.moveTask("t_1", to: "ready")

        XCTAssertFalse(moved)
        XCTAssertEqual(service.lastActionError?.message, refusal)
        XCTAssertEqual(service.snapshot, before)
    }

    func testMutationSingleFlightRejectsSecondAction() async {
        let requester = StubKanbanRequester()
        requester.delay = .milliseconds(100)
        requester.resultsByPrefix["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let first = Task { await service.moveTask("t_1", to: "done") }
        await Task.yield()
        let second = await service.moveTask("t_1", to: "todo")
        let firstResult = await first.value

        XCTAssertTrue(firstResult)
        XCTAssertFalse(second)
        XCTAssertEqual(requester.requests.filter { $0.method == "PATCH" }.count, 1)
        XCTAssertNil(service.mutatingTaskID)
    }

    func testQuietPollSuppressedWhileMutationInFlight() async {
        let requester = StubKanbanRequester()
        requester.delay = .milliseconds(100)
        requester.resultsByPrefix["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let mutation = Task { await service.moveTask("t_1", to: "done") }
        await Task.yield()
        await service.loadBoard(quiet: true)
        _ = await mutation.value

        XCTAssertEqual(
            requester.requests.filter { $0.method == "GET" && $0.path.hasPrefix("/api/plugins/kanban/board") }.count,
            1,
            "Only the mutation's own reload should hit /board; the quiet poll must early-return"
        )
    }

    func testReclaimPostsToReclaimPath() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1/reclaim"] = .success(["ok": true])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let reclaimed = await service.reclaimTask("t_1")

        XCTAssertTrue(reclaimed)
        XCTAssertEqual(
            requester.requests.first(where: { $0.method == "POST" && $0.path.contains("/reclaim") })?.path,
            "/api/plugins/kanban/tasks/t_1/reclaim"
        )
    }

    func testReassignNilSendsEmptyStringAssignee() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        _ = await service.reassignTask("t_1", to: nil)

        XCTAssertEqual(
            requester.requests.first(where: { $0.method == "PATCH" })?.body?["assignee"] as? String,
            ""
        )
    }

    func testSetPriorityPatchesPriority() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        _ = await service.setPriority("t_1", to: 3)

        XCTAssertEqual(requester.requests.first(where: { $0.method == "PATCH" })?.body?["priority"] as? Int, 3)
    }

    func testDeleteTaskUsesDeleteMethod() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .success(["deleted": true, "task_id": "t_1"])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let deleted = await service.deleteTask("t_1")

        XCTAssertTrue(deleted)
        let request = requester.requests.first(where: { $0.method == "DELETE" })
        XCTAssertEqual(request?.path, "/api/plugins/kanban/tasks/t_1")
        XCTAssertNil(request?.body)
    }

    func testAddCommentPostsBodyAndConduitAuthor() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1/comments"] = .success(["ok": true])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let posted = await service.addComment("t_1", body: "  looks good  ")

        XCTAssertTrue(posted)
        let post = requester.requests.first(where: { $0.path.contains("/comments") })
        XCTAssertEqual(post?.method, "POST")
        XCTAssertEqual(post?.body?["body"] as? String, "looks good")
        XCTAssertEqual(post?.body?["author"] as? String, "conduit")
    }

    func testAddEmptyCommentIsRejectedWithoutRequest() async {
        let requester = StubKanbanRequester()
        let service = makeService(requester: requester)

        let posted = await service.addComment("t_1", body: "   ")

        XCTAssertFalse(posted)
        XCTAssertTrue(requester.requests.isEmpty)
    }

    func testCreateTaskBodyShapeIncludesPriorityAndTriage() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks"] = .success(["task": ["id": "t_new"]])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let created = await service.createTask(title: "Ship it", body: "Details", assignee: "builder", priority: 1, triage: true)

        XCTAssertTrue(created)
        let post = requester.requests.first(where: { $0.path == "/api/plugins/kanban/tasks" })
        XCTAssertEqual(post?.method, "POST")
        XCTAssertEqual(post?.body?["title"] as? String, "Ship it")
        XCTAssertEqual(post?.body?["body"] as? String, "Details")
        XCTAssertEqual(post?.body?["assignee"] as? String, "builder")
        XCTAssertEqual(post?.body?["priority"] as? Int, 1)
        XCTAssertEqual(post?.body?["triage"] as? Bool, true)
    }

    func testCreateTaskOmitsEmptyOptionalFields() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks"] = .success(["task": ["id": "t_new"]])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        _ = await service.createTask(title: "Bare", body: "  ", assignee: nil, priority: 0, triage: false)

        let post = requester.requests.first(where: { $0.path == "/api/plugins/kanban/tasks" })
        XCTAssertNil(post?.body?["body"])
        XCTAssertNil(post?.body?["assignee"])
    }

    func testCreateTaskSurfacesDispatcherWarningAsNotice() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks"] = .success(["task": ["id": "t_new"], "warning": "no dispatcher running"])
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        let service = makeService(requester: requester)

        let created = await service.createTask(title: "Ship it", body: nil, assignee: nil, priority: 0, triage: false)

        XCTAssertTrue(created)
        XCTAssertEqual(service.lastActionNotice, "no dispatcher running")
        XCTAssertNil(service.lastActionError)
    }

    func testDispatchNudgeFiresOnceAfterSuccessfulWrite() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        requester.resultsByPrefix["/api/plugins/kanban/dispatch"] = .success(["spawned": []])
        let service = makeService(requester: requester)

        _ = await service.moveTask("t_1", to: "done")
        await service.dispatchNudgeTask?.value

        XCTAssertEqual(
            requester.requests.filter { $0.path.hasPrefix("/api/plugins/kanban/dispatch?max=8") }.count,
            1
        )
    }

    func testDispatchNudgeDebouncedAcrossRapidWrites() async {
        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 2))
        requester.resultsByPrefix["/api/plugins/kanban/dispatch"] = .success(["spawned": []])
        let service = makeService(requester: requester, dispatchNudgeDelay: .milliseconds(60))

        _ = await service.moveTask("t_1", to: "ready")
        _ = await service.moveTask("t_1", to: "done")
        await service.dispatchNudgeTask?.value

        XCTAssertEqual(
            requester.requests.filter { $0.path.hasPrefix("/api/plugins/kanban/dispatch") }.count,
            1,
            "Rapid consecutive writes must collapse into one nudge"
        )
    }

    func testFailedWriteDoesNotNudge() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .failure(DashboardTicketBridgeError.requestFailed("boom"))
        let service = makeService(requester: requester)

        _ = await service.moveTask("t_1", to: "done")
        await service.dispatchNudgeTask?.value

        XCTAssertFalse(requester.requests.contains { $0.path.hasPrefix("/api/plugins/kanban/dispatch") })
    }

    func testActionErrorAutoClears() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .failure(DashboardTicketBridgeError.requestFailed("boom"))
        let service = makeService(requester: requester, actionErrorClearDelay: .milliseconds(20))

        _ = await service.moveTask("t_1", to: "done")
        XCTAssertNotNil(service.lastActionError)

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(service.lastActionError)
    }

    func testWriteAuthExpiryFlipsAvailabilityToSignIn() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/tasks/t_1"] = .failure(DashboardTicketBridgeError.signInRequired)
        let service = makeService(requester: requester)

        let moved = await service.moveTask("t_1", to: "done")

        XCTAssertFalse(moved)
        XCTAssertEqual(service.availability, .signInRequired)
        XCTAssertNil(service.lastActionError)
    }

    func testMoveTargetsExcludeRunningAndCurrent() {
        let targets = KanbanStatus.moveTargets(excluding: "Todo")
        XCTAssertFalse(targets.contains(.running))
        XCTAssertFalse(targets.contains(.todo))
        XCTAssertTrue(targets.contains(.ready))
        XCTAssertFalse(KanbanStatus.moveTargets.contains(.running))
    }

    // MARK: Event streaming

    func testHandleEventBatchTriggersQuietReload() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7))
        let service = makeService(requester: requester)
        await service.loadBoard()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 9, columnName: "done"))

        service.handleEventBatch(KanbanEventFrame(eventCount: 1, cursor: 9))
        await service.eventReloadTask?.value

        XCTAssertEqual(
            requester.requests.filter { $0.method == "GET" && $0.path.hasPrefix("/api/plugins/kanban/board") }.count,
            2
        )
        XCTAssertEqual(service.snapshot?.latestEventID, 9)
    }

    func testHandleEventBatchCoalescesRapidBatches() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7))
        let service = makeService(requester: requester, eventReloadDebounce: .milliseconds(50))
        await service.loadBoard()

        service.handleEventBatch(KanbanEventFrame(eventCount: 1, cursor: 8))
        service.handleEventBatch(KanbanEventFrame(eventCount: 1, cursor: 9))
        service.handleEventBatch(KanbanEventFrame(eventCount: 1, cursor: 10))
        await service.eventReloadTask?.value

        XCTAssertEqual(
            requester.requests.filter { $0.method == "GET" && $0.path.hasPrefix("/api/plugins/kanban/board") }.count,
            2,
            "Three rapid batches must coalesce into one extra reload"
        )
    }

    func testHandleEventBatchSuppressedDuringMutation() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7))
        let service = makeService(requester: requester)
        await service.loadBoard()
        requester.delay = .milliseconds(100)
        requester.resultsByPrefix["/api/plugins/kanban/tasks/t_1"] = .success(["task": ["id": "t_1"]])

        let mutation = Task { await service.moveTask("t_1", to: "done") }
        await Task.yield()
        service.handleEventBatch(KanbanEventFrame(eventCount: 1, cursor: 8))
        await service.eventReloadTask?.value
        _ = await mutation.value

        // Initial load + the mutation's own reload only; the event batch's
        // reload was dropped by the mutation guard.
        XCTAssertEqual(
            requester.requests.filter { $0.method == "GET" && $0.path.hasPrefix("/api/plugins/kanban/board") }.count,
            2
        )
    }

    func testStartEventStreamingNoOpWithoutTicketProvider() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let service = makeService(requester: requester)
        await service.loadBoard()

        service.startEventStreaming()

        XCTAssertFalse(service.streamConnected)
    }

    func testStartEventStreamingNoOpWhenUnavailable() async {
        let requester = StubKanbanRequester()
        let ticketProvider = FakeKanbanTicketProvider()
        let service = makeService(requester: requester, ticketProvider: ticketProvider)

        service.startEventStreaming()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(ticketProvider.mintCount, 0)
    }

    func testStartEventStreamingMintsTicketWhenAvailable() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let ticketProvider = FakeKanbanTicketProvider()
        let service = makeService(requester: requester, ticketProvider: ticketProvider)
        await service.loadBoard()

        service.startEventStreaming()
        await waitUntil { ticketProvider.mintCount >= 1 }

        XCTAssertGreaterThanOrEqual(ticketProvider.mintCount, 1)
        service.stopEventStreaming()
    }

    func testSelectBoardRestartsStream() async {
        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let ticketProvider = FakeKanbanTicketProvider()
        let service = makeService(requester: requester, ticketProvider: ticketProvider)
        await service.loadBoard()
        service.startEventStreaming()
        await waitUntil { ticketProvider.mintCount >= 1 }

        await service.selectBoard("ops")
        await waitUntil { ticketProvider.mintCount >= 2 }

        XCTAssertGreaterThanOrEqual(ticketProvider.mintCount, 2)
        service.stopEventStreaming()
    }

    func testSetIncludeArchivedDoesNotRestartStream() async {
        let requester = StubKanbanRequester()
        requester.resultsByPrefix["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let ticketProvider = FakeKanbanTicketProvider()
        ticketProvider.result = .failure(DashboardTicketBridgeError.notReady)
        let service = makeService(requester: requester, ticketProvider: ticketProvider)
        await service.loadBoard()
        service.startEventStreaming()
        await waitUntil { ticketProvider.mintCount >= 1 }
        let mintsBefore = ticketProvider.mintCount

        await service.setIncludeArchived(true)
        try? await Task.sleep(for: .milliseconds(50))

        // The failing provider backs off for 1s+, so an immediate restart
        // would show up as an extra mint within this window.
        XCTAssertEqual(ticketProvider.mintCount, mintsBefore)
        service.stopEventStreaming()
    }

    func testStreamSignInRequiredFlipsAvailability() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 1))
        let ticketProvider = FakeKanbanTicketProvider()
        ticketProvider.result = .failure(DashboardTicketBridgeError.signInRequired)
        let service = makeService(requester: requester, ticketProvider: ticketProvider)
        await service.loadBoard()

        service.startEventStreaming()
        await waitUntil { service.availability == .signInRequired }

        XCTAssertEqual(service.availability, .signInRequired)
        XCTAssertFalse(service.streamConnected)
    }

    func testStopEventStreamingCancelsPendingReload() async {
        let requester = StubKanbanRequester()
        requester.results["/api/plugins/kanban/board"] = .success(Self.boardPayload(eventID: 7))
        let service = makeService(requester: requester, eventReloadDebounce: .milliseconds(100))
        await service.loadBoard()

        service.handleEventBatch(KanbanEventFrame(eventCount: 1, cursor: 8))
        service.stopEventStreaming()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            requester.requests.filter { $0.method == "GET" && $0.path.hasPrefix("/api/plugins/kanban/board") }.count,
            1,
            "Stopping streaming must cancel the pending coalesced reload"
        )
    }

    // MARK: Helpers

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < timeout {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeService(
        requester: StubKanbanRequester,
        dispatchNudgeDelay: Duration = .zero,
        actionErrorClearDelay: Duration = .seconds(6),
        ticketProvider: KanbanTicketProviding? = nil,
        eventReloadDebounce: Duration = .zero
    ) -> KanbanBoardService {
        KanbanBoardService(
            requester: requester,
            selectionStore: KanbanBoardSelectionStore(defaults: makeDefaults()),
            serverKey: "https://h.example",
            dispatchNudgeDelay: dispatchNudgeDelay,
            actionErrorClearDelay: actionErrorClearDelay,
            ticketProvider: ticketProvider,
            streamBaseURL: ticketProvider == nil ? nil : "https://h.example",
            eventReloadDebounce: eventReloadDebounce
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "kanban-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private static func boardPayload(eventID: Int, columnName: String = "ready") -> [String: Any] {
        [
            "columns": [
                ["name": columnName, "tasks": [["id": "t_1", "title": "One", "status": columnName]]],
                ["name": "done", "tasks": []]
            ],
            "tenants": [],
            "assignees": [],
            "latest_event_id": eventID,
            "now": 1_754_000_000
        ]
    }
}

// MARK: - Fakes

@MainActor
private final class FakeKanbanTicketProvider: KanbanTicketProviding {
    var result: Result<String, Error> = .success("ticket-1")
    private(set) var mintCount = 0

    func mintTicket() async throws -> String {
        mintCount += 1
        return try result.get()
    }
}

// MARK: - Stub requester

@MainActor
private final class StubKanbanRequester: KanbanRequesting {
    var results: [String: Result<[String: Any], Error>] = [:]
    var resultsByPrefix: [String: Result<[String: Any], Error>] = [:]
    var delay: Duration = .zero
    private(set) var requestedPaths: [String] = []
    private(set) var requests: [(path: String, method: String, body: [String: Any]?)] = []
    private(set) var maxResponseBytesByPath: [String: Int] = [:]

    func requestJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        timeoutMilliseconds: Int,
        maxResponseBytes: Int
    ) async throws -> [String: Any] {
        requestedPaths.append(path)
        requests.append((path: path, method: method, body: body))
        maxResponseBytesByPath[path] = maxResponseBytes
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        if let exact = results[path] {
            return try exact.get()
        }
        if let prefixed = resultsByPrefix.first(where: { path.hasPrefix($0.key) })?.value {
            return try prefixed.get()
        }
        throw DashboardTicketBridgeError.requestFailed("Unstubbed path: \(path)")
    }
}
