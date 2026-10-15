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
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacDefaults.register()
        // Start Sparkle's hourly schedule with the app, not the first menu build.
        _ = MacUpdater.shared
        if !MacDefaults.isRunningUnderXCTest { HoverAccessibilityEngine.install() }
        if !MacDefaults.isRunningUnderXCTest { MacActivityBootstrap.start() }
        Task.detached(priority: .background) {
            AttachmentStaging.sweepStaleFiles()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacActivityBootstrap.stop()
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

    /// Clicking the Dock icon with no window open shows the main window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
