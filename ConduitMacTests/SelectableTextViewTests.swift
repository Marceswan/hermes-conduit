import XCTest
import AppKit
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

    func testClickedDisallowedLinkReturnsTrueAndDefaultOpenerRefusesIt() {
        let file = URL(string: "file:///Applications/Calculator.app")!
        XCTAssertFalse(UIApplication.allowsExternalOpen(file))
        // Default opener is UIApplication.shared.open, which applies the allowlist.
        let coordinator = SelectableTextView.Coordinator()
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: file, at: 0))
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: "not a url \u{0}", at: 0))
    }
}
