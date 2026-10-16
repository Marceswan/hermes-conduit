import AppKit
import XCTest
@testable import ConduitMac

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class MacChatFindRegistryTests: XCTestCase {
    private var window: NSWindow!
    private var host: FlippedDocument!
    private var nextY: CGFloat = 0

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        window.contentView = host
        nextY = 0
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        host = nil
    }

    /// A message text view. Hosted views are stacked top to bottom in creation
    /// order, so reading order is deterministic; `hosted: false` leaves it free.
    private func textView(_ string: String, width: CGFloat = 300, hosted: Bool = true) -> NSTextView {
        let view = SelectableTextView.makeTextView()
        view.frame = NSRect(x: 0, y: nextY, width: width, height: 40)
        view.string = string
        if hosted {
            host.addSubview(view)
            nextY += 60
        }
        return view
    }

    private func background(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    private func foreground(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    // MARK: colors

    func testBlackTextClearsSevenToOneOnBothHighlightColors() {
        XCTAssertGreaterThanOrEqual(MacChatFindColors.contrast(MacChatFindColors.text, MacChatFindColors.match), 7)
        XCTAssertGreaterThanOrEqual(MacChatFindColors.contrast(MacChatFindColors.text, MacChatFindColors.current), 7)
        XCTAssertGreaterThan(MacChatFindColors.contrast(.white, .black), 20, "the helper reads 21:1 for black on white")
    }

    // MARK: locate

    func testLocateWalksViewsInOrder() {
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 0, counts: [2, 3])?.view, 0)
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 1, counts: [2, 3])?.local, 1)
        let third = MacChatFindRegistry.locate(ordinal: 2, counts: [2, 3])
        XCTAssertEqual(third?.view, 1)
        XCTAssertEqual(third?.local, 0)
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 4, counts: [2, 3])?.local, 2)
        XCTAssertNil(MacChatFindRegistry.locate(ordinal: 5, counts: [2, 3]))
        XCTAssertNil(MacChatFindRegistry.locate(ordinal: -1, counts: [2, 3]))
        XCTAssertNil(MacChatFindRegistry.locate(ordinal: 0, counts: []))
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 0, counts: [0, 1])?.view, 1, "an empty view is skipped")
    }

    // MARK: scroll math

    func testTargetOffsetIsNilWhileTheRectIsInTheComfortableBand() {
        let rect = CGRect(x: 0, y: 300, width: 50, height: 20)
        XCTAssertNil(MacChatFindScroll.targetOffset(rect: rect, offset: 200, viewportHeight: 400, documentHeight: 2000))
    }

    func testTargetOffsetCentersAHitBelowTheViewportAtThirtyFivePercent() {
        let rect = CGRect(x: 0, y: 1000, width: 50, height: 20)
        let y = MacChatFindScroll.targetOffset(rect: rect, offset: 0, viewportHeight: 400, documentHeight: 2000)
        XCTAssertEqual(y ?? -1, 1010 - 140, accuracy: 0.5)
    }

    func testTargetOffsetTreatsTheBarAsCoveringTheTop() {
        let underBar = CGRect(x: 0, y: 210, width: 50, height: 20)
        XCTAssertNotNil(MacChatFindScroll.targetOffset(rect: underBar, offset: 200, viewportHeight: 400, documentHeight: 2000))
    }

    func testTargetOffsetClampsToTheDocument() {
        let top = MacChatFindScroll.targetOffset(rect: CGRect(x: 0, y: 5, width: 10, height: 10), offset: 500, viewportHeight: 400, documentHeight: 2000)
        XCTAssertEqual(top, 0)
        let bottom = MacChatFindScroll.targetOffset(rect: CGRect(x: 0, y: 1990, width: 10, height: 10), offset: 0, viewportHeight: 400, documentHeight: 2000)
        XCTAssertEqual(bottom, 1600)
    }

    func testRevealMovesTheTranscriptScrollViewToTheHit() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        let view = textView(String(repeating: "filler line\n", count: 120) + "the needle is here")
        view.frame = NSRect(x: 0, y: 1000, width: 300, height: 1900)
        document.addSubview(view)   // moves it out of the shared host
        scroll.documentView = document
        let scrollWindow = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        scrollWindow.isReleasedWhenClosed = false
        scrollWindow.contentView = scroll
        defer { scrollWindow.close() }
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let range = (view.string as NSString).range(of: "needle")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
        MacChatFindScroll.reveal(range, in: view)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 1000, "scrolled down to the hit")
        let visible = scroll.contentView.bounds
        let rectInDocument = document.convert(
            view.layoutManager!.boundingRect(
                forGlyphRange: view.layoutManager!.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                in: view.textContainer!
            ),
            from: view
        )
        XCTAssertTrue(visible.intersects(rectInDocument), "the hit is inside the visible rect")
    }

    // MARK: reading order

    func testViewsOfAMessageComeBackInReadingOrder() {
        let lower = textView("lower")
        lower.frame = NSRect(x: 0, y: 200, width: 150, height: 40)
        let upperRight = textView("upper right")
        upperRight.frame = NSRect(x: 200, y: 10, width: 150, height: 40)
        let upperLeft = textView("upper left")
        upperLeft.frame = NSRect(x: 0, y: 10, width: 150, height: 40)
        let registry = MacChatFindRegistry()
        registry.register(lower, messageID: "m")
        registry.register(upperRight, messageID: "m")
        registry.register(upperLeft, messageID: "m")
        XCTAssertEqual(registry.views(for: "m").map(\.string), ["upper left", "upper right", "lower"])
    }

    // MARK: highlighting

    func testContextHighlightsEveryHitAndMarksTheCurrentOne() {
        let registry = MacChatFindRegistry()
        let first = textView("beta one")
        let second = textView("two beta beta")
        registry.register(first, messageID: "m")
        registry.register(second, messageID: "m")
        let current = MacChatFindMatch(messageID: "m", ordinal: 2, range: NSRange(location: 9, length: 4))
        registry.setContext(.init(query: "beta", current: current, searchable: ["m"]))
        let wanted = [(first, 0, MacChatFindColors.match), (second, 4, MacChatFindColors.match), (second, 9, MacChatFindColors.current)]
        for (view, index, color) in wanted {
            XCTAssertEqual(background(view, at: index), color, "\(view.string)@\(index)")
            XCTAssertEqual(foreground(view, at: index), MacChatFindColors.text)
        }
        XCTAssertNil(background(first, at: 5), "text outside a hit is untouched")
    }

    func testMessagesOutsideTheSearchableSetAreLeftAlone() {
        let registry = MacChatFindRegistry()
        let view = textView("beta here")
        registry.register(view, messageID: "tool-card")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["other"]))
        XCTAssertNil(background(view, at: 0))
    }

    func testClearingTheContextRemovesEveryHighlight() {
        let registry = MacChatFindRegistry()
        let view = textView("beta beta")
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        XCTAssertNotNil(background(view, at: 0))
        registry.setContext(nil)
        XCTAssertNil(background(view, at: 0))
        XCTAssertNil(background(view, at: 5))
        XCTAssertNil(foreground(view, at: 0))
    }

    func testChangingTheQueryReplacesTheOldHighlights() {
        let registry = MacChatFindRegistry()
        let view = textView("alpha beta")
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "alpha", current: nil, searchable: ["m"]))
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        XCTAssertNil(background(view, at: 0), "alpha is no longer a hit")
        XCTAssertNotNil(background(view, at: 6))
    }

    func testRegisteringAViewWhileSearchingHighlightsItAtOnce() {
        let registry = MacChatFindRegistry()
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        let late = textView("a beta")
        registry.register(late, messageID: "m")
        XCTAssertNotNil(background(late, at: 2))
    }

    func testReRegisteringAfterNewTextReHighlightsWithoutStaleRanges() {
        let registry = MacChatFindRegistry()
        let view = textView("beta beta beta")
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        view.string = "x beta"
        registry.register(view, messageID: "m")
        XCTAssertNotNil(background(view, at: 2))
        XCTAssertNil(background(view, at: 0))
    }

    func testClearingLeavesLinkRangesWithTheirOriginalTemporaryAttributes() {
        let view = textView("see docs now")
        let docs = (view.string as NSString).range(of: "docs")
        view.textStorage?.addAttributes([.link: URL(string: "https://example.com")!, .foregroundColor: NSColor.systemBlue], range: docs)
        let before = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: docs.location, effectiveRange: nil) as? NSColor
        let registry = MacChatFindRegistry()
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "docs", current: nil, searchable: ["m"]))
        XCTAssertEqual(foreground(view, at: docs.location), MacChatFindColors.text)
        registry.setContext(nil)
        let after = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: docs.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(after, before)
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: docs.location, effectiveRange: nil) as? NSColor, .systemBlue)
    }

    func testATextKit2ViewIsNeverTouched() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))   // TextKit 2 by default
        view.string = "beta"
        XCTAssertNotNil(view.textLayoutManager)
        let registry = MacChatFindRegistry()
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        XCTAssertNotNil(view.textLayoutManager, "still TextKit 2: nothing converted it")
    }

    // MARK: projection vs drawn text (Task 1 deferred points)

    func testApplyClampsRangesPastTheDrawnTextAndReportsWhatItApplied() {
        let view = textView("beta")
        let applied = MacChatFindHighlighter.apply(
            to: view,
            ranges: [NSRange(location: 0, length: 4), NSRange(location: 2, length: 50), NSRange(location: 40, length: 4)],
            current: nil,
            replacing: []
        )
        XCTAssertEqual(applied, [NSRange(location: 0, length: 4), NSRange(location: 2, length: 2)], "clamped, and the range past the end is skipped")
    }

    func testACurrentHitThePositionedViewsDoNotDrawIsSkippedWithoutHighlightingTheWrongText() {
        // The projection counted three hits (an inline media tag parsed as text),
        // the views draw two: ordinal 2 maps to no view.
        let registry = MacChatFindRegistry()
        let first = textView("beta")
        let second = textView("beta")
        registry.register(first, messageID: "m")
        registry.register(second, messageID: "m")
        let phantom = MacChatFindMatch(messageID: "m", ordinal: 2, range: NSRange(location: 5, length: 4))
        registry.setContext(.init(query: "beta", current: phantom, searchable: ["m"]))
        for view in [first, second] {
            XCTAssertEqual(background(view, at: 0), MacChatFindColors.match, "drawn hits stay ordinary")
        }
    }

    func testAHitSpanningTwoRenderedViewsHighlightsEachViewOnlyWithinItsOwnText() {
        // The projection joins blocks with a newline, so "one\ntwo" is a hit there
        // but neither view draws it: nothing is highlighted and nothing crashes.
        let registry = MacChatFindRegistry()
        let first = textView("alpha one")
        let second = textView("two omega")
        registry.register(first, messageID: "m")
        registry.register(second, messageID: "m")
        registry.setContext(.init(query: "one\ntwo", current: nil, searchable: ["m"]))
        XCTAssertNil(background(first, at: 6))
        XCTAssertNil(background(second, at: 0))
    }

    // MARK: lifetime and membership

    func testTheRegistryDoesNotKeepViewsAlive() {
        let registry = MacChatFindRegistry()
        weak var weakView: NSTextView?
        autoreleasepool {
            let view = textView("beta", hosted: false)
            weakView = view
            registry.register(view, messageID: "m")
            XCTAssertEqual(registry.mountedViewCount, 1)
        }
        // AppKit may release a standalone text view on a later run-loop turn.
        XCTAssertTrue(HostedTestSupport.waitUntil { weakView == nil }, "the registry must not keep the view alive")
        XCTAssertEqual(registry.mountedViewCount, 0)
        XCTAssertTrue(registry.views(for: "m").isEmpty)
    }

    func testUnregisterRemovesTheView() {
        let registry = MacChatFindRegistry()
        let view = textView("beta")
        registry.register(view, messageID: "m")
        registry.unregister(view)
        XCTAssertEqual(registry.mountedViewCount, 0)
    }

    func testDidRegisterReportsTheMessage() {
        let registry = MacChatFindRegistry()
        var seen: [String] = []
        registry.didRegister = { seen.append($0) }
        registry.register(textView("a"), messageID: "m1")
        XCTAssertEqual(seen, ["m1"])
    }

    func testContainsRecognisesMessageViewsAndTheirScrollView() {
        let registry = MacChatFindRegistry()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let view = textView("beta")
        document.addSubview(view)
        scroll.documentView = document
        registry.register(view, messageID: "m")
        XCTAssertTrue(registry.contains(view))
        XCTAssertTrue(registry.contains(document), "anything inside the transcript scroll view")
        XCTAssertFalse(registry.contains(NSView()))
        XCTAssertFalse(registry.contains(nil))
    }
}
