import Combine
import Foundation

struct MacSessionWindowScope: Equatable {
    var dashboardID: UUID?
    var profile: String
    var connected: Bool
}

/// Everything the window does on the wire, injected (D21; the Quick Ask pattern, D15).
struct MacSessionWindowEnvironment {
    var scope: () -> MacSessionWindowScope = { MacSessionWindowScope(dashboardID: nil, profile: "default", connected: false) }
    var clientID: () -> ObjectIdentifier? = { nil }
    var resume: (String) async throws -> SessionResumeResult = { _ in throw HermesError.notConnected }
    var sendPrompt: (String, String) async throws -> PromptSubmissionOutcome = { _, _ in throw HermesError.notConnected }
    var cancel: (String) async throws -> Void = { _ in }
    var activeSessions: () async throws -> [LiveSessionStatus] = { [] }
    var respondToApproval: (String, String?, String) async throws -> Bool = { _, _, _ in throw HermesError.notConnected }
    var respondToClarification: (String, String, String?) async throws -> HermesClient.ClarifyResponseOutcome =
        { _, _, _ in throw HermesError.notConnected }
    var respondToInputPrompt: (String, String) async throws -> Void = { _, _ in throw HermesError.notConnected }
    var catalogRow: (String) -> SessionSummary? = { _ in nil }
    var now: () -> Date = { Date() }
}

/// One session window's state and wire traffic (D21). Holds no AppState state:
/// the shared HermesClient is reached only through `environment`.
@MainActor
final class MacSessionWindowController: ObservableObject {
    enum Phase: Equatable { case loading, ready, disconnected, wrongScope(String), deleted, failed(String) }

    static let maxTitleGraphemes = 80

    @Published private(set) var transcript: MacSessionTranscript
    @Published private(set) var phase: Phase = .loading
    @Published var draft = ""
    @Published private(set) var lastError: String?

    let token: MacSessionWindowToken
    private let environment: MacSessionWindowEnvironment
    private let hub: MacStreamEventHub
    private let settleDelay: Duration
    private var hubToken: MacStreamEventHub.Token?
    private var resumeInFlight = false
    private var buffered: [StreamEvent] = []
    private var bufferOverflowed = false
    /// Cap on events held during one resume; past it the settle resume re-reads what was dropped.
    static let maxBufferedEvents = 500
    private var settleTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var lastClientID: ObjectIdentifier?
    /// Set by a client change; the next resume then asks the live list (stale idle).
    private var probeOnNextResume = false
    /// Bumped by every applied event and every send; the live probe drops its answer when it moved.
    private var revision = 0
    private var bindings: Set<AnyCancellable> = []
    private static let timestampFormatter = ISO8601DateFormatter()

    init(token: MacSessionWindowToken, environment: MacSessionWindowEnvironment,
         hub: MacStreamEventHub? = nil, settleDelay: Duration = .milliseconds(600)) {
        self.token = token
        self.environment = environment
        self.hub = hub ?? .shared
        self.settleDelay = settleDelay
        self.transcript = MacSessionTranscript(sessionID: token.sessionID)
    }

    var title: String {
        let raw = transcript.title ?? environment.catalogRow(token.sessionID)?.title ?? AppLocalization.string("Conversation")
        return MacUntrustedText.sanitize(raw, maxGraphemes: Self.maxTitleGraphemes)
    }

    var canSend: Bool {
        phase == .ready && !resumeInFlight && transcript.turn == .idle && scopeMatches
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scopeMatches: Bool {
        let scope = environment.scope()
        return scope.connected && scope.profile == token.profile && scope.dashboardID == token.dashboardID
    }

    // MARK: Lifecycle

    func start() {
        if hubToken == nil {
            hubToken = hub.subscribe { [weak self] event in self?.handle(event) }
        }
        lastClientID = environment.clientID()
        catalogChanged()
        refreshPhaseForScope()
    }

    func stop() {
        if let hubToken { hub.unsubscribe(hubToken) }
        hubToken = nil
        settleTask?.cancel()
        resumeTask?.cancel()
        resumeInFlight = false
        buffered = []
        bufferOverflowed = false
        bindings.removeAll()
    }

    // MARK: Events

    func handle(_ event: StreamEvent) {
        if resumeInFlight, transcript.runtimeID == nil {
            // The first resume has not told us the runtime id yet, so relevance is not decidable:
            // hold every event (replay filters through `isRelevant`), within the cap.
            buffer(event)
            return
        }
        guard transcript.isRelevant(event) else { return }
        if resumeInFlight { buffer(event); return }
        apply(event)
    }

    private func buffer(_ event: StreamEvent) {
        if buffered.count < Self.maxBufferedEvents { buffered.append(event) } else { bufferOverflowed = true }
    }

    private func apply(_ event: StreamEvent) {
        revision += 1
        switch event {
        case .messageStart, .messageDelta, .toolStart: settleTask?.cancel()
        default: break
        }
        if transcript.apply(event, timestamp: timestamp()) == .turnEnded { scheduleSettle() }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        let delay = settleDelay
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    // MARK: Resume

    private func resume() {
        guard scopeMatches, phase != .deleted else { return }
        let probeBusy = probeOnNextResume
        resumeTask?.cancel()
        resumeInFlight = true
        let id = transcript.runtimeID ?? token.sessionID
        resumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await environment.resume(id)
                guard !Task.isCancelled else { return }
                transcript.hydrate(result)
                let replay = buffered
                let overflowed = bufferOverflowed
                buffered = []
                bufferOverflowed = false
                resumeInFlight = false
                lastError = nil
                replay.filter { transcript.isRelevant($0) }.forEach(apply)
                phase = phaseForScope() ?? .ready
                // The flag stays set until the gateway answered (or the answer no longer matters).
                if probeBusy, await probeLiveStatus() { probeOnNextResume = false }
                if overflowed { scheduleSettle() }
            } catch {
                guard !Task.isCancelled else { return }
                resumeInFlight = false
                buffered = []
                bufferOverflowed = false
                let message = MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300)
                // A failed settle must not blank a window that already shows the turn.
                if phase == .ready { lastError = message } else { phase = .failed(message) }
            }
        }
    }

    /// After a reconnect the resume can report a turn that already ended; the
    /// gateway's live list is the authority (AppState.swift:827, stale idle).
    /// Returns true when the probe is finished (answered, or no longer needed because
    /// the turn is not running or live events overtook it); false to retry on the next resume.
    private func probeLiveStatus() async -> Bool {
        guard transcript.turn == .running else { return true }
        guard !Task.isCancelled, scopeMatches else { return false }
        let startedAt = revision
        guard let rows = try? await environment.activeSessions() else { return false }
        guard !Task.isCancelled, scopeMatches else { return false }
        // Live events or a new send moved the turn while the RPC was out: the answer is stale.
        guard revision == startedAt, transcript.turn == .running else { return true }
        let stillRunning = rows.contains { row in
            row.isRunning && (transcript.owns(row.runtimeSessionId) || transcript.owns(row.storedSessionId))
        }
        guard !stillRunning else { return true }
        // Idle, or needsInput when a card is still pending: the reducer decides.
        transcript.apply(.sessionBusy(sessionId: transcript.runtimeID ?? token.sessionID, busy: false), timestamp: timestamp())
        return true
    }

    /// Re-reads a window whose first read failed (the Retry button). Respects the scope.
    func retry() {
        guard case .failed = phase else { return }
        refreshPhaseForScope()
    }

    // MARK: Changes from AppState

    func scopeChanged() { refreshPhaseForScope() }

    func clientChanged() {
        let current = environment.clientID()
        guard current != lastClientID else { return }
        lastClientID = current
        guard current != nil, phase != .deleted else { refreshPhaseForScope(); return }
        probeOnNextResume = true
        if scopeMatches {
            phase = .loading
            resume()
        } else {
            refreshPhaseForScope()
        }
    }

    func catalogChanged() {
        guard let row = environment.catalogRow(token.sessionID) else { return }
        transcript.adopt(row.macTabIDs)
    }

    func sessionDeleted(_ id: String) {
        guard transcript.owns(id) else { return }
        phase = .deleted
        if let hubToken { hub.unsubscribe(hubToken) }
        hubToken = nil
        settleTask?.cancel()
        resumeTask?.cancel()
        resumeInFlight = false
        buffered = []
    }

    /// The phase a scope that does not match forces, or nil when the scope matches.
    private func phaseForScope() -> Phase? {
        let scope = environment.scope()
        if !scope.connected { return .disconnected }
        if scope.profile != token.profile || scope.dashboardID != token.dashboardID { return .wrongScope(token.profile) }
        return nil
    }

    /// Matching scope: resume unless already ready or a resume is in flight.
    private func refreshPhaseForScope() {
        guard phase != .deleted else { return }
        if let blocked = phaseForScope() {
            // No RPC result may land for a scope this window does not belong to.
            resumeTask?.cancel()
            settleTask?.cancel()
            resumeInFlight = false
            buffered = []
            bufferOverflowed = false
            phase = blocked
            return
        }
        switch phase {
        case .ready: return
        case .loading where resumeInFlight: return
        default:
            phase = .loading
            resume()
        }
    }

    // MARK: Intents

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        lastError = nil
        settleTask?.cancel()
        revision += 1
        transcript.userSent(text, timestamp: timestamp())
        let id = transcript.runtimeID ?? token.sessionID
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await environment.sendPrompt(id, text)
            } catch {
                draft = text
                transcript.setTurn(.idle)
                lastError = MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300)
            }
        }
    }

    func stopTurn() {
        guard transcript.turn != .idle, scopeMatches else { return }
        let id = transcript.runtimeID ?? token.sessionID
        let cancel = environment.cancel
        Task { try? await cancel(id) }
    }

    /// A card left the pending state locally. When it was the last one, the turn leaves needsInput:
    /// running when the answer was accepted (the agent continues, like upstream's setRunning(true)),
    /// idle when the request had already expired.
    private func cardResolved(accepted: Bool) {
        guard transcript.turn == .needsInput, !transcript.hasPendingCard else { return }
        transcript.setTurn(accepted ? .running : .idle)
    }

    func approve(messageID: String, choice: String) {
        guard scopeMatches, let approval = transcript.messages.first(where: { $0.id == messageID })?.approval,
              approval.status == .pending else { return }
        transcript.updateMessage(id: messageID) { $0.approval?.status = .submitting; $0.approval?.choice = choice }
        Task { [weak self] in
            guard let self else { return }
            do {
                let accepted = try await environment.respondToApproval(approval.sessionId, approval.requestId, choice)
                transcript.updateMessage(id: messageID) {
                    $0.approval?.status = accepted ? (choice == "deny" ? .rejected : .approved) : .expired
                }
                cardResolved(accepted: accepted)
            } catch {
                transcript.updateMessage(id: messageID) {
                    $0.approval?.status = .pending
                    $0.approval?.choice = nil
                    $0.approval?.error = MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300)
                }
            }
        }
    }

    func answerClarify(messageID: String, questionID: String, answer: String) {
        guard scopeMatches, let clarify = transcript.messages.first(where: { $0.id == messageID })?.clarify,
              !clarify.isExpired,
              clarify.questions.first(where: { $0.id == questionID })?.status == .pending else { return }
        func setQuestion(_ change: @escaping (inout ClarifyQuestion) -> Void) {
            transcript.updateMessage(id: messageID) { row in
                guard let index = row.clarify?.questions.firstIndex(where: { $0.id == questionID }) else { return }
                change(&row.clarify!.questions[index])
            }
        }
        setQuestion { $0.status = .submitting }
        transcript.updateMessage(id: messageID) { $0.clarify?.error = nil }
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await environment.respondToClarification(clarify.requestId, answer, questionID)
                if case .expired = outcome {
                    setQuestion { $0.status = .pending }
                    transcript.updateMessage(id: messageID) { $0.clarify?.isExpired = true }
                    cardResolved(accepted: false)
                } else {
                    setQuestion { $0.status = .answered; $0.answer = answer }
                    cardResolved(accepted: true)
                }
            } catch {
                setQuestion { $0.status = .pending }
                transcript.updateMessage(id: messageID) {
                    $0.clarify?.error = MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300)
                }
            }
        }
    }

    func answerInputPrompt(messageID: String, value: String?) {
        // Same as upstream `isAnswerable`: a failed answer can be retried.
        guard scopeMatches, let prompt = transcript.messages.first(where: { $0.id == messageID })?.inputPrompt,
              prompt.isAnswerable else { return }
        transcript.updateMessage(id: messageID) { $0.inputPrompt?.status = .submitting; $0.inputPrompt?.error = nil }
        Task { [weak self] in
            guard let self else { return }
            do {
                // Skip sends what upstream's InputPromptCard sends for skip (read ChatView.swift:3026, AppState.swift:24450).
                try await environment.respondToInputPrompt(prompt.requestId, value ?? "")
                transcript.updateMessage(id: messageID) { $0.inputPrompt?.status = value == nil ? .skipped : .submitted }
                cardResolved(accepted: true)
            } catch {
                transcript.updateMessage(id: messageID) {
                    $0.inputPrompt?.status = .error
                    $0.inputPrompt?.error = AppLocalization.string("Hermes did not receive that answer.")
                }
            }
        }
    }

    #if DEBUG
    /// Test seam: suspends until the settle, resume and send tasks in flight now (and any resume
    /// the settle starts) have finished, so tests need no sleeps.
    func awaitInFlightWork() async {
        await sendTask?.value
        await settleTask?.value
        await resumeTask?.value
    }
    #endif

    private func timestamp() -> String { Self.timestampFormatter.string(from: environment.now()) }

    // MARK: Binding

    func bind(to appState: AppState, tabs: MacSessionTabsStore) {
        guard bindings.isEmpty else { return }
        appState.$client.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.clientChanged() }.store(in: &bindings)
        Publishers.CombineLatest4(appState.$isConnected, appState.$activeProfile, appState.$savedDashboardRegistry,
                                  appState.$isProfileSwitching)
            .dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.scopeChanged() }.store(in: &bindings)
        appState.$sessions.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.catalogChanged() }.store(in: &bindings)
        tabs.sessionDeletions.receive(on: RunLoop.main)
            .sink { [weak self] id in self?.sessionDeleted(id) }.store(in: &bindings)
    }

    /// The real environment. A client whose profile is not the token's is never used.
    static func environment(for appState: AppState, token: MacSessionWindowToken) -> MacSessionWindowEnvironment {
        func client() throws -> HermesClient {
            guard let client = appState.client, (client.profile ?? "default") == token.profile else { throw HermesError.notConnected }
            return client
        }
        return MacSessionWindowEnvironment(
            scope: { [weak appState] in
                MacSessionWindowScope(dashboardID: appState?.activeDashboardID, profile: appState?.activeProfile ?? "default",
                                      connected: (appState?.isConnected ?? false) && !(appState?.isProfileSwitching ?? true))
            },
            clientID: { [weak appState] in appState?.client.map(ObjectIdentifier.init) },
            resume: { id in try await client().openSessionLegacy(id) },
            sendPrompt: { id, text in try await client().sendPrompt(id, text: text) },
            cancel: { id in try await client().cancel(id) },
            activeSessions: { try await client().activeSessions() },
            respondToApproval: { session, request, choice in
                try await client().respondToApproval(sessionId: session, requestId: request, choice: choice)
            },
            respondToClarification: { request, answer, question in
                try await client().respondToClarification(requestId: request, answer: answer, questionId: question)
            },
            respondToInputPrompt: { request, value in try await client().respondToInputPrompt(requestId: request, value: value) },
            catalogRow: { [weak appState] id in appState?.sessions.first { $0.macMatches(id) } },
            now: { Date() })
    }
}
