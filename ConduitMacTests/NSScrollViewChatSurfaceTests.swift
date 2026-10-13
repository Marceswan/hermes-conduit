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

    /// Bounds, frame and live-scroll notifications are delivered on .main, so
    /// observers run after the current call returns. Let them run.
    private func drainMainQueue() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
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

    // MARK: - Transcript origin

    func testTranscriptOriginYIsTopOfLocatorInFlippedDocument() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let locator = ChatScrollSurfaceLocatorView(engine: ChatScrollEngine())
        document.addSubview(locator)
        locator.frame = NSRect(x: 0, y: 120, width: 300, height: 800)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: locator, engine: nil)
        XCTAssertEqual(surface.transcriptOriginY, 120, accuracy: 1)
    }

    // MARK: - Scroll intent

    func testClassifyScrollProgrammaticTargetIsNotUserIntent() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        surface.setContentOffsetY(500, animated: false)
        drainMainQueue()
        XCTAssertEqual(surface.classifyScroll(newOffsetY: 500), .programmatic)
        XCTAssertEqual(surface.classifyScroll(newOffsetY: 300), .userDiscrete)
    }

    func testClassifyScrollLiveWhileDragging() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        surface.setContentOffsetY(500, animated: false)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        drainMainQueue()
        XCTAssertEqual(surface.classifyScroll(newOffsetY: 300), .live)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        drainMainQueue()
        XCTAssertEqual(surface.classifyScroll(newOffsetY: 300), .userDiscrete)
    }

    func testDiscreteScrollLeavesFollowingMode() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let engine = ChatScrollEngine()
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: engine)
        engine.attach(surface)
        drainMainQueue()
        XCTAssertEqual(engine.mode, .following)
        XCTAssertEqual(surface.contentOffsetY, 1600, accuracy: 1)

        // A wheel notch or scroller click: no willStartLiveScroll is posted.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        drainMainQueue()
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertFalse(engine.isDragging)
    }

    // MARK: - Tracking (R14)

    func testIsTrackingSpansLiveScroll() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        XCTAssertFalse(surface.isTracking)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        drainMainQueue()
        XCTAssertTrue(surface.isTracking)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        drainMainQueue()
        XCTAssertFalse(surface.isTracking)
        XCTAssertFalse(surface.isDecelerating)
    }

    // MARK: - Insets

    func testInsetsAreReadFromScrollView() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        scroll.contentInsets = NSEdgeInsets(top: 30, left: 0, bottom: 20, right: 0)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.insetTop, 30)
        XCTAssertEqual(surface.insetBottom, 20)
        XCTAssertEqual(surface.minOffsetY, -30)
    }

    func testCheckInsetsReportsChangeToEngine() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let engine = ChatScrollEngine()
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: engine)
        engine.attach(surface)
        drainMainQueue()
        XCTAssertFalse(surface.checkInsets(), "no change since the surface was built")

        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        XCTAssertTrue(surface.checkInsets())
        // Following engine re-pins to the bottom, which now includes the inset.
        XCTAssertEqual(surface.contentOffsetY, surface.maxOffsetY, accuracy: 1)
        XCTAssertFalse(surface.checkInsets(), "second call sees no change")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
