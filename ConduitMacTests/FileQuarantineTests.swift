import XCTest
import Darwin
@testable import ConduitMac

final class FileQuarantineTests: XCTestCase {
    private func quarantineValue(of url: URL) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    func testMarkQuarantinedSetsXattr() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quarantine-\(UUID().uuidString).html")
        try Data("<html></html>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileQuarantine.markQuarantined(url)
        let value = try XCTUnwrap(quarantineValue(of: url))
        XCTAssertTrue(value.hasPrefix("0081;"), value)
        XCTAssertTrue(value.hasSuffix(";Conduit;"), value)
    }

    func testMarkQuarantinedThrowsForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try FileQuarantine.markQuarantined(url))
    }
}
