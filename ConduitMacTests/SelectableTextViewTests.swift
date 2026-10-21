import XCTest
import AppKit
import SwiftUI
@testable import UIKit
@testable import ConduitMac

@MainActor
final class SelectableTextViewTests: XCTestCase {
    func testMeasuredHeightGrowsWhenWidthShrinks() {
        let text = String(repeating: "word ", count: 80)
        let wide = SelectableTextView.measuredHeight(of: NSAttributedString(string: text), width: 600)
        let narrow = SelectableTextView.measuredHeight(of: NSAttributedString(string: text), width: 200)
        XCTAssertGreaterThan(narrow, wide)
    }

    func testTextViewIsSelectableNotEditable() {
        let view = SelectableTextView.makeTextView()
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.drawsBackground)
    }

    func testMaximumLinesTruncates() {
        let text = NSAttributedString(string: String(repeating: "line\n", count: 20))
        let full = SelectableTextView.measuredHeight(of: text, width: 300)
        let capped = SelectableTextView.measuredHeight(of: text, width: 300, maximumNumberOfLines: 2)
        XCTAssertLessThan(capped, full)
    }

    // R11: link clicks go through the coordinator, never NSTextView's NSWorkspace default.

    func testTextViewDelegateIsCoordinatorAfterMake() {
        let coordinator = SelectableTextView.Coordinator()
        XCTAssertTrue(SelectableTextView.makeTextView(delegate: coordinator).delegate === coordinator)
    }

    func testLinkConversionAcceptsURLAndString() {
        let url = URL(string: "https://example.com/a")!
        XCTAssertEqual(SelectableTextView.Coordinator.url(fromLink: url), url)
        XCTAssertEqual(SelectableTextView.Coordinator.url(fromLink: "https://example.com/a"), url)
        XCTAssertNil(SelectableTextView.Coordinator.url(fromLink: 42))
    }

    func testClickedLinkRoutesAllowedURLToOpenerAndReturnsTrue() {
        var opened: [URL] = []
        let coordinator = SelectableTextView.Coordinator { opened.append($0) }
        let handled = coordinator.textView(NSTextView(), clickedOnLink: "https://example.com", at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened, [URL(string: "https://example.com")!])
    }

    func testClickedLinkGoesToCapturedOpenURLActionNotFallback() {
        var fallback: [URL] = []
        var routed: [URL] = []
        let coordinator = SelectableTextView.Coordinator { fallback.append($0) }
        coordinator.openURL = OpenURLAction { url in
            routed.append(url)
            return .handled
        }
        let session = URL(string: "conduit://session/abc")!
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: session, at: 0))
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: "https://example.com", at: 0))
        XCTAssertEqual(routed, [session, URL(string: "https://example.com")!])
        XCTAssertTrue(fallback.isEmpty)
    }

    func testClickedDisallowedLinkReturnsTrueAndDefaultOpenerRefusesIt() {
        let file = URL(string: "file:///Applications/Calculator.app")!
        XCTAssertFalse(UIApplication.allowsExternalOpen(file))
        // Default opener is UIApplication.shared.open, which applies the allowlist.
        let coordinator = SelectableTextView.Coordinator()
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: file, at: 0))
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: "not a url \u{0}", at: 0))
    }

    func testSuppliedFontChangesMeasuredHeightOfUnattributedText() {
        let plain = NSAttributedString(string: String(repeating: "word ", count: 40))
        let small = SelectableTextView(attributedText: plain, font: .systemFont(ofSize: 12))
        let large = SelectableTextView(attributedText: plain, font: .systemFont(ofSize: 28))
        XCTAssertGreaterThan(large.measuredSize(proposalWidth: 300).height, small.measuredSize(proposalWidth: 300).height)
    }

    func testStyledTextFillsMissingFontAndColorButKeepsRunValues() {
        let text = NSMutableAttributedString(string: "ab")
        text.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 1, length: 1))
        let view = SelectableTextView(attributedText: text, font: .systemFont(ofSize: 28), textColor: .blue)
        let styled = view.styledText()
        XCTAssertEqual(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, .systemFont(ofSize: 28))
        XCTAssertEqual(styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .blue)
        XCTAssertEqual(styled.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor, .red)
    }

    func testNonWrappingTextMeasuresNaturalWidth() {
        let view = SelectableTextView(text: "short", wrapsLines: false)
        let size = view.measuredSize(proposalWidth: 1000)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThan(size.width, 200)
    }

    func testUnusableProposalsReturnFiniteSizes() {
        for wraps in [true, false] {
            let view = SelectableTextView(text: "some text here", wrapsLines: wraps)
            for proposal in [nil, .infinity, 0, -5, CGFloat.nan] as [CGFloat?] {
                let size = view.measuredSize(proposalWidth: proposal)
                XCTAssertTrue(size.width.isFinite && size.width > 0, "wraps \(wraps) proposal \(String(describing: proposal))")
                XCTAssertTrue(size.height.isFinite && size.height > 0)
            }
        }
    }

    // MARK: - Prose runs

    /// The unrounded height TextKit 1 lays `text` out to, which is what the
    /// view measures before it rounds up.
    private func rawHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    private func proseHeight(of blocks: ArraySlice<MarkdownBlock>, width: CGFloat) -> CGFloat {
        let text = MarkdownProseRun.attributedText(
            for: blocks,
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
        return rawHeight(of: SelectableTextView(attributedText: text, keepsParagraphStyles: true).styledText(), width: width)
    }

    /// A run is one text view where a stack of block views stood. Each block
    /// view was a paragraph's own height, and the stack spaced them apart:
    /// `Spacing.betweenBlocks` (and a heading's own space above) between
    /// blocks, `Spacing.betweenListItems` between list items. The run's single
    /// text has to add up to the same, whatever the layout engine does with
    /// line spacing between paragraphs: upstream's `gap(_:above:)` assumes
    /// UIKit adds the next paragraph's line spacing above its first line,
    /// where AppKit adds the previous paragraph's under its last line. Checked
    /// pair by pair, so that one gap that is off by a few points cannot hide
    /// behind another. AppKit also lays out a line with line spacing up to a
    /// font `leading` (under 1 pt) short of the line height it gives without
    /// it, which stays inside the 1 pt.
    @MainActor
    func testProseRunHeightMatchesTheBlocksItReplaces() {
        let long = "Bravo paragraph has enough words in it to wrap onto a second line of the chat column at this width, and then some more."
        let item = "Delta item is long enough that it wraps onto another line in the chat column at this width as well"
        let betweenBlocks = MarkdownProseRun.Spacing.betweenBlocks
        let headingGap = betweenBlocks + MarkdownProseRun.Spacing.aboveHeading(level: 3)
        let pairs: [(name: String, first: MarkdownBlock, second: MarkdownBlock, gap: CGFloat)] = [
            ("heading, paragraph", .heading(level: 2, text: "Alpha heading"), .paragraph(long), betweenBlocks),
            ("paragraph, paragraph", .paragraph(long), .paragraph("Hotel closing paragraph."), betweenBlocks),
            ("paragraph, bullet item", .paragraph(long), .unorderedList(["Charlie item"]), betweenBlocks),
            ("paragraph, numbered item", .paragraph("Short."), .orderedList([item]), betweenBlocks),
            ("bullet item, paragraph", .unorderedList([item]), .paragraph(long), betweenBlocks),
            ("numbered item, paragraph", .orderedList(["Foxtrot first"]), .paragraph("Hotel."), betweenBlocks),
            ("bullet item, level 3 heading", .unorderedList([item]), .heading(level: 3, text: "Golf heading"), headingGap),
            ("paragraph, level 3 heading", .paragraph(long), .heading(level: 3, text: "Golf heading"), headingGap),
            ("heading, bullet item", .heading(level: 2, text: "Alpha heading"), .unorderedList(["Charlie item"]), betweenBlocks),
            ("heading, heading", .heading(level: 2, text: "Alpha"), .heading(level: 3, text: "Golf heading"), headingGap),
        ]
        for width in [260, 320, 480] as [CGFloat] {
            for pair in pairs {
                let run = proseHeight(of: [pair.first, pair.second][...], width: width)
                let expected = proseHeight(of: [pair.first][...], width: width)
                    + proseHeight(of: [pair.second][...], width: width)
                    + pair.gap
                XCTAssertEqual(run, expected, accuracy: 1, "\(pair.name) at width \(width): run \(run) pt, blocks \(expected) pt")
            }
            for ordered in [false, true] {
                func list(_ items: [String]) -> MarkdownBlock { ordered ? .orderedList(items) : .unorderedList(items) }
                let run = proseHeight(of: [list(["Charlie item", item])][...], width: width)
                let expected = proseHeight(of: [list(["Charlie item"])][...], width: width)
                    + proseHeight(of: [list([item])][...], width: width)
                    + MarkdownProseRun.Spacing.betweenListItems
                XCTAssertEqual(run, expected, accuracy: 1, "\(ordered ? "numbered" : "bullet") items at width \(width): run \(run) pt, items \(expected) pt")
            }
        }
    }
}
