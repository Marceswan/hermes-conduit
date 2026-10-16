import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ConduitMac

/// Home's card grid (D24), measured on a hosted `MacHomeView` through its accessibility frames:
/// the four tiles fill the content width in equal columns, the Activity / Kanban / Cron cards are
/// equal-width, top-aligned and equal-height, and both step down (4 -> 2 -> 1, 3 -> 2 -> 1) as the
/// pane narrows. The same fixture renders to PNGs when `CONDUIT_HOME_SHOTS=1` (run with
/// `TEST_RUNNER_CONDUIT_HOME_SHOTS=1`; `TEST_RUNNER_CONDUIT_HOME_SHOTS_DIR` picks the folder).
/// Off by default, so CI never writes files.
@MainActor
final class MacHomeLayoutTests: XCTestCase {
    private var window: NSWindow?
    private var boostWasOn = false
    private var reported: [String: CGRect] = [:]

    override func setUp() async throws {
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
    }

    // MARK: Fixture

    /// 193 sessions over seven days, the eight newest as Recent chats; Kanban 7 total, all done;
    /// cron active 5, paused 1, failing 1 (a failing job is still active); nothing running.
    static func realistic() -> MacHomeInput {
        let now = MacHomeInput.referenceNow
        let perDay = [53, 9, 40, 22, 31, 14, 24]   // today first; sums to 193
        var sessions: [MacHomeSession] = []
        let titles = ["Refactor billing", "Deploy script", "Quarterly report", "Fix flaky login test", "Plan the offsite",
                      "Summarise the incident", "Review the pull request", "Draft release notes"]
        for (day, count) in perDay.enumerated() {
            for index in 0..<count {
                let id = "s\(day)-\(index)"
                let title: String = sessions.count < titles.count ? titles[sessions.count] : "Chat \(sessions.count)"
                let age: TimeInterval = Double(day) * 86_400 + Double(index) * 600 + 120
                sessions.append(.fixture(id, title: title, at: now.addingTimeInterval(-age),
                                         unread: index % 17 == 3, model: index % 2 == 0 ? "claude-opus-5" : "sonnet"))
            }
        }
        var jobs: [MacHomeCronJob] = []
        for index in 0..<5 {
            jobs.append(MacHomeCronJob(id: "a\(index)", name: "Job \(index)", isActive: true, hasError: index == 0,
                                       nextRun: now.addingTimeInterval(Double(index + 1) * 3_600)))
        }
        jobs.append(MacHomeCronJob(id: "p", name: "Paused job", isActive: false, hasError: false, nextRun: nil))
        return .fixture(
            sessions: sessions, cron: jobs,
            kanban: .loaded([
                MacHomeKanbanColumnInput(status: "triage", displayName: "Triage", sortOrder: 0, count: 0),
                MacHomeKanbanColumnInput(status: "todo", displayName: "To Do", sortOrder: 1, count: 0),
                MacHomeKanbanColumnInput(status: "ready", displayName: "Ready", sortOrder: 2, count: 0),
                MacHomeKanbanColumnInput(status: "running", displayName: "In Progress", sortOrder: 3, count: 0),
                MacHomeKanbanColumnInput(status: "blocked", displayName: "Blocked", sortOrder: 5, count: 0),
                MacHomeKanbanColumnInput(status: "done", displayName: "Done", sortOrder: 7, count: 7),
            ]))
    }

    /// A titled window is constrained to the screen and animates in; a borderless one keeps the
    /// size asked for, so tall panes render whole and captures are not taken mid-animation.
    private static func borderlessWindow<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 0, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: view)
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        window.orderFront(nil)
        return window
    }

    /// The pane as the router mounts it: 20 pt side padding, 12 pt top.
    private func host(width: CGFloat, height: CGFloat = 1500, dark: Bool = false) async throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let input = Self.realistic()
        let model = MacHomeModel(
            sources: MacHomeModel.Sources(
                input: { now in var copy = input; copy.now = now; return copy },
                changes: Empty<Void, Never>().eraseToAnyPublisher(),
                refresh: { _ in }),
            calendar: MacHomeTestCalendar.utc, clock: { MacHomeInput.referenceNow }, tick: .seconds(3600))
        let actions = MacHomeActions(openSession: { _ in }, newChat: {}, quickAsk: {}, openPane: { _ in })
        var home = MacHomeView(model: model, actions: actions, calendar: MacHomeTestCalendar.utc)
        home.frameReport = { [weak self] in self?.reported = $0 }
        reported = [:]
        let view = home
            .padding(.horizontal, 20).padding(.top, 12)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
        let window = Self.borderlessWindow(view, size: NSSize(width: width, height: height))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        self.window = window
        let rendered = await macHomeEventually { AccessibilityProbe.labels(in: window).contains("Recent chats") }
        XCTAssertTrue(rendered, "Home never rendered")
        await macHomeSettle(0.3)
        return window
    }

    private struct Frames {
        var tiles: [CGRect]
        var recent: CGRect
        var activity: CGRect
        var kanban: CGRect
        var cron: CGRect
        var bottom: [CGRect] { [activity, kanban, cron] }
    }

    /// Frames in the Home content's own space: x = 0 is the left edge Recent chats starts at.
    private func frames(_ window: NSWindow) throws -> Frames {
        let frame = { (name: String) in try XCTUnwrap(self.reported[name], "no frame for \(name)") }
        return Frames(
            tiles: try (0..<4).map { try frame("tile.\($0)") },
            recent: try frame("card.bubble.left.and.bubble.right"),
            activity: try frame("card.chart.bar"),
            kanban: try frame("card.\(SidebarTab.kanban.icon)"),
            cron: try frame("card.\(SidebarTab.cron.icon)"))
    }

    private let accuracy: CGFloat = 0.6

    private func assertEqualWidths(_ rects: [CGRect], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let widths = rects.map(\.width)
        XCTAssertEqual(widths.max()! - widths.min()!, 0, accuracy: accuracy, "\(what) widths \(widths)", file: file, line: line)
    }

    private func assertEqualHeights(_ rects: [CGRect], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let heights = rects.map(\.height)
        XCTAssertEqual(heights.max()! - heights.min()!, 0, accuracy: accuracy, "\(what) heights \(heights)", file: file, line: line)
    }

    private func assertSameTop(_ rects: [CGRect], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let tops = rects.map(\.minY)
        XCTAssertEqual(tops.max()! - tops.min()!, 0, accuracy: accuracy, "\(what) tops \(tops)", file: file, line: line)
    }

    /// Left edge of the first and right edge of the last equal `recent`'s, with the one gap between neighbours.
    private func assertFillsRow(_ rects: [CGRect], like recent: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rects.first!.minX, recent.minX, accuracy: accuracy, "left edge", file: file, line: line)
        XCTAssertEqual(rects.last!.maxX, recent.maxX, accuracy: accuracy, "right edge", file: file, line: line)
        for (a, b) in zip(rects, rects.dropFirst()) {
            XCTAssertEqual(b.minX - a.maxX, MacHomeStyle.sectionGap, accuracy: accuracy, "gap", file: file, line: line)
        }
    }

    // MARK: Pure column steps

    func testColumnStepsPickTheLargestCountThatFits() {
        let gap = MacHomeStyle.sectionGap
        let tiles = { (w: CGFloat) in MacHomeGrid.columns(width: w, options: MacHomeStyle.tileColumns, minColumnWidth: MacHomeStyle.tileMinWidth, spacing: gap) }
        XCTAssertEqual(tiles(1210), 4)
        XCTAssertEqual(tiles(4 * 150 + 3 * gap), 4)
        XCTAssertEqual(tiles(4 * 150 + 3 * gap - 1), 2, "never 3 + 1: four tiles go 4, then 2 x 2")
        XCTAssertEqual(tiles(390), 2, "the 430 pt pane (390 inside the padding)")
        XCTAssertEqual(tiles(2 * 150 + gap - 1), 1)
        let cards = { (w: CGFloat) in MacHomeGrid.columns(width: w, options: MacHomeStyle.overviewColumns, minColumnWidth: MacHomeStyle.wideCardMinWidth, spacing: gap) }
        XCTAssertEqual(cards(1210), 3)
        XCTAssertEqual(cards(3 * 260 + 2 * gap), 3)
        XCTAssertEqual(cards(3 * 260 + 2 * gap - 1), 2)
        XCTAssertEqual(cards(390), 1, "the 430 pt pane is a single column")
        XCTAssertEqual(cards(0), 1)
        XCTAssertEqual(MacHomeGrid.columns(width: 100, options: [], minColumnWidth: 10, spacing: 1), 1)
    }

    // MARK: Hosted frames

    func testWidePaneTilesFillTheRowAndBottomCardsAreEqualTopAlignedColumns() async throws {
        let window = try await host(width: 1250)
        let f = try frames(window)
        XCTAssertEqual(f.recent.width, 1250 - 40, accuracy: accuracy, "Recent chats spans the content width")
        XCTAssertEqual(f.recent.minX, 0, accuracy: accuracy)
        assertSameTop(f.tiles, "tiles"); assertEqualWidths(f.tiles, "tiles"); assertEqualHeights(f.tiles, "tiles")
        assertFillsRow(f.tiles, like: f.recent)
        assertSameTop(f.bottom, "bottom cards"); assertEqualWidths(f.bottom, "bottom cards"); assertEqualHeights(f.bottom, "bottom cards")
        assertFillsRow(f.bottom, like: f.recent)
        XCTAssertEqual(f.bottom.map(\.minX), f.bottom.map(\.minX).sorted(), "Activity, Kanban, Cron left to right")
        XCTAssertGreaterThan(f.bottom[0].minY, f.recent.maxY, "the bottom row sits under Recent chats")
        // Vertical rhythm: one gap between the stacked rows.
        XCTAssertEqual(f.recent.minY - f.tiles[0].maxY, MacHomeStyle.sectionGap, accuracy: accuracy, "tiles to Recent chats")
        XCTAssertEqual(f.bottom[0].minY - f.recent.maxY, MacHomeStyle.sectionGap, accuracy: accuracy, "Recent chats to the bottom row")
    }

    func testActivityChartUsesTheCardsHeight() async throws {
        let window = try await host(width: 1250)
        let f = try frames(window)
        var chart = try XCTUnwrap(AccessibilityProbe.nodes(in: window).first { $0.label == "Sessions per day" }?.frame)
        chart = chart.offsetBy(dx: -20, dy: -12)   // window space to the content's space
        XCTAssertGreaterThanOrEqual(chart.height, MacHomeStyle.chartHeight, "never smaller than the minimum chart")
        XCTAssertLessThanOrEqual(chart.maxY, f.activity.maxY + accuracy, "inside the card")
        XCTAssertGreaterThan(chart.width, f.activity.width * 0.8, "the chart spans the card, not a corner of it")
        // The card is as tall as the row; any height beyond the Activity card's own content goes to the chart.
        XCTAssertGreaterThan(f.activity.maxY - chart.maxY, -accuracy)
        XCTAssertLessThan(f.activity.maxY - chart.maxY, MacHomeStyle.cardPadding + 4, "the chart reaches the card's bottom padding")
    }

    func testMidWidthsStepTheBottomRowDown() async throws {
        let w900 = try await host(width: 900)
        var f = try frames(w900)
        assertSameTop(f.tiles, "tiles at 900"); assertFillsRow(f.tiles, like: f.recent)
        assertSameTop(f.bottom, "cards at 900"); assertEqualWidths(f.bottom, "cards at 900"); assertEqualHeights(f.bottom, "cards at 900")
        assertFillsRow(f.bottom, like: f.recent)
        HostedTestSupport.tearDown(w900); window = nil

        let w640 = try await host(width: 640)
        f = try frames(w640)
        // 600 pt inside the padding: four tiles need 636, so 2 x 2.
        XCTAssertEqual(Set(f.tiles.map { $0.minY.rounded() }).count, 2, "tiles wrap to two rows: \(f.tiles)")
        XCTAssertEqual(Set(f.tiles.map { $0.minX.rounded() }).count, 2)
        assertEqualWidths(f.tiles, "2x2 tiles"); assertEqualHeights(f.tiles, "2x2 tiles")
        XCTAssertEqual(f.tiles[0].minX, f.recent.minX, accuracy: accuracy)
        XCTAssertEqual(f.tiles[1].maxX, f.recent.maxX, accuracy: accuracy)
        // Cards: Activity and Kanban share row one, Cron starts row two in the same column width.
        assertSameTop([f.activity, f.kanban], "first row"); assertEqualHeights([f.activity, f.kanban], "first row")
        assertEqualWidths(f.bottom, "2 columns")
        XCTAssertGreaterThan(f.cron.minY, f.activity.maxY)
        XCTAssertEqual(f.cron.minX, f.activity.minX, accuracy: accuracy)
        assertFillsRow([f.activity, f.kanban], like: f.recent)
    }

    func testMinimumPaneIsOneColumnWithoutClipping() async throws {
        let window = try await host(width: 430, height: 2000)
        let f = try frames(window)
        XCTAssertEqual(f.recent.width, 430 - 40, accuracy: accuracy)
        // Tiles: 2 x 2 inside the 390 pt content.
        XCTAssertEqual(Set(f.tiles.map { $0.minY.rounded() }).count, 2)
        assertEqualWidths(f.tiles, "tiles"); assertEqualHeights(f.tiles, "tiles")
        XCTAssertEqual(f.tiles[1].maxX, f.recent.maxX, accuracy: accuracy)
        // Cards: one column, each as wide as Recent chats, stacked in order.
        for card in f.bottom {
            XCTAssertEqual(card.minX, f.recent.minX, accuracy: accuracy)
            XCTAssertEqual(card.width, f.recent.width, accuracy: accuracy)
        }
        XCTAssertLessThanOrEqual(f.activity.maxY, f.kanban.minY)
        XCTAssertLessThanOrEqual(f.kanban.maxY, f.cron.minY)
        for node in AccessibilityProbe.nodes(in: window) where node.frame.width > 0 {
            XCTAssertGreaterThanOrEqual(node.frame.minX, -accuracy, "\(node.label ?? node.role) clipped on the left")
            XCTAssertLessThanOrEqual(node.frame.maxX, 430 + accuracy, "\(node.label ?? node.role) clipped on the right")
        }
    }

    func testTheHeaderAndTheCardsShareTheContentsLeftEdge() async throws {
        let window = try await host(width: 1250)
        let f = try frames(window)
        let title = try XCTUnwrap(AccessibilityProbe.nodes(in: window).first { $0.value == "Home" || $0.label == "Home" }?.frame)
        XCTAssertEqual(title.minX - 20, f.recent.minX, accuracy: 1.0, "the title starts at the cards' left edge (20 pt is the router's side padding)")
        XCTAssertEqual(try XCTUnwrap(reported["header"]).minX, f.recent.minX, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(reported["header"]).maxX, f.recent.maxX, accuracy: accuracy, "the header row spans the same width")
    }

    // MARK: Renders

    private var shotsDirectory: String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CONDUIT_HOME_SHOTS"] == "1" else { return nil }
        return env["CONDUIT_HOME_SHOTS_DIR"] ?? "/private/tmp/conduit-home-shots"
    }

    /// Captures the window's own pixels (the window server composites SwiftUI and glass; a view's
    /// layer or `cacheDisplay` come out blank). Waits for the window to be fully shown first.
    private func writePNG(of window: NSWindow, to path: String) async throws {
        window.orderFrontRegardless()
        await macHomeSettle(1.0)
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

    func testRenderHomeAtEveryWidth() async throws {
        try XCTSkipUnless(shotsDirectory != nil, "set TEST_RUNNER_CONDUIT_HOME_SHOTS=1 to write PNGs")
        let directory = shotsDirectory ?? ""
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (width, height) in [(1250, 1000), (900, 1000), (640, 1250), (430, 1800)] as [(CGFloat, CGFloat)] {
            for dark in [false, true] {
                let window = try await host(width: width, height: height, dark: dark)
                try await writePNG(of: window, to: "\(directory)/home-\(Int(width))-\(dark ? "dark" : "light").png")
                HostedTestSupport.tearDown(window)
                self.window = nil
            }
        }
    }

    func testRenderTabStrip() async throws {
        try XCTSkipUnless(shotsDirectory != nil, "set TEST_RUNNER_CONDUIT_HOME_SHOTS=1 to write PNGs")
        let directory = shotsDirectory ?? ""
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [340, 400] as [CGFloat] {
            for dark in [false, true] {
                let view = MacSidebarTabStrip(selectedRaw: .constant("Sessions"))
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .frame(width: width, height: MacTabStripMetrics.containerHeight + 28)
                    .background(Color(nsColor: .windowBackgroundColor))
                let window = Self.borderlessWindow(view, size: NSSize(width: width, height: MacTabStripMetrics.containerHeight + 28))
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                await macHomeSettle(0.4)
                try await writePNG(of: window, to: "\(directory)/strip-\(Int(width))\(dark ? "-dark" : "").png")
                HostedTestSupport.tearDown(window)
            }
        }
    }
}
