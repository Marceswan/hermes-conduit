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

    func testSwiftUIAmbiguousNodeIsJudgedByLabelWidth() {
        func node(_ label: String, width: CGFloat, id: String) -> HoverElementSnapshot {
            HoverElementSnapshot(role: .button, label: label, imageIdentifier: id, isEnabled: true,
                                 frame: CGRect(x: 0, y: 0, width: width, height: 24))
        }
        // Wide enough to show its label: text button, no tooltip.
        XCTAssertNil(HoverTooltipPolicy.tooltipText(node("Connect", width: 80, id: "")))
        // Narrow with a longer accessibility label: icon or short title, tooltip.
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(node("Send message", width: 30, id: "")), "Send message")
        // Near-square even though the label fits: an icon.
        let square = HoverElementSnapshot(role: .button, label: "Add", imageIdentifier: "", isEnabled: true,
                                          frame: CGRect(x: 0, y: 0, width: 30, height: 28))
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(square), "Add")
        // Symbol-backed is always an icon, whatever the width.
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(node("Send", width: 200, id: "paperplane")), "Send")
    }
}
