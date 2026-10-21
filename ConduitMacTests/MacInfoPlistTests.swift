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
}
