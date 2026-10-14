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

    // MARK: Visible label text (tabs, segments, radio buttons)

    private func item(_ role: NSAccessibility.Role, label: String?, title: String? = nil, value: String? = nil,
                      childTexts: [String] = [], identifier: String? = nil,
                      size: CGSize = CGSize(width: 49, height: 24)) -> HoverElementSnapshot {
        HoverElementSnapshot(role: role, label: label, title: title, value: value, imageIdentifier: identifier,
                             childTexts: childTexts, isEnabled: true,
                             frame: CGRect(origin: .zero, size: size))
    }

    func testTitleValueOrChildTextEqualToLabelSuppressesTheTooltipForEveryRole() {
        for role: NSAccessibility.Role in [.button, .radioButton, .checkBox, .popUpButton, .menuButton, .link] {
            XCTAssertNil(HoverTooltipPolicy.tooltipText(item(role, label: "Sessions", title: "Sessions")), "title, \(role)")
            XCTAssertNil(HoverTooltipPolicy.tooltipText(item(role, label: "Sessions", value: "sessions")), "value, \(role)")
            XCTAssertNil(HoverTooltipPolicy.tooltipText(item(role, label: "Sessions", childTexts: ["Bots", " Sessions "])), "child, \(role)")
        }
    }

    func testVisibleTextThatDiffersFromTheLabelKeepsTheTooltip() {
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(item(.button, label: "Send message", title: "Go")), "Send message")
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(item(.button, label: "Refresh", childTexts: ["12"])), "Refresh")
        // A radio button's value is its 0/1 state, never a caption.
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(item(.checkBox, label: "Mute", value: "1")), "Mute")
    }

    func testSegmentOrTabRadioButtonShowsItsOwnCaption() {
        // AppKit: label is the caption, title and value stay empty.
        XCTAssertNil(HoverTooltipPolicy.tooltipText(item(.radioButton, label: "One")))
        // Too narrow to hold the caption as text: an icon segment, keeps the tooltip.
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(item(.radioButton, label: "Notifications", size: CGSize(width: 24, height: 24))),
                       "Notifications")
        // A SwiftUI symbol-backed node is an icon whatever its width.
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(item(.radioButton, label: "Cron", identifier: "clock")), "Cron")
    }

    func testVisibleLabelHintSuppressesTheTooltipOfASwiftUINode() {
        // 70 x 36 is below the aspect cutoff that tells a text button from an icon by shape.
        let tab = item(.button, label: "Sessions", identifier: HoverTooltipPolicy.visibleLabelIdentifier,
                       size: CGSize(width: 70, height: 36))
        XCTAssertNil(HoverTooltipPolicy.tooltipText(tab))
        XCTAssertEqual(HoverTooltipPolicy.decide(tab, highlightEnabled: true),
                       HoverDecision(tooltip: nil, showsPointingHand: true, highlights: true))
        // Without the hint the same node reads as an icon and repeats its name.
        var icon = tab
        icon.imageIdentifier = "bubble.left"
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(icon), "Sessions")
        // An explicit help string still wins over the hint.
        var withHelp = tab
        withHelp.help = "Show sessions"
        XCTAssertEqual(HoverTooltipPolicy.tooltipText(withHelp), "Show sessions")
    }
}
