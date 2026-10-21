import AppKit
import XCTest
@testable import ConduitMac

/// `BoundedRemoteImage` (upstream #892) is shared code that runs on the Mac through the `UIImage` shim
/// (`NSImage`): web pictures in replies and Artifacts tiles must decode within bounds here too.
final class BoundedRemoteImageMacTests: XCTestCase {
    private func png(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testDecodeDownsamplesToTheShownSize() throws {
        let outcome = BoundedRemoteImage.decode(try png(width: 400, height: 200), maxPixelSize: 100)
        guard case .image(let image) = outcome else { return XCTFail("expected an image, got \(outcome)") }
        // The pixels, not the NSImage point size: callers scale the image to fit (`.resizable().scaledToFit()`).
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(max(cgImage.width, cgImage.height), 100, "the longer side is the shown size, not the 400 px source")
        XCTAssertEqual(min(cgImage.width, cgImage.height), 50, "the aspect ratio is kept")
    }

    func testDecodeRefusesAPictureWhoseHeaderClaimsTooManyPixels() throws {
        let outcome = BoundedRemoteImage.decode(try png(width: 400, height: 200), maxPixelSize: 100, maxPixelCount: 1_000)
        guard case .tooLarge = outcome else { return XCTFail("expected tooLarge, got \(outcome)") }
    }

    func testDecodeOfNonImageDataIsUnavailable() {
        let outcome = BoundedRemoteImage.decode(Data("<html>error page</html>".utf8), maxPixelSize: 100)
        guard case .unavailable = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
    }

    func testLoadMapsDownloadResultsAndCachesAPicture() async throws {
        let data = try png(width: 64, height: 64)
        let url = URL(string: "https://example.test/\(UUID().uuidString).png")!
        var downloads = 0
        let response = URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)

        let first = await BoundedRemoteImage.load(url, maxPixelSize: 32) { _ in
            downloads += 1
            return .downloaded(data, response)
        }
        guard case .image = first else { return XCTFail("expected an image, got \(first)") }
        let second = await BoundedRemoteImage.load(url, maxPixelSize: 32) { _ in
            downloads += 1
            return .failed
        }
        guard case .image = second else { return XCTFail("a loaded picture is served from the cache, got \(second)") }
        XCTAssertEqual(downloads, 1)

        let other = URL(string: "https://example.test/\(UUID().uuidString).png")!
        let tooLarge = await BoundedRemoteImage.load(other, maxPixelSize: 32) { _ in .tooLarge }
        guard case .tooLarge = tooLarge else { return XCTFail("expected tooLarge, got \(tooLarge)") }
        let failed = await BoundedRemoteImage.load(other, maxPixelSize: 32) { _ in .failed }
        guard case .unavailable = failed else { return XCTFail("expected unavailable, got \(failed)") }
    }
}
