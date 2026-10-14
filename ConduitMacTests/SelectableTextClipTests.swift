import XCTest
import AppKit
import SwiftUI
@testable import UIKit
@testable import ConduitMac

/// Regression: the last line of an assistant message was drawn half-clipped.
/// `sizeThatFits` measured with one text engine while the live NSTextView laid
/// the text out with another, so the SwiftUI frame was shorter than the text.
/// These tests host the real `MarkdownText` path and compare the live view's
/// frame with the live engine's own laid-out height.
@MainActor
final class SelectableTextClipTests: XCTestCase {
    private static let source = """
    Based on what you describe, **this could be several things**, and I would not rule out an infection. \
    The [CDC guidance](https://www.cdc.gov/respiratory-viruses/guidance/index.html) lists **when to test**, \
    **when to isolate**, and which **symptoms** need prompt care, so it is worth a read.

    Most people with **mild symptoms** recover at home with rest and fluids, but watch for \
    [warning signs](https://www.cdc.gov/covid/signs-symptoms/index.html) like trouble breathing, \
    **persistent chest pain**, or new confusion. If any of those show up, **seek care right away**.

    Are you having these symptoms now, and do you have a fever, cough, or pronounced fatigue?
    """

    private struct Probe {
        var usesTextKit2: Bool
        var frameHeight: CGFloat
        var frameWidth: CGFloat
        var laidOutHeight: CGFloat
        var measuredHeight: CGFloat
        var lineCount: Int
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let found = findTextView(in: sub) { return found } }
        return nil
    }

    /// Hosts `MarkdownText` at `width` and waits for its text view to lay out.
    /// The caller tears the window down.
    private func hostMessage(
        width: CGFloat,
        textSize: ChatTextSize = .default,
        source: String = SelectableTextClipTests.source,
        openURL: OpenURLAction? = nil
    ) throws -> (NSWindow, NSTextView) {
        let content = MarkdownText(source: source)
            .environment(\.chatTextSize, textSize)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        let window: NSWindow
        if let openURL {
            window = HostedTestSupport.host(content.environment(\.openURL, openURL), size: NSSize(width: width, height: 1600))
        } else {
            window = HostedTestSupport.host(content, size: NSSize(width: width, height: 1600))
        }
        var found: NSTextView?
        let laidOut = HostedTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            found = window.contentView.flatMap { self.findTextView(in: $0) }
            return (found?.frame.height ?? 0) > 0
        }
        guard laidOut, let textView = found else {
            HostedTestSupport.tearDown(window)
            throw XCTSkip("text view never laid out at width \(width)")
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, textView)
    }

    /// Hosts `MarkdownText` at `width`, waits for a laid-out text view and
    /// returns what the live view and its engine report.
    private func probe(
        width: CGFloat,
        textSize: ChatTextSize = .default,
        source: String = SelectableTextClipTests.source
    ) throws -> Probe {
        let (window, textView) = try hostMessage(width: width, textSize: textSize, source: source)
        defer { HostedTestSupport.tearDown(window) }

        let laidOut: CGFloat
        let lines: Int
        let usesTextKit2: Bool
        if let layout = textView.textLayoutManager {
            usesTextKit2 = true
            layout.ensureLayout(for: layout.documentRange)
            laidOut = ceil(layout.usageBoundsForTextContainer.height)
            var count = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                count += fragment.textLineFragments.count
                return true
            }
            lines = count
        } else {
            usesTextKit2 = false
            let manager = try XCTUnwrap(textView.layoutManager)
            let container = try XCTUnwrap(textView.textContainer)
            manager.ensureLayout(for: container)
            laidOut = ceil(manager.usedRect(for: container).height)
            lines = manager.numberOfGlyphs > 0 ? 1 : 0
        }
        let measured = SelectableTextView.measuredHeight(
            of: textView.attributedString(), width: textView.frame.width
        )
        return Probe(
            usesTextKit2: usesTextKit2,
            frameHeight: textView.frame.height,
            frameWidth: textView.frame.width,
            laidOutHeight: laidOut,
            measuredHeight: measured,
            lineCount: lines
        )
    }

    func testLiveTextViewFrameCoversItsLaidOutTextAtChatWidths() throws {
        for width in [600, 760, 900, 1100] as [CGFloat] {
            let p = try probe(width: width)
            print("CLIPPROBE width=\(width) engine=\(p.usesTextKit2 ? "TextKit2" : "TextKit1") "
                + "frameW=\(p.frameWidth) frameH=\(p.frameHeight) laidOutH=\(p.laidOutHeight) "
                + "measuredH=\(p.measuredHeight) lines=\(p.lineCount)")
            XCTAssertGreaterThanOrEqual(
                p.frameHeight, p.laidOutHeight,
                "width \(width): frame \(p.frameHeight) < laid-out \(p.laidOutHeight) "
                + "(engine \(p.usesTextKit2 ? "TextKit2" : "TextKit1"), measured \(p.measuredHeight))"
            )
        }
    }

    func testFrameCoversLaidOutTextAtEveryChatTextSize() throws {
        for size in ChatTextSize.allCases {
            for width in [600, 900] as [CGFloat] {
                let p = try probe(width: width, textSize: size)
                XCTAssertGreaterThanOrEqual(
                    p.frameHeight, p.laidOutHeight,
                    "size \(size) width \(width): frame \(p.frameHeight) < laid-out \(p.laidOutHeight)"
                )
            }
        }
    }

    /// The engines disagree by a little at every paragraph break, so the shortfall
    /// grows with the number of paragraphs: long answers clip the most.
    func testFrameCoversLaidOutTextOfAMessageWithManyParagraphs() throws {
        let paragraph = "Most people with **mild symptoms** recover at [home](https://example.com/home) with rest, "
            + "and the [CDC guidance](https://example.com/cdc) lists when to seek care."
        let source = (0..<8).map { _ in paragraph }.joined(separator: "\n\n") + "\n\nAre you having these symptoms now?"
        for width in [600, 900] as [CGFloat] {
            let p = try probe(width: width, source: source)
            XCTAssertGreaterThanOrEqual(
                p.frameHeight, p.laidOutHeight,
                "width \(width): frame \(p.frameHeight) < laid-out \(p.laidOutHeight) (engine \(p.usesTextKit2 ? "TextKit2" : "TextKit1"))"
            )
        }
    }

    func testLiveViewUsesTheEngineTheHeightIsMeasuredWith() throws {
        let p = try probe(width: 900)
        XCTAssertFalse(p.usesTextKit2, "measuredHeight uses NSLayoutManager (TextKit 1); the live view must too")
        XCTAssertEqual(p.frameHeight, p.measuredHeight, "frame is exactly the measured height")
        XCTAssertNil(SelectableTextView.makeTextView().textLayoutManager)
    }

    // MARK: Behavior that must survive the engine choice

    func testSelectAllSelectsTheWholeMessage() throws {
        let (window, textView) = try hostMessage(width: 900)
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.selectAll(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: (textView.string as NSString).length))
        XCTAssertTrue(textView.string.hasSuffix("pronounced fatigue?"))
    }

    func testAccessibilityExposesTheWholeTextWithNothingHiddenByTheFrame() throws {
        let (window, textView) = try hostMessage(width: 900)
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertEqual(textView.accessibilityRole(), .textArea)
        XCTAssertEqual(textView.accessibilityValue() as? String, textView.string)
        let visible = textView.accessibilityVisibleCharacterRange()
        XCTAssertEqual(NSMaxRange(visible), (textView.string as NSString).length,
                       "the last character is inside the visible range")
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
    }

    func testFindBarOpensOnAMessageViewMadeByMakeTextView() throws {
        let message = SelectableTextView.makeTextView()
        message.string = "hello find"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        message.frame = scroll.bounds
        scroll.documentView = message
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(window.makeFirstResponder(message))
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        XCTAssertEqual(
            MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: MacFocusRequests()),
            .messageFind
        )
        XCTAssertTrue(HostedTestSupport.waitUntil { scroll.isFindBarVisible })
    }

    func testClickingALinkReachesTheEnvironmentOpenURLAction() throws {
        var opened: [URL] = []
        let (window, textView) = try hostMessage(width: 900, openURL: OpenURLAction { url in
            opened.append(url)
            return .handled
        })
        defer { HostedTestSupport.tearDown(window) }
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let range = (textView.string as NSString).range(of: "CDC guidance")
        XCTAssertNotEqual(range.location, NSNotFound)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        // Hit-test the link's pixels like a click does, then deliver the click.
        // (NSTextView.mouseDown runs a modal tracking loop that never returns
        // for a synthetic event, so the click is delivered via clicked(onLink:at:).)
        let point = NSPoint(x: rect.minX + 4, y: rect.midY)
        let index = textView.characterIndexForInsertion(at: textView.convert(textView.convert(point, to: nil), from: nil))
        XCTAssertTrue(NSLocationInRange(index, range), "hit test at the link's pixels found index \(index), not \(range)")
        let link = try XCTUnwrap(textView.textStorage?.attribute(.link, at: index, effectiveRange: nil))
        textView.clicked(onLink: link, at: index)
        XCTAssertTrue(HostedTestSupport.waitUntil { !opened.isEmpty }, "link click never reached the OpenURLAction")
        XCTAssertEqual(opened.first?.host, "www.cdc.gov")
    }
}
