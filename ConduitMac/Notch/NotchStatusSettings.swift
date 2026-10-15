import Combine
import Foundation

enum NotchMode: String, CaseIterable, Equatable {
    case activeAgents, onlyWhenNeeded, off
}

@MainActor
final class NotchStatusSettings: ObservableObject {
    static let key = "conduit.mac.notchStatus.mode"
    static let shared = NotchStatusSettings()

    @Published var mode: NotchMode {
        didSet { if oldValue != mode { defaults.set(mode.rawValue, forKey: Self.key) } }
    }
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = Self.read(defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.read(self.defaults)
                if current != self.mode { self.mode = current }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private static func read(_ d: UserDefaults) -> NotchMode {
        d.string(forKey: key).flatMap(NotchMode.init(rawValue:)) ?? .activeAgents
    }
}
