import XCTest
@testable import ConduitMac

@MainActor
final class MacUpdaterTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func testFeedAndPolicyKeys() {
        XCTAssertEqual(info["SUFeedURL"] as? String,
                       "https://github.com/Marceswan/hermes-conduit/releases/latest/download/appcast.xml")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false, "prompt, never install silently")
        XCTAssertEqual((info["SUScheduledCheckInterval"] as? NSNumber)?.intValue, 3600)
    }

    func testPublicKeyIsA32ByteBase64Key() throws {
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        let data = try XCTUnwrap(Data(base64Encoded: key), "SUPublicEDKey must be base64")
        XCTAssertEqual(data.count, 32, "an Ed25519 public key is 32 bytes")
    }

    func testUpdaterDoesNotStartUnderXCTest() {
        XCTAssertTrue(MacDefaults.isRunningUnderXCTest)
        XCTAssertFalse(MacUpdater.shared.started)
    }

    func testCheckForUpdatesIsInTheAppMenu() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(main.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let check = try XCTUnwrap(titles.firstIndex(of: "Check for Updates\u{2026}"), "\(titles)")
        let about = try XCTUnwrap(titles.firstIndex { $0.hasPrefix("About") }, "\(titles)")
        XCTAssertGreaterThan(check, about)
    }
}
