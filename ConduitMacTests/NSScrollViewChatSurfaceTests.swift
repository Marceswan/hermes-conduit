import XCTest
import AppKit
@testable import ConduitMac

@MainActor
final class NSScrollViewChatSurfaceTests: XCTestCase {
    private func makeScroll(contentHeight: CGFloat, viewport: CGFloat) -> (NSScrollView, NSView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: viewport))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: contentHeight))
        scroll.documentView = document
        scroll.layoutSubtreeIfNeeded()
        scroll.tile()
        return (scroll, document)
    }

    func testGeometryReadsFromNSScrollView() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        XCTAssertEqual(surface.contentHeight, 2000)
        XCTAssertEqual(surface.viewportHeight, 400, accuracy: 1)
        XCTAssertEqual(surface.contentOffsetY, 0)
    }

    func testSetOffsetMovesClipView() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        surface.setContentOffsetY(1600, animated: false)
        XCTAssertEqual(surface.contentOffsetY, 1600, accuracy: 1)
        XCTAssertEqual(surface.distanceFromBottom, 0, accuracy: 1)
    }

    func testScrolledUpUserIsNotYankedToBottom() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        surface.setContentOffsetY(500, animated: false)
        document.setFrameSize(NSSize(width: 300, height: 2600))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.contentHeight, 2600, accuracy: 1)
        XCTAssertEqual(surface.contentOffsetY, 500, accuracy: 1)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
