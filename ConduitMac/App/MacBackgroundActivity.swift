import Foundation

/// How much running work Conduit has, lowest first (D29). The level picks the `ProcessInfo` activity options.
enum MacBackgroundActivityLevel: Int, Comparable {
    /// Nothing runs: no token.
    case idle
    /// A reply streams. App Nap stays off; the Mac may still sleep when idle.
    case stream
    /// A live voice call runs. Also stops idle system sleep, so the call does not drop with the lid open.
    case call

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Both option sets also carry `.automaticTerminationDisabled` and `.suddenTerminationDisabled`
    /// (Info.plist opts in to neither today), so no separate termination call is needed.
    var options: ProcessInfo.ActivityOptions? {
        switch self {
        case .idle: return nil
        case .stream: return .userInitiatedAllowingIdleSystemSleep
        case .call: return .userInitiated
        }
    }
}

/// What runs now, as plain flags (D29). The decision is pure: flags in, level out.
struct MacBackgroundActivityInputs: Equatable {
    /// The main window's turn (`AppState.turnState`, see `turnHolds`).
    var mainTurn = false
    /// A D21 session window runs a turn (`MacSessionWindowRegistry.runningTurns`).
    var sessionWindowTurn = false
    /// A Quick Ask turn runs (`MacQuickAskModel.isTurnRunning`).
    var quickAskTurn = false
    /// A turn streams on this socket, in any chat (`AgentActivityFeed`). It covers a chat that no window shows,
    /// for example a tab the user left while it ran.
    var socketStream = false
    /// A live voice call runs (`MacBackgroundActivitySources.liveCall`).
    var liveCall = false

    var level: MacBackgroundActivityLevel {
        if liveCall { return .call }
        if mainTurn || sessionWindowTurn || quickAskTurn || socketStream { return .stream }
        return .idle
    }

    /// A reply that runs, and the resync that finds out whether one runs, hold the token. Not `.idle`. Not
    /// `.unsupportedGateway` (a gateway that cannot report a turn: a steady state, no live stream). Not
    /// `.reconnecting` (also the state of a dropped connection that stays down for hours).
    static func turnHolds(_ state: TurnState) -> Bool {
        switch state {
        case .running, .synchronizing: return true
        case .idle, .reconnecting, .unsupportedGateway: return false
        }
    }
}

/// The two `ProcessInfo` calls the holder uses; a test supplies a fake.
protocol MacActivityProcess: AnyObject {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol
    func endActivity(_ activity: any NSObjectProtocol)
}

extension ProcessInfo: MacActivityProcess {}

/// Keeps App Nap and idle throttling off while a reply streams or a call is live (D29), so a reply finishes
/// with the window closed or Conduit hidden. Holds at most one `ProcessInfo` activity token.
///
/// - A higher level takes its token at once.
/// - A lower level (or none) waits `graceInterval` first, so the token does not churn between turns. The level
///   that counts is the one at the end of the grace.
/// - A change of options takes the new token before it ends the old one: there is no gap.
@MainActor
final class MacBackgroundActivity {
    /// Between the last running work and the release. Tests pin it.
    static let graceInterval: TimeInterval = 5
    /// Shown by `pmset -g assertions` and in Activity Monitor. Not user-visible text.
    static let reason = "Conduit: a reply is streaming or a voice call is live"

    /// Runs `fire` once after `delay` seconds; the returned closure cancels it.
    typealias Schedule = (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void

    /// The level of the token held now.
    private(set) var heldLevel: MacBackgroundActivityLevel = .idle
    /// True while a release waits for the end of the grace.
    var isGraceRunning: Bool { cancelGrace != nil }

    private let process: MacActivityProcess
    private let graceInterval: TimeInterval
    private let schedule: Schedule
    private var token: (any NSObjectProtocol)?
    private var wanted: MacBackgroundActivityLevel = .idle
    private var cancelGrace: (() -> Void)?

    init(
        process: MacActivityProcess = ProcessInfo.processInfo,
        graceInterval: TimeInterval = MacBackgroundActivity.graceInterval,
        schedule: @escaping Schedule = MacBackgroundActivity.runLoopSchedule
    ) {
        self.process = process
        self.graceInterval = graceInterval
        self.schedule = schedule
    }

    deinit {
        // A token that is never ended keeps the activity for the life of the process.
        if let token { process.endActivity(token) }
    }

    /// The newest inputs. Call it on every change.
    func update(_ inputs: MacBackgroundActivityInputs) {
        wanted = inputs.level
        if wanted > heldLevel {
            endGrace()
            acquire(wanted)
        } else if wanted == heldLevel {
            endGrace()
        } else if cancelGrace == nil {
            cancelGrace = schedule(graceInterval) { [weak self] in self?.graceElapsed() }
        }
    }

    /// Ends the token now, with no grace (app termination).
    func release() {
        endGrace()
        wanted = .idle
        acquire(.idle)
    }

    private func graceElapsed() {
        cancelGrace = nil
        if wanted < heldLevel { acquire(wanted) }
    }

    private func endGrace() {
        cancelGrace?()
        cancelGrace = nil
    }

    /// Takes the token for `level` and only then ends the old one.
    private func acquire(_ level: MacBackgroundActivityLevel) {
        guard level != heldLevel else { return }
        let old = token
        token = level.options.map { process.beginActivity(options: $0, reason: Self.reason) }
        heldLevel = level
        if let old { process.endActivity(old) }
    }

    /// A main run loop timer, in common modes so it also fires while a scroll tracks. A late fire only holds the
    /// token a little longer.
    nonisolated static func runLoopSchedule(
        _ delay: TimeInterval,
        _ fire: @escaping @MainActor () -> Void
    ) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
