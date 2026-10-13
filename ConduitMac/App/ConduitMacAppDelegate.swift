import AppKit

enum MacDefaults {
    /// The test host is the real app; global monitors must not run in tests.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The persistent sidebar column is the natural Mac layout.
    static func register() {
        UserDefaults.standard.register(defaults: ["conduit.ipadPersistentSidebar": true])
    }
}

final class ConduitMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacDefaults.register()
        if !MacDefaults.isRunningUnderXCTest { HoverAccessibilityEngine.install() }
        Task.detached(priority: .background) {
            AttachmentStaging.sweepStaleFiles()
        }
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
