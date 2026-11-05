@testable import ConduitMac
import XCTest

final class MacV2ShellOffTests: XCTestCase {
    func testV2ShellDefaultsOffOnMac() {
        XCTAssertFalse(V2ShellPreference.defaultValue)
    }

    func testV2ShellReadsOffWhenUnset() {
        // `V2ShellPreference.isOn` reads the standard defaults: put the user's choice back after.
        preserveStandardDefaults(V2ShellPreference.key)
        UserDefaults.standard.removeObject(forKey: V2ShellPreference.key)
        XCTAssertFalse(V2ShellPreference.isOn)
    }
}
