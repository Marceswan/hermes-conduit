import XCTest
import UIKit
@testable import ConduitMac

final class CompatShimTests: XCTestCase {
    /// Built at exactly 4x4 pixels. lockFocus would back it at 2x on Retina
    /// displays, so cgImage.width would be 8 instead of 4.
    private func redSquare() -> UIImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 4, height: 4))
    }

    func testImagePNGRoundTrip() throws {
        let data = try XCTUnwrap(redSquare().pngData())
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.cgImage?.width, 4)
    }

    func testImageJPEGEncodes() {
        XCTAssertNotNil(redSquare().jpegData(compressionQuality: 0.8))
    }

    func testSystemNameImage() {
        XCTAssertNotNil(UIImage(systemName: "star"))
    }

    func testPasteboardStringRoundTrip() {
        let board = UIPasteboard(NSPasteboard(name: NSPasteboard.Name("conduit.tests.\(UUID())")))
        board.string = "hello"
        XCTAssertEqual(board.string, "hello")
        XCTAssertTrue(board.hasStrings)
        XCTAssertFalse(board.hasImages)
    }

    func testPasteboardImageRoundTrip() {
        let board = UIPasteboard(NSPasteboard(name: NSPasteboard.Name("conduit.tests.\(UUID())")))
        board.image = redSquare()
        XCTAssertTrue(board.hasImages)
        XCTAssertNotNil(board.image)
    }

    @MainActor
    func testBackgroundTaskTokensAreValidAndDistinct() {
        let first = UIApplication.shared.beginBackgroundTask(withName: "a", expirationHandler: nil)
        let second = UIApplication.shared.beginBackgroundTask(withName: "b", expirationHandler: nil)
        XCTAssertNotEqual(first, .invalid)
        XCTAssertNotEqual(first, second)
        UIApplication.shared.endBackgroundTask(first)
        UIApplication.shared.endBackgroundTask(second)
    }

    @MainActor
    func testIdleTimerTogglesAssertion() {
        UIApplication.shared.isIdleTimerDisabled = true
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        UIApplication.shared.isIdleTimerDisabled = false
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    @MainActor
    func testDeviceIdiomIsPadSoWideLayoutsApply() {
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .pad)
    }

    func testAudioSessionCallsSucceed() throws {
        let session = AVAudioSession.sharedInstance()
        XCTAssertNoThrow(try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker]))
        XCTAssertNoThrow(try session.setActive(true, options: []))
    }

    func testFontLineHeightPositive() {
        XCTAssertGreaterThan(UIFont.preferredFont(forTextStyle: .body).lineHeight, 0)
    }
}
