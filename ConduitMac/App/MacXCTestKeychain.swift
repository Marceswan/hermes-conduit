//
//  MacXCTestKeychain.swift
//  Conduit
//
//  Under XCTest the Mac test host is the real app binary, and KeychainHelper
//  uses the service ("com.milim.conduit") of the user's installed Conduit.
//  The app installs an in-memory Keychain before anything reads a record, so
//  a test run never reads or rewrites the user's login Keychain.
//  ConduitMacTests/MacTestKeychainGuard.swift renews it around every test.
//

#if DEBUG
import Foundation
import Security

enum MacXCTestKeychain {
    static func isolateIfRunningUnderXCTest() {
        guard MacDefaults.isRunningUnderXCTest else { return }
        KeychainHelper.useBackendForTesting(MacTestKeychainBackend())
    }
}

/// Per-instance Keychain storage keyed by service and account.
final class MacTestKeychainBackend: KeychainHelper.Backend {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var storage: [Key: Data] = [:]

    private func key(for query: [String: Any]) -> Key? {
        guard let account = query[kSecAttrAccount as String] as? String else { return nil }
        return Key(service: query[kSecAttrService as String] as? String ?? "", account: account)
    }

    func data(for query: [String: Any]) -> Data? {
        key(for: query).flatMap { storage[$0] }
    }

    func update(_ data: Data, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else { return errSecItemNotFound }
        storage[key] = data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> Int32 {
        guard let key = key(for: query) else { return errSecParam }
        guard storage[key] == nil else { return errSecDuplicateItem }
        storage[key] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) {
        if let key = key(for: query) { storage.removeValue(forKey: key) }
    }

    func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}
#endif
