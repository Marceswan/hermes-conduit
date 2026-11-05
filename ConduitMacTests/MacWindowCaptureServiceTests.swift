import XCTest
import CoreGraphics
import ImageIO
@testable import ConduitMac

final class MacWindowCaptureServiceTests: XCTestCase {
    private struct Boom: Error {}

    func testCancelWithoutErrorIsCancelled() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: true, pickerError: nil, captureError: nil, hasImage: false), .cancelled)
    }

    func testPickerErrorIsFailureNotCancel() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: Boom(), captureError: nil, hasImage: false), .failed(.pickerFailed))
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: true, pickerError: Boom(), captureError: nil, hasImage: false), .failed(.pickerFailed))
    }

    func testCaptureErrorOrMissingImageIsNoPicture() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: nil, captureError: Boom(), hasImage: false), .failed(.noPicture))
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: nil, captureError: nil, hasImage: false), .failed(.noPicture))
    }

    func testHappyPathProceeds() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: nil, captureError: nil, hasImage: true), .proceed)
    }

    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Incompressible noise so PNG stays large and the JPEG ladder has to run.
    private func noiseImage(_ w: Int, _ h: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<bytes.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testEncodeSmallImageIsPNG() {
        let out = MacWindowCaptureService.encode(solidImage(400, 300), limitBytes: AttachmentSizeLimit.byteLimit(megabytes: 16))
        XCTAssertEqual(out?.isJPEG, false)
    }

    func testEncodeDownscalesBigImageToCap() throws {
        let out = try XCTUnwrap(MacWindowCaptureService.encode(solidImage(6000, 3000), limitBytes: AttachmentSizeLimit.byteLimit(megabytes: 16)))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(out.data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 2560)
    }

    func testEncodeFallsBackToJPEGWhenPNGTooBig() {
        let limit = AttachmentSizeLimit.byteLimit(megabytes: 8)
        let out = MacWindowCaptureService.encode(noiseImage(2000, 1500), limitBytes: limit)
        XCTAssertEqual(out?.isJPEG, true)
        XCTAssertLessThanOrEqual(Int64(out?.data.count ?? .max), limit)
    }

    func testEncodeReturnsNilWhenNothingFits() {
        XCTAssertNil(MacWindowCaptureService.encode(solidImage(400, 300), limitBytes: 10))
    }
}
