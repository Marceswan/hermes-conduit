import AppKit
import SwiftUI

/// Only the accessibility API upstream reads or posts.
public enum UIAccessibility {
    public static var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var isVoiceOverRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    public struct Notification: Hashable, Sendable {
        let name: String
        public static let announcement = Notification(name: "announcement")
    }

    /// `.announcement` becomes an NSAccessibility announcement. The argument
    /// is a String or NSAttributedString, as on iOS.
    @MainActor
    public static func post(notification: Notification, argument: Any?) {
        guard notification == .announcement else { return }
        let text: String
        switch argument {
        case let string as String: text = string
        case let attributed as NSAttributedString: text = attributed.string
        default: return
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

public extension NSAttributedString.Key {
    /// Queue behind current speech instead of interrupting it. VoiceOver reads
    /// the plain text on Mac; the key is carried so call sites compile.
    static let accessibilitySpeechQueueAnnouncement = NSAttributedString.Key("UIAccessibilitySpeechAttributeQueueAnnouncement")
}
