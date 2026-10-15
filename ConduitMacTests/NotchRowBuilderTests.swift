import XCTest
@testable import ConduitMac

final class NotchRowBuilderTests: XCTestCase {
    typealias F = NotchFixtures

    // MARK: approval choices

    func testDefaultChoicesOfferEverythingWhenPermanentAllowed() {
        XCTAssertEqual(NotchApprovalChoices.resolve(F.approval()),
                       NotchApprovalChoices(once: true, deny: true, session: true, always: true))
    }

    func testAlwaysNeedsAllowPermanent() {
        let c = NotchApprovalChoices.resolve(F.approval(allowPermanent: false))
        XCTAssertTrue(c.session)
        XCTAssertFalse(c.always)
    }

    func testSmartDeniedOffersOnlyOnceAndDeny() {
        // The gateway sends explicit choices for a smart-denied request; with none, the base's rule falls back to once and deny.
        XCTAssertEqual(NotchApprovalChoices.resolve(F.approval(choices: ["once", "deny"], smartDenied: true)),
                       NotchApprovalChoices(once: true, deny: true, session: false, always: false))
        XCTAssertEqual(NotchApprovalChoices.resolve(F.approval(smartDenied: true)),
                       NotchApprovalChoices(once: true, deny: true, session: false, always: false))
    }

    func testExplicitChoicesAreHonoured() {
        let c = NotchApprovalChoices.resolve(F.approval(choices: ["deny"]))
        XCTAssertEqual(c, NotchApprovalChoices(once: false, deny: true, session: false, always: false))
        XCTAssertTrue(c.hasInlineButtons)
        XCTAssertFalse(NotchApprovalChoices.resolve(F.approval(choices: [])).hasInlineButtons)
    }

    // MARK: row mapping

    func testApprovalRowCarriesInlineChoicesAndSessionTarget() {
        let list = NotchRowBuilder.build(items: [F.approvalItem("approval:q1", session: "s1")], now: F.t0)
        let row = list.rows[0]
        XCTAssertEqual(row.section, .needsYou)
        XCTAssertEqual(row.target, .session("s1"))
        XCTAssertEqual(row.inline, .approval(NotchApprovalChoices.resolve(F.approval()), command: "ls"))
        XCTAssertEqual(row.tone, .attention)
        XCTAssertFalse(row.canDismiss)
    }

    func testApprovalWithoutCapturedContentSaysOpenToAnswer() {
        let list = NotchRowBuilder.build(items: [F.approvalItem("approval:q1", session: "s1", approval: nil)], now: F.t0)
        XCTAssertEqual(list.rows[0].inline, .openToAnswer)
    }

    func testApprovalWithNoUsableChoiceSaysOpenToAnswer() {
        let a = F.approval(choices: ["session"])
        let list = NotchRowBuilder.build(items: [F.approvalItem("approval:q1", session: "s1", approval: a)], now: F.t0)
        XCTAssertEqual(list.rows[0].inline, .openToAnswer)
    }

    func testClarifyAndInputPromptsAreNeverInline() {
        let items = [F.item("clarify:c1", kind: .clarify, state: .needsUser, session: "a"),
                     F.item("input:i1", kind: .inputPrompt, state: .needsUser, session: "b")]
        let rows = NotchRowBuilder.build(items: items, now: F.t0).rows
        XCTAssertEqual(rows.map(\.inline), [.answerInConduit, .answerInConduit])
    }

    // Kanban and cron: follow-up (the base never produces these kinds). These two tests drive the builder with
    // fixtures so a later source needs no notch change; v1 shows neither.
    func testKanbanRowOpensThePaneAndIsNotInterruptive() {
        let item = F.item("kanban:b/t1", kind: .kanban, state: .blocked, title: "Fix login", detail: "Blocked")
        let list = NotchRowBuilder.build(items: [item], now: F.t0)
        XCTAssertEqual(list.rows[0].target, .kanban)
        XCTAssertEqual(list.rows[0].section, .needsYou)
        XCTAssertEqual(list.counts.needsUser, 1)
        XCTAssertEqual(list.counts.decisions, 0)
    }

    func testCronItemFeedsTheFooterNotTheRows() {
        let at = F.t0.addingTimeInterval(720)
        let item = F.item("cron:j1", kind: .cron, state: .working, title: "Nightly report", since: at)
        let list = NotchRowBuilder.build(items: [item], now: F.t0)
        XCTAssertTrue(list.rows.isEmpty)
        XCTAssertEqual(list.cron, NotchCronInfo(title: "Nightly report", at: at))
        XCTAssertEqual(list.counts, NotchCounts())
    }

    func testEmptyTitleFallsBackToUntitledChat() {
        let list = NotchRowBuilder.build(items: [F.item("turn:a", title: "")], now: F.t0)
        XCTAssertEqual(list.rows[0].title, AppLocalization.string("Untitled chat"))
    }

    func testWorkingTurnBehindADecisionForTheSameSessionIsHidden() {
        let items = [F.approvalItem("approval:q1", session: "s1"), F.item("turn:s1", session: "s1"), F.item("turn:s2", session: "s2")]
        let list = NotchRowBuilder.build(items: items, now: F.t0)
        XCTAssertEqual(list.rows.map(\.id), ["approval:q1", "turn:s2"])
        XCTAssertEqual(list.counts.working, 1)
    }

    // MARK: done rows

    func testFinishedRowsLiveThirtySecondsMaxThreeNewestFirst() {
        func done(_ id: String, age: TimeInterval, _ o: AgentActivityItem.Outcome = .completed) -> AgentActivityItem {
            F.item(id, state: .finished(o), since: F.t0.addingTimeInterval(-age))
        }
        let items = [done("turn:a", age: 5), done("turn:b", age: 10), done("turn:c", age: 15),
                     done("turn:d", age: 20), done("turn:old", age: 31)]
        let list = NotchRowBuilder.build(items: items, now: F.t0)
        XCTAssertEqual(list.rows.map(\.id), ["turn:a", "turn:b", "turn:c"])
        XCTAssertEqual(list.counts.recent, 3)
        XCTAssertTrue(list.rows.allSatisfy { $0.canDismiss && $0.section == .done })
    }

    func testFailedRowIsRedWithTheErrorText() {
        let item = F.item("turn:a", state: .finished(.failed("rate limited")))
        let row = NotchRowBuilder.build(items: [item], now: F.t0).rows[0]
        XCTAssertEqual(row.tone, .failed)
        XCTAssertEqual(row.detail, "rate limited")
    }

    func testNextExpiryIsTheOldestVisibleDoneRow() {
        let items = [F.item("turn:a", state: .finished(.completed), since: F.t0.addingTimeInterval(-10)),
                     F.item("turn:b", state: .finished(.completed), since: F.t0.addingTimeInterval(-25))]
        let list = NotchRowBuilder.build(items: items, now: F.t0)
        XCTAssertEqual(list.nextExpiry, F.t0.addingTimeInterval(5))
    }

    // MARK: ordering and overflow (Review Focus 5)

    func testTwentyWorkingShowSixRowsAndOverflow() {
        let items = (0..<20).map { F.item("turn:\($0)", session: "s\($0)") }
        let list = NotchRowBuilder.build(items: items, now: F.t0)
        XCTAssertEqual(list.rows.count, 6)
        XCTAssertEqual(list.overflow, 14)
        XCTAssertEqual(list.counts.working, 20)
    }

    func testNeedsYouRowsSortAheadOfWorkingAndAreNeverOverflowed() {
        var items = (0..<10).map { F.item("turn:\($0)", session: "s\($0)") }
        items.append(F.approvalItem("approval:late", session: "z"))
        let list = NotchRowBuilder.build(items: items, now: F.t0)
        XCTAssertEqual(list.rows.first?.id, "approval:late")
        XCTAssertEqual(list.rows.count, 6)
    }

    // MARK: command text (Review Focus 4)

    func testCommandIsCollapsedToOneLineAndTruncatedAt160() {
        let long = "echo " + String(repeating: "A", count: 400) + "\n\nsecret=hunter2"
        let out = NotchRowBuilder.truncatedCommand(long)
        XCTAssertLessThanOrEqual(out.count, 160)
        XCTAssertFalse(out.contains("\n"))
        XCTAssertTrue(out.hasSuffix("\u{2026}"))
        XCTAssertEqual(NotchRowBuilder.truncatedCommand("  ls   -la \n"), "ls -la")
    }

    // MARK: diff

    func testDiffFlagsNewDecisionsAndNewFinishesOnly() {
        let working = F.item("turn:a", session: "a")
        let done = F.item("turn:a", state: .finished(.completed), session: "a")
        let approval = F.approvalItem("approval:q", session: "a")
        let kanban = F.item("kanban:b/t", kind: .kanban, state: .blocked)
        XCTAssertTrue(NotchItemDiff.transitions(old: [working], new: [working, approval]).newDecision)
        XCTAssertFalse(NotchItemDiff.transitions(old: [working, approval], new: [working, approval]).newDecision)
        XCTAssertFalse(NotchItemDiff.transitions(old: [], new: [kanban]).newDecision, "kanban never auto-expands")
        XCTAssertTrue(NotchItemDiff.transitions(old: [working], new: [done]).newFinish)
        XCTAssertFalse(NotchItemDiff.transitions(old: [done], new: [done]).newFinish)
    }

    // MARK: compact label

    func testCompactLabelPrefersAttentionThenToolThenCount() {
        let w1 = F.item("turn:a", detail: "Running terminal")
        let w2 = F.item("turn:b")
        let a = F.approvalItem("approval:q", session: "x")
        func label(_ items: [AgentActivityItem]) -> NotchCompactLabel {
            NotchCompactLabel.make(counts: NotchRowBuilder.build(items: items, now: F.t0).counts,
                                   items: NotchRowBuilder.build(items: items, now: F.t0).rows)
        }
        XCTAssertEqual(label([w1, a]), .needYou(1))
        XCTAssertEqual(label([w1]), .tool("Running terminal"))
        XCTAssertEqual(label([w1, w2]), .working(2))
        XCTAssertEqual(label([F.item("turn:z", state: .finished(.completed))]), .done)
        XCTAssertEqual(label([]), .none)
    }
}
