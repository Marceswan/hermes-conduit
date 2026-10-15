import Carbon.HIToolbox
import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskHotKeyTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws { HostedTestSupport.dropSuite(suite) }

    private final class FakeRegistrar: MacHotKeyRegistering {
        var registered: [MacHotKey] = []
        var unregisters = 0
        var failure: MacHotKeyRegistrationError?
        var handler: (@MainActor () -> Void)?
        func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws {
            if let failure { throw failure }
            registered.append(key); self.handler = handler
        }
        func unregister() { unregisters += 1; handler = nil }
    }

    private func manager(_ fake: FakeRegistrar, underTest: Bool = false) -> MacQuickAskHotKeyManager {
        MacQuickAskHotKeyManager(registrar: fake, defaults: suite.defaults, isUnderTest: underTest)
    }

    func testDefaultIsOptionShiftSpace() {
        XCTAssertEqual(MacQuickAskHotKey.default.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(MacQuickAskHotKey.default.modifiers, UInt32(optionKey | shiftKey))
    }

    func testStatusMapping() {
        XCTAssertEqual(MacHotKeyRegistrationError.map(-9868), .unavailableOnThisMacOS)
        XCTAssertEqual(MacHotKeyRegistrationError.map(OSStatus(eventHotKeyExistsErr)), .conflict)
        XCTAssertEqual(MacHotKeyRegistrationError.map(-50), .other(-50))
    }

    func testEnabledByDefaultRegistersOnce() {
        let fake = FakeRegistrar()
        let m = manager(fake)
        m.refresh(); m.refresh()
        XCTAssertEqual(fake.registered, [MacQuickAskHotKey.default], "idempotent")
        XCTAssertEqual(m.state, .registered)
        XCTAssertNil(m.unavailableMessage)
    }

    func testHandlerForwardsToOnHotKey() {
        let fake = FakeRegistrar()
        let m = manager(fake)
        var fired = 0
        m.onHotKey = { fired += 1 }
        m.refresh()
        fake.handler?()
        XCTAssertEqual(fired, 1)
    }

    func testDisabledUnregistersAndEnablingRegistersAgain() {
        let fake = FakeRegistrar()
        let m = manager(fake)
        m.refresh()
        suite.defaults.set(false, forKey: MacQuickAskHotKeyManager.enabledKey)
        m.refresh()
        XCTAssertEqual(m.state, .disabled)
        XCTAssertEqual(fake.unregisters, 1)
        suite.defaults.set(true, forKey: MacQuickAskHotKeyManager.enabledKey)
        m.refresh()
        XCTAssertEqual(m.state, .registered)
        XCTAssertEqual(fake.registered.count, 2)
    }

    func testSequoiaFailureIsVisibleAndNonFatal() {
        let fake = FakeRegistrar()
        fake.failure = .unavailableOnThisMacOS
        let m = manager(fake)
        m.refresh()
        XCTAssertEqual(m.state, .unavailable(.unavailableOnThisMacOS))
        XCTAssertNotNil(m.unavailableMessage)
    }

    func testConflictMessageDiffersFromSequoiaMessage() {
        let a = FakeRegistrar(); a.failure = .unavailableOnThisMacOS
        let b = FakeRegistrar(); b.failure = .conflict
        let ma = manager(a), mb = manager(b)
        ma.refresh(); mb.refresh()
        XCTAssertNotEqual(ma.unavailableMessage, mb.unavailableMessage)
    }

    func testRefreshRetriesAfterFailureOnActivation() {
        let fake = FakeRegistrar()
        fake.failure = .conflict
        let m = manager(fake)
        m.refresh()
        fake.failure = nil
        m.refresh()
        XCTAssertEqual(m.state, .registered, "re-register on app activation recovers")
    }

    func testDisablingAfterFailureLeavesNoStaleUnavailableState() {
        let fake = FakeRegistrar()
        fake.failure = .conflict
        let m = manager(fake)
        m.refresh()
        suite.defaults.set(false, forKey: MacQuickAskHotKeyManager.enabledKey)
        m.refresh()
        XCTAssertEqual(m.state, .disabled)
        XCTAssertNil(m.unavailableMessage)
    }

    func testNeverRegistersUnderXCTest() {
        let fake = FakeRegistrar()
        let m = manager(fake, underTest: true)
        m.refresh()
        XCTAssertTrue(fake.registered.isEmpty)
        XCTAssertEqual(m.state, .disabled)
    }
}
