import Foundation

/// A session window's transcript (D21): pure, no AppKit, no AppState. Folds
/// the window's own StreamEvents into rows. After every turn the controller
/// replaces it from the persisted transcript (`hydrate`), so any difference
/// from AppState's streaming reducer lasts one turn at most.
///
/// Rules:
/// - `messageStart`: turn running; a non-empty `streamingText` is flushed first as an assistant row.
/// - `messageDelta`: append to `streamingText`; turn running.
/// - `reasoningDelta`: ignored (the settled transcript shows reasoning).
/// - `messageComplete`: one assistant row with `content ?? streamingText` and `reasoning`, id
///   `messageId ?? "local-assistant-<n>"`; `streamingText` cleared; returns `.turnEnded` (the controller
///   debounces, because a tool turn continues with another `messageStart`).
/// - `messageInterrupted`: flush, turn idle, `.turnEnded`.
/// - `messageError`: flush, one `.system` row with the sanitized text, turn idle, `.turnEnded`.
/// - `sessionBusy(busy)`: true sets running; false sets needsInput when a card is pending, else idle,
///   and returns `.turnEnded`.
/// - `toolStart`: flush, append a `.tool` row with `ToolActivity(status: .running)`, id `"tool-<toolID or n>"`.
/// - `toolComplete`: the newest running tool row with the same `toolID` (or same name when `toolID` is nil)
///   gets `output` and `.complete`.
/// - `approval` / `clarify` / `inputPrompt`: flush, append a card row (role `.approval` / `.clarify` /
///   `.inputPrompt`), turn needsInput. Id `"approval-<requestId>"`, `"clarify-<requestId>"`, `"input-<requestId>"`.
/// - `approvalWithdrawn(requestId)`: that approval's status `.expired`, `error = reason`.
/// - `clarifyExpire(requestId)`: that clarify's `isExpired = true`.
/// - `inputPromptExpire(requestId)`: that prompt's status `.expired`.
/// - `sessionTitle(runtime, stored, title)`: when either id is owned, adopt both and set `title`.
/// - Everything else, and every event whose id is not owned: no change.
/// - `hydrate`: adopt `result.sessionId` (it becomes `runtimeID`) and `result.storedSessionId`;
///   `messages = result.messages` plus a pending-card row (when not already in the rows) for
///   `snapshot.pendingClarify`, each of `snapshot.additionalPendingClarifies`, each of
///   `snapshot.pendingInputPrompts`, and the approval parsed by
///   `MessageNormalizer.approvalActivity(from: snapshot.pendingApprovalPayload, sessionId:)`;
///   `streamingText = ""`; turn = running when `snapshot.running == true`, else needsInput when a
///   card is pending, else idle.
struct MacSessionTranscript: Equatable {
    enum Turn: Equatable { case idle, running, needsInput }
    enum Effect: Equatable { case none, turnEnded }

    static let maxErrorGraphemes = 300

    private(set) var ids: Set<String>
    private(set) var runtimeID: String?
    private(set) var messages: [ChatMessage] = []
    private(set) var streamingText = ""
    private(set) var turn: Turn = .idle
    private(set) var title: String?
    private var localCounter = 0

    init(sessionID: String) { ids = [sessionID] }

    func owns(_ id: String) -> Bool { ids.contains(id) }

    func isRelevant(_ event: StreamEvent) -> Bool {
        if case .sessionTitle(let runtime, let stored, _) = event { return owns(runtime) || owns(stored) }
        guard let id = Self.sessionID(of: event) else { return false }
        return owns(id)
    }

    mutating func adopt(_ newIDs: [String]) {
        for id in newIDs where !id.isEmpty { ids.insert(id) }
    }

    mutating func hydrate(_ result: SessionResumeResult) {
        runtimeID = result.sessionId
        adopt([result.sessionId, result.storedSessionId].compactMap { $0 })
        var rows = result.messages
        let pending = [result.snapshot.pendingClarify].compactMap { $0 } + result.snapshot.additionalPendingClarifies
        let stamp = rows.last?.timestamp ?? ""
        for clarify in pending where !rows.contains(where: { $0.clarify?.requestId == clarify.requestId }) {
            rows.append(ChatMessage(id: "clarify-\(clarify.requestId)", role: .clarify, content: "",
                                    timestamp: stamp, clarify: clarify))
        }
        for prompt in result.snapshot.pendingInputPrompts where !rows.contains(where: { $0.inputPrompt?.requestId == prompt.requestId }) {
            rows.append(ChatMessage(id: "input-\(prompt.requestId)", role: .inputPrompt, content: prompt.prompt,
                                    timestamp: stamp, inputPrompt: prompt))
        }
        if let payload = result.snapshot.pendingApprovalPayload,
           let approval = MessageNormalizer.approvalActivity(from: payload, sessionId: result.sessionId),
           !rows.contains(where: { $0.approval != nil && $0.approval?.requestId == approval.requestId }) {
            rows.append(ChatMessage(id: "approval-\(approval.requestId ?? "pending")", role: .approval,
                                    content: approval.description, timestamp: stamp, approval: approval))
        }
        messages = rows
        streamingText = ""
        if result.snapshot.running == true { turn = .running }
        else { turn = hasPendingCard ? .needsInput : .idle }
    }

    mutating func userSent(_ text: String, timestamp: String) {
        messages.append(ChatMessage(id: nextLocalID("user"), role: .user, content: text, timestamp: timestamp))
        turn = .running
    }

    mutating func setTurn(_ newTurn: Turn) { turn = newTurn }

    mutating func updateMessage(id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    @discardableResult
    mutating func apply(_ event: StreamEvent, timestamp: String) -> Effect {
        guard isRelevant(event) else { return .none }
        switch event {
        case .sessionTitle(let runtime, let stored, let newTitle):
            adopt([runtime, stored])
            title = newTitle
        case .messageStart:
            flush(timestamp)
            turn = .running
        case .messageDelta(_, let text):
            streamingText += text
            turn = .running
        case .messageComplete(_, let messageID, let content, let reasoning):
            let text = content ?? streamingText
            streamingText = ""
            let row = ChatMessage(id: messageID ?? nextLocalID("assistant"), role: .assistant,
                                  content: text, timestamp: timestamp, reasoning: reasoning)
            if let index = messages.firstIndex(where: { $0.id == row.id }) {
                messages[index] = row
            } else {
                messages.append(row)
            }
            return .turnEnded
        case .messageInterrupted:
            flush(timestamp)
            turn = .idle
            return .turnEnded
        case .messageError(_, let message):
            flush(timestamp)
            messages.append(ChatMessage(id: nextLocalID("error"), role: .system,
                                        content: MacUntrustedText.sanitize(message, maxGraphemes: Self.maxErrorGraphemes),
                                        timestamp: timestamp))
            turn = .idle
            return .turnEnded
        case .sessionBusy(_, let busy):
            if busy { turn = .running; return .none }
            turn = hasPendingCard ? .needsInput : .idle
            return .turnEnded
        case .toolStart(_, let name, let input, let toolID):
            flush(timestamp)
            let row = ChatMessage(id: "tool-\(toolID ?? nextLocalID("t"))", role: .tool, content: "", timestamp: timestamp,
                                  tool: ToolActivity(id: toolID, name: name, input: input, output: nil, status: .running))
            if let index = messages.firstIndex(where: { $0.id == row.id }) {
                if messages[index].tool?.status == .running { messages[index] = row }
            } else {
                messages.append(row)
            }
        case .toolComplete(_, let name, let output, let toolID):
            let index = messages.lastIndex { row in
                guard let tool = row.tool, tool.status == .running else { return false }
                return toolID != nil ? tool.id == toolID : tool.name == name
            }
            if let index {
                messages[index].tool?.output = output
                messages[index].tool?.status = .complete
            }
        case .approval(_, let activity):
            flush(timestamp)
            upsertCard(ChatMessage(id: "approval-\(activity.requestId ?? nextLocalID("a"))", role: .approval,
                                   content: activity.description, timestamp: timestamp, approval: activity))
        case .clarify(_, let activity):
            flush(timestamp)
            upsertCard(ChatMessage(id: "clarify-\(activity.requestId)", role: .clarify, content: "",
                                   timestamp: timestamp, clarify: activity))
        case .inputPrompt(_, let activity):
            flush(timestamp)
            upsertCard(ChatMessage(id: "input-\(activity.requestId)", role: .inputPrompt, content: activity.prompt,
                                   timestamp: timestamp, inputPrompt: activity))
        case .approvalWithdrawn(_, let requestID, let reason):
            if let index = messages.lastIndex(where: { $0.approval?.requestId == requestID }) {
                messages[index].approval?.status = .expired
                messages[index].approval?.error = reason
            }
            settleTurnAfterExpiry()
        case .clarifyExpire(_, let requestID, _):
            if let index = messages.lastIndex(where: { $0.clarify?.requestId == requestID }) {
                messages[index].clarify?.isExpired = true
            }
            settleTurnAfterExpiry()
        case .inputPromptExpire(_, let requestID, _):
            if let index = messages.lastIndex(where: { $0.inputPrompt?.requestId == requestID }) {
                messages[index].inputPrompt?.status = .expired
            }
            settleTurnAfterExpiry()
        default:
            break
        }
        return .none
    }

    // MARK: Private

    var hasPendingCard: Bool { messages.contains { Self.isPending($0) } }

    private static func isPending(_ row: ChatMessage) -> Bool {
        if row.approval?.status == .pending { return true }
        if let clarify = row.clarify, !clarify.isExpired, clarify.questions.contains(where: { $0.status == .pending }) { return true }
        if row.inputPrompt?.status == .pending { return true }
        return false
    }

    /// Gateway replays (session.resume) re-send open requests as live events:
    /// an existing row is refreshed only while still pending, so a locally
    /// submitting/answered/expired card is never reset.
    private mutating func upsertCard(_ row: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == row.id }) {
            guard Self.isPending(messages[index]) else { return }
            messages[index] = row
        } else {
            messages.append(row)
        }
        if Self.isPending(row) { turn = .needsInput }
    }

    private mutating func settleTurnAfterExpiry() {
        if turn == .needsInput, !hasPendingCard { turn = .idle }
    }

    private mutating func flush(_ timestamp: String) {
        guard !streamingText.isEmpty else { return }
        messages.append(ChatMessage(id: nextLocalID("assistant"), role: .assistant, content: streamingText, timestamp: timestamp))
        streamingText = ""
    }

    private mutating func nextLocalID(_ kind: String) -> String {
        localCounter += 1
        return "local-\(kind)-\(localCounter)"
    }

    private static func sessionID(of event: StreamEvent) -> String? {
        switch event {
        case .messageStart(let id), .messageInterrupted(let id): return id
        case .messageDelta(let id, _), .reasoningDelta(let id, _), .messageError(let id, _), .sessionBusy(let id, _): return id
        case .messageComplete(let id, _, _, _): return id
        case .toolStart(let id, _, _, _), .toolComplete(let id, _, _, _): return id
        case .approval(let id, _), .clarify(let id, _), .inputPrompt(let id, _): return id
        case .approvalWithdrawn(let id, _, _), .clarifyExpire(let id, _, _), .inputPromptExpire(let id, _, _): return id
        default: return nil
        }
    }
}
