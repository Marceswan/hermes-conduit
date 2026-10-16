import Combine
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacHomeViewTests: XCTestCase {
    private var window: NSWindow?
    private var boostWasOn = false

    private final class Calls {
        var opened: [String] = []
        var newChats = 0
        var quickAsks = 0
        var panes: [SidebarTab] = []
    }

    override func setUp() async throws {
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
    }

    private func actions(_ calls: Calls) -> MacHomeActions {
        MacHomeActions(
            openSession: { calls.opened.append($0) },
            newChat: { calls.newChats += 1 },
            quickAsk: { calls.quickAsks += 1 },
            openPane: { calls.panes.append($0) }
        )
    }

    private func host(_ input: MacHomeInput, calls: Calls, width: CGFloat = 900, height: CGFloat = 1400, dark: Bool = false) async throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let model = MacHomeModel(
            sources: MacHomeModel.Sources(
                input: { now in var copy = input; copy.now = now; return copy },
                changes: Empty<Void, Never>().eraseToAnyPublisher(),
                refresh: { _ in }
            ),
            calendar: MacHomeTestCalendar.utc, clock: { MacHomeInput.referenceNow }, tick: .seconds(3600)
        )
        let view = MacHomeView(model: model, actions: actions(calls), calendar: MacHomeTestCalendar.utc).padding(20).frame(width: width, height: height)
        let window = HostedTestSupport.host(view, size: NSSize(width: width, height: height))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        self.window = window
        // Bounded async wait for the first render (never HostedTestSupport.waitUntil in an async test),
        // then let queued work drain so negative assertions are meaningful.
        let rendered = await macHomeEventually { labels(window).contains("Home") }
        XCTAssertTrue(rendered, "Home never rendered its header")
        await macHomeSettle(0.2)
        return window
    }

    private func full() -> MacHomeInput {
        let now = MacHomeInput.referenceNow
        return .fixture(
            sessions: [
                .fixture("s1", title: "Refactor billing", at: now.addingTimeInterval(-240), unread: true, model: "opus"),
                .fixture("s2", title: "Deploy script", at: now.addingTimeInterval(-3600), model: "sonnet"),
            ],
            live: [
                .fixture("approval:1", session: "s1", kind: .approval, needsUser: true, title: "Refactor billing", detail: "git push origin main", open: "s1", since: now.addingTimeInterval(-240)),
                .fixture("turn:2", session: "s2", kind: .turn, title: "Deploy script", detail: "web_search", open: nil, since: now.addingTimeInterval(-540)),
            ],
            cron: [MacHomeCronJob(id: "c", name: "Nightly", isActive: true, hasError: false, nextRun: now.addingTimeInterval(7200))],
            kanban: .loaded([
                MacHomeKanbanColumnInput(status: "todo", displayName: "To Do", sortOrder: 1, count: 4),
                MacHomeKanbanColumnInput(status: "done", displayName: "Done", sortOrder: 7, count: 9),
            ]),
            runtime: MacHomeRuntime(model: "claude-opus-5", provider: "anthropic", reasoningEffort: "high", contextPercent: 62, contextUsed: 124_000, contextMax: 200_000),
            subAgents: 2
        )
    }

    /// Labels and string values: static text carries its text as a value.
    private func labels(_ window: NSWindow) -> [String] { AccessibilityProbe.texts(in: window) }

    func testFullSnapshotShowsEverySection() async throws {
        let window = try await host(full(), calls: Calls())
        let all = labels(window).joined(separator: "\n")
        for expected in ["Approval: Refactor billing", "Running: Deploy script", "Recent chats", "claude-opus-5", "Nightly", "To Do", "Home"] {
            XCTAssertTrue(all.contains(expected), "missing \(expected) in:\n\(all)")
        }
    }

    func testRecentRowOpensItsSession() async throws {
        let calls = Calls()
        let window = try await host(full(), calls: calls)
        XCTAssertTrue(AccessibilityProbe.press("Refactor billing", in: window) || AccessibilityProbe.press("Deploy script", in: window))
        XCTAssertFalse(calls.opened.isEmpty)
        XCTAssertTrue(["s1", "s2"].contains(calls.opened[0]))
    }

    func testLiveRowOpensItsSessionAndAnInertRowIsNotAButton() async throws {
        let calls = Calls()
        let window = try await host(full(), calls: calls)
        XCTAssertTrue(AccessibilityProbe.press("Approval: Refactor billing", in: window))
        XCTAssertEqual(calls.opened, ["s1"])
        let inert = AccessibilityProbe.nodes(in: window).first { $0.label == "Running: Deploy script" }
        XCTAssertNotNil(inert, "the row is still described")
        XCTAssertNotEqual(inert?.role, "AXButton", "a live row with no open id is not a button")
    }

    func testQuickActionsCallTheirActions() async throws {
        let calls = Calls()
        let window = try await host(full(), calls: calls)
        XCTAssertTrue(AccessibilityProbe.press("New Chat", in: window))
        XCTAssertTrue(AccessibilityProbe.press("Quick Ask", in: window))
        XCTAssertTrue(AccessibilityProbe.press("Kanban", in: window))
        XCTAssertEqual(calls.newChats, 1)
        XCTAssertEqual(calls.quickAsks, 1)
        XCTAssertEqual(calls.panes, [.kanban])
    }

    func testNewChatIsInertWhenTheSidebarsIs() async throws {
        let calls = Calls()
        var input = full()
        input.canStartChat = false
        let window = try await host(input, calls: calls)
        _ = AccessibilityProbe.press("New Chat", in: window)
        XCTAssertEqual(calls.newChats, 0)
    }

    func testEmptyConnectedHomeSaysNothingIsRunningAndInvitesAChat() async throws {
        let window = try await host(.fixture(), calls: Calls())
        let all = labels(window).joined(separator: "\n")
        XCTAssertTrue(all.contains("Nothing running"), all)
        XCTAssertTrue(all.contains("No chats yet"), all)
        XCTAssertFalse(all.contains("Approval:") || all.contains("Running:"), "no live rows")
    }

    func testLoadingAndEventsOnlyFeedsDoNotClaimNothingIsRunning() async throws {
        for feed in [MacHomeFeedAvailability.loading, .eventsOnly] {
            let window = try await host(.fixture(feed: feed), calls: Calls(), height: 900)
            XCTAssertFalse(labels(window).joined(separator: "\n").contains("Nothing running"), "\(feed)")
            HostedTestSupport.tearDown(window)
            self.window = nil
        }
    }

    func testOfflineShowsTheBannerAndHidesLiveSections() async throws {
        var input = full()
        input.connection.state = .offline
        input.feed = .offline
        input.canStartChat = false
        let window = try await host(input, calls: Calls())
        let all = labels(window).joined(separator: "\n")
        XCTAssertTrue(all.contains("Offline"), all)
        XCTAssertTrue(all.contains("Not connected"), all)
        XCTAssertFalse(all.contains("Approval: Refactor billing"), "the live rows are hidden offline")
        XCTAssertFalse(all.contains("Running: Deploy script"), all)
        XCTAssertTrue(all.contains("Refactor billing"), "the last saved list stays")
    }

    func testChartsCarryTheirValuesAsText() async throws {
        var input = full()
        input.sessions = [.fixture("a", at: MacHomeInput.referenceNow)]
        let window = try await host(input, calls: Calls())
        let all = labels(window).joined(separator: "\n")
        XCTAssertTrue(all.contains("Sessions per day"), all)
        let days = MacHomeSnapshot.make(input, calendar: MacHomeTestCalendar.utc).days
        let summary = MacHomeDayBars.summary(days: days, calendar: MacHomeTestCalendar.utc)
        XCTAssertEqual(summary.components(separatedBy: ", ").count, 7)
        XCTAssertTrue(summary.hasSuffix(" 1"), "today's count is last: \(summary)")
    }

    func testHostileTextStaysOnOneLineAtTheMinimumWidth() async throws {
        var input = full()
        let hostile = "Fix\u{202E}evil\nline " + String(repeating: "w", count: 5000)
        input.sessions = [.fixture("s1", title: hostile, at: MacHomeInput.referenceNow)]
        let window = try await host(input, calls: Calls(), width: 470, height: 1400)
        let nodes = AccessibilityProbe.nodes(in: window)
        XCTAssertFalse(nodes.contains { ($0.label ?? "").contains("\u{202E}") || ($0.value ?? "").contains("\u{202E}") })
        XCTAssertTrue(nodes.allSatisfy { $0.frame.maxX <= 470 + 1 }, "nothing is laid out past the right edge")
    }

    func testRendersInDarkAppearanceToo() async throws {
        let window = try await host(full(), calls: Calls(), dark: true)
        XCTAssertTrue(labels(window).joined(separator: "\n").contains("Recent chats"))
    }

    func testTileLabelsCountItemsNotRows() async throws {
        // Two approvals for one session: one row, two items.
        let now = MacHomeInput.referenceNow
        let input = MacHomeInput.fixture(
            sessions: [.fixture("s1", title: "Billing", at: now)],
            live: [
                .fixture("approval:1", session: "s1", kind: .approval, needsUser: true, title: "Billing", open: "s1", since: now),
                .fixture("approval:2", session: "s1", kind: .approval, needsUser: true, title: "Billing", open: "s1", since: now),
            ]
        )
        let window = try await host(input, calls: Calls())
        let all = labels(window)
        XCTAssertTrue(all.contains("Waiting on you"), "the tile says items, not rows: \(all)")
        XCTAssertEqual(all.filter { $0 == "Approval: Billing" }.count, 1, "one row for the session")
        let tile = AccessibilityProbe.nodes(in: window).first { $0.label == "Waiting on you" }
        XCTAssertEqual(tile?.value, "2, Approvals 2, questions 0", "the tile counts both items")
    }

    func testActiveCronJobWithNoUpcomingRunSaysSo() async throws {
        let now = MacHomeInput.referenceNow
        var input = full()
        input.cron = [MacHomeCronJob(id: "c", name: "Stale", isActive: true, hasError: false, nextRun: now.addingTimeInterval(-3600))]
        let all = labels(try await host(input, calls: Calls())).joined(separator: "\n")
        XCTAssertTrue(all.contains("No upcoming run"), all)
        XCTAssertFalse(all.contains("No scheduled jobs"), all)
    }

    func testEmptyAfterSanitizeTitleGetsAPlaceholder() async throws {
        var input = full()
        input.sessions = [.fixture("s1", title: "\u{200B}\u{200B}", at: MacHomeInput.referenceNow)]
        input.live = [.fixture("turn:1", session: "s1", kind: .turn, title: "\u{200B}", open: "s1")]
        let all = labels(try await host(input, calls: Calls())).joined(separator: "\n")
        XCTAssertTrue(all.contains("Untitled chat"), all)
        XCTAssertTrue(all.contains("Running: Untitled chat"), all)
    }

    func testContextMeterExposesItsValue() async throws {
        let window = try await host(full(), calls: Calls())
        let meter = AccessibilityProbe.nodes(in: window).first { $0.label == "Context" && $0.value != nil }
        XCTAssertEqual(meter?.value, "62 %, 124K of 200K tokens")
        XCTAssertEqual(MacHomeContextMeter.tokens(MacHomeContext(percent: 62, used: 124_000, max: 200_000, isHigh: false)).isEmpty, false)
        XCTAssertEqual(MacHomeContextMeter.tokens(MacHomeContext(percent: 10, used: 5, max: 0, isHigh: false)), "")
    }

    func testOfflineKanbanAndCronAreNotReportedAsLoading() async throws {
        var input = full()
        input.connection.state = .offline
        input.feed = .offline
        input.kanban = .notLoaded
        input.cron = nil
        let all = labels(try await host(input, calls: Calls())).joined(separator: "\n")
        XCTAssertFalse(all.contains("Loading"), all)
    }
}
