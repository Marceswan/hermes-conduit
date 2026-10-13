import XCTest
@testable import ConduitMac

final class ShellSmokeTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.meswan.hermes.mac")
    }

    func testMicrophoneUsageStringPresent() {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        XCTAssertFalse((value ?? "").isEmpty)
    }
}
