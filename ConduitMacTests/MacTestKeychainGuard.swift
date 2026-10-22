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
//  (RealDefaultsWatch, TestDefaultsIsolation.swift). While another Conduit
//  runs, the finding is a printed note, not a failure. A failure recorded in
//  testBundleDidFinish is dropped, so the check cannot wait for the bundle to
//  end. At the end the guard removes the defaults suites that no test dropped,
//  and puts back the window frames that AppKit saved for the host's windows.
//

import XCTest
@testable import ConduitMac

@objc(MacTestKeychainGuard)
final class MacTestKeychainGuard: NSObject, XCTestObservation {
    private let realDefaults = RealDefaultsWatch()
    private let windowFrames = StandardDefaultsSnapshot(prefixes: RealDefaultsWatch.appKitWindowKeyPrefixes)

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
        // Added before the test's own teardown blocks, so it runs after them and after tearDown().
        let name = testCase.name
        testCase.addTeardownBlock { [weak self] in
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
