import AppKit

/// Only the accessibility flags upstream's non-view code reads.
public enum UIAccessibility {
    public static var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
