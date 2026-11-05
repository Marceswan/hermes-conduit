import AppKit

/// Notes mouse use for `InteractionIdleState` (Ruling R24): a click or a scroll anywhere in a Conduit window counts
/// as use, so the drifting backdrop does not rest while the mouse is in use. The Mac twin of upstream's
/// `InteractionIdleTouchProbe` (iOS, gated off on Mac); keep in sync (PORTING_LEDGER).
///
/// One local `NSEvent` monitor for left and right mouse down and scroll wheel. It never consumes an event. Key
/// presses already count through the text-change notifications that `InteractionIdleState` observes. A scroll
/// gesture sends many events, so scrolling is noted at most once per `scrollNoteInterval` (as upstream's probe
/// notes a long drag every few seconds).
@MainActor
final class MacInteractionIdleMonitor {
    static let shared = MacInteractionIdleMonitor()

    /// The event kinds that count as use.
    static let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel]
    static let scrollNoteInterval: TimeInterval = 1

    private let note: @MainActor () -> Void
    private var monitor: Any?
    private var lastScrollNote: TimeInterval = -.infinity

    init(note: @escaping @MainActor () -> Void = { InteractionIdleState.shared.noteInteraction() }) {
        self.note = note
    }

    var isRunning: Bool { monitor != nil }

    /// Installs the monitor; calling it again does nothing.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    /// Removes the monitor (at quit).
    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .scrollWheel {
            guard event.timestamp - lastScrollNote >= Self.scrollNoteInterval else { return }
            lastScrollNote = event.timestamp
        }
        note()
    }
}
