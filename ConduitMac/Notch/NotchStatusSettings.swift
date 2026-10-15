import Combine
import Foundation

enum NotchMode: String, CaseIterable, Equatable {
    case activeAgents, onlyWhenNeeded, off
}

@MainActor
final class NotchStatusSettings: ObservableObject {
    static let key = "conduit.mac.notchStatus.mode"
    static let surfaceStyleKey = "conduit.mac.notchStatus.surfaceStyle"
    static let shared = NotchStatusSettings()

    @Published var mode: NotchMode {
        didSet { if oldValue != mode { defaults.set(mode.rawValue, forKey: Self.key) } }
    }
    @Published var surfaceStyle: NotchSurfaceStyle {
        didSet { if oldValue != surfaceStyle { defaults.set(surfaceStyle.rawValue, forKey: Self.surfaceStyleKey) } }
    }
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = Self.read(defaults)
        surfaceStyle = Self.readSurfaceStyle(defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.read(self.defaults)
                if current != self.mode { self.mode = current }
                let style = Self.readSurfaceStyle(self.defaults)
                if style != self.surfaceStyle { self.surfaceStyle = style }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private static func read(_ d: UserDefaults) -> NotchMode {
        d.string(forKey: key).flatMap(NotchMode.init(rawValue:)) ?? .activeAgents
    }

    /// Glass is the default, and what an unknown or missing value reads as.
    private static func readSurfaceStyle(_ d: UserDefaults) -> NotchSurfaceStyle {
        d.string(forKey: surfaceStyleKey).flatMap(NotchSurfaceStyle.init(rawValue:)) ?? .glass
    }
}
