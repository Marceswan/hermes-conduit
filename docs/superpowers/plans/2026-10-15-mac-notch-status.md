# Mac Notch Agent Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**REQUIRES SHARED BASE MERGED.** This plan does not build `MacFloatingPanel`, the stream-event tap, `AgentActivityFeed` / `AgentActivityReducer`, the background poll, approval respond, connection state or the Mac reconnect-while-inactive exemption. Those come from `docs/superpowers/plans/2026-10-15-mac-shared-base.md`. Do not start Task 1 until that plan is merged into `macos` (Task 1 Step 1 checks it).

**Goal:** A hidden-when-idle status surface at the top-center of the screen (the MacBook notch, or a pill on other displays) that shows working agents, approvals and blocked Kanban cards, lets the user Allow once / Deny inline, and opens the session in the main window on click.

**Architecture:** Pure, table-tested units (`NotchGeometry`, `NotchRowBuilder`, `NotchStatusState`) sit between the shared `AgentActivityFeed` and a thin AppKit shell. A `NotchActivitySource` protocol isolates the feed so every other file is testable with a fake. `NotchStatusController` owns the `MacFloatingPanel` host, a timer scheduler, a dismiss monitor and the view model; SwiftUI views render the view model only.

**Tech Stack:** Swift 6 / SwiftUI / AppKit on macOS 14+, Combine, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-15-mac-notch-status-design.md` (approved; open questions resolved to its proposed defaults: on by default in "Active agents" mode, `NSScreen.main`, Kanban rows open the Kanban pane only, no menu bar icon). Also read the `AgentActivityFeed API` section of that spec and the `MacFloatingPanel API` section of `docs/superpowers/specs/2026-10-15-mac-quick-ask-design.md`.

## Global Constraints

- Mac-only. New code under `ConduitMac/Notch/`; tests under `ConduitMacTests/`. iOS behaviour is unchanged; do not build or verify iOS.
- Upstream edits (`Conduit/`, `Shared/`) are `#if os(macOS)` gated, tagged `// MAC:`, with one row each in `docs/macos/PORTING_LEDGER.md`. `git diff <base> -- Conduit Shared` removes zero lines. This plan has two: the Settings section line in `Conduit/Views/AuxiliaryViews.swift` (Task 2) and the additive `Conduit/Localizable.xcstrings` keys (Task 9). No edit to `Conduit/Services/AppState.swift` (the tap is the shared base's).
- Surface states: Hidden (ordered out, no hit area), Compact, Expanded. Hover expands after 200 ms and collapses after 400 ms. A new approval, clarify or input prompt expands and stays until resolved, or until the pointer leaves after the user interacted. A finished turn flashes expanded for 4 s. After an auto-expand for attention, approval buttons are disabled for 600 ms.
- Rows: Needs you (approvals, clarify, input prompts, Kanban blocked or review), Working, Done. Max 6 rows, then "+N more" (opens the main window). Done and failed rows live 30 s, max 3.
- Without a notch: a 28 pt pill, 160 to 260 pt wide, centered, just below the menu bar of the chosen screen. Screen is `NSScreen.main`. Notch test: `safeAreaInsets.top > 0` and both `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` non-empty (macOS 12+ API; deployment target is 14, no `#available`).
- Approval buttons come from the request's own `choices` (`once`, `session`, `always`, `deny`; default set when nil, as `ChatView.allows`). Inline buttons: "Allow once" and "Deny". "Allow for session" and "Always allow" are menu-only. A smart-denied request offers only once and deny. `always` also needs `allowPermanent`. Clarify, sudo, secret and vault prompts are never inline: the row says "Answer in Conduit".
- Command text: monospaced, 2 lines, truncated at 160 chars, never logged (no `print`, `os_log`, `NSLog`, string interpolation into errors).
- Click a row: activate Conduit, show the main window, `requestOpenSession(id)`. Kanban rows open the Kanban pane only. The cron footer opens the Cron pane. New Chat honors `MacNewChatAvailability` (`appState.macNewChatDisabled`).
- The feed is read-mostly: the notch never writes `liveSessionStatusIndex`, `turnState` or any AppState field. Its one write path is `feed.respond(to:choice:)`.
- Setting key `conduit.mac.notchStatus.mode`, values `activeAgents` (default) / `onlyWhenNeeded` / `off`. No menu bar icon. Active profile only.
- UI limit to state in the empty state, the Settings footnote and D16: Conduit sees only sessions on its own gateway socket. Sessions started by another process (CLI, Slack, a separate cron process) are invisible. Sessions of the same gateway process that appear in `session.active_list` show, but approvals and events only flow after `session.activate` / `session.resume`, which Conduit does when the user opens the row; that adds Conduit as a viewer of that session.
- Accessibility: one group "Agent status: ..." with every row and button reachable; attention posts an `NSAccessibility` announcement; Hover is never the only way in ("Show Agent Status" command); Reduce Motion means fade only. Text on the black surface is at least 4.5:1.
- Localization per `docs/LOCALIZATION.md`: every on-screen string through `AppLocalization.string` (or a SwiftUI literal), counts as `Int` plurals, one key per sentence, all shipped languages translated (Task 9).
- Build: `xcodegen generate`, then `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`. Tests: same command with `test -only-testing:'ConduitMacTests/<Class>'`. Never two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`. In zsh, quote every glob and `-only-testing` value.
- Tests: injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`), an injected timer scheduler (no real sleeps), explicit teardown. Never touch the live app's defaults. No test installs real event monitors or shows a real panel on the user's screen except the hosted panel tests in Task 5, which use an offscreen frame.
- Git: stage explicit paths only (`git add <path> ...`). Never `git add -A`, `git add .` or `git commit -a`: the main checkout has uncommitted user edits in `Conduit/Services/AppState.swift` and `Conduit/Views/ChatView.swift` that must not be committed by this work. `Conduit.xcodeproj` is generated and untracked.
- Safety: the user's own Conduit is running. Do not quit it, click it or type into it. Smoke items that need the running app are for the user.

## Review Focus

1. Approval arrives while the user is already clicking near the notch: buttons stay disabled for exactly 600 ms, Allow once is never default-key bound, Always allow is menu-only. Tests in Task 4 (`testClickGuard...`) and Task 6 (`testAlwaysAllowIsNotAnInlineButton`).
2. The request is answered elsewhere (main window, Hermes Desktop) while the row is on screen, or the click races it (`.alreadyResolved`): the row disappears without an error. Test in Task 8.
3. Display unplugged, lid closed or `NSScreen.main` changes while expanded: panel re-anchors to the new screen, hides if there is none, and returns without losing state. Test in Task 8.
4. Huge, multi-line or secret-looking command text: collapsed to one line of at most 160 chars for the 2-line field, never logged. Test in Task 3.
5. Twenty sessions working at once: 6 rows plus "+14 more", and Needs-you rows are never pushed into the overflow. Test in Task 3.

## File Map

- Create `ConduitMac/Notch/NotchGeometry.swift`: pure placement and frame math (Task 1).
- Create `ConduitMac/Notch/NotchStatusSettings.swift`, `ConduitMac/Notch/NotchStatusSettingsSection.swift`: mode setting and picker (Task 2).
- Create `ConduitMac/Notch/NotchActivitySource.swift`: protocol, feed adapter, typealiases (Task 3).
- Create `ConduitMac/Notch/NotchRowBuilder.swift`: rows, approval choices, counts, diff, compact label (Task 3).
- Create `ConduitMac/Notch/NotchStatusState.swift`: the state machine (Task 4).
- Create `ConduitMac/Notch/NotchPanelHost.swift`: `MacFloatingPanel` wrapper; additive members on the shared panel only if missing (Task 5).
- Create `ConduitMac/Notch/NotchStatusViewModel.swift`, `NotchStatusView.swift`, `NotchStatusRowView.swift`, `NotchPalette.swift` (Task 6).
- Create `ConduitMac/Notch/NotchActions.swift`, `NotchTimerScheduling.swift`, `NotchDismissMonitor.swift`, `NotchStatusController.swift` (Tasks 7 and 8).
- Modify `ConduitMac/App/ConduitMacApp.swift`, `ConduitMac/App/ConduitCommands.swift` (Task 7).
- Modify `Conduit/Views/AuxiliaryViews.swift` (one gated line, Task 2), `Conduit/Localizable.xcstrings` (Task 9).
- Tests: `ConduitMacTests/NotchTestFixtures.swift`, `NotchGeometryTests.swift`, `NotchStatusSettingsTests.swift`, `NotchRowBuilderTests.swift`, `NotchStatusStateTests.swift`, `NotchPanelHostTests.swift`, `NotchStatusViewTests.swift`, `NotchStatusControllerTests.swift`.
- Docs: `docs/macos/DECISIONS.md` (D16), `docs/macos/PORTING_LEDGER.md`, `docs/macos/SMOKE_CHECKLIST.md` (Task 10).

`ConduitMac/` sources are picked up by the folder glob in `project.yml`; run `xcodegen generate` after adding files.

---

### Task 1: Preflight, then NotchGeometry

**Files:**
- Create: `ConduitMac/Notch/NotchGeometry.swift`
- Test: `ConduitMacTests/NotchGeometryTests.swift`

**Interfaces:**
- Produces:
  - `struct NotchScreenMetrics: Equatable { var frame: CGRect; var visibleFrame: CGRect; var safeAreaTop: CGFloat; var auxiliaryTopLeft: CGRect; var auxiliaryTopRight: CGRect }` and `@MainActor static func main() -> NotchScreenMetrics?` (reads `NSScreen.main`)
  - `enum NotchPlacement: Equatable { case notch(notchRect: CGRect); case pill }` with `var notchWidth: CGFloat`, `var notchHeight: CGFloat` (0 for pill)
  - `enum NotchMetrics` constants: `leftWing = 36`, `rightWing = 124`, `pillHeight = 28`, `pillMinWidth = 160`, `pillMaxWidth = 260`, `pillGap = 4`, `expandedWidth = 380`
  - `enum NotchGeometry { static func placement(for:) -> NotchPlacement; static func compactFrame(_:in:contentWidth:) -> CGRect; static func expandedFrame(_:in:height:) -> CGRect }`

- [ ] **Step 1: Preflight the shared base (stop if it fails)**

Run:
```bash
git log --oneline -20 | grep -i "shared base\|floating panel\|activity feed"
grep -rn "final class MacFloatingPanelController\|enum MacFloatingPanelPlacement\|final class AgentActivityFeed\|struct AgentActivityItem\|struct AgentActivityReducer" ConduitMac | head
```
Expected: all five types found. If any is missing, the shared base is not merged: stop and report. Then record, in a scratch note (not committed), the actual names for: the nested or top-level `Availability` enum and `RespondResult` enum; the `AgentActivityItem` memberwise initializer (argument order, whether `alternateIds` or other stored properties exist); how `ApprovalActivity` reaches `AgentActivityItem.approval` (expected: the existing `ApprovalActivity` in `Conduit/Models/Models.swift` with `choices`, `allowPermanent`, `smartDenied`, `command`); whether finished items expire inside the feed; what `since` means on a `.cron` item (expected: next run time); who creates, retains and starts the feed instance (`AgentActivityFeed.shared` is weak); and whether an `activateMainWindow` helper already exists (`grep -rn "activateMainWindow" ConduitMac`). Tasks 3, 5, 7 use these.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class NotchGeometryTests: XCTestCase {
    // Representative values for a 14" notch display. Task 10's smoke item
    // records the real values from hardware; the logic does not depend on them.
    private let mbp14 = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 659, height: 32),
        auxiliaryTopRight: CGRect(x: 853, y: 950, width: 659, height: 32))
    private let mbp16 = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 765, height: 32),
        auxiliaryTopRight: CGRect(x: 963, y: 1085, width: 765, height: 32))
    private let external = NotchScreenMetrics(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0, auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)

    func testNotchScreensYieldNotchRect() {
        guard case .notch(let r) = NotchGeometry.placement(for: mbp14) else { return XCTFail("expected notch") }
        XCTAssertEqual(r, CGRect(x: 659, y: 950, width: 194, height: 32))
        guard case .notch(let r16) = NotchGeometry.placement(for: mbp16) else { return XCTFail("expected notch") }
        XCTAssertEqual(r16.width, 198)
        XCTAssertEqual(r16.maxY, mbp16.frame.maxY)
    }

    func testNoNotchAndEmptyAuxiliaryAreasFallBackToPill() {
        XCTAssertEqual(NotchGeometry.placement(for: external), .pill)
        var mirrored = mbp14
        mirrored.auxiliaryTopLeft = .zero   // mirrored or clamshell: no extra unobscured area
        XCTAssertEqual(NotchGeometry.placement(for: mirrored), .pill)
        var inconsistent = mbp14
        inconsistent.auxiliaryTopRight = CGRect(x: 600, y: 950, width: 100, height: 32)   // maxX <= minX
        XCTAssertEqual(NotchGeometry.placement(for: inconsistent), .pill)
    }

    func testCompactNotchFrameWrapsTheNotchWithWingsAtTheTopEdge() {
        let p = NotchGeometry.placement(for: mbp14)
        let f = NotchGeometry.compactFrame(p, in: mbp14, contentWidth: 0)
        XCTAssertEqual(f.minX, 659 - NotchMetrics.leftWing)
        XCTAssertEqual(f.width, 194 + NotchMetrics.leftWing + NotchMetrics.rightWing)
        XCTAssertEqual(f.height, 32)
        XCTAssertEqual(f.maxY, mbp14.frame.maxY, "top flush with the physical screen edge")
    }

    func testCompactWingsClampToTheUnobscuredAreas() {
        var narrow = mbp14
        narrow.auxiliaryTopLeft = CGRect(x: 0, y: 950, width: 20, height: 32)
        narrow.auxiliaryTopRight = CGRect(x: 214, y: 950, width: 50, height: 32)
        let f = NotchGeometry.compactFrame(NotchGeometry.placement(for: narrow), in: narrow, contentWidth: 0)
        XCTAssertEqual(f.minX, 20 - 20)
        XCTAssertEqual(f.maxX, 214 + 50)
    }

    func testPillIsClampedCenteredAndBelowTheMenuBarOfThatScreen() {
        let p = NotchGeometry.placement(for: external)
        let small = NotchGeometry.compactFrame(p, in: external, contentWidth: 90)
        XCTAssertEqual(small.width, NotchMetrics.pillMinWidth)
        let large = NotchGeometry.compactFrame(p, in: external, contentWidth: 900)
        XCTAssertEqual(large.width, NotchMetrics.pillMaxWidth)
        XCTAssertEqual(large.midX, external.visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(large.height, NotchMetrics.pillHeight)
        XCTAssertEqual(large.maxY, external.visibleFrame.maxY - NotchMetrics.pillGap)
        XCTAssertGreaterThanOrEqual(large.minX, external.frame.minX, "stays on the secondary screen")
    }

    func testExpandedNotchFrameIsTopFlushAndCenteredOnTheNotch() {
        let p = NotchGeometry.placement(for: mbp16)
        let f = NotchGeometry.expandedFrame(p, in: mbp16, height: 300)
        XCTAssertEqual(f.width, NotchMetrics.expandedWidth)
        XCTAssertEqual(f.midX, 864, accuracy: 0.5)
        XCTAssertEqual(f.maxY, mbp16.frame.maxY)
        XCTAssertEqual(f.height, 300)
    }

    func testExpandedPillFrameHangsBelowTheMenuBar() {
        let p = NotchGeometry.placement(for: external)
        let f = NotchGeometry.expandedFrame(p, in: external, height: 300)
        XCTAssertEqual(f.maxY, external.visibleFrame.maxY - NotchMetrics.pillGap)
        XCTAssertEqual(f.midX, external.visibleFrame.midX, accuracy: 0.5)
    }

    func testExpandedHeightClampsToTheScreen() {
        let p = NotchGeometry.placement(for: external)
        let f = NotchGeometry.expandedFrame(p, in: external, height: 5000)
        XCTAssertLessThanOrEqual(f.height, external.visibleFrame.height - 8)
        XCTAssertGreaterThanOrEqual(f.minY, external.visibleFrame.minY)
    }

    func testNotchSizeAccessors() {
        XCTAssertEqual(NotchGeometry.placement(for: mbp14).notchWidth, 194)
        XCTAssertEqual(NotchGeometry.placement(for: mbp14).notchHeight, 32)
        XCTAssertEqual(NotchPlacement.pill.notchHeight, 0)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/NotchGeometryTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile, `cannot find 'NotchGeometry' in scope`.

- [ ] **Step 4: Implement**

```swift
import AppKit

struct NotchScreenMetrics: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect
    var auxiliaryTopRight: CGRect

    /// The screen of the key window, else the primary (`NSScreen.main`).
    @MainActor static func main() -> NotchScreenMetrics? {
        guard let s = NSScreen.main else { return nil }
        return NotchScreenMetrics(
            frame: s.frame, visibleFrame: s.visibleFrame,
            safeAreaTop: s.safeAreaInsets.top,
            auxiliaryTopLeft: s.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRight: s.auxiliaryTopRightArea ?? .zero)
    }
}

enum NotchPlacement: Equatable {
    case notch(notchRect: CGRect)
    case pill

    var notchWidth: CGFloat { if case .notch(let r) = self { r.width } else { 0 } }
    var notchHeight: CGFloat { if case .notch(let r) = self { r.height } else { 0 } }
}

enum NotchMetrics {
    static let leftWing: CGFloat = 36
    static let rightWing: CGFloat = 124
    static let pillHeight: CGFloat = 28
    static let pillMinWidth: CGFloat = 160
    static let pillMaxWidth: CGFloat = 260
    static let pillGap: CGFloat = 4
    static let expandedWidth: CGFloat = 380
}

enum NotchGeometry {
    /// `safeAreaInsets.top` is the notch height; the auxiliary areas are the
    /// unobscured menu bar rects either side of it (NSScreen.h, macOS 12+).
    static func placement(for m: NotchScreenMetrics) -> NotchPlacement {
        guard m.safeAreaTop > 0, !m.auxiliaryTopLeft.isEmpty, !m.auxiliaryTopRight.isEmpty else { return .pill }
        let minX = m.auxiliaryTopLeft.maxX, maxX = m.auxiliaryTopRight.minX
        guard maxX > minX else { return .pill }
        return .notch(notchRect: CGRect(x: minX, y: m.frame.maxY - m.safeAreaTop, width: maxX - minX, height: m.safeAreaTop))
    }

    static func compactFrame(_ p: NotchPlacement, in m: NotchScreenMetrics, contentWidth: CGFloat) -> CGRect {
        switch p {
        case .notch(let n):
            let left = min(NotchMetrics.leftWing, m.auxiliaryTopLeft.width)
            let right = min(NotchMetrics.rightWing, m.auxiliaryTopRight.width)
            return CGRect(x: n.minX - left, y: n.minY, width: n.width + left + right, height: n.height)
        case .pill:
            let w = min(max(contentWidth, NotchMetrics.pillMinWidth), NotchMetrics.pillMaxWidth)
            return CGRect(x: m.visibleFrame.midX - w / 2,
                          y: m.visibleFrame.maxY - NotchMetrics.pillGap - NotchMetrics.pillHeight,
                          width: w, height: NotchMetrics.pillHeight)
        }
    }

    static func expandedFrame(_ p: NotchPlacement, in m: NotchScreenMetrics, height: CGFloat) -> CGRect {
        let w = NotchMetrics.expandedWidth
        let h = min(height, m.visibleFrame.height - 8)
        switch p {
        case .notch(let n):
            let x = min(max(n.midX - w / 2, m.frame.minX), m.frame.maxX - w)
            return CGRect(x: x, y: m.frame.maxY - h, width: w, height: h)
        case .pill:
            let x = min(max(m.visibleFrame.midX - w / 2, m.frame.minX), m.frame.maxX - w)
            return CGRect(x: x, y: m.visibleFrame.maxY - NotchMetrics.pillGap - h, width: w, height: h)
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run the Step 3 command. Expected: all `NotchGeometryTests` PASS. If the 14" `midX` or wing math fails by a point, fix the code, not the fixture.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/Notch/NotchGeometry.swift ConduitMacTests/NotchGeometryTests.swift
git commit -m "macOS notch: geometry (notch rect, pill fallback, frames)"
```

---

### Task 2: Mode setting, Settings picker, Settings gate

**Files:**
- Create: `ConduitMac/Notch/NotchStatusSettings.swift`, `ConduitMac/Notch/NotchStatusSettingsSection.swift`
- Modify: `Conduit/Views/AuxiliaryViews.swift` (the `VStack` in `body`, after `chatDisplaySection`, about line 176)
- Modify: `docs/macos/PORTING_LEDGER.md`
- Test: `ConduitMacTests/NotchStatusSettingsTests.swift`

**Interfaces:**
- Produces:
  - `enum NotchMode: String, CaseIterable, Equatable { case activeAgents, onlyWhenNeeded, off }` (raw values are the stored strings)
  - `@MainActor final class NotchStatusSettings: ObservableObject` with `static let key = "conduit.mac.notchStatus.mode"`, `static let shared`, `init(defaults: UserDefaults = .standard)`, `@Published var mode: NotchMode` (writes through to defaults; re-reads on `UserDefaults.didChangeNotification` so the `@AppStorage` picker and this stay in step)
  - `struct MacNotchStatusSettingsSection: View`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class NotchStatusSettingsTests: XCTestCase {
    func testDefaultIsActiveAgents() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        XCTAssertEqual(NotchStatusSettings(defaults: s.defaults).mode, .activeAgents)
    }

    func testUnknownStoredValueFallsBackToDefault() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        s.defaults.set("sometimes", forKey: NotchStatusSettings.key)
        XCTAssertEqual(NotchStatusSettings(defaults: s.defaults).mode, .activeAgents)
    }

    func testSettingModePersistsUnderTheDocumentedKey() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let settings = NotchStatusSettings(defaults: s.defaults)
        settings.mode = .onlyWhenNeeded
        XCTAssertEqual(s.defaults.string(forKey: "conduit.mac.notchStatus.mode"), "onlyWhenNeeded")
    }

    func testExternalWriteIsPickedUp() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let settings = NotchStatusSettings(defaults: s.defaults)
        s.defaults.set("off", forKey: NotchStatusSettings.key)   // what the @AppStorage picker does
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: s.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { settings.mode == .off })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/NotchStatusSettingsTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL, `cannot find 'NotchStatusSettings'`.

- [ ] **Step 3: Implement settings and section**

```swift
import Combine
import Foundation

enum NotchMode: String, CaseIterable, Equatable {
    case activeAgents, onlyWhenNeeded, off
}

@MainActor
final class NotchStatusSettings: ObservableObject {
    static let key = "conduit.mac.notchStatus.mode"
    static let shared = NotchStatusSettings()

    @Published var mode: NotchMode {
        didSet { if oldValue != mode { defaults.set(mode.rawValue, forKey: Self.key) } }
    }
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = Self.read(defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.read(self.defaults)
                if current != self.mode { self.mode = current }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private static func read(_ d: UserDefaults) -> NotchMode {
        d.string(forKey: key).flatMap(NotchMode.init(rawValue:)) ?? .activeAgents
    }
}
```

```swift
import SwiftUI

/// The "Notch status" section of the Settings sheet (inserted by one gated
/// line in AuxiliaryViews.swift).
struct MacNotchStatusSettingsSection: View {
    @AppStorage(NotchStatusSettings.key) private var raw = NotchMode.activeAgents.rawValue

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Notch status"), symbol: "capsule.tophalf.filled", tint: .conduitAccent) {
            Picker(AppLocalization.string("Notch status"), selection: $raw) {
                Text("Active agents").tag(NotchMode.activeAgents.rawValue)
                Text("Only when I'm needed").tag(NotchMode.onlyWhenNeeded.rawValue)
                Text("Off").tag(NotchMode.off.rawValue)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Shows what Hermes is doing at the top of the screen. It only sees chats on this connection: chats started from the CLI, Slack or another app are not shown.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
```
If `ConduitSettingsSection`'s signature differs, copy the call shape from `appearanceSection` in `AuxiliaryViews.swift`.

- [ ] **Step 4: Add the gated Settings line and ledger row**

In `Conduit/Views/AuxiliaryViews.swift`, inside the `VStack(spacing: 14)` after `chatDisplaySection`:
```swift
                        chatDisplaySection
                        #if os(macOS)
                        MacNotchStatusSettingsSection() // MAC: notch agent status mode (D16)
                        #endif
                        aboutSection
```
Append a row to `docs/macos/PORTING_LEDGER.md` in the exact column format of the neighbouring R4 rows (`grep -n "| R4 |" docs/macos/PORTING_LEDGER.md`):
`| Conduit/Views/AuxiliaryViews.swift | R4 | Mac-only "Notch status" section in the Settings sheet; the section lives in ConduitMac/Notch | statement gated `#if os(macOS)`; iOS never compiles it |`

- [ ] **Step 5: Run tests and the Mac build**

Run the Step 2 command (PASS), then the full Mac build command from Global Constraints. Expected `** BUILD SUCCEEDED **`. Then `git diff -- Conduit Shared | grep '^-[^-]'` must print nothing.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/Notch/NotchStatusSettings.swift ConduitMac/Notch/NotchStatusSettingsSection.swift ConduitMacTests/NotchStatusSettingsTests.swift Conduit/Views/AuxiliaryViews.swift docs/macos/PORTING_LEDGER.md
git commit -m "macOS notch: mode setting and Settings section (gated, ledger)"
```

---

### Task 3: Activity source, rows, choices, counts, diff

**Files:**
- Create: `ConduitMac/Notch/NotchActivitySource.swift`, `ConduitMac/Notch/NotchRowBuilder.swift`
- Test: `ConduitMacTests/NotchTestFixtures.swift`, `ConduitMacTests/NotchRowBuilderTests.swift`

**Interfaces:**
- Consumes (from the shared base, names per the spec): `AgentActivityItem` (`id, kind, state, sessionId, sessionKey, title, detail, since, approval, isActiveSession`), `AgentActivityItem.Kind` (`turn, approval, clarify, inputPrompt, kanban, cron`), `AgentActivityItem.State` (`working, needsUser, finished(Outcome), blocked`), `AgentActivityItem.Outcome` (`completed, failed(String), interrupted`), `AgentActivityFeed` (`$items`, `$availability`, `respond(to:choice:)`, `dismiss(_:)`), `ApprovalActivity` (`command, choices, allowPermanent, smartDenied, requestId`).
- Produces:
  - `typealias NotchAvailability = <actual type from preflight>` (cases `live`, `eventsOnly`, `offline`) and `typealias NotchRespondResult = <actual type>` (cases `resolved`, `alreadyResolved`, `failed(String)`)
  - `@MainActor protocol NotchActivitySource: AnyObject { var items: [AgentActivityItem] { get }; var itemsPublisher: AnyPublisher<[AgentActivityItem], Never> { get }; var availability: NotchAvailability { get }; var availabilityPublisher: AnyPublisher<NotchAvailability, Never> { get }; func respond(to id: String, choice: String) async -> NotchRespondResult; func dismiss(_ id: String) }` and `final class FeedNotchSource: NotchActivitySource` (wraps `AgentActivityFeed`)
  - `struct NotchApprovalChoices: Equatable { once, deny, session, always: Bool; hasInlineButtons; static func resolve(_ a: ApprovalActivity) -> NotchApprovalChoices }`
  - `struct NotchRow: Identifiable, Equatable` (see code), `struct NotchCounts: Equatable`, `struct NotchCronInfo: Equatable { title: String; at: Date }`, `struct NotchRowList: Equatable { rows, overflow, counts, cron; static let empty }`
  - `enum NotchRowBuilder { static let maxRows = 6, doneLifetime: TimeInterval = 30, maxDone = 3, commandLimit = 160; static func build(items:now:) -> NotchRowList; static func truncatedCommand(_:) -> String }`
  - `enum NotchItemDiff { static func transitions(old:new:) -> (newDecision: Bool, newFinish: Bool) }`
  - `enum NotchCompactLabel: Equatable { case needYou(Int), tool(String), working(Int), done, none; static func make(counts:items:) -> NotchCompactLabel }`

- [ ] **Step 1: Write the fixtures and failing tests**

`ConduitMacTests/NotchTestFixtures.swift` isolates the feed model's initializer; adjust it to the real memberwise init found in Task 1 Step 1 and touch nothing else when it differs.

```swift
import Foundation
@testable import ConduitMac

enum NotchFixtures {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func item(
        _ id: String, kind: AgentActivityItem.Kind = .turn, state: AgentActivityItem.State = .working,
        session: String? = nil, title: String = "Chat", detail: String? = nil,
        since: Date = t0, approval: ApprovalActivity? = nil
    ) -> AgentActivityItem {
        AgentActivityItem(
            id: id, kind: kind, state: state, sessionId: session ?? id, sessionKey: session ?? id,
            profile: "default", dashboardID: "d", title: title, detail: detail, since: since,
            approval: approval, isActiveSession: false)
    }

    static func approval(
        command: String = "ls", choices: [String]? = nil, allowPermanent: Bool = true, smartDenied: Bool = false
    ) -> ApprovalActivity {
        ApprovalActivity(sessionId: "s", requestId: "r1", command: command, description: "d",
                         choices: choices, allowPermanent: allowPermanent, smartDenied: smartDenied,
                         status: .pending, choice: nil, error: nil)
    }

    static func approvalItem(_ id: String, session: String, approval: ApprovalActivity? = approval()) -> AgentActivityItem {
        item(id, kind: .approval, state: .needsUser, session: session, title: "Deploy", approval: approval)
    }
}
```

`ConduitMacTests/NotchRowBuilderTests.swift`:

```swift
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
        let c = NotchApprovalChoices.resolve(F.approval(choices: ["once", "session", "always", "deny"], smartDenied: true))
        XCTAssertEqual(c, NotchApprovalChoices(once: true, deny: true, session: false, always: false))
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
```
Note: `NotchCompactLabel.make` takes the built rows (`[NotchRow]`) as its `items:` argument; the Interfaces line above is superseded by this signature: `static func make(counts: NotchCounts, items: [NotchRow]) -> NotchCompactLabel`. Rows therefore carry the tool detail (`NotchRow.detail`).

- [ ] **Step 2: Run to verify failure**

Run (test command pattern from Task 1, class `NotchRowBuilderTests`). Expected: FAIL to compile, `cannot find 'NotchRowBuilder'`.

- [ ] **Step 3: Implement the source adapter**

```swift
import Combine
import Foundation

// Set these two to the shared base's real types (Task 1 Step 1 notes).
typealias NotchAvailability = AgentActivityFeed.Availability
typealias NotchRespondResult = AgentActivityFeed.RespondResult

@MainActor
protocol NotchActivitySource: AnyObject {
    var items: [AgentActivityItem] { get }
    var itemsPublisher: AnyPublisher<[AgentActivityItem], Never> { get }
    var availability: NotchAvailability { get }
    var availabilityPublisher: AnyPublisher<NotchAvailability, Never> { get }
    func respond(to id: String, choice: String) async -> NotchRespondResult
    func dismiss(_ id: String)
}

@MainActor
final class FeedNotchSource: NotchActivitySource {
    private let feed: AgentActivityFeed
    init(feed: AgentActivityFeed) { self.feed = feed }

    var items: [AgentActivityItem] { feed.items }
    var itemsPublisher: AnyPublisher<[AgentActivityItem], Never> { feed.$items.eraseToAnyPublisher() }
    var availability: NotchAvailability { feed.availability }
    var availabilityPublisher: AnyPublisher<NotchAvailability, Never> { feed.$availability.eraseToAnyPublisher() }
    func respond(to id: String, choice: String) async -> NotchRespondResult { await feed.respond(to: id, choice: choice) }
    func dismiss(_ id: String) { feed.dismiss(id) }
}
```

- [ ] **Step 4: Implement the row builder**

```swift
import Foundation

struct NotchApprovalChoices: Equatable {
    var once = false
    var deny = false
    var session = false
    var always = false
    var hasInlineButtons: Bool { once || deny }

    /// Same rule as `ChatView.allows`, plus: smart-denied requests never offer
    /// the persistent grants, and Session / Always are menu-only anyway.
    static func resolve(_ a: ApprovalActivity) -> NotchApprovalChoices {
        let offered = Set(a.choices ?? (a.smartDenied ? ["once", "deny"] : ["once", "session", "always", "deny"]))
        let grants = !a.smartDenied
        return NotchApprovalChoices(
            once: offered.contains("once"), deny: offered.contains("deny"),
            session: grants && offered.contains("session"),
            always: grants && a.allowPermanent && offered.contains("always"))
    }
}

struct NotchCounts: Equatable {
    var decisions = 0   // approval, clarify, input prompt: the interruptive kinds
    var needsUser = 0   // decisions + Kanban blocked or review
    var working = 0
    var recent = 0      // finished rows still shown
    var isActive: Bool { needsUser + working > 0 }
    var hasAnything: Bool { isActive || recent > 0 }
}

struct NotchCronInfo: Equatable {
    var title: String
    var at: Date
}

struct NotchRow: Identifiable, Equatable {
    enum Section: Int, Comparable {
        case needsYou, working, done
        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }
    enum Target: Equatable { case session(String), kanban, cron }
    enum Inline: Equatable {
        case none
        case approval(NotchApprovalChoices, command: String)
        case answerInConduit   // clarify, sudo, secret, vault: never inline
        case openToAnswer      // approval content not captured or no usable choice
    }
    enum Tone: Equatable { case normal, attention, failed }

    let id: String
    var section: Section
    var title: String
    var detail: String?
    var target: Target?
    var inline: Inline
    var tone: Tone
    var canDismiss: Bool
}

struct NotchRowList: Equatable {
    var rows: [NotchRow]
    var overflow: Int
    var counts: NotchCounts
    var cron: NotchCronInfo?
    var nextExpiry: Date?
    static let empty = NotchRowList(rows: [], overflow: 0, counts: NotchCounts(), cron: nil, nextExpiry: nil)
}

enum NotchRowBuilder {
    static let maxRows = 6
    static let doneLifetime: TimeInterval = 30
    static let maxDone = 3
    static let commandLimit = 160

    static func build(items: [AgentActivityItem], now: Date) -> NotchRowList {
        let decisionSessions = Set(items.compactMap { i -> String? in
            guard isDecision(i.kind), case .needsUser = i.state else { return nil }
            return i.sessionKey ?? i.sessionId
        })

        var needs: [NotchRow] = [], working: [NotchRow] = []
        var done: [(row: NotchRow, since: Date)] = []
        var cron: NotchCronInfo?
        var counts = NotchCounts()

        for i in items {
            switch (i.kind, i.state) {
            case (.cron, _):
                if cron == nil { cron = NotchCronInfo(title: i.title, at: i.since) }
            case (.turn, .working):
                if let key = i.sessionKey ?? i.sessionId, decisionSessions.contains(key) { continue }
                counts.working += 1
                working.append(row(i, .working, tone: .normal, inline: .none))
            case (.turn, .finished(let outcome)):
                guard now.timeIntervalSince(i.since) <= doneLifetime else { continue }
                var r = row(i, .done, tone: .normal, inline: .none)
                if case .failed(let message) = outcome { r.tone = .failed; r.detail = truncatedCommand(message) }
                r.canDismiss = true
                done.append((r, i.since))
            case (.kanban, .blocked), (.kanban, .needsUser):
                counts.needsUser += 1
                var r = row(i, .needsYou, tone: .attention, inline: .none)
                r.target = .kanban
                needs.append(r)
            case (let kind, .needsUser) where isDecision(kind):
                counts.needsUser += 1; counts.decisions += 1
                needs.append(row(i, .needsYou, tone: .attention, inline: inline(for: i)))
            default:
                continue
            }
        }

        let newestDone = done.sorted { $0.since > $1.since }.prefix(maxDone)
        counts.recent = newestDone.count
        let ordered = needs + working + newestDone.map(\.row)
        return NotchRowList(
            rows: Array(ordered.prefix(maxRows)), overflow: max(0, ordered.count - maxRows),
            counts: counts, cron: cron,
            nextExpiry: newestDone.map { $0.since.addingTimeInterval(doneLifetime) }.min())
    }

    /// Collapses whitespace runs (including newlines) and cuts at 160 chars.
    /// Never log the result: it can contain secrets.
    static func truncatedCommand(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > commandLimit else { return flat }
        return String(flat.prefix(commandLimit - 1)) + "\u{2026}"
    }

    private static func isDecision(_ k: AgentActivityItem.Kind) -> Bool {
        k == .approval || k == .clarify || k == .inputPrompt
    }

    private static func inline(for i: AgentActivityItem) -> NotchRow.Inline {
        guard i.kind == .approval else { return .answerInConduit }
        guard let a = i.approval else { return .openToAnswer }
        let choices = NotchApprovalChoices.resolve(a)
        return choices.hasInlineButtons ? .approval(choices, command: truncatedCommand(a.command)) : .openToAnswer
    }

    private static func row(_ i: AgentActivityItem, _ section: NotchRow.Section, tone: NotchRow.Tone, inline: NotchRow.Inline) -> NotchRow {
        let title = i.title.isEmpty ? AppLocalization.string("Untitled chat") : i.title
        let id = i.sessionId ?? i.sessionKey
        return NotchRow(
            id: i.id, section: section, title: title, detail: i.detail.map(truncatedCommand),
            target: id.map { .session($0) }, inline: inline, tone: tone, canDismiss: false)
    }
}

enum NotchItemDiff {
    static func transitions(old: [AgentActivityItem], new: [AgentActivityItem]) -> (newDecision: Bool, newFinish: Bool) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var decision = false, finish = false
        for i in new {
            let before = oldByID[i.id]
            switch i.state {
            case .needsUser where i.kind == .approval || i.kind == .clarify || i.kind == .inputPrompt:
                if before == nil { decision = true }
            case .finished where i.kind == .turn:
                if case .finished? = before?.state { break }
                finish = true
            default: break
            }
        }
        return (decision, finish)
    }
}

enum NotchCompactLabel: Equatable {
    case needYou(Int), tool(String), working(Int), done, none

    static func make(counts: NotchCounts, items rows: [NotchRow]) -> NotchCompactLabel {
        if counts.needsUser > 0 { return .needYou(counts.needsUser) }
        if counts.working == 1, let tool = rows.first(where: { $0.section == .working })?.detail, !tool.isEmpty { return .tool(tool) }
        if counts.working > 0 { return .working(counts.working) }
        return counts.recent > 0 ? .done : .none
    }
}
```
`AgentActivityItem.State` / `Kind` need `Equatable` for the pattern matches; they are (the item is `Equatable`). If `Kind` lacks `Equatable` conformance synthesis (no payload), it has it automatically.

- [ ] **Step 5: Run to verify pass**

Run the Task 3 test command. Expected: PASS. Then `grep -n "print(\|NSLog\|os_log\|Logger" ConduitMac/Notch/NotchRowBuilder.swift` must print nothing.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/Notch/NotchActivitySource.swift ConduitMac/Notch/NotchRowBuilder.swift ConduitMacTests/NotchTestFixtures.swift ConduitMacTests/NotchRowBuilderTests.swift
git commit -m "macOS notch: activity source adapter, row builder, approval choices"
```

---

### Task 4: State machine

**Files:**
- Create: `ConduitMac/Notch/NotchStatusState.swift`
- Test: `ConduitMacTests/NotchStatusStateTests.swift`

**Interfaces:**
- Consumes: `NotchMode` (Task 2), `NotchCounts` (Task 3).
- Produces:
  - `enum NotchSurface: Equatable { case hidden, compact, expanded }`
  - `enum NotchTimer: Hashable { case hoverIn, hoverOut, flash, clickGuard }`
  - `enum NotchEffect: Equatable { case schedule(NotchTimer, after: TimeInterval), cancel(NotchTimer), announceAttention }`
  - `enum NotchInput: Equatable { case counts(NotchCounts, newDecision: Bool, newFinish: Bool), mode(NotchMode), online(Bool), hoverEntered, hoverExited, interacted, dismissRequested, toggleCommandPin, timer(NotchTimer) }`
  - `struct NotchStatusState: Equatable { init(mode:); var surface: NotchSurface; var buttonsEnabled: Bool; var isCommandPinned: Bool; mutating func apply(_ input: NotchInput) -> [NotchEffect] }` with constants `hoverInDelay = 0.2`, `hoverOutDelay = 0.4`, `flashDuration = 4.0`, `clickGuard = 0.6`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run the test command for `NotchStatusStateTests`. Expected: FAIL, `cannot find 'NotchStatusState'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum NotchSurface: Equatable { case hidden, compact, expanded }
enum NotchTimer: Hashable { case hoverIn, hoverOut, flash, clickGuard }

enum NotchEffect: Equatable {
    case schedule(NotchTimer, after: TimeInterval)
    case cancel(NotchTimer)
    case announceAttention
}

enum NotchInput: Equatable {
    case counts(NotchCounts, newDecision: Bool, newFinish: Bool)
    case mode(NotchMode)
    case online(Bool)
    case hoverEntered, hoverExited
    case interacted
    case dismissRequested       // Esc or a click outside
    case toggleCommandPin       // Go > Show Agent Status
    case timer(NotchTimer)
}

/// Pure state machine. The controller runs the returned effects and feeds
/// timer expiries back in, so tests need no clock.
struct NotchStatusState: Equatable {
    static let hoverInDelay: TimeInterval = 0.2
    static let hoverOutDelay: TimeInterval = 0.4
    static let flashDuration: TimeInterval = 4.0
    static let clickGuard: TimeInterval = 0.6

    private(set) var mode: NotchMode
    private(set) var counts = NotchCounts()
    private var online = true
    private var attentionPinned = false
    private var commandPinned = false
    private var hovering = false
    private var hoverExpanded = false
    private var flashing = false
    private var guarding = false
    private var interacted = false

    init(mode: NotchMode = .activeAgents) { self.mode = mode }

    var isCommandPinned: Bool { commandPinned }
    var buttonsEnabled: Bool { !guarding }

    var surface: NotchSurface {
        if !online || mode == .off { return commandPinned ? .expanded : .hidden }
        if commandPinned || attentionPinned { return .expanded }
        let visible = mode == .onlyWhenNeeded ? counts.needsUser > 0 : counts.hasAnything
        guard visible else { return .hidden }
        return (flashing || hoverExpanded) ? .expanded : .compact
    }

    private static let allTimers: [NotchEffect] = [.cancel(.hoverIn), .cancel(.hoverOut), .cancel(.flash), .cancel(.clickGuard)]

    private mutating func clearTransient() {
        attentionPinned = false; hoverExpanded = false; flashing = false; guarding = false; interacted = false
    }

    mutating func apply(_ input: NotchInput) -> [NotchEffect] {
        var fx: [NotchEffect] = []
        switch input {
        case let .counts(c, newDecision, newFinish):
            counts = c
            let live = online && mode != .off
            if live && newDecision {
                attentionPinned = true; interacted = false; guarding = true
                fx += [.schedule(.clickGuard, after: Self.clickGuard), .announceAttention]
            } else if c.decisions == 0 && attentionPinned {
                attentionPinned = false; interacted = false; guarding = false
                fx.append(.cancel(.clickGuard))
            }
            if live && mode == .activeAgents && newFinish && !attentionPinned && c.recent > 0 {
                flashing = true
                fx.append(.schedule(.flash, after: Self.flashDuration))
            }
            if !c.hasAnything {
                flashing = false; hoverExpanded = false
                fx += [.cancel(.flash), .cancel(.hoverIn), .cancel(.hoverOut)]
            }
        case let .mode(m):
            mode = m
            if m == .off { clearTransient(); fx = Self.allTimers }
        case let .online(o):
            online = o
            if !o { clearTransient(); fx = Self.allTimers }
        case .hoverEntered:
            hovering = true
            fx.append(.cancel(.hoverOut))
            if surface == .compact && !hoverExpanded { fx.append(.schedule(.hoverIn, after: Self.hoverInDelay)) }
        case .hoverExited:
            hovering = false
            fx.append(.cancel(.hoverIn))
            if hoverExpanded || (attentionPinned && interacted) {
                fx.append(.schedule(.hoverOut, after: Self.hoverOutDelay))
            } else if surface != .compact {
                fx = []   // nothing pending to cancel (sticky panel before interaction)
            }
        case .interacted:
            interacted = true
        case .dismissRequested:
            guard surface == .expanded else { return [] }
            commandPinned = false; clearTransient()
            fx = Self.allTimers
        case .toggleCommandPin:
            commandPinned.toggle()
        case .timer(let t):
            switch t {
            case .hoverIn: if hovering && surface == .compact { hoverExpanded = true }
            case .hoverOut:
                if !hovering {
                    hoverExpanded = false
                    if interacted { attentionPinned = false; interacted = false }
                }
            case .flash: flashing = false
            case .clickGuard: guarding = false
            }
        }
        if surface == .hidden { hoverExpanded = false; flashing = false }
        return fx
    }
}
```
- [ ] **Step 4: Run to verify pass**

Run the `NotchStatusStateTests` command. Expected: PASS. If a test fails, fix the code, not the test.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notch/NotchStatusState.swift ConduitMacTests/NotchStatusStateTests.swift
git commit -m "macOS notch: state machine (hover, sticky approvals, flash, click guard, modes)"
```

---

### Task 5: Panel host and MacFloatingPanel capabilities

**Files:**
- Create: `ConduitMac/Notch/NotchPanelHost.swift`
- Modify (only members the probe shows missing): `ConduitMac/Panels/MacFloatingPanel.swift`
- Test: `ConduitMacTests/NotchPanelHostTests.swift`

**Interfaces:**
- Consumes: `MacFloatingPanelConfig`, `MacFloatingPanelPlacement.custom`, `MacFloatingPanelController(config:content:)` (shared base).
- Produces:
  - `@MainActor protocol NotchPanelHosting: AnyObject { var isVisible: Bool { get }; var onPointerChange: ((Bool) -> Void)? { get set }; func show(); func hide(); func setFrame(_ frame: CGRect, animated: Bool) }`
  - `@MainActor final class NotchPanelHost: NotchPanelHosting` with `init<Content: View>(content: Content)`; the content is supplied by the controller (Task 8).
  - Additive members on the shared panel, only if missing: `constrainFrameRect(_:to:)` returning the rect unchanged; `setFrame(_:animated:)` on the controller (width and height, top fixed by the caller); `onPointerChange` driven by an `NSTrackingArea` with `.activeAlways`; rounded hit test.

- [ ] **Step 1: Probe the shared panel against the five gaps the spec lists**

Run `sed -n 1,400p ConduitMac/Panels/MacFloatingPanel.swift` and answer each question in a scratch note: (1) does it override `constrainFrameRect(_:to:)` to return the rect unchanged? (2) can the controller set a full frame (width and height) after show, animated? (3) are there mouse entered/exited callbacks from an `.activeAlways` tracking area? (4) is hit testing limited to a shape? (5) does `show()` use `orderFrontRegardless` and never activate, and is `hide()` an `orderOut`? Record the controller's accessor for the panel (`controller.panel` or similar). Only the missing ones are implemented in Step 4.

- [ ] **Step 2: Write the failing tests**

All use an offscreen frame (`x: -30000`) and never call `NSApp.activate`.

```swift
import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class NotchPanelHostTests: XCTestCase {
    private let offscreen = CGRect(x: -30000, y: -30000, width: 300, height: 32)

    private func makeHost() -> NotchPanelHost {
        NotchPanelHost(content: Color.black.frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    func testPanelIsNonActivatingNonKeyStatusLevelAndJoinsAllSpaces() {
        let host = makeHost(); defer { host.hide() }
        let panel = host.panelForTesting
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testShowDoesNotActivateTheAppAndHideLeavesNoWindowOnScreen() {
        let host = makeHost()
        host.setFrame(offscreen, animated: false)
        let wasActive = NSApp.isActive
        host.show()
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(NSApp.isActive, wasActive)
        host.hide()
        XCTAssertFalse(host.isVisible)
        XCTAssertFalse(host.panelForTesting.isVisible)
    }

    func testSetFrameMovesAndResizesBothWidthAndHeightWithTheTopEdgeAsGiven() {
        let host = makeHost(); defer { host.hide() }
        host.setFrame(offscreen, animated: false)
        host.show()
        let big = CGRect(x: -30000, y: -30300, width: 380, height: 332)
        host.setFrame(big, animated: false)
        XCTAssertEqual(host.panelForTesting.frame, big)
    }

    func testPanelMayOverlapTheMenuBarBand() {
        let host = makeHost(); defer { host.hide() }
        let screen = NSScreen.screens[0]
        let top = CGRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 32, width: 200, height: 32)
        host.setFrame(top, animated: false)
        host.panelForTesting.orderFrontRegardless()
        XCTAssertEqual(host.panelForTesting.frame.maxY, screen.frame.maxY, "AppKit must not push it below the menu bar")
    }

    func testPointerEnterAndExitReachTheCallbackWithoutActivation() {
        let host = makeHost(); defer { host.hide() }
        host.setFrame(offscreen, animated: false)
        host.show()
        var events: [Bool] = []
        host.onPointerChange = { events.append($0) }
        host.simulatePointerForTesting(inside: true)
        host.simulatePointerForTesting(inside: false)
        XCTAssertEqual(events, [true, false])
    }

    func testHitTestIgnoresTheClearCornersOfTheRoundedShape() {
        let host = makeHost(); defer { host.hide() }
        host.setFrame(CGRect(x: -30000, y: -30000, width: 200, height: 100), animated: false)
        host.show()
        XCTAssertNil(host.hitTestForTesting(CGPoint(x: 1, y: 1)), "bottom-left corner of the rounded shape")
        XCTAssertNotNil(host.hitTestForTesting(CGPoint(x: 100, y: 50)))
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run the `NotchPanelHostTests` command. Expected: FAIL, `cannot find 'NotchPanelHost'`.

- [ ] **Step 4: Implement the host (and the missing panel members)**

```swift
import AppKit
import SwiftUI

@MainActor
protocol NotchPanelHosting: AnyObject {
    var isVisible: Bool { get }
    var onPointerChange: ((Bool) -> Void)? { get set }
    func show()
    func hide()
    func setFrame(_ frame: CGRect, animated: Bool)
}

/// Wraps the shared `MacFloatingPanelController`. Frames come from
/// `NotchGeometry` (via `.custom` placement), so notch and pill share one path;
/// `.notchAnchored` would only cover the expanded notch case.
@MainActor
final class NotchPanelHost: NotchPanelHosting {
    var onPointerChange: ((Bool) -> Void)?
    private var frame = CGRect(x: 0, y: 0, width: NotchMetrics.expandedWidth, height: NotchMetrics.pillHeight)
    private let controller: MacFloatingPanelController

    init<Content: View>(content: Content) {
        var config = MacFloatingPanelConfig(
            size: frame.size, placement: .custom { _ in .zero },
            canBecomeKey: false, dismissOnResignKey: false)
        config.dismissOnEscape = false
        config.level = .statusBar
        config.joinsAllSpaces = true
        controller = MacFloatingPanelController(config: config) { content }
        // Replace the placeholder closure now that `self` exists.
        controller.updatePlacement(.custom { [weak self] _ in self?.frame ?? .zero })
        controller.onPointerChange = { [weak self] inside in self?.onPointerChange?(inside) }
    }

    var isVisible: Bool { controller.isVisible }
    func show() { controller.show() }
    func hide() { controller.hide() }

    func setFrame(_ new: CGRect, animated: Bool) {
        frame = new
        guard controller.isVisible else { return }
        controller.setFrame(new, animated: animated)
    }

    // Test seams.
    var panelForTesting: NSPanel { controller.panel }
    func simulatePointerForTesting(inside: Bool) { controller.simulatePointerForTesting(inside: inside) }
    func hitTestForTesting(_ p: CGPoint) -> NSView? { controller.hitTestForTesting(p) }
}
```
Names `updatePlacement`, `onPointerChange`, `setFrame`, `panel`, `simulatePointerForTesting`, `hitTestForTesting` on `MacFloatingPanelController` are the additive members. For each one the Step 1 probe found missing, add it to `ConduitMac/Panels/MacFloatingPanel.swift`:
- In `MacFloatingPanel`: `override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }` (only when `config.allowsMenuBarOverlap`, a new `Bool = false` on `MacFloatingPanelConfig`; the notch config sets it `true`, so Quick Ask is unaffected).
- `setFrame(_:animated:)` on the controller: `panel.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)`.
- Pointer: install `NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: trackingView, userInfo: nil)` on a thin `NSView` subclass that forwards `mouseEntered`/`mouseExited` to `onPointerChange`; `simulatePointerForTesting` calls the same forwarder.
- Hit shape: a container `NSView` subclass `NotchHitContainer` set as `panel.contentView` (the hosting view becomes its subview) whose `hitTest(_:)` returns nil when the point is outside `CGPath(roundedRect:cornerWidth:cornerHeight:)` with the 14 pt bottom-corner radius. Gate by `config.hitTestsRoundedShape` (default false).
Existing Quick Ask panel tests must still pass: run `xcodebuild ... test -only-testing:'ConduitMacTests/MacFloatingPanelTests'` (use the real class names from `ls ConduitMacTests | grep -i panel`).

- [ ] **Step 5: Run to verify pass**

Run `NotchPanelHostTests` plus the existing panel test classes. Expected: PASS. If a probe answer in Step 1 was "already present", skip that member and keep its test: the test is the contract.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/Notch/NotchPanelHost.swift ConduitMac/Panels/MacFloatingPanel.swift ConduitMacTests/NotchPanelHostTests.swift
git commit -m "macOS notch: panel host, additive MacFloatingPanel capabilities"
```
Add any other test file you touched to the `git add`, by explicit path.

---

### Task 6: View model, palette, views

**Files:**
- Create: `ConduitMac/Notch/NotchPalette.swift`, `ConduitMac/Notch/NotchStatusViewModel.swift`, `ConduitMac/Notch/NotchStatusView.swift`, `ConduitMac/Notch/NotchStatusRowView.swift`
- Test: `ConduitMacTests/NotchStatusViewTests.swift`

**Interfaces:**
- Consumes: `NotchRowList`, `NotchRow`, `NotchCompactLabel`, `NotchSurface`, `NotchAvailability`, `NotchPlacement`.
- Produces:
  - `enum NotchPalette` (sRGB tuples and `Color`s: `surface` black, `text` white, `secondary`, `attention` amber, `failure` red) plus `static func contrast(_ a: (r: Double, g: Double, b: Double), _ b: ...) -> Double`
  - `enum NotchMotion { static func animation(reduceMotion: Bool) -> Animation }`
  - `@MainActor final class NotchStatusViewModel: ObservableObject` with `@Published` `surface`, `list`, `availability`, `buttonsEnabled`, `newChatEnabled`, `placement`, `contentHeight`, `submitting: Set<String>`, `failedRows: Set<String>`, `errorMessage`; closures `onOpenRow(NotchRow)`, `onChoose(NotchRow, String)`, `onDismissRow(String)`, `onNewChat()`, `onOpenConduit()`, `onOpenCron()`, `onOpenMore()`; computed `accessibilitySummary: String`
  - `struct NotchStatusView: View` (init takes the view model)

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class NotchStatusViewTests: XCTestCase {
    typealias F = NotchFixtures

    private func model(_ items: [AgentActivityItem], surface: NotchSurface = .expanded,
                       availability: NotchAvailability = .live) -> NotchStatusViewModel {
        let m = NotchStatusViewModel()
        m.list = NotchRowBuilder.build(items: items, now: F.t0)
        m.surface = surface
        m.availability = availability
        m.buttonsEnabled = true
        return m
    }

    private func labels(of view: NSView) -> [String] {
        var out: [String] = []
        func walk(_ element: Any) {
            if let e = element as? NSAccessibilityElementProtocol, let l = (element as AnyObject).accessibilityLabel?(), !l.isEmpty { out.append(l) }
            for c in ((element as AnyObject).accessibilityChildren?() as? [Any]) ?? [] { walk(c) }
        }
        walk(view)
        return out
    }

    private func render(_ m: NotchStatusViewModel, dark: Bool) -> NSWindow {
        let w = HostedTestSupport.host(NotchStatusView(model: m), size: NSSize(width: 380, height: 360))
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        HostedTestSupport.settle()
        return w
    }

    func testExpandedRowsRenderInLightAndDark() {
        let items = [F.approvalItem("approval:q", session: "s1"), F.item("turn:a", title: "Refactor"), F.item("turn:b", title: "Docs", detail: "Running terminal")]
        for dark in [false, true] {
            let w = render(model(items), dark: dark); defer { HostedTestSupport.tearDown(w) }
            let l = labels(of: w.contentView!)
            XCTAssertTrue(l.contains { $0.contains("Deploy") }, "approval row title (dark: \(dark))")
            XCTAssertTrue(l.contains(AppLocalization.string("Allow once")))
            XCTAssertTrue(l.contains(AppLocalization.string("Deny")))
        }
    }

    func testAlwaysAllowIsNotAnInlineButton() {
        let w = render(model([F.approvalItem("approval:q", session: "s1")]), dark: true); defer { HostedTestSupport.tearDown(w) }
        XCTAssertFalse(labels(of: w.contentView!).contains(AppLocalization.string("Always allow")), "menu-only: not visible until the menu opens")
    }

    func testClarifyRowShowsAnswerInConduitAndNoButtons() {
        let w = render(model([F.item("clarify:c", kind: .clarify, state: .needsUser, title: "Which env?")]), dark: false); defer { HostedTestSupport.tearDown(w) }
        let l = labels(of: w.contentView!)
        XCTAssertTrue(l.contains(AppLocalization.string("Answer in Conduit")))
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

    func testMoreRowAppearsWhenRowsOverflow() {
        let items = (0..<9).map { F.item("turn:\($0)", session: "s\($0)") }
        let w = render(model(items), dark: true); defer { HostedTestSupport.tearDown(w) }
        XCTAssertTrue(labels(of: w.contentView!).contains { $0.contains("+3") })
    }

    func testCompactStateRendersInBothAppearances() {
        let m = model([F.item("turn:a", detail: "Running terminal")], surface: .compact)
        for dark in [false, true] {
            let w = render(m, dark: dark); defer { HostedTestSupport.tearDown(w) }
            XCTAssertTrue(labels(of: w.contentView!).contains { $0.contains("Agent status") })
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

    func testIconOnlyDismissButtonHasALabel() {
        let item = F.item("turn:a", state: .finished(.completed))
        let w = render(model([item]), dark: true); defer { HostedTestSupport.tearDown(w) }
        XCTAssertTrue(labels(of: w.contentView!).contains(AppLocalization.string("Dismiss")))
    }
}
```
If SwiftUI does not expose a label in the AX walk, expose it with `.accessibilityElement(children: .contain)` plus `.accessibilityLabel` on the row container; do not delete the assertion.

- [ ] **Step 2: Run to verify failure**

Run the `NotchStatusViewTests` command. Expected: FAIL, `cannot find 'NotchStatusViewModel'`.

- [ ] **Step 3: Implement palette and motion**

```swift
import SwiftUI

enum NotchPalette {
    typealias RGB = (r: Double, g: Double, b: Double)
    static let surfaceRGB: RGB = (0, 0, 0)               // black blends into the notch; same in light and dark
    static let textRGB: RGB = (1, 1, 1)
    static let secondaryRGB: RGB = (0.78, 0.78, 0.80)
    static let attentionRGB: RGB = (1.0, 0.78, 0.20)
    static let failureRGB: RGB = (1.0, 0.45, 0.42)

    static func color(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
    static var surface: Color { color(surfaceRGB) }
    static var text: Color { color(textRGB) }
    static var secondary: Color { color(secondaryRGB) }
    static var attention: Color { color(attentionRGB) }
    static var failure: Color { color(failureRGB) }

    /// WCAG relative-luminance contrast ratio.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func lum(_ c: RGB) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }
        let (hi, lo) = (max(lum(a), lum(b)), min(lum(a), lum(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}

enum NotchMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.82)
    }
}
```

- [ ] **Step 4: Implement the view model**

```swift
import Combine
import Foundation

@MainActor
final class NotchStatusViewModel: ObservableObject {
    enum EmptyState: Equatable { case noAgents, disconnected }

    @Published var surface: NotchSurface = .hidden
    @Published var list: NotchRowList = .empty
    @Published var availability: NotchAvailability = .live
    @Published var buttonsEnabled = true
    @Published var newChatEnabled = true
    @Published var placement: NotchPlacement = .pill
    @Published var contentHeight: CGFloat = 0
    @Published var submitting: Set<String> = []
    @Published var failedRows: Set<String> = []

    var onOpenRow: (NotchRow) -> Void = { _ in }
    var onChoose: (NotchRow, String) -> Void = { _, _ in }
    var onDismissRow: (String) -> Void = { _ in }
    var onNewChat: () -> Void = {}
    var onOpenConduit: () -> Void = {}
    var onOpenCron: () -> Void = {}
    var onOpenMore: () -> Void = {}

    var emptyState: EmptyState { availability == .offline ? .disconnected : .noAgents }
    var showsEventsOnlyNote: Bool { availability == .eventsOnly }

    func canChoose(rowID: String) -> Bool { buttonsEnabled && !submitting.contains(rowID) }

    var compactLabel: NotchCompactLabel { NotchCompactLabel.make(counts: list.counts, items: list.rows) }

    /// "Agent status: 2 working, 1 need you" (one count per key, joined in code).
    var accessibilitySummary: String {
        var parts: [String] = []
        let c = list.counts
        let workingOnly = c.working
        if workingOnly > 0 { parts.append(AppLocalization.string("\(workingOnly) working")) }
        if c.needsUser > 0 { let n = c.needsUser; parts.append(AppLocalization.string("\(n) need you")) }
        let body = parts.isEmpty ? AppLocalization.string("idle") : parts.joined(separator: ", ")
        return AppLocalization.string("Agent status: \(body)")
    }
}
```
`AppLocalization.string` must accept interpolation the way the repo's other call sites do. Check one existing plural call site first (`grep -rn "AppLocalization.string(\"\\\\(" Conduit | head -3`) and copy its form; if it is `AppLocalization.string("%lld working", count)` use that.

- [ ] **Step 5: Implement the views**

`NotchStatusView.swift`:
```swift
import SwiftUI

struct NotchStatusView: View {
    @ObservedObject var model: NotchStatusViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.surface {
            case .hidden: Color.clear
            case .compact: compact
            case .expanded: expanded
            }
        }
        .foregroundStyle(NotchPalette.text)
        .environment(\.colorScheme, .dark)
        .animation(NotchMotion.animation(reduceMotion: reduceMotion), value: model.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilitySummary)
    }

    // MARK: compact

    private var compact: some View {
        HStack(spacing: 0) {
            mark.frame(width: NotchMetrics.leftWing)
            if model.placement.notchWidth > 0 { Spacer(minLength: model.placement.notchWidth) }
            compactText.frame(maxWidth: .infinity, alignment: model.placement.notchWidth > 0 ? .leading : .center).padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchPalette.surface, in: shape)
    }

    private var mark: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "sparkle")
                .symbolEffect(.pulse, isActive: model.list.counts.working > 0 && !reduceMotion)
            if model.list.counts.needsUser > 0 {
                Circle().fill(NotchPalette.attention).frame(width: 7, height: 7).offset(x: 3, y: -2)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var compactText: some View {
        switch model.compactLabel {
        case .needYou(let n): Text("\(n) need you").foregroundStyle(NotchPalette.attention)
        case .tool(let name): Text(name).lineLimit(1)
        case .working(let n): Text("\(n) working")
        case .done: Text("Done")
        case .none: EmptyView()
        }
    }

    // MARK: expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: model.placement.notchHeight)   // beside the notch the wings stay empty
            if model.list.rows.isEmpty { emptyState } else { rows }
            if model.list.overflow > 0 {
                Button { model.onOpenMore() } label: { Text("+\(model.list.overflow) more") }
                    .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 6)
                    .foregroundStyle(NotchPalette.secondary)
            }
            Divider().overlay(NotchPalette.secondary.opacity(0.3))
            footer
        }
        .padding(.bottom, 8)
        .frame(width: NotchMetrics.expandedWidth, alignment: .top)
        .background(NotchPalette.surface, in: shape)
        .background(GeometryReader { g in Color.clear.preference(key: NotchHeightKey.self, value: g.size.height) })
        .onPreferenceChange(NotchHeightKey.self) { model.contentHeight = $0 }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.list.rows.enumerated()), id: \.element.id) { index, row in
                if index == 0 || model.list.rows[index - 1].section != row.section {
                    sectionHeader(row.section)
                }
                NotchStatusRowView(row: row, model: model)
            }
        }
    }

    private func sectionHeader(_ s: NotchRow.Section) -> some View {
        Group {
            switch s {
            case .needsYou: Text("Needs you")
            case .working: Text("Working")
            case .done: Text("Done")
            }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(NotchPalette.secondary)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.emptyState {
            case .disconnected:
                Text("Not connected to Hermes").font(.callout.weight(.semibold))
            case .noAgents:
                Text("No agents running").font(.callout.weight(.semibold))
                Text("Chats started from the CLI, Slack or another app are not shown here.")
                    .font(.caption).foregroundStyle(NotchPalette.secondary)
            }
            if model.showsEventsOnlyNote {
                Text("Only chats opened in Conduit are tracked right now.")
                    .font(.caption).foregroundStyle(NotchPalette.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cron = model.list.cron {
                Button { model.onOpenCron() } label: {
                    Text("Next cron: \(cron.title), \(NotchRelativeTime.string(for: cron.at))")
                        .font(.caption).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                }.buttonStyle(.plain)
            }
            HStack {
                Button { model.onNewChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .disabled(!model.newChatEnabled)
                Spacer()
                Button { model.onOpenConduit() } label: { Text("Open Conduit") }
            }
            .buttonStyle(.plain).font(.callout)
        }
        .padding(.horizontal, 14).padding(.top, 8)
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
    }
}

private struct NotchHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum NotchRelativeTime {
    static func string(for date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLocalization.formattingLocale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}
```

`NotchStatusRowView.swift`:
```swift
import SwiftUI

struct NotchStatusRowView: View {
    let row: NotchRow
    @ObservedObject var model: NotchStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.callout.weight(.medium)).lineLimit(1)
                    if let detail = row.detail, !isApproval {
                        Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if row.canDismiss {
                    Button { model.onDismissRow(row.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("Dismiss"))
                }
            }
            inline
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.onOpenRow(row) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.title)
    }

    private var isApproval: Bool { if case .approval = row.inline { true } else { false } }

    private var detailColor: Color { row.tone == .failed ? NotchPalette.failure : NotchPalette.secondary }

    private var statusDot: some View {
        Group {
            switch (row.section, row.tone) {
            case (.done, .failed): Image(systemName: "xmark.circle.fill").foregroundStyle(NotchPalette.failure)
            case (.done, _): Image(systemName: "checkmark.circle.fill").foregroundStyle(NotchPalette.secondary)
            case (.needsYou, _): Circle().fill(NotchPalette.attention).frame(width: 8, height: 8)
            default: ProgressView().controlSize(.mini)
            }
        }.accessibilityHidden(true)
    }

    @ViewBuilder private var inline: some View {
        switch row.inline {
        case .none: EmptyView()
        case .answerInConduit:
            Text("Answer in Conduit").font(.caption).foregroundStyle(NotchPalette.attention)
        case .openToAnswer:
            Text("Open in Conduit to answer").font(.caption).foregroundStyle(NotchPalette.attention)
        case .approval(let choices, let command):
            VStack(alignment: .leading, spacing: 6) {
                Text(command).font(.system(.caption, design: .monospaced)).lineLimit(2)
                    .foregroundStyle(NotchPalette.secondary)
                if model.failedRows.contains(row.id) {
                    Text("Couldn't send. Open in Conduit.").font(.caption).foregroundStyle(NotchPalette.failure)
                }
                HStack(spacing: 8) {
                    if choices.once { button("Allow once", .once) }
                    if choices.deny { button("Deny", .deny) }
                    if choices.session || choices.always {
                        Menu {
                            if choices.session { Button("Allow for session") { model.onChoose(row, "session") } }
                            if choices.always { Button("Always allow") { model.onChoose(row, "always") } }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(!model.canChoose(rowID: row.id))
                        .accessibilityLabel(AppLocalization.string("More options"))
                    }
                }
            }
        }
    }

    private enum Kind { case once, deny }

    private func button(_ title: LocalizedStringKey, _ kind: Kind) -> some View {
        Button(title) { model.onChoose(row, kind == .once ? "once" : "deny") }
            .buttonStyle(.bordered)
            .tint(kind == .deny ? NotchPalette.failure : NotchPalette.attention)
            .disabled(!model.canChoose(rowID: row.id))   // 600 ms click guard; no .defaultAction binding
    }
}
```

- [ ] **Step 6: Run to verify pass**

Run the `NotchStatusViewTests` command. Expected: PASS. Then `grep -n "keyboardShortcut\|defaultAction" ConduitMac/Notch/*.swift` must print nothing (no default-key binding anywhere).

- [ ] **Step 7: Commit**

```bash
git add ConduitMac/Notch/NotchPalette.swift ConduitMac/Notch/NotchStatusViewModel.swift ConduitMac/Notch/NotchStatusView.swift ConduitMac/Notch/NotchStatusRowView.swift ConduitMacTests/NotchStatusViewTests.swift
git commit -m "macOS notch: view model, palette and views (rows, inline approvals, empty and disconnected states)"
```

---

### Task 7: Actions, scheduler, dismiss monitor, wiring, command

**Files:**
- Create: `ConduitMac/Notch/NotchActions.swift`, `ConduitMac/Notch/NotchTimerScheduling.swift`, `ConduitMac/Notch/NotchDismissMonitor.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift`, `ConduitMac/App/ConduitCommands.swift` (and any `ConduitCommands(` call site found by `grep -rn "ConduitCommands(" ConduitMac ConduitMacTests`)
- Test: add to `ConduitMacTests/NotchStatusControllerTests.swift` (created here, extended in Task 8)

**Interfaces:**
- Produces:
  - `struct NotchActions { var openSession: (String) -> Void; var openPane: (SidebarTab) -> Void; var newChat: () -> Void; var newChatEnabled: () -> Bool; var openConduit: () -> Void; static func live(appState: AppState) -> NotchActions }`
  - `enum NotchMainWindow { @MainActor static func bringToFront() }` (reuse the shared base's helper if Task 1 Step 1 found one; then this enum just forwards)
  - `@MainActor protocol NotchTimerScheduling { func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void }`, `struct TaskTimerScheduler: NotchTimerScheduling`
  - `@MainActor protocol NotchDismissMonitoring: AnyObject { func start(onDismiss: @escaping () -> Void, isOwnWindow: @escaping (NSWindow?) -> Bool); func stop() }`, `final class NotchDismissMonitor: NotchDismissMonitoring`
  - `ConduitCommands` gains `@ObservedObject var notch: NotchStatusController` and a Go-menu item "Show Agent Status" / "Hide Agent Status" with no key equivalent.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class NotchActionsTests: XCTestCase {
    func testOpenPaneWritesTheSidebarTabKey() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        NotchActions.selectPane(.kanban, defaults: s.defaults)
        XCTAssertEqual(s.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
        NotchActions.selectPane(.cron, defaults: s.defaults)
        XCTAssertEqual(s.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.cron.rawValue)
    }

    func testTaskSchedulerFiresOnceAndCancels() async {
        let scheduler = TaskTimerScheduler()
        var fired = 0
        let cancel = scheduler.schedule(after: 0.01) { fired += 1 }
        _ = cancel
        XCTAssertTrue(HostedTestSupport.waitUntil { fired == 1 })
        var cancelledFired = 0
        let cancel2 = scheduler.schedule(after: 0.05) { cancelledFired += 1 }
        cancel2()
        HostedTestSupport.settle(0.15)
        XCTAssertEqual(cancelledFired, 0)
    }
}
```
(The `ConduitCommands` change is exercised by the existing `MacSessionTabsCommandsTests`/keyboard menu tests compiling and passing; Task 8 tests the toggle.)

- [ ] **Step 2: Run to verify failure**

Run the `NotchActionsTests` command. Expected: FAIL, `cannot find 'NotchActions'`.

- [ ] **Step 3: Implement**

`NotchActions.swift`:
```swift
import AppKit

enum NotchMainWindow {
    /// Same route `applicationShouldHandleReopen` uses; the notch panel itself
    /// cannot become main, so `canBecomeMain` picks the real window.
    @MainActor static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

struct NotchActions {
    var openSession: (String) -> Void
    var openPane: (SidebarTab) -> Void
    var newChat: () -> Void
    var newChatEnabled: () -> Bool
    var openConduit: () -> Void

    @MainActor static func selectPane(_ tab: SidebarTab, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
    }

    @MainActor static func live(appState: AppState) -> NotchActions {
        NotchActions(
            openSession: { id in
                NotchMainWindow.bringToFront()
                _ = appState.requestOpenSession(id)   // resumes the session; adds Conduit as a viewer
            },
            openPane: { tab in
                NotchMainWindow.bringToFront()
                selectPane(tab)
            },
            newChat: {
                guard !appState.macNewChatDisabled else { return }
                NotchMainWindow.bringToFront()
                Task { await appState.createNewSession() }
            },
            newChatEnabled: { !appState.macNewChatDisabled },
            openConduit: { NotchMainWindow.bringToFront() })
    }
}
```

`NotchTimerScheduling.swift`:
```swift
import Foundation

@MainActor
protocol NotchTimerScheduling {
    /// Returns a cancel closure.
    func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void
}

struct TaskTimerScheduler: NotchTimerScheduling {
    func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(after)) } catch { return }
            fire()
        }
        return { task.cancel() }
    }
}
```

`NotchDismissMonitor.swift`:
```swift
import AppKit

@MainActor
protocol NotchDismissMonitoring: AnyObject {
    func start(onDismiss: @escaping () -> Void, isOwnWindow: @escaping (NSWindow?) -> Bool)
    func stop()
}

/// Click outside and Esc. Mouse events from other apps need no permission
/// (`addGlobalMonitorForEvents` only gates key events). The panel is not key,
/// so Esc is only seen while Conduit is the active app (local monitor).
@MainActor
final class NotchDismissMonitor: NotchDismissMonitoring {
    private var global: Any?
    private var local: Any?

    func start(onDismiss: @escaping () -> Void, isOwnWindow: @escaping (NSWindow?) -> Bool) {
        stop()
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in onDismiss() }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { onDismiss() }   // Esc
            } else if !isOwnWindow(event.window) {
                onDismiss()
            }
            return event
        }
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil
    }
}
```

`ConduitMacApp.swift`: in `rootContent`, next to `.task { MacSessionTabsStore.shared.bind(to: appState) }` add
```swift
            .task { NotchStatusController.shared.bind(to: appState) }
```
and change `.commands { ... }` to pass `notch: .shared`. `ConduitCommands.swift`: add `@ObservedObject var notch: NotchStatusController` after `tabs`, and in the `CommandMenu("Go")` after the session navigation block (before "Message Field"):
```swift
            Divider()
            Button(notch.isCommandPinned ? "Hide Agent Status" : "Show Agent Status") { notch.toggleCommandPin() }
```
No `keyboardShortcut` (nothing to clash with). Update every other `ConduitCommands(` call site the grep finds.

- [ ] **Step 4: Run to verify pass**

`NotchStatusController` does not exist yet, so the build fails at the wiring. Do Steps 3's `NotchActions`, scheduler and monitor first, run `NotchActionsTests` (PASS), and add the `ConduitMacApp` / `ConduitCommands` edits as the last action of Task 8 Step 4, after the controller exists. Record this ordering in the commit.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notch/NotchActions.swift ConduitMac/Notch/NotchTimerScheduling.swift ConduitMac/Notch/NotchDismissMonitor.swift ConduitMacTests/NotchStatusControllerTests.swift
git commit -m "macOS notch: actions, timer scheduler, dismiss monitor"
```

---

### Task 8: Controller, wiring, command

**Files:**
- Create: `ConduitMac/Notch/NotchStatusController.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift`, `ConduitMac/App/ConduitCommands.swift`
- Test: `ConduitMacTests/NotchStatusControllerTests.swift` (extend)

**Interfaces:**
- Consumes: everything above.
- Produces: `@MainActor final class NotchStatusController: ObservableObject` with `static let shared`, `@Published private(set) var isCommandPinned: Bool`, `let viewModel: NotchStatusViewModel`, `init(settings:actions:makeHost:screen:scheduler:monitor:now:)`, `func bind(to appState: AppState)`, `func bind(source: NotchActivitySource, actions: NotchActions)`, `func toggleCommandPin()`, `func screenParametersChanged()`.

- [ ] **Step 1: Write the failing tests** (append to `NotchStatusControllerTests.swift`)

```swift
import Combine
import XCTest
@testable import ConduitMac

@MainActor
final class FakeNotchSource: NotchActivitySource {
    let itemsSubject = CurrentValueSubject<[AgentActivityItem], Never>([])
    let availabilitySubject = CurrentValueSubject<NotchAvailability, Never>(.live)
    var responses: [(id: String, choice: String)] = []
    var result: NotchRespondResult = .resolved
    var dismissed: [String] = []
    var items: [AgentActivityItem] { itemsSubject.value }
    var itemsPublisher: AnyPublisher<[AgentActivityItem], Never> { itemsSubject.eraseToAnyPublisher() }
    var availability: NotchAvailability { availabilitySubject.value }
    var availabilityPublisher: AnyPublisher<NotchAvailability, Never> { availabilitySubject.eraseToAnyPublisher() }
    func respond(to id: String, choice: String) async -> NotchRespondResult { responses.append((id, choice)); return result }
    func dismiss(_ id: String) { dismissed.append(id) }
}

@MainActor
final class FakeNotchHost: NotchPanelHosting {
    var isVisible = false
    var onPointerChange: ((Bool) -> Void)?
    var frames: [CGRect] = []
    var showCount = 0, hideCount = 0
    func show() { isVisible = true; showCount += 1 }
    func hide() { isVisible = false; hideCount += 1 }
    func setFrame(_ frame: CGRect, animated: Bool) { frames.append(frame) }
}

@MainActor
final class FakeScheduler: NotchTimerScheduling {
    struct Entry { var after: TimeInterval; var fire: @MainActor () -> Void; var cancelled = false }
    var entries: [Entry] = []
    func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        entries.append(Entry(after: after, fire: fire))
        let i = entries.count - 1
        return { [unowned self] in entries[i].cancelled = true }
    }
    /// Fires the newest uncancelled timer with this delay.
    func fire(after: TimeInterval) {
        guard let i = entries.lastIndex(where: { $0.after == after && !$0.cancelled }) else { return }
        entries[i].cancelled = true
        entries[i].fire()
    }
}

@MainActor
final class FakeMonitor: NotchDismissMonitoring {
    var started = 0, stopped = 0
    var onDismiss: (() -> Void)?
    func start(onDismiss: @escaping () -> Void, isOwnWindow: @escaping (NSWindow?) -> Bool) { started += 1; self.onDismiss = onDismiss }
    func stop() { stopped += 1 }
}

@MainActor
final class NotchStatusControllerTests: XCTestCase {
    typealias F = NotchFixtures

    private struct Rig {
        let controller: NotchStatusController
        let source: FakeNotchSource
        let host: FakeNotchHost
        let scheduler: FakeScheduler
        let monitor: FakeMonitor
        var opened: Box<[String]>, panes: Box<[SidebarTab]>, newChats: Box<Int>
        var screen: Box<NotchScreenMetrics?>
        var newChatEnabled: Box<Bool>
        let suite: (defaults: UserDefaults, name: String)
        var now: Box<Date>
    }
    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private let notchScreen = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32, auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 659, height: 32),
        auxiliaryTopRight: CGRect(x: 853, y: 950, width: 659, height: 32))
    private let externalScreen = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0, auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero)

    private func makeRig(mode: NotchMode = .activeAgents) -> Rig {
        let suite = HostedTestSupport.makeSuite()
        suite.defaults.set(mode.rawValue, forKey: NotchStatusSettings.key)
        let source = FakeNotchSource(), host = FakeNotchHost(), scheduler = FakeScheduler(), monitor = FakeMonitor()
        let opened = Box<[String]>([]), panes = Box<[SidebarTab]>([]), newChats = Box(0)
        let screen = Box<NotchScreenMetrics?>(notchScreen), enabled = Box(true), now = Box(F.t0)
        let actions = NotchActions(
            openSession: { opened.value.append($0) }, openPane: { panes.value.append($0) },
            newChat: { newChats.value += 1 }, newChatEnabled: { enabled.value }, openConduit: {})
        let controller = NotchStatusController(
            settings: NotchStatusSettings(defaults: suite.defaults), actions: actions,
            makeHost: { host }, screen: { screen.value }, scheduler: scheduler, monitor: monitor, now: { now.value })
        controller.bind(source: source, actions: actions)
        return Rig(controller: controller, source: source, host: host, scheduler: scheduler, monitor: monitor,
                   opened: opened, panes: panes, newChats: newChats, screen: screen, newChatEnabled: enabled, suite: suite, now: now)
    }

    private func finish(_ r: Rig) { HostedTestSupport.dropSuite(r.suite) }

    func testIdleStaysHiddenAndNeverShowsThePanel() {
        let r = makeRig(); defer { finish(r) }
        XCTAssertFalse(r.host.isVisible)
        XCTAssertEqual(r.host.showCount, 0)
    }

    func testWorkingShowsCompactAtTheNotchFrame() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertTrue(r.host.isVisible)
        XCTAssertEqual(r.host.frames.last, NotchGeometry.compactFrame(NotchGeometry.placement(for: notchScreen), in: notchScreen, contentWidth: 0))
    }

    func testStartupBaselineWithAPendingApprovalDoesNotAutoExpand() {
        let rig = makeRig(); defer { finish(rig) }
        rig.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])   // first emission is the baseline
        XCTAssertEqual(rig.controller.viewModel.surface, .compact)
    }

    func testNewApprovalExpandsAndGuardsThenEnablesButtons() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a", session: "s")])
        r.source.itemsSubject.send([F.item("turn:a", session: "s"), F.approvalItem("approval:q", session: "s")])
        XCTAssertEqual(r.controller.viewModel.surface, .expanded)
        XCTAssertFalse(r.controller.viewModel.buttonsEnabled)
        XCTAssertEqual(r.monitor.started, 1)
        r.scheduler.fire(after: 0.6)
        XCTAssertTrue(r.controller.viewModel.buttonsEnabled)
    }

    func testChoosingRoutesThroughTheFeedAndMarksInteraction() async {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.scheduler.fire(after: 0.6)
        let row = r.controller.viewModel.list.rows[0]
        r.controller.viewModel.onChoose(row, "once")
        XCTAssertTrue(HostedTestSupport.waitUntil { !r.source.responses.isEmpty })
        XCTAssertEqual(r.source.responses.first?.id, "approval:q")
        XCTAssertEqual(r.source.responses.first?.choice, "once")
        XCTAssertTrue(HostedTestSupport.waitUntil { r.controller.viewModel.submitting.isEmpty })
        XCTAssertTrue(r.controller.viewModel.failedRows.isEmpty)
    }

    func testChoosingDuringTheClickGuardIsIgnored() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.controller.viewModel.onChoose(r.controller.viewModel.list.rows[0], "once")
        HostedTestSupport.settle(0.05)
        XCTAssertTrue(r.source.responses.isEmpty)
    }

    func testFailedRespondShowsRowErrorAndReenablesButtons() async {
        let r = makeRig(); defer { finish(r) }
        r.source.result = .failed("boom")
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.scheduler.fire(after: 0.6)
        r.controller.viewModel.onChoose(r.controller.viewModel.list.rows[0], "deny")
        XCTAssertTrue(HostedTestSupport.waitUntil { r.controller.viewModel.failedRows.contains("approval:q") })
        XCTAssertTrue(r.controller.viewModel.canChoose(rowID: "approval:q"))
    }

    func testAnsweredElsewhereRacesWithoutAnErrorAndTheRowGoes() async {
        let r = makeRig(); defer { finish(r) }
        r.source.result = .alreadyResolved
        r.source.itemsSubject.send([])
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        r.scheduler.fire(after: 0.6)
        r.controller.viewModel.onChoose(r.controller.viewModel.list.rows[0], "once")
        r.source.itemsSubject.send([])   // the feed drops it
        XCTAssertTrue(HostedTestSupport.waitUntil { r.controller.viewModel.submitting.isEmpty })
        XCTAssertTrue(r.controller.viewModel.failedRows.isEmpty)
        XCTAssertEqual(r.controller.viewModel.list.rows.count, 0)
    }

    func testRowClicksRouteToSessionKanbanAndCron() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a", session: "s1"),
                                    F.item("kanban:b/t", kind: .kanban, state: .blocked, title: "Fix"),
                                    F.item("cron:j", kind: .cron, state: .working, title: "Nightly", since: F.t0.addingTimeInterval(60))])
        let rows = r.controller.viewModel.list.rows
        r.controller.viewModel.onOpenRow(rows.first { $0.target == .session("s1") }!)
        r.controller.viewModel.onOpenRow(rows.first { $0.target == .kanban }!)
        r.controller.viewModel.onOpenCron()
        XCTAssertEqual(r.opened.value, ["s1"])
        XCTAssertEqual(r.panes.value, [.kanban, .cron])
    }

    func testNewChatHonoursAvailability() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.newChatEnabled.value = false
        r.controller.toggleCommandPin()   // expand: refreshes the flag
        XCTAssertFalse(r.controller.viewModel.newChatEnabled)
        r.controller.viewModel.onNewChat()
        XCTAssertEqual(r.newChats.value, 0)
        r.newChatEnabled.value = true
        r.controller.toggleCommandPin(); r.controller.toggleCommandPin()
        r.controller.viewModel.onNewChat()
        XCTAssertEqual(r.newChats.value, 1)
    }

    func testPointerEventsDriveHoverExpandThroughTheScheduler() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.host.onPointerChange?(true)
        r.scheduler.fire(after: 0.2)
        XCTAssertEqual(r.controller.viewModel.surface, .expanded)
        r.host.onPointerChange?(false)
        r.scheduler.fire(after: 0.4)
        XCTAssertEqual(r.controller.viewModel.surface, .compact)
    }

    func testDismissMonitorCollapsesAndStopsWhenNotExpanded() {
        let r = makeRig(); defer { finish(r) }
        r.controller.toggleCommandPin()
        XCTAssertEqual(r.monitor.started, 1)
        r.monitor.onDismiss?()
        XCTAssertEqual(r.controller.viewModel.surface, .hidden)
        XCTAssertGreaterThanOrEqual(r.monitor.stopped, 1)
    }

    func testShowAgentStatusPinsAndShowsTheEmptyStateEvenWhenOff() {
        let r = makeRig(mode: .off); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertFalse(r.host.isVisible)
        r.controller.toggleCommandPin()
        XCTAssertTrue(r.host.isVisible)
        XCTAssertTrue(r.controller.isCommandPinned)
        r.controller.toggleCommandPin()
        XCTAssertFalse(r.host.isVisible)
    }

    func testOfflineClearsRowsHidesAndPinnedShowsDisconnected() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.source.availabilitySubject.send(.offline)
        r.source.itemsSubject.send([])
        XCTAssertFalse(r.host.isVisible)
        r.controller.toggleCommandPin()
        XCTAssertEqual(r.controller.viewModel.emptyState, .disconnected)
        XCTAssertTrue(r.host.isVisible)
    }

    func testReconnectBaselineDoesNotFlashOrExpand() {
        let r = makeRig(); defer { finish(r) }
        r.source.availabilitySubject.send(.offline)
        r.source.availabilitySubject.send(.live)
        r.source.itemsSubject.send([F.approvalItem("approval:q", session: "s")])
        XCTAssertEqual(r.controller.viewModel.surface, .compact)
    }

    // Review Focus 3.
    func testScreenChangeReanchorsHidesWithNoScreenAndRecovers() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.screen.value = externalScreen
        r.controller.screenParametersChanged()
        XCTAssertEqual(r.host.frames.last, NotchGeometry.compactFrame(.pill, in: externalScreen, contentWidth: 0))
        r.screen.value = nil
        r.controller.screenParametersChanged()
        XCTAssertFalse(r.host.isVisible)
        r.screen.value = notchScreen
        r.controller.screenParametersChanged()
        XCTAssertTrue(r.host.isVisible)
        XCTAssertEqual(r.controller.viewModel.surface, .compact)
    }

    func testSettingsChangeIsAppliedLive() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        XCTAssertTrue(r.host.isVisible)
        r.suite.defaults.set("off", forKey: NotchStatusSettings.key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: r.suite.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { !r.host.isVisible })
    }

    func testFinishedRowsExpireOnSchedule() {
        let r = makeRig(); defer { finish(r) }
        r.source.itemsSubject.send([F.item("turn:a")])
        r.source.itemsSubject.send([F.item("turn:a", state: .finished(.completed), since: F.t0)])
        XCTAssertEqual(r.controller.viewModel.list.rows.count, 1)
        r.now.value = F.t0.addingTimeInterval(31)
        r.scheduler.fire(after: 30)
        XCTAssertEqual(r.controller.viewModel.list.rows.count, 0)
        XCTAssertEqual(r.controller.viewModel.surface, .hidden)
    }

    func testDismissRowGoesToTheFeed() {
        let r = makeRig(); defer { finish(r) }
        r.controller.viewModel.onDismissRow("turn:a")
        XCTAssertEqual(r.source.dismissed, ["turn:a"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run the `NotchStatusControllerTests` command. Expected: FAIL, `cannot find 'NotchStatusController'`.

- [ ] **Step 3: Implement the controller**

```swift
import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchStatusController: ObservableObject {
    static let shared = NotchStatusController()

    @Published private(set) var isCommandPinned = false
    let viewModel = NotchStatusViewModel()

    private let settings: NotchStatusSettings
    private var actions: NotchActions
    private let makeHost: () -> NotchPanelHosting
    private let screen: () -> NotchScreenMetrics?
    private let scheduler: NotchTimerScheduling
    private let monitor: NotchDismissMonitoring
    private let now: () -> Date

    private var state: NotchStatusState
    private var host: NotchPanelHosting?
    private var source: NotchActivitySource?
    private var cancellables = Set<AnyCancellable>()
    private var timerCancels: [NotchTimer: () -> Void] = [:]
    private var cancelExpiry: (() -> Void)?
    private var lastItems: [AgentActivityItem] = []
    private var isBaseline = true
    private var monitoring = false

    init(
        settings: NotchStatusSettings = .shared,
        actions: NotchActions = NotchActions(openSession: { _ in }, openPane: { _ in }, newChat: {}, newChatEnabled: { false }, openConduit: {}),
        makeHost: (() -> NotchPanelHosting)? = nil,
        screen: @escaping () -> NotchScreenMetrics? = { NotchScreenMetrics.main() },
        scheduler: NotchTimerScheduling = TaskTimerScheduler(),
        monitor: NotchDismissMonitoring = NotchDismissMonitor(),
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.actions = actions
        self.screen = screen
        self.scheduler = scheduler
        self.monitor = monitor
        self.now = now
        self.state = NotchStatusState(mode: settings.mode)
        let vm = viewModel
        self.makeHost = makeHost ?? { NotchPanelHost(content: NotchStatusView(model: vm)) }
    }

    // MARK: binding

    /// Production entry (ConduitMacApp). The feed instance belongs to the
    /// shared base; the notch only reads it.
    func bind(to appState: AppState) {
        guard source == nil, let feed = AgentActivityFeed.shared else { return }
        bind(source: FeedNotchSource(feed: feed), actions: .live(appState: appState))
    }

    func bind(source: NotchActivitySource, actions: NotchActions) {
        self.source = source
        self.actions = actions
        cancellables.removeAll()
        wireViewModel()
        source.itemsPublisher.receive(on: DispatchQueue.main).sink { [weak self] in self?.itemsChanged($0) }.store(in: &cancellables)
        source.availabilityPublisher.receive(on: DispatchQueue.main).sink { [weak self] in self?.availabilityChanged($0) }.store(in: &cancellables)
        settings.$mode.dropFirst().removeDuplicates().sink { [weak self] in self?.send(.mode($0)) }.store(in: &cancellables)
        viewModel.$contentHeight.removeDuplicates().sink { [weak self] _ in self?.render() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenParametersChanged() }.store(in: &cancellables)
        viewModel.availability = source.availability
        itemsChanged(source.items)
    }

    func toggleCommandPin() {
        send(.toggleCommandPin)
        isCommandPinned = state.isCommandPinned
    }

    func screenParametersChanged() { render() }

    // MARK: inputs

    private func itemsChanged(_ items: [AgentActivityItem]) {
        let list = NotchRowBuilder.build(items: items, now: now())
        let t = isBaseline ? (newDecision: false, newFinish: false) : NotchItemDiff.transitions(old: lastItems, new: items)
        isBaseline = false
        lastItems = items
        viewModel.list = list
        let ids = Set(list.rows.map(\.id))
        viewModel.submitting.formIntersection(ids)
        viewModel.failedRows.formIntersection(ids)
        scheduleExpiry(list.nextExpiry)
        send(.counts(list.counts, newDecision: t.newDecision, newFinish: t.newFinish))
    }

    private func availabilityChanged(_ a: NotchAvailability) {
        viewModel.availability = a
        if a == .offline { send(.online(false)) } else {
            send(.online(true))
            isBaseline = true    // what is already there on (re)connect is a silent baseline
        }
    }

    private func send(_ input: NotchInput) {
        let effects = state.apply(input)
        for effect in effects { run(effect) }
        render()
    }

    private func run(_ effect: NotchEffect) {
        switch effect {
        case .schedule(let timer, let delay):
            timerCancels[timer]?()
            timerCancels[timer] = scheduler.schedule(after: delay) { [weak self] in
                self?.timerCancels[timer] = nil
                self?.send(.timer(timer))
            }
        case .cancel(let timer):
            timerCancels[timer]?(); timerCancels[timer] = nil
        case .announceAttention:
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: viewModel.accessibilitySummary,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func scheduleExpiry(_ at: Date?) {
        cancelExpiry?(); cancelExpiry = nil
        guard let at else { return }
        let delay = max(0, at.timeIntervalSince(now()))
        cancelExpiry = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.itemsChanged(self.lastItems)
        }
    }

    // MARK: rendering

    private func render() {
        viewModel.surface = state.surface
        viewModel.buttonsEnabled = state.buttonsEnabled
        isCommandPinned = state.isCommandPinned
        updateMonitor()
        guard state.surface != .hidden, let metrics = screen() else {
            host?.hide()
            return
        }
        let placement = NotchGeometry.placement(for: metrics)
        viewModel.placement = placement
        if state.surface == .expanded { viewModel.newChatEnabled = actions.newChatEnabled() }
        let frame: CGRect
        switch state.surface {
        case .compact:
            frame = NotchGeometry.compactFrame(placement, in: metrics, contentWidth: 0)
        default:
            let height = viewModel.contentHeight > 0 ? viewModel.contentHeight : 120
            frame = NotchGeometry.expandedFrame(placement, in: metrics, height: height)
        }
        let host = self.host ?? makeHost()
        if self.host == nil { self.host = host; host.onPointerChange = { [weak self] in self?.send($0 ? .hoverEntered : .hoverExited) } }
        let wasVisible = host.isVisible
        host.setFrame(frame, animated: wasVisible)
        if !wasVisible { host.show() }
    }

    private func updateMonitor() {
        let wantsMonitor = state.surface == .expanded
        if wantsMonitor && !monitoring {
            monitoring = true
            monitor.start(onDismiss: { [weak self] in self?.send(.dismissRequested) },
                          isOwnWindow: { [weak self] w in w != nil && w === (self?.hostWindow) })
        } else if !wantsMonitor && monitoring {
            monitoring = false
            monitor.stop()
        }
    }

    private var hostWindow: NSWindow? { (host as? NotchPanelHost)?.panelForTesting }

    // MARK: view model actions

    private func wireViewModel() {
        viewModel.onOpenRow = { [weak self] row in
            guard let self else { return }
            switch row.target {
            case .session(let id): self.actions.openSession(id)
            case .kanban: self.actions.openPane(.kanban)
            case .cron: self.actions.openPane(.cron)
            case nil: self.actions.openConduit()
            }
        }
        viewModel.onOpenCron = { [weak self] in self?.actions.openPane(.cron) }
        viewModel.onOpenConduit = { [weak self] in self?.actions.openConduit() }
        viewModel.onOpenMore = { [weak self] in self?.actions.openConduit() }
        viewModel.onNewChat = { [weak self] in self?.actions.newChat() }
        viewModel.onDismissRow = { [weak self] id in self?.source?.dismiss(id) }
        viewModel.onChoose = { [weak self] row, choice in self?.choose(row, choice) }
    }

    private func choose(_ row: NotchRow, _ choice: String) {
        guard viewModel.canChoose(rowID: row.id), let source else { return }
        viewModel.submitting.insert(row.id)
        viewModel.failedRows.remove(row.id)
        send(.interacted)
        Task { @MainActor [weak self] in
            let result = await source.respond(to: row.id, choice: choice)
            guard let self else { return }
            self.viewModel.submitting.remove(row.id)
            if case .failed = result { self.viewModel.failedRows.insert(row.id) }
            // .resolved and .alreadyResolved: the feed removes the row itself.
        }
    }
}
```
Fix-ups the implementer should expect and handle without changing test intent: `panelForTesting` is the test seam name used by `hostWindow`; if the base exposes a cleaner accessor, use it in both places. `NotchStatusController.init`'s default `NotchPanelHost(content:)` closure captures the view model, which exists before `self` is fully initialised (it is a `let` assigned first).

- [ ] **Step 4: Wire the app and the Go-menu command**

Apply the `ConduitMacApp.swift` and `ConduitCommands.swift` edits from Task 7 Step 3 (the `.task { NotchStatusController.shared.bind(to: appState) }` line, `notch: .shared` in `.commands`, the `@ObservedObject var notch`, and the Go-menu button). The `bind(to:)` guard on `AgentActivityFeed.shared` is nil until the shared base's wiring has created it; `.task` runs once per window appearance, so if Task 1's note says the base creates the feed later than first render, wrap in `.task(id: appState.isConnected) { NotchStatusController.shared.bind(to: appState) }` (`bind(to:)` is a no-op once bound).

- [ ] **Step 5: Run to verify pass**

Run `NotchStatusControllerTests`, `NotchActionsTests`, then the whole `ConduitMacTests` suite once: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO`. Expected: all pass except the known flaky orb test. Then the Mac build command (`** BUILD SUCCEEDED **`).

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/Notch/NotchStatusController.swift ConduitMac/App/ConduitMacApp.swift ConduitMac/App/ConduitCommands.swift ConduitMacTests/NotchStatusControllerTests.swift
git commit -m "macOS notch: controller, app wiring, Show Agent Status command"
```
Add any other `ConduitCommands(` call-site file you changed, by explicit path.

---

### Task 9: Localization

**Files:**
- Modify: `Conduit/Localizable.xcstrings` (additive keys only, via `scripts/l10n.py`)

**Interfaces:** none.

The new English keys (each exactly as written in code; `%lld` ones are plural keys with English `one` and `other` forms):

| Key | Where |
|---|---|
| `Notch status` | Settings section and picker |
| `Active agents`, `Only when I'm needed`, `Off` | picker (check `Off` already exists) |
| `Shows what Hermes is doing at the top of the screen. It only sees chats on this connection: chats started from the CLI, Slack or another app are not shown.` | Settings footnote |
| `Agent status: %@` | a11y group and announcement |
| `%lld working` (plural), `%lld need you` (plural) | compact label, a11y summary |
| `idle` | a11y summary |
| `Needs you`, `Working`, `Done` | section headers (`Working`, `Done` exist) |
| `Allow once`, `Deny`, `Allow for session`, `Always allow`, `More options` | approval row |
| `Answer in Conduit`, `Open in Conduit to answer`, `Couldn't send. Open in Conduit.` | row hints |
| `Dismiss`, `Untitled chat` | row (check both) |
| `+%lld more` (plural) | overflow |
| `No agents running`, `Chats started from the CLI, Slack or another app are not shown here.`, `Not connected to Hermes`, `Only chats opened in Conduit are tracked right now.` | empty states |
| `Next cron: %@, %@` | footer |
| `New Chat`, `Open Conduit` | footer (exist) |
| `Show Agent Status`, `Hide Agent Status` | Go menu |

- [ ] **Step 1: Find which keys already exist**

For each key: `grep -c "^    \"<key>\" : {" Conduit/Localizable.xcstrings`. Only create the missing ones. Reuse existing translations as-is; do not retranslate `New Chat`, `Open Conduit`, `Done`, `Working`, `Off`.

- [ ] **Step 2: Create the worksheets and import**

Follow `docs/LOCALIZATION.md` "Translating with worksheets": for each shipped language (list them from the catalog; `python3 scripts/check-l10n-coverage.py --repo-root .` names them), `python3 scripts/l10n.py export <lang> -o <scratch>/<lang>.json`, fill only the new keys (plural keys as `{"one": ..., "other": ...}` plus the forms that language needs), `python3 scripts/l10n.py import --create <scratch>/<lang>.json`. Worksheets live in the scratchpad directory, not the repo. Write natural translations; `%lld` and `%@` placeholders and the `Next cron: %@, %@` argument order must survive.

- [ ] **Step 3: Verify**

Run: `python3 scripts/check-l10n-coverage.py --repo-root .`
Expected: no missing, malformed or plural errors. The checker also fails raw string literals in `String` display parameters: if it flags `NotchStatusViewModel.accessibilitySummary` or `NotchCompactLabel` usage, wrap them as it asks. Then `git diff -- Conduit | grep '^-[^-]'` must print nothing (additions only).

- [ ] **Step 4: Commit**

```bash
git add Conduit/Localizable.xcstrings ConduitMac/Notch
git commit -m "macOS notch: localization for all shipped languages"
```
`ConduitMac/Notch` is included only if Step 3 forced code changes; list the specific files instead of the directory.

---

### Task 10: Docs, ledger, smoke checklist, final verification

**Files:**
- Modify: `docs/macos/DECISIONS.md` (append D16), `docs/macos/PORTING_LEDGER.md`, `docs/macos/SMOKE_CHECKLIST.md`

- [ ] **Step 1: DECISIONS D16**

Append after D15 (Quick Ask; if D15 is not there yet, the shared base or Quick Ask plan has not landed it: use the next free number and say so in the commit):
```markdown
## D16: Mac notch agent status (2026-10-15)
Spec: docs/superpowers/specs/2026-10-15-mac-notch-status-design.md. A hidden-when-idle surface at the top-center of NSScreen.main: wings around the notch (safeAreaInsets.top > 0 with both auxiliary areas non-empty) or a 28 pt pill elsewhere. Built on MacFloatingPanel (non-activating, non-key, statusBar level) driven by AgentActivityFeed; no menu bar icon, no third-party notch package. Default on, mode "Active agents"; "Only when I'm needed" and "Off" (conduit.mac.notchStatus.mode). Show Agent Status (Go menu) pins the panel open even when Off. Inline Allow once / Deny come from each request's choices; Session and Always are menu-only; smart-denied requests offer once and deny only; clarify, sudo, secret and vault prompts are never inline. 600 ms click guard after an auto-expand; no default-key binding. Surface is black in light and dark so it blends into the notch (text at least 4.5:1). Components: NotchGeometry, NotchRowBuilder, NotchStatusState (pure), NotchStatusController, NotchPanelHost.

Visibility limit (verified against the gateway): Conduit sees only sessions on its own socket. Sessions started by another process (CLI, Slack, a separate cron process) are invisible. Sessions of the same gateway process appear in session.active_list but approvals and events flow only after session.activate / session.resume; opening a row from the notch does that, which adds Conduit as a viewer of the session. The empty state, the Settings footnote and this entry say so. Esc reaches the panel only while Conduit is the active app (the panel is never key); click outside and moving the pointer away work always.
```

- [ ] **Step 2: Ledger**

Confirm the Task 2 row is present. Add a row for the additive catalog keys in the existing column format: `| Conduit/Localizable.xcstrings | additive | Mac notch status strings (Task 9 of the notch plan); no gate, data only | none needed |`. The `handleStreamEvent` tap row belongs to the shared base: do not add it here.

- [ ] **Step 3: Smoke checklist**

Append a "Notch status (D16)" section to `docs/macos/SMOKE_CHECKLIST.md`, one checkbox per line, in the file's existing style:
- Idle: nothing at the top of the screen; Settings > Notch status shows the three modes and the visibility footnote.
- Start a long turn: compact wings appear around the notch (and a pill on an external display); the mark pulses; the right wing names the tool or the count.
- Hover the compact surface: expands after about 200 ms, collapses about 400 ms after the pointer leaves. Reduce Motion on: fade only.
- Trigger an approval in a background session: the panel expands and stays; Allow once and Deny are disabled for about 600 ms and then work; Always allow exists only in the "..." menu; a smart-denied request has no menu.
- Answer from the notch; answer from the main window; answer from Hermes Desktop: the row disappears each time with no error.
- A clarify or sudo/secret prompt: row says "Answer in Conduit" and click opens that session.
- Click a working row: Conduit comes forward on that session. Click a Kanban row: the Kanban pane opens. Click the cron footer: the Cron pane opens.
- Turn finishes: checkmark row for 4 s expanded, stays as a row for 30 s (max 3), then disappears. A failed turn is red with the error text.
- A session started in the CLI or Slack never shows (known limit, D16).
- Go > Show Agent Status pins the panel (also with the mode Off) and shows "No agents running" with the limit note; again hides it. Esc collapses it with Conduit frontmost; click outside collapses it always.
- Disconnect Hermes: rows clear after about 15 s and the panel hides; pinned shows "Not connected to Hermes".
- Capture on a notch Mac: `NSScreen.main` `safeAreaInsets.top`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea` and record them next to the fixture in NotchGeometryTests.
- Hardware matrix: external display only (lid closed), mirrored display, a full-screen app, two Spaces, unplug the external display while expanded.
- VoiceOver: the panel reads "Agent status: ..." and every row and button is reachable; an approval announces.
- Click the empty corners of the compact capsule: clicks pass through to the menu bar.

- [ ] **Step 4: Final verification**

Run in order, one xcodebuild at a time:
1. `xcodegen generate`
2. Mac build command (expect `** BUILD SUCCEEDED **`).
3. Full suite twice: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO` (all pass except the known flaky orb test).
4. `python3 scripts/check-l10n-coverage.py --repo-root .` (clean).
5. `git diff <base> -- Conduit Shared | grep '^-[^-]'` (no output) and `git diff <base> --stat -- Conduit Shared` shows only `AuxiliaryViews.swift` (one gated block) and `Localizable.xcstrings`.
6. `grep -rn "print(\|NSLog\|os_log\|Logger(" ConduitMac/Notch` (no output).
7. `grep -rn "keyboardShortcut\|defaultAction" ConduitMac/Notch` (no output).
8. Whole-branch review against the spec and this plan's Review Focus.

- [ ] **Step 5: Commit and clean up**

```bash
git add docs/macos/DECISIONS.md docs/macos/PORTING_LEDGER.md docs/macos/SMOKE_CHECKLIST.md
git commit -m "docs(mac): D16 notch status, ledger, smoke checklist"
```
Then clean as you go: after the merge gate passes, `git worktree remove` the worktree, delete its branch, and delete `build/dd` and any scratch worksheets (all regenerable; confirm no other agent is using them first).

---

## Execution notes

- Task order: 1, 2, 3 (independent of 2), 4, 5, 6, 7, 8, 9, 10. Tasks 1 to 4 are pure and may run as parallel worktrees branched after the shared base; Tasks 5 to 8 are sequential. Task 7's wiring half lands inside Task 8.
- Never two xcodebuilds on one checkout; parallel worktrees need separate `-derivedDataPath` (for example `build/dd-t2`). Check `df -h` first (prune below about 20 GB free).
- Stage explicit paths only. The main checkout has uncommitted user edits in `Conduit/Services/AppState.swift` and `Conduit/Views/ChatView.swift`; they are not part of this work.
- After all tasks: whole-branch review, merge into `macos`, full suite on the merge, remove worktrees and branches right away.
