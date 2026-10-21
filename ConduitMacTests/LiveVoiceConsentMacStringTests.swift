import XCTest
@testable import ConduitMac

/// The "Take back" button of the live voice consent row (`LiveVoiceConsentViews.swift`, upstream #827)
/// has a hint "Ends a running call on this iPhone. The next call asks again." On Mac the hint names the
/// Mac. The Mac string is the Mac-owned key `Mac.LiveVoiceConsent.TakeBackHint` (Ruling R27 pattern:
/// upstream's translations with "iPhone" changed to "Mac"). The iPhone string stays in the `#else`
/// branch of an `#if os(macOS) // MAC:` region.
final class LiveVoiceConsentMacStringTests: XCTestCase {
    private let key = "Mac.LiveVoiceConsent.TakeBackHint"
    private let upstreamKey = "Ends a running call on this iPhone. The next call asks again."
    private let languages = ["de", "en", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func strings() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Conduit/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(object?["strings"] as? [String: Any])
    }

    private func values(_ entry: Any?) throws -> [String: String] {
        let localizations = try XCTUnwrap((entry as? [String: Any])?["localizations"] as? [String: Any])
        var result: [String: String] = [:]
        for (language, body) in localizations {
            let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any]
            result[language] = unit?["value"] as? String
        }
        return result
    }

    func testTheMacKeyHasAllLanguagesAndNamesNoIPhone() throws {
        let mac = try values(try strings()[key])
        XCTAssertEqual(Set(mac.keys), Set(languages), "English and the 13 other languages")
        XCTAssertEqual(mac["en"], "Ends a running call on this Mac. The next call asks again.")
        for language in languages {
            let value = try XCTUnwrap(mac[language], language)
            XCTAssertFalse(value.contains("iPhone"), "\(language): \(value)")
            XCTAssertTrue(value.contains("Mac"), "\(language): \(value)")
            if language != "en" {
                XCTAssertNotEqual(value, mac["en"], "\(language) is translated")
            }
        }
    }

    func testTheKeyResolvesInTheMacBundle() {
        // The argument is a literal: `AppLocalization.string` takes a `String.LocalizationValue`.
        XCTAssertNotEqual(AppLocalization.string("Mac.LiveVoiceConsent.TakeBackHint"), key,
                          "the key is missing from the compiled catalog")
    }

    func testTheViewUsesTheMacKeyOnlyUnderTheMacRegion() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Conduit/Views/LiveVoiceConsentViews.swift"), encoding: .utf8)
        let macKey = try XCTUnwrap(source.range(of: "\"\(key)\""), "the Mac key")
        // The region around the key, wherever it sits in the file: the nearest `#if` above the key,
        // the `#else` after it, and the `#endif` after upstream's text.
        let region = try XCTUnwrap(
            source.range(of: "#if os(macOS) // MAC:", options: .backwards, range: source.startIndex..<macKey.lowerBound),
            "the Mac region above the Mac key")
        let otherwise = try XCTUnwrap(
            source.range(of: "#else // MAC:", range: macKey.upperBound..<source.endIndex), "the #else after the Mac key")
        let upstreamText = try XCTUnwrap(
            source.range(of: "\"\(upstreamKey)\"", range: otherwise.upperBound..<source.endIndex),
            "upstream's text after the #else")
        let end = try XCTUnwrap(
            source.range(of: "#endif // MAC:", range: upstreamText.upperBound..<source.endIndex), "the #endif")
        XCTAssertTrue(region.lowerBound < macKey.lowerBound)
        XCTAssertTrue(macKey.upperBound <= otherwise.lowerBound)
        XCTAssertTrue(otherwise.upperBound <= upstreamText.lowerBound)
        XCTAssertTrue(upstreamText.upperBound <= end.lowerBound)
        // No other `#if` sits between the region start and the end: one region, not several.
        let inner = String(source[region.upperBound..<end.lowerBound])
        XCTAssertFalse(inner.contains("#if "), "one region")
    }
}
