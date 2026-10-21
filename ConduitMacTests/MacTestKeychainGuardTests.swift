import XCTest
@testable import ConduitMac

/// No Mac test may reach the user's login Keychain (MacTestKeychainGuard).
final class MacTestKeychainGuardTests: XCTestCase {
    func testTestsNeverStartOnTheSystemKeychain() {
        XCTAssertFalse(KeychainHelper.backend is KeychainHelper.SystemKeychainBackend)
        XCTAssertTrue(KeychainHelper.backend is MacTestKeychainBackend)
    }

    func testARestoredSystemBackendDoesNotLeakIntoTheNextTest() {
        // A tearDown that restores the system backend; the guard replaces it
        // when this test finishes, and testTestsNeverStartOnTheSystemKeychain
        // (any order) still finds memory.
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        XCTAssertTrue(KeychainHelper.backend is KeychainHelper.SystemKeychainBackend)
    }

    func testRegistryWritesStayInMemory() {
        let data = Data("guard".utf8)
        KeychainHelper.saveDashboardRegistryData(data)
        XCTAssertEqual(KeychainHelper.loadDashboardRegistryData(), data)
        MacTestKeychainGuard.isolate()
        XCTAssertNil(KeychainHelper.loadDashboardRegistryData())
    }
}
