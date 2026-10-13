import XCTest
import AppKit
@testable import ConduitMac

final class HoverTooltipPolicyTests: XCTestCase {
    private func el(_ role: NSAccessibility.Role?, label: String? = nil, title: String? = nil,
                    help: String? = nil, enabled: Bool = true) -> HoverElementSnapshot {
        HoverElementSnapshot(role: role, label: label, title: title, help: help,
                             isEnabled: enabled, frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    }

    func testIconButtonShowsLabelPointerAndHighlight() {
        let d = HoverTooltipPolicy.decide(el(.button, label: "Close Settings"), highlightEnabled: true)
        XCTAssertEqual(d, HoverDecision(tooltip: "Close Settings", showsPointingHand: true, highlights: true))
    }

    func testHelpWinsOverLabel() {
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.button, label: "Gear", help: "Open settings"), highlightEnabled: false).tooltip, "Open settings")
    }

    func testVisibleTitleEqualToLabelHasNoTooltip() {
        XCTAssertNil(HoverTooltipPolicy.decide(el(.button, label: "Connect", title: "connect"), highlightEnabled: true).tooltip)
    }

    func testDisabledButtonGetsTooltipButNoPointer() {
        let d = HoverTooltipPolicy.decide(el(.button, label: "Send", enabled: false), highlightEnabled: true)
        XCTAssertEqual(d.tooltip, "Send")
        XCTAssertFalse(d.showsPointingHand)
        XCTAssertFalse(d.highlights)
    }

    func testLabelledImageGetsTooltipOnly() {
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.image, label: "Bot avatar"), highlightEnabled: true),
                       HoverDecision(tooltip: "Bot avatar", showsPointingHand: false, highlights: false))
    }

    func testTextAndGroupsGetNothing() {
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.staticText, label: "Hello"), highlightEnabled: true), .none)
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.group, label: "Row"), highlightEnabled: true), .none)
        XCTAssertEqual(HoverTooltipPolicy.decide(el(nil), highlightEnabled: true), .none)
    }

    func testHighlightRespectsSetting() {
        XCTAssertFalse(HoverTooltipPolicy.decide(el(.button, label: "X"), highlightEnabled: false).highlights)
    }

    func testLongLabelIsTruncatedWithASCIIEllipsis() {
        let long = String(repeating: "a", count: 300)
        let tip = HoverTooltipPolicy.decide(el(.button, label: long), highlightEnabled: false).tooltip
        XCTAssertEqual(tip?.count, HoverTooltipPolicy.maxLength)
        XCTAssertTrue(tip?.hasSuffix("...") ?? false)
    }

    func testSwiftUITextButtonWithEmptyImageIdentifierHasNoTooltip() {
        var text = el(.button, label: "Connect")
        text.imageIdentifier = ""
        XCTAssertNil(HoverTooltipPolicy.decide(text, highlightEnabled: true).tooltip)
        var icon = el(.button, label: "Send")
        icon.imageIdentifier = "paperplane"
        XCTAssertEqual(HoverTooltipPolicy.decide(icon, highlightEnabled: true).tooltip, "Send")
    }
}
