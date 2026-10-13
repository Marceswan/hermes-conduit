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

    /// False when this macOS no longer answers the selectors.
    static var isAvailable: Bool {
        NSApp.responds(to: getter) && NSApp.responds(to: setter)
    }

    static var isOn: Bool {
        guard isAvailable else { return false }
        return (NSApp.value(forKey: "accessibilityEnhancedUserInterfaceAttribute") as? NSNumber)?.boolValue ?? false
    }

    static func set(_ on: Bool) {
        guard isAvailable, isOn != on else { return }
        _ = NSApp.perform(setter, with: NSNumber(value: on))
    }
}
