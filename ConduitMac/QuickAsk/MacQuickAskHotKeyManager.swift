import Foundation

enum MacQuickAskHotKeyState: Equatable {
    case disabled
    case registered
    case unavailable(MacHotKeyRegistrationError)
}

@MainActor
final class MacQuickAskHotKeyManager: ObservableObject {
    static let enabledKey = "conduit.mac.quickAsk.enabled"

    @Published private(set) var state: MacQuickAskHotKeyState = .disabled
    var onHotKey: @MainActor () -> Void = {}

    private let registrar: MacHotKeyRegistering
    private let defaults: UserDefaults
    private let isUnderTest: Bool
    private var isShutDown = false
    private var lastEnabled: Bool
    private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?

    init(registrar: MacHotKeyRegistering, defaults: UserDefaults = .standard,
         isUnderTest: Bool = MacDefaults.isRunningUnderXCTest) {
        self.registrar = registrar
        self.defaults = defaults
        self.isUnderTest = isUnderTest
        self.lastEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        // The Chat menu toggle only writes the default. A menu item is not a live
        // view, so do not rely on an onChange there: follow the default itself,
        // and only react when the Quick Ask key actually flipped (a retry per
        // unrelated preference write would re-register a failed hotkey each time).
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled != self.lastEnabled else { return }
                self.refresh()
            }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Idempotent: call at launch, on app activation and when the toggle changes.
    func refresh() {
        lastEnabled = isEnabled
        guard !isShutDown else { return }
        guard !isUnderTest, isEnabled else {
            if state != .disabled { registrar.unregister() }
            state = .disabled
            return
        }
        if state == .registered { return }
        do {
            try registrar.register(MacQuickAskHotKey.default) { [weak self] in self?.onHotKey() }
            state = .registered
        } catch let error as MacHotKeyRegistrationError {
            state = .unavailable(error)
        } catch {
            state = .unavailable(.other(-1))
        }
    }

    /// App termination: release the Carbon hotkey and its event handler now rather
    /// than leave it to process teardown. Final; `refresh()` does nothing after it.
    func shutdown() {
        isShutDown = true
        registrar.unregister()
        state = .disabled
    }

    /// Chat-menu text, nil when nothing is wrong.
    var unavailableMessage: String? {
        guard case .unavailable(let error) = state else { return nil }
        switch error {
        case .unavailableOnThisMacOS:
            return AppLocalization.string("Quick Ask shortcut unavailable on this macOS version. Use Chat > Quick Ask.")
        case .conflict:
            return AppLocalization.string("Quick Ask shortcut is taken by another app. Use Chat > Quick Ask.")
        case .other:
            return AppLocalization.string("Quick Ask shortcut could not be registered. Use Chat > Quick Ask.")
        }
    }
}

extension MacQuickAskHotKeyManager {
    static let shared = MacQuickAskHotKeyManager(registrar: MacCarbonHotKey())
}
