import Foundation

/// Quick Ask's panel state (D15): pure, no AppKit, no AppState. It owns the
/// session ids Quick Ask created and turns StreamEvents for them into state.
///
/// - submit() is accepted from idle, done and failed only, for a non-blank prompt.
/// - Events count only for owned ids and only in sending, streaming or done
///   (done accepts a continuation segment of a tool turn).
/// - messageComplete replaces only the current segment, so earlier segments survive.
/// - sessionBusy(false) ends a streaming turn, never a sending one.
/// - Every accepted event and every submit/open/close refreshes lastActivity.
struct MacQuickAskModel: Equatable {
    static let restoreWindow: TimeInterval = 120
    /// Gateway-controlled strings shown in the panel chrome (tool name, error text)
    /// pass through `MacUntrustedText` at the model boundary; the reply body does not.
    static let maxStatusGraphemes = 60
    static let maxMessageGraphemes = 300

    static func chrome(_ raw: String, max: Int) -> String {
        MacUntrustedText.sanitize(raw, maxGraphemes: max)
    }

    enum FailureKind: Equatable { case generic, sessionLimit }

    enum State: Equatable {
        case idle
        case creating
        case sending
        case streaming(text: String, status: String?)
        case done(text: String)
        case needsInput(text: String)
        case failed(message: String, partial: String, kind: FailureKind)
    }

    private(set) var state: State = .idle
    private(set) var runtimeID: String?
    private(set) var storedID: String?
    private(set) var lastPrompt = ""
    private(set) var lastActivity: Date?

    init() {}

    private var turnText = ""
    private var segmentStart = 0
    private var separatorPending = false

    var text: String {
        switch state {
        case .streaming(let text, _), .done(let text), .needsInput(let text): return text
        case .failed(_, let partial, _): return partial
        case .idle, .creating, .sending: return ""
        }
    }

    var isTurnRunning: Bool {
        switch state {
        case .creating, .sending, .streaming: return true
        default: return false
        }
    }

    var canSubmit: Bool {
        switch state {
        case .idle, .done, .failed: return true
        default: return false
        }
    }

    var hasExchange: Bool { state != .idle }
    var promoteID: String? { storedID ?? runtimeID }

    func owns(_ id: String) -> Bool { id == runtimeID || id == storedID }

    mutating func submit(_ text: String, now: Date) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !prompt.isEmpty else { return false }
        lastPrompt = prompt
        turnText = ""
        segmentStart = 0
        separatorPending = false
        state = runtimeID == nil ? .creating : .sending
        lastActivity = now
        return true
    }

    mutating func sessionCreated(runtimeID: String, storedID: String?) {
        self.runtimeID = runtimeID
        self.storedID = storedID
        if state == .creating { state = .sending }
    }

    /// sendPrompt returned. Events may have beaten it: only move on from sending.
    mutating func promptStarted() {
        if state == .sending { state = .streaming(text: turnText, status: nil) }
    }

    mutating func fail(_ message: String, kind: FailureKind, now: Date) {
        state = .failed(message: Self.chrome(message, max: Self.maxMessageGraphemes), partial: turnText, kind: kind)
        lastActivity = now
    }

    /// Would `apply` change anything for this event? The controller asks first so
    /// a foreign or ignored event (every delta of the main chat) never touches the
    /// published model.
    func isRelevant(_ event: StreamEvent) -> Bool {
        if case .sessionTitle(let runtime, let stored, _) = event { return owns(runtime) || owns(stored) }
        return accepts(event)
    }

    mutating func apply(_ event: StreamEvent, now: Date) {
        if case .sessionTitle(let runtime, let stored, _) = event {
            guard owns(runtime) || owns(stored) else { return }
            if storedID == nil { storedID = stored }
            if runtimeID == nil { runtimeID = runtime }
            lastActivity = now
            return
        }
        guard accepts(event) else { return }
        lastActivity = now
        switch event {
        case .messageStart:
            separatorPending = !turnText.isEmpty
            segmentStart = turnText.count + (separatorPending ? 2 : 0)
            setStreaming(status: nil)
        case .messageDelta(_, let text):
            if separatorPending { turnText += "\n\n"; separatorPending = false }
            turnText += text
            setStreaming(status: currentStatus)
        case .toolStart(_, let toolName, _, _):
            let status = Self.chrome(toolName, max: Self.maxStatusGraphemes)
            setStreaming(status: status.isEmpty ? nil : status)
        case .toolComplete:
            setStreaming(status: nil)
        case .messageComplete(_, _, let content, _, _):
            if let content {
                if separatorPending { turnText += "\n\n"; separatorPending = false }
                turnText = String(turnText.prefix(segmentStart)) + content
            }
            state = .done(text: turnText)
        case .messageInterrupted:
            state = .done(text: turnText)
        case .messageError(_, let message):
            state = .failed(message: Self.chrome(message, max: Self.maxMessageGraphemes), partial: turnText, kind: .generic)
        case .approval, .clarify, .inputPrompt:
            state = .needsInput(text: turnText)
        case .sessionBusy(_, let busy):
            if !busy, case .streaming = state { state = .done(text: turnText) }
        default:
            break
        }
    }

    /// 120 s counts from the last activity (a hidden turn that kept streaming
    /// counts), not from the hide.
    mutating func panelOpened(now: Date) {
        guard hasExchange, let lastActivity, now.timeIntervalSince(lastActivity) <= Self.restoreWindow else {
            reset()
            return
        }
        self.lastActivity = now
    }

    mutating func panelClosed(now: Date) {
        if hasExchange { lastActivity = max(lastActivity ?? now, now) }
    }

    /// Cmd-N, or the window ran out.
    mutating func reset() { self = MacQuickAskModel() }

    /// After promotion the main chat owns the session.
    mutating func detach() { reset() }

    private var currentStatus: String? {
        if case .streaming(_, let status) = state { return status }
        return nil
    }

    private mutating func setStreaming(status: String?) {
        state = .streaming(text: turnText, status: status)
    }

    private func accepts(_ event: StreamEvent) -> Bool {
        guard let id = Self.sessionID(of: event), owns(id) else { return false }
        switch state {
        case .sending, .streaming, .done: return true
        case .idle, .creating, .needsInput, .failed: return false
        }
    }

    private static func sessionID(of event: StreamEvent) -> String? {
        switch event {
        case .messageStart(let id), .messageInterrupted(let id): return id
        case .messageDelta(let id, _), .messageError(let id, _), .sessionBusy(let id, _): return id
        case .messageComplete(let id, _, _, _, _): return id
        case .toolStart(let id, _, _, _), .toolComplete(let id, _, _, _): return id
        case .approval(let id, _), .clarify(let id, _), .inputPrompt(let id, _): return id
        default: return nil
        }
    }
}

#if DEBUG
extension MacQuickAskModel {
    // test seam: a model already holding a session, in the given state
    init(testState: State) {
        self.init()
        runtimeID = "rt-test"
        storedID = "st-test"
        lastPrompt = "test prompt"
        state = testState
    }
}
#endif
