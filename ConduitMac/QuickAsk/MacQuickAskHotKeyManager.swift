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

    init(registrar: MacHotKeyRegistering, defaults: UserDefaults = .standard,
         isUnderTest: Bool = MacDefaults.isRunningUnderXCTest) {
        self.registrar = registrar
        self.defaults = defaults
        self.isUnderTest = isUnderTest
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Idempotent: call at launch, on app activation and when the toggle changes.
    func refresh() {
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
