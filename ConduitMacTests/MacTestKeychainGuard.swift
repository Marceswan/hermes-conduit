//
//  MacTestKeychainGuard.swift
//  ConduitMacTests
//
//  The test host is the real Mac app binary, and KeychainHelper's service
//  ("com.milim.conduit") is the same one the user's installed Conduit uses.
//  With SystemKeychainBackend, a test that signs in, switches dashboards or
//  saves credentials reads and rewrites the user's login Keychain. This
//  principal class (INFOPLIST_KEY_NSPrincipalClass in project.yml) installs a
//  fresh in-memory backend before every test case and again after it, so a
//  test's tearDown that restores SystemKeychainBackend cannot leak into the
//  next test. A test may still install its own backend in setUp.
//

import XCTest
@testable import ConduitMac

@objc(MacTestKeychainGuard)
final class MacTestKeychainGuard: NSObject, XCTestObservation {
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
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        Self.isolate()
    }
}
