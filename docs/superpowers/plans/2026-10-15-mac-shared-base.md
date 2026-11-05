# Mac Shared Base Implementation Plan (Floating Panel, Stream Hub, Agent Activity Feed)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The shared foundation three approved Mac features stand on: a non-activating floating panel (`MacFloatingPanel`), a Mac-side multicast hub that sees every session's stream events, and an `AgentActivityFeed` that turns those events plus a scene-independent `session.active_list` poll into typed items and events, with a visible connection state and a Mac-only reconnect-while-inactive exemption.

**Architecture:** Pure value types carry all logic that can be tested without AppKit or a gateway: placement geometry, the activity reducer (`state + input -> state + events`), the poll cadence and the approval-choice rules. Thin main-actor shells wrap them: `MacFloatingPanelController` (AppKit), `MacStreamEventHub` (multicast), `AgentActivityPoller` and `AgentActivityFeed` (Combine, injected sources, clock and sleeper). Upstream `Conduit/Services/AppState.swift` gets exactly two `#if os(macOS) // MAC:` edits: one hub publish line in `handleStreamEvent`, and one early return in `canRunTransportRecovery`.

**Tech Stack:** Swift 5.9 mode / SwiftUI / AppKit on macOS 14+, Combine, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Specs (read all three; the plan argues from them):**
- `docs/superpowers/specs/2026-10-15-mac-quick-ask-design.md` (owns `MacFloatingPanel`; Quick Ask consumes the hub)
- `docs/superpowers/specs/2026-10-15-mac-notch-status-design.md` (owns `AgentActivityFeed`; reuses the panel)
- `docs/superpowers/specs/2026-10-15-mac-notifications-design.md` (consumes the feed)

Open questions in those specs are resolved to each spec's own proposed default; the ones that touch the shared base are listed under "Resolved Decisions".

## Global Constraints

- Mac only. Never run an iOS build or iOS tests (project scope: macOS only). iOS behaviour is unchanged by construction: both upstream edits are `#if os(macOS)` gated.
- New code lives under `ConduitMac/Panels/` (panel), `ConduitMac/Shared/` (hub) and `ConduitMac/Activity/` (feed). Tests live in `ConduitMacTests/`. `ConduitMac/` is picked up by the folder glob in `project.yml`; re-run `xcodegen generate` after adding any file.
- Upstream edits: exactly two, both in `Conduit/Services/AppState.swift`, each `#if os(macOS) // MAC: <reason>` ... `#endif // MAC:`, each with one row in `docs/macos/PORTING_LEDGER.md` (Task 5 and Task 13). `git diff <base> -- Conduit Shared | grep '^-[^-]'` prints nothing after Task 5, and exactly one removed line after Task 13 (the original `canRunTransportRecovery` expression, re-added with `return` inside the `#else` branch; Swift cannot put `#if` around a bare single-expression body).
- The working tree has unrelated uncommitted edits in `Conduit/Services/AppState.swift` and `Conduit/Views/ChatView.swift`. Never stage them. Never run `git add -A`, `git add .` or `git commit -a`; stage explicit paths only. Never revert, reformat or stash those edits in the main checkout.
- Where to work: because `AppState.swift` is dirty in the main checkout, execute this plan in a worktree branched from `macos`: `git worktree add ../conduit-macos-shared-base -b mac-shared-base macos` (check `df -h` first; under about 20 GB free, prune first). The worktree has a clean `AppState.swift`, so `git add Conduit/Services/AppState.swift` in Tasks 5 and 13 stages only your hunk. If you must work in the main checkout instead, stage the AppState hunk without the user's edits: `git diff -U0 -- Conduit/Services/AppState.swift > "$TMPDIR/appstate.patch"`, delete every hunk that is not yours, then `git apply --cached --unidiff-zero "$TMPDIR/appstate.patch"`. After the branch is merged and the merge gate passed, remove the worktree, delete the branch and delete `build/dd` there at once.
- Find edit anchors by symbol, not by line number. Line numbers in this plan are for orientation only and move when the user's pending edits land.
- zsh: quote every glob and every path containing `*`, `[`, `?` (for example `git add 'ConduitMac/Panels/MacFloatingPanel.swift'`).
- Build: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`
- Test one class: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/<ClassName>`. Never run two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- TDD: failing test, run to see it fail, minimal implementation, run to see it pass, commit. The code in this plan is the intended shape; if the compiler rejects a detail (a concurrency annotation, an access level), fix the detail without changing tested behaviour.
- Tests: injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`, `settle`), explicit teardown, no fixed sleeps, injected clock and sleeper for anything timed. Never touch the live app's defaults, never register a real global hotkey, never post a real notification. Every hosted panel is hidden and closed in `tearDown`.
- Safety: the user's own Conduit is running. Do not quit it, click it or type into it; never touch a Conduit login form. A hosted test panel must not activate the app (`show()` uses `orderFrontRegardless`).
- Concurrency: everything stateful is `@MainActor`. Pure types are plain value types with no AppKit, Combine or AppState import. No `Date()` or `Task.sleep` inside the reducer, cadence or placement code; time arrives as a parameter.
- Localization: the shared base has no user-visible strings (titles and details come from the gateway; the consumers own copy). If a task needs one, use `AppLocalization.string("...")` with an English source key.
- The feed never writes `AppState.liveSessionStatusIndex`, `turnState` or any other AppState field. Its one write path is approval response (Task 11).
- Docs: one section titled `Mac shared base: floating panel, stream hub, activity feed (2026-10-15)` in `docs/macos/DECISIONS.md` (Task 14). It carries no `D<number>`: the specs each claim D15 and D16, and the consumer plans own those numbers.

## Verified Gateway Facts (from a source read of `tui_gateway/`; the design rests on these)

1. One WebSocket receives events for every session it created or resumed. Subscriptions are additive and are never removed until the socket closes.
2. Prompts can run concurrently in several sessions on one socket (optional `max_concurrent_sessions` cap; refusal is error 4090). Quick Ask relies on this.
3. Sessions in the same gateway process appear in `session.active_list`, but push events only after `session.activate`/`session.resume` attaches this socket. Such sessions are poll-only: the feed knows working/waiting and nothing else until `approval.pending` answers.
4. Sessions from other processes (CLI, Slack, a separate cron process) are invisible to `session.active_list`. The feed cannot show them; consumer copy must not promise full coverage.
5. Approval methods: `approval.pending`, `approval.received`, `approval.respond`. Choices are `once`, `session`, `always`, `deny`, built per request; a smart-denied request offers only `once` and `deny`.
6. The Mac app keeps the socket while inactive or windowless (`applicationShouldTerminateAfterLastWindowClosed` is false), but `AppState.scheduleReconnect` is blocked unless `isSceneActive` (Task 13 fixes that) and `refreshLiveSessionStatuses()` returns early unless `isSceneActive` (the feed polls on its own, Task 9).
7. Unverified, so it degrades instead of failing: whether `approval.pending` and `approval.respond` answer for a session this socket is not attached to. A failed or empty `approval.pending` yields a no-button "open in Conduit" row (Task 8).

## Resolved Decisions (spec open questions, spec defaults)

- Notch Q1 (does the socket survive inactive/window closed): yes (fact 6); only reconnect needs the exemption, which is Task 13.
- Notch Q2 and Notifications Q1 (events for sessions not active in AppState): socket-attached sessions deliver events through the hub; others come from the poll (facts 1 and 3).
- Notch Q3 default on, Q4 `NSScreen.main`, Q5 Kanban deep link later: consumer concerns, nothing in the base.
- Quick Ask Q1-Q5 and Notifications Q2-Q5: consumer concerns, nothing in the base.

## Decisions This Plan Makes Where The Specs Leave A Gap

1. **Hub instead of two direct calls.** The Quick Ask spec's `MacQuickAskStreamTap.shared.observe(event)` and the notch spec's `AgentActivityFeed.shared?.observe(event)` are replaced by one upstream line, `MacStreamEventHub.shared.publish(event)`. `MacQuickAskStreamTap` becomes a hub subscriber (Quick Ask plan); the feed subscribes in `start()`. `AgentActivityFeed.observe(_:)` stays public for tests and for a consumer that wants to inject.
2. **Panel folder.** `ConduitMac/Panels/` as the Quick Ask spec says (not `Shared/`).
3. **Placement fraction.** The spec's `.screenCenterTop(fromTop:)` takes points but Quick Ask wants "0.22 of screen height". `MacFloatingPanelPlacement` gains the case `.screenCenterTopFraction(CGFloat)`; the spec's three cases are unchanged.
4. **Panel hooks the notch spec lists as gaps** are added additively with defaults (Task 3): menu-bar overlap, content width and height, mouse enter/exit, shadow off. The hit-test shape (clicks through the empty corners of the rectangle) is left to the notch plan, which owns its view.
4a. **Draggable, edge-docked panel (user scope change after the specs).** The notch surface can sit at any point along any screen edge. `MacFloatingPanelPlacement` gains `.edgeDocked(edge: NSRectEdge, offset: CGFloat, screenID: UInt32?)` (Task 3A, pure `EdgeDockGeometry`); `MacFloatingPanelConfig` gains `isDraggable`, `dragThreshold` (4 pt) and `onPlacementChanged` (Task 3B). A drag moves the panel freely; on release it snaps to the nearest edge of the screen under the pointer and reports the resulting placement. `.notchAnchored` stays the default, and a saved screen that no longer exists falls back to it. Persistence and the per-edge layout of the content belong to the notch plan.
5. **Item fields beyond the spec:** `startedAt` (turn start; `since` is when the current state began, so a finished item's duration is `since - startedAt`), `turnSeq` (per-session turn counter, the dedupe key for "one Done per turn"), `isPollOnly`, `failure` (last respond error), `openQuestionCount`. `AgentActivityEvent.Reason` is `answeredHere | answeredElsewhere | expired | withdrawn | sessionClosed` because the notch spec's own tests need the here/elsewhere split; Notifications treats both answered cases as `answered`.
6. **Turn item id is `turn:<runtimeId>`** (stable for a turn's life; poll rows and stream events both always know the runtime id). `sessionKey` carries the durable id (catalog id, else stored id, else lineage root, else runtime id) so consumers match through `alternateIds`.
7. **`Kind.kanban`, `Kind.cron` and `State.blocked` exist but this plan never produces them.** Kanban and cron sources belong to the notch plan; the enum cases are reserved so the spec's API is stable.
8. **No `sessionInterrupted` stream event exists** (the spec mentions one); `.messageInterrupted` is the only interrupt signal.
9. **A completed turn reopens on new work within 3 s** (same `turnSeq`, no second `turnStarted`) because the Quick Ask spec flags that tool turns may emit several `messageComplete` segments. A second `turnFinished` for the same `turnSeq` is possible; consumers dedupe on `(sessionKey, turnSeq)`.
10. **`AgentActivityFeed.isBaselined`** (published) turns true once the first poll and its approval fetches finished, so a consumer calls `snapshot()` after it and sees what was already pending.

## Review Focus

1. A key panel dismissed by Esc must fire `onDismiss` once even though AppKit sends `resignKey` while ordering it out (Task 2).
2. A stream event for a session that is not the active one must reach hub subscribers, and `AppState` must still ignore it exactly as before, including the two early-return paths (`sessionTitle`, `statusUpdate`) (Task 5).
3. One flaky `session.active_list` response that omits a working session must not finish its turn; two consecutive misses do (Task 8).
4. A replayed or duplicated `approval` event (after a reconnect) must neither duplicate the row nor raise a second `decisionRequested` (Task 7).
5. Approving with a choice the request does not offer (`always` on a smart-denied request, or when `allowPermanent` is false) must be refused before any RPC (Task 11).
6. A press-and-release on a draggable panel that moves under 4 pt is a click (content receives it, no placement callback); a docked panel whose saved screen was unplugged returns to the notch-anchored default instead of landing off-screen (Tasks 3A and 3B).

## File Map

- Create `ConduitMac/Panels/MacFloatingPanelPlacement.swift`: pure placement, screen choice and resize geometry (Task 1).
- Create `ConduitMac/Panels/MacFloatingPanel.swift`: `MacFloatingPanelConfig`, `MacFloatingPanelEnvironment`, `MacFloatingPanel`, `MacFloatingPanelController` (Tasks 2 and 3).
- Create `ConduitMac/Panels/EdgeDockGeometry.swift`: pure edge-dock math (Task 3A). Create `ConduitMac/Panels/MacPanelDragTracker.swift`: pure click-versus-drag tracker (Task 3B).
- Create `ConduitMac/Shared/MacStreamEventHub.swift`: multicast hub (Task 4).
- Modify `Conduit/Services/AppState.swift` (`handleStreamEvent`): publish line (Task 5). Modify it again (`canRunTransportRecovery`) in Task 13.
- Create `ConduitMac/Activity/AgentActivityModels.swift`: items, events, availability, approval choice rules (Task 6).
- Create `ConduitMac/Activity/AgentActivityReducer.swift`: state, inputs, reducer (Tasks 7, 8, 12).
- Create `ConduitMac/Activity/AgentActivitySources.swift`: sources protocol, live implementation, cadence, poller (Task 9).
- Create `ConduitMac/Activity/AgentActivityFeed.swift`: the observable shell (Tasks 10, 11, 12).
- Create `ConduitMac/Activity/AgentActivityConnection.swift`: connection state derivation (Task 12).
- Create `ConduitMac/Activity/MacActivityBootstrap.swift`; modify `ConduitMac/App/ConduitMacAppDelegate.swift` (Task 14).
- Tests: `MacFloatingPanelPlacementTests`, `EdgeDockGeometryTests`, `MacPanelDragTrackerTests`, `MacFloatingPanelTests`, `MacStreamEventHubTests`, `MacStreamTapTests`, `AgentActivityModelsTests`, `AgentActivityReducerStreamTests`, `AgentActivityReducerPollTests`, `AgentActivityPollerTests`, `AgentActivityFeedTests`, `AgentActivityApprovalTests`, `AgentActivityConnectionTests`, `MacTransportRecoveryTests`; support files `MacSharedBaseTestSupport.swift`, `AgentActivityTestSupport.swift`, `AgentActivitySourcesTestSupport.swift` (all in `ConduitMacTests/`).
- Docs: `docs/macos/PORTING_LEDGER.md` (2 rows), `docs/macos/DECISIONS.md` (1 section), `docs/macos/SMOKE_CHECKLIST.md` (1 section).

---

### Task 1: Placement geometry (pure)

**Files:**
- Create: `ConduitMac/Panels/MacFloatingPanelPlacement.swift`
- Test: `ConduitMacTests/MacFloatingPanelPlacementTests.swift`

**Interfaces:**
- Produces:
  - `struct MacScreenGeometry: Equatable { var frame: CGRect; var visibleFrame: CGRect; var safeAreaTop: CGFloat = 0 }` (AppKit bottom-left global coordinates)
  - `enum MacFloatingPanelPlacement { case screenCenterTop(fromTop: CGFloat); case screenCenterTopFraction(CGFloat); case notchAnchored; case custom((_ panelSize: CGSize) -> CGRect) }`
  - `func frame(panelSize: CGSize, screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat) -> CGRect`
  - `func targetScreenIndex(mouse: CGPoint, screens: [MacScreenGeometry]) -> Int?`
  - `static func resized(_ frame: CGRect, to size: CGSize, maxHeight: CGFloat, within bounds: CGRect) -> CGRect` (top edge and horizontal center stay put)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacFloatingPanelPlacementTests: XCTestCase {
    /// Dock 70 pt at the bottom, menu bar 24 pt.
    private let primary = MacScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 806))
    private let right = MacScreenGeometry(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private let below = MacScreenGeometry(
        frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1055))
    /// A 14-inch class notch display to the right of the primary.
    private let notch = MacScreenGeometry(
        frame: CGRect(x: 1440, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1512, height: 950),
        safeAreaTop: 32)
    private let size = CGSize(width: 600, height: 80)

    private func frame(_ placement: MacFloatingPanelPlacement, on screen: MacScreenGeometry, size: CGSize? = nil) -> CGRect {
        placement.frame(panelSize: size ?? self.size, screenFrame: screen.frame,
                        visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaTop)
    }

    func testCenterTopFromTopInPoints() {
        // top = 876 - 100 = 776, so y = 696; x = 720 - 300.
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: primary), CGRect(x: 420, y: 696, width: 600, height: 80))
    }

    func testCenterTopFractionUsesTheVisibleHeight() {
        let f = frame(.screenCenterTopFraction(0.22), on: primary)
        XCTAssertEqual(f.maxY, 876 - 0.22 * 806, accuracy: 0.001)
        XCTAssertEqual(f.midX, 720, accuracy: 0.001)
    }

    func testCenteredInTheVisibleFrameWhenTheDockIsOnTheLeft() {
        let dockLeft = MacScreenGeometry(frame: primary.frame, visibleFrame: CGRect(x: 80, y: 0, width: 1360, height: 876))
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: dockLeft).minX, 80 + 680 - 300)
    }

    func testSecondaryScreenToTheRight() {
        // top = 1055 - 100 = 955, y = 875; x = 1440 + 960 - 300.
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: right), CGRect(x: 2100, y: 875, width: 600, height: 80))
    }

    func testScreenBelowThePrimaryHasNegativeY() {
        // top = -1080 + 1055 - 100 = -125.
        XCTAssertEqual(frame(.screenCenterTop(fromTop: 100), on: below), CGRect(x: 660, y: -205, width: 600, height: 80))
    }

    func testPanelTallerThanTheScreenShortensWithTheTopFixed() {
        let f = frame(.screenCenterTop(fromTop: 100), on: primary, size: CGSize(width: 600, height: 2000))
        XCTAssertEqual(f.maxY, 776)
        XCTAssertEqual(f.minY, 70)
    }

    func testPanelWiderThanTheScreenClamps() {
        let f = frame(.screenCenterTop(fromTop: 100), on: primary, size: CGSize(width: 5000, height: 80))
        XCTAssertEqual(f.minX, 0)
        XCTAssertEqual(f.width, 1440)
    }

    func testNotchAnchoredIsFlushWithTheTopAndCentered() {
        let f = frame(.notchAnchored, on: notch, size: CGSize(width: 400, height: 60))
        XCTAssertEqual(f, CGRect(x: 1440 + 756 - 200, y: 982 - 60, width: 400, height: 60))
    }

    func testCustomIsPassedThrough() {
        let custom = MacFloatingPanelPlacement.custom { s in CGRect(x: 1, y: 2, width: s.width, height: s.height) }
        XCTAssertEqual(frame(custom, on: primary), CGRect(x: 1, y: 2, width: 600, height: 80))
    }

    // MARK: - Screen choice

    func testMouseScreenIsChosen() {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 100, y: 100), screens: [primary, right]), 0)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 2000, y: 500), screens: [primary, right]), 1)
    }

    func testMouseOnTheTopEdgeStillCountsAsInsideThatScreen() {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 2000, y: 1080), screens: [primary, right]), 1)
    }

    func testMouseOutsideEveryScreenFallsBackToTheFirst() {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: -5000, y: -5000), screens: [primary, right]), 0)
    }

    func testNoScreensIsNil() {
        XCTAssertNil(MacFloatingPanelPlacement.notchAnchored.targetScreenIndex(mouse: .zero, screens: []))
    }

    func testNotchAnchoredPrefersANotchScreenOverTheMouseScreen() {
        XCTAssertEqual(MacFloatingPanelPlacement.notchAnchored.targetScreenIndex(mouse: CGPoint(x: 100, y: 100), screens: [primary, notch]), 1)
    }

    func testNotchAnchoredWithoutANotchScreenUsesTheMouseScreen() {
        XCTAssertEqual(MacFloatingPanelPlacement.notchAnchored.targetScreenIndex(mouse: CGPoint(x: 2000, y: 500), screens: [primary, right]), 1)
    }

    // MARK: - Resize

    func testResizeGrowsDownKeepingTheTopAndTheCenter() {
        let start = CGRect(x: 420, y: 696, width: 600, height: 80)
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 600, height: 300), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f, CGRect(x: 420, y: 476, width: 600, height: 300))
    }

    func testResizeCapsAtMaxHeight() {
        let start = CGRect(x: 420, y: 696, width: 600, height: 80)
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 600, height: 900), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f.height, 480)
        XCTAssertEqual(f.maxY, 776)
    }

    func testResizeStopsAtTheBottomOfTheVisibleFrame() {
        let start = CGRect(x: 420, y: 70, width: 600, height: 80)   // top = 150
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 600, height: 400), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f.height, 80)
        XCTAssertEqual(f.minY, 70)
    }

    func testResizeWidthKeepsTheCenter() {
        let start = CGRect(x: 420, y: 696, width: 600, height: 80)
        let f = MacFloatingPanelPlacement.resized(start, to: CGSize(width: 400, height: 80), maxHeight: 480, within: primary.visibleFrame)
        XCTAssertEqual(f.minX, 520)
        XCTAssertEqual(f.midX, start.midX)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacFloatingPanelPlacementTests`
Expected: build failure, `cannot find 'MacScreenGeometry' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics

/// One screen's geometry in AppKit's bottom-left global coordinates. The
/// controller builds it from `NSScreen`; tests build it by hand.
struct MacScreenGeometry: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`: the notch height, 0 without a notch.
    var safeAreaTop: CGFloat = 0

    var hasNotch: Bool { safeAreaTop > 0 }
}

/// Where a floating panel goes. Pure: no AppKit windows, only rectangles.
enum MacFloatingPanelPlacement {
    /// Screen under the mouse; x centered in `visibleFrame`; `fromTop` points below its top.
    case screenCenterTop(fromTop: CGFloat)
    /// Same, with the distance as a fraction of the visible height (Quick Ask uses 0.22).
    case screenCenterTopFraction(CGFloat)
    /// A screen with a notch (else the mouse screen); x centered, top flush with the screen edge.
    case notchAnchored
    /// The caller computes the whole frame (the notch pill reads `NotchGeometry`).
    case custom((_ panelSize: CGSize) -> CGRect)

    func frame(panelSize: CGSize, screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat) -> CGRect {
        switch self {
        case .screenCenterTop(let fromTop):
            return Self.topCentered(panelSize, fromTop: fromTop, in: visibleFrame)
        case .screenCenterTopFraction(let fraction):
            return Self.topCentered(panelSize, fromTop: visibleFrame.height * fraction, in: visibleFrame)
        case .notchAnchored:
            let width = min(panelSize.width, screenFrame.width)
            let height = min(panelSize.height, screenFrame.height)
            let x = min(max(screenFrame.midX - width / 2, screenFrame.minX), screenFrame.maxX - width)
            return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
        case .custom(let build):
            return build(panelSize)
        }
    }

    /// Index of the screen the panel belongs on, or nil with no screens.
    func targetScreenIndex(mouse: CGPoint, screens: [MacScreenGeometry]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let mouseIndex = screens.firstIndex { Self.inclusiveContains($0.frame, mouse) } ?? 0
        guard case .notchAnchored = self else { return mouseIndex }
        if screens[mouseIndex].hasNotch { return mouseIndex }
        return screens.firstIndex { $0.hasNotch } ?? mouseIndex
    }

    /// The new frame when content size changes: the top edge and the
    /// horizontal center stay put, height is capped by `maxHeight` and by the
    /// room left above the bottom of `bounds`.
    static func resized(_ frame: CGRect, to size: CGSize, maxHeight: CGFloat, within bounds: CGRect) -> CGRect {
        let top = frame.maxY
        let width = min(size.width, bounds.width)
        let height = min(size.height, maxHeight, max(top - bounds.minY, 0))
        let x = min(max(frame.midX - width / 2, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    private static func topCentered(_ size: CGSize, fromTop: CGFloat, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let top = max(visible.minY, visible.maxY - max(fromTop, 0))
        let height = min(size.height, top - visible.minY)
        let x = min(max(visible.midX - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// `CGRect.contains` excludes the top and right edges; a mouse pinned to
    /// the top of a screen reports exactly `maxY`.
    private static func inclusiveContains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the same command as Step 2.
Expected: all MacFloatingPanelPlacementTests pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Panels/MacFloatingPanelPlacement.swift' 'ConduitMacTests/MacFloatingPanelPlacementTests.swift'
git commit -m "macOS: floating panel placement geometry (shared base)"
```

---

### Task 2: MacFloatingPanel and MacFloatingPanelController (Quick Ask API)

**Files:**
- Create: `ConduitMac/Panels/MacFloatingPanel.swift`
- Test: `ConduitMacTests/MacFloatingPanelTests.swift`

**Interfaces:**
- Consumes: `MacFloatingPanelPlacement`, `MacScreenGeometry` (Task 1); `HostedTestSupport` (existing).
- Produces:
  - `struct MacFloatingPanelConfig { var size: NSSize; var maxHeight: CGFloat = 480; var placement: MacFloatingPanelPlacement; var canBecomeKey: Bool; var dismissOnResignKey: Bool; var dismissOnEscape: Bool = true; var level: NSWindow.Level = .floating; var joinsAllSpaces: Bool = true; var onDismiss: (() -> Void)? = nil }`
  - `struct MacFloatingPanelEnvironment { var screens: () -> [MacScreenGeometry]; var mouseLocation: () -> CGPoint; var reduceMotion: () -> Bool; static let live }`
  - `final class MacFloatingPanel: NSPanel` with `allowsKey`, `onCancel`, `onResignKey`
  - `@MainActor final class MacFloatingPanelController { init<Content: View>(config:environment:content:); let panel: MacFloatingPanel; var isVisible: Bool; private(set) var targetFrame: CGRect; func show(); func hide(); func toggle(); func updateContentHeight(_ h: CGFloat) }`

`targetFrame` is the frame the controller last asked for. Tests assert it instead of `panel.frame` because AppKit may move a window that lies off the real displays.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacFloatingPanelTests: XCTestCase {
    private let primary = MacScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 806))
    private let second = MacScreenGeometry(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private var mouse = CGPoint(x: 100, y: 100)
    private var dismissCount = 0
    private var controllers: [MacFloatingPanelController] = []

    override func tearDown() async throws {
        for controller in controllers {
            controller.hide()
            controller.panel.close()
        }
        controllers = []
        dismissCount = 0
    }

    private func make(configure: (inout MacFloatingPanelConfig) -> Void = { _ in }) -> MacFloatingPanelController {
        var config = MacFloatingPanelConfig(
            size: NSSize(width: 600, height: 80),
            placement: .screenCenterTop(fromTop: 100),
            canBecomeKey: true,
            dismissOnResignKey: true,
            onDismiss: { [weak self] in self?.dismissCount += 1 })
        configure(&config)
        let screens = [primary, second]
        let environment = MacFloatingPanelEnvironment(
            screens: { screens },
            mouseLocation: { [unowned self] in self.mouse },
            reduceMotion: { true })
        let controller = MacFloatingPanelController(config: config, environment: environment) { Color.clear }
        controllers.append(controller)
        return controller
    }

    func testPanelStyleAndBehaviourContract() {
        let panel = make().panel
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testCanBecomeKeyFollowsConfig() {
        XCTAssertTrue(make().panel.canBecomeKey)
        XCTAssertFalse(make { $0.canBecomeKey = false }.panel.canBecomeKey)
    }

    func testLevelAndSpacesFollowConfig() {
        let panel = make { $0.level = .statusBar; $0.joinsAllSpaces = false }.panel
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testShowPlacesOnTheMouseScreen() {
        mouse = CGPoint(x: 2000, y: 500)
        let controller = make()
        controller.show()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.isVisible })
        XCTAssertEqual(controller.targetFrame, CGRect(x: 2100, y: 875, width: 600, height: 80))
    }

    func testShowRecomputesPlacementEveryTime() {
        let controller = make()
        controller.show()
        XCTAssertEqual(controller.targetFrame.midX, 720, accuracy: 0.001)
        controller.hide()
        mouse = CGPoint(x: 2000, y: 500)
        controller.show()
        XCTAssertEqual(controller.targetFrame.midX, 2400, accuracy: 0.001)
    }

    func testToggleShowsThenHides() {
        let controller = make()
        controller.toggle()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.isVisible })
        controller.toggle()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(dismissCount, 1)
    }

    func testEscapeHidesOnceEvenWhenAppKitThenResignsKey() {
        let controller = make()
        controller.show()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.isVisible })
        controller.panel.cancelOperation(nil)
        XCTAssertFalse(controller.isVisible)
        controller.panel.resignKey()   // AppKit sends this while ordering a key panel out
        XCTAssertEqual(dismissCount, 1)
    }

    func testEscapeDoesNothingWhenDisabled() {
        let controller = make { $0.dismissOnEscape = false }
        controller.show()
        controller.panel.cancelOperation(nil)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(dismissCount, 0)
    }

    func testResignKeyHidesOnlyWhenConfigured() {
        let hides = make()
        hides.show()
        hides.panel.resignKey()
        XCTAssertFalse(hides.isVisible)

        let stays = make { $0.dismissOnResignKey = false }
        stays.show()
        stays.panel.resignKey()
        XCTAssertTrue(stays.isVisible)
    }

    func testHideWhenNotVisibleDoesNotFireOnDismiss() {
        let controller = make()
        controller.hide()
        XCTAssertEqual(dismissCount, 0)
    }

    func testContentHeightGrowsDownwardWithAFixedTopAndCapsAtMaxHeight() {
        let controller = make { $0.maxHeight = 300 }
        controller.show()
        let top = controller.targetFrame.maxY
        controller.updateContentHeight(200)
        XCTAssertEqual(controller.targetFrame.height, 200)
        XCTAssertEqual(controller.targetFrame.maxY, top)
        controller.updateContentHeight(900)
        XCTAssertEqual(controller.targetFrame.height, 300)
        XCTAssertEqual(controller.targetFrame.maxY, top)
    }

    func testContentHeightBeforeShowIsRememberedForTheNextShow() {
        let controller = make()
        controller.updateContentHeight(240)
        controller.show()
        XCTAssertEqual(controller.targetFrame.height, 240)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacFloatingPanelTests`
Expected: build failure, `cannot find 'MacFloatingPanelConfig' in scope`.

- [ ] **Step 3: Implement**

```swift
import AppKit
import SwiftUI

struct MacFloatingPanelConfig {
    var size: NSSize                       // initial; height may follow content
    var maxHeight: CGFloat = 480
    var placement: MacFloatingPanelPlacement
    var canBecomeKey: Bool                 // Quick Ask true, notch status false
    var dismissOnResignKey: Bool           // Quick Ask true, notch status false
    var dismissOnEscape: Bool = true
    var level: NSWindow.Level = .floating
    var joinsAllSpaces: Bool = true        // plus fullScreenAuxiliary
    var onDismiss: (() -> Void)? = nil
}

/// What the controller needs from the machine. Injected so placement is testable.
struct MacFloatingPanelEnvironment {
    var screens: () -> [MacScreenGeometry]
    var mouseLocation: () -> CGPoint
    var reduceMotion: () -> Bool

    static let live = MacFloatingPanelEnvironment(
        screens: {
            NSScreen.screens.map {
                MacScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame, safeAreaTop: $0.safeAreaInsets.top)
            }
        },
        mouseLocation: { NSEvent.mouseLocation },
        reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
}

/// A borderless, non-activating panel: showing it never activates Conduit and
/// never takes the front app's menu bar.
final class MacFloatingPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class MacFloatingPanelController {
    let panel: MacFloatingPanel
    private let config: MacFloatingPanelConfig
    private let environment: MacFloatingPanelEnvironment
    private var contentSize: CGSize
    private var isHiding = false
    private var screenObserver: NSObjectProtocol?
    /// The frame last requested from the panel (before any AppKit adjustment).
    private(set) var targetFrame: CGRect = .zero

    init<Content: View>(
        config: MacFloatingPanelConfig,
        environment: MacFloatingPanelEnvironment = .live,
        @ViewBuilder content: () -> Content
    ) {
        self.config = config
        self.environment = environment
        self.contentSize = config.size
        let panel = MacFloatingPanel(
            contentRect: NSRect(origin: .zero, size: config.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = config.level
        panel.collectionBehavior = config.joinsAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
        panel.allowsKey = config.canBecomeKey
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = []   // the controller owns the panel's size
        panel.contentView = hosting
        self.panel = panel
        panel.onCancel = { [weak self] in
            guard let self, self.config.dismissOnEscape else { return }
            self.hide()
        }
        panel.onResignKey = { [weak self] in
            guard let self, self.config.dismissOnResignKey else { return }
            self.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Places the panel, orders it front without activating the app, and makes
    /// it key when the config allows it.
    func show() {
        let wasVisible = panel.isVisible
        place()
        let fade = !wasVisible && !environment.reduceMotion()
        if !wasVisible { panel.alphaValue = fade ? 0 : 1 }
        panel.orderFrontRegardless()
        if config.canBecomeKey { panel.makeKey() }
        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        installScreenObserver()
    }

    /// Orders the panel out and fires `onDismiss` once per visible-to-hidden
    /// transition. Re-entrant calls (AppKit's `resignKey` during `orderOut`) are ignored.
    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        removeScreenObserver()
        panel.orderOut(nil)
        config.onDismiss?()
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// The top edge stays fixed; the panel grows downward, clamped to `maxHeight`.
    func updateContentHeight(_ height: CGFloat) {
        resize(to: CGSize(width: contentSize.width, height: height))
    }

    // MARK: - Geometry

    func resize(to size: CGSize) {
        contentSize = CGSize(width: size.width, height: min(size.height, config.maxHeight))
        guard panel.isVisible, let screen = currentScreen() else { return }
        targetFrame = MacFloatingPanelPlacement.resized(
            targetFrame, to: contentSize, maxHeight: config.maxHeight, within: bounds(of: screen))
        panel.setFrame(targetFrame, display: true)
    }

    func bounds(of screen: MacScreenGeometry) -> CGRect {
        screen.visibleFrame
    }

    private func place() {
        let screens = environment.screens()
        guard let index = config.placement.targetScreenIndex(mouse: environment.mouseLocation(), screens: screens) else { return }
        let screen = screens[index]
        targetFrame = config.placement.frame(
            panelSize: contentSize, screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaTop)
        panel.setFrame(targetFrame, display: true)
    }

    private func currentScreen() -> MacScreenGeometry? {
        let screens = environment.screens()
        let probe = CGPoint(x: targetFrame.midX, y: targetFrame.maxY - 1)
        return screens.first { $0.frame.contains(probe) }
            ?? config.placement.targetScreenIndex(mouse: environment.mouseLocation(), screens: screens).map { screens[$0] }
    }

    // MARK: - Screen changes

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the same command as Step 2.
Expected: all MacFloatingPanelTests pass. If `panel.isVisible` is false right after `orderFrontRegardless` in the test host, widen the `waitUntil` use (the tests already poll once; add it where a test reads `isVisible` immediately).

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Panels/MacFloatingPanel.swift' 'ConduitMacTests/MacFloatingPanelTests.swift'
git commit -m "macOS: non-activating floating panel and controller (shared base)"
```

---

### Task 3: Panel hooks the notch surface needs

**Files:**
- Modify: `ConduitMac/Panels/MacFloatingPanel.swift`
- Modify: `ConduitMacTests/MacFloatingPanelTests.swift` (append tests)

**Interfaces:**
- Consumes: Task 2 types.
- Produces (all additive, defaults keep Quick Ask unchanged):
  - `MacFloatingPanelConfig.allowsMenuBarOverlap: Bool = false`, `.hasShadow: Bool = true`, `.onMouseEntered: (() -> Void)? = nil`, `.onMouseExited: (() -> Void)? = nil`
  - `MacFloatingPanel.allowsMenuBarOverlap` (overrides `constrainFrameRect(_:to:)`), `onMouseEntered`, `onMouseExited`
  - `MacFloatingPanelController.updateContentSize(_ size: CGSize)` (width and height, top edge and center fixed)

- [ ] **Step 1: Append the failing tests**

Add inside `MacFloatingPanelTests`:

```swift
    func testMenuBarOverlapReturnsTheFrameUnchanged() {
        let panel = make { $0.allowsMenuBarOverlap = true }.panel
        let screen = NSScreen.screens[0]
        let overlapping = NSRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 40, width: 200, height: 40)
        XCTAssertEqual(panel.constrainFrameRect(overlapping, to: screen), overlapping)
    }

    func testShadowFollowsConfig() {
        XCTAssertTrue(make().panel.hasShadow)
        XCTAssertFalse(make { $0.hasShadow = false }.panel.hasShadow)
    }

    func testContentSizeChangesWidthAndHeightKeepingTopAndCenter() {
        let controller = make()
        controller.show()
        let top = controller.targetFrame.maxY
        let midX = controller.targetFrame.midX
        controller.updateContentSize(CGSize(width: 300, height: 200))
        XCTAssertEqual(controller.targetFrame.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(controller.targetFrame.maxY, top)
        XCTAssertEqual(controller.targetFrame.midX, midX, accuracy: 0.001)
    }

    func testOverlapAllowedPanelMayGrowIntoTheMenuBarBand() {
        // notchAnchored sits flush with screen.frame.maxY, above visibleFrame.maxY.
        let controller = make { $0.placement = .notchAnchored; $0.allowsMenuBarOverlap = true }
        controller.show()
        XCTAssertEqual(controller.targetFrame.maxY, 900)   // primary.frame.maxY, not 876
        controller.updateContentSize(CGSize(width: 600, height: 120))
        XCTAssertEqual(controller.targetFrame.maxY, 900)
    }

    func testMouseCallbacksFire() {
        var entered = 0, exited = 0
        let controller = make { $0.onMouseEntered = { entered += 1 }; $0.onMouseExited = { exited += 1 } }
        controller.show()
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: controller.panel.windowNumber, context: nil,
                                   eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        controller.panel.mouseEntered(with: event(.mouseEntered))
        controller.panel.mouseExited(with: event(.mouseExited))
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(exited, 1)
    }

    func testPlacementFollowsScreenParameterChanges() {
        var screens = [primary]
        let environment = MacFloatingPanelEnvironment(screens: { screens }, mouseLocation: { CGPoint(x: 100, y: 100) }, reduceMotion: { true })
        let controller = MacFloatingPanelController(
            config: MacFloatingPanelConfig(size: NSSize(width: 600, height: 80), placement: .screenCenterTop(fromTop: 100),
                                           canBecomeKey: false, dismissOnResignKey: false),
            environment: environment) { Color.clear }
        controllers.append(controller)
        controller.show()
        XCTAssertEqual(controller.targetFrame.midX, 720, accuracy: 0.001)
        screens = [MacScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(HostedTestSupport.waitUntil { abs(controller.targetFrame.midX - 500) < 0.001 })
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacFloatingPanelTests`
Expected: build failure, `allowsMenuBarOverlap` is not a member of `MacFloatingPanelConfig`.

- [ ] **Step 3: Implement**

In `MacFloatingPanelConfig`, after `onDismiss`:

```swift
    /// The notch surface sits in the menu bar band; AppKit would push it below.
    var allowsMenuBarOverlap: Bool = false
    var hasShadow: Bool = true
    var onMouseEntered: (() -> Void)? = nil
    var onMouseExited: (() -> Void)? = nil
```

In `MacFloatingPanel`, add:

```swift
    var allowsMenuBarOverlap = false
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsMenuBarOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
```

In the controller `init`, replace `panel.hasShadow = true` with `panel.hasShadow = config.hasShadow`, and after `panel.contentView = hosting` add:

```swift
        panel.allowsMenuBarOverlap = config.allowsMenuBarOverlap
        panel.onMouseEntered = config.onMouseEntered
        panel.onMouseExited = config.onMouseExited
        if config.onMouseEntered != nil || config.onMouseExited != nil {
            hosting.addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: panel, userInfo: nil))
        }
```

Replace `bounds(of:)` with:

```swift
    func bounds(of screen: MacScreenGeometry) -> CGRect {
        config.allowsMenuBarOverlap ? screen.frame : screen.visibleFrame
    }
```

Add the public size API next to `updateContentHeight`:

```swift
    /// Width and height follow the content (compact capsule vs expanded list);
    /// the top edge and the horizontal center stay put.
    func updateContentSize(_ size: CGSize) {
        resize(to: size)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: the same command as Step 2.
Expected: all MacFloatingPanelTests pass (Task 2 tests unchanged).

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Panels/MacFloatingPanel.swift' 'ConduitMacTests/MacFloatingPanelTests.swift'
git commit -m "macOS: floating panel menu-bar overlap, content size and hover hooks (shared base)"
```

---


---

### Task 3A: Edge docking geometry and the `.edgeDocked` placement (pure)

Scope change from the user: the notch status surface must be draggable and sit at any point along any screen edge. This task is the pure half; Task 3B adds the drag. The notch-anchored position stays the default; the notch feature plan owns persistence and the per-edge layout of its content.

**Files:**
- Create: `ConduitMac/Panels/EdgeDockGeometry.swift`
- Modify: `ConduitMac/Panels/MacFloatingPanelPlacement.swift`
- Test: `ConduitMacTests/EdgeDockGeometryTests.swift`; append to `ConduitMacTests/MacFloatingPanelPlacementTests.swift`

**Interfaces:**
- Consumes: `MacScreenGeometry`, `MacFloatingPanelPlacement` (Task 1).
- Produces:
  - `MacScreenGeometry.id: UInt32? = nil` (the `CGDirectDisplayID` from `NSScreen.deviceDescription["NSScreenNumber"]`; stable across relaunches, so it is the persistable screen key)
  - `struct MacEdgeDock: Equatable { var edge: NSRectEdge; var offset: CGFloat; var screenID: UInt32? }`. `NSRectEdge` in AppKit coordinates: `.maxY` top, `.minY` bottom, `.minX` left, `.maxX` right. `offset` is 0...1 along the edge: left to right on top and bottom, top to bottom on left and right. Persist `edge.rawValue` (a `UInt`), `offset` and `screenID`.
  - `enum EdgeDockGeometry`: `clampedOffset(_:) -> CGFloat`, `frame(for:panelSize:screenFrame:) -> CGRect`, `nearestEdge(to:in:) -> NSRectEdge`, `offset(of:on:in:) -> CGFloat`, `screenIndex(containing:in:) -> Int?`, `screenIndex(for:screens:) -> Int?`, `snap(pointer:panelFrame:screens:) -> MacEdgeDock?`
  - `MacFloatingPanelPlacement.edgeDocked(edge: NSRectEdge, offset: CGFloat, screenID: UInt32?)` and `func resolve(panelSize:mouse:screens:) -> (screenIndex: Int, frame: CGRect)?`

Rules (pinned by the tests): the panel is flush with the chosen edge of the screen's full `frame` (not `visibleFrame`; docking over the Dock or menu bar band is the point, as with the notch) and always fully on screen; the offset is a fraction, so a resolution or screen change re-fits it by recomputing the frame; with a saved `screenID` that no longer exists the placement falls back to the default (`.notchAnchored`); with `screenID == nil` the docked screen is the one under the mouse.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/EdgeDockGeometryTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class EdgeDockGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 400, height: 60)

    private func frame(_ edge: NSRectEdge, _ offset: CGFloat, size: CGSize? = nil, on rect: CGRect? = nil) -> CGRect {
        EdgeDockGeometry.frame(for: MacEdgeDock(edge: edge, offset: offset, screenID: nil),
                               panelSize: size ?? self.size, screenFrame: rect ?? screen)
    }

    func testEachEdgeIsFlushAndCenteredAtHalfOffset() {
        XCTAssertEqual(frame(.maxY, 0.5), CGRect(x: 520, y: 840, width: 400, height: 60))
        XCTAssertEqual(frame(.minY, 0.5), CGRect(x: 520, y: 0, width: 400, height: 60))
        XCTAssertEqual(frame(.minX, 0.5), CGRect(x: 0, y: 420, width: 400, height: 60))
        XCTAssertEqual(frame(.maxX, 0.5), CGRect(x: 1040, y: 420, width: 400, height: 60))
    }

    func testOffsetRunsLeftToRightOnTopAndBottomAndTopToBottomOnTheSides() {
        XCTAssertEqual(frame(.maxY, 0).minX, 0)
        XCTAssertEqual(frame(.maxY, 1).maxX, 1440)
        XCTAssertEqual(frame(.minX, 0).maxY, 900)
        XCTAssertEqual(frame(.minX, 1).minY, 0)
    }

    func testOffsetIsClamped() {
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(-3), 0)
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(7), 1)
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(.nan), 0.5)
        XCTAssertEqual(EdgeDockGeometry.clampedOffset(0.25), 0.25)
    }

    func testThePanelNeverLeavesTheScreen() {
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            for offset in [-1, 0, 0.3, 1, 2] as [CGFloat] {
                XCTAssertTrue(screen.contains(frame(edge, offset)), "\(edge) \(offset)")
            }
        }
    }

    func testAPanelLargerThanTheScreenShrinksToIt() {
        let f = frame(.maxY, 0.5, size: CGSize(width: 3000, height: 60))
        XCTAssertEqual(f.width, 1440)
        XCTAssertEqual(f.minX, 0)
    }

    func testScreensAwayFromTheOriginWork() {
        let other = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(frame(.maxY, 0.5, on: other), CGRect(x: 2200, y: 820, width: 400, height: 60))
    }

    func testAChangeOfResolutionRefitsTheSameDock() {
        XCTAssertEqual(frame(.maxY, 1).minX, 1040)
        let smaller = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let refit = frame(.maxY, 1, on: smaller)
        XCTAssertEqual(refit.minX, 600)
        XCTAssertTrue(smaller.contains(refit))
    }

    // MARK: - Snap

    func testNearestEdgeOfThePointer() {
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 720, y: 880), in: screen), .maxY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 720, y: 10), in: screen), .minY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 5, y: 450), in: screen), .minX)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 1435, y: 450), in: screen), .maxX)
    }

    func testTiesPreferTopThenBottomThenLeft() {
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 0, y: 900), in: screen), .maxY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 0, y: 0), in: screen), .minY)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 720, y: 450), in: screen), .maxY)
    }

    func testOffsetOfAPanelFrameAlongAnEdgeIsClamped() {
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 520, y: 0, width: 400, height: 60), on: .maxY, in: screen), 0.5)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: -100, y: 0, width: 400, height: 60), on: .maxY, in: screen), 0)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 5000, y: 0, width: 400, height: 60), on: .minY, in: screen), 1)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 0, y: 840, width: 400, height: 60), on: .minX, in: screen), 0)
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 0, y: 0, width: 400, height: 60), on: .maxX, in: screen), 1)
    }

    func testAPanelAsLongAsTheEdgeSitsInTheMiddle() {
        XCTAssertEqual(EdgeDockGeometry.offset(of: CGRect(x: 0, y: 0, width: 1440, height: 60), on: .maxY, in: screen), 0.5)
    }

    func testScreenUnderThePointerIsInclusiveThenNearest() {
        let a = MacScreenGeometry(frame: screen, visibleFrame: screen, id: 1)
        let b = MacScreenGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: screen, id: 2)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(containing: CGPoint(x: 100, y: 100), in: [a, b]), 0)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(containing: CGPoint(x: 2000, y: 1080), in: [a, b]), 1)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(containing: CGPoint(x: 1500, y: -40), in: [a, b]), 1, "outside every screen: nearest")
        XCTAssertNil(EdgeDockGeometry.screenIndex(containing: .zero, in: []))
    }

    func testSnapPicksTheScreenTheEdgeTheOffsetAndTheScreenId() throws {
        let a = MacScreenGeometry(frame: screen, visibleFrame: screen, id: 11)
        let b = MacScreenGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: screen, id: 22)
        let dock = try XCTUnwrap(EdgeDockGeometry.snap(
            pointer: CGPoint(x: 2400, y: 1070),
            panelFrame: CGRect(x: 2200, y: 900, width: 400, height: 60),
            screens: [a, b]))
        XCTAssertEqual(dock.edge, .maxY)
        XCTAssertEqual(dock.screenID, 22)
        XCTAssertEqual(dock.offset, (2200 - 1440) / (1920 - 400), accuracy: 0.0001)
        XCTAssertNil(EdgeDockGeometry.snap(pointer: .zero, panelFrame: .zero, screens: []))
    }

    func testScreenLookupByIdReturnsNilWhenGone() {
        let a = MacScreenGeometry(frame: screen, visibleFrame: screen, id: 11)
        XCTAssertEqual(EdgeDockGeometry.screenIndex(for: MacEdgeDock(edge: .maxY, offset: 0, screenID: 11), screens: [a]), 0)
        XCTAssertNil(EdgeDockGeometry.screenIndex(for: MacEdgeDock(edge: .maxY, offset: 0, screenID: 99), screens: [a]))
        XCTAssertNil(EdgeDockGeometry.screenIndex(for: MacEdgeDock(edge: .maxY, offset: 0, screenID: nil), screens: [a]))
    }
}
```

Append to `MacFloatingPanelPlacementTests`:

```swift
    // MARK: - Edge docked

    private func dockedPrimary() -> MacScreenGeometry { MacScreenGeometry(frame: primary.frame, visibleFrame: primary.visibleFrame, id: 1) }
    private func dockedRight() -> MacScreenGeometry { MacScreenGeometry(frame: right.frame, visibleFrame: right.visibleFrame, id: 2) }

    func testEdgeDockedFrameUsesTheFullScreenFrame() {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .minY, offset: 0.5, screenID: 1)
        XCTAssertEqual(frame(p, on: primary, size: CGSize(width: 400, height: 60)), CGRect(x: 520, y: 0, width: 400, height: 60))
    }

    func testEdgeDockedTargetsTheSavedScreen() {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .maxY, offset: 0.5, screenID: 2)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 100, y: 100), screens: [dockedPrimary(), dockedRight()]), 1)
    }

    func testEdgeDockedWithoutAScreenIdUsesTheMouseScreen() {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .maxY, offset: 0.5, screenID: nil)
        XCTAssertEqual(p.targetScreenIndex(mouse: CGPoint(x: 2000, y: 500), screens: [dockedPrimary(), dockedRight()]), 1)
    }

    func testEdgeDockedFallsBackToTheDefaultWhenTheSavedScreenIsGone() throws {
        let p = MacFloatingPanelPlacement.edgeDocked(edge: .minX, offset: 1, screenID: 99)
        let screens = [dockedPrimary(), dockedRight()]
        let resolved = try XCTUnwrap(p.resolve(panelSize: CGSize(width: 400, height: 60), mouse: CGPoint(x: 100, y: 100), screens: screens))
        let expected = MacFloatingPanelPlacement.notchAnchored.frame(
            panelSize: CGSize(width: 400, height: 60), screenFrame: primary.frame,
            visibleFrame: primary.visibleFrame, safeAreaTop: 0)
        XCTAssertEqual(resolved.screenIndex, 0)
        XCTAssertEqual(resolved.frame, expected, "notch-anchored default, not a left-edge dock")
    }

    func testResolveForTheExistingPlacementsMatchesFrame() throws {
        let p = MacFloatingPanelPlacement.screenCenterTop(fromTop: 100)
        let resolved = try XCTUnwrap(p.resolve(panelSize: size, mouse: CGPoint(x: 2000, y: 500), screens: [primary, right]))
        XCTAssertEqual(resolved.screenIndex, 1)
        XCTAssertEqual(resolved.frame, frame(p, on: right))
        XCTAssertNil(p.resolve(panelSize: size, mouse: .zero, screens: []))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/EdgeDockGeometryTests -only-testing:ConduitMacTests/MacFloatingPanelPlacementTests`
Expected: build failure, `cannot find 'MacEdgeDock' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Panels/EdgeDockGeometry.swift`:

```swift
import Foundation

/// Where a panel is docked: one edge of one screen, a fraction along it.
struct MacEdgeDock: Equatable {
    /// AppKit coordinates: `.maxY` top, `.minY` bottom, `.minX` left, `.maxX` right.
    var edge: NSRectEdge
    /// 0...1 along the edge: left to right on top and bottom, top to bottom on left and right.
    var offset: CGFloat
    /// `CGDirectDisplayID` of the screen, or nil for "the screen under the mouse".
    var screenID: UInt32?
}

/// Pure edge-dock math. No windows, no screens: rectangles in, rectangles out.
enum EdgeDockGeometry {
    static func clampedOffset(_ offset: CGFloat) -> CGFloat {
        guard !offset.isNaN else { return 0.5 }
        return min(max(offset, 0), 1)
    }

    /// Flush with `dock.edge` of `screenFrame`, `offset` of the way along it,
    /// and always fully on screen (a panel longer than the screen shrinks to it).
    static func frame(for dock: MacEdgeDock, panelSize: CGSize, screenFrame f: CGRect) -> CGRect {
        let width = min(panelSize.width, f.width)
        let height = min(panelSize.height, f.height)
        let t = clampedOffset(dock.offset)
        let x = f.minX + (f.width - width) * t
        let y = f.maxY - height - (f.height - height) * t
        switch dock.edge {
        case .maxY: return CGRect(x: x, y: f.maxY - height, width: width, height: height)
        case .minY: return CGRect(x: x, y: f.minY, width: width, height: height)
        case .minX: return CGRect(x: f.minX, y: y, width: width, height: height)
        case .maxX: return CGRect(x: f.maxX - width, y: y, width: width, height: height)
        @unknown default: return CGRect(x: x, y: f.maxY - height, width: width, height: height)
        }
    }

    /// The screen edge closest to `pointer`. Ties prefer top, then bottom, then left, then right.
    static func nearestEdge(to pointer: CGPoint, in f: CGRect) -> NSRectEdge {
        let candidates: [(NSRectEdge, CGFloat)] = [
            (.maxY, f.maxY - pointer.y), (.minY, pointer.y - f.minY),
            (.minX, pointer.x - f.minX), (.maxX, f.maxX - pointer.x),
        ]
        var best = candidates[0]
        for candidate in candidates.dropFirst() where candidate.1 < best.1 { best = candidate }
        return best.0
    }

    /// Where `panelFrame` sits along `edge`, as a clamped fraction. A panel as
    /// long as the edge has no room to move and reads as centered.
    static func offset(of panelFrame: CGRect, on edge: NSRectEdge, in f: CGRect) -> CGFloat {
        switch edge {
        case .maxY, .minY:
            let room = f.width - panelFrame.width
            return room > 0 ? clampedOffset((panelFrame.minX - f.minX) / room) : 0.5
        default:
            let room = f.height - panelFrame.height
            return room > 0 ? clampedOffset((f.maxY - panelFrame.maxY) / room) : 0.5
        }
    }

    /// The screen containing `point` (edges inclusive), else the nearest one.
    static func screenIndex(containing point: CGPoint, in screens: [MacScreenGeometry]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let hit = screens.firstIndex(where: { contains($0.frame, point) }) { return hit }
        return screens.indices.min { distance(from: point, to: screens[$0].frame) < distance(from: point, to: screens[$1].frame) }
    }

    /// The screen a dock names, or nil (no id, or that screen is gone).
    static func screenIndex(for dock: MacEdgeDock, screens: [MacScreenGeometry]) -> Int? {
        guard let id = dock.screenID else { return nil }
        return screens.firstIndex { $0.id == id }
    }

    /// Mouse-up after a drag: the dock for the screen under the pointer, its
    /// nearest edge, and the panel's offset along that edge.
    static func snap(pointer: CGPoint, panelFrame: CGRect, screens: [MacScreenGeometry]) -> MacEdgeDock? {
        guard let index = screenIndex(containing: pointer, in: screens) else { return nil }
        let screen = screens[index]
        let edge = nearestEdge(to: pointer, in: screen.frame)
        return MacEdgeDock(edge: edge, offset: offset(of: panelFrame, on: edge, in: screen.frame), screenID: screen.id)
    }

    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    private static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
```

In `MacFloatingPanelPlacement.swift`:

(a) Add the id to `MacScreenGeometry`, after `safeAreaTop`:

```swift
    /// `CGDirectDisplayID` of the display (`NSScreen.deviceDescription["NSScreenNumber"]`); nil in tests.
    var id: UInt32? = nil
```

(b) Add the case after `.notchAnchored`:

```swift
    /// Docked to one edge of one screen, `offset` (0...1) of the way along it.
    /// A saved `screenID` that is gone falls back to the default, `.notchAnchored`;
    /// a nil `screenID` means the screen under the mouse.
    case edgeDocked(edge: NSRectEdge, offset: CGFloat, screenID: UInt32?)
```

(c) In `frame(panelSize:screenFrame:visibleFrame:safeAreaTop:)`, add before `case .custom`:

```swift
        case .edgeDocked(let edge, let offset, let screenID):
            return EdgeDockGeometry.frame(
                for: MacEdgeDock(edge: edge, offset: offset, screenID: screenID),
                panelSize: panelSize, screenFrame: screenFrame)
```

(d) Replace `targetScreenIndex` with:

```swift
    func targetScreenIndex(mouse: CGPoint, screens: [MacScreenGeometry]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let mouseIndex = screens.firstIndex { Self.inclusiveContains($0.frame, mouse) } ?? 0
        func notchOrMouse() -> Int {
            if screens[mouseIndex].hasNotch { return mouseIndex }
            return screens.firstIndex { $0.hasNotch } ?? mouseIndex
        }
        switch self {
        case .notchAnchored:
            return notchOrMouse()
        case .edgeDocked(_, _, let screenID):
            guard let screenID else { return mouseIndex }
            return screens.firstIndex { $0.id == screenID } ?? notchOrMouse()
        default:
            return mouseIndex
        }
    }

    /// The screen and frame for a panel of `panelSize`. A docked placement whose
    /// saved screen is gone resolves as the default (`.notchAnchored`).
    func resolve(panelSize: CGSize, mouse: CGPoint, screens: [MacScreenGeometry]) -> (screenIndex: Int, frame: CGRect)? {
        var placement = self
        if case .edgeDocked(_, _, let id?) = self, !screens.contains(where: { $0.id == id }) {
            placement = .notchAnchored
        }
        guard let index = placement.targetScreenIndex(mouse: mouse, screens: screens) else { return nil }
        let screen = screens[index]
        return (index, placement.frame(panelSize: panelSize, screenFrame: screen.frame,
                                       visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaTop))
    }
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2.
Expected: EdgeDockGeometryTests and all MacFloatingPanelPlacementTests (Task 1 tests unchanged) pass. Also run `-only-testing:ConduitMacTests/MacFloatingPanelTests` to confirm Task 2 still builds (the controller still calls `targetScreenIndex` and `frame`).

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Panels/EdgeDockGeometry.swift' 'ConduitMac/Panels/MacFloatingPanelPlacement.swift' 'ConduitMacTests/EdgeDockGeometryTests.swift' 'ConduitMacTests/MacFloatingPanelPlacementTests.swift'
git commit -m "macOS: edge-docked placement and pure dock geometry (shared base)"
```

---

### Task 3B: Draggable panel (threshold, snap on release, placement callback)

**Files:**
- Create: `ConduitMac/Panels/MacPanelDragTracker.swift`
- Modify: `ConduitMac/Panels/MacFloatingPanel.swift`
- Test: `ConduitMacTests/MacPanelDragTrackerTests.swift`; append to `ConduitMacTests/MacFloatingPanelTests.swift`

**Interfaces:**
- Consumes: `EdgeDockGeometry`, `MacEdgeDock`, `MacFloatingPanelPlacement.resolve` (Task 3A); controller and panel (Tasks 2, 3).
- Produces:
  - `MacFloatingPanelConfig.isDraggable: Bool = false`, `.dragThreshold: CGFloat = 4`, `.onPlacementChanged: ((MacFloatingPanelPlacement) -> Void)? = nil`
  - `MacFloatingPanelController.currentPlacement: MacFloatingPanelPlacement` and `setPlacement(_:)` (the owner applies a saved placement before `show()`; it re-places at once when visible)
  - `struct MacPanelDragTracker` (pure): `init(threshold:)`, `begin(pointer:frame:)`, `move(to:) -> CGRect?`, `end() -> Bool`, `isDragging`
  - `MacFloatingPanel.isDraggable`, `dragThreshold`, `onDragMoved`, `onDragEnded`

Behaviour: a mouse-down starts a potential drag and is still delivered to the content. Movement under the threshold (4 pt) is a click: nothing moves, events are delivered, no callback. Once the pointer has moved 4 pt the panel follows the pointer freely (no clamping) and drag events stop reaching the content. On mouse-up after a drag the mouse-up is swallowed (no click), the panel snaps to the nearest edge of the screen under the pointer (`EdgeDockGeometry.snap`), the controller adopts `.edgeDocked(edge:offset:screenID:)` as its placement, re-places, and calls `onPlacementChanged` once with it. A non-draggable panel never intercepts events. The notch plan decides whether its content uses a drag handle or the whole surface, and persists the callback's placement.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacPanelDragTrackerTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class MacPanelDragTrackerTests: XCTestCase {
    private let start = CGRect(x: 100, y: 200, width: 300, height: 60)

    func testNothingMovesBeforeAPointerHasBeenPressed() {
        var tracker = MacPanelDragTracker(threshold: 4)
        XCTAssertNil(tracker.move(to: CGPoint(x: 50, y: 50)))
        XCTAssertFalse(tracker.end())
    }

    func testMovementUnderTheThresholdIsNotADrag() {
        var tracker = MacPanelDragTracker(threshold: 4)
        tracker.begin(pointer: CGPoint(x: 10, y: 10), frame: start)
        XCTAssertNil(tracker.move(to: CGPoint(x: 13, y: 10)))
        XCTAssertNil(tracker.move(to: CGPoint(x: 12.5, y: 12.5)))
        XCTAssertFalse(tracker.isDragging)
        XCTAssertFalse(tracker.end(), "a click, not a drag")
    }

    func testMovementAtTheThresholdStartsTheDragAndTheFrameFollowsThePointer() {
        var tracker = MacPanelDragTracker(threshold: 4)
        tracker.begin(pointer: CGPoint(x: 10, y: 10), frame: start)
        XCTAssertEqual(tracker.move(to: CGPoint(x: 14, y: 10)), start.offsetBy(dx: 4, dy: 0))
        XCTAssertTrue(tracker.isDragging)
        XCTAssertEqual(tracker.move(to: CGPoint(x: 11, y: 8)), start.offsetBy(dx: 1, dy: -2), "once started, no threshold")
        XCTAssertTrue(tracker.end())
    }

    func testEndResetsSoTheNextPressStartsFresh() {
        var tracker = MacPanelDragTracker(threshold: 4)
        tracker.begin(pointer: .zero, frame: start)
        _ = tracker.move(to: CGPoint(x: 20, y: 0))
        XCTAssertTrue(tracker.end())
        XCTAssertFalse(tracker.isDragging)
        XCTAssertNil(tracker.move(to: CGPoint(x: 50, y: 0)))
        XCTAssertFalse(tracker.end())
    }
}
```

Append to `MacFloatingPanelTests`:

```swift
    // MARK: - Dragging

    private var placements: [MacFloatingPanelPlacement] = []

    private func makeDraggable(placement: MacFloatingPanelPlacement = .screenCenterTop(fromTop: 100)) -> MacFloatingPanelController {
        let screens = [
            MacScreenGeometry(frame: primary.frame, visibleFrame: primary.visibleFrame, id: 1),
            MacScreenGeometry(frame: second.frame, visibleFrame: second.visibleFrame, id: 2),
        ]
        var config = MacFloatingPanelConfig(
            size: NSSize(width: 600, height: 80), placement: placement,
            canBecomeKey: false, dismissOnResignKey: false)
        config.isDraggable = true
        config.allowsMenuBarOverlap = true   // no AppKit frame adjustment in the test
        config.onPlacementChanged = { [weak self] in self?.placements.append($0) }
        let environment = MacFloatingPanelEnvironment(
            screens: { screens }, mouseLocation: { [unowned self] in self.mouse }, reduceMotion: { true })
        let controller = MacFloatingPanelController(config: config, environment: environment) { Color.clear }
        controllers.append(controller)
        return controller
    }

    /// A synthetic mouse event at a point in SCREEN coordinates.
    private func send(_ type: NSEvent.EventType, at point: CGPoint, to panel: MacFloatingPanel) {
        let location = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.sendEvent(event)
    }

    func testMovementUnderFourPointsIsAClickAndMovesNothing() {
        let controller = makeDraggable()
        controller.show()
        let before = controller.panel.frame
        send(.leftMouseDown, at: CGPoint(x: 720, y: 736), to: controller.panel)
        send(.leftMouseDragged, at: CGPoint(x: 723, y: 736), to: controller.panel)
        send(.leftMouseUp, at: CGPoint(x: 723, y: 736), to: controller.panel)
        XCTAssertEqual(controller.panel.frame, before)
        XCTAssertTrue(placements.isEmpty)
    }

    func testFourPointsStartsTheDrag() {
        let controller = makeDraggable()
        controller.show()
        let before = controller.panel.frame
        send(.leftMouseDown, at: CGPoint(x: 720, y: 736), to: controller.panel)
        send(.leftMouseDragged, at: CGPoint(x: 724, y: 736), to: controller.panel)
        XCTAssertEqual(controller.panel.frame, before.offsetBy(dx: 4, dy: 0))
    }

    func testReleaseSnapsToTheNearestEdgeAndReportsThePlacement() throws {
        let controller = makeDraggable()
        controller.show()
        send(.leftMouseDown, at: CGPoint(x: 720, y: 736), to: controller.panel)
        send(.leftMouseDragged, at: CGPoint(x: 720, y: 300), to: controller.panel)
        send(.leftMouseDragged, at: CGPoint(x: 720, y: 20), to: controller.panel)
        send(.leftMouseUp, at: CGPoint(x: 720, y: 20), to: controller.panel)
        XCTAssertEqual(placements.count, 1)
        guard case .edgeDocked(let edge, let offset, let screenID) = try XCTUnwrap(placements.first) else {
            return XCTFail("expected an edge-docked placement")
        }
        XCTAssertEqual(edge, .minY)
        XCTAssertEqual(offset, 0.5, accuracy: 0.0001)
        XCTAssertEqual(screenID, 1)
        XCTAssertEqual(controller.targetFrame, CGRect(x: 420, y: 0, width: 600, height: 80))
        XCTAssertEqual(controller.panel.frame, controller.targetFrame)
    }

    func testReleaseNearTheRightEdgeDocksThereAlongTheDraggedHeight() throws {
        let controller = makeDraggable()
        controller.show()
        send(.leftMouseDown, at: CGPoint(x: 720, y: 736), to: controller.panel)
        send(.leftMouseDragged, at: CGPoint(x: 1435, y: 450), to: controller.panel)
        send(.leftMouseUp, at: CGPoint(x: 1435, y: 450), to: controller.panel)
        guard case .edgeDocked(let edge, let offset, _) = try XCTUnwrap(placements.first) else { return XCTFail() }
        XCTAssertEqual(edge, .maxX)
        XCTAssertEqual(offset, 0.5, accuracy: 0.0001)
        XCTAssertEqual(controller.targetFrame, CGRect(x: 840, y: 410, width: 600, height: 80))
    }

    func testReleaseOnTheSecondScreenDocksThereWithItsId() throws {
        let controller = makeDraggable()
        controller.show()
        send(.leftMouseDown, at: CGPoint(x: 720, y: 736), to: controller.panel)
        send(.leftMouseDragged, at: CGPoint(x: 2400, y: 1070), to: controller.panel)
        send(.leftMouseUp, at: CGPoint(x: 2400, y: 1070), to: controller.panel)
        guard case .edgeDocked(let edge, _, let screenID) = try XCTUnwrap(placements.first) else { return XCTFail() }
        XCTAssertEqual(edge, .maxY)
        XCTAssertEqual(screenID, 2)
        XCTAssertEqual(controller.targetFrame.maxY, 1080)
    }

    func testANonDraggablePanelIgnoresDrags() {
        let controller = make { $0.allowsMenuBarOverlap = true }
        controller.show()
        let before = controller.panel.frame
        send(.leftMouseDown, at: CGPoint(x: 720, y: 736), to: controller.panel)
        send(.leftMouseDragged, at: CGPoint(x: 900, y: 500), to: controller.panel)
        send(.leftMouseUp, at: CGPoint(x: 900, y: 500), to: controller.panel)
        XCTAssertEqual(controller.panel.frame, before)
    }

    func testSetPlacementAppliesASavedDockOnTheNextShow() {
        let controller = makeDraggable()
        controller.setPlacement(.edgeDocked(edge: .minX, offset: 0, screenID: 2))
        controller.show()
        XCTAssertEqual(controller.targetFrame, CGRect(x: 1440, y: 1000, width: 600, height: 80))
        if case .edgeDocked = controller.currentPlacement {} else { XCTFail("placement not kept") }
    }

    func testASavedDockOnAMissingScreenFallsBackToNotchAnchoredDefault() {
        let controller = makeDraggable()
        controller.setPlacement(.edgeDocked(edge: .minX, offset: 0, screenID: 99))
        controller.show()
        XCTAssertEqual(controller.targetFrame.maxY, 900, "flush with the top of the mouse screen")
        XCTAssertEqual(controller.targetFrame.midX, 720, accuracy: 0.001)
    }

    func testResizingADockedPanelKeepsItOnItsEdge() {
        let controller = makeDraggable(placement: .edgeDocked(edge: .minY, offset: 0.5, screenID: 1))
        controller.show()
        controller.updateContentSize(CGSize(width: 300, height: 200))
        XCTAssertEqual(controller.targetFrame, CGRect(x: 570, y: 0, width: 300, height: 200))
    }
```

Add `placements = []` to the class `tearDown`.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPanelDragTrackerTests -only-testing:ConduitMacTests/MacFloatingPanelTests`
Expected: build failure, `cannot find 'MacPanelDragTracker' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Panels/MacPanelDragTracker.swift`:

```swift
import CoreGraphics

/// Tells a click from a drag. Pointer positions are in screen coordinates.
struct MacPanelDragTracker {
    var threshold: CGFloat = 4
    private var startPointer: CGPoint?
    private var startFrame: CGRect = .zero
    private(set) var isDragging = false

    init(threshold: CGFloat = 4) {
        self.threshold = threshold
    }

    mutating func begin(pointer: CGPoint, frame: CGRect) {
        startPointer = pointer
        startFrame = frame
        isDragging = false
    }

    /// nil while the pointer is still within `threshold` of the press (a click);
    /// from the first move past it, the frame the panel should have.
    mutating func move(to pointer: CGPoint) -> CGRect? {
        guard let startPointer else { return nil }
        let dx = pointer.x - startPointer.x
        let dy = pointer.y - startPointer.y
        if !isDragging {
            guard (dx * dx + dy * dy).squareRoot() >= threshold else { return nil }
            isDragging = true
        }
        return startFrame.offsetBy(dx: dx, dy: dy)
    }

    /// Whether a drag happened (so the mouse-up must not count as a click). Resets.
    mutating func end() -> Bool {
        defer { startPointer = nil; isDragging = false }
        return isDragging
    }
}
```

In `MacFloatingPanel.swift`:

(a) `MacFloatingPanelConfig`, after `onMouseExited`:

```swift
    /// Opt-in: the panel can be dragged, and snaps to the nearest screen edge on release.
    var isDraggable: Bool = false
    /// Movement before a press becomes a drag; below it the press is a click.
    var dragThreshold: CGFloat = 4
    /// Called once after a drag with the resulting `.edgeDocked` placement, so the owner can persist it.
    var onPlacementChanged: ((MacFloatingPanelPlacement) -> Void)? = nil
```

(b) `MacFloatingPanelEnvironment.live`: give each screen its id.

```swift
        screens: {
            NSScreen.screens.map {
                MacScreenGeometry(
                    frame: $0.frame, visibleFrame: $0.visibleFrame, safeAreaTop: $0.safeAreaInsets.top,
                    id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
            }
        },
```

(c) `MacFloatingPanel`, add:

```swift
    var isDraggable = false
    var dragThreshold: CGFloat = 4
    var onDragMoved: ((CGRect) -> Void)?
    /// Pointer (screen coordinates) and the panel's frame at mouse-up after a drag.
    var onDragEnded: ((CGPoint, CGRect) -> Void)?
    private var drag = MacPanelDragTracker()

    private func screenPoint(of event: NSEvent) -> CGPoint {
        convertPoint(toScreen: event.locationInWindow)
    }

    override func sendEvent(_ event: NSEvent) {
        guard isDraggable else { super.sendEvent(event); return }
        switch event.type {
        case .leftMouseDown:
            drag.threshold = dragThreshold
            drag.begin(pointer: screenPoint(of: event), frame: frame)
            super.sendEvent(event)               // a click must still reach the content
        case .leftMouseDragged:
            if let moved = drag.move(to: screenPoint(of: event)) {
                setFrame(moved, display: true)
                onDragMoved?(moved)              // swallowed: the content never sees a drag
            } else {
                super.sendEvent(event)
            }
        case .leftMouseUp:
            let pointer = screenPoint(of: event)
            if drag.end() {
                onDragEnded?(pointer, frame)     // swallowed: a drag is not a click
            } else {
                super.sendEvent(event)
            }
        default:
            super.sendEvent(event)
        }
    }
```

(d) `MacFloatingPanelController`: make the placement mutable and add the API. Replace `private let config` usage of `config.placement` with a stored `private var placement: MacFloatingPanelPlacement` initialised in `init` (`self.placement = config.placement`), then:

- in `init`, after the hover wiring: 

```swift
        panel.isDraggable = config.isDraggable
        panel.dragThreshold = config.dragThreshold
        panel.onDragMoved = { [weak self] frame in self?.targetFrame = frame }
        panel.onDragEnded = { [weak self] pointer, frame in self?.finishDrag(pointer: pointer, frame: frame) }
```

- new members:

```swift
    var currentPlacement: MacFloatingPanelPlacement { placement }

    /// Applies a saved or computed placement; re-places at once when visible.
    func setPlacement(_ newPlacement: MacFloatingPanelPlacement) {
        placement = newPlacement
        if panel.isVisible { place() }
    }

    private func finishDrag(pointer: CGPoint, frame: CGRect) {
        guard let dock = EdgeDockGeometry.snap(pointer: pointer, panelFrame: frame, screens: environment.screens()) else {
            place()
            return
        }
        placement = .edgeDocked(edge: dock.edge, offset: dock.offset, screenID: dock.screenID)
        place()
        config.onPlacementChanged?(placement)
    }
```

- `place()` becomes:

```swift
    private func place() {
        let screens = environment.screens()
        guard let resolved = placement.resolve(panelSize: contentSize, mouse: environment.mouseLocation(), screens: screens) else { return }
        targetFrame = resolved.frame
        panel.setFrame(targetFrame, display: true)
    }
```

- `currentScreen()` uses `placement.targetScreenIndex(...)` instead of `config.placement...`.

- `resize(to:)`: after storing `contentSize`, for a docked placement re-place instead of the top-fixed resize:

```swift
        if case .edgeDocked = placement {
            if panel.isVisible { place() }
            return
        }
```
(insert before the `guard panel.isVisible, let screen = currentScreen()` line).

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2, then `-only-testing:ConduitMacTests/MacFloatingPanelPlacementTests` and `-only-testing:ConduitMacTests/EdgeDockGeometryTests` again.
Expected: all pass. If a synthetic mouse event reports `panel.windowNumber == 0` (panel not yet realized), call `controller.show()` first (the tests do) and wait for `isVisible`. Hardware smoke (Task 14): on a real display, press a SwiftUI `Button` inside a draggable panel without moving (it must still click), then drag from the same button (it must not click on release, and must not stay highlighted); if a control keeps tracking, the consumer uses a dedicated drag handle region instead.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Panels/MacPanelDragTracker.swift' 'ConduitMac/Panels/MacFloatingPanel.swift' 'ConduitMacTests/MacPanelDragTrackerTests.swift' 'ConduitMacTests/MacFloatingPanelTests.swift'
git commit -m "macOS: draggable floating panel with edge snap and placement callback (shared base)"
```

---

### Task 4: Stream event hub

**Files:**
- Create: `ConduitMac/Shared/MacStreamEventHub.swift`
- Test: `ConduitMacTests/MacStreamEventHubTests.swift`

**Interfaces:**
- Produces: `@MainActor final class MacStreamEventHub { static let shared; struct Token: Hashable; func subscribe(_ handler: @escaping @MainActor (StreamEvent) -> Void) -> Token; func unsubscribe(_ token: Token); func publish(_ event: StreamEvent); var subscriberCount: Int }`

Delivery rules: subscription order; a subscriber added during a publish does not see that event; a subscriber removed during a publish is skipped; with no subscribers `publish` does nothing.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacStreamEventHubTests: XCTestCase {
    private func label(_ event: StreamEvent) -> String {
        switch event {
        case .messageStart(let id): return "start:\(id)"
        case .messageDelta(let id, let text): return "delta:\(id):\(text)"
        default: return "other"
        }
    }

    func testPublishWithNoSubscribersIsANoOp() {
        MacStreamEventHub().publish(.messageStart(sessionId: "s"))
    }

    func testEverySubscriberReceivesEveryEventInSubscriptionOrder() {
        let hub = MacStreamEventHub()
        var seen: [String] = []
        _ = hub.subscribe { seen.append("a/" + self.label($0)) }
        _ = hub.subscribe { seen.append("b/" + self.label($0)) }
        hub.publish(.messageStart(sessionId: "s1"))
        hub.publish(.messageDelta(sessionId: "s2", text: "x"))
        XCTAssertEqual(seen, ["a/start:s1", "b/start:s1", "a/delta:s2:x", "b/delta:s2:x"])
    }

    func testUnsubscribeStopsDelivery() {
        let hub = MacStreamEventHub()
        var count = 0
        let token = hub.subscribe { _ in count += 1 }
        hub.publish(.messageStart(sessionId: "s"))
        hub.unsubscribe(token)
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testSubscriberAddedDuringPublishMissesThatEvent() {
        let hub = MacStreamEventHub()
        var late = 0
        var added = false
        _ = hub.subscribe { _ in
            guard !added else { return }
            added = true
            _ = hub.subscribe { _ in late += 1 }
        }
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(late, 0)
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(late, 1)
    }

    func testSubscriberRemovedDuringPublishIsSkipped() {
        let hub = MacStreamEventHub()
        var second = 0
        var secondToken: MacStreamEventHub.Token!
        _ = hub.subscribe { _ in hub.unsubscribe(secondToken) }
        secondToken = hub.subscribe { _ in second += 1 }
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(second, 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacStreamEventHubTests`
Expected: build failure, `cannot find 'MacStreamEventHub' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Multicast for every parsed `StreamEvent`, fed by the one gated line in
/// `AppState.handleStreamEvent` (Task 5). Mac-only consumers (Quick Ask, the
/// agent activity feed) subscribe here instead of each adding a line to
/// upstream code. Events arrive on the main actor, before AppState's
/// active-session filter, for every session this socket carries.
@MainActor
final class MacStreamEventHub {
    static let shared = MacStreamEventHub()

    typealias Handler = @MainActor (StreamEvent) -> Void

    struct Token: Hashable {
        fileprivate let id: UInt64
    }

    private var entries: [(token: Token, handler: Handler)] = []
    private var nextID: UInt64 = 0

    var subscriberCount: Int { entries.count }

    func subscribe(_ handler: @escaping Handler) -> Token {
        nextID += 1
        let token = Token(id: nextID)
        entries.append((token, handler))
        return token
    }

    func unsubscribe(_ token: Token) {
        entries.removeAll { $0.token == token }
    }

    func publish(_ event: StreamEvent) {
        guard !entries.isEmpty else { return }
        let snapshot = entries
        for entry in snapshot where entries.contains(where: { $0.token == entry.token }) {
            entry.handler(event)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the same command as Step 2.
Expected: all MacStreamEventHubTests pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Shared/MacStreamEventHub.swift' 'ConduitMacTests/MacStreamEventHubTests.swift'
git commit -m "macOS: stream event hub (shared base)"
```

---

### Task 5: The AppState tap (one gated line) and its ledger row

**Files:**
- Modify: `Conduit/Services/AppState.swift` (`handleStreamEvent`, about line 23412 in a tree with the user's pending edits)
- Modify: `docs/macos/PORTING_LEDGER.md` (one row)
- Create: `ConduitMacTests/MacSharedBaseTestSupport.swift`
- Test: `ConduitMacTests/MacStreamTapTests.swift`

**Interfaces:**
- Consumes: `MacStreamEventHub.shared` (Task 4).
- Produces: every `StreamEvent` that reaches `AppState.handleStreamEvent` is published to the hub first, before the voice-job observer, the early returns for `sessionTitle` and `statusUpdate`, and the active-session filter. `MacSharedBaseAppStateFixture` (test support): `init(reconnectScheduler:reconnectExecutor:)`, `appState`, `tearDown()`.

- [ ] **Step 1: Write the test support and the failing tests**

`ConduitMacTests/MacSharedBaseTestSupport.swift`:

```swift
import XCTest
@testable import ConduitMac

/// A real `AppState` built the way `MacSessionTabsBindTests` builds one:
/// injected defaults, no saved connection, no network, widget output kept out
/// of the real app group. Call `tearDown()` from the test's tearDown.
@MainActor
final class MacSharedBaseAppStateFixture {
    let suite = HostedTestSupport.makeSuite()
    let scratch: URL
    let appState: AppState

    init(
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil
    ) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSharedBase.\(UUID().uuidString)", isDirectory: true)
        self.scratch = scratch
        let appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            reconnectScheduler: reconnectScheduler,
            reconnectExecutor: reconnectExecutor,
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
        appState.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: scratch.appendingPathComponent("widgets", isDirectory: true))
        appState.widgetSnapshotReloadOverride = {}
        appState.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
        self.appState = appState
    }

    func tearDown() {
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }
}
```

`ConduitMacTests/MacStreamTapTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacStreamTapTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!
    private var token: MacStreamEventHub.Token?
    private var seen: [String] = []

    override func setUp() async throws {
        fixture = MacSharedBaseAppStateFixture()
        seen = []
        token = MacStreamEventHub.shared.subscribe { [weak self] event in
            self?.seen.append(Self.label(event))
        }
    }

    override func tearDown() async throws {
        if let token { MacStreamEventHub.shared.unsubscribe(token) }
        token = nil
        fixture.tearDown()
        fixture = nil
    }

    private static func label(_ event: StreamEvent) -> String {
        switch event {
        case .messageStart(let id): return "start:\(id)"
        case .messageDelta(let id, _): return "delta:\(id)"
        case .messageInterrupted(let id): return "interrupted:\(id)"
        case .approval(let id, _): return "approval:\(id)"
        case .sessionTitle(let runtime, _, _): return "title:\(runtime)"
        default: return "other"
        }
    }

    func testEventForAnInactiveSessionReachesTheHubAndLeavesAppStateUntouched() {
        let appState = fixture.appState
        appState.activeSessionId = "active"
        let messagesBefore = appState.messages
        appState.handleStreamEvent(.messageDelta(sessionId: "other", text: "hello"))
        XCTAssertEqual(seen, ["delta:other"])
        XCTAssertEqual(appState.messages, messagesBefore, "AppState still drops events for sessions that are not open")
        XCTAssertFalse(appState.turnState.isRunning)
    }

    func testTheEarlyReturnPathStillPublishes() {
        fixture.appState.handleStreamEvent(.sessionTitle(runtimeSessionId: "r", storedSessionId: "s", title: "T"))
        XCTAssertEqual(seen, ["title:r"], "the tap is the first statement, ahead of the sessionTitle early return")
    }

    func testEveryKindOfEventIsForwarded() {
        let appState = fixture.appState
        let approval = ApprovalActivity(
            sessionId: "other", requestId: "q1", command: "ls", description: "list",
            choices: nil, allowPermanent: true, smartDenied: false, status: .pending)
        appState.handleStreamEvent(.messageStart(sessionId: "other"))
        appState.handleStreamEvent(.approval(sessionId: "other", activity: approval))
        appState.handleStreamEvent(.messageInterrupted(sessionId: "other"))
        XCTAssertEqual(seen, ["start:other", "approval:other", "interrupted:other"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacStreamTapTests`
Expected: the three tests fail on `XCTAssertEqual(seen, ...)` (`seen` is empty). A compile error in the fixture means an `AppState.init` argument changed; match `MacSessionTabsBindTests.setUp`.

- [ ] **Step 3: Add the gated line**

In `Conduit/Services/AppState.swift`, change the start of `handleStreamEvent`. Match on the anchor text; do not touch any other line.

Before:

```swift
    func handleStreamEvent(_ event: StreamEvent) {
        // Voice background jobs are not the active conversation, so they
        // observe every event before the active-session filter below.
        voiceBackgroundJobSupervisor.observe(event)
```

After:

```swift
    func handleStreamEvent(_ event: StreamEvent) {
        #if os(macOS) // MAC: Mac-side subscribers (Quick Ask, activity feed) see every session's events, ahead of the active-session filter
        MacStreamEventHub.shared.publish(event)
        #endif // MAC:
        // Voice background jobs are not the active conversation, so they
        // observe every event before the active-session filter below.
        voiceBackgroundJobSupervisor.observe(event)
```

Verify the diff is purely additive and contains only your three lines: `git diff -U0 -- Conduit/Services/AppState.swift | grep '^[-+][^-+]'`
Expected (in the worktree): exactly the three `+` lines above and no `-` lines. In the main checkout the user's own hunk also shows; ignore that one and stage with the patch recipe from Global Constraints.

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2.
Expected: all MacStreamTapTests pass. Then build once with the full build command to confirm nothing else broke.

- [ ] **Step 5: Ledger row and commit**

Append this as the last row of the table in `docs/macos/PORTING_LEDGER.md` (the last line starting with `| ` before `## Sync routine`; read the file first to find it):

```
| Conduit/Services/AppState.swift `handleStreamEvent` | R4 (1 region, `#if`/`#endif` tagged `// MAC:`, additive: no line removed, no stored property added) | publishes every parsed StreamEvent to the Mac stream hub as the first statement, ahead of the voice-job observer, the `sessionTitle`/`statusUpdate` early returns and the active-session filter, so Quick Ask and the agent activity feed see events for sessions that are not open (verified: the gateway pushes events for every session this socket created or resumed) | ConduitMac/Shared/MacStreamEventHub.swift; tested in MacStreamTapTests |
```

```bash
git add 'Conduit/Services/AppState.swift' 'docs/macos/PORTING_LEDGER.md' 'ConduitMacTests/MacSharedBaseTestSupport.swift' 'ConduitMacTests/MacStreamTapTests.swift'
git commit -m "macOS: publish every stream event to the Mac stream hub (shared base)"
```

---

### Task 6: Activity models and approval choice rules

**Files:**
- Create: `ConduitMac/Activity/AgentActivityModels.swift`
- Create: `ConduitMacTests/AgentActivityTestSupport.swift`
- Test: `ConduitMacTests/AgentActivityModelsTests.swift`

**Interfaces:**
- Produces:
  - `enum AgentActivityAvailability: Equatable { case live, eventsOnly, offline }`
  - `enum AgentActivityRespondResult: Equatable { case resolved, alreadyResolved, failed(String) }`
  - `struct AgentActivityItem: Identifiable, Equatable` (fields below), `static func ordered(_:) -> [AgentActivityItem]`
  - `struct AgentActivityEvent: Equatable` with `Reason` and `Payload` (below)
  - `enum AgentActivityApprovalChoices { static let once, session, always, deny; static func allowed(for:) -> [String]; static func isAllowed(_:for:) -> Bool }`
  - test factories: `AgentActivityTestSupport.item(...)`, `.approval(...)`, `.summary(...)`, `.row(...)`

- [ ] **Step 1: Write the test support and the failing tests**

`ConduitMacTests/AgentActivityTestSupport.swift`:

```swift
import Foundation
@testable import ConduitMac

enum AgentActivityTestSupport {
    static let origin = Date(timeIntervalSince1970: 1_000_000)

    static func item(
        _ id: String,
        kind: AgentActivityItem.Kind = .turn,
        state: AgentActivityItem.State = .working,
        since seconds: TimeInterval = 0,
        sessionId: String? = nil
    ) -> AgentActivityItem {
        AgentActivityItem(
            id: id, kind: kind, state: state, sessionId: sessionId,
            startedAt: origin.addingTimeInterval(seconds), since: origin.addingTimeInterval(seconds))
    }

    static func approval(
        session: String = "s1",
        request: String? = "q1",
        command: String = "rm -rf build",
        description: String = "Delete build output",
        choices: [String]? = nil,
        allowPermanent: Bool = true,
        smartDenied: Bool = false
    ) -> ApprovalActivity {
        ApprovalActivity(
            sessionId: session, requestId: request, command: command, description: description,
            choices: choices, allowPermanent: allowPermanent, smartDenied: smartDenied, status: .pending)
    }

    static func summary(
        id: String, stored: String? = nil, alternates: [String] = [],
        title: String, lineage: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: stored, alternateIds: alternates, title: title, model: "",
            updatedLabel: "", profile: "default", source: .chat, isActive: false,
            isArchived: false, lineageRootId: lineage)
    }

    static func row(_ runtime: String, stored: String = "", _ status: String) -> LiveSessionStatus {
        LiveSessionStatus(runtimeSessionId: runtime, storedSessionId: stored, status: status)
    }
}
```

`ConduitMacTests/AgentActivityModelsTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class AgentActivityModelsTests: XCTestCase {
    private func item(_ id: String, _ state: AgentActivityItem.State, since: TimeInterval) -> AgentActivityItem {
        AgentActivityTestSupport.item(id, state: state, since: since)
    }

    func testOrderingNeedsUserThenWorkingOldestFirstThenFinishedNewestFirst() {
        let ordered = AgentActivityItem.ordered([
            item("f3", .finished(.completed), since: 3),
            item("w1", .working, since: 1),
            item("n5", .needsUser, since: 5),
            item("f9", .finished(.failed("boom")), since: 9),
            item("w0", .working, since: 0),
        ])
        XCTAssertEqual(ordered.map(\.id), ["n5", "w0", "w1", "f9", "f3"])
    }

    func testOrderingBreaksTiesById() {
        let ordered = AgentActivityItem.ordered([item("b", .working, since: 1), item("a", .working, since: 1)])
        XCTAssertEqual(ordered.map(\.id), ["a", "b"])
    }

    func testDefaultChoicesAreTheFullSet() {
        let approval = AgentActivityTestSupport.approval(choices: nil)
        XCTAssertEqual(AgentActivityApprovalChoices.allowed(for: approval), ["once", "session", "always", "deny"])
    }

    func testSmartDeniedOffersOnlyOnceAndDeny() {
        let approval = AgentActivityTestSupport.approval(choices: nil, smartDenied: true)
        XCTAssertEqual(AgentActivityApprovalChoices.allowed(for: approval), ["once", "deny"])
        XCTAssertFalse(AgentActivityApprovalChoices.isAllowed("always", for: approval))
    }

    func testAlwaysIsHiddenWhenPermanentIsNotAllowed() {
        let approval = AgentActivityTestSupport.approval(choices: nil, allowPermanent: false)
        XCTAssertEqual(AgentActivityApprovalChoices.allowed(for: approval), ["once", "session", "deny"])
    }

    func testExplicitChoicesWin() {
        let approval = AgentActivityTestSupport.approval(choices: ["once", "deny"])
        XCTAssertTrue(AgentActivityApprovalChoices.isAllowed("once", for: approval))
        XCTAssertFalse(AgentActivityApprovalChoices.isAllowed("session", for: approval))
    }

    func testUnknownChoiceIsNeverAllowed() {
        XCTAssertFalse(AgentActivityApprovalChoices.isAllowed("approve", for: AgentActivityTestSupport.approval()))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/AgentActivityModelsTests`
Expected: build failure, `cannot find 'AgentActivityItem' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Activity/AgentActivityModels.swift`:

```swift
import Foundation

/// How much the feed can see right now.
enum AgentActivityAvailability: Equatable {
    /// Connected; stream events and the `session.active_list` poll both work.
    case live
    /// Connected, but the gateway has no `session.active_list`: only sessions on this socket show.
    case eventsOnly
    /// Not connected. Rows clear after a grace period; no events are emitted.
    case offline
}

enum AgentActivityRespondResult: Equatable {
    case resolved
    case alreadyResolved
    case failed(String)
}

/// One row of what the agent is doing or waiting for.
struct AgentActivityItem: Identifiable, Equatable {
    /// `kanban` and `cron` are reserved for the notch plan; the shared base never produces them.
    enum Kind: Equatable { case turn, approval, clarify, inputPrompt, kanban, cron }
    enum Outcome: Equatable { case completed, failed(String), interrupted }
    /// `blocked` is reserved for kanban rows.
    enum State: Equatable { case working, needsUser, finished(Outcome), blocked }

    /// `turn:<runtimeId>`, `approval:<queueId>`, `clarify:<requestId>`, `inputPrompt:<requestId>`;
    /// `approval:waiting:<runtimeId>` and `clarify:waiting:<runtimeId>` are the no-content fallbacks.
    let id: String
    var kind: Kind
    var state: State
    /// Runtime id as the gateway reported it; open via `requestOpenSession`.
    var sessionId: String?
    /// Durable id (catalog id, else stored id, else lineage root, else runtime id).
    var sessionKey: String?
    var profile: String
    var dashboardID: String
    /// Session title from the catalog or a `session.title` event; empty when unknown.
    var title: String
    /// Tool name, approval description or command, first clarify question.
    var detail: String?
    /// When the turn or request began.
    var startedAt: Date
    /// When the current state began (for a finished turn, the finish time).
    var since: Date
    /// Per-session turn counter; with `sessionKey` it is the "one Done per turn" dedupe key.
    var turnSeq: Int
    var approval: ApprovalActivity?
    var isActiveSession: Bool
    /// Seen only in `session.active_list`: no stream events for it, so no tool names.
    var isPollOnly: Bool
    /// The last approval response error, if any.
    var failure: String?
    var openQuestionCount: Int

    init(
        id: String, kind: Kind, state: State,
        sessionId: String? = nil, sessionKey: String? = nil,
        profile: String = "default", dashboardID: String = "none",
        title: String = "", detail: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 0), since: Date = Date(timeIntervalSince1970: 0),
        turnSeq: Int = 0, approval: ApprovalActivity? = nil,
        isActiveSession: Bool = false, isPollOnly: Bool = false,
        failure: String? = nil, openQuestionCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.sessionId = sessionId
        self.sessionKey = sessionKey
        self.profile = profile
        self.dashboardID = dashboardID
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.since = since
        self.turnSeq = turnSeq
        self.approval = approval
        self.isActiveSession = isActiveSession
        self.isPollOnly = isPollOnly
        self.failure = failure
        self.openQuestionCount = openQuestionCount
    }

    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    /// 0 needs the user, 1 working, 2 finished.
    var sortRank: Int {
        switch state {
        case .needsUser, .blocked: return 0
        case .working: return 1
        case .finished: return 2
        }
    }

    /// Needs-user and working oldest first; finished newest first; ties by id.
    static func ordered(_ items: [AgentActivityItem]) -> [AgentActivityItem] {
        items.sorted { a, b in
            if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
            if a.since != b.since { return a.sortRank == 2 ? a.since > b.since : a.since < b.since }
            return a.id < b.id
        }
    }
}

/// Something that happened, delivered after `items` already reflects it.
struct AgentActivityEvent: Equatable {
    enum Reason: Equatable {
        /// Answered through `AgentActivityFeed.respond`.
        case answeredHere
        /// The gateway said `resolved` and this feed did not send the answer (another surface, another Mac).
        case answeredElsewhere
        case expired
        case withdrawn
        case sessionClosed
    }

    enum Payload: Equatable {
        case turnStarted(AgentActivityItem)
        case turnFinished(AgentActivityItem, outcome: AgentActivityItem.Outcome, replyPreview: String?, observedGap: Bool)
        /// Approval, clarify, input prompt.
        case decisionRequested(AgentActivityItem)
        case decisionResolved(id: String, reason: Reason)
        case titleChanged(sessionKey: String, title: String)
    }

    /// Monotonic per feed instance; the consumer dedupe key.
    let eventId: UInt64
    let at: Date
    let payload: Payload
}

/// Which approval answers a request offers. Mirrors `ChatView.allows`:
/// explicit `choices` win, else the default set (smart-denied requests offer
/// only once and deny), and `always` also needs `allowPermanent`.
enum AgentActivityApprovalChoices {
    static let once = "once"
    static let session = "session"
    static let always = "always"
    static let deny = "deny"

    static func allowed(for approval: ApprovalActivity) -> [String] {
        let offered = approval.choices ?? (approval.smartDenied ? [once, deny] : [once, session, always, deny])
        return offered.filter { $0 != always || approval.allowPermanent }
    }

    static func isAllowed(_ choice: String, for approval: ApprovalActivity) -> Bool {
        allowed(for: approval).contains(choice)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2.
Expected: all AgentActivityModelsTests pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/AgentActivityModels.swift' 'ConduitMacTests/AgentActivityTestSupport.swift' 'ConduitMacTests/AgentActivityModelsTests.swift'
git commit -m "macOS: agent activity models and approval choice rules (shared base)"
```

---

### Task 7: Reducer, part 1: stream events, decisions, lifecycle

**Files:**
- Create: `ConduitMac/Activity/AgentActivityReducer.swift`
- Create: `ConduitMacTests/AgentActivityHarness.swift`
- Test: `ConduitMacTests/AgentActivityReducerStreamTests.swift`

**Interfaces:**
- Consumes: models (Task 6); `StreamEvent`, `ApprovalActivity`, `ClarifyActivity`, `InputPromptActivity`.
- Produces:
  - `struct AgentActivityState: Equatable` (all fields below, including those Task 8 uses)
  - `enum AgentActivityInput` with `.stream(StreamEvent)`, `.activeSession(id: String?)`, `.respondStarted(itemId:)`, `.respondFailed(itemId:message:)`, `.respondResolved(itemId:alreadyResolved:)`, `.dismiss(itemId:)`, `.reset(profile:dashboardID:)`, `.tick`
  - `enum AgentActivityReducer { static func reduce(_ state:, _ input:, now:) -> Output; struct Output { var state; var payloads } }` plus the constants `missesToFinish = 2`, `reopenWindow = 3`, `finishedLifetime = 30`, `maxFinished = 3`, `staleSilence = 600`, `decisionMaxAge = 600`, `previewLimit = 200`
  - test helper `AgentActivityHarness`

Rules this task implements (the tests below pin each):
- `messageStart`, `messageDelta`, `reasoningDelta`, `toolStart`, `sessionBusy(true)` and an `approval` raise `turn:<runtimeId>` (working) and emit `turnStarted` once.
- `messageComplete` finishes `.completed` with `replyPreview` (trimmed, at most 200 chars); `messageError` finishes `.failed(message)`; `messageInterrupted` finishes `.interrupted`; `sessionBusy(false)` finishes `.completed` with no preview. Terminal events for a session with no working turn are ignored.
- Work arriving within 3 s of a `.completed` finish reopens the same turn (same `turnSeq`, no second `turnStarted`).
- `approval`, `clarify`, `inputPrompt` raise a `needsUser` item and one `decisionRequested`; a repeat of the same request id updates silently. Withdrawal and expiry events remove the item with `decisionResolved` and a mapped `Reason`.
- `sessionTitle` updates titles and emits `titleChanged` only when the title changed.
- `tick` drops finished rows after 30 s and keeps at most 3, expires decisions older than 600 s, and (when polling is unavailable) drops silent working turns after 600 s.

- [ ] **Step 1: Write the harness and the failing tests**

`ConduitMacTests/AgentActivityHarness.swift`:

```swift
import Foundation
@testable import ConduitMac

/// Drives the reducer with a controllable clock and collects what it emits.
struct AgentActivityHarness {
    var state = AgentActivityState()
    var payloads: [AgentActivityEvent.Payload] = []
    let origin = AgentActivityTestSupport.origin

    @discardableResult
    mutating func send(_ input: AgentActivityInput, at seconds: TimeInterval = 0) -> [AgentActivityEvent.Payload] {
        let output = AgentActivityReducer.reduce(state, input, now: origin.addingTimeInterval(seconds))
        state = output.state
        payloads += output.payloads
        return output.payloads
    }

    @discardableResult
    mutating func stream(_ event: StreamEvent, at seconds: TimeInterval = 0) -> [AgentActivityEvent.Payload] {
        send(.stream(event), at: seconds)
    }

    func item(_ id: String) -> AgentActivityItem? { state.items[id] }

    var turnStarts: [AgentActivityItem] {
        payloads.compactMap { if case .turnStarted(let item) = $0 { return item } else { return nil } }
    }

    var turnFinishes: [(item: AgentActivityItem, outcome: AgentActivityItem.Outcome, preview: String?, gap: Bool)] {
        payloads.compactMap {
            if case .turnFinished(let item, let outcome, let preview, let gap) = $0 { return (item, outcome, preview, gap) }
            return nil
        }
    }

    var requests: [AgentActivityItem] {
        payloads.compactMap { if case .decisionRequested(let item) = $0 { return item } else { return nil } }
    }

    var resolutions: [(id: String, reason: AgentActivityEvent.Reason)] {
        payloads.compactMap { if case .decisionResolved(let id, let reason) = $0 { return (id, reason) } else { return nil } }
    }

    var titleChanges: [(key: String, title: String)] {
        payloads.compactMap { if case .titleChanged(let key, let title) = $0 { return (key, title) } else { return nil } }
    }
}
```

`ConduitMacTests/AgentActivityReducerStreamTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class AgentActivityReducerStreamTests: XCTestCase {
    private func approvalEvent(_ session: String = "s1", request: String = "q1") -> StreamEvent {
        .approval(sessionId: session, activity: AgentActivityTestSupport.approval(session: session, request: request))
    }

    // MARK: - Turns

    func testMessageStartRaisesAWorkingTurnOnce() throws {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 5)
        let item = try XCTUnwrap(h.item("turn:s1"))
        XCTAssertEqual(item.kind, .turn)
        XCTAssertEqual(item.state, .working)
        XCTAssertEqual(item.sessionId, "s1")
        XCTAssertEqual(item.turnSeq, 1)
        XCTAssertEqual(item.startedAt, h.origin.addingTimeInterval(5))
        XCTAssertEqual(h.turnStarts.count, 1)
        h.stream(.messageStart(sessionId: "s1"), at: 6)
        XCTAssertEqual(h.turnStarts.count, 1, "already working: no second start")
    }

    func testDeltaToolAndBusyEachRaiseAMissingTurn() {
        for (index, event) in [
            StreamEvent.messageDelta(sessionId: "s1", text: "hi"),
            .reasoningDelta(sessionId: "s1", text: "hm"),
            .toolStart(sessionId: "s1", toolName: "terminal", toolInput: nil),
            .sessionBusy(sessionId: "s1", busy: true),
        ].enumerated() {
            var h = AgentActivityHarness()
            h.stream(event)
            XCTAssertEqual(h.turnStarts.count, 1, "case \(index)")
        }
    }

    func testToolStartSetsDetailAndToolCompleteClearsIt() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.toolStart(sessionId: "s1", toolName: "terminal", toolInput: nil))
        XCTAssertEqual(h.item("turn:s1")?.detail, "terminal")
        h.stream(.toolComplete(sessionId: "s1", toolName: "terminal", toolOutput: nil))
        XCTAssertNil(h.item("turn:s1")?.detail)
    }

    func testCompleteFinishesWithATrimmedPreview() throws {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "  Done!  ", reasoning: nil), at: 12)
        let item = try XCTUnwrap(h.item("turn:s1"))
        XCTAssertEqual(item.state, .finished(.completed))
        XCTAssertEqual(item.startedAt, h.origin)
        XCTAssertEqual(item.since, h.origin.addingTimeInterval(12))
        XCTAssertEqual(h.turnFinishes.count, 1)
        XCTAssertEqual(h.turnFinishes[0].outcome, .completed)
        XCTAssertEqual(h.turnFinishes[0].preview, "Done!")
        XCTAssertFalse(h.turnFinishes[0].gap)
    }

    func testPreviewIsCappedAt200Characters() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: String(repeating: "a", count: 300), reasoning: nil))
        XCTAssertEqual(h.turnFinishes[0].preview?.count, 200)
    }

    func testErrorAndInterruptFinishWithTheirOutcome() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "e"))
        h.stream(.messageStart(sessionId: "i"))
        h.stream(.messageError(sessionId: "e", message: "boom"))
        h.stream(.messageInterrupted(sessionId: "i"))
        XCTAssertEqual(h.item("turn:e")?.state, .finished(.failed("boom")))
        XCTAssertEqual(h.item("turn:i")?.state, .finished(.interrupted))
        XCTAssertEqual(h.turnFinishes.map(\.outcome), [.failed("boom"), .interrupted])
    }

    func testBusyFalseEndsATurnThatNeverCompleted() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.sessionBusy(sessionId: "s1", busy: false))
        XCTAssertEqual(h.item("turn:s1")?.state, .finished(.completed))
        XCTAssertNil(h.turnFinishes[0].preview)
    }

    func testTerminalEventsWithoutAWorkingTurnAreIgnored() {
        var h = AgentActivityHarness()
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "x", reasoning: nil))
        h.stream(.messageError(sessionId: "s1", message: "x"))
        h.stream(.messageInterrupted(sessionId: "s1"))
        h.stream(.sessionBusy(sessionId: "s1", busy: false))
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testNewWorkWithinThreeSecondsReopensTheSameTurn() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "first", reasoning: nil), at: 10)
        h.stream(.messageStart(sessionId: "s1"), at: 12)
        XCTAssertEqual(h.item("turn:s1")?.state, .working)
        XCTAssertEqual(h.item("turn:s1")?.turnSeq, 1)
        XCTAssertEqual(h.item("turn:s1")?.startedAt, h.origin)
        XCTAssertEqual(h.turnStarts.count, 1, "a reopened turn is not a new start")
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "second", reasoning: nil), at: 20)
        XCTAssertEqual(h.turnFinishes.map(\.item.turnSeq), [1, 1], "consumers dedupe on (sessionKey, turnSeq)")
    }

    func testNewWorkAfterTheReopenWindowStartsANewTurn() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageComplete(sessionId: "s1", messageId: nil, content: "first", reasoning: nil), at: 10)
        h.stream(.messageStart(sessionId: "s1"), at: 14)
        XCTAssertEqual(h.item("turn:s1")?.turnSeq, 2)
        XCTAssertEqual(h.turnStarts.count, 2)
    }

    func testFailedTurnDoesNotReopen() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"), at: 0)
        h.stream(.messageError(sessionId: "s1", message: "boom"), at: 1)
        h.stream(.messageStart(sessionId: "s1"), at: 2)
        XCTAssertEqual(h.item("turn:s1")?.turnSeq, 2)
    }

    func testSessionsAreIndependent() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "a"))
        h.stream(.messageStart(sessionId: "b"))
        h.stream(.messageComplete(sessionId: "a", messageId: nil, content: "x", reasoning: nil))
        XCTAssertEqual(h.item("turn:a")?.state, .finished(.completed))
        XCTAssertEqual(h.item("turn:b")?.state, .working)
    }

    func testUnrelatedEventsAreIgnored() {
        var h = AgentActivityHarness()
        h.stream(.contextUpdate(sessionId: "s1", percent: 1, used: 1, max: 2))
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testActiveSessionFlagFollowsTheActiveId() {
        var h = AgentActivityHarness()
        h.send(.activeSession(id: "s1"))
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.messageStart(sessionId: "s2"))
        XCTAssertEqual(h.item("turn:s1")?.isActiveSession, true)
        XCTAssertEqual(h.item("turn:s2")?.isActiveSession, false)
        h.send(.activeSession(id: "s2"))
        XCTAssertEqual(h.item("turn:s1")?.isActiveSession, false)
        XCTAssertEqual(h.item("turn:s2")?.isActiveSession, true)
    }

    // MARK: - Decisions

    func testApprovalRaisesANeedsUserItemWithItsContentAndTheTurn() throws {
        var h = AgentActivityHarness()
        h.stream(approvalEvent())
        let item = try XCTUnwrap(h.item("approval:q1"))
        XCTAssertEqual(item.kind, .approval)
        XCTAssertEqual(item.state, .needsUser)
        XCTAssertEqual(item.approval?.command, "rm -rf build")
        XCTAssertEqual(item.detail, "Delete build output")
        XCTAssertNotNil(h.item("turn:s1"), "a pending approval implies a running turn")
        XCTAssertEqual(h.requests.map(\.id), ["approval:q1"])
    }

    func testReplayedApprovalNeitherDuplicatesTheRowNorRaisesASecondRequest() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent(), at: 0)
        h.stream(approvalEvent(), at: 30)
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(h.state.items.count, 2, "one turn, one approval")
        XCTAssertEqual(h.item("approval:q1")?.since, h.origin, "a replay keeps the original time")
    }

    func testWithdrawalReasonsMapToEventReasons() {
        let table: [(String, AgentActivityEvent.Reason)] = [
            ("resolved", .answeredElsewhere), ("timeout", .expired), ("session_closed", .sessionClosed),
            ("interrupted", .withdrawn), ("shutdown", .withdrawn), ("something-new", .withdrawn),
        ]
        for (raw, expected) in table {
            var h = AgentActivityHarness()
            h.stream(approvalEvent())
            h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: raw))
            XCTAssertNil(h.item("approval:q1"), raw)
            XCTAssertEqual(h.resolutions.map(\.id), ["approval:q1"], raw)
            XCTAssertEqual(h.resolutions.map(\.reason), [expected], raw)
        }
    }

    func testResolvedAfterALocalResponseIsAnsweredHere() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent())
        h.send(.respondStarted(itemId: "approval:q1"))
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.answeredHere])
    }

    func testAFailedResponseForgetsTheLocalClaim() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent())
        h.send(.respondStarted(itemId: "approval:q1"))
        h.send(.respondFailed(itemId: "approval:q1", message: "offline"))
        XCTAssertEqual(h.item("approval:q1")?.failure, "offline")
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.answeredElsewhere])
    }

    func testRespondResolvedRemovesTheItemWithTheRightReason() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent(request: "q1"))
        h.stream(approvalEvent(request: "q2"))
        h.send(.respondResolved(itemId: "approval:q1", alreadyResolved: false))
        h.send(.respondResolved(itemId: "approval:q2", alreadyResolved: true))
        XCTAssertEqual(h.resolutions.map(\.reason), [.answeredHere, .answeredElsewhere])
        // The gateway's own cancel for the same request now finds nothing.
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(h.resolutions.count, 2)
    }

    func testWithdrawalOfAnUnknownRequestDoesNothing() {
        var h = AgentActivityHarness()
        h.stream(.approvalWithdrawn(sessionId: "s1", requestId: "zzz", reason: "resolved"))
        XCTAssertTrue(h.payloads.isEmpty)
    }

    func testClarifyRaisesWithTheFirstQuestionAndOpenCount() throws {
        var h = AgentActivityHarness()
        let questions = [
            ClarifyQuestion(id: "a", question: "First?", choices: []),
            ClarifyQuestion(id: "b", question: "Second?", choices: []),
            ClarifyQuestion(id: "c", question: "Done?", choices: [], status: .answered),
        ]
        h.stream(.clarify(sessionId: "s1", activity: ClarifyActivity(requestId: "c1", questions: questions)))
        let item = try XCTUnwrap(h.item("clarify:c1"))
        XCTAssertEqual(item.kind, .clarify)
        XCTAssertEqual(item.detail, "First?")
        XCTAssertEqual(item.openQuestionCount, 2)
        h.stream(.clarifyExpire(sessionId: "s1", requestId: "c1", reason: nil))
        XCTAssertNil(h.item("clarify:c1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.expired])
    }

    func testAnAlreadyExpiredClarifyIsNotRaised() {
        var h = AgentActivityHarness()
        let question = ClarifyQuestion(id: "a", question: "First?", choices: [])
        h.stream(.clarify(sessionId: "s1", activity: ClarifyActivity(requestId: "c1", questions: [question], isExpired: true)))
        XCTAssertNil(h.item("clarify:c1"))
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testInputPromptCarriesNoDetailAndExpiresWithItsReason() throws {
        var h = AgentActivityHarness()
        let prompt = InputPromptActivity(requestId: "srq-1", sessionId: "s1", kind: .sudo)
        h.stream(.inputPrompt(sessionId: "s1", activity: prompt))
        let item = try XCTUnwrap(h.item("inputPrompt:srq-1"))
        XCTAssertEqual(item.kind, .inputPrompt)
        XCTAssertNil(item.detail, "sudo and secret prompts never travel as row text")
        h.stream(.inputPromptExpire(sessionId: "s1", requestId: "srq-1", reason: "session_closed"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.sessionClosed])
    }

    // MARK: - Titles

    func testTitleEventUpdatesItemsAndEmitsOnlyOnChange() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.stream(.sessionTitle(runtimeSessionId: "s1", storedSessionId: "st1", title: "Laravel"))
        XCTAssertEqual(h.item("turn:s1")?.title, "Laravel")
        XCTAssertEqual(h.item("turn:s1")?.sessionKey, "st1")
        XCTAssertEqual(h.titleChanges.map(\.title), ["Laravel"])
        XCTAssertEqual(h.titleChanges.map(\.key), ["st1"])
        h.stream(.sessionTitle(runtimeSessionId: "s1", storedSessionId: "st1", title: "Laravel"))
        XCTAssertEqual(h.titleChanges.count, 1)
    }

    // MARK: - Tick, dismiss, reset

    func testTickDropsFinishedAfterThirtySecondsAndKeepsThreeNewest() {
        var h = AgentActivityHarness()
        for (index, id) in ["a", "b", "c", "d"].enumerated() {
            h.stream(.messageStart(sessionId: id), at: TimeInterval(index))
            h.stream(.messageComplete(sessionId: id, messageId: nil, content: nil, reasoning: nil), at: TimeInterval(index))
        }
        h.send(.tick, at: 4)
        XCTAssertEqual(Set(h.state.items.keys), ["turn:b", "turn:c", "turn:d"])
        h.send(.tick, at: 40)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testTickExpiresAStuckDecision() {
        var h = AgentActivityHarness()
        h.stream(approvalEvent(), at: 0)
        h.send(.tick, at: 599)
        XCTAssertNotNil(h.item("approval:q1"))
        h.send(.tick, at: 601)
        XCTAssertNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.expired])
    }

    func testDismissRemovesOnlyFinishedItems() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "w"))
        h.stream(.messageStart(sessionId: "f"))
        h.stream(.messageComplete(sessionId: "f", messageId: nil, content: nil, reasoning: nil))
        h.send(.dismiss(itemId: "turn:w"))
        h.send(.dismiss(itemId: "turn:f"))
        XCTAssertNotNil(h.item("turn:w"))
        XCTAssertNil(h.item("turn:f"))
    }

    func testResetClearsEverythingSilentlyAndRearmsTheBaseline() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "s1"))
        h.state.baselinePending = false
        let before = h.payloads.count
        h.send(.reset(profile: "work", dashboardID: "d1"))
        XCTAssertTrue(h.state.items.isEmpty)
        XCTAssertEqual(h.payloads.count, before, "a scope switch emits nothing")
        XCTAssertEqual(h.state.scope, AgentActivityState.Scope(profile: "work", dashboardID: "d1"))
        XCTAssertTrue(h.state.baselinePending)
        h.stream(.messageStart(sessionId: "s2"))
        XCTAssertEqual(h.item("turn:s2")?.profile, "work")
        XCTAssertEqual(h.item("turn:s2")?.dashboardID, "d1")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/AgentActivityReducerStreamTests`
Expected: build failure, `cannot find 'AgentActivityState' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Activity/AgentActivityReducer.swift`:

```swift
import Foundation

/// Everything the reducer remembers. A plain value: copy it, compare it, test it.
struct AgentActivityState: Equatable {
    struct Scope: Equatable {
        var profile: String
        var dashboardID: String
    }

    /// Every id one session is known under. Matching is by any of them, the
    /// same rule as `SessionLiveStatusIndex.status(for:)`.
    struct Identity: Equatable {
        var runtimeId: String
        var storedId: String?
        var lineageRootId: String?
        var catalogId: String?
        var alternateIds: Set<String> = []

        var allIds: [String] {
            [runtimeId, storedId, catalogId, lineageRootId].compactMap { $0 } + alternateIds.sorted()
        }
        func matches(_ id: String) -> Bool { allIds.contains(id) }
    }

    /// A poll said `waiting` and no decision content is known yet.
    struct Waiting: Equatable {
        /// Found in the baseline pass: its content is shown but not announced.
        var silent: Bool
        /// The feed has started the `approval.pending` fetch.
        var requested = false
    }

    var scope = Scope(profile: "default", dashboardID: "none")
    var items: [String: AgentActivityItem] = [:]
    /// Keyed by runtime id.
    var identities: [String: Identity] = [:]
    /// Any known id to the latest title.
    var titles: [String: String] = [:]
    /// Item id to consecutive polls that did not show it.
    var misses: [String: Int] = [:]
    /// Runtime id to the last stream event time.
    var lastEventAt: [String: Date] = [:]
    /// Runtime id to a pending-content record.
    var waiting: [String: Waiting] = [:]
    var locallyAnswered: Set<String> = []
    /// True until the first `session.active_list` after start, reconnect or scope reset.
    var baselinePending = true
    /// False when the gateway has no `session.active_list`.
    var pollAuthoritative = true
    var activeSessionId: String?
    var nextTurnSeq = 1
}

enum AgentActivityInput {
    case stream(StreamEvent)
    case activeSession(id: String?)
    case respondStarted(itemId: String)
    case respondFailed(itemId: String, message: String)
    case respondResolved(itemId: String, alreadyResolved: Bool)
    case dismiss(itemId: String)
    case reset(profile: String, dashboardID: String)
    case tick
}

/// `reduce(state, input, now) -> (state, events)`. Pure: no clock, no network, no AppKit.
enum AgentActivityReducer {
    /// Consecutive polls that must omit a working session before its turn finishes.
    static let missesToFinish = 2
    /// New work within this many seconds of a completed finish reopens the same turn.
    static let reopenWindow: TimeInterval = 3
    static let finishedLifetime: TimeInterval = 30
    static let maxFinished = 3
    /// A working turn with no event for this long is dropped when polling is unavailable.
    static let staleSilence: TimeInterval = 600
    /// The gateway blocks a decision for about five minutes; this is the backstop.
    static let decisionMaxAge: TimeInterval = 600
    static let previewLimit = 200

    struct Output {
        var state: AgentActivityState
        var payloads: [AgentActivityEvent.Payload]
    }

    static func reduce(_ state: AgentActivityState, _ input: AgentActivityInput, now: Date) -> Output {
        var engine = Engine(s: state, now: now)
        engine.apply(input)
        return Output(state: engine.s, payloads: engine.out)
    }

    private struct Engine {
        var s: AgentActivityState
        let now: Date
        var out: [AgentActivityEvent.Payload] = []

        enum Source { case stream, poll }

        mutating func apply(_ input: AgentActivityInput) {
            switch input {
            case .stream(let event):
                stream(event)
            case .activeSession(let id):
                s.activeSessionId = id
                for key in Array(s.items.keys) {
                    if let runtime = s.items[key]?.sessionId { s.items[key]?.isActiveSession = isActive(runtime) }
                }
            case .respondStarted(let itemId):
                guard var item = s.items[itemId] else { return }
                item.failure = nil
                s.items[itemId] = item
                if let request = item.approval?.requestId { s.locallyAnswered.insert(request) }
            case .respondFailed(let itemId, let message):
                guard var item = s.items[itemId] else { return }
                item.failure = message
                s.items[itemId] = item
                if let request = item.approval?.requestId { s.locallyAnswered.remove(request) }
            case .respondResolved(let itemId, let alreadyResolved):
                resolve(itemId, alreadyResolved ? .answeredElsewhere : .answeredHere)
            case .dismiss(let itemId):
                if let item = s.items[itemId], item.isFinished { s.items[itemId] = nil }
            case .reset(let profile, let dashboardID):
                var fresh = AgentActivityState()
                fresh.scope = .init(profile: profile, dashboardID: dashboardID)
                fresh.nextTurnSeq = s.nextTurnSeq
                fresh.activeSessionId = s.activeSessionId
                s = fresh
            case .tick:
                tick()
            }
        }

        // MARK: Identity

        mutating func ensureIdentity(_ runtime: String, stored: String? = nil) {
            var identity = s.identities[runtime] ?? AgentActivityState.Identity(runtimeId: runtime)
            if let stored, !stored.isEmpty { identity.storedId = stored }
            s.identities[runtime] = identity
            refreshKeys(runtime)
        }

        /// The canonical runtime id for any id the session is known under.
        mutating func runtimeID(for id: String) -> String {
            if s.identities[id] != nil { return id }
            if let hit = s.identities.values.first(where: { $0.matches(id) }) { return hit.runtimeId }
            ensureIdentity(id)
            return id
        }

        func sessionKey(_ runtime: String) -> String {
            let identity = s.identities[runtime]
            return identity?.catalogId ?? identity?.storedId ?? identity?.lineageRootId ?? runtime
        }

        func title(_ runtime: String) -> String {
            for id in s.identities[runtime]?.allIds ?? [runtime] {
                if let title = s.titles[id] { return title }
            }
            return ""
        }

        func isActive(_ runtime: String) -> Bool {
            guard let active = s.activeSessionId else { return false }
            return s.identities[runtime]?.matches(active) ?? (active == runtime)
        }

        mutating func refreshKeys(_ runtime: String) {
            let key = sessionKey(runtime)
            for id in Array(s.items.keys) where s.items[id]?.sessionId == runtime {
                s.items[id]?.sessionKey = key
            }
        }

        mutating func touch(_ runtime: String) {
            s.lastEventAt[runtime] = now
            if var turn = s.items["turn:\(runtime)"], turn.isPollOnly {
                turn.isPollOnly = false
                s.items["turn:\(runtime)"] = turn
            }
        }

        func baseItem(id: String, kind: AgentActivityItem.Kind, state: AgentActivityItem.State, runtime: String) -> AgentActivityItem {
            AgentActivityItem(
                id: id, kind: kind, state: state, sessionId: runtime, sessionKey: sessionKey(runtime),
                profile: s.scope.profile, dashboardID: s.scope.dashboardID, title: title(runtime),
                startedAt: now, since: now, isActiveSession: isActive(runtime))
        }

        // MARK: Turns

        mutating func ensureWorkingTurn(_ runtime: String, source: Source, announce: Bool) {
            let id = "turn:\(runtime)"
            if var existing = s.items[id] {
                switch existing.state {
                case .working, .needsUser, .blocked:
                    return
                case .finished(let outcome):
                    let recent = now.timeIntervalSince(existing.since) <= AgentActivityReducer.reopenWindow
                    if source == .poll, recent { return }   // a stale poll must not resurrect a finished turn
                    if source == .stream, recent, outcome == .completed {
                        existing.state = .working
                        existing.since = now
                        existing.detail = nil
                        s.items[id] = existing
                        s.misses[id] = 0
                        return
                    }
                }
            }
            var item = baseItem(id: id, kind: .turn, state: .working, runtime: runtime)
            item.turnSeq = s.nextTurnSeq
            s.nextTurnSeq += 1
            item.isPollOnly = source == .poll && s.lastEventAt[runtime] == nil
            s.items[id] = item
            s.misses[id] = 0
            if announce { out.append(.turnStarted(item)) }
        }

        mutating func finish(_ runtime: String, outcome: AgentActivityItem.Outcome, preview: String?, observedGap: Bool = false) {
            let id = "turn:\(runtime)"
            guard var item = s.items[id], item.state == .working else { return }
            item.state = .finished(outcome)
            item.since = now
            item.detail = nil
            s.items[id] = item
            s.misses[id] = nil
            out.append(.turnFinished(item, outcome: outcome, replyPreview: preview, observedGap: observedGap))
        }

        static func preview(_ content: String?) -> String? {
            guard let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed.count <= AgentActivityReducer.previewLimit
                ? trimmed : String(trimmed.prefix(AgentActivityReducer.previewLimit))
        }

        // MARK: Decisions

        mutating func decision(
            id: String, kind: AgentActivityItem.Kind, runtime: String,
            detail: String?, approval: ApprovalActivity? = nil, questions: Int = 0
        ) -> AgentActivityItem {
            var item = baseItem(id: id, kind: kind, state: .needsUser, runtime: runtime)
            item.detail = detail
            item.approval = approval
            item.openQuestionCount = questions
            if let existing = s.items[id] {
                item.startedAt = existing.startedAt
                item.since = existing.since
                item.failure = existing.failure
            }
            return item
        }

        mutating func addDecision(_ item: AgentActivityItem, announce: Bool) {
            let isNew = s.items[item.id] == nil
            s.items[item.id] = item
            s.misses[item.id] = 0
            if isNew && announce { out.append(.decisionRequested(item)) }
        }

        mutating func resolve(_ id: String, _ reason: AgentActivityEvent.Reason) {
            guard s.items.removeValue(forKey: id) != nil else { return }
            s.misses[id] = nil
            out.append(.decisionResolved(id: id, reason: reason))
        }

        mutating func removeFallbacks(_ runtime: String) {
            resolve("approval:waiting:\(runtime)", .withdrawn)
            resolve("clarify:waiting:\(runtime)", .withdrawn)
        }

        func reason(forCancel raw: String?, requestId: String) -> AgentActivityEvent.Reason {
            switch raw?.lowercased() {
            case "resolved"?: return s.locallyAnswered.contains(requestId) ? .answeredHere : .answeredElsewhere
            case nil, "timeout"?: return .expired
            case "session_closed"?: return .sessionClosed
            default: return .withdrawn
            }
        }

        // MARK: Stream events

        mutating func stream(_ event: StreamEvent) {
            switch event {
            case .messageStart(let sid):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                s.items["turn:\(runtime)"]?.detail = nil

            case .messageDelta(let sid, _), .reasoningDelta(let sid, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)

            case .toolStart(let sid, let toolName, _, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                s.items["turn:\(runtime)"]?.detail = toolName

            case .toolComplete(let sid, let toolName, _, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                if s.items["turn:\(runtime)"]?.detail == toolName { s.items["turn:\(runtime)"]?.detail = nil }

            case .sessionBusy(let sid, let busy):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                if busy {
                    ensureWorkingTurn(runtime, source: .stream, announce: true)
                } else {
                    finish(runtime, outcome: .completed, preview: nil)
                }

            case .messageComplete(let sid, _, let content, _):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                finish(runtime, outcome: .completed, preview: Self.preview(content))

            case .messageError(let sid, let message):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                finish(runtime, outcome: .failed(message), preview: nil)

            case .messageInterrupted(let sid):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                finish(runtime, outcome: .interrupted, preview: nil)

            case .approval(let sid, let activity):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                removeFallbacks(runtime)
                s.waiting[runtime] = nil
                let id = activity.requestId.map { "approval:\($0)" } ?? "approval:legacy:\(runtime)"
                let detail = activity.description.isEmpty ? activity.command : activity.description
                addDecision(decision(id: id, kind: .approval, runtime: runtime, detail: detail, approval: activity), announce: true)

            case .approvalWithdrawn(let sid, let requestId, let raw):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                resolve("approval:\(requestId)", reason(forCancel: raw, requestId: requestId))

            case .clarify(let sid, let activity):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                let id = "clarify:\(activity.requestId)"
                if activity.isExpired { resolve(id, .expired); break }
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                removeFallbacks(runtime)
                s.waiting[runtime] = nil
                let open = activity.questions.filter(\.isAnswerable)
                let first = (open.first ?? activity.questions.first)?.question
                addDecision(decision(id: id, kind: .clarify, runtime: runtime, detail: first, questions: open.count), announce: true)

            case .clarifyExpire(let sid, let requestId, let raw):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                resolve("clarify:\(requestId)", reason(forCancel: raw, requestId: requestId))

            case .inputPrompt(let sid, let activity):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                ensureWorkingTurn(runtime, source: .stream, announce: true)
                removeFallbacks(runtime)
                s.waiting[runtime] = nil
                addDecision(decision(id: "inputPrompt:\(activity.requestId)", kind: .inputPrompt, runtime: runtime, detail: nil), announce: true)

            case .inputPromptExpire(let sid, let requestId, let raw):
                let runtime = runtimeID(for: sid)
                touch(runtime)
                resolve("inputPrompt:\(requestId)", reason(forCancel: raw, requestId: requestId))

            case .sessionTitle(let runtimeId, let stored, let title):
                ensureIdentity(runtimeId, stored: stored)
                let changed = s.titles[runtimeId] != title
                s.titles[runtimeId] = title
                if !stored.isEmpty { s.titles[stored] = title }
                for id in Array(s.items.keys) where s.items[id]?.sessionId == runtimeId { s.items[id]?.title = title }
                if changed { out.append(.titleChanged(sessionKey: sessionKey(runtimeId), title: title)) }

            default:
                break
            }
        }

        // MARK: Tick

        mutating func tick() {
            let finished = s.items.values.filter(\.isFinished).sorted { $0.since > $1.since }
            for (index, item) in finished.enumerated()
            where index >= AgentActivityReducer.maxFinished
                || now.timeIntervalSince(item.since) >= AgentActivityReducer.finishedLifetime {
                s.items[item.id] = nil
            }
            for item in Array(s.items.values) {
                switch item.state {
                case .needsUser:
                    if now.timeIntervalSince(item.since) >= AgentActivityReducer.decisionMaxAge { resolve(item.id, .expired) }
                case .working:
                    guard !s.pollAuthoritative else { continue }
                    let last = s.lastEventAt[item.sessionId ?? ""] ?? item.since
                    if now.timeIntervalSince(last) >= AgentActivityReducer.staleSilence { s.items[item.id] = nil }
                default:
                    break
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2.
Expected: all AgentActivityReducerStreamTests pass. Known trap: `case .messageDelta(let sid, _), .reasoningDelta(let sid, _):` needs both patterns to bind `sid` with the same type (both `String`).

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/AgentActivityReducer.swift' 'ConduitMacTests/AgentActivityHarness.swift' 'ConduitMacTests/AgentActivityReducerStreamTests.swift'
git commit -m "macOS: agent activity reducer, stream events and decisions (shared base)"
```

---

### Task 8: Reducer, part 2: poll, waiting sessions, catalog, baseline

**Files:**
- Modify: `ConduitMac/Activity/AgentActivityReducer.swift`
- Test: `ConduitMacTests/AgentActivityReducerPollTests.swift`

**Interfaces:**
- Consumes: Task 7 reducer; `LiveSessionStatus` (`runtimeSessionId`, `storedSessionId`, `status` in `working|waiting|starting|idle`, `isRunning`); `SessionSummary`.
- Produces: new `AgentActivityInput` cases `.activeList([LiveSessionStatus])`, `.activeListUnavailable`, `.fetchRequested(runtimeSessionId:)`, `.pendingApprovals(runtimeSessionId:_:)`, `.pendingApprovalsFailed(runtimeSessionId:)`, `.catalog([SessionSummary])`; `static func AgentActivityReducer.fetchTargets(_ state:) -> [String]`.

Rules (pinned by the tests):
- The first `.activeList` is a silent baseline: it creates what is running (working turns, waiting placeholders) without `turnStarted` or `decisionRequested`, and clears `baselinePending`.
- After the baseline a running row with no turn raises a poll-only turn and `turnStarted`.
- A working turn omitted from (or reported `idle` in) a poll gets a miss; the second consecutive miss finishes it `.completed` with no preview. A `starting` row is neutral. A stale poll never resurrects a turn that finished within 3 s.
- A `waiting` row with no decision content records `state.waiting[runtime]`; the feed fetches `approval.pending` for each unrequested one. A non-empty result becomes real approval items (announced unless the wait was found in the baseline); an empty result becomes `clarify:waiting:<runtime>`; a failure becomes `approval:waiting:<runtime>` with no approval content (a "needs approval, open in Conduit" row).
- A decision item whose session is no longer `waiting` gets a miss per poll; the second resolves it (`.withdrawn`, or `.sessionClosed` when the row is gone).
- `.activeListUnavailable` makes the poll non-authoritative (no miss logic) and ends the baseline.
- `.catalog` joins titles and aliases (`id`, `storedSessionId`, `lineageRootId`, `alternateIds`) so one session is one row however its id arrives.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/AgentActivityReducerPollTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class AgentActivityReducerPollTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    /// A harness that has already consumed its silent baseline.
    private func baselined(_ rows: [LiveSessionStatus] = []) -> AgentActivityHarness {
        var h = AgentActivityHarness()
        h.send(.activeList(rows))
        return h
    }

    func testBaselineIsSilentButFillsTheItems() {
        var h = AgentActivityHarness()
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]))
        XCTAssertNotNil(h.item("turn:rt1"))
        XCTAssertTrue(h.payloads.isEmpty, "what is already running at start is not news")
        XCTAssertFalse(h.state.baselinePending)
    }

    func testAPollOnlySessionAppearsAfterTheBaselineAndIsMarked() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        let item = h.item("turn:rt1")
        XCTAssertEqual(item?.isPollOnly, true)
        XCTAssertEqual(item?.sessionKey, "st1")
        XCTAssertEqual(h.turnStarts.count, 1)
    }

    func testStreamAndPollMergeIntoOneRow() {
        var h = baselined()
        h.stream(.messageStart(sessionId: "rt1"))
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        XCTAssertEqual(h.state.items.count, 1)
        XCTAssertEqual(h.item("turn:rt1")?.isPollOnly, false)
        XCTAssertEqual(h.turnStarts.count, 1)
    }

    func testOneFlakyPollDoesNotFinishATurnButTwoDo() {
        var h = baselined([Support.row("rt1", "working")])
        h.send(.activeList([]), at: 4)
        XCTAssertEqual(h.item("turn:rt1")?.state, .working, "one miss")
        h.send(.activeList([Support.row("rt1", "working")]), at: 8)
        h.send(.activeList([]), at: 12)
        XCTAssertEqual(h.item("turn:rt1")?.state, .working, "the streak was reset")
        h.send(.activeList([]), at: 16)
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed))
        XCTAssertEqual(h.turnFinishes.count, 1)
        XCTAssertNil(h.turnFinishes[0].preview)
        XCTAssertFalse(h.turnFinishes[0].gap)
    }

    func testIdleCountsAsAMissAndStartingIsNeutral() {
        var h = baselined([Support.row("rt1", "working"), Support.row("rt2", "working")])
        for step in 1...3 {
            h.send(.activeList([Support.row("rt1", "idle"), Support.row("rt2", "starting")]), at: TimeInterval(step * 4))
        }
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed))
        XCTAssertEqual(h.item("turn:rt2")?.state, .working)
    }

    func testAStalePollNeverResurrectsAJustFinishedTurn() {
        var h = baselined()
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.stream(.messageComplete(sessionId: "rt1", messageId: nil, content: "x", reasoning: nil), at: 5)
        h.send(.activeList([Support.row("rt1", "working")]), at: 6)
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed))
        XCTAssertEqual(h.turnStarts.count, 1)
    }

    // MARK: - Waiting sessions

    func testWaitingFetchesOnceThenRaisesRealApprovalsAnnounced() throws {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 4)
        XCTAssertEqual(AgentActivityReducer.fetchTargets(h.state), ["rt1"])
        XCTAssertTrue(h.requests.isEmpty, "no row until the content is known")
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        XCTAssertTrue(AgentActivityReducer.fetchTargets(h.state).isEmpty)
        h.send(.pendingApprovals(runtimeSessionId: "rt1", [Support.approval(session: "rt1", request: "q1")]), at: 5)
        let item = try XCTUnwrap(h.item("approval:q1"))
        XCTAssertEqual(item.approval?.command, "rm -rf build")
        XCTAssertEqual(h.requests.map(\.id), ["approval:q1"])
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 8)
        XCTAssertTrue(AgentActivityReducer.fetchTargets(h.state).isEmpty, "content is known: no second fetch")
        XCTAssertEqual(h.requests.count, 1)
    }

    func testFetchFailureBecomesANoButtonRow() throws {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovalsFailed(runtimeSessionId: "rt1"))
        let item = try XCTUnwrap(h.item("approval:waiting:rt1"))
        XCTAssertEqual(item.kind, .approval)
        XCTAssertNil(item.approval)
        XCTAssertEqual(h.requests.count, 1)
    }

    func testAnEmptyPendingListMeansAnAnswerInConduitRow() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovals(runtimeSessionId: "rt1", []))
        XCTAssertEqual(h.item("clarify:waiting:rt1")?.kind, .clarify)
        XCTAssertNil(h.item("clarify:waiting:rt1")?.approval)
    }

    func testAWaitingSessionFoundInTheBaselineShowsItsContentSilently() {
        var h = AgentActivityHarness()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        XCTAssertEqual(AgentActivityReducer.fetchTargets(h.state), ["rt1"])
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovals(runtimeSessionId: "rt1", [Support.approval(session: "rt1", request: "q1")]))
        XCTAssertNotNil(h.item("approval:q1"))
        XCTAssertTrue(h.requests.isEmpty, "snapshot() carries it; no decisionRequested for what was already pending")
    }

    func testALateFetchResultAfterTheSessionStoppedWaitingIsIgnored() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.activeList([Support.row("rt1", "working")]), at: 4)
        h.send(.pendingApprovals(runtimeSessionId: "rt1", [Support.approval(session: "rt1")]), at: 5)
        XCTAssertNil(h.item("approval:q1"))
    }

    func testAnEventCapturedApprovalNeedsNoFetch() {
        var h = baselined()
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")))
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 4)
        XCTAssertTrue(AgentActivityReducer.fetchTargets(h.state).isEmpty)
    }

    func testAStreamApprovalReplacesTheFallbackRow() {
        var h = baselined()
        h.send(.activeList([Support.row("rt1", "waiting")]))
        h.send(.fetchRequested(runtimeSessionId: "rt1"))
        h.send(.pendingApprovalsFailed(runtimeSessionId: "rt1"))
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")), at: 2)
        XCTAssertNil(h.item("approval:waiting:rt1"))
        XCTAssertNotNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.id), ["approval:waiting:rt1"])
    }

    func testADecisionWhoseSessionStoppedWaitingResolvesAfterTwoPolls() {
        var h = baselined()
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")))
        h.send(.activeList([Support.row("rt1", "working")]), at: 4)
        XCTAssertNotNil(h.item("approval:q1"), "one miss")
        h.send(.activeList([Support.row("rt1", "working")]), at: 8)
        XCTAssertNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.withdrawn])
    }

    func testADecisionWhoseSessionVanishedIsSessionClosed() {
        var h = baselined()
        h.stream(.approval(sessionId: "rt1", activity: Support.approval(session: "rt1")))
        h.send(.activeList([]), at: 4)
        h.send(.activeList([]), at: 8)
        XCTAssertEqual(h.resolutions.map(\.reason), [.sessionClosed])
    }

    // MARK: - Capability and staleness

    func testUnavailableListEndsTheBaselineAndSuspendsMissLogic() {
        var h = AgentActivityHarness()
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.send(.activeListUnavailable)
        XCTAssertFalse(h.state.baselinePending)
        XCTAssertFalse(h.state.pollAuthoritative)
        h.send(.tick, at: 300)
        XCTAssertEqual(h.item("turn:rt1")?.state, .working)
        h.send(.tick, at: 601)
        XCTAssertNil(h.item("turn:rt1"), "silent for ten minutes with no list to confirm it")
        XCTAssertTrue(h.turnFinishes.isEmpty, "dropped silently, not finished")
    }

    // MARK: - Identity and catalog

    func testIdsInAnyFormYieldOneRow() {
        var h = baselined()
        h.stream(.messageStart(sessionId: "rt1"))
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", alternates: ["old"], title: "Laravel")]), at: 5)
        h.stream(.messageDelta(sessionId: "old", text: "hi"), at: 6)
        XCTAssertEqual(h.state.items.count, 1)
        XCTAssertEqual(h.turnStarts.count, 1)
        XCTAssertEqual(h.item("turn:rt1")?.sessionKey, "cat1")
        XCTAssertEqual(h.item("turn:rt1")?.title, "Laravel")
    }

    func testCatalogTitleAppliesToLaterItemsToo() {
        var h = baselined()
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", title: "Laravel")]))
        h.send(.activeList([Support.row("rt1", stored: "st1", "working")]), at: 4)
        XCTAssertEqual(h.item("turn:rt1")?.title, "Laravel")
    }

    func testCatalogRenameUpdatesTheRow() {
        var h = baselined([Support.row("rt1", stored: "st1", "working")])
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", title: "One")]))
        h.send(.catalog([Support.summary(id: "cat1", stored: "st1", title: "Two")]))
        XCTAssertEqual(h.item("turn:rt1")?.title, "Two")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/AgentActivityReducerPollTests`
Expected: build failure, `type 'AgentActivityInput' has no member 'activeList'`.

- [ ] **Step 3: Implement**

In `AgentActivityReducer.swift`:

(a) Add the cases to `AgentActivityInput`, after `.tick`:

```swift
    case activeList([LiveSessionStatus])
    case activeListUnavailable
    case fetchRequested(runtimeSessionId: String)
    case pendingApprovals(runtimeSessionId: String, [ApprovalActivity])
    case pendingApprovalsFailed(runtimeSessionId: String)
    case catalog([SessionSummary])
```

(b) Add the static helper to `AgentActivityReducer`, after `reduce`:

```swift
    /// Runtime ids whose `approval.pending` the feed still has to fetch.
    static func fetchTargets(_ state: AgentActivityState) -> [String] {
        state.waiting.filter { !$0.value.requested }.map(\.key).sorted()
    }
```

(c) Add arms to `Engine.apply`, before `case .tick:`:

```swift
            case .activeList(let rows):
                activeList(rows)
            case .activeListUnavailable:
                s.pollAuthoritative = false
                s.baselinePending = false
            case .fetchRequested(let runtime):
                s.waiting[runtime]?.requested = true
            case .pendingApprovals(let runtime, let list):
                pendingApprovals(runtime, list)
            case .pendingApprovalsFailed(let runtime):
                fallbackDecision(runtime, kind: .approval)
            case .catalog(let sessions):
                catalog(sessions)
```

(d) Add these methods inside `Engine`, after `tick()`:

```swift
        // MARK: Poll

        mutating func activeList(_ rows: [LiveSessionStatus]) {
            let baseline = s.baselinePending
            s.baselinePending = false
            s.pollAuthoritative = true
            var byRuntime: [String: LiveSessionStatus] = [:]
            for row in rows {
                ensureIdentity(row.runtimeSessionId, stored: row.storedSessionId)
                byRuntime[row.runtimeSessionId] = row
            }

            for row in rows where row.isRunning {
                let runtime = row.runtimeSessionId
                ensureWorkingTurn(runtime, source: .poll, announce: !baseline)
                if row.status == "waiting" {
                    noteWaiting(runtime, silent: baseline)
                } else {
                    s.waiting[runtime] = nil
                }
            }
            for runtime in Array(s.waiting.keys) where byRuntime[runtime]?.status != "waiting" {
                s.waiting[runtime] = nil
            }

            for item in Array(s.items.values) where item.kind == .turn && item.state == .working {
                guard let runtime = item.sessionId else { continue }
                if let row = byRuntime[runtime] {
                    if row.isRunning { s.misses[item.id] = 0; continue }
                    if row.status == "starting" { continue }   // runtime present, liveness inconclusive
                }
                let misses = (s.misses[item.id] ?? 0) + 1
                s.misses[item.id] = misses
                if misses >= AgentActivityReducer.missesToFinish {
                    finish(runtime, outcome: .completed, preview: nil)
                }
            }

            for item in Array(s.items.values) where item.state == .needsUser {
                guard let runtime = item.sessionId else { continue }
                if byRuntime[runtime]?.status == "waiting" { s.misses[item.id] = 0; continue }
                let misses = (s.misses[item.id] ?? 0) + 1
                s.misses[item.id] = misses
                if misses >= AgentActivityReducer.missesToFinish {
                    resolve(item.id, byRuntime[runtime] == nil ? .sessionClosed : .withdrawn)
                }
            }
        }

        mutating func noteWaiting(_ runtime: String, silent: Bool) {
            let hasDecision = s.items.values.contains { $0.sessionId == runtime && $0.state == .needsUser }
            guard !hasDecision, s.waiting[runtime] == nil else { return }
            s.waiting[runtime] = .init(silent: silent)
        }

        mutating func pendingApprovals(_ runtime: String, _ list: [ApprovalActivity]) {
            guard let wait = s.waiting[runtime] else { return }
            if list.isEmpty {
                fallbackDecision(runtime, kind: .clarify)
                return
            }
            s.waiting[runtime] = nil
            for approval in list {
                let id = approval.requestId.map { "approval:\($0)" } ?? "approval:legacy:\(runtime)"
                let detail = approval.description.isEmpty ? approval.command : approval.description
                addDecision(decision(id: id, kind: .approval, runtime: runtime, detail: detail, approval: approval), announce: !wait.silent)
            }
        }

        /// A waiting session whose content could not be fetched (or is not an approval):
        /// a row with no buttons that says "open in Conduit".
        mutating func fallbackDecision(_ runtime: String, kind: AgentActivityItem.Kind) {
            guard let wait = s.waiting.removeValue(forKey: runtime) else { return }
            let prefix = kind == .approval ? "approval" : "clarify"
            addDecision(decision(id: "\(prefix):waiting:\(runtime)", kind: kind, runtime: runtime, detail: nil), announce: !wait.silent)
        }

        // MARK: Catalog

        mutating func catalog(_ sessions: [SessionSummary]) {
            for session in sessions {
                let ids = [session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 } + session.alternateIds
                for id in ids { s.titles[id] = session.title }
                for (runtime, var identity) in s.identities where ids.contains(where: { identity.matches($0) }) {
                    identity.alternateIds.formUnion(ids.filter { $0 != runtime })
                    identity.catalogId = session.id
                    if identity.lineageRootId == nil { identity.lineageRootId = session.lineageRootId }
                    s.identities[runtime] = identity
                }
            }
            for id in Array(s.items.keys) {
                guard let runtime = s.items[id]?.sessionId else { continue }
                let latest = title(runtime)
                if !latest.isEmpty, s.items[id]?.title != latest { s.items[id]?.title = latest }
                s.items[id]?.sessionKey = sessionKey(runtime)
            }
        }
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2, then `-only-testing:ConduitMacTests/AgentActivityReducerStreamTests` again (Task 7 must stay green).
Expected: all pass. Trap: in `catalog`, `for (runtime, var identity) in s.identities` iterates a copy while `s.identities[runtime]` is written; that is fine for a value-type dictionary.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/AgentActivityReducer.swift' 'ConduitMacTests/AgentActivityReducerPollTests.swift'
git commit -m "macOS: agent activity reducer, poll, waiting sessions and catalog (shared base)"
```

---

### Task 9: Sources, poll cadence and the poller

**Files:**
- Create: `ConduitMac/Activity/AgentActivitySources.swift`
- Create: `ConduitMacTests/AgentActivitySourcesTestSupport.swift`
- Test: `ConduitMacTests/AgentActivityPollerTests.swift`

**Interfaces:**
- Consumes: `LiveSessionStatus`, `ApprovalActivity`, `HermesClient.activeSessions()`, `.pendingApprovals(sessionId:)`, `.respondToApproval(sessionId:requestId:choice:profile:)`, `AppState.isConnected`, `.client`, `.messages`, `.respondToApproval(messageId:choice:)`, `AppState.isExpiredPromptError(_:)`, `RpcError`.
- Produces:
  - `@MainActor protocol AgentActivitySources: AnyObject { var isConnected: Bool { get }; func activeSessions() async throws -> [LiveSessionStatus]; func pendingApprovals(sessionId: String) async throws -> [ApprovalActivity]; func respondToApproval(sessionId: String, requestId: String?, choice: String) async throws -> Bool; func respondViaActiveCard(requestId: String, choice: String) async -> Bool?; func isMethodUnavailable(_ error: Error) -> Bool }`
  - `@MainActor final class AgentActivityLiveSources: AgentActivitySources { init(appState: AppState) }` (production)
  - `enum AgentActivityRpc { static func isMethodUnavailable(_:) -> Bool; static func isExpiredPrompt(_:) -> Bool }`
  - `enum AgentActivityPollCadence { static let live = 4.0; static let idle = 15.0; static func interval(isLive:panelVisible:) -> TimeInterval }`
  - `@MainActor final class AgentActivityPoller { typealias Sleep = @MainActor (TimeInterval) async throws -> Void; static let liveSleep; init(sources:sleep:); var isLive, isPanelVisible: () -> Bool; var onRows: ([LiveSessionStatus]) -> Void; var onUnavailable: () -> Void; var isRunning: Bool; func start(); func stop(); func resetCapability(); func pollNow() async }`
  - test doubles: `FakeActivitySources`, `ManualSleeper`, `waitForCondition`, `assertEventually`

Why this exists: `AppState.refreshLiveSessionStatuses()` returns early unless the scene is active and is driven by the sidebar, so it cannot feed a surface that must work while Conduit is in the background. The poller calls `client.activeSessions()` directly and is guarded by connection state only. No file under `ConduitMac/Activity/` may mention the scene state; a test enforces it.

- [ ] **Step 1: Write the test support and the failing tests**

`ConduitMacTests/AgentActivitySourcesTestSupport.swift`:

```swift
import XCTest
@testable import ConduitMac

/// Polls without blocking the main actor: a suspension lets main-actor tasks and
/// Combine hops run, which a run-loop spin inside an async test does not.
@MainActor
func waitForCondition(timeout: TimeInterval = 5, _ predicate: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

@MainActor
func assertEventually(
    _ message: String = "condition not reached", timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line,
    _ predicate: @MainActor () -> Bool
) async {
    let reached = await waitForCondition(timeout: timeout, predicate)
    XCTAssertTrue(reached, message, file: file, line: line)
}

/// A sleeper the test advances by hand: `sleep` records the request and parks
/// until `fire()`. No wall-clock time passes.
@MainActor
final class ManualSleeper {
    private(set) var requested: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []
    var pending: Int { waiters.count }

    func sleep(_ seconds: TimeInterval) async throws {
        requested.append(seconds)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func fire() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    /// Releases every parked sleeper (call from tearDown so no task is left hanging).
    func cancelAll() {
        let all = waiters
        waiters = []
        all.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class FakeActivitySources: AgentActivitySources {
    var isConnected = true
    var rows: [LiveSessionStatus] = []
    var activeError: Error?
    var pendingResults: [String: Result<[ApprovalActivity], Error>] = [:]
    var respondResult: Result<Bool, Error> = .success(true)
    /// nil: no open card for the request.
    var cardResult: Bool?
    var holdResponses = false

    private(set) var activeCalls = 0
    private(set) var pendingCalls: [String] = []
    private(set) var responses: [(session: String, request: String?, choice: String)] = []
    private(set) var cardResponses: [(request: String, choice: String)] = []
    private var gate: CheckedContinuation<Void, Never>?

    func activeSessions() async throws -> [LiveSessionStatus] {
        activeCalls += 1
        if let activeError { throw activeError }
        return rows
    }

    func pendingApprovals(sessionId: String) async throws -> [ApprovalActivity] {
        pendingCalls.append(sessionId)
        switch pendingResults[sessionId] {
        case .success(let list)?: return list
        case .failure(let error)?: throw error
        case nil: return []
        }
    }

    func respondToApproval(sessionId: String, requestId: String?, choice: String) async throws -> Bool {
        responses.append((sessionId, requestId, choice))
        if holdResponses { await withCheckedContinuation { gate = $0 } }
        return try respondResult.get()
    }

    func releaseResponses() {
        holdResponses = false
        gate?.resume()
        gate = nil
    }

    func respondViaActiveCard(requestId: String, choice: String) async -> Bool? {
        cardResponses.append((requestId, choice))
        return cardResult
    }

    func isMethodUnavailable(_ error: Error) -> Bool { AgentActivityRpc.isMethodUnavailable(error) }
}
```

`ConduitMacTests/AgentActivityPollerTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class AgentActivityPollerTests: XCTestCase {
    private var sources: FakeActivitySources!
    private var sleeper: ManualSleeper!
    private var poller: AgentActivityPoller!
    private var delivered: [[LiveSessionStatus]] = []
    private var unavailableCalls = 0
    private var live = false
    private var panelVisible = false

    override func setUp() async throws {
        sources = FakeActivitySources()
        sleeper = ManualSleeper()
        delivered = []
        unavailableCalls = 0
        live = false
        panelVisible = false
        poller = AgentActivityPoller(sources: sources, sleep: sleeper.sleep)
        poller.isLive = { [unowned self] in self.live }
        poller.isPanelVisible = { [unowned self] in self.panelVisible }
        poller.onRows = { [unowned self] in self.delivered.append($0) }
        poller.onUnavailable = { [unowned self] in self.unavailableCalls += 1 }
    }

    override func tearDown() async throws {
        poller.stop()
        sleeper.cancelAll()
        poller = nil
    }

    func testCadenceTable() {
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: true, panelVisible: false), 4)
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: false, panelVisible: true), 4)
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: true, panelVisible: true), 4)
        XCTAssertEqual(AgentActivityPollCadence.interval(isLive: false, panelVisible: false), 15)
    }

    func testFirstPollRunsAtOnceAndDeliversRows() async {
        sources.rows = [AgentActivityTestSupport.row("rt1", "working")]
        poller.start()
        await assertEventually { self.delivered.count == 1 }
        XCTAssertEqual(delivered[0].map(\.runtimeSessionId), ["rt1"])
    }

    func testTheLoopSleepsForTheCadenceItIsGiven() async {
        poller.start()
        await assertEventually { self.sleeper.requested == [15] }
        live = true
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [15, 4] }
        live = false
        panelVisible = true
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [15, 4, 4] }
        panelVisible = false
        sleeper.fire()
        await assertEventually { self.sleeper.requested == [15, 4, 4, 15] }
    }

    func testNoPollWhileDisconnected() async {
        sources.isConnected = false
        poller.start()
        await assertEventually { self.sleeper.requested.count == 1 }
        XCTAssertEqual(sources.activeCalls, 0)
    }

    func testMethodUnavailableStopsAskingUntilTheCapabilityIsReset() async {
        sources.activeError = RpcError(code: -32601, message: "Method not found")
        poller.start()
        await assertEventually { self.unavailableCalls == 1 }
        await assertEventually { self.sleeper.pending == 1 }
        sleeper.fire()
        await assertEventually { self.sleeper.requested.count == 2 }
        XCTAssertEqual(sources.activeCalls, 1, "no retry loop against a client without the method")
        sources.activeError = nil
        poller.resetCapability()
        sleeper.fire()
        await assertEventually { self.delivered.count == 1 }
        XCTAssertEqual(sources.activeCalls, 2)
    }

    func testOtherErrorsRetryOnTheNextTick() async {
        sources.activeError = RpcError(code: 500, message: "boom")
        poller.start()
        await assertEventually { self.sources.activeCalls == 1 }
        await assertEventually { self.sleeper.pending == 1 }
        XCTAssertEqual(unavailableCalls, 0)
        sleeper.fire()
        await assertEventually { self.sources.activeCalls == 2 }
    }

    func testStartIsIdempotentAndStopEndsTheLoop() async {
        poller.start()
        poller.start()
        await assertEventually { self.sleeper.requested.count == 1 }
        XCTAssertEqual(sources.activeCalls, 1, "one loop, not two")
        XCTAssertTrue(poller.isRunning)
        poller.stop()
        XCTAssertFalse(poller.isRunning)
        sleeper.cancelAll()
        HostedTestSupport.settle(0.05)
        XCTAssertEqual(sources.activeCalls, 1)
    }

    func testMethodUnavailableClassification() {
        XCTAssertTrue(AgentActivityRpc.isMethodUnavailable(RpcError(code: -32601, message: "x")))
        XCTAssertTrue(AgentActivityRpc.isMethodUnavailable(RpcError(code: 1, message: "Method not found")))
        XCTAssertTrue(AgentActivityRpc.isMethodUnavailable(RpcError(code: 1, message: "unknown method session.active_list")))
        XCTAssertFalse(AgentActivityRpc.isMethodUnavailable(RpcError(code: 4009, message: "no pending approval")))
        XCTAssertFalse(AgentActivityRpc.isMethodUnavailable(CancellationError()))
    }

    // MARK: - Independent of the scene

    func testLiveSourcesReportConnectedWhileTheSceneIsInactive() {
        let fixture = MacSharedBaseAppStateFixture()
        defer { fixture.tearDown() }
        let appState = fixture.appState
        let connection = HermesConnection(baseUrl: "https://example.com", ticket: "t")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        _ = appState.handleScenePhase(.background)
        XCTAssertFalse(appState.isSceneActive)
        XCTAssertTrue(AgentActivityLiveSources(appState: appState).isConnected,
                      "the poll must not depend on the app being frontmost")
    }

    func testNoActivityFileConsultsTheSceneState() throws {
        let activity = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConduitMac/Activity", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: activity, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("isSceneActive"), file.lastPathComponent)
            XCTAssertFalse(text.contains("scenePhase"), file.lastPathComponent)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/AgentActivityPollerTests`
Expected: build failure, `cannot find type 'AgentActivitySources' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Activity/AgentActivitySources.swift`:

```swift
import Foundation

/// Everything the feed needs from the gateway, behind a protocol so tests inject a fake.
@MainActor
protocol AgentActivitySources: AnyObject {
    /// A client exists and the socket is up. Nothing else gates the poll.
    var isConnected: Bool { get }
    func activeSessions() async throws -> [LiveSessionStatus]
    func pendingApprovals(sessionId: String) async throws -> [ApprovalActivity]
    /// `approval.respond`. True when the gateway resolved at least one queue entry.
    func respondToApproval(sessionId: String, requestId: String?, choice: String) async throws -> Bool
    /// Answers through the open chat's approval card so its state stays coherent.
    /// nil when no pending card matches `requestId`; false when the card ended in error.
    func respondViaActiveCard(requestId: String, choice: String) async -> Bool?
    func isMethodUnavailable(_ error: Error) -> Bool
}

enum AgentActivityRpc {
    /// Same rule as the private `AppState.isMethodUnavailable`.
    static func isMethodUnavailable(_ error: Error) -> Bool {
        guard let rpc = error as? RpcError else { return false }
        let message = rpc.message.lowercased()
        return rpc.code == -32601 || message.contains("method not found") || message.contains("unknown method")
    }

    /// 4009 / "no pending": the decision is no longer active.
    @MainActor
    static func isExpiredPrompt(_ error: Error) -> Bool {
        AppState.isExpiredPromptError(error)
    }
}

enum AgentActivityPollCadence {
    static let live: TimeInterval = 4
    static let idle: TimeInterval = 15

    /// 4 s while anything is live or a surface is showing; 15 s when idle.
    static func interval(isLive: Bool, panelVisible: Bool) -> TimeInterval {
        isLive || panelVisible ? live : idle
    }
}

/// Production sources over the app's `HermesClient`.
@MainActor
final class AgentActivityLiveSources: AgentActivitySources {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var isConnected: Bool { appState.isConnected && appState.client != nil }

    func activeSessions() async throws -> [LiveSessionStatus] {
        guard let client = appState.client else { throw HermesError.notConnected }
        return try await client.activeSessions()
    }

    func pendingApprovals(sessionId: String) async throws -> [ApprovalActivity] {
        guard let client = appState.client else { throw HermesError.notConnected }
        return try await client.pendingApprovals(sessionId: sessionId)
    }

    func respondToApproval(sessionId: String, requestId: String?, choice: String) async throws -> Bool {
        guard let client = appState.client else { throw HermesError.notConnected }
        return try await client.respondToApproval(sessionId: sessionId, requestId: requestId, choice: choice, profile: nil)
    }

    func respondViaActiveCard(requestId: String, choice: String) async -> Bool? {
        guard let message = appState.messages.first(where: {
            $0.approval?.requestId == requestId && ($0.approval?.status == .pending || $0.approval?.status == .error)
        }) else { return nil }
        await appState.respondToApproval(messageId: message.id, choice: choice)
        return appState.messages.first { $0.id == message.id }?.approval?.status != .error
    }

    func isMethodUnavailable(_ error: Error) -> Bool { AgentActivityRpc.isMethodUnavailable(error) }
}

/// Polls `session.active_list` on its own clock. Not tied to the sidebar and not
/// tied to whether Conduit is frontmost: only to the connection.
@MainActor
final class AgentActivityPoller {
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void

    static let liveSleep: Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    var isLive: () -> Bool = { false }
    var isPanelVisible: () -> Bool = { false }
    var onRows: ([LiveSessionStatus]) -> Void = { _ in }
    var onUnavailable: () -> Void = {}

    private let sources: AgentActivitySources
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var unavailable = false

    init(sources: AgentActivitySources, sleep: @escaping Sleep = AgentActivityPoller.liveSleep) {
        self.sources = sources
        self.sleep = sleep
    }

    var isRunning: Bool { task != nil }

    /// Polls at once, then every `AgentActivityPollCadence.interval`. Idempotent.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollNow()
                let interval = AgentActivityPollCadence.interval(isLive: self.isLive(), panelVisible: self.isPanelVisible())
                do { try await self.sleep(interval) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// A new connection probes for `session.active_list` again.
    func resetCapability() {
        unavailable = false
    }

    func pollNow() async {
        guard sources.isConnected, !unavailable else { return }
        do {
            let rows = try await sources.activeSessions()
            guard !Task.isCancelled else { return }
            onRows(rows)
        } catch is CancellationError {
            return
        } catch {
            // Stop asking a gateway that lacks the method; other failures retry next tick.
            if sources.isMethodUnavailable(error) {
                unavailable = true
                onUnavailable()
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2.
Expected: all AgentActivityPollerTests pass. `HermesError.notConnected` is the case at `HermesClient.swift` (about line 2755); if the enum is named differently, match the file.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/AgentActivitySources.swift' 'ConduitMacTests/AgentActivitySourcesTestSupport.swift' 'ConduitMacTests/AgentActivityPollerTests.swift'
git commit -m "macOS: agent activity sources, cadence and scene-independent poller (shared base)"
```

---

### Task 10: AgentActivityFeed shell

**Files:**
- Create: `ConduitMac/Activity/AgentActivityFeed.swift`
- Test: `ConduitMacTests/AgentActivityFeedTests.swift`

**Interfaces:**
- Consumes: reducer (Tasks 7, 8), poller and sources (Task 9), hub (Task 4), models (Task 6).
- Produces `@MainActor final class AgentActivityFeed: ObservableObject`:
  - `static var shared: AgentActivityFeed?` (set by the bootstrap, Task 14)
  - `@Published private(set) var items: [AgentActivityItem]` (ordered: needs-user, working, finished)
  - `@Published private(set) var availability: AgentActivityAvailability`
  - `@Published private(set) var isBaselined: Bool`
  - `let events: AnyPublisher<AgentActivityEvent, Never>`
  - `init(sources:hub:clock:pollSleep:tickSleep:)` (all but `sources` defaulted)
  - `func start()`, `func stop()` (idempotent), `func observe(_ event: StreamEvent)`, `func snapshot() -> [AgentActivityItem]`, `func dismiss(_ id: String)`
  - `func setActiveSession(_ id: String?)`, `func setCatalog(_ sessions: [SessionSummary])`, `func setScope(profile: String, dashboardID: String)`, `func setPanelVisible(_ visible: Bool)`, `func refreshNow()`

Contract: `items` is updated before the matching event is sent (a handler can read the new state); `eventId` starts at 1 and increases by 1 per event; events are ordered; the feed runs whether or not any UI is shown; `stop()` unsubscribes from the hub, stops the poller, ticker and fetches, and clears the rows silently. The first poll is the baseline (silent); `isBaselined` turns true once it and its `approval.pending` fetches finished, so a consumer calls `snapshot()` after that.

- [ ] **Step 1: Write the failing tests**

```swift
import Combine
import XCTest
@testable import ConduitMac

@MainActor
final class AgentActivityFeedTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private var sources: FakeActivitySources!
    private var hub: MacStreamEventHub!
    private var pollSleeper: ManualSleeper!
    private var tickSleeper: ManualSleeper!
    private var feed: AgentActivityFeed!
    private var now = AgentActivityTestSupport.origin
    private var received: [AgentActivityEvent] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        sources = FakeActivitySources()
        hub = MacStreamEventHub()
        pollSleeper = ManualSleeper()
        tickSleeper = ManualSleeper()
        now = Support.origin
        received = []
        cancellables = []
        feed = AgentActivityFeed(
            sources: sources, hub: hub, clock: { [unowned self] in self.now },
            pollSleep: pollSleeper.sleep, tickSleep: tickSleeper.sleep)
        feed.events.sink { [unowned self] in self.received.append($0) }.store(in: &cancellables)
    }

    override func tearDown() async throws {
        feed.stop()
        pollSleeper.cancelAll()
        tickSleeper.cancelAll()
        cancellables = []
        feed = nil
    }

    /// Hub-driven tests do not need the poller to run.
    private func startOffline() {
        sources.isConnected = false
        feed.start()
    }

    private func finish(_ session: String) {
        hub.publish(.messageComplete(sessionId: session, messageId: nil, content: "done", reasoning: nil))
    }

    // MARK: - Events and items

    func testHubEventsBuildItemsAndEvents() {
        startOffline()
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.map(\.id), ["turn:s1"])
        XCTAssertEqual(received.count, 1)
        guard case .turnStarted(let item) = received[0].payload else { return XCTFail("expected turnStarted") }
        XCTAssertEqual(item.id, "turn:s1")
    }

    func testItemsAreUpdatedBeforeTheMatchingEventIsSent() {
        startOffline()
        var countAtEvent: [Int] = []
        feed.events.sink { [unowned self] _ in countAtEvent.append(self.feed.items.count) }.store(in: &cancellables)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(countAtEvent, [1])
    }

    func testEventIdsStartAtOneAndIncreaseByOne() {
        startOffline()
        hub.publish(.messageStart(sessionId: "s1"))
        finish("s1")
        XCTAssertEqual(received.map(\.eventId), [1, 2])
    }

    func testEventTimestampsComeFromTheClock() {
        startOffline()
        now = Support.origin.addingTimeInterval(42)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(received[0].at, Support.origin.addingTimeInterval(42))
    }

    func testSnapshotHoldsPendingWorkAndNotFinishedRows() {
        startOffline()
        hub.publish(.messageStart(sessionId: "a"))
        hub.publish(.messageStart(sessionId: "b"))
        finish("b")
        XCTAssertEqual(feed.snapshot().map(\.id), ["turn:a"])
        XCTAssertEqual(feed.items.count, 2)
    }

    func testDismissRemovesAFinishedRowOnly() {
        startOffline()
        hub.publish(.messageStart(sessionId: "a"))
        hub.publish(.messageStart(sessionId: "b"))
        finish("b")
        feed.dismiss("turn:a")
        feed.dismiss("turn:b")
        XCTAssertEqual(feed.items.map(\.id), ["turn:a"])
    }

    func testActiveSessionFlagAndCatalogTitleFlowIntoItems() {
        startOffline()
        feed.setActiveSession("s1")
        feed.setCatalog([Support.summary(id: "s1", title: "Laravel")])
        hub.publish(.messageStart(sessionId: "s1"))
        hub.publish(.messageStart(sessionId: "s2"))
        XCTAssertEqual(feed.items.first { $0.id == "turn:s1" }?.isActiveSession, true)
        XCTAssertEqual(feed.items.first { $0.id == "turn:s1" }?.title, "Laravel")
        XCTAssertEqual(feed.items.first { $0.id == "turn:s2" }?.isActiveSession, false)
    }

    func testScopeChangeResetsSilentlyAndKeepsTheCatalog() {
        startOffline()
        feed.setCatalog([Support.summary(id: "s1", title: "Laravel")])
        hub.publish(.messageStart(sessionId: "s1"))
        let before = received.count
        feed.setScope(profile: "work", dashboardID: "d1")
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertEqual(received.count, before)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.first?.title, "Laravel")
        XCTAssertEqual(feed.items.first?.profile, "work")
    }

    // MARK: - Lifecycle

    func testStartAndStopAreIdempotentAndStopUnsubscribesAndClears() {
        startOffline()
        feed.start()
        XCTAssertEqual(hub.subscriberCount, 1)
        hub.publish(.messageStart(sessionId: "s1"))
        feed.stop()
        feed.stop()
        XCTAssertEqual(hub.subscriberCount, 0)
        XCTAssertTrue(feed.items.isEmpty)
        let before = received.count
        hub.publish(.messageStart(sessionId: "s2"))
        feed.observe(.messageStart(sessionId: "s3"))
        XCTAssertEqual(received.count, before, "a stopped feed ignores events")
        XCTAssertEqual(feed.availability, .offline)
    }

    func testAvailabilityIsLiveWhenStartedAndConnected() {
        feed.start()
        XCTAssertEqual(feed.availability, .live)
    }

    // MARK: - Poll

    func testPollOnlySessionsAppearAfterTheSilentBaseline() async {
        feed.start()
        await assertEventually { self.feed.isBaselined }
        XCTAssertTrue(received.isEmpty)
        sources.rows = [Support.row("rt1", stored: "st1", "working")]
        pollSleeper.fire()
        await assertEventually { self.feed.items.map(\.id) == ["turn:rt1"] }
        XCTAssertEqual(feed.items.first?.isPollOnly, true)
        guard case .turnStarted = received.last?.payload else { return XCTFail("expected turnStarted") }
    }

    func testRunningRowsFoundInTheBaselineDoNotAnnounce() async {
        sources.rows = [Support.row("rt1", "working")]
        feed.start()
        await assertEventually { self.feed.items.map(\.id) == ["turn:rt1"] }
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(feed.snapshot().map(\.id), ["turn:rt1"])
    }

    func testIsBaselinedIsFalseBeforeTheFirstPoll() async {
        XCTAssertFalse(feed.isBaselined)
        feed.start()
        await assertEventually { self.feed.isBaselined }
    }

    func testAWaitingRowFetchesPendingApprovalsOnceAndRaisesTheDecision() async {
        feed.start()
        await assertEventually { self.feed.isBaselined }
        sources.rows = [Support.row("rt1", "waiting")]
        sources.pendingResults["rt1"] = .success([Support.approval(session: "rt1", request: "q1")])
        pollSleeper.fire()
        await assertEventually { self.feed.items.contains { $0.id == "approval:q1" } }
        XCTAssertEqual(sources.pendingCalls, ["rt1"])
        XCTAssertTrue(received.contains {
            if case .decisionRequested(let item) = $0.payload { return item.id == "approval:q1" }
            return false
        })
        pollSleeper.fire()
        await assertEventually { self.sources.activeCalls == 3 }
        XCTAssertEqual(sources.pendingCalls, ["rt1"], "content is known: no second fetch")
    }

    func testAFailedPendingFetchLeavesANoButtonRow() async {
        feed.start()
        await assertEventually { self.feed.isBaselined }
        sources.rows = [Support.row("rt1", "waiting")]
        sources.pendingResults["rt1"] = .failure(RpcError(code: 500, message: "boom"))
        pollSleeper.fire()
        await assertEventually { self.feed.items.contains { $0.id == "approval:waiting:rt1" } }
        XCTAssertNil(feed.items.first { $0.id == "approval:waiting:rt1" }?.approval)
    }

    func testAnUnsupportedListMeansEventsOnly() async {
        sources.activeError = RpcError(code: -32601, message: "Method not found")
        feed.start()
        await assertEventually { self.feed.availability == .eventsOnly }
        XCTAssertTrue(feed.isBaselined)
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.map(\.id), ["turn:s1"], "the tap still serves sessions on this socket")
    }

    func testPanelVisibilityAndLiveWorkShortenTheIdleInterval() async {
        feed.start()
        await assertEventually { self.pollSleeper.requested == [15] }
        feed.setPanelVisible(true)
        pollSleeper.fire()
        await assertEventually { self.pollSleeper.requested == [15, 4] }
        feed.setPanelVisible(false)
        hub.publish(.messageStart(sessionId: "s1"))
        pollSleeper.fire()
        await assertEventually { self.pollSleeper.requested == [15, 4, 4] }
    }

    // MARK: - Ticker

    func testTheTickerDropsFinishedRowsAfterThirtySeconds() async {
        startOffline()
        hub.publish(.messageStart(sessionId: "s1"))
        finish("s1")
        await assertEventually { self.tickSleeper.pending == 1 }
        now = Support.origin.addingTimeInterval(31)
        tickSleeper.fire()
        await assertEventually { self.feed.items.isEmpty }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/AgentActivityFeedTests`
Expected: build failure, `cannot find 'AgentActivityFeed' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Activity/AgentActivityFeed.swift`:

```swift
import Combine
import Foundation

/// What the agent is doing, for any Mac surface: the notch status, notifications,
/// and whatever comes next. Driven by the stream hub (every session on this
/// socket) plus its own `session.active_list` poll. Read-mostly: it never writes
/// AppState; the one write path is approval response (`respond`).
@MainActor
final class AgentActivityFeed: ObservableObject {
    /// Set by `MacActivityBootstrap`.
    static var shared: AgentActivityFeed?

    @Published private(set) var items: [AgentActivityItem] = []
    @Published private(set) var availability: AgentActivityAvailability = .offline
    /// True once the first poll and its approval fetches finished; call `snapshot()` after it.
    @Published private(set) var isBaselined = false
    let events: AnyPublisher<AgentActivityEvent, Never>

    private let subject: PassthroughSubject<AgentActivityEvent, Never>
    let sources: AgentActivitySources
    private let hub: MacStreamEventHub
    private let clock: () -> Date
    private let tickSleep: AgentActivityPoller.Sleep
    let poller: AgentActivityPoller

    private(set) var state = AgentActivityState()
    private var nextEventId: UInt64 = 1
    private var started = false
    private var hubToken: MacStreamEventHub.Token?
    private var fetchTasks: [String: Task<Void, Never>] = [:]
    private var tickTask: Task<Void, Never>?
    private var panelVisible = false
    private var activeListUnsupported = false
    private var catalog: [SessionSummary] = []
    private var activeSessionId: String?

    init(
        sources: AgentActivitySources,
        hub: MacStreamEventHub? = nil,
        clock: @escaping () -> Date = Date.init,
        pollSleep: @escaping AgentActivityPoller.Sleep = AgentActivityPoller.liveSleep,
        tickSleep: @escaping AgentActivityPoller.Sleep = AgentActivityPoller.liveSleep
    ) {
        let subject = PassthroughSubject<AgentActivityEvent, Never>()
        self.subject = subject
        self.events = subject.eraseToAnyPublisher()
        self.sources = sources
        self.hub = hub ?? .shared
        self.clock = clock
        self.tickSleep = tickSleep
        self.poller = AgentActivityPoller(sources: sources, sleep: pollSleep)
        poller.isLive = { [weak self] in self?.hasLiveWork ?? false }
        poller.isPanelVisible = { [weak self] in self?.panelVisible ?? false }
        poller.onRows = { [weak self] rows in self?.apply(.activeList(rows)) }
        poller.onUnavailable = { [weak self] in
            guard let self else { return }
            self.activeListUnsupported = true
            self.apply(.activeListUnavailable)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        hubToken = hub.subscribe { [weak self] event in self?.observe(event) }
        updateAvailability()
        poller.start()
    }

    func stop() {
        guard started else { return }
        started = false
        if let hubToken { hub.unsubscribe(hubToken) }
        hubToken = nil
        poller.stop()
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks = [:]
        tickTask?.cancel()
        tickTask = nil
        apply(.reset(profile: state.scope.profile, dashboardID: state.scope.dashboardID))
        updateAvailability()
    }

    // MARK: - Input

    /// Called for every stream event (via the hub). Ignored while stopped.
    func observe(_ event: StreamEvent) {
        guard started else { return }
        apply(.stream(event))
    }

    func setActiveSession(_ id: String?) {
        activeSessionId = id
        apply(.activeSession(id: id))
    }

    func setCatalog(_ sessions: [SessionSummary]) {
        catalog = sessions
        apply(.catalog(sessions))
    }

    /// A profile or dashboard switch: reset silently and take a new baseline.
    func setScope(profile: String, dashboardID: String) {
        guard state.scope != AgentActivityState.Scope(profile: profile, dashboardID: dashboardID) else { return }
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks = [:]
        apply(.reset(profile: profile, dashboardID: dashboardID))
        apply(.activeSession(id: activeSessionId))
        apply(.catalog(catalog))
        poller.resetCapability()
        activeListUnsupported = false
        refreshNow()
    }

    /// A visible surface shortens the idle poll interval and asks for a fresh poll.
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshNow() }
    }

    func refreshNow() {
        guard started else { return }
        Task { await poller.pollNow() }
    }

    func snapshot() -> [AgentActivityItem] {
        items.filter { !$0.isFinished }
    }

    /// Finished rows only.
    func dismiss(_ id: String) {
        apply(.dismiss(itemId: id))
    }

    // MARK: - Core

    private var hasLiveWork: Bool { items.contains { !$0.isFinished } }
    private var needsTick: Bool { !state.items.isEmpty }

    func apply(_ input: AgentActivityInput) {
        let output = AgentActivityReducer.reduce(state, input, now: clock())
        state = output.state
        let ordered = AgentActivityItem.ordered(Array(state.items.values))
        if ordered != items { items = ordered }
        let baselined = !state.baselinePending && state.waiting.isEmpty
        if baselined != isBaselined { isBaselined = baselined }
        updateAvailability()
        for payload in output.payloads {
            subject.send(AgentActivityEvent(eventId: nextEventId, at: clock(), payload: payload))
            nextEventId += 1
        }
        startFetches()
        updateTicker()
    }

    func updateAvailability() {
        let next: AgentActivityAvailability
        if !started || !sources.isConnected {
            next = .offline
        } else {
            next = activeListUnsupported ? .eventsOnly : .live
        }
        if next != availability { availability = next }
    }

    /// One `approval.pending` per waiting session whose content is unknown.
    private func startFetches() {
        let targets = AgentActivityReducer.fetchTargets(state)
        guard !targets.isEmpty else { return }
        // Mark every target first, straight through the reducer (no events, no recursion).
        for runtime in targets {
            state = AgentActivityReducer.reduce(state, .fetchRequested(runtimeSessionId: runtime), now: clock()).state
        }
        for runtime in targets {
            fetchTasks[runtime] = Task { [weak self] in
                guard let self else { return }
                do {
                    let list = try await self.sources.pendingApprovals(sessionId: runtime)
                    guard !Task.isCancelled else { return }
                    self.apply(.pendingApprovals(runtimeSessionId: runtime, list))
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.apply(.pendingApprovalsFailed(runtimeSessionId: runtime))
                }
                self.fetchTasks[runtime] = nil
            }
        }
    }

    private func updateTicker() {
        guard started, needsTick, tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let tickSleep = self?.tickSleep else { return }
                do { try await tickSleep(1) } catch { return }
                guard let self else { return }
                self.apply(.tick)
                if !self.needsTick {
                    self.tickTask = nil
                    return
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2, then `-only-testing:ConduitMacTests/AgentActivityReducerStreamTests -only-testing:ConduitMacTests/AgentActivityReducerPollTests -only-testing:ConduitMacTests/AgentActivityPollerTests` (all earlier activity tests stay green).
Expected: all pass. If a test is flaky on ordering, the cause is a missing `await assertEventually` before a `fire()`: always wait for `pending == 1` (or the expected `requested` list) before firing a sleeper.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/AgentActivityFeed.swift' 'ConduitMacTests/AgentActivityFeedTests.swift'
git commit -m "macOS: AgentActivityFeed shell over hub, poller and reducer (shared base)"
```

---

### Task 11: Approval responses driven by the request's choices

**Files:**
- Modify: `ConduitMac/Activity/AgentActivityFeed.swift`
- Test: `ConduitMacTests/AgentActivityApprovalTests.swift`

**Interfaces:**
- Consumes: `AgentActivityApprovalChoices` (Task 6), `AgentActivitySources.respondToApproval` / `respondViaActiveCard` (Task 9), reducer inputs `.respondStarted`, `.respondFailed`, `.respondResolved` (Task 7), `UserFacingError.message(for:)`.
- Produces:
  - `func respond(to id: String, choice: String) async -> AgentActivityRespondResult` on the feed
  - `enum AgentActivityRespondFailure { static let notAnswerable, choiceNotOffered, notConnected, inFlight, sendFailed: String }`: stable English codes carried in `.failed(_)` for refusals made before or without an RPC. They are not user-facing; the consumer shows its own localized text for them. A transport error carries `UserFacingError.message(for:)` instead.

Rules (pinned by the tests): only a `kind == .approval` row with approval content and a request id can be answered; the choice must be in `AgentActivityApprovalChoices.allowed(for:)` (refused with `choiceNotOffered` before any state change or RPC); a disconnected feed refuses with `notConnected`; one response per item at a time (`inFlight`); the active session's approval goes through the open card when one exists (so the card does not show a stale pending state), else through `HermesClient.respondToApproval`; `resolved == true` removes the row as `answeredHere`, `false` or a 4009/"no pending" error removes it as `answeredElsewhere` and returns `.alreadyResolved`; any other error keeps the row, records `failure`, and allows a retry. The gateway's own `request.cancel(resolved)` afterwards finds nothing and emits nothing.

- [ ] **Step 1: Write the failing tests**

```swift
import Combine
import XCTest
@testable import ConduitMac

@MainActor
final class AgentActivityApprovalTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private var sources: FakeActivitySources!
    private var hub: MacStreamEventHub!
    private var feed: AgentActivityFeed!
    private var pollSleeper: ManualSleeper!
    private var tickSleeper: ManualSleeper!
    private var received: [AgentActivityEvent] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        sources = FakeActivitySources()
        sources.isConnected = true
        hub = MacStreamEventHub()
        pollSleeper = ManualSleeper()
        tickSleeper = ManualSleeper()
        received = []
        feed = AgentActivityFeed(sources: sources, hub: hub, pollSleep: pollSleeper.sleep, tickSleep: tickSleeper.sleep)
        feed.events.sink { [unowned self] in self.received.append($0) }.store(in: &cancellables)
        feed.start()
        await assertEventually { self.feed.isBaselined }
    }

    override func tearDown() async throws {
        feed.stop()
        pollSleeper.cancelAll()
        tickSleeper.cancelAll()
        cancellables = []
        feed = nil
    }

    private func raise(_ approval: ApprovalActivity) {
        hub.publish(.approval(sessionId: approval.sessionId, activity: approval))
    }

    private var resolutions: [AgentActivityEvent.Reason] {
        received.compactMap { if case .decisionResolved(_, let reason) = $0.payload { return reason } else { return nil } }
    }

    func testRespondSendsTheChoiceThroughTheClientAndRemovesTheRow() async {
        raise(Support.approval())
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .resolved)
        XCTAssertEqual(sources.responses.map(\.choice), ["once"])
        XCTAssertEqual(sources.responses.map(\.session), ["s1"])
        XCTAssertEqual(sources.responses.map { $0.request ?? "" }, ["q1"])
        XCTAssertNil(feed.items.first { $0.id == "approval:q1" })
        XCTAssertEqual(resolutions, [.answeredHere])
    }

    func testNotResolvedMeansAnsweredElsewhere() async {
        raise(Support.approval())
        sources.respondResult = .success(false)
        let result = await feed.respond(to: "approval:q1", choice: "deny")
        XCTAssertEqual(result, .alreadyResolved)
        XCTAssertEqual(resolutions, [.answeredElsewhere])
    }

    func testAnExpiredPromptErrorIsTreatedAsAlreadyResolved() async {
        raise(Support.approval())
        sources.respondResult = .failure(RpcError(code: 4009, message: "no pending approval request"))
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .alreadyResolved)
        XCTAssertEqual(resolutions, [.answeredElsewhere])
    }

    func testATransportErrorKeepsTheRowRecordsTheFailureAndAllowsRetry() async {
        raise(Support.approval())
        sources.respondResult = .failure(RpcError(code: 500, message: "boom"))
        let first = await feed.respond(to: "approval:q1", choice: "once")
        guard case .failed(let message) = first else { return XCTFail("expected failure") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(feed.items.first { $0.id == "approval:q1" }?.failure, message)
        sources.respondResult = .success(true)
        let second = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(second, .resolved)
        XCTAssertNil(feed.items.first { $0.id == "approval:q1" })
    }

    func testAChoiceTheRequestDoesNotOfferIsRefusedBeforeAnyRPC() async {
        raise(Support.approval(request: "smart", smartDenied: true))
        let always = await feed.respond(to: "approval:smart", choice: "always")
        XCTAssertEqual(always, .failed(AgentActivityRespondFailure.choiceNotOffered))
        let session = await feed.respond(to: "approval:smart", choice: "session")
        XCTAssertEqual(session, .failed(AgentActivityRespondFailure.choiceNotOffered))

        raise(Support.approval(request: "nopermanent", allowPermanent: false))
        let blocked = await feed.respond(to: "approval:nopermanent", choice: "always")
        XCTAssertEqual(blocked, .failed(AgentActivityRespondFailure.choiceNotOffered))

        XCTAssertTrue(sources.responses.isEmpty, "no RPC for a refused choice")
        XCTAssertNil(feed.items.first { $0.id == "approval:smart" }?.failure, "a refusal does not mark the row failed")
        XCTAssertTrue(resolutions.isEmpty)
    }

    func testAnUnknownChoiceIsRefused() async {
        raise(Support.approval())
        let result = await feed.respond(to: "approval:q1", choice: "approve")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.choiceNotOffered))
    }

    func testTheActiveSessionsApprovalGoesThroughTheOpenCard() async {
        feed.setActiveSession("s1")
        raise(Support.approval())
        sources.cardResult = true
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .resolved)
        XCTAssertEqual(sources.cardResponses.map(\.choice), ["once"])
        XCTAssertTrue(sources.responses.isEmpty)
    }

    func testWithoutAnOpenCardTheActiveSessionFallsBackToTheClient() async {
        feed.setActiveSession("s1")
        raise(Support.approval())
        sources.cardResult = nil
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .resolved)
        XCTAssertEqual(sources.responses.count, 1)
    }

    func testAFailedCardIsAFailureNotAnAlreadyResolved() async {
        feed.setActiveSession("s1")
        raise(Support.approval())
        sources.cardResult = false
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.sendFailed))
        XCTAssertNotNil(feed.items.first { $0.id == "approval:q1" })
    }

    func testRowsWithoutContentOrUnknownIdsCannotBeAnswered() async {
        let unknown = await feed.respond(to: "approval:nope", choice: "once")
        XCTAssertEqual(unknown, .failed(AgentActivityRespondFailure.notAnswerable))
        hub.publish(.messageStart(sessionId: "s1"))
        let turn = await feed.respond(to: "turn:s1", choice: "once")
        XCTAssertEqual(turn, .failed(AgentActivityRespondFailure.notAnswerable))
    }

    func testAFallbackRowWithoutContentCannotBeAnswered() async {
        sources.rows = [Support.row("rt9", "waiting")]
        sources.pendingResults["rt9"] = .failure(RpcError(code: 500, message: "x"))
        pollSleeper.fire()
        await assertEventually { self.feed.items.contains { $0.id == "approval:waiting:rt9" } }
        let result = await feed.respond(to: "approval:waiting:rt9", choice: "once")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.notAnswerable))
    }

    func testADisconnectedFeedRefusesWithoutAnRPC() async {
        raise(Support.approval())
        sources.isConnected = false
        let result = await feed.respond(to: "approval:q1", choice: "once")
        XCTAssertEqual(result, .failed(AgentActivityRespondFailure.notConnected))
        XCTAssertTrue(sources.responses.isEmpty)
    }

    func testTheGatewaysOwnCancelAfterALocalAnswerAddsNothing() async {
        raise(Support.approval())
        _ = await feed.respond(to: "approval:q1", choice: "once")
        hub.publish(.approvalWithdrawn(sessionId: "s1", requestId: "q1", reason: "resolved"))
        XCTAssertEqual(resolutions, [.answeredHere])
    }

    func testASecondResponseForTheSameRowWhileOneIsInFlightIsRejected() async {
        raise(Support.approval())
        sources.holdResponses = true
        let first = Task { await self.feed.respond(to: "approval:q1", choice: "once") }
        await assertEventually { self.sources.responses.count == 1 }
        let second = await feed.respond(to: "approval:q1", choice: "deny")
        XCTAssertEqual(second, .failed(AgentActivityRespondFailure.inFlight))
        sources.releaseResponses()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .resolved)
        XCTAssertEqual(sources.responses.count, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/AgentActivityApprovalTests`
Expected: build failure, `value of type 'AgentActivityFeed' has no member 'respond'`.

- [ ] **Step 3: Implement**

Append to `AgentActivityFeed.swift` (file level):

```swift
/// Stable codes carried in `AgentActivityRespondResult.failed(_)` when no RPC
/// was attempted or the open card failed. Not user-facing: consumers localize them.
enum AgentActivityRespondFailure {
    static let notAnswerable = "not_answerable"
    static let choiceNotOffered = "choice_not_offered"
    static let notConnected = "not_connected"
    static let inFlight = "in_flight"
    static let sendFailed = "send_failed"
}
```

Add a stored property to `AgentActivityFeed` (next to `fetchTasks`):

```swift
    private var respondInFlight: Set<String> = []
```

Add the method to the class (after `dismiss`):

```swift
    /// Answers an approval row with one of `AgentActivityApprovalChoices`. See the task rules.
    func respond(to id: String, choice: String) async -> AgentActivityRespondResult {
        guard let item = state.items[id], item.kind == .approval,
              let approval = item.approval, let requestId = approval.requestId,
              let sessionId = item.sessionId else {
            return .failed(AgentActivityRespondFailure.notAnswerable)
        }
        guard AgentActivityApprovalChoices.isAllowed(choice, for: approval) else {
            return .failed(AgentActivityRespondFailure.choiceNotOffered)
        }
        guard sources.isConnected else { return .failed(AgentActivityRespondFailure.notConnected) }
        guard respondInFlight.insert(id).inserted else { return .failed(AgentActivityRespondFailure.inFlight) }
        defer { respondInFlight.remove(id) }

        apply(.respondStarted(itemId: id))
        do {
            let resolved: Bool
            if item.isActiveSession, let viaCard = await sources.respondViaActiveCard(requestId: requestId, choice: choice) {
                guard viaCard else {
                    apply(.respondFailed(itemId: id, message: AgentActivityRespondFailure.sendFailed))
                    return .failed(AgentActivityRespondFailure.sendFailed)
                }
                resolved = true
            } else {
                resolved = try await sources.respondToApproval(sessionId: sessionId, requestId: requestId, choice: choice)
            }
            apply(.respondResolved(itemId: id, alreadyResolved: !resolved))
            return resolved ? .resolved : .alreadyResolved
        } catch {
            if AgentActivityRpc.isExpiredPrompt(error) {
                apply(.respondResolved(itemId: id, alreadyResolved: true))
                return .alreadyResolved
            }
            let message = UserFacingError.message(for: error)
            apply(.respondFailed(itemId: id, message: message))
            return .failed(message)
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2, then `AgentActivityFeedTests` once more.
Expected: all pass. `testAChoiceTheRequestDoesNotOfferIsRefusedBeforeAnyRPC` is Review Focus 5.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/AgentActivityFeed.swift' 'ConduitMacTests/AgentActivityApprovalTests.swift'
git commit -m "macOS: approval responses limited to the request's choices (shared base)"
```

---

### Task 12: Connection state, offline grace and gap handling

**Files:**
- Create: `ConduitMac/Activity/AgentActivityConnection.swift`
- Modify: `ConduitMac/Activity/AgentActivityReducer.swift`
- Modify: `ConduitMac/Activity/AgentActivityFeed.swift`
- Test: `ConduitMacTests/AgentActivityConnectionTests.swift`

**Interfaces:**
- Consumes: reducer, feed (Tasks 7 to 11); `AppState.$isConnected`, `$isConnecting`, `$connection`, `$client`, `$activeSessionId`, `$sessions`, `$activeProfile`, `activeDashboardID`.
- Produces:
  - `enum AgentActivityConnectionState: Equatable { case connected; case reconnecting(since: Date); case disconnected(since: Date) }`
  - `struct AgentActivityConnectionSignals: Equatable { var isConnected, isConnecting, hasCredentials: Bool }`
  - `enum AgentActivityConnection { static func state(_ signals:, previous:, now:) -> AgentActivityConnectionState }`
  - reducer: `AgentActivityInput.connectionLost`, `.connectionRestored`; `AgentActivityReducer.offlineGrace = 15`; state fields `offlineSince`, `gapRuntimeIds`
  - feed: `@Published private(set) var connection: AgentActivityConnectionState`, `func connectionSignalsChanged(_:)`, `func bind(to appState: AppState)`

Rules (pinned by the tests):
- Visible state: connected; reconnecting (not connected, but credentials exist or a connect is in progress); disconnected (not connected, nothing to reconnect with). `since` is kept while the kind stays the same.
- The feed publishes `connection` at once and sets `availability = .offline` while not connected.
- On loss nothing is emitted (no `turnFinished`, no `decisionResolved`). Rows stay for `offlineGrace` (15 s) so a blip does not flash the surface empty, then clear silently.
- On restore the next poll is a silent baseline, except that a working turn or a decision that was live at the drop and is absent from that first poll finishes at once (one poll, not two) with `observedGap: true` (decisions resolve as `withdrawn`/`sessionClosed`), so consumers can suppress a "done" for something the user never watched end.
- `bind(to:)` follows AppState: connection signals, the active session, the session catalog, client replacement (new connection probes `session.active_list` again), and profile or dashboard switches (silent reset plus a new baseline).

- [ ] **Step 1: Write the failing tests**

```swift
import Combine
import XCTest
@testable import ConduitMac

final class AgentActivityConnectionDerivationTests: XCTestCase {
    private let t0 = AgentActivityTestSupport.origin

    private func signals(_ connected: Bool, _ connecting: Bool = false, _ creds: Bool = false) -> AgentActivityConnectionSignals {
        .init(isConnected: connected, isConnecting: connecting, hasCredentials: creds)
    }

    func testConnectedWinsOverEverything() {
        XCTAssertEqual(AgentActivityConnection.state(signals(true, true, true), previous: .disconnected(since: t0), now: t0), .connected)
    }

    func testNotConnectedWithCredentialsOrAConnectInProgressIsReconnecting() {
        let later = t0.addingTimeInterval(5)
        XCTAssertEqual(AgentActivityConnection.state(signals(false, false, true), previous: .connected, now: later), .reconnecting(since: later))
        XCTAssertEqual(AgentActivityConnection.state(signals(false, true, false), previous: .connected, now: later), .reconnecting(since: later))
    }

    func testNotConnectedWithNothingToReconnectWithIsDisconnected() {
        let later = t0.addingTimeInterval(5)
        XCTAssertEqual(AgentActivityConnection.state(signals(false), previous: .connected, now: later), .disconnected(since: later))
    }

    func testSinceIsKeptWhileTheKindStaysTheSame() {
        let first = AgentActivityConnectionState.reconnecting(since: t0)
        XCTAssertEqual(AgentActivityConnection.state(signals(false, true, true), previous: first, now: t0.addingTimeInterval(30)), first)
        let moved = AgentActivityConnection.state(signals(false), previous: first, now: t0.addingTimeInterval(30))
        XCTAssertEqual(moved, .disconnected(since: t0.addingTimeInterval(30)))
    }
}

final class AgentActivityReducerGapTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private func approval() -> StreamEvent {
        .approval(sessionId: "rt1", activity: Support.approval(session: "rt1"))
    }

    func testLossEmitsNothingAndRowsClearSilentlyAfterTheGrace() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.stream(approval(), at: 1)
        let emitted = h.payloads.count
        h.send(.connectionLost, at: 10)
        XCTAssertEqual(h.payloads.count, emitted, "a drop emits nothing")
        h.send(.tick, at: 24)
        XCTAssertFalse(h.state.items.isEmpty, "inside the grace")
        h.send(.tick, at: 25)
        XCTAssertTrue(h.state.items.isEmpty)
        XCTAssertEqual(h.payloads.count, emitted, "clearing is silent: no turnFinished, no decisionResolved")
    }

    func testASecondLossDoesNotRestartTheGrace() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.send(.connectionLost, at: 10)
        h.send(.connectionLost, at: 20)
        h.send(.tick, at: 25)
        XCTAssertTrue(h.state.items.isEmpty)
    }

    func testRestoringInsideTheGraceKeepsTheRows() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.send(.connectionLost, at: 10)
        h.send(.connectionRestored, at: 12)
        h.send(.tick, at: 60)
        XCTAssertNotNil(h.item("turn:rt1"))
        XCTAssertNil(h.state.offlineSince)
    }

    func testAfterARestoreAVanishedTurnFinishesAtOnceWithAGapFlag() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(.messageStart(sessionId: "rt1"), at: 0)
        h.stream(.messageStart(sessionId: "rt2"), at: 0)
        let starts = h.turnStarts.count
        h.send(.connectionLost, at: 10)
        h.send(.connectionRestored, at: 12)
        h.send(.activeList([Support.row("rt2", "working"), Support.row("rt3", "working")]), at: 13)
        XCTAssertEqual(h.item("turn:rt1")?.state, .finished(.completed), "one poll is enough after a gap")
        XCTAssertEqual(h.turnFinishes.map(\.gap), [true])
        XCTAssertEqual(h.item("turn:rt2")?.state, .working)
        XCTAssertNotNil(h.item("turn:rt3"))
        XCTAssertEqual(h.turnStarts.count, starts, "the baseline after a reconnect is silent")
    }

    func testAnOrdinaryFinishAfterTheBaselineIsNotFlaggedAsAGap() {
        var h = AgentActivityHarness()
        h.send(.activeList([Support.row("rt1", "working")]))
        h.send(.activeList([]), at: 4)
        h.send(.activeList([]), at: 8)
        XCTAssertEqual(h.turnFinishes.map(\.gap), [false])
    }

    func testADecisionThatDidNotSurviveTheGapResolvesOnTheFirstPoll() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(approval(), at: 0)
        h.send(.connectionLost, at: 5)
        h.send(.connectionRestored, at: 7)
        h.send(.activeList([Support.row("rt1", "working")]), at: 8)
        XCTAssertNil(h.item("approval:q1"))
        XCTAssertEqual(h.resolutions.map(\.reason), [.withdrawn])
    }

    func testADecisionStillWaitingAfterTheGapSurvives() {
        var h = AgentActivityHarness()
        h.send(.activeList([]))
        h.stream(approval(), at: 0)
        h.send(.connectionLost, at: 5)
        h.send(.connectionRestored, at: 7)
        h.send(.activeList([Support.row("rt1", "waiting")]), at: 8)
        XCTAssertNotNil(h.item("approval:q1"))
        XCTAssertTrue(h.resolutions.isEmpty)
    }
}

@MainActor
final class AgentActivityFeedConnectionTests: XCTestCase {
    private typealias Support = AgentActivityTestSupport

    private var sources: FakeActivitySources!
    private var hub: MacStreamEventHub!
    private var pollSleeper: ManualSleeper!
    private var tickSleeper: ManualSleeper!
    private var feed: AgentActivityFeed!
    private var now = AgentActivityTestSupport.origin
    private var received: [AgentActivityEvent] = []
    private var cancellables: Set<AnyCancellable> = []
    private var fixture: MacSharedBaseAppStateFixture?

    override func setUp() async throws {
        sources = FakeActivitySources()
        sources.isConnected = false   // connection state is driven by signals here; no polling
        hub = MacStreamEventHub()
        pollSleeper = ManualSleeper()
        tickSleeper = ManualSleeper()
        now = Support.origin
        received = []
        cancellables = []
        feed = AgentActivityFeed(
            sources: sources, hub: hub, clock: { [unowned self] in self.now },
            pollSleep: pollSleeper.sleep, tickSleep: tickSleeper.sleep)
    }

    override func tearDown() async throws {
        feed.stop()
        pollSleeper.cancelAll()
        tickSleeper.cancelAll()
        cancellables = []
        fixture?.tearDown()
        fixture = nil
        feed = nil
    }

    private func signals(_ connected: Bool, _ connecting: Bool = false, _ creds: Bool = true) -> AgentActivityConnectionSignals {
        .init(isConnected: connected, isConnecting: connecting, hasCredentials: creds)
    }

    func testReconnectingAndDisconnectedAreVisibleAndAvailabilityGoesOffline() {
        feed.start()
        feed.connectionSignalsChanged(signals(true))
        XCTAssertEqual(feed.connection, .connected)
        XCTAssertEqual(feed.availability, .live)
        feed.connectionSignalsChanged(signals(false))
        XCTAssertEqual(feed.connection, .reconnecting(since: now))
        XCTAssertEqual(feed.availability, .offline)
        feed.connectionSignalsChanged(signals(false, false, false))
        XCTAssertEqual(feed.connection, .disconnected(since: now))
        feed.connectionSignalsChanged(signals(true))
        XCTAssertEqual(feed.connection, .connected)
        XCTAssertEqual(feed.availability, .live)
    }

    func testRowsSurviveTheGraceThenClearWithoutEvents() async {
        feed.start()
        feed.connectionSignalsChanged(signals(true))
        hub.publish(.messageStart(sessionId: "s1"))
        feed.events.sink { [unowned self] in self.received.append($0) }.store(in: &cancellables)
        feed.connectionSignalsChanged(signals(false))
        await assertEventually { self.tickSleeper.pending == 1 }
        now = Support.origin.addingTimeInterval(14)
        tickSleeper.fire()
        await assertEventually { self.tickSleeper.requested.count == 2 && self.tickSleeper.pending == 1 }
        XCTAssertEqual(feed.items.map(\.id), ["turn:s1"], "inside the grace the surface does not flash empty")
        now = Support.origin.addingTimeInterval(15)
        tickSleeper.fire()
        await assertEventually { self.feed.items.isEmpty }
        XCTAssertTrue(received.isEmpty, "no turnFinished on disconnect")
    }

    func testBindFollowsAppStateConnectionAndActiveSession() {
        let fixture = MacSharedBaseAppStateFixture()
        self.fixture = fixture
        let appState = fixture.appState
        feed.bind(to: appState)
        feed.start()
        XCTAssertEqual(feed.connection, .disconnected(since: now))

        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "t")
        XCTAssertEqual(feed.connection, .reconnecting(since: now), "credentials but no socket")
        appState.isConnected = true
        XCTAssertEqual(feed.connection, .connected)
        appState.isConnected = false
        XCTAssertEqual(feed.connection, .reconnecting(since: now))
        appState.connection = nil
        XCTAssertEqual(feed.connection, .disconnected(since: now))

        appState.activeSessionId = "s1"
        hub.publish(.messageStart(sessionId: "s1"))
        XCTAssertEqual(feed.items.first?.isActiveSession, true)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/AgentActivityConnectionDerivationTests -only-testing:ConduitMacTests/AgentActivityReducerGapTests -only-testing:ConduitMacTests/AgentActivityFeedConnectionTests`
Expected: build failure, `cannot find 'AgentActivityConnectionSignals' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Activity/AgentActivityConnection.swift`:

```swift
import Foundation

enum AgentActivityConnectionState: Equatable {
    case connected
    /// Not connected, but credentials exist or a connect is in progress.
    case reconnecting(since: Date)
    /// Not connected and nothing to reconnect with (signed out).
    case disconnected(since: Date)
}

struct AgentActivityConnectionSignals: Equatable {
    var isConnected: Bool
    var isConnecting: Bool
    var hasCredentials: Bool
}

enum AgentActivityConnection {
    /// Pure derivation. `since` is kept while the kind stays the same.
    static func state(
        _ signals: AgentActivityConnectionSignals,
        previous: AgentActivityConnectionState,
        now: Date
    ) -> AgentActivityConnectionState {
        if signals.isConnected { return .connected }
        if signals.hasCredentials || signals.isConnecting {
            if case .reconnecting = previous { return previous }
            return .reconnecting(since: now)
        }
        if case .disconnected = previous { return previous }
        return .disconnected(since: now)
    }
}
```

Reducer edits (`AgentActivityReducer.swift`):

(a) `AgentActivityState`, after `nextTurnSeq`:

```swift
    /// Set while the socket is down; rows clear after `offlineGrace`.
    var offlineSince: Date?
    /// Runtime ids with live work when the socket dropped.
    var gapRuntimeIds: Set<String> = []
```

(b) `AgentActivityInput`, after `.catalog`:

```swift
    case connectionLost
    case connectionRestored
```

(c) `AgentActivityReducer` constants, after `previewLimit`:

```swift
    /// Rows stay this long after the socket drops, then clear silently.
    static let offlineGrace: TimeInterval = 15
```

(d) `Engine.apply`, before `case .tick:`:

```swift
            case .connectionLost:
                guard s.offlineSince == nil else { return }
                s.offlineSince = now
                s.gapRuntimeIds = Set(s.items.values.compactMap {
                    ($0.state == .working || $0.state == .needsUser) ? $0.sessionId : nil
                })
            case .connectionRestored:
                s.offlineSince = nil
                s.baselinePending = true
```

Also add `s.gapRuntimeIds = []` to the `.activeListUnavailable` arm.

(e) `Engine.tick()`, as its first statement:

```swift
            if let offlineSince = s.offlineSince,
               now.timeIntervalSince(offlineSince) >= AgentActivityReducer.offlineGrace {
                if !s.items.isEmpty || !s.waiting.isEmpty {
                    s.items = [:]
                    s.misses = [:]
                    s.waiting = [:]
                }
                s.gapRuntimeIds = []
                return
            }
```

(f) Replace the two miss loops in `Engine.activeList` (from `for item in Array(s.items.values) where item.kind == .turn` to the end of the method) with:

```swift
            let gap = s.gapRuntimeIds
            for item in Array(s.items.values) where item.kind == .turn && item.state == .working {
                guard let runtime = item.sessionId else { continue }
                if let row = byRuntime[runtime] {
                    if row.isRunning { s.misses[item.id] = 0; continue }
                    if row.status == "starting" { continue }   // runtime present, liveness inconclusive
                }
                let inGap = gap.contains(runtime)
                let needed = (baseline && inGap) ? 1 : AgentActivityReducer.missesToFinish
                let misses = (s.misses[item.id] ?? 0) + 1
                s.misses[item.id] = misses
                if misses >= needed {
                    finish(runtime, outcome: .completed, preview: nil, observedGap: inGap)
                }
            }

            for item in Array(s.items.values) where item.state == .needsUser {
                guard let runtime = item.sessionId else { continue }
                if byRuntime[runtime]?.status == "waiting" { s.misses[item.id] = 0; continue }
                let needed = (baseline && gap.contains(runtime)) ? 1 : AgentActivityReducer.missesToFinish
                let misses = (s.misses[item.id] ?? 0) + 1
                s.misses[item.id] = misses
                if misses >= needed {
                    resolve(item.id, byRuntime[runtime] == nil ? .sessionClosed : .withdrawn)
                }
            }
            if baseline { s.gapRuntimeIds = [] }
        }
```

Feed edits (`AgentActivityFeed.swift`):

(a) Add properties:

```swift
    @Published private(set) var connection: AgentActivityConnectionState = .disconnected(since: Date(timeIntervalSince1970: 0))
    private var bindings: Set<AnyCancellable> = []
    private var isBound = false
```

(b) In `init`, as the last statement: `self.connection = .disconnected(since: clock())`.

(c) In `start()`, before `updateAvailability()`:

```swift
        if !isBound {
            connection = sources.isConnected ? .connected : .disconnected(since: clock())
        }
```

(d) Replace the body of `updateAvailability()`:

```swift
        let next: AgentActivityAvailability
        if !started || connection != .connected {
            next = .offline
        } else {
            next = activeListUnsupported ? .eventsOnly : .live
        }
        if next != availability { availability = next }
```

(e) Add:

```swift
    /// Folds connection signals into the visible state and tells the reducer
    /// about drops and restores.
    func connectionSignalsChanged(_ signals: AgentActivityConnectionSignals) {
        let next = AgentActivityConnection.state(signals, previous: connection, now: clock())
        guard next != connection else { return }
        let wasConnected = connection == .connected
        connection = next
        if next == .connected {
            apply(.connectionRestored)
            poller.resetCapability()
            activeListUnsupported = false
            refreshNow()
        } else if wasConnected {
            apply(.connectionLost)
        }
        updateAvailability()
    }

    /// Follows AppState: connection, active session, catalog, client and scope.
    func bind(to appState: AppState) {
        guard !isBound else { return }
        isBound = true
        // @Published emits in willSet: use the emitted values, never re-read the property inside the sink.
        Publishers.CombineLatest3(appState.$isConnected, appState.$isConnecting, appState.$connection.map { $0 != nil })
            .sink { [weak self] connected, connecting, hasCredentials in
                self?.connectionSignalsChanged(.init(isConnected: connected, isConnecting: connecting, hasCredentials: hasCredentials))
            }
            .store(in: &bindings)
        appState.$activeSessionId
            .sink { [weak self] id in self?.setActiveSession(id) }
            .store(in: &bindings)
        appState.$sessions
            .sink { [weak self] sessions in self?.setCatalog(sessions) }
            .store(in: &bindings)
        appState.$client
            .dropFirst()
            .sink { [weak self] _ in
                self?.poller.resetCapability()
                self?.activeListUnsupported = false
            }
            .store(in: &bindings)
        // Profile and dashboard switches: read the settled values on the next turn.
        Publishers.Merge(appState.$activeProfile.map { _ in () }, appState.$connection.map { _ in () })
            .sink { [weak self, weak appState] _ in
                DispatchQueue.main.async {
                    guard let self, let appState else { return }
                    self.setScope(profile: appState.activeProfile, dashboardID: appState.activeDashboardID?.uuidString ?? "none")
                }
            }
            .store(in: &bindings)
        setScope(profile: appState.activeProfile, dashboardID: appState.activeDashboardID?.uuidString ?? "none")
    }
```

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2, then every earlier activity class (`AgentActivityReducerStreamTests`, `AgentActivityReducerPollTests`, `AgentActivityPollerTests`, `AgentActivityFeedTests`, `AgentActivityApprovalTests`).
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/AgentActivityConnection.swift' 'ConduitMac/Activity/AgentActivityReducer.swift' 'ConduitMac/Activity/AgentActivityFeed.swift' 'ConduitMacTests/AgentActivityConnectionTests.swift'
git commit -m "macOS: activity feed connection state, offline grace and gap handling (shared base)"
```

---

### Task 13: Mac reconnect while the app is not frontmost (gated AppState edit)

**Files:**
- Create: `ConduitMac/App/MacTransportRecoveryPolicy.swift`
- Modify: `Conduit/Services/AppState.swift` (`canRunTransportRecovery`, about line 3220)
- Modify: `docs/macos/PORTING_LEDGER.md` (one row)
- Test: `ConduitMacTests/MacTransportRecoveryTests.swift`

**Interfaces:**
- Consumes: `MacSharedBaseAppStateFixture` (Task 5), `AppState.scheduleReconnect(immediately:purpose:)`, `handleScenePhase(_:)`, the `reconnectScheduler` / `reconnectExecutor` init seams.
- Produces: `enum MacTransportRecoveryPolicy { static var allowsRecoveryWhileInactive = true }`; on Mac `canRunTransportRecovery` is true whenever the policy allows it.

Why: on Mac, closing the window or switching to another app sets the scene inactive, but the process and its gateway socket live on (`applicationShouldTerminateAfterLastWindowClosed` is false). `canRunTransportRecovery` gates `scheduleReconnect`, `executeReconnect` and, through `transportContinuation`, the whole post-connect sync on the scene being active (an iOS rule: backgrounded scene work must finish inside the 0x8BADF00D watchdog). So a socket lost while the Mac app is behind other windows stays dead until it is brought forward, and the feed and notifications go blind exactly when they matter. The `.active` scene path still repairs on return; this only stops recovery from being refused in the meantime.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

/// Mirrors the iOS `CarPlayTransportRecoveryTests` seams: a recording scheduler
/// and executor, no network.
@MainActor
final class MacTransportRecoveryTests: XCTestCase {
    private final class Recorder {
        var delays: [TimeInterval] = []
        var operations: [@MainActor () async -> Void] = []
        var purposes: [ChatResumeSyncPurpose] = []
    }

    private var fixture: MacSharedBaseAppStateFixture!
    private let recorder = Recorder()

    override func setUp() async throws {
        let recorder = self.recorder
        fixture = MacSharedBaseAppStateFixture(
            reconnectScheduler: { delay, operation in
                recorder.delays.append(delay)
                recorder.operations.append(operation)
                return {}
            },
            reconnectExecutor: { purpose in recorder.purposes.append(purpose) })
        fixture.appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        fixture.appState.isConnected = false
        fixture.appState.isConnecting = false
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = true
    }

    override func tearDown() async throws {
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = true
        fixture.tearDown()
        fixture = nil
    }

    func testAReconnectIsScheduledAndRunsWhileTheAppIsInBackground() async {
        _ = fixture.appState.handleScenePhase(.background)
        XCTAssertFalse(fixture.appState.isSceneActive)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertEqual(recorder.delays.count, 1, "an inactive Mac app still schedules recovery")
        await recorder.operations.first?()
        XCTAssertEqual(recorder.purposes.count, 1, "and the cycle runs")
    }

    func testAReconnectIsScheduledWhileInactive() async {
        _ = fixture.appState.handleScenePhase(.inactive)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertEqual(recorder.delays.count, 1)
        await recorder.operations.first?()
        XCTAssertEqual(recorder.purposes.count, 1)
    }

    func testAnActiveSceneStillSchedulesNormally() {
        _ = fixture.appState.handleScenePhase(.active)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertEqual(recorder.delays.count, 1)
    }

    func testTurningThePolicyOffRestoresTheSceneGate() {
        MacTransportRecoveryPolicy.allowsRecoveryWhileInactive = false
        _ = fixture.appState.handleScenePhase(.background)
        fixture.appState.scheduleReconnect(immediately: true)
        XCTAssertTrue(recorder.delays.isEmpty, "with the policy off the iOS rule applies again")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacTransportRecoveryTests`
Expected: build failure, `cannot find 'MacTransportRecoveryPolicy' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/App/MacTransportRecoveryPolicy.swift` (kept out of `ConduitMac/Activity/`, whose files must not name the scene state):

```swift
import Foundation

/// Whether transport recovery (reconnect cycles and the post-connect sync) may
/// run while Conduit is not the frontmost app. On Mac the process and its
/// gateway socket outlive the window, and the agent activity feed and
/// notifications need the socket back without the user foregrounding the app.
enum MacTransportRecoveryPolicy {
    static var allowsRecoveryWhileInactive = true
}
```

In `Conduit/Services/AppState.swift`, edit `canRunTransportRecovery`. Match on the anchor text.

Before:

```swift
    private var canRunTransportRecovery: Bool {
        isSceneActive || isCarPlayVoiceSurfaceActive || isLockedVoiceSurfaceActive || isWatchVoiceCallActive || isNativeHermesCallActive
    }
```

After:

```swift
    private var canRunTransportRecovery: Bool {
        #if os(macOS) // MAC: the window can be closed or hidden while the dashboard socket stays up (activity feed, notifications); the iOS watchdog reason for this gate does not apply
        return MacTransportRecoveryPolicy.allowsRecoveryWhileInactive
            || isSceneActive || isCarPlayVoiceSurfaceActive || isLockedVoiceSurfaceActive || isWatchVoiceCallActive || isNativeHermesCallActive
        #else
        return isSceneActive || isCarPlayVoiceSurfaceActive || isLockedVoiceSurfaceActive || isWatchVoiceCallActive || isNativeHermesCallActive
        #endif // MAC:
    }
```

The original expression line is re-added with `return` inside the `#else` branch because Swift cannot wrap a bare single-expression body in `#if`. Verify the diff for this hunk: `git diff -U0 -- Conduit/Services/AppState.swift` shows exactly one `-` line (the original expression) and the `+` lines above; the `#else` branch is that line plus `return`, so iOS semantics are unchanged.

- [ ] **Step 4: Run to verify pass**

Run: the command from Step 2. Then `-only-testing:ConduitMacTests/MissingSessionRecoveryTests` (it drives the same recovery seams).
Expected: all pass.

- [ ] **Step 5: Ledger row and commit**

Append as the last row of the table in `docs/macos/PORTING_LEDGER.md`:

```
| Conduit/Services/AppState.swift `canRunTransportRecovery` | R4 (1 region, `#if`/`#else`/`#endif` tagged `// MAC:`; the one expression line is re-added with `return` in the `#else` branch, so the diff removes exactly that one line and iOS semantics are unchanged) | the Mac app keeps its dashboard socket while inactive or windowless (applicationShouldTerminateAfterLastWindowClosed is false), but `scheduleReconnect`, `executeReconnect` and the post-connect sync (`transportContinuation`) are all gated on the scene being active, an iOS rule against the backgrounded-scene watchdog (0x8BADF00D). On Mac a socket lost behind other windows stayed dead until foregrounded, blinding the activity feed and notifications. Gated by `MacTransportRecoveryPolicy.allowsRecoveryWhileInactive` (default true); the `.active` scene path still repairs on return | ConduitMac/App/MacTransportRecoveryPolicy.swift; tested in MacTransportRecoveryTests |
```

```bash
git add 'Conduit/Services/AppState.swift' 'ConduitMac/App/MacTransportRecoveryPolicy.swift' 'ConduitMacTests/MacTransportRecoveryTests.swift' 'docs/macos/PORTING_LEDGER.md'
git commit -m "macOS: reconnect while the app is not frontmost (shared base)"
```

---

### Task 14: Bootstrap, docs and the full gate

**Files:**
- Create: `ConduitMac/Activity/MacActivityBootstrap.swift`
- Modify: `ConduitMac/App/ConduitMacAppDelegate.swift`
- Modify: `docs/macos/DECISIONS.md` (one section), `docs/macos/SMOKE_CHECKLIST.md` (one section)
- Test: `ConduitMacTests/MacActivityBootstrapTests.swift`

**Interfaces:**
- Consumes: `AgentActivityFeed`, `AgentActivityLiveSources` (Tasks 9 to 12), `AppStateRuntimeRegistry.shared.appState`, `MacDefaults.isRunningUnderXCTest`.
- Produces: `@MainActor enum MacActivityBootstrap { static var feed: AgentActivityFeed? { get }; static func start(appState:); static func stop() }`. After launch (outside XCTest) `AgentActivityFeed.shared` is non-nil, bound to the app's `AppState`, subscribed to `MacStreamEventHub.shared` and polling. It runs whether or not any UI exists, and keeps running after the last window closes.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacActivityBootstrapTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!

    override func setUp() async throws {
        fixture = MacSharedBaseAppStateFixture()
    }

    override func tearDown() async throws {
        MacActivityBootstrap.stop()
        fixture.tearDown()
        fixture = nil
    }

    func testStartCreatesBindsAndSubscribesTheSharedFeedOnce() {
        let before = MacStreamEventHub.shared.subscriberCount
        MacActivityBootstrap.start(appState: fixture.appState)
        MacActivityBootstrap.start(appState: fixture.appState)
        XCTAssertNotNil(AgentActivityFeed.shared)
        XCTAssertTrue(AgentActivityFeed.shared === MacActivityBootstrap.feed)
        XCTAssertEqual(MacStreamEventHub.shared.subscriberCount, before + 1)
    }

    func testStopTearsItDown() {
        let before = MacStreamEventHub.shared.subscriberCount
        MacActivityBootstrap.start(appState: fixture.appState)
        MacActivityBootstrap.stop()
        XCTAssertNil(AgentActivityFeed.shared)
        XCTAssertNil(MacActivityBootstrap.feed)
        XCTAssertEqual(MacStreamEventHub.shared.subscriberCount, before)
    }

    func testAnEventPublishedByAppStateReachesTheSharedFeed() {
        MacActivityBootstrap.start(appState: fixture.appState)
        fixture.appState.handleStreamEvent(.messageStart(sessionId: "other"))
        XCTAssertEqual(AgentActivityFeed.shared?.items.map(\.id), ["turn:other"],
                       "AppState tap -> hub -> feed, for a session that is not open")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacActivityBootstrapTests`
Expected: build failure, `cannot find 'MacActivityBootstrap' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Activity/MacActivityBootstrap.swift`:

```swift
import Foundation

/// Creates the one app-wide `AgentActivityFeed`. Called from the app delegate at
/// launch, not from a window, so it keeps running after the last window closes.
@MainActor
enum MacActivityBootstrap {
    private(set) static var feed: AgentActivityFeed?

    static func start(appState: AppState = AppStateRuntimeRegistry.shared.appState) {
        guard feed == nil else { return }
        let feed = AgentActivityFeed(sources: AgentActivityLiveSources(appState: appState))
        feed.bind(to: appState)
        feed.start()
        AgentActivityFeed.shared = feed
        self.feed = feed
    }

    static func stop() {
        feed?.stop()
        feed = nil
        AgentActivityFeed.shared = nil
    }
}
```

In `ConduitMac/App/ConduitMacAppDelegate.swift`, inside `applicationDidFinishLaunching`, after the `HoverAccessibilityEngine.install()` line:

```swift
        if !MacDefaults.isRunningUnderXCTest { MacActivityBootstrap.start() }
```

(If the compiler objects to the main-actor call from the delegate method, wrap it: `MainActor.assumeIsolated { MacActivityBootstrap.start() }`; `applicationDidFinishLaunching` runs on the main thread.)

Docs. Append to `docs/macos/DECISIONS.md`:

```
## Mac shared base: floating panel, stream hub, activity feed (2026-10-15)
Plan: docs/superpowers/plans/2026-10-15-mac-shared-base.md. Specs: Quick Ask, notch status, notifications (all 2026-10-15). The consumer features own the numbered decisions; this section records the base they share.
- `MacFloatingPanel` (ConduitMac/Panels): borderless non-activating NSPanel hosting SwiftUI, with pure placement (`screenCenterTop`, `screenCenterTopFraction`, `notchAnchored`, `edgeDocked`, `custom`). Opt-in drag (4 pt threshold) snaps to the nearest edge of the screen under the pointer and reports an `.edgeDocked` placement for the owner to persist; a saved screen that is gone falls back to notch-anchored. Optional menu-bar overlap, content size, hover callbacks, no shadow.
- One upstream line in `AppState.handleStreamEvent` publishes every StreamEvent to `MacStreamEventHub` (ahead of the active-session filter). Quick Ask and the activity feed subscribe; neither adds an upstream line.
- `AgentActivityFeed` (ConduitMac/Activity): pure reducer over stream events and a feed-owned `session.active_list` poll that never consults whether Conduit is frontmost (4 s while live or visible, 15 s idle). Poll-only sessions (same gateway process, socket not attached) show working and waiting only; `approval.pending` supplies approval content, and a failure degrades to a no-button row. Sessions from other processes are invisible by gateway design.
- Visible connection state (connected, reconnecting, disconnected); rows clear silently 15 s after a drop; after a reconnect a vanished turn finishes once with `observedGap`.
- `canRunTransportRecovery` is exempted on Mac so reconnect runs while the app is not frontmost (`MacTransportRecoveryPolicy`).
- Approval responses are limited to the request's own choices (once, session, always, deny; smart-denied requests offer only once and deny; always also needs allowPermanent).
```

Append to `docs/macos/SMOKE_CHECKLIST.md` a section (match the file's existing heading and list style):

```
## Shared base (floating panel, stream hub, activity feed)
- Panel (needs a consumer panel): click a control without moving the mouse and it still clicks; drag past about 4 pt and the panel follows; releasing near each of the four edges snaps to that edge; releasing on an external display docks there; unplug that display and the panel returns to its default notch-anchored spot; after a drag a control under the pointer is not left highlighted and does not fire.
- Panel never takes focus from the front app: show it from Safari and keep typing there; it appears over a full-screen app and on the current Space.
- Reconnect while behind other windows: close the Conduit window (Cmd-W), switch to another app, restart the gateway (or turn Wi-Fi off for 20 s and on again). Conduit reconnects within about 30 s without being brought forward (before this change it stayed disconnected until foregrounded).
- Feed while not frontmost: start a turn in session A, open session B in the main window, switch to another app. A consumer (notch, notifications) still sees A working and then finished.
- Poll-only session: a session running in the same gateway process but opened by another client shows as working or waiting with no tool name; a CLI or Slack session from another process never appears (expected).
- Disconnect: turn Wi-Fi off; the consumer shows reconnecting at once and clears its rows after about 15 s with no "done" notification; turn it back on and a turn that finished during the outage is dropped without a notification.
```

- [ ] **Step 4: Run to verify pass, then the whole gate**

Run: the command from Step 2.
Expected: MacActivityBootstrapTests pass.

Then the whole gate, in order:
1. `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO` twice. Expected: `** TEST SUCCEEDED **` both times (known flaky: the orb test).
2. `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`. Expected: `** BUILD SUCCEEDED **`.
3. Upstream diff check against the branch base: `git diff <base> -- Conduit Shared | grep '^-[^-]'` prints exactly one line (the original `canRunTransportRecovery` expression). `git diff <base> -- Conduit Shared | grep '^+' | grep -c 'MAC:'` shows the tagged gate lines of Tasks 5 and 13 only; `grep -rn 'MacStreamEventHub' Conduit | wc -l` prints 1.
4. `grep -rn 'isSceneActive\|scenePhase' ConduitMac/Activity` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Activity/MacActivityBootstrap.swift' 'ConduitMac/App/ConduitMacAppDelegate.swift' 'ConduitMacTests/MacActivityBootstrapTests.swift' 'docs/macos/DECISIONS.md' 'docs/macos/SMOKE_CHECKLIST.md'
git commit -m "macOS: start the activity feed at launch; shared base docs and smoke items"
```

---

## Consumer API Summary (what the three feature plans call)

Quick Ask (panel, hub):
- `MacFloatingPanelController(config: MacFloatingPanelConfig(size:, maxHeight:, placement: .screenCenterTopFraction(0.22), canBecomeKey: true, dismissOnResignKey: true, ...)) { QuickAskView }`, then `show()`, `hide()`, `toggle()`, `updateContentHeight(_:)`, `isVisible`.
- `MacStreamEventHub.shared.subscribe { event in ... } -> Token` and `unsubscribe(_:)`: replaces `MacQuickAskStreamTap.observe`; the upstream line is already in place.

Notch status (panel, feed):
- Panel: `placement: .notchAnchored` by default, `.edgeDocked(edge:offset:screenID:)` once dragged; `canBecomeKey: false`, `dismissOnResignKey: false`, `dismissOnEscape: false`, `level: .statusBar`, `allowsMenuBarOverlap: true`, `hasShadow: false`, `onMouseEntered`/`onMouseExited`, `isDraggable: true`, `onPlacementChanged` (persist the placement: `edge.rawValue`, `offset`, `screenID`), `controller.setPlacement(_:)` to restore, `currentPlacement`, `updateContentSize(_:)`, `.custom` for the no-notch pill, `EdgeDockGeometry` and `MacEdgeDock` for per-edge content layout.
- Feed: `AgentActivityFeed.shared` (`items`, `availability`, `connection`, `isBaselined`, `snapshot()`, `events`), `respond(to:choice:)` with `AgentActivityApprovalChoices.allowed(for:)` to decide which buttons to draw, `dismiss(_:)`, `setPanelVisible(_:)`, `refreshNow()`. Row actions open sessions through `AppState.requestOpenSession` (not part of the base).

Notifications (feed):
- `AgentActivityFeed.shared?.events` (subscribe on the main actor; dedupe on `eventId`; `turnFinished` dedupe on `(item.sessionKey, item.turnSeq)`), `snapshot()` after `isBaselined`, `AgentActivityEvent.Payload` cases `turnStarted`, `turnFinished(outcome, replyPreview, observedGap)`, `decisionRequested` (approval: `item.approval`; question: `item.kind == .clarify`, `item.detail`, `item.openQuestionCount`), `decisionResolved(id:reason:)`, `titleChanged`. Approve and Deny from a notification call `respond(to: item.id, choice:)` (or `HermesClient.respondToApproval` directly); the mapper lives in the Notifications plan.

## Execution Notes

- Order: Tasks 1, 2, 3, 3A, 3B (panel track) are independent of Tasks 4 to 13 (hub, feed, recovery) and may run in separate worktrees; merge the panel track and the feed track, then run Task 14. Inside the feed track: 4, 5, 6, 7, 8, 9, 10, 11, 12 are sequential. Task 13 depends only on Task 5's fixture and may run any time after it. Tasks 5 and 13 both edit `Conduit/Services/AppState.swift` (different hunks): merge them one after the other.
- After all tasks: whole-branch review against the three specs and this plan's Review Focus, merge into `macos`, run the full suite on the merge, then remove the worktree, delete the branch and `build/dd` right away.
- Do not stage `Conduit/Views/ChatView.swift` or the user's pending `AppState.swift` hunk at any point.
