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
        // App Nap stays off while a reply streams or a call is live (D29). After the activity feed: it is an input.
        if !MacDefaults.isRunningUnderXCTest { MacBackgroundActivityBootstrap.start() }
        // Local notifications (D20). After the activity feed (its events feed
        // the coordinator) and before this method returns, so a cold-launch
        // click on a notification finds its delegate.
        if !MacDefaults.isRunningUnderXCTest {
            MacNotificationRuntime.shared.start(appState: AppStateRuntimeRegistry.shared.appState)
        }
        Task.detached(priority: .background) {
            AttachmentStaging.sweepStaleFiles()
        }
        // Ported from ConduitAppDelegate (upstream step 2); keep in sync (PORTING_LEDGER). Ruling R24.
        if !MacDefaults.isRunningUnderXCTest {
            // Low Power Mode and Low Data Mode stretch every poll (#845).
            DeviceConditionsMonitor.shared.start()
            // MetricKit's daily reports, kept for Diagnostics & logs (#843). MetricKit reaches the Mac from macOS 12.
            MetricKitReports.shared.start()
            // Mouse use keeps the drifting backdrop moving (the Mac twin of the iOS touch probe).
            MacInteractionIdleMonitor.shared.start()
        }
    }

    /// A failed hotkey registration is retried when the app comes forward (no retry loop).
    func applicationDidBecomeActive(_ notification: Notification) {
        if !MacDefaults.isRunningUnderXCTest { MacQuickAskHotKeyManager.shared.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacInteractionIdleMonitor.shared.stop()
        // Contact cards written for "Add to Contacts" hold a phone number and an email address.
        RichContactVCard.removeAllFiles()
        MacActivityBootstrap.stop()
        if !MacDefaults.isRunningUnderXCTest { MacQuickAskBootstrap.stop() }
        MacBackgroundActivityBootstrap.stop()
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
