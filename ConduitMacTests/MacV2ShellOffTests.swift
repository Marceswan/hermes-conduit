@testable import ConduitMac
import XCTest

final class MacV2ShellOffTests: XCTestCase {
    func testV2ShellDefaultsOffOnMac() {
        XCTAssertFalse(V2ShellPreference.defaultValue)
    }

    func testV2ShellReadsOffWhenUnset() {
        UserDefaults.standard.removeObject(forKey: V2ShellPreference.key)
        XCTAssertFalse(V2ShellPreference.isOn)
    }
}
