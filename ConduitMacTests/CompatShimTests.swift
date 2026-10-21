import XCTest
@testable import UIKit
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

    func testAudioSessionRemembersCategoryOptionsForConfiguredChecks() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        XCTAssertTrue(session.categoryOptions.isSuperset(of: [.allowBluetoothHFP]))
        XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker))
        try session.setCategory(.playback, options: [])
        XCTAssertTrue(session.categoryOptions.isEmpty)
        XCTAssertNoThrow(try session.overrideOutputAudioPort(.speaker))
    }

    func testDynamicColorResolvesPerAppearance() throws {
        let color = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0, blue: 0, alpha: 1)
                : UIColor(red: 0, green: 0, blue: 1, alpha: 1)
        }
        func resolved(_ name: NSAppearance.Name) throws -> NSColor {
            var result: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)
            }
            return try XCTUnwrap(result)
        }
        XCTAssertEqual(try resolved(.darkAqua).redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try resolved(.aqua).blueComponent, 1, accuracy: 0.01)
    }

    func testImageRendererProducesRequestedPixelsAndKeepsOrientation() throws {
        let source = UIImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            NSRect(x: 0, y: 2, width: 4, height: 2).fill()   // top half red (AppKit origin is bottom-left)
            NSColor.blue.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 2).fill()
            return true
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let rep = try XCTUnwrap(rendered.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 8)
        XCTAssertEqual(rep.pixelsHigh, 8)
        XCTAssertEqual(rendered.scale, 1, accuracy: 0.001)
        // Bitmap rows run top to bottom: the red half must still be on top.
        let top = try XCTUnwrap(rep.colorAt(x: 4, y: 1)?.usingColorSpace(.sRGB))
        let bottom = try XCTUnwrap(rep.colorAt(x: 4, y: 6)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(top.redComponent, 0.9)
        XCTAssertGreaterThan(bottom.blueComponent, 0.9)
    }

    func testImageRendererPngDataIsAPngOfTheDrawing() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).pngData { context in
            NSColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 8)
        XCTAssertEqual(rep.pixelsHigh, 8)
        let pixel = try XCTUnwrap(rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.greenComponent, pixel.redComponent, "teal, not black or transparent")
        XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01)
    }

    @MainActor
    func testScreenChangedIsPostedWithoutEffectOnMac() {
        // Like layoutChanged: iOS-only, so `post` must accept it and do nothing.
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    func testFontLineHeightPositive() {
        XCTAssertGreaterThan(UIFont.preferredFont(forTextStyle: .body).lineHeight, 0)
    }

    @MainActor
    func testResignFirstResponderClearsFieldFocus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))

        XCTAssertTrue(UIApplication.shared.dismissFocus(in: window))

        let responder = window.firstResponder
        XCTAssertFalse(responder === field)
        XCTAssertFalse((responder as? NSText)?.delegate as? NSTextField === field)
        window.orderOut(nil)
    }

    func testAllowsExternalOpenOnlyForWebMailAndSettings() {
        XCTAssertFalse(UIApplication.allowsExternalOpen(URL(fileURLWithPath: "/Applications/Calculator.app")))
        XCTAssertFalse(UIApplication.allowsExternalOpen(URL(string: "file:///Applications/Calculator.app")!))
        XCTAssertFalse(UIApplication.allowsExternalOpen(URL(string: "myapp://run")!))
        XCTAssertTrue(UIApplication.allowsExternalOpen(URL(string: "https://example.com")!))
        XCTAssertTrue(UIApplication.allowsExternalOpen(URL(string: "HTTP://example.com")!))
        XCTAssertTrue(UIApplication.allowsExternalOpen(URL(string: "mailto:someone@example.com")!))
        XCTAssertTrue(UIApplication.allowsExternalOpen(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        ))
    }

    @MainActor
    func testDisallowedURLIsRefusedWithoutOpening() async {
        let url = URL(string: "file:///Applications/Calculator.app")!
        var reported: Bool?
        UIApplication.shared.open(url) { reported = $0 }
        XCTAssertEqual(reported, false)
        let opened = await UIApplication.shared.open(url)
        XCTAssertFalse(opened)
    }

    func testContentSizeCategoryMapsFromSwiftUI() {
        XCTAssertEqual(UIContentSizeCategory(.large), .large)
        XCTAssertNotEqual(UIContentSizeCategory(.accessibilityExtraLarge), .large)
    }

    func testTraitCollectionCarriesContentSizeCategory() {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(.extraLarge))
        XCTAssertEqual(traits.preferredContentSizeCategory, UIContentSizeCategory(.extraLarge))
        XCTAssertEqual(UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize,
                       UIFont.preferredFont(forTextStyle: .body).pointSize)
    }
}
