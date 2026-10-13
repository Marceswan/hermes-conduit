import AppKit

public enum UIUserInterfaceIdiom: Int, Sendable {
    case unspecified = -1, phone = 0, pad = 1, tv = 2, carPlay = 3, mac = 5, vision = 6
}

@MainActor
public final class UIDevice {
    public static let current = UIDevice()
    /// `.pad`: upstream's wide-layout paths (persistent sidebar) key off iPad.
    public let userInterfaceIdiom: UIUserInterfaceIdiom = .pad
    public var name: String { Host.current().localizedName ?? "Mac" }
    public var systemName: String { "macOS" }
    public var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
