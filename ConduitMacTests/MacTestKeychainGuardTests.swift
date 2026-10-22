import Security
import XCTest
@testable import ConduitMac

/// No Mac test may reach the user's login Keychain (MacTestKeychainGuard).
final class MacTestKeychainGuardTests: XCTestCase {
    /// The backend that `testABackendLeftByATestIsReplacedBeforeTheNextTest` left installed. The Keychain holds
    /// the only strong reference, so it is nil once the guard has replaced it.
    nonisolated(unsafe) private static weak var leftBehind: MacTestKeychainBackend?

    func testTestsNeverStartOnTheSystemKeychain() {
        XCTAssertFalse(KeychainHelper.backend is KeychainHelper.SystemKeychainBackend)
        XCTAssertTrue(KeychainHelper.backend is MacTestKeychainBackend)
        XCTAssertNil(Self.leftBehind, "the backend that an earlier test left installed is gone")
    }

    /// A tearDown that swaps a backend in must not leak into the next test: the guard replaces it when this test
    /// finishes. The test installs a second in-memory backend and never the system one. A task of an earlier
    /// test that is still running would save to the user's login Keychain (the registry of saved dashboards)
    /// while the system backend is installed, however short the time.
    func testABackendLeftByATestIsReplacedBeforeTheNextTest() {
        let intruder = MacTestKeychainBackend()
        Self.leftBehind = intruder
        KeychainHelper.useBackendForTesting(intruder)
        XCTAssertTrue((KeychainHelper.backend as AnyObject) === intruder)
    }

    /// No test installs the system backend, not even to check the guard: a task that still runs from an earlier
    /// test would write the user's real Keychain in that window. This is how "A" and "B" (a.example.com,
    /// b.example.com) came into the user's saved dashboards, before the guard existed.
    func testNoTestInstallsTheSystemBackend() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let needles = ["SystemKeychainBackend" + "()", "SystemKeychainBackend" + "("]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if needles.contains(where: text.contains) { offenders.append(file.lastPathComponent) }
        }
        XCTAssertEqual(offenders.sorted(), [], "use MacTestKeychainBackend; MacTestKeychainGuard installs it")
    }

    /// One in-memory backend serves every test (M3). A second copy can differ from the real Keychain,
    /// so a test can pass on one and fail on the other.
    func testNoTestDeclaresItsOwnKeychainBackend() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let needle = ": KeychainHelper." + "Backend"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            if try String(contentsOf: file, encoding: .utf8).contains(needle) { offenders.append(file.lastPathComponent) }
        }
        XCTAssertEqual(offenders.sorted(), [], "use MacTestKeychainBackend; MacTestKeychainGuard installs it")
    }

    /// Like the system Keychain, `add` refuses an item that exists. `KeychainHelper.save` never relies on an
    /// overwrite there: it updates first and adds only after `errSecItemNotFound`.
    func testTheBackendRefusesADuplicateAddLikeTheSystemKeychain() {
        let backend = MacTestKeychainBackend()
        let query: [String: Any] = [kSecAttrService as String: "s", kSecAttrAccount as String: "a", kSecValueData as String: Data([1])]
        XCTAssertEqual(backend.add(query), errSecSuccess)
        XCTAssertEqual(backend.add(query), errSecDuplicateItem)
    }

    func testSavingARecordTwiceKeepsTheLastValue() {
        KeychainHelper.saveDashboardRegistryData(Data("one".utf8))
        KeychainHelper.saveDashboardRegistryData(Data("two".utf8))
        XCTAssertEqual(KeychainHelper.loadDashboardRegistryData(), Data("two".utf8))
    }

    func testRegistryWritesStayInMemory() {
        let data = Data("guard".utf8)
        KeychainHelper.saveDashboardRegistryData(data)
        XCTAssertEqual(KeychainHelper.loadDashboardRegistryData(), data)
        MacTestKeychainGuard.isolate()
        XCTAssertNil(KeychainHelper.loadDashboardRegistryData())
    }
}
