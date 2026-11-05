import Combine
import Foundation

/// Feeds `MacBackgroundActivity` from the published state of the app (D29). One `Bool` publisher per input of
/// `MacBackgroundActivityInputs`; each emits its current value on subscribe. The monitor holds no other state.
@MainActor
final class MacBackgroundActivityMonitor {
    struct Sources {
        var mainTurn: AnyPublisher<Bool, Never>
        var sessionWindowTurn: AnyPublisher<Bool, Never>
        var quickAskTurn: AnyPublisher<Bool, Never>
        var socketStream: AnyPublisher<Bool, Never>
        var liveCall: AnyPublisher<Bool, Never>
    }

    private let holder: MacBackgroundActivity
    private let sources: Sources
    private var inputs = MacBackgroundActivityInputs()
    private var bindings: Set<AnyCancellable> = []

    init(holder: MacBackgroundActivity, sources: Sources) {
        self.holder = holder
        self.sources = sources
    }

    var isRunning: Bool { !bindings.isEmpty }

    func start() {
        guard bindings.isEmpty else { return }
        follow(sources.mainTurn, \.mainTurn)
        follow(sources.sessionWindowTurn, \.sessionWindowTurn)
        follow(sources.quickAskTurn, \.quickAskTurn)
        follow(sources.socketStream, \.socketStream)
        follow(sources.liveCall, \.liveCall)
    }

    /// App termination: the token ends now, with no grace.
    func stop() {
        bindings.removeAll()
        inputs = MacBackgroundActivityInputs()
        holder.release()
    }

    /// @Published emits in willSet: use the emitted value, never re-read the property inside the sink.
    private func follow(_ source: AnyPublisher<Bool, Never>, _ flag: WritableKeyPath<MacBackgroundActivityInputs, Bool>) {
        source
            .sink { [weak self] value in
                guard let self else { return }
                self.inputs[keyPath: flag] = value
                self.holder.update(self.inputs)
            }
            .store(in: &bindings)
    }
}

extension MacBackgroundActivityMonitor.Sources {
    /// The real signals:
    /// - main window: `AppState.turnState` (`MacBackgroundActivityInputs.turnHolds`);
    /// - session windows (D21): `MacSessionWindowRegistry.runningTurns`;
    /// - Quick Ask (D15): `MacQuickAskController.model.isTurnRunning`;
    /// - any chat on this socket: a non-poll-only working turn in `AgentActivityFeed.items`;
    /// - live calls: `MacBackgroundActivitySources.liveCall`.
    @MainActor
    static func live(
        appState: AppState,
        feed: AgentActivityFeed?,
        registry: MacSessionWindowRegistry? = nil,
        quickAsk: MacQuickAskController? = nil,
        callPollInterval: TimeInterval = MacBackgroundActivitySources.callPollInterval
    ) -> Self {
        Self(
            mainTurn: MacBackgroundActivitySources.mainTurn(of: appState),
            sessionWindowTurn: MacBackgroundActivitySources.sessionWindowTurn(of: registry ?? .shared),
            quickAskTurn: MacBackgroundActivitySources.quickAskTurn(of: quickAsk ?? .shared),
            socketStream: MacBackgroundActivitySources.socketStream(items: feed?.$items.eraseToAnyPublisher()),
            liveCall: MacBackgroundActivitySources.liveCall(
                surface: MacBackgroundActivitySources.callSurface(of: appState),
                isActive: { [weak appState] in
                    guard let appState else { return false }
                    return appState.isLiveVoiceCallActive || appState.isNativeHermesCallActive
                },
                ticks: { MacBackgroundActivitySources.timerTicks(every: callPollInterval) }))
    }
}

/// The pieces of the live sources that need their own rules (D29).
enum MacBackgroundActivitySources {
    /// While a call screen is up, the call is read again this often: a call's phase change (a call that fails with
    /// its screen open) publishes nothing on `AppState`.
    static let callPollInterval: TimeInterval = 2

    /// The main window's turn: `AppState.turnState`, by `MacBackgroundActivityInputs.turnHolds`.
    @MainActor
    static func mainTurn(of appState: AppState) -> AnyPublisher<Bool, Never> {
        appState.$turnState
            .map(MacBackgroundActivityInputs.turnHolds)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Some session window (D21) runs a turn.
    @MainActor
    static func sessionWindowTurn(of registry: MacSessionWindowRegistry) -> AnyPublisher<Bool, Never> {
        registry.$runningTurns
            .map { !$0.isEmpty }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Quick Ask (D15) creates, sends or streams a turn.
    @MainActor
    static func quickAskTurn(of controller: MacQuickAskController) -> AnyPublisher<Bool, Never> {
        controller.$model
            .map(\.isTurnRunning)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// A turn the Mac streams now, in any chat on this socket. A poll-only row (seen in the server's active list
    /// only, with no stream events here) is another device's or a cron job's, and holds nothing.
    static func socketStream(items: AnyPublisher<[AgentActivityItem], Never>?) -> AnyPublisher<Bool, Never> {
        guard let items else { return Just(false).eraseToAnyPublisher() }
        return items
            .map { rows in rows.contains { $0.kind == .turn && $0.state == .working && !$0.isPollOnly } }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// True while a call has a screen or a bar: one of the four live sheets, the minimised bar, or a native call.
    /// A call that is running with none of these (none is known on the Mac) is read at the next change.
    @MainActor
    static func callSurface(of appState: AppState) -> AnyPublisher<Bool, Never> {
        let sheets = Publishers.CombineLatest4(
            appState.$showGeminiLiveSheet, appState.$showGPTLiveSheet,
            appState.$showGrokLiveSheet, appState.$showLocalLiveSheet
        ).map { $0 || $1 || $2 || $3 }
        return Publishers.CombineLatest3(
            sheets, appState.$minimisedLiveVoice.map { $0 != nil }, appState.$isNativeHermesCallActive
        )
        .map { $0 || $1 || $2 }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    /// Whether a call runs. `surface` says when to look; `isActive` is the answer.
    ///
    /// A sheet that is up can show a call that failed or never started, and `VoiceBackgroundJobSupervisor.liveCallID`
    /// stays set after a hang-up (its comment says "the running (or last)" call), so neither is the answer.
    /// `isActive` is: it reads each controller's phase, and builds no controller.
    /// - On each change of `surface`: read once, on the next main turn (the change has landed by then).
    /// - While `surface` is true: read again at each tick.
    static func liveCall(
        surface: AnyPublisher<Bool, Never>,
        isActive: @escaping @MainActor () -> Bool,
        ticks: @escaping () -> AnyPublisher<Void, Never>
    ) -> AnyPublisher<Bool, Never> {
        surface
            .receive(on: DispatchQueue.main)
            .map { up -> AnyPublisher<Bool, Never> in
                let read = { MainActor.assumeIsolated { isActive() } }
                guard up else { return Just(read()).eraseToAnyPublisher() }
                return ticks().prepend(()).map { _ in read() }.eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    static func timerTicks(every interval: TimeInterval) -> AnyPublisher<Void, Never> {
        Timer.publish(every: interval, tolerance: interval / 2, on: .main, in: .common)
            .autoconnect()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

/// Starts the holder at launch, from the app delegate rather than a window, so a reply keeps its token after the
/// last window closes. Mirrors `MacActivityBootstrap`.
@MainActor
enum MacBackgroundActivityBootstrap {
    private(set) static var monitor: MacBackgroundActivityMonitor?

    /// Call after `MacActivityBootstrap.start()`: the feed it makes is one of the inputs.
    static func start(
        appState: AppState? = nil,
        sources: MacBackgroundActivityMonitor.Sources? = nil,
        holder: MacBackgroundActivity? = nil
    ) {
        guard monitor == nil else { return }
        let sources = sources ?? .live(
            appState: appState ?? AppStateRuntimeRegistry.shared.appState, feed: AgentActivityFeed.shared)
        let monitor = MacBackgroundActivityMonitor(holder: holder ?? MacBackgroundActivity(), sources: sources)
        monitor.start()
        self.monitor = monitor
    }

    /// App termination: end the token now.
    static func stop() {
        monitor?.stop()
        monitor = nil
    }
}
