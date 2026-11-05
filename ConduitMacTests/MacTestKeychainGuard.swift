//
//  MacTestKeychainGuard.swift
//  ConduitMacTests
//
//  The test host is the real Mac app binary. Its Keychain service
//  ("com.milim.conduit") and its defaults domain are the ones the user's
//  installed Conduit uses. Two guards keep a test run off the user's data.
//
//  Keychain. With SystemKeychainBackend, a test that signs in, switches
//  dashboards or saves credentials reads and rewrites the user's login
//  Keychain. This principal class (INFOPLIST_KEY_NSPrincipalClass in
//  project.yml) installs a fresh in-memory backend (MacTestKeychainBackend)
//  before every test case and again after it, so a test never installs its
//  own and a tearDown that restores SystemKeychainBackend cannot leak into the
//  next test.
//
//  Defaults. It reads the keys the app owns in the user's real defaults
//  domain when the bundle loads. A teardown block that it adds to every test
//  compares them again, and a changed value fails that test and names the key
//  (RealDefaultsWatch, TestDefaultsIsolation.swift). The guard looks for
//  another Conduit at bundle start, at the start of each test and at its end.
//  Once it has seen one, a finding is a printed note and not a failure for
//  the rest of the bundle. A failure recorded in testBundleDidFinish is
//  dropped, so the check cannot wait for the bundle to end. At the end the
//  guard removes the defaults suites that no test dropped, and puts back the
//  window frames that AppKit saved for the host's windows.
//

import XCTest
@testable import ConduitMac

@objc(MacTestKeychainGuard)
final class MacTestKeychainGuard: NSObject, XCTestObservation {
    private let realDefaults = RealDefaultsWatch()
    private let windowFrames = StandardDefaultsSnapshot(prefixes: RealDefaultsWatch.appKitWindowKeyPrefixes)

    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var checked = 0
    nonisolated(unsafe) private static var currentName: String?

    /// How often the defaults check was added to a test and how often it ran, for the test that proves the wiring.
    static var wiring: (testsStarted: Int, checksRun: Int, currentTest: String?) {
        counterLock.lock()
        defer { counterLock.unlock() }
        return (started, checked, currentName)
    }

    override init() {
        super.init()
        Self.isolate()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    static func isolate() {
        KeychainHelper.useBackendForTesting(MacTestKeychainBackend())
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        Self.isolate()
        realDefaults.testStarted()
        let name = testCase.name
        Self.counterLock.lock()
        Self.started += 1
        Self.currentName = name
        Self.counterLock.unlock()
        // XCTest runs teardown blocks in reverse order after the test method returns and before tearDown().
        // This one is added first, so it runs after the test's own teardown blocks. A test that puts a key back
        // in tearDown() is too late: use preserveStandardDefaults(_:), which restores in a teardown block.
        testCase.addTeardownBlock { [weak self] in
            Self.counterLock.lock()
            Self.checked += 1
            Self.counterLock.unlock()
            guard let finding = self?.realDefaults.testFinished(name) else { return }
            if finding.isFailure { XCTFail(finding.message) } else { print(finding.message) }
        }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        Self.isolate()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        TestDefaultsSuites.removeLeaked()
        MacXCTestDefaults.removeTestSuites()
        windowFrames.restore()
    }
}
