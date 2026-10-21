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
}
