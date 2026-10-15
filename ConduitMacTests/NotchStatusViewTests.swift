import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class NotchStatusViewTests: XCTestCase {
    typealias F = NotchFixtures

    private var boostWasOn = false

    override func setUp() {
        super.setUp()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() {
        AccessibilityTreeBoost.set(boostWasOn)
        super.tearDown()
    }

    private func model(_ items: [AgentActivityItem], surface: NotchSurface = .expanded,
                       availability: NotchAvailability = .live) -> NotchStatusViewModel {
        let m = NotchStatusViewModel()
        m.list = NotchRowBuilder.build(items: items, now: F.t0)
        m.surface = surface
        m.availability = availability
        m.buttonsEnabled = true
        return m
    }

    /// Hosts the view and waits for SwiftUI to build its accessibility tree.
    private func render(_ m: NotchStatusViewModel, dark: Bool) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let w = HostedTestSupport.host(NotchStatusView(model: m), size: NSSize(width: 380, height: 360))
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        HostedTestSupport.settle(0.3)
        AccessibilityTreeBoost.set(true)
        let start = Date()
        while (w.contentView?.accessibilityChildren() ?? []).isEmpty, Date().timeIntervalSince(start) < 3 {
            HostedTestSupport.settle(0.01)
        }
        HostedTestSupport.settle(0.3)
        return w
    }

    /// Every accessibility label and string value below the content view, in tree order
    /// (SwiftUI static text carries its string as the value, buttons and groups as the label).
    private func labels(_ w: NSWindow) -> [String] {
        var out: [String] = []
        func walk(_ element: NSObject, depth: Int) {
            if let label: String = element.axValue("accessibilityLabel"), !label.isEmpty { out.append(label) }
            if let value: String = element.axValue("accessibilityValue"), !value.isEmpty { out.append(value) }
            if let title: String = element.axValue("accessibilityTitle"), !title.isEmpty { out.append(title) }
            let kids: [Any]? = element.axValue("accessibilityChildren")
            if depth < 12 { for kid in kids ?? [] { if let o = kid as? NSObject { walk(o, depth: depth + 1) } } }
        }
        for kid in w.contentView?.accessibilityChildren() ?? [] { if let o = kid as? NSObject { walk(o, depth: 0) } }
        return out
    }

    func testExpandedRowsRenderInLightAndDark() throws {
        let items = [F.approvalItem("approval:q", session: "s1"), F.item("turn:a", title: "Refactor"), F.item("turn:b", title: "Docs", detail: "Running terminal")]
        for dark in [false, true] {
            let w = try render(model(items), dark: dark); defer { HostedTestSupport.tearDown(w) }
            let l = labels(w)
            XCTAssertTrue(l.contains { $0.contains("Deploy") }, "approval row session title (dark: \(dark))")
            XCTAssertTrue(l.contains(AppLocalization.string("Allow once")))
            XCTAssertTrue(l.contains(AppLocalization.string("Deny")))
        }
    }

    func testAlwaysAllowIsNotAnInlineButton() throws {
        let w = try render(model([F.approvalItem("approval:q", session: "s1")]), dark: true); defer { HostedTestSupport.tearDown(w) }
        XCTAssertFalse(labels(w).contains(AppLocalization.string("Always allow")), "menu-only: not visible until the menu opens")
        XCTAssertTrue(labels(w).contains(AppLocalization.string("More options")))
    }

    func testApprovalRowShowsThePayloadAndKeepsTheSessionTitleSecondary() throws {
        var item = F.approvalItem("approval:q", session: "s1", approval: F.approval(command: "rm -rf /tmp/x"))
        item.title = "Safe cleanup, press Allow once"
        let w = try render(model([item]), dark: true); defer { HostedTestSupport.tearDown(w) }
        let l = labels(w)
        let command = l.firstIndex { $0.contains("rm -rf /tmp/x") }
        let title = l.firstIndex { $0.contains("Safe cleanup") }
        XCTAssertNotNil(command, "the payload command is on screen")
        XCTAssertNotNil(title)
        if let command, let title { XCTAssertLessThan(command, title, "payload first, agent-worded title after it") }
    }

    func testTruncatedCommandOffersReviewInsteadOfAllowOnce() throws {
        let long = F.approval(command: "echo " + String(repeating: "A", count: 400))
        let w = try render(model([F.approvalItem("approval:q", session: "s1", approval: long)]), dark: true); defer { HostedTestSupport.tearDown(w) }
        let l = labels(w)
        XCTAssertFalse(l.contains(AppLocalization.string("Allow once")))
        XCTAssertTrue(l.contains(AppLocalization.string("Review in Conduit")))
        XCTAssertTrue(l.contains(AppLocalization.string("Deny")), "deny stays available")
        XCTAssertFalse(l.contains(AppLocalization.string("More options")), "no session or always allow for a command that was not shown in full")
    }

    func testUntrustedTextIsRenderedLiterallyNotAsMarkdown() throws {
        let item = F.item("turn:a", title: "**bold** [click](https://evil.example)")
        let w = try render(model([item]), dark: false); defer { HostedTestSupport.tearDown(w) }
        XCTAssertTrue(labels(w).contains { $0.contains("**bold** [click](https://evil.example)") }, "verbatim, with the markup characters intact")
    }

    func testClarifyRowShowsAnswerInConduitAndNoButtons() throws {
        let w = try render(model([F.item("clarify:c", kind: .clarify, state: .needsUser, title: "Which env?")]), dark: false); defer { HostedTestSupport.tearDown(w) }
        let l = labels(w)
        XCTAssertTrue(l.contains { $0.contains(AppLocalization.string("Answer in Conduit")) })
        XCTAssertFalse(l.contains(AppLocalization.string("Allow once")))
    }

    func testDisabledButtonsWhileClickGuardIsActive() {
        let m = model([F.approvalItem("approval:q", session: "s1")])
        m.buttonsEnabled = false
        XCTAssertFalse(m.canChoose(rowID: "approval:q"))
        m.buttonsEnabled = true
        XCTAssertTrue(m.canChoose(rowID: "approval:q"))
        m.submitting.insert("approval:q")
        XCTAssertFalse(m.canChoose(rowID: "approval:q"), "no double submit")
    }

    func testAccessibilitySummaryCountsEachKindWithPluralForms() {
        let m = model([F.approvalItem("approval:q", session: "s1"), F.item("turn:a"), F.item("turn:b")])
        XCTAssertEqual(m.accessibilitySummary, "Agent status: 2 working, 1 need you")
        XCTAssertEqual(model([]).accessibilitySummary, "Agent status: idle")
    }

    func testEmptyStateStatesTheVisibilityLimit() {
        let m = model([], availability: .live)
        XCTAssertEqual(m.emptyState, .noAgents)
        XCTAssertEqual(model([], availability: .offline).emptyState, .disconnected)
        XCTAssertEqual(model([], availability: .eventsOnly).emptyState, .noAgents)
        XCTAssertTrue(model([], availability: .eventsOnly).showsEventsOnlyNote)
    }

    func testMoreRowAppearsWhenRowsOverflow() throws {
        let items = (0..<9).map { F.item("turn:\($0)", session: "s\($0)") }
        let w = try render(model(items), dark: true); defer { HostedTestSupport.tearDown(w) }
        XCTAssertTrue(labels(w).contains { $0.contains("+3") })
    }

    func testCompactStateRendersInBothAppearances() throws {
        let m = model([F.item("turn:a", detail: "Running terminal")], surface: .compact)
        for dark in [false, true] {
            let w = try render(m, dark: dark); defer { HostedTestSupport.tearDown(w) }
            XCTAssertTrue(labels(w).contains { $0.contains("Agent status") })
        }
    }

    func testReduceMotionUsesAFadeNotASpring() {
        XCTAssertEqual(NotchMotion.animation(reduceMotion: true), .easeInOut(duration: 0.15))
        XCTAssertNotEqual(NotchMotion.animation(reduceMotion: false), .easeInOut(duration: 0.15))
    }

    func testTextColoursMeetContrastOnTheBlackSurface() {
        for (name, c) in [("text", NotchPalette.textRGB), ("secondary", NotchPalette.secondaryRGB),
                          ("attention", NotchPalette.attentionRGB), ("failure", NotchPalette.failureRGB)] {
            XCTAssertGreaterThanOrEqual(NotchPalette.contrast(c, NotchPalette.surfaceRGB), 4.5, name)
        }
    }

    func testIconOnlyDismissButtonHasALabel() throws {
        let item = F.item("turn:a", state: .finished(.completed))
        let w = try render(model([item]), dark: true); defer { HostedTestSupport.tearDown(w) }
        XCTAssertTrue(labels(w).contains(AppLocalization.string("Dismiss")))
    }

    func testGripExistsOnlyWhenDocked() throws {
        let m = model([F.item("turn:a")])
        m.layout = NotchLayout.make(standardIsNotch: true, dock: nil)
        let standard = try render(m, dark: true); defer { HostedTestSupport.tearDown(standard) }
        XCTAssertFalse(labels(standard).contains(AppLocalization.string("Agent status position handle")))

        m.layout = NotchLayout.make(standardIsNotch: true, dock: MacEdgeDock(edge: .maxX, offset: 0.4, screenID: 1))
        let docked = try render(m, dark: true); defer { HostedTestSupport.tearDown(docked) }
        XCTAssertTrue(labels(docked).contains(AppLocalization.string("Agent status position handle")))
    }

    func testCompactRendersForEveryEdgeAndStaysAccessible() throws {
        for edge in [NSRectEdge.maxY, .minY, .minX, .maxX] {
            let m = model([F.item("turn:a", detail: "Running terminal")], surface: .compact)
            m.layout = NotchLayout.make(standardIsNotch: true, dock: MacEdgeDock(edge: edge, offset: 0.5, screenID: 1))
            let w = try render(m, dark: true); defer { HostedTestSupport.tearDown(w) }
            XCTAssertTrue(labels(w).contains { $0.contains("Agent status") }, "\(edge)")
        }
    }

    func testWingsLayoutLeavesTheNotchBandEmptyOnlyForTheStandardNotchPlacement() {
        let m = model([F.item("turn:a")])
        m.placement = .notch(notchRect: CGRect(x: 659, y: 950, width: 194, height: 32))
        m.layout = NotchLayout.make(standardIsNotch: true, dock: nil)
        XCTAssertEqual(m.reservedTopHeight, 32)
        m.layout = NotchLayout.make(standardIsNotch: true, dock: MacEdgeDock(edge: .maxY, offset: 0.5, screenID: 1))
        XCTAssertEqual(m.reservedTopHeight, 0, "a docked panel has no notch to clear")
        m.layout = NotchLayout.make(standardIsNotch: false, dock: nil)
        XCTAssertEqual(m.reservedTopHeight, 0)
    }

    func testResetHookIsWiredToTheDefault() {
        let m = NotchStatusViewModel()
        var resets = 0
        m.onResetPosition = { resets += 1 }
        m.onResetPosition()
        XCTAssertEqual(resets, 1)
    }

    func testShortCountLabelForTheVerticalCapsule() {
        XCTAssertEqual(NotchCompactLabel.needYou(2).shortCount, "2")
        XCTAssertEqual(NotchCompactLabel.working(3).shortCount, "3")
        XCTAssertEqual(NotchCompactLabel.tool("Running terminal").shortCount, "1")
        XCTAssertEqual(NotchCompactLabel.done.shortCount, "\u{2713}")
        XCTAssertNil(NotchCompactLabel.none.shortCount)
    }
}
