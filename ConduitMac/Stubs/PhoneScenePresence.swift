// Mac twin of Conduit/CarPlay/PhoneScenePresence.swift (R2); keep in sync (PORTING_LEDGER).
import AppKit

/// Upstream asks "is a phone window in the foreground?" before running
/// foreground-only work. On Mac that means: a visible, unminimized window.
@MainActor
enum PhoneScenePresence {
    static var isInForeground: Bool {
        !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
    }
}
