import Security
import WebKit
import XCTest
@testable import ConduitMac

/// A frame that says whether it is the main frame. WebKit builds the real
/// one; a test cannot. `-[WKFrameInfo dealloc]` releases an object that a
/// stub never has and traps, so each stub stays alive until the process ends.
final class StubFrameInfo: WKFrameInfo {
    private static var kept: [StubFrameInfo] = []
    private let stubIsMainFrame: Bool

    init(isMainFrame: Bool) {
        stubIsMainFrame = isMainFrame
        super.init()
        Self.kept.append(self)
    }

    override var isMainFrame: Bool { stubIsMainFrame }
}

/// The navigation a delegate is asked about. WebKit builds the real one;
/// a test states the URL, the way the user got there and the frame.
final class StubNavigationAction: WKNavigationAction {
    private let stubRequest: URLRequest
    private let stubType: WKNavigationType
    private let stubFrame: StubFrameInfo?

    init(url: String, type: WKNavigationType, isMainFrame: Bool? = nil) {
        stubRequest = URLRequest(url: URL(string: url)!)
        stubType = type
        stubFrame = isMainFrame.map { StubFrameInfo(isMainFrame: $0) }
        super.init()
    }

    override var request: URLRequest { stubRequest }
    override var navigationType: WKNavigationType { stubType }
    override var targetFrame: WKFrameInfo? { stubFrame }
}

/// Asks a delegate the question WebKit asks before a navigation, and
/// returns the answer it gives.
@MainActor
func decidePolicy(
    _ url: String,
    type: WKNavigationType,
    isMainFrame: Bool? = nil,
    delegate: WKNavigationDelegate
) async -> WKNavigationActionPolicy {
    let action = StubNavigationAction(url: url, type: type, isMainFrame: isMainFrame)
    return await withCheckedContinuation { continuation in
        delegate.webView?(WKWebView(), decidePolicyFor: action) { policy in
            continuation.resume(returning: policy)
        }
    }
}

/// A Keychain that lives in memory. The Mac test host signs with the same
/// service (`com.milim.conduit`) as the real app, so `SystemKeychainBackend`
/// would read and write the user's real login Keychain.
final class IsolatedKeychainBackend: KeychainHelper.Backend {
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
        storage[key] = query[kSecValueData as String] as? Data ?? Data()
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) {
        if let key = key(for: query) { storage[key] = nil }
    }

    func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

extension XCTestCase {
    /// Keeps the test off the user's real Keychain: an in-memory backend until
    /// teardown, then the backend that was in place before. Call it first in
    /// `setUp`.
    func isolateKeychain() {
        let previous = KeychainHelper.backend
        KeychainHelper.useBackendForTesting(IsolatedKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(previous) }
    }
}
