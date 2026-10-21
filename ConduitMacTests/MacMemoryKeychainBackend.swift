import Foundation
import Security
@testable import ConduitMac

/// A `KeychainHelper.Backend` that keeps every record in memory.
///
/// The Mac test host uses the Keychain service `com.milim.conduit`, the same
/// service as the user's installed app. `KeychainHelper` uses the system
/// backend unless a test installs another one, so a test that builds an
/// `AppState` and saves, switches or signs in can change the user's real
/// records (the saved-dashboards registry, credentials, sessions). A test
/// that can reach `KeychainHelper` installs this backend in `setUp` and puts
/// the system backend back in `tearDown`:
///
///     override func setUp() async throws { MacMemoryKeychainBackend.install() }
///     override func tearDown() async throws { MacMemoryKeychainBackend.restore() }
///
/// Same record semantics as `ConduitTests/InMemoryKeychainBackend.swift`
/// (per-instance storage, scoped by service and account), without the locked
/// phone switch.
final class MacMemoryKeychainBackend: KeychainHelper.Backend {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var storage: [Key: Data] = [:]
    private var accessibilityClasses: [Key: String] = [:]
    private let defaultService = "com.milim.conduit"

    /// Routes `KeychainHelper` to a fresh in-memory store.
    @discardableResult
    static func install() -> MacMemoryKeychainBackend {
        let backend = MacMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        return backend
    }

    /// Puts the system backend back.
    static func restore() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
    }

    private func key(for query: [String: Any]) -> Key? {
        guard let account = query[kSecAttrAccount as String] as? String else { return nil }
        let service = query[kSecAttrService as String] as? String ?? defaultService
        return Key(service: service, account: account)
    }

    func data(for query: [String: Any]) -> Data? {
        guard let key = key(for: query) else { return nil }
        return storage[key]
    }

    func update(_ data: Data, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else { return errSecItemNotFound }
        storage[key] = data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> Int32 {
        guard let key = key(for: query) else { return errSecParam }
        storage[key] = query[kSecValueData as String] as? Data
        accessibilityClasses[key] = query[kSecAttrAccessible as String] as? String
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) {
        if let key = key(for: query) {
            storage.removeValue(forKey: key)
            accessibilityClasses.removeValue(forKey: key)
        }
    }

    func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else { return errSecItemNotFound }
        accessibilityClasses[key] = accessibility as String
        return errSecSuccess
    }

    /// Test diagnostics: whether any record exists for an account.
    func hasAccount(_ account: String) -> Bool {
        storage.keys.contains { $0.account == account }
    }
}
