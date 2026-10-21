import XCTest
import AppKit
import SwiftUI
@testable import UIKit
@testable import ConduitMac

@MainActor
final class SelectableTextViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        isolateKeychain()
    }

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

    // MARK: - Ideal width (#727)

    /// Asked for its ideal width, wrapping text gives its unbroken width, so
    /// a sent bubble fits a short message instead of filling the row.
    func testWrappingTextGivesItsUnbrokenWidthForAnIdealWidthRequest() {
        let view = SelectableTextView(text: "A short message that fits on one line")
        let natural = view.measureNonWrapping()
        for proposal in [nil, .infinity] as [CGFloat?] {
            let size = view.measuredSize(proposalWidth: proposal)
            XCTAssertEqual(size.width, natural.width, "proposal \(String(describing: proposal))")
            XCTAssertEqual(size.height, natural.height, accuracy: 1)
        }
        XCTAssertEqual(view.measuredSize(proposalWidth: 120).width, 120, "a real proposal still wraps")
        XCTAssertGreaterThan(view.measuredSize(proposalWidth: 120).height, natural.height)
    }

    // MARK: - Paragraph styles (keepsParagraphStyles)

    private func styledPair(keeps: Bool) -> (caller: NSParagraphStyle, styled: NSAttributedString) {
        let caller = NSMutableParagraphStyle()
        caller.firstLineHeadIndent = 5
        caller.headIndent = 21
        caller.paragraphSpacing = 7
        caller.lineSpacing = 9
        caller.alignment = .right
        caller.lineBreakMode = .byCharWrapping
        caller.tabStops = [NSTextTab(textAlignment: .natural, location: 21, options: [:])]
        caller.defaultTabInterval = 21
        let text = NSMutableAttributedString(string: "styled\nplain")
        text.addAttribute(.paragraphStyle, value: caller, range: NSRange(location: 0, length: 7))
        let view = SelectableTextView(attributedText: text, lineSpacing: 2, textAlignment: .center, keepsParagraphStyles: keeps)
        return (caller, view.styledText())
    }

    /// Prose runs carry their own spacing, indents and tab stops. The view
    /// leaves a paragraph that has a style exactly as it is, and fills one
    /// that has none with its own values (upstream `applyParagraphStyle`).
    func testKeepsParagraphStylesLeavesTheCallersStyleUntouched() throws {
        let (caller, styled) = styledPair(keeps: true)
        let kept = try XCTUnwrap(styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(kept, caller, "head indent, tab stops, spacing, alignment and line break mode all stay")
        XCTAssertEqual(kept.lineBreakMode, .byCharWrapping)
        let filled = try XCTUnwrap(styled.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(filled.lineSpacing, 2)
        XCTAssertEqual(filled.alignment, .center)
        XCTAssertEqual(filled.lineBreakMode, .byWordWrapping)
    }

    /// The Mac keeps the caller's indents when it replaces the line spacing
    /// and alignment: `MarkdownSelectionFormatter.list` (a Mac region in
    /// MarkdownText.swift) needs its hanging indent to survive. Upstream
    /// replaces the whole style here.
    func testWithoutKeepTheViewsSpacingAndAlignmentReplaceTheCallers() throws {
        let (_, styled) = styledPair(keeps: false)
        let first = try XCTUnwrap(styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(first.lineSpacing, 2)
        XCTAssertEqual(first.alignment, .center)
        XCTAssertEqual(first.headIndent, 21, "Mac difference: the hanging indent stays")
        XCTAssertEqual(first.firstLineHeadIndent, 5)
        XCTAssertEqual(first.paragraphSpacing, 7)
        XCTAssertEqual(first.tabStops.count, 1)
        let second = try XCTUnwrap(styled.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(second.lineSpacing, 2)
        XCTAssertEqual(second.alignment, .center)
    }

    // MARK: - Copy (a prose run)

    private func proseRunText() -> NSAttributedString {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Plan"),
            .paragraph("Alpha **bold**"),
            .unorderedList(["One", "Two"]),
            .orderedList(["Three"]),
        ]
        return MarkdownProseRun.attributedText(
            for: blocks[...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
    }

    /// Copying a run gives what copying its blocks did: blocks a blank line
    /// apart, list items a line apart, each with its marker and a space. The
    /// run's text holds a tab after each marker and one line break between
    /// blocks, which a plain NSTextView would copy as they are.
    @MainActor
    func testCopyOfAProseRunGivesBlankLinesBetweenBlocksAndASpaceAfterMarkers() throws {
        let text = proseRunText()
        XCTAssertEqual(text.string, "Plan\nAlpha bold\n•\tOne\n•\tTwo\n1.\tThree", "one line break between blocks, spaced by the paragraph style")
        let textView = try XCTUnwrap(SelectableTextView.makeTextView() as? SelectableTextView.ProseCopyTextView)
        textView.textStorage?.setAttributedString(text)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("conduit.test.copy.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        textView.pasteboard = pasteboard

        func copied(_ selection: NSRange) -> String? {
            textView.setSelectedRange(selection)
            pasteboard.clearContents()
            textView.copy(nil)
            return pasteboard.string(forType: .string)
        }
        let string = text.string as NSString
        XCTAssertEqual(copied(NSRange(location: 0, length: text.length)), "Plan\n\nAlpha bold\n\n• One\n• Two\n\n1. Three")
        XCTAssertEqual(copied(string.range(of: "bold\n•\tOne")), "bold\n\n• One", "a selection inside the run copies the same way")
        XCTAssertEqual(copied(string.range(of: "\nAlpha bold\n")), "Alpha bold", "breaks at the selection's ends copy as nothing, as a block's own view ended there")

        textView.setSelectedRange(string.range(of: "Alpha"))
        XCTAssertNil(textView.copiedSelection(), "plain text copies as the text view would")
    }

    /// Drag and Services read the selection through `writeSelection`, not `copy`.
    @MainActor
    func testDraggedSelectionOfAProseRunCopiesLikeCopy() throws {
        let text = proseRunText()
        let textView = try XCTUnwrap(SelectableTextView.makeTextView() as? SelectableTextView.ProseCopyTextView)
        textView.textStorage?.setAttributedString(text)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("conduit.test.drag.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        textView.setSelectedRange((text.string as NSString).range(of: "Alpha bold\n•\tOne"))
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "Alpha bold\n\n• One")
    }

    // MARK: - Selection tint (#697)

    private func sRGB(_ color: NSColor?) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    /// A sent bubble is filled with the accent, the colour a selection takes
    /// by default, so a selection there would not show. `MarkdownText` puts
    /// a contrasting tint (black or white) in the environment for it.
    @MainActor
    func testSelectionOnAnAccentSurfaceUsesTheEnvironmentTint() throws {
        let view = SelectableTextView.makeTextView()
        let original = view.selectedTextAttributes[.backgroundColor] as? NSColor

        for (tint, level) in [(NSColor.white, CGFloat(1)), (NSColor.black, CGFloat(0))] {
            SelectableTextView.applySelectionTint(tint, to: view)
            let background = try XCTUnwrap(sRGB(view.selectedTextAttributes[.backgroundColor] as? NSColor))
            XCTAssertEqual(background.red, level, accuracy: 0.01)
            XCTAssertEqual(background.green, level, accuracy: 0.01)
            XCTAssertEqual(background.blue, level, accuracy: 0.01)
            XCTAssertTrue((0.15...0.6).contains(background.alpha), "the tint shows over the bubble and leaves the text readable, alpha \(background.alpha)")
        }

        // The tint the app hands over, resolved for this view's appearance.
        SelectableTextView.applySelectionTint(UIColor.conduitSelectionOnAccent, to: view)
        let onAccent = try XCTUnwrap(sRGB(view.selectedTextAttributes[.backgroundColor] as? NSColor))
        XCTAssertTrue([onAccent.red, onAccent.green, onAccent.blue].allSatisfy { $0 < 0.01 || $0 > 0.99 }, "black or white")

        // No tint: the system selection colour again.
        SelectableTextView.applySelectionTint(nil, to: view)
        XCTAssertEqual(view.selectedTextAttributes[.backgroundColor] as? NSColor, original)
    }

    @MainActor
    func testApplyingTheSameTintTwiceLeavesTheAttributesAlone() {
        let view = SelectableTextView.makeTextView()
        SelectableTextView.applySelectionTint(.white, to: view)
        let first = view.selectedTextAttributes[.backgroundColor] as? NSColor
        SelectableTextView.applySelectionTint(.white, to: view)
        XCTAssertEqual(view.selectedTextAttributes[.backgroundColor] as? NSColor, first)
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
