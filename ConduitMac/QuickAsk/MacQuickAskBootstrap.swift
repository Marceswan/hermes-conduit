import Foundation

/// Starts Quick Ask at launch, from the app delegate rather than a window, so
/// the hotkey and the stream subscription keep working after the last window
/// closes (the app stays running). Mirrors `MacActivityBootstrap`.
@MainActor
enum MacQuickAskBootstrap {
    static func start(
        appState: AppState? = nil,
        controller: MacQuickAskController? = nil,
        hotKey: MacQuickAskHotKeyManager? = nil
    ) {
        let appState = appState ?? AppStateRuntimeRegistry.shared.appState
        let controller = controller ?? MacQuickAskController.shared
        let hotKey = hotKey ?? MacQuickAskHotKeyManager.shared
        controller.installDefaultPanel()
        controller.bind(to: appState)
        hotKey.onHotKey = { [weak controller] in controller?.toggle() }
        hotKey.refresh()
    }
}
