import AppKit
import CoreSpotlight

enum MacDefaults {
    /// The test host is the real app; global monitors must not run in tests.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The persistent sidebar column is the natural Mac layout. Return sends
    /// (Shift- or Option-Return for a new line): every Mac has a hardware
    /// keyboard, so upstream's opt-in default is wrong here. Registered, not
    /// stored, so the Keyboard setting still overrides it.
    static func register() {
        // In-app session tabs replace window tabs (D11). AppKit's own tab items
        // in the Window menu would compete for Ctrl-Tab and Ctrl-Shift-Tab.
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.register(defaults: [
            "conduit.ipadPersistentSidebar": true,
            ComposerReturnKey.preferenceKey: true,
        ])
    }
}

final class ConduitMacAppDelegate: NSObject, NSApplicationDelegate {
    /// The "Send to Hermes" Service (D19). AppKit holds the provider weakly.
    /// Conduit comes forward at once, even while disconnected, so the user
    /// sees the connection UI the text is waiting on.
    private let servicesProvider = MacServicesProvider { text in
        MacServiceInbox.shared.submit(text)
        MacWindowActivation.bringConduitForward()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacDefaults.register()
        NSApp.servicesProvider = servicesProvider
        // Start Sparkle's hourly schedule with the app, not the first menu build.
        _ = MacUpdater.shared
        if !MacDefaults.isRunningUnderXCTest { HoverAccessibilityEngine.install() }
        if !MacDefaults.isRunningUnderXCTest { MacActivityBootstrap.start() }
        if !MacDefaults.isRunningUnderXCTest { MacQuickAskBootstrap.start() }
        // Local notifications (D20). After the activity feed (its events feed
        // the coordinator) and before this method returns, so a cold-launch
        // click on a notification finds its delegate.
        if !MacDefaults.isRunningUnderXCTest {
            MacNotificationRuntime.shared.start(appState: AppStateRuntimeRegistry.shared.appState)
        }
        Task.detached(priority: .background) {
            AttachmentStaging.sweepStaleFiles()
        }
    }

    /// A failed hotkey registration is retried when the app comes forward (no retry loop).
    func applicationDidBecomeActive(_ notification: Notification) {
        if !MacDefaults.isRunningUnderXCTest { MacQuickAskHotKeyManager.shared.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacActivityBootstrap.stop()
        if !MacDefaults.isRunningUnderXCTest { MacQuickAskBootstrap.stop() }
    }

    /// A Spotlight result opened Conduit (D19). SwiftUI's `.onContinueUserActivity`
    /// may not fire when the activity launches the app cold, so this AppKit door
    /// feeds the same inbox; the inbox drops the repeat if both fire.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        MacSpotlightInbox.shared.receive(activity: userActivity)
    }

    /// Closing the window keeps Conduit (and its dashboard socket) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon brings the main window back: when it is minimised or hidden, and also
    /// when it was closed while a session window (D21) is still open, which `hasVisibleWindows`
    /// alone would never report. With nothing visible at all, the system's own reopen creates it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MacPrimaryWindow.handleReopen(hasVisibleWindows: flag, windows: sender.windows)
        return true
    }
}
