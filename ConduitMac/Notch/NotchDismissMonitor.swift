import AppKit

@MainActor
protocol NotchDismissMonitoring: AnyObject {
    func start(onDismiss: @escaping () -> Void, isOwnWindow: @escaping (NSWindow?) -> Bool)
    func stop()
}

/// Click outside and Esc. Mouse events from other apps need no permission
/// (`addGlobalMonitorForEvents` only gates key events). The panel is not key,
/// so Esc is only seen while Conduit is the active app (local monitor).
@MainActor
final class NotchDismissMonitor: NotchDismissMonitoring {
    private var global: Any?
    private var local: Any?

    func start(onDismiss: @escaping () -> Void, isOwnWindow: @escaping (NSWindow?) -> Bool) {
        stop()
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in onDismiss() }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { onDismiss() }   // Esc
            } else if !isOwnWindow(event.window) {
                onDismiss()
            }
            return event
        }
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil
    }
}
