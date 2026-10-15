import AppKit
import Combine
import Foundation

enum MacQuickAskConnection: Equatable { case connected, connecting, disconnected }

@MainActor
protocol MacQuickAskPanelHosting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func toggle()
}

extension MacFloatingPanelController: MacQuickAskPanelHosting {}

struct MacQuickAskEnvironment {
    var connection: () -> MacQuickAskConnection = { .disconnected }
    var activeProfile: () -> String = { "default" }
    var createSession: () async throws -> (sessionId: String, storedSessionId: String?, profile: String?) =
        { throw HermesError.notConnected }
    var sendPrompt: (String, String) async throws -> PromptSubmissionOutcome = { _, _ in throw HermesError.notConnected }
    var cancel: (String) async throws -> Void = { _ in }
    var openSession: (String) -> Void = { _ in }
    var activateMainWindow: () -> Void = {}
    var refreshSessions: () -> Void = {}
    var now: () -> Date = { Date() }
}

private struct MacQuickAskProfileMismatch: Error { let profile: String }

/// Orchestrates Quick Ask (D15). Holds no AppState state of its own: every
/// RPC goes through the injected environment, bound to AppState at app start.
@MainActor
final class MacQuickAskController: ObservableObject {
    static let shared = MacQuickAskController()

    @Published private(set) var model = MacQuickAskModel()
    @Published var draft = ""
    @Published private(set) var connection: MacQuickAskConnection = .disconnected
    /// Bumped on every show(); the view refocuses its field (a reopened panel keeps its view).
    @Published private(set) var focusRequest = 0

    var environment = MacQuickAskEnvironment()
    var panel: MacQuickAskPanelHosting?
    /// Builds the real panel on first show (`installDefaultPanel()` supplies it).
    var makePanel: (MacQuickAskController) -> MacQuickAskPanelHosting = { _ in
        preconditionFailure("MacQuickAskController.makePanel not installed")
    }

    private let hub: MacStreamEventHub
    private var hubToken: MacStreamEventHub.Token?
    private var turnTask: Task<Void, Never>?
    private var bindings: Set<AnyCancellable> = []

    init(hub: MacStreamEventHub? = nil) {
        self.hub = hub ?? .shared
    }

    // MARK: Panel lifecycle

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        model.panelOpened(now: environment.now())
        if panel == nil { panel = makePanel(self) }
        panel?.show()
        focusRequest += 1
    }

    func hide() { panel?.hide() }

    /// Called from the panel's onDismiss. Hiding never cancels a turn.
    func panelDidDismiss() { model.panelClosed(now: environment.now()) }

    // MARK: Intents

    func submit() {
        guard connection == .connected, model.canSubmit else { return }
        guard model.submit(draft, now: environment.now()) else { return }
        draft = ""
        run(prompt: model.lastPrompt)
    }

    func retry() {
        guard connection == .connected, model.canSubmit, !model.lastPrompt.isEmpty else { return }
        guard model.submit(model.lastPrompt, now: environment.now()) else { return }
        draft = ""
        run(prompt: model.lastPrompt)
    }

    func stop() {
        guard model.isTurnRunning, let id = model.runtimeID else { return }
        let cancel = environment.cancel
        Task { try? await cancel(id) }
    }

    func newConversation() {
        turnTask?.cancel()
        model.reset()
        draft = ""
    }

    func promote() {
        guard let id = model.promoteID else { return }
        environment.activateMainWindow()
        environment.openSession(id)
        model.detach()
        hide()
    }

    func openConduit() { environment.activateMainWindow(); hide() }

    func connectionChanged(_ value: MacQuickAskConnection) { connection = value }

    /// One stream event, from the hub. Foreign sessions are ignored by the model.
    func handle(_ event: StreamEvent) {
        model.apply(event, now: environment.now())
    }

    // MARK: Turn

    private func run(prompt: String) {
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                if model.runtimeID == nil {
                    let created = try await environment.createSession()
                    // Cmd-N or a newer turn replaced this one while the RPC was in flight.
                    guard !Task.isCancelled else { return }
                    if let profile = created.profile, profile != environment.activeProfile() {
                        throw MacQuickAskProfileMismatch(profile: profile)
                    }
                    model.sessionCreated(runtimeID: created.sessionId, storedID: created.storedSessionId)
                    environment.refreshSessions()
                }
                guard let id = model.runtimeID else { return }
                _ = try await environment.sendPrompt(id, prompt)
                guard !Task.isCancelled else { return }
                model.promptStarted()
            } catch {
                guard !Task.isCancelled else { return }
                let failure = Self.classify(error)
                draft = prompt   // preserved for Retry and for editing
                model.fail(failure.message, kind: failure.kind, now: environment.now())
            }
        }
    }

    nonisolated static func classify(_ error: Error) -> (message: String, kind: MacQuickAskModel.FailureKind) {
        if let mismatch = error as? MacQuickAskProfileMismatch {
            return (String(format: AppLocalization.string("Hermes created this in %@. Switch profiles in Conduit and try again."),
                           mismatch.profile), .generic)
        }
        if let rpc = error as? RpcError, rpc.code == 4090, !rpc.isSessionNotOwned {
            return (AppLocalization.string("Hermes is already running the most sessions it allows. Finish or close one in Conduit, then try again."),
                    .sessionLimit)
        }
        return (UserFacingError.message(for: error), .generic)
    }

    // MARK: Binding

    func subscribeToHub() {
        guard hubToken == nil else { return }
        hubToken = hub.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    func unsubscribeFromHub() {
        guard let hubToken else { return }
        hub.unsubscribe(hubToken)
        self.hubToken = nil
    }

    func bind(to appState: AppState) {
        guard bindings.isEmpty else { return }
        environment = MacQuickAskEnvironment(
            connection: { [weak appState] in Self.connection(of: appState) },
            activeProfile: { [weak appState] in appState?.activeProfile ?? "default" },
            createSession: { [weak appState] in
                guard let client = appState?.client else { throw HermesError.notConnected }
                return try await client.createSession(inProfile: nil)
            },
            sendPrompt: { [weak appState] id, text in
                guard let client = appState?.client else { throw HermesError.notConnected }
                return try await client.sendPrompt(id, text: text)
            },
            cancel: { [weak appState] id in
                guard let client = appState?.client else { throw HermesError.notConnected }
                try await client.cancel(id)
            },
            openSession: { [weak appState] id in _ = appState?.requestOpenSession(id) },
            activateMainWindow: { MacWindowActivation.bringConduitForward() },
            refreshSessions: { [weak appState] in Task { await appState?.loadSessions(forceRefresh: true) } },
            now: { Date() })
        subscribeToHub()
        connection = Self.connection(of: appState)
        Publishers.CombineLatest3(appState.$isConnected, appState.$isConnecting, appState.$isProfileSwitching)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak appState] _, _, _ in
                self?.connectionChanged(Self.connection(of: appState))
            }
            .store(in: &bindings)
    }

    private static func connection(of appState: AppState?) -> MacQuickAskConnection {
        guard let appState else { return .disconnected }
        if appState.isConnected && !appState.isProfileSwitching { return .connected }
        return appState.isConnecting || appState.isProfileSwitching ? .connecting : .disconnected
    }
}

#if DEBUG
extension MacQuickAskController {
    // test seam: put the model in a given state without driving a turn
    func forceStateForTest(_ state: MacQuickAskModel.State) {
        model = MacQuickAskModel(testState: state)
    }
}
#endif
