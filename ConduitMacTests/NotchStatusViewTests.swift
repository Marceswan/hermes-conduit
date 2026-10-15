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

    func testApprovalRowAccessibilityLabelLeadsWithTheCommandNotTheDescription() throws {
        let command = "rm -rf /tmp/x", harmless = "Harmless cleanup, safe to allow"
        var a = F.approval(command: command)
        a.description = harmless
        let w = try render(model([F.approvalItem("approval:q", session: "s1", approval: a)]), dark: true); defer { HostedTestSupport.tearDown(w) }
        let l = labels(w)
        XCTAssertTrue(l.contains(AppLocalization.string("Approval needed: \(command)")), "VoiceOver hears the command first")
        XCTAssertFalse(l.contains(AppLocalization.string("Approval needed: \(harmless)")), "the agent-worded description is never the label")
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

    func testDarkInksMeetTextContrastOnTheBlackSurface() {
        for ink in NotchPalette.Ink.allCases {
            XCTAssertGreaterThanOrEqual(NotchPalette.contrast(NotchPalette.rgb(ink, dark: true), NotchPalette.surfaceRGB), 4.5, "\(ink)")
        }
    }

    /// Text, secondary and attention keep the values the black notch shipped with; only the failure
    /// ink was lightened, because over a washed white window its old value fell under 3:1.
    func testDarkInksKeepTheirShippedValuesExceptFailure() {
        XCTAssertTrue(NotchPalette.rgb(.text, dark: true) == (1, 1, 1))
        XCTAssertTrue(NotchPalette.rgb(.secondary, dark: true) == (0.78, 0.78, 0.80))
        XCTAssertTrue(NotchPalette.rgb(.attention, dark: true) == (1.0, 0.78, 0.20))
        XCTAssertTrue(NotchPalette.rgb(.failure, dark: true) == (1.0, 0.65, 0.63))
    }

    /// Every ink is checked as text (4.5:1), which also covers the glyph-only uses (3:1).
    func testLightInksMeetTextContrastOnLightGlass() {
        XCTAssertFalse(NotchPalette.lightGlassReferenceRGBs.isEmpty)
        for background in NotchPalette.lightGlassReferenceRGBs {
            for ink in NotchPalette.Ink.allCases {
                XCTAssertGreaterThanOrEqual(NotchPalette.contrast(NotchPalette.rgb(ink, dark: false), background), 4.5,
                                            "\(ink) on \(background)")
            }
        }
    }

    func testLightInksAreDarkerThanTheirDarkPairsAndNotTheHardCodedWhite() {
        func luminance(_ c: NotchPalette.RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        for ink in NotchPalette.Ink.allCases {
            XCTAssertLessThan(luminance(NotchPalette.rgb(ink, dark: false)), luminance(NotchPalette.rgb(ink, dark: true)), "\(ink)")
        }
    }

    func testLightGlassReferencesAreLight() {
        for background in NotchPalette.lightGlassReferenceRGBs {
            XCTAssertGreaterThanOrEqual(NotchPalette.contrast(background, NotchPalette.surfaceRGB), 10, "\(background)")
        }
    }

    func testAdaptiveColoursResolveToTheMatchingVariantForEachAppearance() {
        for ink in NotchPalette.Ink.allCases {
            for dark in [true, false] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(NotchPalette.color(ink)).usingColorSpace(.sRGB)
                }
                let expected = NotchPalette.rgb(ink, dark: dark)
                XCTAssertEqual(Double(resolved?.redComponent ?? -1), expected.r, accuracy: 0.01, "\(ink) dark=\(dark)")
                XCTAssertEqual(Double(resolved?.greenComponent ?? -1), expected.g, accuracy: 0.01, "\(ink) dark=\(dark)")
                XCTAssertEqual(Double(resolved?.blueComponent ?? -1), expected.b, accuracy: 0.01, "\(ink) dark=\(dark)")
            }
        }
    }

    /// The black band pins `colorScheme` to dark while the window follows the Mac (light): the ink
    /// there must be the dark variant (white), or the text would be dark on black.
    func testColourSchemeOverrideSelectsTheInkVariantInsideALightWindow() {
        func centrePixel(dark: Bool?) -> NSColor? {
            let swatch = Rectangle().fill(NotchPalette.text).frame(width: 40, height: 40)
            let w = HostedTestSupport.host(Group {
                if let dark { swatch.environment(\.colorScheme, dark ? .dark : .light) } else { swatch }
            }, size: NSSize(width: 40, height: 40))
            defer { HostedTestSupport.tearDown(w) }
            w.appearance = NSAppearance(named: .aqua)
            HostedTestSupport.settle(0.3)
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB)
        }
        XCTAssertLessThan(centrePixel(dark: nil)?.redComponent ?? 1, 0.2, "a light window with no override: dark ink")
        XCTAssertGreaterThan(centrePixel(dark: true)?.redComponent ?? 0, 0.9, "the dark override wins inside a light window")
    }

    func testViewModelDefaultsToTheGlassStyleAndTakesAnotherOne() {
        let m = NotchStatusViewModel()
        XCTAssertEqual(m.surfaceStyle, .glass)
        m.surfaceStyle = .solid
        XCTAssertEqual(m.surfaceStyle, .solid)
    }

    func testEveryStyleRendersExpandedAndCompactInBothAppearances() throws {
        for style in NotchSurfaceStyle.allCases {
            for surface in [NotchSurface.expanded, .compact] {
                for dark in [false, true] {
                    let m = model([F.item("turn:a", detail: "Running terminal")], surface: surface)
                    m.surfaceStyle = style
                    let w = try render(m, dark: dark); defer { HostedTestSupport.tearDown(w) }
                    XCTAssertTrue(labels(w).contains { $0.contains("Agent status") }, "\(style) \(surface) dark=\(dark)")
                }
            }
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

    func testOnlyTheStandardNotchPlacementWeldsItsBandToTheHardware() {
        let m = model([F.item("turn:a")])
        m.placement = .notch(notchRect: CGRect(x: 659, y: 950, width: 194, height: 32))
        m.layout = NotchLayout.make(standardIsNotch: true, dock: nil)
        XCTAssertTrue(m.weldsToHardwareNotch)
        m.layout = NotchLayout.make(standardIsNotch: true, dock: MacEdgeDock(edge: .maxY, offset: 0.5, screenID: 1))
        XCTAssertFalse(m.weldsToHardwareNotch, "docked at the top: a capsule, no hardware beside it")
        m.layout = NotchLayout.make(standardIsNotch: false, dock: nil)
        m.placement = .pill
        XCTAssertFalse(m.weldsToHardwareNotch, "the pill on an external display draws the chosen style")
    }

    func testDrawnStyleFollowsTheLayoutTheChoiceAndReduceTransparency() {
        let m = model([F.item("turn:a")])
        m.glassAvailable = true
        m.surfaceStyle = .dock
        m.layout = NotchLayout.make(standardIsNotch: false, dock: MacEdgeDock(edge: .minY, offset: 0.5, screenID: 1))
        XCTAssertEqual(m.drawnSurfaceStyle, .dock)
        m.reduceTransparency = true
        XCTAssertEqual(m.drawnSurfaceStyle, .solid)
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
