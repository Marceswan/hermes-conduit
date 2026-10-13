import AppKit
import SwiftUI
import IOKit.pwr_mgt

public struct UIBackgroundTaskIdentifier: Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

public struct UIContentSizeCategory: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let large = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryL")

    /// UIContentSizeCategory(_: SwiftUI.ContentSizeCategory).
    public init(_ category: ContentSizeCategory) {
        switch category {
        case .extraSmall: self.init(rawValue: "UICTContentSizeCategoryXS")
        case .small: self.init(rawValue: "UICTContentSizeCategoryS")
        case .medium: self.init(rawValue: "UICTContentSizeCategoryM")
        case .large: self.init(rawValue: "UICTContentSizeCategoryL")
        case .extraLarge: self.init(rawValue: "UICTContentSizeCategoryXL")
        case .extraExtraLarge: self.init(rawValue: "UICTContentSizeCategoryXXL")
        case .extraExtraExtraLarge: self.init(rawValue: "UICTContentSizeCategoryXXXL")
        case .accessibilityMedium: self.init(rawValue: "UICTContentSizeCategoryAccessibilityM")
        case .accessibilityLarge: self.init(rawValue: "UICTContentSizeCategoryAccessibilityL")
        case .accessibilityExtraLarge: self.init(rawValue: "UICTContentSizeCategoryAccessibilityXL")
        case .accessibilityExtraExtraLarge: self.init(rawValue: "UICTContentSizeCategoryAccessibilityXXL")
        case .accessibilityExtraExtraExtraLarge: self.init(rawValue: "UICTContentSizeCategoryAccessibilityXXXL")
        @unknown default: self.init(rawValue: "UICTContentSizeCategoryL")
        }
    }
}

@MainActor
public final class UIApplication {
    public static let shared = UIApplication()
    public static let openSettingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy"
    public static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    public static let willResignActiveNotification = NSApplication.willResignActiveNotification

    public enum State: Sendable { case active, inactive, background }

    public struct OpenExternalURLOptionsKey: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    private var nextTaskID = 1
    private var idleAssertion: IOPMAssertionID?

    /// Mac apps are not suspended; "background" here means hidden.
    public var applicationState: State {
        if NSApp.isActive { return .active }
        return NSApp.isHidden ? .background : .inactive
    }

    /// Only web, mail, and System Settings links may leave the app. iOS never
    /// lets a link launch local software, so `file:` and app URLs are refused.
    nonisolated public static func allowsExternalOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "x-apple.systempreferences"].contains(scheme)
    }

    public func open(
        _ url: URL,
        options: [OpenExternalURLOptionsKey: Any] = [:],
        completionHandler: ((Bool) -> Void)? = nil
    ) {
        guard Self.allowsExternalOpen(url) else {
            completionHandler?(false)
            return
        }
        completionHandler?(NSWorkspace.shared.open(url))
    }

    @discardableResult
    public func open(_ url: URL, options: [OpenExternalURLOptionsKey: Any] = [:]) async -> Bool {
        guard Self.allowsExternalOpen(url) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// No suspension on Mac, so there is nothing to extend. Tokens stay
    /// valid and distinct because callers compare against `.invalid`.
    public func beginBackgroundTask(
        withName name: String?,
        expirationHandler: (@MainActor @Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        defer { nextTaskID += 1 }
        return UIBackgroundTaskIdentifier(rawValue: nextTaskID)
    }

    public func beginBackgroundTask(expirationHandler: (@MainActor @Sendable () -> Void)?) -> UIBackgroundTaskIdentifier {
        beginBackgroundTask(withName: nil, expirationHandler: expirationHandler)
    }

    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}

    public var isIdleTimerDisabled: Bool {
        get { idleAssertion != nil }
        set {
            if newValue, idleAssertion == nil {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Conduit voice conversation" as CFString,
                    &id
                )
                if result == kIOReturnSuccess { idleAssertion = id }
            } else if !newValue, let id = idleAssertion {
                IOPMAssertionRelease(id)
                idleAssertion = nil
            }
        }
    }

    /// Upstream dismisses focus with `sendAction(resignFirstResponder, to: nil, ...)`.
    /// NSApp.sendAction only calls resignFirstResponder on the responder and leaves
    /// the window's firstResponder unchanged, so the nil-target case is handled here.
    @discardableResult
    public func sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: Any?) -> Bool {
        if action == #selector(NSResponder.resignFirstResponder), target == nil {
            return dismissFocus(in: NSApp.keyWindow)
        }
        return NSApp.sendAction(action, to: target, from: sender)
    }

    func dismissFocus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(nil) ?? false
    }

    public var supportsAlternateIcons: Bool { false }
    public var alternateIconName: String? { nil }

    public func setAlternateIconName(_ name: String?, completionHandler: ((Error?) -> Void)? = nil) {
        completionHandler?(nil)
    }

    public func registerForRemoteNotifications() {}

    public nonisolated var preferredContentSizeCategory: UIContentSizeCategory { .large }
}
