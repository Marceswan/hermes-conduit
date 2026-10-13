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
}
