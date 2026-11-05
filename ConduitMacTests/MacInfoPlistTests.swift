import XCTest

/// Keys the Mac `Info.plist` must carry because merged upstream code needs them.
final class MacInfoPlistTests: XCTestCase {
    private func plist(_ relativePath: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(value as? [String: Any])
    }

    /// Upstream added the key with #833: without it, macOS shows no reason when Conduit first reaches a Hermes
    /// server on the local network. The Mac keeps upstream's text.
    func testLocalNetworkUsageDescriptionIsUpstreams() throws {
        let key = "NSLocalNetworkUsageDescription"
        let mac = try XCTUnwrap(try plist("ConduitMac/Resources/Info.plist")[key] as? String)
        let upstream = try XCTUnwrap(try plist("Conduit/Info.plist")[key] as? String)
        XCTAssertFalse(mac.isEmpty)
        XCTAssertEqual(mac, upstream)
    }

    /// Upstream #940 reworded the iPhone text: dictation in a language without on-device support is recognized
    /// on Apple's servers (`AppleSpeechDictationRecognizer` sets `requiresOnDeviceRecognition` from
    /// `supportsOnDeviceRecognition`; the Mac compiles it). The Mac text says the same, for the Mac.
    func testSpeechRecognitionUsageDescriptionStatesTheServerCase() throws {
        let key = "NSSpeechRecognitionUsageDescription"
        let mac = try XCTUnwrap(try plist("ConduitMac/Resources/Info.plist")[key] as? String)
        let upstream = try XCTUnwrap(try plist("Conduit/Info.plist")[key] as? String)
        XCTAssertEqual(mac, upstream.replacingOccurrences(of: "iPhone", with: "Mac"))
        XCTAssertTrue(mac.contains("Apple may process your dictation on its servers"))
        XCTAssertFalse(mac.contains("iPhone"))
    }

    /// The microphone key is the Mac's own text and stays.
    func testMicrophoneUsageDescriptionIsTheMacsOwn() throws {
        let mac = try XCTUnwrap(try plist("ConduitMac/Resources/Info.plist")["NSMicrophoneUsageDescription"] as? String)
        XCTAssertEqual(mac, "Conduit uses the microphone for voice conversations with Hermes.")
    }

    // MARK: Localized usage descriptions (Ruling R27)

    /// The 13 shipped languages besides English; English is the value in `Info.plist` itself.
    private static let languages = ["de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"]

    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    /// The usage-description keys the Mac `Info.plist` declares.
    private func macUsageDescriptions() throws -> [String: String] {
        let plist = try plist("ConduitMac/Resources/Info.plist")
        return plist.reduce(into: [:]) { result, pair in
            if pair.key.hasSuffix("UsageDescription"), let value = pair.value as? String { result[pair.key] = value }
        }
    }

    /// `InfoPlist.strings` of one language in the app bundle that is running these tests (the Mac app, the test host).
    private func builtStrings(_ language: String) throws -> [String: String] {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.meswan.hermes.mac", "the test host is the Mac app")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: language),
                                "no InfoPlist.strings for \(language) in the built bundle")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "unreadable InfoPlist.strings for \(language)")
    }

    /// The Mac bundle compiled the iOS catalog before: the Mac showed "iPhone" in 12 languages. No localized value
    /// in the built bundle may name an iPhone.
    func testNoLocalizedValueInTheBuiltMacBundleSaysIPhone() throws {
        for language in ["en"] + Self.languages {
            for (key, value) in try builtStrings(language) {
                XCTAssertFalse(value.contains("iPhone"), "\(language) \(key): \(value)")
            }
        }
    }

    /// Each usage description of the Mac `Info.plist` has a value in English (the plist's own) and in the 13 other
    /// languages, and no other key is localized (the iOS-only keys, such as motion, are not in the Mac bundle).
    func testEveryMacUsageDescriptionHasAValueInAll13Languages() throws {
        let declared = try macUsageDescriptions()
        XCTAssertFalse(declared.isEmpty)
        for language in ["en"] + Self.languages {
            let strings = try builtStrings(language)
            for (key, english) in declared {
                let value = try XCTUnwrap(strings[key], "\(language) has no \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) \(key)")
                if language == "en" {
                    XCTAssertEqual(value, english, "the English value equals Info.plist")
                } else {
                    XCTAssertNotEqual(value, english, "\(language) \(key) is translated")
                }
            }
            XCTAssertEqual(Set(strings.keys), Set(declared.keys), "\(language): only the keys the Mac Info.plist declares")
        }
    }

    /// The source catalog: the same keys as the Mac `Info.plist` (usage descriptions), the English value equal to
    /// the plist, and the twin comment on each key.
    func testTheMacCatalogMatchesTheMacPlistAndCarriesTheTwinComment() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("ConduitMac/Resources/InfoPlist.xcstrings"))
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let declared = try macUsageDescriptions()
        XCTAssertEqual(Set(strings.keys), Set(declared.keys))
        for (key, entry) in strings {
            XCTAssertEqual(entry["comment"] as? String, "Mac twin of Conduit/InfoPlist.xcstrings; keep in sync", key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
            XCTAssertEqual(Set(localizations.keys), Set(["en"] + Self.languages), key)
            let english = (localizations["en"]?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertEqual(english, declared[key], "\(key): English equals Info.plist")
        }
    }
}
