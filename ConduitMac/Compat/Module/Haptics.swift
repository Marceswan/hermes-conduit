import Foundation

/// Macs have no haptic engine for app feedback; these keep call sites compiling.
public final class UIImpactFeedbackGenerator {
    public enum FeedbackStyle: Int, Sendable { case light, medium, heavy, soft, rigid }
    public init(style: FeedbackStyle = .medium) {}
    public func prepare() {}
    public func impactOccurred() {}
    public func impactOccurred(intensity: CGFloat) {}
}

public final class UINotificationFeedbackGenerator {
    public enum FeedbackType: Int, Sendable { case success, warning, error }
    public init() {}
    public func prepare() {}
    public func notificationOccurred(_ type: FeedbackType) {}
}

public final class UISelectionFeedbackGenerator {
    public init() {}
    public func prepare() {}
    public func selectionChanged() {}
}
