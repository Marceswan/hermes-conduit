import AppKit
import SwiftUI

/// Opens the primary chat window when none exists (D21). Closing the main window while a session
/// window is open leaves Conduit running with no way back: File > New Window is removed, and
/// `applicationShouldHandleReopen` used to act only when NO window was visible. SwiftUI's
/// `openWindow` is an environment value, so a view that outlives the main window (a session window,
/// the main window itself) registers it here.
@MainActor
final class MacPrimaryWindowOpener {
    static let shared = MacPrimaryWindowOpener()
    private var action: (() -> Void)?

    func register(_ open: @escaping () -> Void) { action = open }

    /// False when no scene has registered yet (nothing can be opened).
    @discardableResult
    func open() -> Bool {
        guard let action else { return false }
        action()
        return true
    }
}

enum MacPrimaryWindow {
    static let sceneID = "conduit-primary"

    enum ReopenAction: Equatable {
        case none
        case showPrimary(NSWindow)
        case openPrimary
    }

    static func isPrimary(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix(sceneID) ?? false
    }

    /// What a Dock click (`applicationShouldHandleReopen`) does.
    /// - A primary window exists but is not on screen (minimised or hidden): show it.
    /// - No primary window and another window is visible (a session window): open one. This is the
    ///   stranded case the system never handles, because it acts only when nothing is visible.
    /// - No primary window and nothing visible: nothing here; the system's own reopen creates it.
    static func reopenAction(hasVisibleWindows: Bool, windows: [NSWindow]) -> ReopenAction {
        guard let primary = windows.first(where: isPrimary) else {
            return hasVisibleWindows ? .openPrimary : .none
        }
        return primary.isVisible ? .none : .showPrimary(primary)
    }

    @MainActor
    static func handleReopen(hasVisibleWindows: Bool, windows: [NSWindow], opener: MacPrimaryWindowOpener? = nil) {
        switch reopenAction(hasVisibleWindows: hasVisibleWindows, windows: windows) {
        case .none:
            break
        case .showPrimary(let window):
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        case .openPrimary:
            (opener ?? .shared).open()
        }
    }
}

/// Registers `openWindow(id:)` for the primary scene with `MacPrimaryWindowOpener`.
/// Applied to the primary window's content and to every session window's content, so a
/// registration from a view that is still alive exists when the main window is gone.
struct MacRegisterPrimaryWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            MacPrimaryWindowOpener.shared.register { [openWindow] in openWindow(id: MacPrimaryWindow.sceneID) }
        }
    }
}
