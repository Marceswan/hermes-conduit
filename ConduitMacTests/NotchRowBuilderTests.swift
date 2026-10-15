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
        XCTAssertEqual(row.inline, .approval(NotchApprovalChoices.resolve(F.approval()),
                                             NotchApprovalContent(summary: "d", command: "ls", needsReview: false)))
        XCTAssertEqual(row.tone, .attention)
        XCTAssertFalse(row.canDismiss)
    }

    // MARK: approval spoofing hardening (coordinator security note)

    func testApprovalRowShowsThePayloadNotTheAgentWordedTitleOrDetail() {
        var item = F.approvalItem("approval:q1", session: "s1", approval: F.approval(command: "rm -rf /tmp/x"))
        item.title = "Routine cleanup, safe to allow"          // agent-controlled
        item.detail = "Allow this, it only lists files"        // agent-controlled
        let row = NotchRowBuilder.build(items: [item], now: F.t0).rows[0]
        guard case .approval(_, let content) = row.inline else { return XCTFail("expected inline approval") }
        XCTAssertEqual(content.command, "rm -rf /tmp/x")
        XCTAssertEqual(content.summary, "d")
        XCTAssertNil(row.detail, "an approval row has no second agent-worded line")
        XCTAssertEqual(row.title, "Routine cleanup, safe to allow", "the session title is kept, as the secondary line")
    }

    func testEveryStringOnARowIsSanitized() {
        let title = "Deploy\u{202E}\u{200B}\n" + String(repeating: "T", count: 500)
        var item = F.item("turn:a", title: title, detail: "Running\u{202E} terminal\nline two")
        item.state = .finished(.failed("boom\u{2066}\n" + String(repeating: "E", count: 500)))
        let row = NotchRowBuilder.build(items: [item], now: F.t0).rows[0]
        XCTAssertLessThanOrEqual(row.title.count, NotchRowBuilder.titleLimit)
        XCTAssertTrue(row.title.hasSuffix(MacUntrustedText.ellipsis))
        XCTAssertLessThanOrEqual(row.detail?.count ?? 0, NotchRowBuilder.commandLimit)
        for text in [row.title, row.detail ?? ""] {
            XCTAssertFalse(text.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) || $0.value == 0x200B || $0.value == 0x0A })
        }
    }

    func testTitleThatSanitizesToNothingFallsBackToUntitledChat() {
        let list = NotchRowBuilder.build(items: [F.item("turn:a", title: "\u{200B}\u{202E}")], now: F.t0)
        XCTAssertEqual(list.rows[0].title, AppLocalization.string("Untitled chat"))
    }

    func testShortCleanCommandCanBeAllowedInline() {
        let content = NotchApprovalContent.make(F.approval(command: "ls -la"))
        XCTAssertFalse(content.needsReview)
    }

    func testTruncatedCommandRequiresReview() {
        let content = NotchApprovalContent.make(F.approval(command: "echo " + String(repeating: "A", count: 400)))
        XCTAssertTrue(content.needsReview)
        XCTAssertTrue(content.command.hasSuffix(MacUntrustedText.ellipsis))
    }

    func testCommandWithHiddenCharactersRequiresReview() {
        XCTAssertTrue(NotchApprovalContent.make(F.approval(command: "ls\u{202E} gpj.txt")).needsReview)
        XCTAssertTrue(NotchApprovalContent.make(F.approval(command: "r\u{200B}m -rf x")).needsReview)
    }

    func testEmptyOrInvisibleCommandRequiresReview() {
        XCTAssertTrue(NotchApprovalContent.make(F.approval(command: "")).needsReview)
        XCTAssertTrue(NotchApprovalContent.make(F.approval(command: "\u{200B}\n")).needsReview)
    }

    func testMultilineCommandWithoutHiddenCharactersStaysReviewable() {
        let content = NotchApprovalContent.make(F.approval(command: "cd /tmp\nls"))
        XCTAssertEqual(content.command, "cd /tmp ls")
        XCTAssertFalse(content.needsReview)
    }

    func testSummaryIsSanitizedAndCapped() {
        var a = F.approval(command: "ls")
        a.description = "Run\u{202E} this\n" + String(repeating: "D", count: 300)
        let content = NotchApprovalContent.make(a)
        XCTAssertLessThanOrEqual(content.summary?.count ?? 0, NotchApprovalContent.summaryLimit)
        XCTAssertTrue(content.needsReview, "the description was cut and had a bidi override")
    }

    // MARK: button -> choice mapping (display text never picks the choice)

    func testActionsMapToFixedChoicesThatTheBaseAllows() {
        XCTAssertEqual(NotchApprovalAction.allowOnce.choice, AgentActivityApprovalChoices.once)
        XCTAssertEqual(NotchApprovalAction.deny.choice, AgentActivityApprovalChoices.deny)
        XCTAssertEqual(NotchApprovalAction.allowSession.choice, AgentActivityApprovalChoices.session)
        XCTAssertEqual(NotchApprovalAction.allowAlways.choice, AgentActivityApprovalChoices.always)
        XCTAssertNil(NotchApprovalAction.reviewInConduit.choice, "review never answers")
    }

    func testOfferedActionsAreAlwaysASubsetOfTheBasesAllowedChoices() {
        let cases = [F.approval(), F.approval(allowPermanent: false), F.approval(smartDenied: true),
                     F.approval(choices: ["deny"]), F.approval(choices: ["once", "always"], allowPermanent: false),
                     F.approval(choices: ["session", "bogus"])]
        for a in cases {
            let allowed = Set(AgentActivityApprovalChoices.allowed(for: a))
            let choices = NotchApprovalChoices.resolve(a)
            for review in [false, true] {
                let actions = choices.inlineActions(needsReview: review) + choices.menuActions(needsReview: review)
                for action in actions {
                    if let choice = action.choice { XCTAssertTrue(allowed.contains(choice), "\(action) not allowed for \(a.choices ?? [])") }
                }
            }
        }
    }

    func testInlineAndMenuActionsFollowTheChoiceRule() {
        let all = NotchApprovalChoices.resolve(F.approval())
        XCTAssertEqual(all.inlineActions(needsReview: false), [.allowOnce, .deny])
        XCTAssertEqual(all.menuActions(needsReview: false), [.allowSession, .allowAlways], "session and always are menu-only")
        let noPermanent = NotchApprovalChoices.resolve(F.approval(allowPermanent: false))
        XCTAssertEqual(noPermanent.menuActions(needsReview: false), [.allowSession])
        let denyOnly = NotchApprovalChoices.resolve(F.approval(choices: ["deny"]))
        XCTAssertEqual(denyOnly.inlineActions(needsReview: false), [.deny])
    }

    func testReviewReplacesAllowOnceAndRemovesTheMenuButKeepsDeny() {
        let all = NotchApprovalChoices.resolve(F.approval())
        XCTAssertEqual(all.inlineActions(needsReview: true), [.reviewInConduit, .deny])
        XCTAssertTrue(all.menuActions(needsReview: true).isEmpty)
    }

    func testLabelsAreFixedAndDoNotDependOnPayloadText() {
        let labels = [NotchApprovalAction.allowOnce, .deny, .allowSession, .allowAlways, .reviewInConduit].map(\.label)
        XCTAssertEqual(labels, ["Allow once", "Deny", "Allow for session", "Always allow", "Review in Conduit"].map { AppLocalization.string($0) })
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
