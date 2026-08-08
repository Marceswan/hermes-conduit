//
//  KanbanBoardService.swift
//  Conduit
//

import Foundation

/// A small adapter protocol keeps the Kanban loaders deterministic in tests
/// without exposing WebKit or dashboard cookies to the view layer.
@MainActor
protocol KanbanRequesting: AnyObject {
    func requestJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        timeoutMilliseconds: Int,
        maxResponseBytes: Int
    ) async throws -> [String: Any]
}

@MainActor
extension DashboardTicketBridge: KanbanRequesting {}

/// Path construction for the Kanban dashboard plugin. Kanban endpoints are
/// server-wide: they never take `?profile=`. Board selection stays client-side
/// via `?board=` — the server-global `/boards/{slug}/switch` is never called.
enum KanbanPath {
    static let prefix = "/api/plugins/kanban"

    static func board(slug: String?, includeArchived: Bool) -> String {
        var path = "\(prefix)/board"
        var query: [String] = []
        if let slug, !slug.isEmpty, let encoded = DashboardPath.encodedQueryComponent(slug) {
            query.append("board=\(encoded)")
        }
        if includeArchived {
            query.append("include_archived=true")
        }
        if !query.isEmpty {
            path += "?" + query.joined(separator: "&")
        }
        return path
    }

    static func boards() -> String {
        "\(prefix)/boards"
    }

    static func task(id: String, board: String?) -> String? {
        guard let safeID = sanitizeTaskID(id) else { return nil }
        var path = "\(prefix)/tasks/\(safeID)"
        if let board, !board.isEmpty, let encoded = DashboardPath.encodedQueryComponent(board) {
            path += "?board=\(encoded)"
        }
        return path
    }

    static func taskLog(id: String, board: String?, tailBytes: Int) -> String? {
        guard let safeID = sanitizeTaskID(id) else { return nil }
        var path = "\(prefix)/tasks/\(safeID)/log?tail=\(max(1, tailBytes))"
        if let board, !board.isEmpty, let encoded = DashboardPath.encodedQueryComponent(board) {
            path += "&board=\(encoded)"
        }
        return path
    }

    static func tasks(board: String?) -> String {
        appendingBoard(to: "\(prefix)/tasks", board: board)
    }

    static func taskComments(id: String, board: String?) -> String? {
        guard let safeID = sanitizeTaskID(id) else { return nil }
        return appendingBoard(to: "\(prefix)/tasks/\(safeID)/comments", board: board)
    }

    static func taskReclaim(id: String, board: String?) -> String? {
        guard let safeID = sanitizeTaskID(id) else { return nil }
        return appendingBoard(to: "\(prefix)/tasks/\(safeID)/reclaim", board: board)
    }

    static func assignees(board: String?) -> String {
        appendingBoard(to: "\(prefix)/assignees", board: board)
    }

    static func dispatch(board: String?, max maxSpawns: Int = 8) -> String {
        appendingBoard(to: "\(prefix)/dispatch?max=\(maxSpawns)", board: board)
    }

    private static func appendingBoard(to path: String, board: String?) -> String {
        guard let board, !board.isEmpty, let encoded = DashboardPath.encodedQueryComponent(board) else {
            return path
        }
        return "\(path)\(path.contains("?") ? "&" : "?")board=\(encoded)"
    }

    /// Task ids are server-generated `t_<hex>`; anything outside a strict
    /// identifier alphabet is rejected rather than interpolated into a path.
    static func sanitizeTaskID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ taskIDAllowedCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static let taskIDAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-_")
        return characters
    }()
}

enum KanbanAvailability: Equatable {
    case unknown
    case checking
    case available
    /// The kanban plugin is disabled or absent on this server.
    case unavailable
    case signInRequired
    /// Transient failure — retryable, does not mean the plugin is missing.
    case failed(String)
}

/// A write-action failure with identity, so the UI can re-animate repeats of
/// the same message and auto-clear stale ones.
struct KanbanActionError: Equatable, Identifiable {
    let id: UUID
    let message: String
}

@MainActor
final class KanbanBoardService: ObservableObject {
    @Published private(set) var availability: KanbanAvailability = .unknown
    @Published private(set) var snapshot: KanbanBoardSnapshot?
    @Published private(set) var boards: [KanbanBoardSummary] = []
    @Published private(set) var serverCurrentBoard: String?
    @Published private(set) var selectedBoardSlug: String?
    @Published private(set) var includeArchived = false
    @Published private(set) var isLoading = false
    @Published private(set) var mutatingTaskID: String?
    @Published private(set) var lastActionError: KanbanActionError?
    @Published private(set) var lastActionNotice: String?
    @Published private(set) var assigneeOptions: [String] = []
    @Published private(set) var streamConnected = false

    /// Internal (not private) so tests can await the debounced nudge.
    private(set) var dispatchNudgeTask: Task<Void, Never>?
    /// Internal so tests can await the coalesced event-triggered reload.
    private(set) var eventReloadTask: Task<Void, Never>?

    private let requester: KanbanRequesting
    private let selectionStore: KanbanBoardSelectionStore
    private let serverKey: String
    private let dispatchNudgeDelay: Duration
    private let actionErrorClearDelay: Duration
    private let ticketProvider: KanbanTicketProviding?
    private let streamBaseURL: String?
    private let eventReloadDebounce: Duration
    private var eventStream: KanbanEventStream?
    private var requestGeneration = 0
    private var feedbackClearTask: Task<Void, Never>?

    /// Sentinel `mutatingTaskID` for create, which has no task id yet.
    static let createMutationID = "+create"

    private static let boardMaxResponseBytes = 8 * 1024 * 1024
    private static let logMaxResponseBytes = 1024 * 1024

    init(
        requester: KanbanRequesting,
        selectionStore: KanbanBoardSelectionStore,
        serverKey: String,
        dispatchNudgeDelay: Duration = .milliseconds(400),
        actionErrorClearDelay: Duration = .seconds(6),
        ticketProvider: KanbanTicketProviding? = nil,
        streamBaseURL: String? = nil,
        eventReloadDebounce: Duration = .milliseconds(300)
    ) {
        self.requester = requester
        self.selectionStore = selectionStore
        self.serverKey = serverKey
        self.dispatchNudgeDelay = dispatchNudgeDelay
        self.actionErrorClearDelay = actionErrorClearDelay
        self.ticketProvider = ticketProvider
        self.streamBaseURL = streamBaseURL
        self.eventReloadDebounce = eventReloadDebounce
        selectedBoardSlug = selectionStore.selectedBoard(forServer: serverKey)
    }

    convenience init(bridge: DashboardTicketBridge) {
        self.init(
            requester: bridge,
            selectionStore: KanbanBoardSelectionStore(),
            serverKey: bridge.baseURL,
            ticketProvider: bridge,
            streamBaseURL: bridge.baseURL
        )
    }

    /// Fetches the board. Doubles as the capability probe: the plugin's
    /// `GET /board` auto-creates its database, so a healthy install never
    /// errors here — a "not found" failure means the plugin is disabled.
    /// Quiet refreshes keep the previous snapshot on failure and skip
    /// publishing when the event cursor has not moved.
    func loadBoard(quiet: Bool = false) async {
        await loadBoard(quiet: quiet, ignoringMutationGuard: false)
    }

    private func loadBoard(quiet: Bool, ignoringMutationGuard: Bool) async {
        // Quiet polls must not race an in-flight mutation; the mutation's own
        // post-write reload passes ignoringMutationGuard to get through.
        if quiet, !ignoringMutationGuard, mutatingTaskID != nil { return }
        requestGeneration += 1
        let generation = requestGeneration
        let slug = selectedBoardSlug
        let archived = includeArchived

        if !quiet {
            isLoading = true
            if snapshot == nil { availability = .checking }
        }
        defer {
            if generation == requestGeneration { isLoading = false }
        }

        do {
            let result = try await requester.requestJSON(
                path: KanbanPath.board(slug: slug, includeArchived: archived),
                method: "GET",
                body: nil,
                timeoutMilliseconds: 12_000,
                maxResponseBytes: Self.boardMaxResponseBytes
            )
            guard generation == requestGeneration else { return }
            guard let board = KanbanNormalizer.normalizeBoard(AnyCodable.from(result)) else {
                availability = .failed("The board response could not be read.")
                return
            }
            if quiet,
               let previous = snapshot,
               let cursor = board.latestEventID,
               cursor == previous.latestEventID {
                availability = .available
                return
            }
            snapshot = board
            availability = .available
        } catch {
            guard generation == requestGeneration else { return }
            let classified = Self.classify(error)
            if classified == .unavailable, slug != nil {
                // A stale persisted board slug also 404s. Distinguish it from
                // a disabled plugin by retrying the server-default board once.
                selectionStore.setSelectedBoard(nil, forServer: serverKey)
                selectedBoardSlug = nil
                await loadBoard(quiet: quiet, ignoringMutationGuard: ignoringMutationGuard)
                return
            }
            if quiet, snapshot != nil, classified != .signInRequired, classified != .unavailable {
                return
            }
            availability = classified
            if classified == .unavailable { snapshot = nil }
        }
    }

    func loadBoards() async {
        do {
            let result = try await requester.requestJSON(
                path: KanbanPath.boards(),
                method: "GET",
                body: nil,
                timeoutMilliseconds: 12_000,
                maxResponseBytes: Self.boardMaxResponseBytes
            )
            let catalog = KanbanNormalizer.normalizeBoards(AnyCodable.from(result))
            boards = catalog.boards
            serverCurrentBoard = catalog.current
        } catch {
            // The picker degrades to the current board; board loading surfaces errors.
        }
    }

    func selectBoard(_ slug: String?) async {
        let normalized = (slug?.isEmpty == true) ? nil : slug
        guard normalized != selectedBoardSlug else { return }
        selectionStore.setSelectedBoard(normalized, forServer: serverKey)
        selectedBoardSlug = normalized
        snapshot = nil
        await loadBoard()
        // The events stream pins its board at the handshake; restart after the
        // load so it seeds from the fresh cursor and the settled slug (the
        // stale-slug fallback inside loadBoard may have cleared it).
        restartEventStreamingIfActive()
    }

    // `include_archived` is a fetch parameter, not a stream parameter — the
    // events feed is board-scoped invalidation either way, so no restart.
    func setIncludeArchived(_ include: Bool) async {
        guard include != includeArchived else { return }
        includeArchived = include
        await loadBoard()
    }

    // MARK: Event streaming

    /// Starts the live events stream. Idempotent and safe to call every poll
    /// tick: it is a no-op while a stream exists, before the first successful
    /// board load, or when the service was built without a ticket provider.
    func startEventStreaming() {
        guard eventStream == nil,
              availability == .available,
              let ticketProvider,
              let streamBaseURL else { return }
        let stream = KanbanEventStream(
            baseURL: streamBaseURL,
            boardSlug: selectedBoardSlug,
            since: snapshot?.latestEventID,
            ticketProvider: ticketProvider,
            onBatch: { [weak self] frame in self?.handleEventBatch(frame) },
            onStateChange: { [weak self] state in self?.handleStreamState(state) }
        )
        eventStream = stream
        stream.start()
    }

    func stopEventStreaming() {
        eventReloadTask?.cancel()
        eventReloadTask = nil
        eventStream?.stop()
        eventStream = nil
        streamConnected = false
    }

    private func restartEventStreamingIfActive() {
        guard eventStream != nil else { return }
        stopEventStreaming()
        startEventStreaming()
    }

    /// Events are invalidation signals: coalesce rapid batches into one quiet
    /// refetch. The reload passes through the standard mutation guard, so a
    /// batch arriving mid-write is dropped (the write's own reload covers it).
    func handleEventBatch(_ frame: KanbanEventFrame) {
        eventReloadTask?.cancel()
        let delay = eventReloadDebounce
        eventReloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.loadBoard(quiet: true)
        }
    }

    private func handleStreamState(_ state: KanbanEventStreamState) {
        streamConnected = (state == .connected)
        if state == .stoppedAuthRequired {
            // mintTicket only fails this way after the bridge's own reload
            // retries; the poll would surface the same sign-in state within
            // 8 seconds — the stream just reports it sooner.
            stopEventStreaming()
            availability = .signInRequired
        }
    }

    func loadTaskDetail(_ id: String) async throws -> KanbanTaskDetail {
        guard let path = KanbanPath.task(id: id, board: selectedBoardSlug) else {
            throw DashboardTicketBridgeError.requestFailed("Invalid task identifier.")
        }
        let result = try await requester.requestJSON(
            path: path,
            method: "GET",
            body: nil,
            timeoutMilliseconds: 12_000,
            maxResponseBytes: Self.boardMaxResponseBytes
        )
        guard let detail = KanbanNormalizer.normalizeTaskDetail(AnyCodable.from(result)) else {
            throw DashboardTicketBridgeError.requestFailed("The task response could not be read.")
        }
        return detail
    }

    func loadTaskLog(_ id: String, tailBytes: Int = 65_536) async throws -> KanbanTaskLog {
        guard let path = KanbanPath.taskLog(id: id, board: selectedBoardSlug, tailBytes: tailBytes) else {
            throw DashboardTicketBridgeError.requestFailed("Invalid task identifier.")
        }
        let result = try await requester.requestJSON(
            path: path,
            method: "GET",
            body: nil,
            timeoutMilliseconds: 12_000,
            maxResponseBytes: Self.logMaxResponseBytes
        )
        guard let log = KanbanNormalizer.normalizeLog(AnyCodable.from(result)) else {
            throw DashboardTicketBridgeError.requestFailed("The log response could not be read.")
        }
        return log
    }

    // MARK: Write actions

    /// Moves a task to a new status. `running` is dispatcher-only and guarded
    /// here defensively (the server would 400 it anyway). A `blocked` move
    /// carries the optional reason; an empty reason omits the key entirely.
    @discardableResult
    func moveTask(_ id: String, to status: String, blockReason: String? = nil) async -> Bool {
        guard status != KanbanStatus.running.rawValue else { return false }
        guard let path = KanbanPath.task(id: id, board: selectedBoardSlug) else { return false }
        var body: [String: Any] = ["status": status]
        if status == KanbanStatus.blocked.rawValue,
           let reason = blockReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            body["block_reason"] = reason
        }
        return await performMutation(taskID: id, path: path, method: "PATCH", body: body) != nil
    }

    /// Releases a running task's claim: stops the worker and returns the task
    /// to Ready with the run closed as reclaimed.
    @discardableResult
    func reclaimTask(_ id: String) async -> Bool {
        guard let path = KanbanPath.taskReclaim(id: id, board: selectedBoardSlug) else { return false }
        return await performMutation(taskID: id, path: path, method: "POST", body: [:]) != nil
    }

    /// Sets or clears the assignee. `nil` unassigns (the server's sentinel is
    /// an empty string). Callers must not offer this for running tasks.
    @discardableResult
    func reassignTask(_ id: String, to assignee: String?) async -> Bool {
        guard let path = KanbanPath.task(id: id, board: selectedBoardSlug) else { return false }
        return await performMutation(taskID: id, path: path, method: "PATCH", body: ["assignee": assignee ?? ""]) != nil
    }

    @discardableResult
    func setPriority(_ id: String, to priority: Int) async -> Bool {
        guard let path = KanbanPath.task(id: id, board: selectedBoardSlug) else { return false }
        return await performMutation(taskID: id, path: path, method: "PATCH", body: ["priority": priority]) != nil
    }

    @discardableResult
    func deleteTask(_ id: String) async -> Bool {
        guard let path = KanbanPath.task(id: id, board: selectedBoardSlug) else { return false }
        return await performMutation(taskID: id, path: path, method: "DELETE", body: nil) != nil
    }

    /// Posts a comment as author "conduit" so mobile comments stay
    /// identifiable in the agent-readable thread (the server default author
    /// is "dashboard").
    @discardableResult
    func addComment(_ id: String, body commentBody: String) async -> Bool {
        let trimmed = commentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let path = KanbanPath.taskComments(id: id, board: selectedBoardSlug) else { return false }
        return await performMutation(taskID: id, path: path, method: "POST", body: ["body": trimmed, "author": "conduit"]) != nil
    }

    /// Creates a task. Assigned tasks with no pending parents land in Ready;
    /// unassigned in To Do; `triage: true` in Triage. A server `warning`
    /// (e.g. "no dispatcher running") is surfaced as a non-fatal notice.
    func createTask(title: String, body taskBody: String?, assignee: String?, priority: Int, triage: Bool) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        var body: [String: Any] = ["title": trimmedTitle, "priority": priority, "triage": triage]
        if let taskBody = taskBody?.trimmingCharacters(in: .whitespacesAndNewlines), !taskBody.isEmpty {
            body["body"] = taskBody
        }
        if let assignee, !assignee.isEmpty {
            body["assignee"] = assignee
        }
        let result = await performMutation(
            taskID: Self.createMutationID,
            path: KanbanPath.tasks(board: selectedBoardSlug),
            method: "POST",
            body: body
        )
        guard let result else { return false }
        if let warning = result["warning"] as? String, !warning.isEmpty {
            publishActionNotice(warning)
        }
        return true
    }

    /// Populates the assignee menus. Silent failure: menus fall back to the
    /// board snapshot's assignees.
    func loadAssignees() async {
        guard let result = try? await requester.requestJSON(
            path: KanbanPath.assignees(board: selectedBoardSlug),
            method: "GET",
            body: nil,
            timeoutMilliseconds: 12_000,
            maxResponseBytes: Self.logMaxResponseBytes
        ) else { return }
        let payload = AnyCodable.from(result)
        let names = (payload.objectValue?["assignees"]?.arrayValue ?? [])
            .compactMap { $0.stringValue ?? $0.objectValue?["name"]?.stringValue }
            .filter { !$0.isEmpty }
        if !names.isEmpty { assigneeOptions = names }
    }

    // MARK: Mutation plumbing

    /// Single-flight mutation core: one write at a time, board-wide. On
    /// success it schedules the debounced dispatch nudge and reloads the
    /// board (bypassing the poll-suppression guard).
    private func performMutation(taskID: String, path: String, method: String, body: [String: Any]?) async -> [String: Any]? {
        guard mutatingTaskID == nil else { return nil }
        mutatingTaskID = taskID
        defer { mutatingTaskID = nil }
        do {
            let result = try await requester.requestJSON(
                path: path,
                method: method,
                body: body,
                timeoutMilliseconds: 12_000,
                maxResponseBytes: Self.boardMaxResponseBytes
            )
            scheduleDispatchNudge()
            await loadBoard(quiet: true, ignoringMutationGuard: true)
            return result
        } catch {
            setActionError(for: error)
            return nil
        }
    }

    /// Fire-and-forget dispatcher nudge, debounced like the desktop client
    /// (rapid consecutive writes collapse into one). Over-nudging is
    /// harmless, so failures are swallowed.
    private func scheduleDispatchNudge() {
        dispatchNudgeTask?.cancel()
        let delay = dispatchNudgeDelay
        dispatchNudgeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.requester.requestJSON(
                path: KanbanPath.dispatch(board: self.selectedBoardSlug),
                method: "POST",
                body: nil,
                timeoutMilliseconds: 12_000,
                maxResponseBytes: Self.logMaxResponseBytes
            )
        }
    }

    private func setActionError(for error: Error) {
        switch error {
        case DashboardTicketBridgeError.signInRequired:
            // Writes failing auth means reads will too; use the full-screen state.
            availability = .signInRequired
        case DashboardTicketBridgeError.notReady:
            publishActionError("The dashboard connection is still starting.")
        case DashboardTicketBridgeError.requestFailed(let message):
            // Server detail text (e.g. the 409 blocking-parents message)
            // reaches the user verbatim.
            publishActionError(message)
        default:
            publishActionError(error.localizedDescription)
        }
    }

    private func publishActionError(_ message: String) {
        lastActionError = KanbanActionError(id: UUID(), message: message)
        lastActionNotice = nil
        scheduleFeedbackClear()
    }

    private func publishActionNotice(_ message: String) {
        lastActionNotice = message
        scheduleFeedbackClear()
    }

    private func scheduleFeedbackClear() {
        feedbackClearTask?.cancel()
        let delay = actionErrorClearDelay
        feedbackClearTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.lastActionError = nil
            self.lastActionNotice = nil
        }
    }

    /// The bridge surfaces no HTTP status codes, so plugin absence is detected
    /// from the error text: a disabled plugin's 404 carries the FastAPI body
    /// `{"detail": "Plugin not found"}`, and a body-less 404 falls back to
    /// "Dashboard request failed (404).".
    static func classify(_ error: Error) -> KanbanAvailability {
        switch error {
        case DashboardTicketBridgeError.signInRequired:
            return .signInRequired
        case DashboardTicketBridgeError.notReady:
            return .failed("The dashboard connection is still starting.")
        case DashboardTicketBridgeError.requestFailed(let message):
            let lowered = message.lowercased()
            if lowered.contains("plugin not found")
                || lowered.contains("not found")
                || lowered.contains("(404)") {
                return .unavailable
            }
            return .failed(message)
        default:
            return .failed(error.localizedDescription)
        }
    }
}
