import XCTest
import SwiftUI
@testable import ConduitMac

@MainActor
final class ViewTwinTests: XCTestCase {
    func testCameraIsUnavailableOnMac() {
        XCTAssertFalse(CameraCapture.isAvailable)
    }

    func testComposerHeightBounds() {
        XCTAssertGreaterThanOrEqual(ComposerPasteTextView.minimumHeight, 32)
        XCTAssertGreaterThan(ComposerPasteTextView.maximumHeight, ComposerPasteTextView.minimumHeight)
        XCTAssertLessThanOrEqual(ComposerPasteTextView.maximumHeight, 280)
    }

    func testSelectableTextBridgeKeepsText() {
        let bridged = SelectableTextView.bridge(
            AttributedString("hello"),
            defaultFont: .preferredFont(forTextStyle: .body),
            defaultColor: .labelColor,
            linkColor: .linkColor
        )
        XCTAssertEqual(bridged.string, "hello")
    }

    func testWithTraitsAccumulatesBoldAndItalic() {
        let base = NSFont.systemFont(ofSize: 14)
        let styled = base.withTraits(.traitBold).withTraits(.traitItalic)
        XCTAssertTrue(styled.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(styled.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(styled.pointSize, 14)
    }

    func testBridgeAppliesBoldAndLinkColor() throws {
        var value = AttributedString("a b")
        let boldRange = try XCTUnwrap(value.range(of: "b"))
        value[boldRange].inlinePresentationIntent = .stronglyEmphasized
        value[boldRange].link = URL(string: "https://example.com")
        let bridged = SelectableTextView.bridge(
            value, defaultFont: .systemFont(ofSize: 14), defaultColor: .labelColor, linkColor: .systemBlue
        )
        let font = try XCTUnwrap(bridged.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(bridged.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, .systemBlue)
    }

    func testEdgePanAndCameraTwinsConstruct() {
        _ = EdgePanGesture(action: {})
        _ = CameraCapture(onCapture: { _ in })
    }
}
