import Foundation

enum NotchSurface: Equatable { case hidden, compact, expanded }
enum NotchTimer: Hashable { case hoverIn, hoverOut, flash, clickGuard }

enum NotchEffect: Hashable {
    case schedule(NotchTimer, after: TimeInterval)
    case cancel(NotchTimer)
    case announceAttention
}

enum NotchInput: Equatable {
    case counts(NotchCounts, newDecision: Bool, newFinish: Bool)
    case mode(NotchMode)
    case online(Bool)
    case hoverEntered, hoverExited
    case interacted
    case dismissRequested       // Esc or a click outside
    case toggleCommandPin       // Go > Show Agent Status
    case timer(NotchTimer)
}

/// Pure state machine. The controller runs the returned effects and feeds
/// timer expiries back in, so tests need no clock.
struct NotchStatusState: Equatable {
    static let hoverInDelay: TimeInterval = 0.2
    static let hoverOutDelay: TimeInterval = 0.4
    static let flashDuration: TimeInterval = 4.0
    static let clickGuard: TimeInterval = 0.6

    private(set) var mode: NotchMode
    private(set) var counts = NotchCounts()
    private var online = true
    private var attentionPinned = false
    private var commandPinned = false
    private var hovering = false
    private var hoverExpanded = false
    private var flashing = false
    private var guarding = false
    private var interacted = false

    init(mode: NotchMode = .activeAgents) { self.mode = mode }

    var isCommandPinned: Bool { commandPinned }
    var buttonsEnabled: Bool { !guarding }

    var surface: NotchSurface {
        if !online || mode == .off { return commandPinned ? .expanded : .hidden }
        if commandPinned || attentionPinned { return .expanded }
        let visible = mode == .onlyWhenNeeded ? counts.needsUser > 0 : counts.hasAnything
        guard visible else { return .hidden }
        return (flashing || hoverExpanded) ? .expanded : .compact
    }

    private static let allTimers: [NotchEffect] = [.cancel(.hoverIn), .cancel(.hoverOut), .cancel(.flash), .cancel(.clickGuard)]

    private mutating func clearTransient() {
        attentionPinned = false; hoverExpanded = false; flashing = false; guarding = false; interacted = false
    }

    mutating func apply(_ input: NotchInput) -> [NotchEffect] {
        var fx: [NotchEffect] = []
        switch input {
        case let .counts(c, newDecision, newFinish):
            counts = c
            let live = online && mode != .off
            if live && newDecision {
                attentionPinned = true; interacted = false; guarding = true
                fx += [.schedule(.clickGuard, after: Self.clickGuard), .announceAttention]
            } else if c.decisions == 0 && attentionPinned {
                attentionPinned = false; interacted = false; guarding = false
                fx.append(.cancel(.clickGuard))
            }
            if live && mode == .activeAgents && newFinish && !attentionPinned && c.recent > 0 {
                flashing = true
                fx.append(.schedule(.flash, after: Self.flashDuration))
            }
            if !c.hasAnything {
                flashing = false; hoverExpanded = false
                fx += [.cancel(.flash), .cancel(.hoverIn), .cancel(.hoverOut)]
            }
        case let .mode(m):
            mode = m
            if m == .off { clearTransient(); fx = Self.allTimers }
        case let .online(o):
            online = o
            if !o { clearTransient(); fx = Self.allTimers }
        case .hoverEntered:
            hovering = true
            fx.append(.cancel(.hoverOut))
            if surface == .compact && !hoverExpanded { fx.append(.schedule(.hoverIn, after: Self.hoverInDelay)) }
        case .hoverExited:
            hovering = false
            fx.append(.cancel(.hoverIn))
            if hoverExpanded || (attentionPinned && interacted) {
                fx.append(.schedule(.hoverOut, after: Self.hoverOutDelay))
            } else if surface != .compact {
                fx = []   // nothing pending to cancel (sticky panel before interaction)
            }
        case .interacted:
            interacted = true
        case .dismissRequested:
            guard surface == .expanded else { return [] }
            commandPinned = false; clearTransient()
            fx = Self.allTimers
        case .toggleCommandPin:
            commandPinned.toggle()
        case .timer(let t):
            switch t {
            case .hoverIn: if hovering && surface == .compact { hoverExpanded = true }
            case .hoverOut:
                if !hovering {
                    hoverExpanded = false
                    if interacted { attentionPinned = false; interacted = false }
                }
            case .flash: flashing = false
            case .clickGuard: guarding = false
            }
        }
        if surface == .hidden { hoverExpanded = false; flashing = false }
        return fx
    }
}
