import XCTest
@testable import ConduitMac

/// LC-B F3: a Developer ID build that updates itself with Sparkle is not an App Store copy.
final class MacInstallSourceTests: XCTestCase {
    func testNoReceiptAndSparkleIsADirectDownload() {
        XCTAssertTrue(AppInstallSource.isMacDirectDownload(receiptExists: false, sparkleFeed: "https://example.com/appcast.xml"))
    }

    func testAReceiptIsNotADirectDownload() {
        XCTAssertFalse(AppInstallSource.isMacDirectDownload(receiptExists: true, sparkleFeed: "https://example.com/appcast.xml"))
    }

    func testNoSparkleFeedIsNotADirectDownload() {
        XCTAssertFalse(AppInstallSource.isMacDirectDownload(receiptExists: false, sparkleFeed: nil))
        XCTAssertFalse(AppInstallSource.isMacDirectDownload(receiptExists: false, sparkleFeed: ""))
    }

    /// A self-updating direct download gets stable releases only, as the App Store does; TestFlight and Xcode
    /// builds follow main.
    func testDirectDownloadFollowsStablePluginVersionsUnderAutomatic() {
        XCTAssertFalse(NotifierPluginNoticeChannel.automatic.followsMain(installedFrom: .macDirect))
        XCTAssertTrue(NotifierPluginNoticeChannel.everyVersion.followsMain(installedFrom: .macDirect))
        XCTAssertFalse(NotifierPluginNoticeChannel.stableOnly.followsMain(installedFrom: .macDirect))
        XCTAssertTrue(NotifierPluginNoticeChannel.automatic.followsMain(installedFrom: .xcode))
    }

    func testRawValueRoundTripsThroughDefaults() {
        XCTAssertEqual(AppInstallSource(rawValue: AppInstallSource.macDirect.rawValue), .macDirect)
    }

    func testTheSentenceExistsInAllLanguagesAndDoesNotSayAppStoreCopy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conduit/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings["Mac.InstallSource.DirectDownload"] as? [String: Any])
        let locs = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
        XCTAssertEqual(Set(locs.keys), ["en", "de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"])
        let appStore = try XCTUnwrap(strings["This copy of Conduit is from the App Store."] as? [String: Any])
        let appStoreLocs = try XCTUnwrap(appStore["localizations"] as? [String: [String: Any]])
        for (lang, loc) in locs {
            let value = (loc["stringUnit"] as? [String: Any])?["value"] as? String
            let old = (appStoreLocs[lang]?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertFalse(value?.isEmpty ?? true, lang)
            XCTAssertNotEqual(value, old, lang)
        }
    }

    func testPluginPageShowsTheDirectDownloadSentence() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conduit/Views/ConduitPluginViews.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("case .macDirect: AppLocalization.string(\"Mac.InstallSource.DirectDownload\")"))
    }
}
