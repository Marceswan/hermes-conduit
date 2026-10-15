import XCTest
@testable import ConduitMac

final class NotchStatusStateTests: XCTestCase {
    private func counts(decisions: Int = 0, needs: Int? = nil, working: Int = 0, recent: Int = 0) -> NotchCounts {
        NotchCounts(decisions: decisions, needsUser: needs ?? decisions, working: working, recent: recent)
    }
    private func make(_ mode: NotchMode = .activeAgents) -> NotchStatusState { NotchStatusState(mode: mode) }

    @discardableResult
    private func send(_ s: inout NotchStatusState, _ i: NotchInput) -> [NotchEffect] { s.apply(i) }

    func testIdleIsHidden() {
        XCTAssertEqual(make().surface, .hidden)
    }

    func testWorkingShowsCompactAndHoverExpandsAfterDelays() {
        var s = make()
        send(&s, .counts(counts(working: 1), newDecision: false, newFinish: false))
        XCTAssertEqual(s.surface, .compact)
        XCTAssertEqual(send(&s, .hoverEntered), [.cancel(.hoverOut), .schedule(.hoverIn, after: 0.2)])
        XCTAssertEqual(s.surface, .compact, "not before 200 ms")
        send(&s, .timer(.hoverIn))
        XCTAssertEqual(s.surface, .expanded)
        XCTAssertEqual(send(&s, .hoverExited), [.cancel(.hoverIn), .schedule(.hoverOut, after: 0.4)])
        XCTAssertEqual(s.surface, .expanded, "not before 400 ms")
        send(&s, .timer(.hoverOut))
        XCTAssertEqual(s.surface, .compact)
    }

    func testHoverThatLeavesBeforeTheDelayNeverExpands() {
        var s = make()
        send(&s, .counts(counts(working: 1), newDecision: false, newFinish: false))
        send(&s, .hoverEntered)
        send(&s, .hoverExited)
        send(&s, .timer(.hoverIn))
        XCTAssertEqual(s.surface, .compact)
    }

    func testNewDecisionExpandsStickyAnnouncesAndGuardsClicksFor600ms() {
        var s = make()
        let fx = send(&s, .counts(counts(decisions: 1), newDecision: true, newFinish: false))
        XCTAssertEqual(s.surface, .expanded)
        XCTAssertFalse(s.buttonsEnabled)
        XCTAssertEqual(fx, [.schedule(.clickGuard, after: 0.6), .announceAttention])
        send(&s, .timer(.clickGuard))
        XCTAssertTrue(s.buttonsEnabled)
    }

    func testClickGuardRestartsOnASecondDecision() {
        var s = make()
        send(&s, .counts(counts(decisions: 1), newDecision: true, newFinish: false))
        send(&s, .timer(.clickGuard))
        let fx = send(&s, .counts(counts(decisions: 2), newDecision: true, newFinish: false))
        XCTAssertFalse(s.buttonsEnabled)
        XCTAssertTrue(fx.contains(.schedule(.clickGuard, after: 0.6)))
    }

    func testStickyDecisionStaysWhilePointerLeavesUntilUserInteracted() {
        var s = make()
        send(&s, .counts(counts(decisions: 1), newDecision: true, newFinish: false))
        send(&s, .hoverEntered)
        XCTAssertTrue(send(&s, .hoverExited).isEmpty, "no collapse before interaction")
        XCTAssertEqual(s.surface, .expanded)
        send(&s, .hoverEntered)
        send(&s, .interacted)
        XCTAssertEqual(send(&s, .hoverExited), [.cancel(.hoverIn), .schedule(.hoverOut, after: 0.4)])
        send(&s, .timer(.hoverOut))
        XCTAssertEqual(s.surface, .compact)
    }

    func testResolvingTheDecisionReleasesTheStickyExpand() {
        var s = make()
        send(&s, .counts(counts(decisions: 1, working: 1), newDecision: true, newFinish: false))
        let fx = send(&s, .counts(counts(working: 1), newDecision: false, newFinish: false))
        XCTAssertEqual(s.surface, .compact)
        XCTAssertTrue(fx.contains(.cancel(.clickGuard)))
        XCTAssertTrue(s.buttonsEnabled)
    }

    func testFinishFlashesFourSecondsThenSettlesToCompactWhileDoneRowsRemain() {
        var s = make()
        send(&s, .counts(counts(working: 1), newDecision: false, newFinish: false))
        let fx = send(&s, .counts(counts(recent: 1), newDecision: false, newFinish: true))
        XCTAssertEqual(s.surface, .expanded)
        XCTAssertEqual(fx, [.schedule(.flash, after: 4.0)])
        send(&s, .timer(.flash))
        XCTAssertEqual(s.surface, .compact)
    }

    func testEverythingGoneHidesAndCancelsTimers() {
        var s = make()
        send(&s, .counts(counts(recent: 1), newDecision: false, newFinish: true))
        let fx = send(&s, .counts(counts(), newDecision: false, newFinish: false))
        XCTAssertEqual(s.surface, .hidden)
        XCTAssertTrue(fx.contains(.cancel(.flash)))
    }

    func testEscapeAndClickOutsideCollapseAPinnedPanelAndDoNotRepin() {
        var s = make()
        send(&s, .counts(counts(decisions: 1), newDecision: true, newFinish: false))
        send(&s, .dismissRequested)
        XCTAssertEqual(s.surface, .compact)
        send(&s, .counts(counts(decisions: 1), newDecision: false, newFinish: false))
        XCTAssertEqual(s.surface, .compact, "same decision does not re-expand")
        send(&s, .toggleCommandPin)
        XCTAssertEqual(s.surface, .expanded)
        send(&s, .dismissRequested)
        XCTAssertFalse(s.isCommandPinned)
    }

    func testDismissWhenNotExpandedIsANoOp() {
        var s = make()
        send(&s, .counts(counts(working: 1), newDecision: false, newFinish: false))
        XCTAssertTrue(send(&s, .dismissRequested).isEmpty)
        XCTAssertEqual(s.surface, .compact)
    }

    func testOnlyWhenNeededHidesWorkAndShowsCompactForNeedsYouAndExpandsOnDecision() {
        var s = make(.onlyWhenNeeded)
        send(&s, .counts(counts(working: 2), newDecision: false, newFinish: false))
        XCTAssertEqual(s.surface, .hidden)
        send(&s, .counts(counts(working: 2, recent: 1), newDecision: false, newFinish: true))
        XCTAssertEqual(s.surface, .hidden, "no done flash in this mode")
        send(&s, .counts(counts(needs: 1, working: 2), newDecision: false, newFinish: false))
        XCTAssertEqual(s.surface, .compact, "a blocked Kanban card shows but does not pop")
        send(&s, .counts(counts(decisions: 1, working: 2), newDecision: true, newFinish: false))
        XCTAssertEqual(s.surface, .expanded)
        send(&s, .counts(counts(working: 2), newDecision: false, newFinish: false))
        XCTAssertEqual(s.surface, .hidden)
    }

    func testOffHidesEverythingButAnExplicitCommandPinStillShows() {
        var s = make(.off)
        send(&s, .counts(counts(decisions: 1), newDecision: true, newFinish: false))
        XCTAssertEqual(s.surface, .hidden)
        XCTAssertTrue(s.buttonsEnabled)
        send(&s, .toggleCommandPin)
        XCTAssertEqual(s.surface, .expanded)
        send(&s, .toggleCommandPin)
        XCTAssertEqual(s.surface, .hidden)
    }

    func testSwitchingToOffCollapsesAndCancelsEverything() {
        var s = make()
        send(&s, .counts(counts(decisions: 1), newDecision: true, newFinish: false))
        let fx = send(&s, .mode(.off))
        XCTAssertEqual(s.surface, .hidden)
        XCTAssertTrue(Set(fx).isSuperset(of: [.cancel(.hoverIn), .cancel(.hoverOut), .cancel(.flash), .cancel(.clickGuard)]))
    }

    func testOfflineHidesUnlessPinnedAndNeverFlashes() {
        var s = make()
        send(&s, .counts(counts(working: 1), newDecision: false, newFinish: false))
        send(&s, .online(false))
        XCTAssertEqual(s.surface, .hidden)
        send(&s, .toggleCommandPin)
        XCTAssertEqual(s.surface, .expanded, "pinned panel shows the disconnected state")
        send(&s, .toggleCommandPin)
        send(&s, .counts(counts(recent: 1), newDecision: false, newFinish: true))
        XCTAssertEqual(s.surface, .hidden)
    }

    func testPinnedWithNothingToShowIsExpandedForTheEmptyState() {
        var s = make()
        send(&s, .toggleCommandPin)
        XCTAssertEqual(s.surface, .expanded)
    }

    func testClickGuardDoesNotOutliveItsDecisionAfterEscape() {
        var s = make()
        send(&s, .counts(counts(decisions: 1), newDecision: true, newFinish: false))
        send(&s, .dismissRequested)
        XCTAssertTrue(s.buttonsEnabled)
    }
}
