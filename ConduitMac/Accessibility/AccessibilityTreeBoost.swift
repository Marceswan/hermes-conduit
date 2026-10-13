import AppKit

/// Controls AppKit's "enhanced user interface" flag, which makes SwiftUI
/// populate a hosting view's accessibility tree without a VoiceOver client.
/// This file is the only place that names the undocumented selectors.
/// While the flag is on AppKit may slow or skip window animations, so the
/// hover engine holds it only while the pointer is actively moving.
@MainActor
enum AccessibilityTreeBoost {
    private static let getter = Selector(("accessibilityEnhancedUserInterfaceAttribute"))
    private static let setter = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))

    /// False when this macOS no longer answers the selectors. No KVC anywhere:
    /// on `SwiftUI.AppKitApplication` the KVC key raises `NSUnknownKeyException`.
    static func isAvailable(on app: NSObject) -> Bool {
        app.responds(to: getter) && app.responds(to: setter)
    }

    static func isOn(on app: NSObject) -> Bool {
        guard app.responds(to: getter) else { return false }
        return (app.perform(getter)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
    }

    static func set(_ on: Bool, on app: NSObject) {
        guard isAvailable(on: app), isOn(on: app) != on else { return }
        _ = app.perform(setter, with: NSNumber(value: on))
    }

    static var isAvailable: Bool { isAvailable(on: NSApp) }
    static var isOn: Bool { isOn(on: NSApp) }
    static func set(_ on: Bool) { set(on, on: NSApp) }

    /// SwiftUI builds a window's accessibility tree only while an assistive
    /// client is attached, so hold the flag on just for `body`, then put it
    /// back. Already on (e.g. the hover engine left it on) means touch
    /// nothing. If the accessors are unavailable `body` does not run and the
    /// result is false.
    static func withTree(on app: NSObject = NSApp, _ body: () -> Bool) -> Bool {
        guard isAvailable(on: app) else { return false }
        let previous = isOn(on: app)
        if !previous { set(true, on: app) }
        defer { if !previous { set(false, on: app) } }
        return body()
    }
}
