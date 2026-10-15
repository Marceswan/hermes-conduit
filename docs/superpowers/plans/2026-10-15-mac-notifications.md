# Mac Done and Approval Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**REQUIRES SHARED BASE MERGED.** `docs/superpowers/plans/2026-10-15-mac-shared-base.md` delivers `AgentActivityFeed` (events `turnStarted`, `turnFinished`, `approvalRequested`, `questionRequested`, `decisionResolved`, `sessionTitleChanged`, each with `eventId`, snapshot on subscribe), the stream-event tap, connection state and the Mac reconnect-while-inactive exemption. This plan does not build any of that. Tasks 1 to 8 and 10 run against a local, feed-neutral event model (`MacNotificationEvent`) and can be built and tested before the shared base lands; Task 9 (the feed adapter) and the smoke run need it merged. Do not start Task 9 until `grep -rn "AgentActivityFeed" ConduitMac` finds the type.

**Goal:** A local macOS notification when a long turn finishes, or the agent blocks on an approval or a clarifying question while the user is not looking, with Approve/Deny and inline Reply from the notification and click-to-open.

**Architecture:** A pure policy (`MacNotificationPolicy`) decides long-running, suppression, dedupe and burst collapse. A main-actor `MacNotificationCoordinator` consumes `MacNotificationEvent`s, applies the policy and preferences, owns the 3 s approval grace timers, and posts through a `MacNotificationCenterClient` protocol (fake in tests). Actions arrive through a thin `UNUserNotificationCenterDelegate` shim, become a tested `MacNotificationAction`, and are performed by `MacNotificationActionHandler` against a `MacNotificationGateway` that calls `HermesClient` directly with explicit session ids (no switching of `AppState`'s active session). A feed adapter maps `AgentActivityFeed` onto the local event model.

**Tech Stack:** Swift 6 / SwiftUI / AppKit on macOS 14+, UserNotifications, Combine, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-15-mac-notifications-design.md` (approved). Decisions resolved after the spec, which this plan follows over the spec text where they differ:

1. Defaults confirmed: 30 s threshold, master toggle on, permission prompt on the first eligible event while Conduit is inactive.
2. A click on a notification from another dashboard or profile only activates the app.
3. From a gateway source read: approval choices are exactly `once`, `session`, `always`, `deny`, built per request; a smart-denied request offers only `once` and `deny`. Approve sends `once`, Deny sends `deny`. A notification never offers `always` and never offers `session`. Approve is dropped when `once` is absent; Deny is dropped when `deny` is absent. `allowPermanent` is irrelevant to the mapping.
4. `HermesClient.respondToApproval(sessionId:requestId:choice:profile:)` and `HermesClient.sendPrompt(_:text:)` take an explicit session id, and `approval.respond` works for any in-process session. Inline Reply therefore does NOT call `requestOpenSession` and does not touch `AppState`'s active session (the spec's "Reply switches the visible session" is dropped, as are its open questions 2 and 3). A question Reply goes through `HermesClient.respondToClarification(requestId:answer:questionId:)`, which is already internal. No shared-file edit is needed for any action.
5. Events arrive push-based for every session the dashboard socket has attached to. Sessions started by another process (a terminal Hermes, another Mac's app that this socket never attached) never notify. This is documented in D15 and the smoke checklist, not worked around.

## Global Constraints

- Mac only. New code lives under `ConduitMac/Notifications/` (plus `ConduitMac/Views/MacNotificationSettingsView.swift`). iOS behaviour is unchanged.
- Upstream edits (`Conduit/`, `Shared/`): `#if os(macOS)` gate, tagged `// MAC:`, one row each in `docs/macos/PORTING_LEDGER.md`. The only planned one is the settings section insert in `Conduit/Views/AuxiliaryViews.swift` (Task 10). `git diff <base> -- Conduit Shared | grep '^-[^-]'` prints nothing.
- No edits to `Conduit/Services/AppState.swift` or `HermesClient.swift`. If a task seems to need one, stop and gate it with a ledger row instead of widening scope silently.
- Local notifications only. `PushNotificationService`, `ConduitNotificationTarget` and `ConduitNotificationPreferences` are not reused. `HermesCallNotifications` is not called.
- Never bypass Focus: interruption level stays `.active`; no Time Sensitive, no Critical. Authorization options are `[.alert, .sound]` (no badge). Requested lazily, never at launch.
- Threshold choices 10 / 30 / 60 / 120 s, default 30 s; long-running means `finishedAt - startedAt >= threshold`. Approval grace 3 s. Burst: more than 3 Done posts inside 10 s collapse to `conduit.done.summary`.
- Identifiers: `conduit.done.<sessionKey>`, `conduit.approval.<requestId>`, `conduit.question.<requestId>`, `conduit.done.summary`, `conduit.notice.<uuid>`; `threadIdentifier = "session-<sessionKey>"`. Routing payload in `userInfo["conduit_mac"]` with `session_id`, `session_key`, `profile`, `dashboard_id`, `request_id`, `kind`, plus `question_count` (Task 4). No message text beyond the visible content.
- Preference keys: `conduit.mac.notifications.*`, per Mac, in `UserDefaults`.
- Suppression uses `NSApp.isActive` plus the key window, never `scenePhase`, and is evaluated at post time.
- Approve and Deny actions carry `.authenticationRequired` and do not bring the app forward. Reply does not bring the app forward. Only Open and a default click use `.foreground`.
- Localization per `docs/LOCALIZATION.md`: every user-visible string goes through `AppLocalization.string(...)`; counts are `Int` interpolations named like `...Count` with plural variants in the catalog; one key per sentence. Task 11 decides catalog coverage (see there).
- Tests in `ConduitMacTests`, TDD. Injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`), explicit teardown, no fixed sleeps, fake notification center and fake scheduler. Never touch the live app's defaults or the real `UNUserNotificationCenter` in tests.
- Build: `xcodegen generate` first, then `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`. Tests: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/<Class>`. Never two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`. In zsh quote every glob.
- Staging: stage explicit paths only (`git add <file> <file>`). Never `git add -A`, `git add .` or `git add ConduitMac`; the tree has unrelated modified files (`Conduit/Services/AppState.swift`, `Conduit/Views/ChatView.swift`) and untracked plans that are not part of this work.
- Safety: the user's own Conduit is running. Do not quit it, click it, type into it or post real notifications to it from tests. Never touch a Conduit login form. Delete scratch output (`build/dd` excepted while you still need it) and stop any process you start before reporting done.
- Record `BASE=$(git rev-parse HEAD)` before Task 1; it is the base for the `git diff` checks.

## Review Focus

1. An approval or question that arrives while the user is looking at that session (suppressed) and stays pending after the user switches away or deactivates the app: it must still notify then, once. Test in Task 6 (`testSuppressedDecisionPostsWhenTheUserLeaves`).
2. Feed replay after reconnect (same events, same or new `eventId`): one notification per turn or request, never a duplicate Done after a resolved approval. Tests in Task 5 and Task 6.
3. The user answers in the app inside the 3 s grace, or on another Mac after delivery: no banner, or the banner is removed. Tests in Task 6.
4. A notification action fired after the dashboard or profile changed, the gateway disconnected, or the request expired (4009 / `expired`): never a wrong-scope answer, never a silent failure; expired approval counts as success, anything else posts "Couldn't send". Tests in Task 7.
5. Category replacement: registering Conduit's categories must keep a foreign category (`HERMES_CALL`) and must survive the app-language change. Test in Task 4.

## File Map

- Create `ConduitMac/Notifications/MacNotificationEvent.swift`: feed-neutral session and event model (Task 1).
- Create `ConduitMac/Notifications/MacNotificationPolicy.swift`: pure policy, posted-set, burst limiter, identifiers (Task 1).
- Create `ConduitMac/Notifications/MacApprovalChoiceMapper.swift` (Task 2).
- Create `ConduitMac/Notifications/MacNotificationPreferences.swift` (Task 3).
- Create `ConduitMac/Notifications/MacNotificationCenterClient.swift`: protocol, real adapter, scheduler protocol (Task 4).
- Create `ConduitMac/Notifications/MacNotificationContent.swift`: payload, request builders, copy (Task 4).
- Create `ConduitMac/Notifications/MacNotificationCategories.swift`: categories and merge (Task 4).
- Create `ConduitMac/Notifications/MacNotificationCoordinator.swift` (Tasks 5, 6).
- Create `ConduitMac/Notifications/MacNotificationActions.swift`: action model, gateway protocol and Hermes implementation, handler (Task 7).
- Create `ConduitMac/Notifications/MacNotificationRouter.swift`: click routing, cold-launch hold (Task 8).
- Create `ConduitMac/Notifications/MacNotificationVisibility.swift`: visibility provider (Task 8).
- Create `ConduitMac/Notifications/MacNotificationDelegate.swift`: delegate shim and presentation options (Task 8).
- Create `ConduitMac/Notifications/MacNotificationRuntime.swift`: wiring singleton (Task 8).
- Create `ConduitMac/Notifications/MacNotificationFeedAdapter.swift` (Task 9).
- Create `ConduitMac/Views/MacNotificationSettingsView.swift` (Task 10).
- Modify `ConduitMac/App/ConduitMacAppDelegate.swift` (Task 8), `ConduitMac/App/ConduitMacApp.swift` (Task 8, language hook).
- Modify `Conduit/Views/AuxiliaryViews.swift` (`NotificationsSettingsDetail.body`, about line 2124): gated insert (Task 10).
- Tests: `ConduitMacTests/MacNotificationFakes.swift` (Task 4), `MacNotificationPolicyTests.swift`, `MacApprovalChoiceMapperTests.swift`, `MacNotificationPreferencesTests.swift`, `MacNotificationContentTests.swift`, `MacNotificationCategoriesTests.swift`, `MacNotificationCoordinatorTests.swift`, `MacNotificationDecisionTests.swift`, `MacNotificationActionTests.swift`, `MacNotificationRouterTests.swift`, `MacNotificationFeedAdapterTests.swift`, `MacNotificationSettingsViewTests.swift`.
- Docs: `docs/macos/DECISIONS.md` (D15), `docs/macos/PORTING_LEDGER.md`, `docs/macos/SMOKE_CHECKLIST.md`.

`ConduitMac/` sources are picked up by the folder glob in `project.yml`; run `xcodegen generate` after adding files (`grep -n "path: ConduitMac$" project.yml` confirms the glob).

---

### Task 1: Event model and policy

**Files:**
- Create: `ConduitMac/Notifications/MacNotificationEvent.swift`
- Create: `ConduitMac/Notifications/MacNotificationPolicy.swift`
- Test: `ConduitMacTests/MacNotificationPolicyTests.swift`

**Interfaces:**
- Produces:
  - `struct MacNotificationSession: Equatable, Hashable { var sessionId: String; var sessionKey: String; var alternateIds: [String]; var profile: String; var dashboardID: UUID?; var title: String; var allIDs: Set<String> }`
  - `struct MacNotificationEvent: Equatable { var eventId: Int; var session: MacNotificationSession; var kind: Kind }` with `enum Kind: Equatable { case turnStarted(turnId: String, at: Date); case turnFinished(turnId: String, at: Date, outcome: Outcome, replyPreview: String?); case approvalRequested(requestId: String, description: String, command: String, choices: [String]?, allowPermanent: Bool); case questionRequested(requestId: String, firstQuestionText: String, openQuestionCount: Int); case decisionResolved(requestId: String, reason: Resolution); case sessionTitleChanged(title: String) }`, `enum Outcome { case completed, failed, interrupted }`, `enum Resolution { case answered, expired, withdrawn, sessionClosed }`
  - `struct MacNotificationVisibility: Equatable { var appIsActive, mainWindowKeyAndVisible, chatSurfaceShowing, sessionIsActive: Bool; var isAttended: Bool; static let away }`
  - `enum MacNotificationKind: String { case done, failed, approval, question, notice }`
  - `enum MacNotificationPolicy` with `thresholdChoices: [TimeInterval]`, `defaultThreshold`, `approvalGrace`, `burstLimit`, `burstWindow`, `isLongRunning(startedAt:finishedAt:threshold:)`, `shouldSuppress(_:)`, and `enum ID { static func done(_ sessionKey: String), approval(_:), question(_:), thread(_:), notice(_ uuid: UUID); static let doneSummary }`
  - `struct MacNotificationPostedSet { enum Slot { case done, approval, question }; mutating func insert(_ slot: Slot, _ key: String) -> Bool }`
  - `struct MacDoneBurstLimiter { enum Decision: Equatable { case individual, summary(count: Int) }; mutating func register(at: Date) -> Decision }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacNotificationPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLongRunningBoundary() {
        XCTAssertFalse(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(29.9), threshold: 30))
        XCTAssertTrue(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(30), threshold: 30))
        XCTAssertTrue(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(120), threshold: 120))
        XCTAssertFalse(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(-5), threshold: 10),
                       "a clock that ran backwards is never long-running")
    }

    func testThresholdChoicesAndDefault() {
        XCTAssertEqual(MacNotificationPolicy.thresholdChoices, [10, 30, 60, 120])
        XCTAssertEqual(MacNotificationPolicy.defaultThreshold, 30)
    }

    func testSuppressionTruthTable() {
        func v(_ a: Bool, _ k: Bool, _ c: Bool, _ s: Bool) -> MacNotificationVisibility {
            MacNotificationVisibility(appIsActive: a, mainWindowKeyAndVisible: k, chatSurfaceShowing: c, sessionIsActive: s)
        }
        XCTAssertTrue(MacNotificationPolicy.shouldSuppress(v(true, true, true, true)))
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(false, true, true, true)), "app in background")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(true, false, true, true)), "window not key or occluded")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(true, true, false, true)), "another pane or a sheet covers chat")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(true, true, true, false)), "another session is active (tab strip)")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(.away))
    }

    func testIdentifiers() {
        XCTAssertEqual(MacNotificationPolicy.ID.done("k1"), "conduit.done.k1")
        XCTAssertEqual(MacNotificationPolicy.ID.approval("r1"), "conduit.approval.r1")
        XCTAssertEqual(MacNotificationPolicy.ID.question("r2"), "conduit.question.r2")
        XCTAssertEqual(MacNotificationPolicy.ID.thread("k1"), "session-k1")
        XCTAssertEqual(MacNotificationPolicy.ID.doneSummary, "conduit.done.summary")
        let u = UUID()
        XCTAssertEqual(MacNotificationPolicy.ID.notice(u), "conduit.notice.\(u.uuidString)")
    }

    func testPostedSetAbsorbsReplaysPerSlot() {
        var set = MacNotificationPostedSet()
        XCTAssertTrue(set.insert(.done, "t1"))
        XCTAssertFalse(set.insert(.done, "t1"))
        XCTAssertTrue(set.insert(.approval, "t1"), "slots are independent")
        XCTAssertTrue(set.insert(.done, "t2"))
    }

    func testBurstCollapsesFromTheFourthInsideTenSeconds() {
        var limiter = MacDoneBurstLimiter()
        XCTAssertEqual(limiter.register(at: t0), .individual)
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(1)), .individual)
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(2)), .individual)
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(3)), .summary(count: 4))
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(4)), .summary(count: 5))
    }

    func testBurstWindowSlides() {
        var limiter = MacDoneBurstLimiter()
        for i in 0..<3 { _ = limiter.register(at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(12)), .individual,
                       "the first three are older than 10 s by then")
    }

    func testSessionAllIDsCoversRuntimeKeyAndAlternates() {
        let s = MacNotificationSession(sessionId: "run", sessionKey: "key", alternateIds: ["alt"], profile: "default", dashboardID: nil, title: "T")
        XCTAssertEqual(s.allIDs, ["run", "key", "alt"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationPolicyTests`
Expected: build failure (types missing).

- [ ] **Step 3: Implement**

`ConduitMac/Notifications/MacNotificationEvent.swift`:

```swift
import Foundation

/// The session an event belongs to, as the notification layer needs it. The
/// feed adapter (Task 9) fills it; nothing here knows about the feed.
struct MacNotificationSession: Equatable, Hashable {
    /// The runtime (live) id the gateway addresses in RPCs.
    var sessionId: String
    /// The durable id, matched through `alternateIds` (spec 2026-09-06).
    var sessionKey: String
    var alternateIds: [String]
    var profile: String
    var dashboardID: UUID?
    var title: String

    var allIDs: Set<String> { Set([sessionId, sessionKey] + alternateIds) }
}

struct MacNotificationEvent: Equatable {
    /// Monotonic per feed; replays and duplicates are absorbed with it.
    var eventId: Int
    var session: MacNotificationSession
    var kind: Kind

    enum Outcome: Equatable { case completed, failed, interrupted }
    enum Resolution: Equatable { case answered, expired, withdrawn, sessionClosed }

    enum Kind: Equatable {
        case turnStarted(turnId: String, at: Date)
        case turnFinished(turnId: String, at: Date, outcome: Outcome, replyPreview: String?)
        case approvalRequested(requestId: String, description: String, command: String, choices: [String]?, allowPermanent: Bool)
        case questionRequested(requestId: String, firstQuestionText: String, openQuestionCount: Int)
        case decisionResolved(requestId: String, reason: Resolution)
        case sessionTitleChanged(title: String)
    }
}
```

`ConduitMac/Notifications/MacNotificationPolicy.swift`:

```swift
import Foundation

struct MacNotificationVisibility: Equatable {
    var appIsActive: Bool
    var mainWindowKeyAndVisible: Bool
    var chatSurfaceShowing: Bool
    var sessionIsActive: Bool

    /// The user is looking at this session right now.
    var isAttended: Bool { appIsActive && mainWindowKeyAndVisible && chatSurfaceShowing && sessionIsActive }

    static let away = MacNotificationVisibility(appIsActive: false, mainWindowKeyAndVisible: false, chatSurfaceShowing: false, sessionIsActive: false)
}

enum MacNotificationKind: String, Equatable {
    case done, failed, approval, question, notice
}

enum MacNotificationPolicy {
    static let thresholdChoices: [TimeInterval] = [10, 30, 60, 120]
    static let defaultThreshold: TimeInterval = 30
    static let approvalGrace: TimeInterval = 3
    static let burstLimit = 3
    static let burstWindow: TimeInterval = 10

    static func isLongRunning(startedAt: Date, finishedAt: Date, threshold: TimeInterval) -> Bool {
        finishedAt.timeIntervalSince(startedAt) >= threshold
    }

    static func shouldSuppress(_ visibility: MacNotificationVisibility) -> Bool { visibility.isAttended }

    enum ID {
        static func done(_ sessionKey: String) -> String { "conduit.done.\(sessionKey)" }
        static func approval(_ requestId: String) -> String { "conduit.approval.\(requestId)" }
        static func question(_ requestId: String) -> String { "conduit.question.\(requestId)" }
        static func thread(_ sessionKey: String) -> String { "session-\(sessionKey)" }
        static func notice(_ uuid: UUID) -> String { "conduit.notice.\(uuid.uuidString)" }
        static let doneSummary = "conduit.done.summary"
    }
}

/// Process-lifetime memory of what was already announced; the feed may replay
/// after a reconnect.
struct MacNotificationPostedSet {
    enum Slot: Hashable { case done, approval, question }
    private var keys = Set<String>()

    /// True when this (slot, key) is new.
    mutating func insert(_ slot: Slot, _ key: String) -> Bool {
        keys.insert("\(slot)|\(key)").inserted
    }
}

/// More than `burstLimit` Done posts inside `burstWindow` collapse into one
/// summary. The first three post individually; the fourth and later replace
/// the summary with the running count.
struct MacDoneBurstLimiter {
    enum Decision: Equatable { case individual, summary(count: Int) }
    private var stamps: [Date] = []

    mutating func register(at now: Date) -> Decision {
        stamps = stamps.filter { now.timeIntervalSince($0) < MacNotificationPolicy.burstWindow }
        stamps.append(now)
        return stamps.count > MacNotificationPolicy.burstLimit ? .summary(count: stamps.count) : .individual
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacNotificationEvent.swift ConduitMac/Notifications/MacNotificationPolicy.swift ConduitMacTests/MacNotificationPolicyTests.swift
git commit -m "macOS notifications: event model and policy"
```

---

### Task 2: Approval choice mapper

**Files:**
- Create: `ConduitMac/Notifications/MacApprovalChoiceMapper.swift`
- Test: `ConduitMacTests/MacApprovalChoiceMapperTests.swift`

**Interfaces:**
- Produces:
  - `enum MacApprovalChoiceMapper` with `static let approveChoice = "once"`, `static let denyChoice = "deny"`
  - `struct MacApprovalChoiceMapper.Mapping: Equatable { var approve: String?; var deny: String?; var isEmpty: Bool }`
  - `static func map(choices: [String]?) -> Mapping`

The gateway builds `choices` per request from `once`, `session`, `always`, `deny` (smart-denied: `once`, `deny` only). `nil` is an older gateway without the field; the approval card treats it as the full default list (`ChatView.allows(_:for:)`), so nil maps to both. `always` and `session` are never returned.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacApprovalChoiceMapperTests: XCTestCase {
    func testFullSetMapsToOnceAndDeny() {
        let m = MacApprovalChoiceMapper.map(choices: ["once", "session", "always", "deny"])
        XCTAssertEqual(m, .init(approve: "once", deny: "deny"))
    }

    func testSmartDeniedPairMapsToOnceAndDeny() {
        XCTAssertEqual(MacApprovalChoiceMapper.map(choices: ["once", "deny"]), .init(approve: "once", deny: "deny"))
    }

    func testNilChoicesFallBackToTheCardDefaults() {
        XCTAssertEqual(MacApprovalChoiceMapper.map(choices: nil), .init(approve: "once", deny: "deny"))
    }

    func testPermanentOnlyNeverOffersApprove() {
        let m = MacApprovalChoiceMapper.map(choices: ["always", "deny"])
        XCTAssertNil(m.approve, "always is never offered from a notification")
        XCTAssertEqual(m.deny, "deny")
    }

    func testSessionOnlyNeverOffersApprove() {
        XCTAssertNil(MacApprovalChoiceMapper.map(choices: ["session", "deny"]).approve)
    }

    func testDenyAbsentDropsDeny() {
        let m = MacApprovalChoiceMapper.map(choices: ["once"])
        XCTAssertEqual(m.approve, "once")
        XCTAssertNil(m.deny)
    }

    func testEmptyAndUnknownChoicesMapToNothing() {
        XCTAssertTrue(MacApprovalChoiceMapper.map(choices: []).isEmpty)
        XCTAssertTrue(MacApprovalChoiceMapper.map(choices: ["maybe"]).isEmpty)
    }

    func testMatchingIsExactNotCaseFolded() {
        XCTAssertTrue(MacApprovalChoiceMapper.map(choices: ["Once", "DENY"]).isEmpty,
                      "the wire values are lowercase literals; a near-miss must not be sent")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacApprovalChoiceMapperTests`
Expected: build failure.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which approval choices a notification may carry. Pure; the gateway's
/// choices are `once`, `session`, `always`, `deny`, built per request.
enum MacApprovalChoiceMapper {
    static let approveChoice = "once"
    static let denyChoice = "deny"

    struct Mapping: Equatable {
        var approve: String?
        var deny: String?
        var isEmpty: Bool { approve == nil && deny == nil }
    }

    static func map(choices: [String]?) -> Mapping {
        // nil: a gateway older than the choices field. The approval card
        // treats it as the full default set, so Approve and Deny are valid.
        guard let choices else { return Mapping(approve: approveChoice, deny: denyChoice) }
        return Mapping(
            approve: choices.contains(approveChoice) ? approveChoice : nil,
            deny: choices.contains(denyChoice) ? denyChoice : nil
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacApprovalChoiceMapper.swift ConduitMacTests/MacApprovalChoiceMapperTests.swift
git commit -m "macOS notifications: approval choice mapper (once/deny only)"
```

---

### Task 3: Preferences

**Files:**
- Create: `ConduitMac/Notifications/MacNotificationPreferences.swift`
- Test: `ConduitMacTests/MacNotificationPreferencesTests.swift`

**Interfaces:**
- Consumes: `MacNotificationPolicy.thresholdChoices`, `.defaultThreshold`, `MacNotificationKind` (Task 1).
- Produces: `@MainActor final class MacNotificationPreferences: ObservableObject` with `static let shared`, `init(defaults: UserDefaults = .standard)`, published `isEnabled`, `notifiesDone`, `notifiesApprovals`, `notifiesQuestions`, `soundEnabled` (all default true), `threshold: TimeInterval` (default 30, snapped to a valid choice), and `func allows(_ kind: MacNotificationKind) -> Bool` (`failed` follows `notifiesDone`; `notice` follows only the master toggle). Key names in `MacNotificationPreferences.Key`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationPreferencesTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws { HostedTestSupport.dropSuite(suite) }

    func testDefaults() {
        let p = MacNotificationPreferences(defaults: suite.defaults)
        XCTAssertTrue(p.isEnabled)
        XCTAssertTrue(p.notifiesDone && p.notifiesApprovals && p.notifiesQuestions && p.soundEnabled)
        XCTAssertEqual(p.threshold, 30)
    }

    func testChangesPersistUnderTheMacKeys() {
        let p = MacNotificationPreferences(defaults: suite.defaults)
        p.isEnabled = false
        p.threshold = 60
        p.notifiesQuestions = false
        let again = MacNotificationPreferences(defaults: suite.defaults)
        XCTAssertFalse(again.isEnabled)
        XCTAssertEqual(again.threshold, 60)
        XCTAssertFalse(again.notifiesQuestions)
        XCTAssertNotNil(suite.defaults.object(forKey: "conduit.mac.notifications.enabled"))
        XCTAssertNotNil(suite.defaults.object(forKey: "conduit.mac.notifications.thresholdSeconds"))
    }

    func testAStoredThresholdOutsideTheChoicesSnapsToTheDefault() {
        suite.defaults.set(7, forKey: MacNotificationPreferences.Key.threshold)
        XCTAssertEqual(MacNotificationPreferences(defaults: suite.defaults).threshold, 30)
        let p = MacNotificationPreferences(defaults: suite.defaults)
        p.threshold = 45
        XCTAssertEqual(p.threshold, 30, "setting an invalid value snaps instead of storing it")
    }

    func testAllowsFollowsMasterAndKindToggles() {
        let p = MacNotificationPreferences(defaults: suite.defaults)
        XCTAssertTrue(p.allows(.failed))
        p.notifiesDone = false
        XCTAssertFalse(p.allows(.done))
        XCTAssertFalse(p.allows(.failed), "failed is part of the Done toggle")
        XCTAssertTrue(p.allows(.approval))
        XCTAssertTrue(p.allows(.notice))
        p.isEnabled = false
        XCTAssertFalse(p.allows(.approval))
        XCTAssertFalse(p.allows(.notice))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationPreferencesTests`
Expected: build failure.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Per-Mac notification preferences (`conduit.mac.notifications.*`).
@MainActor
final class MacNotificationPreferences: ObservableObject {
    static let shared = MacNotificationPreferences()

    enum Key {
        static let enabled = "conduit.mac.notifications.enabled"
        static let done = "conduit.mac.notifications.done"
        static let approvals = "conduit.mac.notifications.approvals"
        static let questions = "conduit.mac.notifications.questions"
        static let sound = "conduit.mac.notifications.sound"
        static let threshold = "conduit.mac.notifications.thresholdSeconds"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    @Published var notifiesDone: Bool { didSet { defaults.set(notifiesDone, forKey: Key.done) } }
    @Published var notifiesApprovals: Bool { didSet { defaults.set(notifiesApprovals, forKey: Key.approvals) } }
    @Published var notifiesQuestions: Bool { didSet { defaults.set(notifiesQuestions, forKey: Key.questions) } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.sound) } }
    @Published var threshold: TimeInterval {
        didSet {
            if !MacNotificationPolicy.thresholdChoices.contains(threshold) {
                threshold = MacNotificationPolicy.defaultThreshold
                return
            }
            defaults.set(threshold, forKey: Key.threshold)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        isEnabled = flag(Key.enabled)
        notifiesDone = flag(Key.done)
        notifiesApprovals = flag(Key.approvals)
        notifiesQuestions = flag(Key.questions)
        soundEnabled = flag(Key.sound)
        let stored = (defaults.object(forKey: Key.threshold) as? NSNumber)?.doubleValue
        threshold = stored.flatMap { MacNotificationPolicy.thresholdChoices.contains($0) ? $0 : nil }
            ?? MacNotificationPolicy.defaultThreshold
    }

    func allows(_ kind: MacNotificationKind) -> Bool {
        guard isEnabled else { return false }
        switch kind {
        case .done, .failed: return notifiesDone
        case .approval: return notifiesApprovals
        case .question: return notifiesQuestions
        case .notice: return true
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacNotificationPreferences.swift ConduitMacTests/MacNotificationPreferencesTests.swift
git commit -m "macOS notifications: per-Mac preferences"
```

---

### Task 4: Center client, content builders, categories (and the merge)

**Files:**
- Create: `ConduitMac/Notifications/MacNotificationCenterClient.swift`
- Create: `ConduitMac/Notifications/MacNotificationContent.swift`
- Create: `ConduitMac/Notifications/MacNotificationCategories.swift`
- Create: `ConduitMacTests/MacNotificationFakes.swift`
- Test: `ConduitMacTests/MacNotificationContentTests.swift`, `ConduitMacTests/MacNotificationCategoriesTests.swift`

**Interfaces:**
- Consumes: Task 1 (`MacNotificationSession`, `MacNotificationPolicy.ID`, `MacNotificationKind`), Task 2 (`MacApprovalChoiceMapper.Mapping`).
- Produces:
  - `@MainActor protocol MacNotificationCenterClient: AnyObject { func authorizationStatus() async -> UNAuthorizationStatus; func requestAuthorization() async -> Bool; func add(_ request: UNNotificationRequest) async throws; func removeDelivered(_ identifiers: [String]); func removePending(_ identifiers: [String]); func categories() async -> Set<UNNotificationCategory>; func setCategories(_ categories: Set<UNNotificationCategory>) }`
  - `@MainActor final class UNMacNotificationCenterClient: MacNotificationCenterClient` (wraps `UNUserNotificationCenter.current()`; constructed only by the runtime, never in tests)
  - `@MainActor protocol MacNotificationScheduling: AnyObject { func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void }` (returns a cancel closure) and `final class MacTaskScheduler: MacNotificationScheduling`
  - `struct MacNotificationPayload: Equatable { var kind: MacNotificationKind; var sessionId: String; var sessionKey: String; var profile: String; var dashboardID: UUID?; var requestId: String?; var questionCount: Int; var userInfo: [AnyHashable: Any] { get }; init?(userInfo: [AnyHashable: Any]) }`
  - `enum MacNotificationContent` with `static let payloadKey = "conduit_mac"`, `static func done(session:turnId:preview:sound:) -> UNNotificationRequest`, `failed(session:turnId:sound:)`, `doneSummary(count:sound:)`, `approval(session:requestId:description:command:mapping:sound:)`, `question(session:requestId:text:openQuestionCount:sound:)`, `notice(session:kind:sound:)`, and `static func truncated(_ text: String, limit: Int) -> String`
  - `enum MacNotificationCategories` with category identifiers `done`, `open`, `approval`, `approvalDenyOnly`, `approvalApproveOnly`, `question`; action identifiers `MacNotificationActionID`-compatible strings `openAction`, `approveAction`, `denyAction`, `replyAction`; `static func approvalCategory(for: MacApprovalChoiceMapper.Mapping) -> String`; `static func ours() -> Set<UNNotificationCategory>`; `@MainActor static func register(on: MacNotificationCenterClient) async`
  - Test doubles in `MacNotificationFakes.swift`: `FakeNotificationCenter` (`status`, `grantOnRequest`, `authorizationRequests`, `added`, `addError`, `removedDelivered`, `removedPending`, `stored`) and `FakeScheduler` (`jobs`, `fireAll()`, `cancelledCount`), plus `makeSession(...)`.

Action identifier strings are fixed here and reused in Task 7: `conduit.action.open`, `conduit.action.approve`, `conduit.action.deny`, `conduit.action.reply`. Category identifiers: `CONDUIT_DONE` (Reply, Open), `CONDUIT_OPEN` (Open), `CONDUIT_APPROVAL` (Approve, Deny, Open), `CONDUIT_APPROVAL_DENY` (Deny, Open), `CONDUIT_APPROVAL_APPROVE` (Approve, Open), `CONDUIT_QUESTION` (Reply, Open). Categories are static, so the approval variant is chosen at post time from the mapper's result; both absent falls back to `CONDUIT_OPEN`.

- [ ] **Step 1: Write the fakes and failing tests**

`ConduitMacTests/MacNotificationFakes.swift`:

```swift
import Foundation
import UserNotifications
@testable import ConduitMac

@MainActor
final class FakeNotificationCenter: MacNotificationCenterClient {
    var status: UNAuthorizationStatus = .authorized
    var grantOnRequest = true
    var authorizationRequests = 0
    var added: [UNNotificationRequest] = []
    var addError: Error?
    var removedDelivered: [String] = []
    var removedPending: [String] = []
    var stored: Set<UNNotificationCategory> = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grantOnRequest ? .authorized : .denied
        return grantOnRequest
    }
    func add(_ request: UNNotificationRequest) async throws {
        if let addError { throw addError }
        added.append(request)
    }
    func removeDelivered(_ identifiers: [String]) { removedDelivered += identifiers }
    func removePending(_ identifiers: [String]) { removedPending += identifiers }
    func categories() async -> Set<UNNotificationCategory> { stored }
    func setCategories(_ categories: Set<UNNotificationCategory>) { stored = categories }

    var identifiers: [String] { added.map(\.identifier) }
}

@MainActor
final class FakeScheduler: MacNotificationScheduling {
    struct Job { var delay: TimeInterval; var work: @MainActor () -> Void; var cancelled = false }
    private(set) var jobs: [Job] = []
    var cancelledCount: Int { jobs.filter(\.cancelled).count }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        jobs.append(Job(delay: seconds, work: work))
        let index = jobs.count - 1
        return { [weak self] in self?.jobs[index].cancelled = true }
    }

    /// Runs every job that was not cancelled, once.
    func fireAll() {
        for index in jobs.indices where !jobs[index].cancelled {
            jobs[index].cancelled = true
            jobs[index].work()
        }
    }
}

func makeSession(
    id: String = "run-1", key: String = "key-1", alternates: [String] = [],
    profile: String = "default", dashboard: UUID? = nil, title: String = "Refactor billing"
) -> MacNotificationSession {
    MacNotificationSession(sessionId: id, sessionKey: key, alternateIds: alternates, profile: profile, dashboardID: dashboard, title: title)
}
```

`ConduitMacTests/MacNotificationContentTests.swift`:

```swift
import UserNotifications
import XCTest
@testable import ConduitMac

final class MacNotificationContentTests: XCTestCase {
    private let session = makeSessionNonisolated()

    func testDoneRequest() {
        let r = MacNotificationContent.done(session: session, turnId: "t1", preview: "All 14 files migrated.", sound: true)
        XCTAssertEqual(r.identifier, "conduit.done.key-1")
        XCTAssertEqual(r.content.title, "Refactor billing")
        XCTAssertEqual(r.content.body, "All 14 files migrated.")
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_DONE")
        XCTAssertEqual(r.content.threadIdentifier, "session-key-1")
        XCTAssertEqual(r.content.interruptionLevel, .active)
        XCTAssertNotNil(r.content.sound)
        XCTAssertNil(r.trigger)
    }

    func testDoneWithoutPreviewSaysFinishedAndSoundCanBeOff() {
        let r = MacNotificationContent.done(session: session, turnId: "t1", preview: "  \n ", sound: false)
        XCTAssertEqual(r.content.body, "Finished")
        XCTAssertNil(r.content.sound)
    }

    func testPreviewIsCollapsedAndTruncatedTo140() {
        let long = String(repeating: "word ", count: 80)
        let body = MacNotificationContent.done(session: session, turnId: "t", preview: long, sound: false).content.body
        XCTAssertLessThanOrEqual(body.count, 140)
        XCTAssertTrue(body.hasSuffix("\u{2026}"))
        XCTAssertEqual(MacNotificationContent.truncated("a\n\nb", limit: 140), "a b")
    }

    func testFailedRequestIsOpenOnly() {
        let r = MacNotificationContent.failed(session: session, turnId: "t1", sound: true)
        XCTAssertEqual(r.content.body, "Stopped with an error")
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_OPEN")
        XCTAssertEqual(r.identifier, "conduit.done.key-1")
    }

    func testSummaryRequest() {
        let r = MacNotificationContent.doneSummary(count: 5, sound: true)
        XCTAssertEqual(r.identifier, "conduit.done.summary")
        XCTAssertTrue(r.content.title.contains("5"))
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_OPEN")
    }

    func testApprovalRequestCarriesCommandAsSubtitleAndPicksCategoryFromMapping() {
        let both = MacApprovalChoiceMapper.Mapping(approve: "once", deny: "deny")
        let r = MacNotificationContent.approval(session: session, requestId: "r9", description: "Run a shell command", command: "rm -rf build", mapping: both, sound: true)
        XCTAssertEqual(r.identifier, "conduit.approval.r9")
        XCTAssertEqual(r.content.subtitle, "rm -rf build")
        XCTAssertEqual(r.content.body, "Run a shell command")
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_APPROVAL")
        let denyOnly = MacNotificationContent.approval(session: session, requestId: "r9", description: "d", command: "c", mapping: .init(approve: nil, deny: "deny"), sound: true)
        XCTAssertEqual(denyOnly.content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
        let none = MacNotificationContent.approval(session: session, requestId: "r9", description: "d", command: "c", mapping: .init(approve: nil, deny: nil), sound: true)
        XCTAssertEqual(none.content.categoryIdentifier, "CONDUIT_OPEN")
    }

    func testApprovalWithoutDescriptionUsesTheCommandAsBody() {
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "", command: "ls", mapping: .init(approve: "once", deny: "deny"), sound: false)
        XCTAssertEqual(r.content.body, "ls")
        XCTAssertEqual(r.content.subtitle, "")
    }

    func testLongCommandSubtitleIsTruncated() {
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "d", command: String(repeating: "x", count: 300), mapping: .init(approve: "once", deny: "deny"), sound: false)
        XCTAssertLessThanOrEqual(r.content.subtitle.count, 80)
    }

    func testQuestionRequestOffersReplyOnlyForASingleOpenQuestion() {
        let one = MacNotificationContent.question(session: session, requestId: "q1", text: "Which branch?", openQuestionCount: 1, sound: true)
        XCTAssertEqual(one.identifier, "conduit.question.q1")
        XCTAssertEqual(one.content.body, "Which branch?")
        XCTAssertEqual(one.content.categoryIdentifier, "CONDUIT_QUESTION")
        let batch = MacNotificationContent.question(session: session, requestId: "q1", text: "Which branch?", openQuestionCount: 3, sound: true)
        XCTAssertEqual(batch.content.categoryIdentifier, "CONDUIT_OPEN", "a batch has no Reply; the click opens the session")
    }

    func testEmptyTitleFallsBackToConduit() {
        let s = makeSessionNonisolated(title: "  ")
        XCTAssertEqual(MacNotificationContent.done(session: s, turnId: "t", preview: "x", sound: false).content.title, "Conduit")
    }

    func testPayloadRoundTripsAndCarriesNoMessageText() throws {
        let dash = UUID()
        let s = makeSessionNonisolated(dashboard: dash)
        let r = MacNotificationContent.approval(session: s, requestId: "r9", description: "SECRET DESCRIPTION", command: "SECRET CMD", mapping: .init(approve: "once", deny: "deny"), sound: false)
        let payload = try XCTUnwrap(MacNotificationPayload(userInfo: r.content.userInfo))
        XCTAssertEqual(payload.kind, .approval)
        XCTAssertEqual(payload.sessionId, "run-1")
        XCTAssertEqual(payload.sessionKey, "key-1")
        XCTAssertEqual(payload.profile, "default")
        XCTAssertEqual(payload.dashboardID, dash)
        XCTAssertEqual(payload.requestId, "r9")
        let dump = "\(r.content.userInfo)"
        XCTAssertFalse(dump.contains("SECRET"))
    }

    func testPayloadRejectsMissingSessionId() {
        XCTAssertNil(MacNotificationPayload(userInfo: ["conduit_mac": ["kind": "done"]]))
        XCTAssertNil(MacNotificationPayload(userInfo: [:]))
    }
}

/// `makeSession` is main-actor-free (a plain value builder).
private func makeSessionNonisolated(
    id: String = "run-1", key: String = "key-1", profile: String = "default", dashboard: UUID? = nil, title: String = "Refactor billing"
) -> MacNotificationSession {
    MacNotificationSession(sessionId: id, sessionKey: key, alternateIds: [], profile: profile, dashboardID: dashboard, title: title)
}
```

(If `makeSession` in the fakes file is not actor-isolated it can be used directly; it is a free function, so the private duplicate above may be deleted when the compiler accepts `makeSession` from a nonisolated context.)

`ConduitMacTests/MacNotificationCategoriesTests.swift`:

```swift
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationCategoriesTests: XCTestCase {
    func testOurCategoriesAndTheirActions() {
        let byID = Dictionary(uniqueKeysWithValues: MacNotificationCategories.ours().map { ($0.identifier, $0) })
        XCTAssertEqual(Set(byID.keys), ["CONDUIT_DONE", "CONDUIT_OPEN", "CONDUIT_APPROVAL", "CONDUIT_APPROVAL_DENY", "CONDUIT_APPROVAL_APPROVE", "CONDUIT_QUESTION"])
        XCTAssertEqual(byID["CONDUIT_DONE"]?.actions.map(\.identifier), ["conduit.action.reply", "conduit.action.open"])
        XCTAssertEqual(byID["CONDUIT_QUESTION"]?.actions.map(\.identifier), ["conduit.action.reply", "conduit.action.open"])
        XCTAssertEqual(byID["CONDUIT_APPROVAL"]?.actions.map(\.identifier), ["conduit.action.approve", "conduit.action.deny", "conduit.action.open"])
        XCTAssertEqual(byID["CONDUIT_OPEN"]?.actions.map(\.identifier), ["conduit.action.open"])
    }

    func testReplyIsATextInputThatDoesNotForegroundTheApp() throws {
        let done = try XCTUnwrap(MacNotificationCategories.ours().first { $0.identifier == "CONDUIT_DONE" })
        let reply = try XCTUnwrap(done.actions.first { $0.identifier == "conduit.action.reply" })
        XCTAssertTrue(reply is UNTextInputNotificationAction)
        XCTAssertFalse(reply.options.contains(.foreground))
    }

    func testApproveAndDenyRequireAuthenticationAndDoNotForeground() throws {
        let approval = try XCTUnwrap(MacNotificationCategories.ours().first { $0.identifier == "CONDUIT_APPROVAL" })
        for id in ["conduit.action.approve", "conduit.action.deny"] {
            let action = try XCTUnwrap(approval.actions.first { $0.identifier == id })
            XCTAssertTrue(action.options.contains(.authenticationRequired), id)
            XCTAssertFalse(action.options.contains(.foreground), id)
        }
        let open = try XCTUnwrap(approval.actions.first { $0.identifier == "conduit.action.open" })
        XCTAssertTrue(open.options.contains(.foreground))
    }

    func testNoCategoryOffersAlwaysOrSession() {
        for category in MacNotificationCategories.ours() {
            for action in category.actions {
                XCTAssertFalse(action.identifier.contains("always") || action.identifier.contains("session"))
            }
        }
    }

    func testApprovalCategorySelection() {
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: "once", deny: "deny")), "CONDUIT_APPROVAL")
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: nil, deny: "deny")), "CONDUIT_APPROVAL_DENY")
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: "once", deny: nil)), "CONDUIT_APPROVAL_APPROVE")
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: nil, deny: nil)), "CONDUIT_OPEN")
    }

    func testRegisterMergesWithForeignCategoriesInsteadOfReplacingThem() async {
        let center = FakeNotificationCenter()
        let foreign = UNNotificationCategory(identifier: "HERMES_CALL", actions: [], intentIdentifiers: [], options: [])
        center.stored = [foreign]
        await MacNotificationCategories.register(on: center)
        XCTAssertTrue(center.stored.contains { $0.identifier == "HERMES_CALL" }, "HermesCallNotifications' category survives")
        XCTAssertTrue(center.stored.contains { $0.identifier == "CONDUIT_DONE" })
    }

    func testRegisterIsIdempotentAndReplacesOurStaleCopiesOnly() async {
        let center = FakeNotificationCenter()
        let stale = UNNotificationCategory(identifier: "CONDUIT_DONE", actions: [], intentIdentifiers: [], options: [])
        center.stored = [stale]
        await MacNotificationCategories.register(on: center)
        await MacNotificationCategories.register(on: center)
        let done = center.stored.filter { $0.identifier == "CONDUIT_DONE" }
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.actions.count, 2, "the stale empty copy was replaced by the current one (re-register on language change)")
        XCTAssertEqual(center.stored.count, MacNotificationCategories.ours().count)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationContentTests -only-testing:ConduitMacTests/MacNotificationCategoriesTests`
Expected: build failure (types missing).

- [ ] **Step 3: Implement**

`ConduitMac/Notifications/MacNotificationCenterClient.swift`:

```swift
import Foundation
import OSLog
import UserNotifications

let macNotificationsLogger = Logger(subsystem: "com.milim.conduit.mac", category: "notifications")

/// The slice of `UNUserNotificationCenter` the coordinator needs. Tests inject
/// a fake; the real adapter is built only by `MacNotificationRuntime`.
@MainActor
protocol MacNotificationCenterClient: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removeDelivered(_ identifiers: [String])
    func removePending(_ identifiers: [String])
    func categories() async -> Set<UNNotificationCategory>
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

@MainActor
final class UNMacNotificationCenterClient: MacNotificationCenterClient {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func categories() async -> Set<UNNotificationCategory> { await center.notificationCategories() }
    func setCategories(_ categories: Set<UNNotificationCategory>) { center.setNotificationCategories(categories) }
}

/// Delayed work for the approval grace window. The returned closure cancels.
@MainActor
protocol MacNotificationScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
final class MacTaskScheduler: MacNotificationScheduling {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            work()
        }
        return { task.cancel() }
    }
}
```

`ConduitMac/Notifications/MacNotificationCategories.swift`:

```swift
import Foundation
import UserNotifications

/// Conduit's notification categories. `setNotificationCategories` REPLACES the
/// whole set and `HermesCallNotifications.registerCategory` also calls it, so
/// registration reads the current set, drops only Conduit's own identifiers
/// and writes the union back. Re-run on app-language change so the button
/// titles localise.
enum MacNotificationCategories {
    static let done = "CONDUIT_DONE"
    static let open = "CONDUIT_OPEN"
    static let approval = "CONDUIT_APPROVAL"
    static let approvalDenyOnly = "CONDUIT_APPROVAL_DENY"
    static let approvalApproveOnly = "CONDUIT_APPROVAL_APPROVE"
    static let question = "CONDUIT_QUESTION"

    static let openAction = "conduit.action.open"
    static let approveAction = "conduit.action.approve"
    static let denyAction = "conduit.action.deny"
    static let replyAction = "conduit.action.reply"

    static let allIdentifiers: Set<String> = [done, open, approval, approvalDenyOnly, approvalApproveOnly, question]

    static func approvalCategory(for mapping: MacApprovalChoiceMapper.Mapping) -> String {
        switch (mapping.approve != nil, mapping.deny != nil) {
        case (true, true): return approval
        case (false, true): return approvalDenyOnly
        case (true, false): return approvalApproveOnly
        case (false, false): return open
        }
    }

    static func ours() -> Set<UNNotificationCategory> {
        let openButton = UNNotificationAction(identifier: openAction, title: AppLocalization.string("Open"), options: [.foreground])
        let approve = UNNotificationAction(identifier: approveAction, title: AppLocalization.string("Approve"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: AppLocalization.string("Deny"), options: [.authenticationRequired, .destructive])
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: AppLocalization.string("Reply"),
            options: [],
            textInputButtonTitle: AppLocalization.string("Send"),
            textInputPlaceholder: AppLocalization.string("Message")
        )
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        }
        return [
            category(done, [reply, openButton]),
            category(open, [openButton]),
            category(approval, [approve, deny, openButton]),
            category(approvalDenyOnly, [deny, openButton]),
            category(approvalApproveOnly, [approve, openButton]),
            category(question, [reply, openButton]),
        ]
    }

    @MainActor
    static func register(on center: MacNotificationCenterClient) async {
        let existing = await center.categories()
        let foreign = existing.filter { !allIdentifiers.contains($0.identifier) }
        center.setCategories(foreign.union(ours()))
    }
}
```

`ConduitMac/Notifications/MacNotificationContent.swift`:

```swift
import Foundation
import UserNotifications

/// What a notification's tap, button or reply needs to find its session.
/// Lives in `userInfo["conduit_mac"]`; carries ids only, never message text.
struct MacNotificationPayload: Equatable {
    var kind: MacNotificationKind
    var sessionId: String
    var sessionKey: String
    var profile: String
    var dashboardID: UUID?
    var requestId: String?
    /// Open questions in a clarify request; Reply exists only for 1.
    var questionCount: Int = 1

    var userInfo: [AnyHashable: Any] {
        var routing: [String: Any] = [
            "kind": kind.rawValue,
            "session_id": sessionId,
            "session_key": sessionKey,
            "profile": profile,
            "question_count": questionCount,
        ]
        if let dashboardID { routing["dashboard_id"] = dashboardID.uuidString }
        if let requestId { routing["request_id"] = requestId }
        return [MacNotificationContent.payloadKey: routing]
    }

    init(kind: MacNotificationKind, sessionId: String, sessionKey: String, profile: String, dashboardID: UUID?, requestId: String?, questionCount: Int = 1) {
        self.kind = kind; self.sessionId = sessionId; self.sessionKey = sessionKey
        self.profile = profile; self.dashboardID = dashboardID; self.requestId = requestId
        self.questionCount = questionCount
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let routing = userInfo[MacNotificationContent.payloadKey] as? [String: Any],
              let sessionId = (routing["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else { return nil }
        self.kind = (routing["kind"] as? String).flatMap(MacNotificationKind.init(rawValue:)) ?? .done
        self.sessionId = sessionId
        self.sessionKey = (routing["session_key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionId
        self.profile = (routing["profile"] as? String) ?? "default"
        self.dashboardID = (routing["dashboard_id"] as? String).flatMap(UUID.init(uuidString:))
        self.requestId = routing["request_id"] as? String
        self.questionCount = (routing["question_count"] as? Int) ?? 1
    }
}

enum MacNotificationContent {
    static let payloadKey = "conduit_mac"
    static let previewLimit = 140
    static let commandLimit = 80

    /// Whitespace collapsed to single spaces, cut to `limit` characters with an ellipsis.
    static func truncated(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "\u{2026}"
    }

    private static func title(for session: MacNotificationSession) -> String {
        let t = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? AppLocalization.string("Conduit") : t
    }

    private static func content(
        session: MacNotificationSession, kind: MacNotificationKind, requestId: String?, questionCount: Int = 1,
        category: String, body: String, subtitle: String = "", sound: Bool
    ) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title(for: session)
        c.subtitle = subtitle
        c.body = body
        c.categoryIdentifier = category
        c.threadIdentifier = MacNotificationPolicy.ID.thread(session.sessionKey)
        c.interruptionLevel = .active
        if sound { c.sound = .default }
        c.userInfo = MacNotificationPayload(
            kind: kind, sessionId: session.sessionId, sessionKey: session.sessionKey, profile: session.profile,
            dashboardID: session.dashboardID, requestId: requestId, questionCount: questionCount
        ).userInfo
        return c
    }

    static func done(session: MacNotificationSession, turnId: String, preview: String?, sound: Bool) -> UNNotificationRequest {
        let text = truncated(preview ?? "", limit: previewLimit)
        let c = content(session: session, kind: .done, requestId: nil, category: MacNotificationCategories.done,
                        body: text.isEmpty ? AppLocalization.string("Finished") : text, sound: sound)
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.done(session.sessionKey), content: c, trigger: nil)
    }

    static func failed(session: MacNotificationSession, turnId: String, sound: Bool) -> UNNotificationRequest {
        let c = content(session: session, kind: .failed, requestId: nil, category: MacNotificationCategories.open,
                        body: AppLocalization.string("Stopped with an error"), sound: sound)
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.done(session.sessionKey), content: c, trigger: nil)
    }

    static func doneSummary(count finishedCount: Int, sound: Bool) -> UNNotificationRequest {
        let c = UNMutableNotificationContent()
        c.title = AppLocalization.string("\(finishedCount) conversations finished")
        c.categoryIdentifier = MacNotificationCategories.open
        c.interruptionLevel = .active
        if sound { c.sound = .default }
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.doneSummary, content: c, trigger: nil)
    }

    static func approval(
        session: MacNotificationSession, requestId: String, description: String, command: String,
        mapping: MacApprovalChoiceMapper.Mapping, sound: Bool
    ) -> UNNotificationRequest {
        let desc = truncated(description, limit: previewLimit)
        let cmd = truncated(command, limit: commandLimit)
        let c = content(
            session: session, kind: .approval, requestId: requestId,
            category: MacNotificationCategories.approvalCategory(for: mapping),
            body: desc.isEmpty ? cmd : desc, subtitle: desc.isEmpty ? "" : cmd, sound: sound
        )
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.approval(requestId), content: c, trigger: nil)
    }

    static func question(session: MacNotificationSession, requestId: String, text: String, openQuestionCount: Int, sound: Bool) -> UNNotificationRequest {
        let c = content(
            session: session, kind: .question, requestId: requestId, questionCount: openQuestionCount,
            category: openQuestionCount == 1 ? MacNotificationCategories.question : MacNotificationCategories.open,
            body: truncated(text, limit: previewLimit), sound: sound
        )
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.question(requestId), content: c, trigger: nil)
    }

    /// "Couldn't send" after a failed action. `reply` picks the wording.
    static func notice(session: MacNotificationSession, reply: Bool, sound: Bool) -> UNNotificationRequest {
        let body = reply
            ? AppLocalization.string("Couldn't send your reply. Open Conduit.")
            : AppLocalization.string("Couldn't send your answer. Open Conduit.")
        let c = content(session: session, kind: .notice, requestId: nil, category: MacNotificationCategories.open, body: body, sound: sound)
        return UNNotificationRequest(identifier: MacNotificationPolicy.ID.notice(UUID()), content: c, trigger: nil)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: the Step 2 command. Expected: PASS. If `AppLocalization.string("\(finishedCount) conversations finished")` does not resolve a plural at test time, the test only asserts the number is present; do not weaken it.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacNotificationCenterClient.swift ConduitMac/Notifications/MacNotificationContent.swift ConduitMac/Notifications/MacNotificationCategories.swift ConduitMacTests/MacNotificationFakes.swift ConduitMacTests/MacNotificationContentTests.swift ConduitMacTests/MacNotificationCategoriesTests.swift
git commit -m "macOS notifications: center client, content builders, merged categories"
```

---

### Task 5: Coordinator core (Done, Failed, authorization, suppression, dedupe)

**Files:**
- Create: `ConduitMac/Notifications/MacNotificationCoordinator.swift`
- Test: `ConduitMacTests/MacNotificationCoordinatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 4.
- Produces: `@MainActor final class MacNotificationCoordinator` with
  - `init(center: MacNotificationCenterClient, preferences: MacNotificationPreferences, scheduler: MacNotificationScheduling, visibility: @escaping (MacNotificationSession) -> MacNotificationVisibility, now: @escaping () -> Date = Date.init)`
  - `func handle(_ event: MacNotificationEvent)` (sync entry; work is serialized on an internal chain)
  - `func drain() async` (awaits the chain; tests and shutdown)
  - `func recheckAttention()` (Task 6 fills the decision half; Task 5 ships removal of delivered Done items for sessions that became attended)
  - `func postNotice(for payload: MacNotificationPayload, reply: Bool)` (used by Task 7)
  - `func languageDidChange()` re-registers categories

Behaviour in this task: `turnStarted` records the start; `turnFinished` with `interrupted` never notifies; `completed`/`failed` post only when long-running (threshold from preferences at finish time); `sessionTitleChanged` updates the title used at post time; events with `eventId` less than or equal to the last seen for the session are dropped; posted-set dedupes per turn id; the Done burst limiter collapses to the summary; authorization is requested lazily, only when the app is inactive; the suppression rule is checked before and after the authorization await; a failing `add` is logged and dropped.

- [ ] **Step 1: Write the failing tests**

```swift
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationCoordinatorTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var prefs: MacNotificationPreferences!
    private var center: FakeNotificationCenter!
    private var scheduler: FakeScheduler!
    private var coordinator: MacNotificationCoordinator!
    private var visibility = MacNotificationVisibility.away
    private var clock = Date(timeIntervalSince1970: 2_000_000)
    private var nextEvent = 1

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        prefs = MacNotificationPreferences(defaults: suite.defaults)
        center = FakeNotificationCenter()
        scheduler = FakeScheduler()
        visibility = .away
        clock = Date(timeIntervalSince1970: 2_000_000)
        nextEvent = 1
        coordinator = MacNotificationCoordinator(
            center: center, preferences: prefs, scheduler: scheduler,
            visibility: { [unowned self] _ in self.visibility }, now: { [unowned self] in self.clock }
        )
    }

    override func tearDown() async throws {
        await coordinator.drain()
        coordinator = nil
        HostedTestSupport.dropSuite(suite)
    }

    // MARK: helpers
    private func send(_ kind: MacNotificationEvent.Kind, session: MacNotificationSession = makeSession(), id: Int? = nil) {
        defer { nextEvent += 1 }
        coordinator.handle(MacNotificationEvent(eventId: id ?? nextEvent, session: session, kind: kind))
    }
    private func turn(_ seconds: TimeInterval, turnId: String = "t1", outcome: MacNotificationEvent.Outcome = .completed,
                      preview: String? = "Done.", session: MacNotificationSession = makeSession()) async {
        send(.turnStarted(turnId: turnId, at: clock), session: session)
        send(.turnFinished(turnId: turnId, at: clock.addingTimeInterval(seconds), outcome: outcome, replyPreview: preview), session: session)
        await coordinator.drain()
    }

    // MARK: tests
    func testShortTurnDoesNotNotify() async {
        await turn(29.9)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testThresholdTurnPostsDone() async {
        await turn(30)
        XCTAssertEqual(center.identifiers, ["conduit.done.key-1"])
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_DONE")
        XCTAssertEqual(center.added[0].content.body, "Done.")
    }

    func testThresholdFollowsThePreference() async {
        prefs.threshold = 120
        await turn(60)
        XCTAssertTrue(center.added.isEmpty)
        await turn(120, turnId: "t2")
        XCTAssertEqual(center.added.count, 1)
    }

    func testFailedLongTurnPostsStoppedWithAnError() async {
        await turn(45, outcome: .failed)
        XCTAssertEqual(center.added.first?.content.body, "Stopped with an error")
        XCTAssertEqual(center.added.first?.content.categoryIdentifier, "CONDUIT_OPEN")
    }

    func testFailedShortTurnDoesNotNotify() async {
        await turn(5, outcome: .failed)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testInterruptedNeverNotifiesEvenWhenLong() async {
        await turn(600, outcome: .interrupted)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testFinishWithoutAStartPostsNothing() async {
        send(.turnFinished(turnId: "ghost", at: clock, outcome: .completed, replyPreview: "x"))
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "no start observed, so the duration is unknown")
    }

    func testAttendedSessionIsSuppressedAtPostTime() async {
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        await turn(60)
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testReplayedFinishPostsOnceEvenWithNewEventIds() async {
        send(.turnStarted(turnId: "t1", at: clock))
        let finish = MacNotificationEvent.Kind.turnFinished(turnId: "t1", at: clock.addingTimeInterval(40), outcome: .completed, replyPreview: "x")
        send(finish)
        send(finish)
        send(finish, id: 99)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
    }

    func testStaleEventIdIsDropped() async {
        send(.turnStarted(turnId: "t1", at: clock), id: 10)
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(40), outcome: .completed, replyPreview: "x"), id: 5)
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "an event at or below the last seen id for the session is a replay")
    }

    func testNewerFinishReplacesTheOlderDoneByIdentifier() async {
        await turn(40, turnId: "t1")
        await turn(40, turnId: "t2")
        XCTAssertEqual(center.identifiers, ["conduit.done.key-1", "conduit.done.key-1"], "same identifier, so the system replaces the older banner")
    }

    func testTitleChangeIsUsedAtPostTime() async {
        send(.sessionTitleChanged(title: "Billing cleanup"))
        await turn(40)
        XCTAssertEqual(center.added.first?.content.title, "Billing cleanup")
    }

    func testSoundPreference() async {
        prefs.soundEnabled = false
        await turn(40)
        XCTAssertNil(center.added.first?.content.sound)
    }

    func testMasterAndKindTogglesGate() async {
        prefs.notifiesDone = false
        await turn(40)
        XCTAssertTrue(center.added.isEmpty)
        prefs.notifiesDone = true
        prefs.isEnabled = false
        await turn(40, turnId: "t2")
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testNoAuthorizationRequestUntilTheFirstEligibleEvent() async {
        center.status = .notDetermined
        await turn(5)
        XCTAssertEqual(center.authorizationRequests, 0, "a short turn is not an eligible event")
        await turn(40, turnId: "t2")
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.added.count, 1)
        await turn(40, turnId: "t3")
        XCTAssertEqual(center.authorizationRequests, 1, "asked once")
    }

    func testUndeterminedWhileTheAppIsActiveButUnattendedDoesNotPrompt() async {
        center.status = .notDetermined
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: false)
        await turn(40)
        XCTAssertEqual(center.authorizationRequests, 0, "the prompt only appears while Conduit is inactive")
        XCTAssertTrue(center.added.isEmpty)
    }

    func testDeniedPostsNothingAndNeverRetries() async {
        center.status = .denied
        await turn(40)
        await turn(40, turnId: "t2")
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testDeclinedPromptPostsNothing() async {
        center.status = .notDetermined
        center.grantOnRequest = false
        await turn(40)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testAddFailureIsSwallowed() async {
        struct Boom: Error {}
        center.addError = Boom()
        await turn(40)
        XCTAssertTrue(center.added.isEmpty)
        center.addError = nil
        await turn(40, turnId: "t2")
        XCTAssertEqual(center.added.count, 1, "the coordinator keeps working")
    }

    func testBurstCollapsesToASummary() async {
        for i in 1...5 {
            let s = makeSession(id: "r\(i)", key: "k\(i)", title: "S\(i)")
            await turn(40, turnId: "t\(i)", session: s)
            clock = clock.addingTimeInterval(1)
        }
        XCTAssertEqual(center.identifiers.prefix(3), ["conduit.done.k1", "conduit.done.k2", "conduit.done.k3"])
        XCTAssertEqual(center.identifiers.suffix(2), ["conduit.done.summary", "conduit.done.summary"])
        XCTAssertTrue(center.added.last!.content.title.contains("5"))
    }

    func testBecomingAttendedRemovesDeliveredDone() async {
        await turn(40)
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        coordinator.recheckAttention()
        XCTAssertEqual(center.removedDelivered, ["conduit.done.key-1"])
        XCTAssertEqual(center.removedPending, ["conduit.done.key-1"])
        coordinator.recheckAttention()
        XCTAssertEqual(center.removedDelivered.count, 1, "removed once")
    }

    func testLanguageChangeReRegistersCategoriesWithoutLosingForeignOnes() async {
        let foreign = UNNotificationCategory(identifier: "HERMES_CALL", actions: [], intentIdentifiers: [], options: [])
        center.stored = [foreign]
        coordinator.languageDidChange()
        await coordinator.drain()
        XCTAssertTrue(center.stored.contains { $0.identifier == "HERMES_CALL" })
        XCTAssertTrue(center.stored.contains { $0.identifier == "CONDUIT_DONE" })
    }

    func testCategoriesAreRegisteredBeforeTheFirstPost() async {
        await turn(40)
        XCTAssertTrue(center.stored.contains { $0.identifier == "CONDUIT_DONE" })
    }

    func testNoticeBypassesSuppressionButHonoursTheMasterToggle() async {
        visibility = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        let payload = MacNotificationPayload(kind: .done, sessionId: "run-1", sessionKey: "key-1", profile: "default", dashboardID: nil, requestId: nil)
        coordinator.postNotice(for: payload, reply: true)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_OPEN")
        prefs.isEnabled = false
        coordinator.postNotice(for: payload, reply: true)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationCoordinatorTests`
Expected: build failure (`MacNotificationCoordinator` missing).

- [ ] **Step 3: Implement**

```swift
import Foundation
import UserNotifications

@MainActor
final class MacNotificationCoordinator {
    private let center: MacNotificationCenterClient
    private let preferences: MacNotificationPreferences
    private let scheduler: MacNotificationScheduling
    private let visibility: (MacNotificationSession) -> MacNotificationVisibility
    private let now: () -> Date

    // State shared with Task 6 (decisions); kept in this one file.
    private(set) var titles: [String: String] = [:]
    private var turnStarts: [String: Date] = [:]
    private var lastEventID: [String: Int] = [:]
    private var posted = MacNotificationPostedSet()
    private var burst = MacDoneBurstLimiter()
    /// identifier -> session, for everything delivered and not yet removed.
    private var delivered: [String: MacNotificationSession] = [:]
    private var categoriesRegistered = false
    private var chain: Task<Void, Never>?

    init(
        center: MacNotificationCenterClient,
        preferences: MacNotificationPreferences,
        scheduler: MacNotificationScheduling,
        visibility: @escaping (MacNotificationSession) -> MacNotificationVisibility,
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.preferences = preferences
        self.scheduler = scheduler
        self.visibility = visibility
        self.now = now
    }

    // MARK: Entry points

    func handle(_ event: MacNotificationEvent) {
        enqueue { [self] in await process(event) }
    }

    /// Serialises async work so events are processed in arrival order even
    /// when a step awaits (authorization, `add`).
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func drain() async {
        while let current = chain {
            await current.value
            if chain == current { chain = nil; return }
        }
    }

    func languageDidChange() {
        enqueue { [self] in
            await MacNotificationCategories.register(on: center)
            categoriesRegistered = true
        }
    }

    /// Call when attention may have changed (app activation, window key, route
    /// or active session change). Removes what the user is now looking at.
    func recheckAttention() {
        for (identifier, session) in delivered where visibility(session).isAttended {
            center.removeDelivered([identifier])
            center.removePending([identifier])
            delivered[identifier] = nil
        }
        retryHeldDecisions()
    }

    func postNotice(for payload: MacNotificationPayload, reply: Bool) {
        let session = MacNotificationSession(
            sessionId: payload.sessionId, sessionKey: payload.sessionKey, alternateIds: [],
            profile: payload.profile, dashboardID: payload.dashboardID, title: titles[payload.sessionKey] ?? ""
        )
        enqueue { [self] in
            await deliver(.notice, session: session, identifier: nil, suppressible: false) {
                MacNotificationContent.notice(session: session, reply: reply, sound: preferences.soundEnabled)
            }
        }
    }

    // MARK: Processing

    private func process(_ event: MacNotificationEvent) async {
        let key = event.session.sessionKey
        if let last = lastEventID[key], event.eventId <= last { return }
        lastEventID[key] = event.eventId

        switch event.kind {
        case .sessionTitleChanged(let title):
            titles[key] = title
        case .turnStarted(let turnId, let at):
            turnStarts[turnKey(event.session, turnId)] = at
        case .turnFinished(let turnId, let at, let outcome, let preview):
            await finish(event.session, turnId: turnId, at: at, outcome: outcome, preview: preview)
        case .approvalRequested, .questionRequested, .decisionResolved:
            processDecision(event)   // Task 6
        }
    }

    private func turnKey(_ session: MacNotificationSession, _ turnId: String) -> String { "\(session.sessionKey)|\(turnId)" }

    private func finish(_ session: MacNotificationSession, turnId: String, at finishedAt: Date, outcome: MacNotificationEvent.Outcome, preview: String?) async {
        let started = turnStarts.removeValue(forKey: turnKey(session, turnId))
        clearOutstanding(for: session)             // Task 6 hook: the turn is over
        guard outcome != .interrupted, let started else { return }
        guard MacNotificationPolicy.isLongRunning(startedAt: started, finishedAt: finishedAt, threshold: preferences.threshold) else { return }
        guard !toldAlreadyByDecision(session) else { return }        // Task 6 hook
        guard posted.insert(.done, turnId) else { return }
        let kind: MacNotificationKind = outcome == .failed ? .failed : .done
        guard preferences.allows(kind) else { return }
        let sound = preferences.soundEnabled
        switch burst.register(at: now()) {
        case .individual:
            await deliver(kind, session: session, identifier: MacNotificationPolicy.ID.done(session.sessionKey)) {
                outcome == .failed
                    ? MacNotificationContent.failed(session: session, turnId: turnId, sound: sound)
                    : MacNotificationContent.done(session: session, turnId: turnId, preview: preview, sound: sound)
            }
        case .summary(let count):
            await deliver(kind, session: session, identifier: MacNotificationPolicy.ID.doneSummary) {
                MacNotificationContent.doneSummary(count: count, sound: sound)
            }
        }
    }

    /// The one place that posts. Suppression is evaluated at post time, before
    /// and again after the authorization await.
    func deliver(
        _ kind: MacNotificationKind, session: MacNotificationSession, identifier: String?, suppressible: Bool = true,
        build: () -> UNNotificationRequest
    ) async {
        guard preferences.allows(kind) else { return }
        let before = visibility(session)
        if suppressible, MacNotificationPolicy.shouldSuppress(before) { return }
        guard await ensureAuthorized(appIsActive: before.appIsActive) else { return }
        if suppressible, MacNotificationPolicy.shouldSuppress(visibility(session)) { return }
        if !categoriesRegistered {
            await MacNotificationCategories.register(on: center)
            categoriesRegistered = true
        }
        let request = build()
        do {
            try await center.add(request)
            delivered[request.identifier] = session
        } catch {
            macNotificationsLogger.error("Notification not posted: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureAuthorized(appIsActive: Bool) async -> Bool {
        switch await center.authorizationStatus() {
        case .authorized, .provisional: return true
        case .notDetermined:
            // The first eligible event while Conduit is inactive asks.
            guard !appIsActive else { return false }
            return await center.requestAuthorization()
        default: return false
        }
    }

    // Task 6 fills these three; Task 5 compiles with the empty versions below.
    private func processDecision(_ event: MacNotificationEvent) {}
    private func clearOutstanding(for session: MacNotificationSession) {}
    private func toldAlreadyByDecision(_ session: MacNotificationSession) -> Bool { false }
    private func retryHeldDecisions() {}
}
```

Note `deliver` takes a non-escaping `build` closure; `enqueue` closures capture `self` strongly on purpose (short-lived chain). `posted`, `burst` and `delivered` are touched only on the main actor inside the chain.

- [ ] **Step 4: Run to verify pass**

Run: the Step 2 command. Expected: PASS. If `testBurstCollapsesToASummary` fails because `FakeNotificationCenter.added` keeps duplicates for the replaced identifier, that is expected (the fake appends); the assertions above are written for that.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacNotificationCoordinator.swift ConduitMacTests/MacNotificationCoordinatorTests.swift
git commit -m "macOS notifications: coordinator core (Done, Failed, authorization, dedupe)"
```

---

### Task 6: Coordinator decisions (approvals, questions, grace, supersede, held-back)

**Files:**
- Modify: `ConduitMac/Notifications/MacNotificationCoordinator.swift` (replace the four stub methods; add stored properties)
- Test: `ConduitMacTests/MacNotificationDecisionTests.swift`

**Interfaces:**
- Consumes: Task 5 coordinator, Task 2 mapper, Task 4 `FakeScheduler`.
- Produces: the decision half of `handle(_:)`. No new public API.

Behaviour:
- `approvalRequested` / `questionRequested`: dedupe on the request id (posted-set slot `.approval` / `.question`), record the request as outstanding for the session, then schedule a delivery after `MacNotificationPolicy.approvalGrace` (3 s) with the scheduler. The grace work enqueues the delivery; the title is read at fire time.
- `decisionResolved` (any reason): cancel the pending grace job, remove delivered and pending requests for both identifiers (`conduit.approval.<id>`, `conduit.question.<id>`), drop the request from outstanding and from held-back. The posted-set keeps the id so a replayed `*Requested` cannot re-post a resolved decision.
- Suppressed at fire time (the user is looking at it): the decision is kept in `held` and retried by `recheckAttention()` with no new grace; this fixes "approval pending, user then leaves".
- Done is skipped when the session still had an outstanding decision at turn end (that item already told the user); outstanding is cleared when the turn finishes.
- Mapper result with neither Approve nor Deny posts with `CONDUIT_OPEN`. Question with `openQuestionCount > 1` has no Reply (Task 4).

- [ ] **Step 1: Write the failing tests**

```swift
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationDecisionTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var prefs: MacNotificationPreferences!
    private var center: FakeNotificationCenter!
    private var scheduler: FakeScheduler!
    private var coordinator: MacNotificationCoordinator!
    private var visibility = MacNotificationVisibility.away
    private var clock = Date(timeIntervalSince1970: 3_000_000)
    private var nextEvent = 1
    private let attended = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        prefs = MacNotificationPreferences(defaults: suite.defaults)
        center = FakeNotificationCenter()
        scheduler = FakeScheduler()
        visibility = .away
        nextEvent = 1
        coordinator = MacNotificationCoordinator(
            center: center, preferences: prefs, scheduler: scheduler,
            visibility: { [unowned self] _ in self.visibility }, now: { [unowned self] in self.clock }
        )
    }

    override func tearDown() async throws {
        await coordinator.drain()
        coordinator = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func send(_ kind: MacNotificationEvent.Kind, session: MacNotificationSession = makeSession()) {
        defer { nextEvent += 1 }
        coordinator.handle(MacNotificationEvent(eventId: nextEvent, session: session, kind: kind))
    }
    private func requestApproval(_ id: String = "r1", choices: [String]? = ["once", "session", "always", "deny"]) {
        send(.approvalRequested(requestId: id, description: "Run tests", command: "swift test", choices: choices, allowPermanent: true))
    }
    private func settle() async {
        await coordinator.drain()
        scheduler.fireAll()
        await coordinator.drain()
    }

    func testApprovalWaitsForTheGraceThenPosts() async {
        requestApproval()
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "nothing before the 3 s grace")
        XCTAssertEqual(scheduler.jobs.map(\.delay), [3])
        await settle()
        XCTAssertEqual(center.identifiers, ["conduit.approval.r1"])
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_APPROVAL")
        XCTAssertEqual(center.added[0].content.subtitle, "swift test")
    }

    func testSmartDeniedApprovalStillOffersApproveOnceAndDeny() async {
        requestApproval(choices: ["once", "deny"])
        await settle()
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_APPROVAL")
    }

    func testApprovalWithoutOnceDropsApprove() async {
        requestApproval(choices: ["always", "deny"])
        await settle()
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
    }

    func testResolvedInsideTheGraceNeverPosts() async {
        requestApproval()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        await settle()
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(scheduler.cancelledCount, 1)
    }

    func testResolvedAfterDeliveryRemovesTheBanner() async {
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .expired))
        await coordinator.drain()
        XCTAssertTrue(center.removedDelivered.contains("conduit.approval.r1"))
        XCTAssertTrue(center.removedPending.contains("conduit.approval.r1"))
    }

    func testReplayedRequestAfterResolutionDoesNotRepost() async {
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        requestApproval()
        await settle()
        XCTAssertEqual(center.added.count, 1)
    }

    func testDuplicateRequestSchedulesOnce() async {
        requestApproval()
        requestApproval()
        await settle()
        XCTAssertEqual(center.added.count, 1)
    }

    func testSuppressedDecisionPostsWhenTheUserLeaves() async {
        visibility = attended
        requestApproval()
        await settle()
        XCTAssertTrue(center.added.isEmpty, "the user is looking at it")
        visibility = .away
        coordinator.recheckAttention()
        await coordinator.drain()
        XCTAssertEqual(center.identifiers, ["conduit.approval.r1"])
        coordinator.recheckAttention()
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1, "held decisions post once")
    }

    func testHeldDecisionResolvedWhileAttendedNeverPosts() async {
        visibility = attended
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        visibility = .away
        coordinator.recheckAttention()
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty)
    }

    func testQuestionPostsWithReplyForOneAndNotForABatch() async {
        send(.questionRequested(requestId: "q1", firstQuestionText: "Which branch?", openQuestionCount: 1))
        send(.questionRequested(requestId: "q2", firstQuestionText: "Pick one", openQuestionCount: 3))
        await settle()
        let byID = Dictionary(uniqueKeysWithValues: center.added.map { ($0.identifier, $0.content.categoryIdentifier) })
        XCTAssertEqual(byID["conduit.question.q1"], "CONDUIT_QUESTION")
        XCTAssertEqual(byID["conduit.question.q2"], "CONDUIT_OPEN")
    }

    func testQuestionToggleOffPostsNothing() async {
        prefs.notifiesQuestions = false
        send(.questionRequested(requestId: "q1", firstQuestionText: "x", openQuestionCount: 1))
        await settle()
        XCTAssertTrue(center.added.isEmpty)
    }

    func testApprovalToggleOffPostsNothingButApprovalsDoNotNeedAThreshold() async {
        requestApproval()
        await settle()
        XCTAssertEqual(center.added.count, 1, "no 30 s threshold applies to approvals")
        prefs.notifiesApprovals = false
        requestApproval("r2")
        await settle()
        XCTAssertEqual(center.added.count, 1)
    }

    func testNoDoneWhenADecisionAlreadyToldTheUserThisTurn() async {
        send(.turnStarted(turnId: "t1", at: clock))
        requestApproval()
        await settle()
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(90), outcome: .completed, replyPreview: "ok"))
        await coordinator.drain()
        XCTAssertEqual(center.identifiers, ["conduit.approval.r1"], "no Done after the approval banner")
    }

    func testDoneStillPostsWhenTheDecisionWasResolvedBeforeTheTurnEnded() async {
        send(.turnStarted(turnId: "t1", at: clock))
        requestApproval()
        await settle()
        send(.decisionResolved(requestId: "r1", reason: .answered))
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(90), outcome: .completed, replyPreview: "ok"))
        await coordinator.drain()
        XCTAssertEqual(center.identifiers.last, "conduit.done.key-1")
    }

    func testOutstandingFromAnEarlierTurnDoesNotSuppressTheNextDone() async {
        send(.turnStarted(turnId: "t1", at: clock))
        requestApproval()
        await settle()
        send(.turnFinished(turnId: "t1", at: clock.addingTimeInterval(90), outcome: .completed, replyPreview: "ok"))
        send(.turnStarted(turnId: "t2", at: clock.addingTimeInterval(100)))
        send(.turnFinished(turnId: "t2", at: clock.addingTimeInterval(160), outcome: .completed, replyPreview: "second"))
        await coordinator.drain()
        XCTAssertEqual(center.identifiers.last, "conduit.done.key-1")
    }

    func testDecisionNoticesFromTwoSessionsKeepSeparateThreads() async {
        let other = makeSession(id: "run-2", key: "key-2", title: "Other")
        requestApproval("r1")
        send(.approvalRequested(requestId: "r2", description: "d", command: "c", choices: nil, allowPermanent: false), session: other)
        await settle()
        XCTAssertEqual(Set(center.added.map(\.content.threadIdentifier)), ["session-key-1", "session-key-2"])
    }

    func testTheTitleAtFireTimeIsUsed() async {
        requestApproval()
        send(.sessionTitleChanged(title: "Renamed during grace"))
        await settle()
        XCTAssertEqual(center.added[0].content.title, "Renamed during grace")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationDecisionTests`
Expected: FAIL (stubs do nothing; no notifications post).

- [ ] **Step 3: Implement**

In `MacNotificationCoordinator`, add stored properties next to the others:

```swift
    private struct Held { var session: MacNotificationSession; var kind: MacNotificationEvent.Kind }
    /// requestId -> cancel closure of the grace job.
    private var graceJobs: [String: () -> Void] = [:]
    /// Decisions whose grace ended while the user was looking: retried when attention leaves.
    private var held: [String: Held] = [:]
    /// sessionKey -> request ids announced (or pending) during the current turn.
    private var outstanding: [String: Set<String>] = [:]
```

and replace the four stubs:

```swift
    private func processDecision(_ event: MacNotificationEvent) {
        let session = event.session
        switch event.kind {
        case .approvalRequested(let requestId, _, _, _, _):
            guard posted.insert(.approval, requestId) else { return }
            beginDecision(requestId, session: session, kind: event.kind)
        case .questionRequested(let requestId, _, _):
            guard posted.insert(.question, requestId) else { return }
            beginDecision(requestId, session: session, kind: event.kind)
        case .decisionResolved(let requestId, _):
            graceJobs.removeValue(forKey: requestId)?()
            held[requestId] = nil
            outstanding[session.sessionKey]?.remove(requestId)
            let ids = [MacNotificationPolicy.ID.approval(requestId), MacNotificationPolicy.ID.question(requestId)]
            center.removeDelivered(ids)
            center.removePending(ids)
            for id in ids { delivered[id] = nil }
        default:
            break
        }
    }

    private func beginDecision(_ requestId: String, session: MacNotificationSession, kind: MacNotificationEvent.Kind) {
        outstanding[session.sessionKey, default: []].insert(requestId)
        graceJobs[requestId] = scheduler.schedule(after: MacNotificationPolicy.approvalGrace) { [weak self] in
            guard let self else { return }
            graceJobs[requestId] = nil
            enqueue { [self] in await postDecision(requestId, session: session, kind: kind) }
        }
    }

    private func postDecision(_ requestId: String, session: MacNotificationSession, kind: MacNotificationEvent.Kind) async {
        // Resolved while the post waited in the chain.
        guard outstanding[session.sessionKey]?.contains(requestId) == true else { return }
        var live = session
        live.title = titles[session.sessionKey] ?? session.title
        let sound = preferences.soundEnabled
        switch kind {
        case .approvalRequested(_, let description, let command, let choices, _):
            let mapping = MacApprovalChoiceMapper.map(choices: choices)
            let did = await postIfNotAttended(.approval, session: live, identifier: MacNotificationPolicy.ID.approval(requestId)) {
                MacNotificationContent.approval(session: live, requestId: requestId, description: description, command: command, mapping: mapping, sound: sound)
            }
            if !did { held[requestId] = Held(session: session, kind: kind) }
        case .questionRequested(_, let text, let count):
            let did = await postIfNotAttended(.question, session: live, identifier: MacNotificationPolicy.ID.question(requestId)) {
                MacNotificationContent.question(session: live, requestId: requestId, text: text, openQuestionCount: count, sound: sound)
            }
            if !did { held[requestId] = Held(session: session, kind: kind) }
        default:
            break
        }
    }

    /// True when the request was added. False means suppressed, disabled or
    /// unauthorized; only the suppressed case is worth retrying, and
    /// `recheckAttention` retries every held decision cheaply.
    private func postIfNotAttended(_ kind: MacNotificationKind, session: MacNotificationSession, identifier: String, build: () -> UNNotificationRequest) async -> Bool {
        let before = delivered[identifier] != nil
        await deliver(kind, session: session, identifier: identifier, build: build)
        return !before && delivered[identifier] != nil
    }

    private func clearOutstanding(for session: MacNotificationSession) {
        // Read by `toldAlreadyByDecision` first; cleared right after in `finish`.
    }

    private func toldAlreadyByDecision(_ session: MacNotificationSession) -> Bool {
        defer { outstanding[session.sessionKey] = nil }
        return outstanding[session.sessionKey]?.isEmpty == false
    }

    private func retryHeldDecisions() {
        for (requestId, entry) in held where !visibility(entry.session).isAttended {
            held[requestId] = nil
            enqueue { [self] in await postDecision(requestId, session: entry.session, kind: entry.kind) }
        }
    }
```

Then fix the ordering bug this layout would create in `finish`: `clearOutstanding(for:)` must not run before `toldAlreadyByDecision`. Delete the `clearOutstanding(for: session)` call and its empty method from Task 5's `finish` (the interrupted and short-turn returns must also clear outstanding): replace the top of `finish` with

```swift
        let started = turnStarts.removeValue(forKey: turnKey(session, turnId))
        guard outcome != .interrupted, let started,
              MacNotificationPolicy.isLongRunning(startedAt: started, finishedAt: finishedAt, threshold: preferences.threshold) else {
            outstanding[session.sessionKey] = nil
            return
        }
        guard !toldAlreadyByDecision(session) else { return }
```

and remove the two later lines it supersedes. `postIfNotAttended` relies on `deliver` recording `delivered[identifier]` on success; a held decision whose `postDecision` is retried while a banner for it already exists is not re-added because the identifier would be replaced by the system and `before` is true (the retry returns false and re-holds, which is harmless: `decisionResolved` clears it).

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationDecisionTests -only-testing:ConduitMacTests/MacNotificationCoordinatorTests`
Expected: PASS for both classes (Task 5's tests must still pass after the `finish` edit).

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacNotificationCoordinator.swift ConduitMacTests/MacNotificationDecisionTests.swift
git commit -m "macOS notifications: approvals and questions with grace, supersede and held-back retry"
```

---

### Task 7: Actions (Approve, Deny, Reply) through a thin client-level gateway

**Files:**
- Create: `ConduitMac/Notifications/MacNotificationActions.swift`
- Test: `ConduitMacTests/MacNotificationActionTests.swift`

**Interfaces:**
- Consumes: Task 4 (`MacNotificationPayload`, `MacNotificationCategories` action ids), Task 5 (`MacNotificationCoordinator.postNotice`), `HermesClient.respondToApproval(sessionId:requestId:choice:profile:) async throws -> Bool`, `HermesClient.sendPrompt(_:text:surface:voiceTurn:) async throws -> PromptSubmissionOutcome`, `HermesClient.respondToClarification(requestId:answer:questionId:) async throws -> HermesClient.ClarifyResponseOutcome`, `AppState.isExpiredPromptError(_:)`, `AppState.client`, `AppState.activeProfile`, `AppState.activeDashboardID`, `AppState.isConnected`.
- Produces:
  - `enum MacNotificationActionID: Equatable { case open, approve, deny, reply }`
  - `struct MacNotificationAction: Equatable { var id: MacNotificationActionID; var userText: String?; var payload: MacNotificationPayload; var notificationIdentifier: String; static func make(actionIdentifier: String, userText: String?, userInfo: [AnyHashable: Any], notificationIdentifier: String) -> MacNotificationAction? }` (`UNNotificationDefaultActionIdentifier` maps to `.open`; the dismiss action and unknown ids return nil)
  - `@MainActor protocol MacNotificationGateway: AnyObject { var isConnected: Bool { get }; var activeDashboardID: UUID? { get }; var activeProfile: String { get }; func respondToApproval(sessionId: String, requestId: String, choice: String, profile: String?) async throws -> Bool; func sendPrompt(sessionId: String, text: String) async throws; func answerClarify(requestId: String, answer: String) async throws -> Bool; func isExpired(_ error: Error) -> Bool }`
  - `@MainActor final class MacHermesNotificationGateway: MacNotificationGateway` (`init(appState: AppState)`; reads `appState.client` on each call, never retains the client)
  - `@MainActor final class MacNotificationActionHandler` with `init(gateway:coordinator:router:removeDelivered:)` where `router` is `MacNotificationRouting` (`func route(_ payload: MacNotificationPayload)`, defined in Task 8 as a protocol; a one-method protocol is declared here so this task compiles: `@MainActor protocol MacNotificationRouting: AnyObject { func route(_ payload: MacNotificationPayload) }`) and `func perform(_ action: MacNotificationAction) async`

Rules: Approve sends exactly `"once"`, Deny exactly `"deny"`; no other choice string can be sent. A scope mismatch (payload dashboard differs from `gateway.activeDashboardID` when both are set, or payload profile differs from `gateway.activeProfile`) or a disconnected gateway posts the failure notice and sends nothing (no queued replay). An approval RPC that resolves 0 entries, or throws an expired/4009/"no pending" error, is success. A Reply with only whitespace is ignored. A question Reply is allowed only for `questionCount == 1` and sends a request-level answer (`questionId: nil`); `.expired` outcome is a failure notice. After any action the delivered notification is removed.

- [ ] **Step 1: Write the failing tests**

```swift
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationActionTests: XCTestCase {
    final class Gateway: MacNotificationGateway {
        var isConnected = true
        var activeDashboardID: UUID?
        var activeProfile = "default"
        var approvalResult: Result<Bool, Error> = .success(true)
        var promptError: Error?
        var clarifyResult: Result<Bool, Error> = .success(true)
        var expiredErrors: [String] = ["gone"]
        private(set) var approvals: [(session: String, request: String, choice: String, profile: String?)] = []
        private(set) var prompts: [(session: String, text: String)] = []
        private(set) var clarifies: [(request: String, answer: String)] = []

        func respondToApproval(sessionId: String, requestId: String, choice: String, profile: String?) async throws -> Bool {
            approvals.append((sessionId, requestId, choice, profile))
            return try approvalResult.get()
        }
        func sendPrompt(sessionId: String, text: String) async throws {
            prompts.append((sessionId, text))
            if let promptError { throw promptError }
        }
        func answerClarify(requestId: String, answer: String) async throws -> Bool {
            clarifies.append((requestId, answer))
            return try clarifyResult.get()
        }
        func isExpired(_ error: Error) -> Bool { expiredErrors.contains("\(error)") }
    }
    final class Router: MacNotificationRouting {
        var routed: [MacNotificationPayload] = []
        func route(_ payload: MacNotificationPayload) { routed.append(payload) }
    }
    struct Failure: Error, CustomStringConvertible { var description: String }

    private var suite: (defaults: UserDefaults, name: String)!
    private var center: FakeNotificationCenter!
    private var coordinator: MacNotificationCoordinator!
    private var gateway: Gateway!
    private var router: Router!
    private var removed: [String] = []
    private var handler: MacNotificationActionHandler!

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        center = FakeNotificationCenter()
        coordinator = MacNotificationCoordinator(
            center: center, preferences: MacNotificationPreferences(defaults: suite.defaults), scheduler: FakeScheduler(),
            visibility: { _ in .away }
        )
        gateway = Gateway(); router = Router(); removed = []
        handler = MacNotificationActionHandler(gateway: gateway, coordinator: coordinator, router: router, removeDelivered: { [unowned self] in self.removed += $0 })
    }

    override func tearDown() async throws {
        await coordinator.drain()
        handler = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func payload(_ kind: MacNotificationKind, request: String? = "r1", dashboard: UUID? = nil, profile: String = "default", questions: Int = 1) -> MacNotificationPayload {
        MacNotificationPayload(kind: kind, sessionId: "run-1", sessionKey: "key-1", profile: profile, dashboardID: dashboard, requestId: request, questionCount: questions)
    }
    private func action(_ id: MacNotificationActionID, _ p: MacNotificationPayload, text: String? = nil) -> MacNotificationAction {
        MacNotificationAction(id: id, userText: text, payload: p, notificationIdentifier: "n1")
    }

    // MARK: extraction
    func testMakeMapsIdentifiersAndTextAndIgnoresDismiss() {
        let info = payload(.approval).userInfo
        XCTAssertEqual(MacNotificationAction.make(actionIdentifier: "conduit.action.approve", userText: nil, userInfo: info, notificationIdentifier: "n")?.id, .approve)
        XCTAssertEqual(MacNotificationAction.make(actionIdentifier: "conduit.action.deny", userText: nil, userInfo: info, notificationIdentifier: "n")?.id, .deny)
        let reply = MacNotificationAction.make(actionIdentifier: "conduit.action.reply", userText: "hi", userInfo: info, notificationIdentifier: "n")
        XCTAssertEqual(reply?.id, .reply)
        XCTAssertEqual(reply?.userText, "hi")
        XCTAssertEqual(MacNotificationAction.make(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil, userInfo: info, notificationIdentifier: "n")?.id, .open)
        XCTAssertNil(MacNotificationAction.make(actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil, userInfo: info, notificationIdentifier: "n"))
        XCTAssertNil(MacNotificationAction.make(actionIdentifier: "conduit.action.approve", userText: nil, userInfo: [:], notificationIdentifier: "n"))
        XCTAssertNil(MacNotificationAction.make(actionIdentifier: "something.else", userText: nil, userInfo: info, notificationIdentifier: "n"))
    }

    // MARK: approvals
    func testApproveSendsOnceExactlyOnceWithTheSessionAndProfile() async {
        await handler.perform(action(.approve, payload(.approval)))
        XCTAssertEqual(gateway.approvals.count, 1)
        XCTAssertEqual(gateway.approvals[0].choice, "once")
        XCTAssertEqual(gateway.approvals[0].session, "run-1")
        XCTAssertEqual(gateway.approvals[0].request, "r1")
        XCTAssertEqual(gateway.approvals[0].profile, "default")
        XCTAssertEqual(removed, ["n1"])
        XCTAssertTrue(router.routed.isEmpty, "Approve does not bring the app forward")
    }

    func testDenySendsDenyAndNeverAnythingPermanent() async {
        await handler.perform(action(.deny, payload(.approval)))
        XCTAssertEqual(gateway.approvals.map(\.choice), ["deny"])
        for sent in gateway.approvals { XCTAssertFalse(["always", "session"].contains(sent.choice)) }
    }

    func testApprovalResolvingNothingCountsAsSuccess() async {
        gateway.approvalResult = .success(false)
        await handler.perform(action(.approve, payload(.approval)))
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty, "already handled elsewhere is not a failure")
        XCTAssertEqual(removed, ["n1"])
    }

    func testExpiredApprovalErrorCountsAsSuccess() async {
        gateway.approvalResult = .failure(Failure(description: "gone"))
        await handler.perform(action(.approve, payload(.approval)))
        await coordinator.drain()
        XCTAssertTrue(center.added.isEmpty)
    }

    func testApprovalTransportFailurePostsACouldntSendNotice() async {
        gateway.approvalResult = .failure(Failure(description: "socket closed"))
        await handler.perform(action(.approve, payload(.approval)))
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added[0].content.categoryIdentifier, "CONDUIT_OPEN")
        XCTAssertTrue(center.added[0].content.body.contains("Couldn't send"))
        XCTAssertTrue(removed.isEmpty, "the original banner stays: the card is still pending")
    }

    func testApprovalWithoutARequestIdIsRejectedWithoutACall() async {
        await handler.perform(action(.approve, payload(.approval, request: nil)))
        XCTAssertTrue(gateway.approvals.isEmpty)
    }

    func testApproveOnANonApprovalPayloadIsIgnored() async {
        await handler.perform(action(.approve, payload(.done)))
        XCTAssertTrue(gateway.approvals.isEmpty)
    }

    func testDisconnectedGatewayPostsNoticeAndSendsNothing() async {
        gateway.isConnected = false
        await handler.perform(action(.approve, payload(.approval)))
        await coordinator.drain()
        XCTAssertTrue(gateway.approvals.isEmpty, "a stale approval is never replayed later")
        XCTAssertEqual(center.added.count, 1)
    }

    func testOtherDashboardOrProfileSendsNothing() async {
        gateway.activeDashboardID = UUID()
        await handler.perform(action(.approve, payload(.approval, dashboard: UUID())))
        XCTAssertTrue(gateway.approvals.isEmpty)
        gateway.activeDashboardID = nil
        await handler.perform(action(.approve, payload(.approval, profile: "work")))
        XCTAssertTrue(gateway.approvals.isEmpty)
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 2)
    }

    // MARK: replies
    func testReplyOnDoneSendsThePromptToThatSessionWithoutOpeningIt() async {
        await handler.perform(action(.reply, payload(.done, request: nil), text: "  thanks, ship it  "))
        XCTAssertEqual(gateway.prompts.count, 1)
        XCTAssertEqual(gateway.prompts[0].session, "run-1")
        XCTAssertEqual(gateway.prompts[0].text, "thanks, ship it")
        XCTAssertTrue(router.routed.isEmpty, "the active session is not switched")
        XCTAssertEqual(removed, ["n1"])
    }

    func testBlankReplyIsIgnored() async {
        await handler.perform(action(.reply, payload(.done, request: nil), text: "  \n "))
        await handler.perform(action(.reply, payload(.done, request: nil), text: nil))
        XCTAssertTrue(gateway.prompts.isEmpty)
    }

    func testReplyFailurePostsTheReplyNotice() async {
        gateway.promptError = Failure(description: "boom")
        await handler.perform(action(.reply, payload(.done, request: nil), text: "hi"))
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
        XCTAssertTrue(center.added[0].content.body.contains("reply"))
    }

    func testQuestionReplyAnswersTheRequestForASingleQuestion() async {
        await handler.perform(action(.reply, payload(.question, request: "q1"), text: "main"))
        XCTAssertEqual(gateway.clarifies.count, 1)
        XCTAssertEqual(gateway.clarifies[0].request, "q1")
        XCTAssertEqual(gateway.clarifies[0].answer, "main")
        XCTAssertTrue(gateway.prompts.isEmpty)
    }

    func testBatchQuestionHasNoReplyEvenIfOneArrives() async {
        await handler.perform(action(.reply, payload(.question, request: "q1", questions: 3), text: "main"))
        XCTAssertTrue(gateway.clarifies.isEmpty)
    }

    func testExpiredClarifyIsAFailureNotice() async {
        gateway.clarifyResult = .success(false)
        await handler.perform(action(.reply, payload(.question, request: "q1"), text: "main"))
        await coordinator.drain()
        XCTAssertEqual(center.added.count, 1)
    }

    // MARK: open
    func testOpenRoutesThroughTheRouterAndRemovesTheBanner() async {
        await handler.perform(action(.open, payload(.done)))
        XCTAssertEqual(router.routed.count, 1)
        XCTAssertEqual(removed, ["n1"])
        XCTAssertTrue(gateway.approvals.isEmpty && gateway.prompts.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationActionTests`
Expected: build failure.

- [ ] **Step 3: Implement**

```swift
import Foundation
import UserNotifications

enum MacNotificationActionID: Equatable { case open, approve, deny, reply }

struct MacNotificationAction: Equatable {
    var id: MacNotificationActionID
    var userText: String?
    var payload: MacNotificationPayload
    var notificationIdentifier: String

    /// The thin, testable half of the delegate: everything it needs from a
    /// `UNNotificationResponse` (which cannot be built in tests) arrives as values.
    static func make(actionIdentifier: String, userText: String?, userInfo: [AnyHashable: Any], notificationIdentifier: String) -> MacNotificationAction? {
        guard let payload = MacNotificationPayload(userInfo: userInfo) else { return nil }
        let id: MacNotificationActionID
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier, MacNotificationCategories.openAction: id = .open
        case MacNotificationCategories.approveAction: id = .approve
        case MacNotificationCategories.denyAction: id = .deny
        case MacNotificationCategories.replyAction: id = .reply
        default: return nil
        }
        return MacNotificationAction(id: id, userText: userText, payload: payload, notificationIdentifier: notificationIdentifier)
    }
}

@MainActor
protocol MacNotificationRouting: AnyObject {
    func route(_ payload: MacNotificationPayload)
}

/// The client-level entry the actions use. It addresses sessions by id, so
/// answering never switches the session the user is looking at.
@MainActor
protocol MacNotificationGateway: AnyObject {
    var isConnected: Bool { get }
    var activeDashboardID: UUID? { get }
    var activeProfile: String { get }
    /// True when the gateway resolved a pending approval; false when nothing was pending.
    func respondToApproval(sessionId: String, requestId: String, choice: String, profile: String?) async throws -> Bool
    func sendPrompt(sessionId: String, text: String) async throws
    /// False when the request had already expired.
    func answerClarify(requestId: String, answer: String) async throws -> Bool
    func isExpired(_ error: Error) -> Bool
}

@MainActor
final class MacHermesNotificationGateway: MacNotificationGateway {
    private weak var appState: AppState?
    init(appState: AppState) { self.appState = appState }

    var isConnected: Bool { appState?.isConnected == true && appState?.client != nil }
    var activeDashboardID: UUID? { appState?.activeDashboardID }
    var activeProfile: String { appState?.activeProfile ?? "default" }

    private func client() throws -> HermesClient {
        guard let client = appState?.client, appState?.isConnected == true else { throw HermesError.invalidResponse }
        return client
    }

    func respondToApproval(sessionId: String, requestId: String, choice: String, profile: String?) async throws -> Bool {
        try await client().respondToApproval(sessionId: sessionId, requestId: requestId, choice: choice, profile: profile)
    }

    func sendPrompt(sessionId: String, text: String) async throws {
        _ = try await client().sendPrompt(sessionId, text: text)
    }

    func answerClarify(requestId: String, answer: String) async throws -> Bool {
        let outcome = try await client().respondToClarification(requestId: requestId, answer: answer, questionId: nil)
        return !outcome.isExpired
    }

    func isExpired(_ error: Error) -> Bool { AppState.isExpiredPromptError(error) }
}

@MainActor
final class MacNotificationActionHandler {
    private let gateway: MacNotificationGateway
    private let coordinator: MacNotificationCoordinator
    private let router: MacNotificationRouting
    private let removeDelivered: ([String]) -> Void

    init(gateway: MacNotificationGateway, coordinator: MacNotificationCoordinator, router: MacNotificationRouting, removeDelivered: @escaping ([String]) -> Void) {
        self.gateway = gateway
        self.coordinator = coordinator
        self.router = router
        self.removeDelivered = removeDelivered
    }

    func perform(_ action: MacNotificationAction) async {
        switch action.id {
        case .open:
            router.route(action.payload)
            removeDelivered([action.notificationIdentifier])
        case .approve:
            await decide(action, choice: MacApprovalChoiceMapper.approveChoice)
        case .deny:
            await decide(action, choice: MacApprovalChoiceMapper.denyChoice)
        case .reply:
            await reply(action)
        }
    }

    /// Same dashboard and profile as the connected client, and connected.
    private func canAct(on payload: MacNotificationPayload) -> Bool {
        guard gateway.isConnected else { return false }
        if let dashboard = payload.dashboardID, let active = gateway.activeDashboardID, dashboard != active { return false }
        return payload.profile == gateway.activeProfile
    }

    private func decide(_ action: MacNotificationAction, choice: String) async {
        let payload = action.payload
        // Only these two literals can ever leave this method.
        precondition(choice == "once" || choice == "deny")
        guard payload.kind == .approval, let requestId = payload.requestId else { return }
        guard canAct(on: payload) else { coordinator.postNotice(for: payload, reply: false); return }
        do {
            _ = try await gateway.respondToApproval(sessionId: payload.sessionId, requestId: requestId, choice: choice, profile: payload.profile)
            removeDelivered([action.notificationIdentifier])
        } catch where gateway.isExpired(error) {
            removeDelivered([action.notificationIdentifier])
        } catch {
            coordinator.postNotice(for: payload, reply: false)
        }
    }

    private func reply(_ action: MacNotificationAction) async {
        let payload = action.payload
        let text = (action.userText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard canAct(on: payload) else { coordinator.postNotice(for: payload, reply: true); return }
        do {
            switch payload.kind {
            case .done:
                try await gateway.sendPrompt(sessionId: payload.sessionId, text: text)
            case .question:
                guard payload.questionCount == 1, let requestId = payload.requestId else { return }
                guard try await gateway.answerClarify(requestId: requestId, answer: text) else {
                    coordinator.postNotice(for: payload, reply: true)
                    return
                }
            default:
                return
            }
            removeDelivered([action.notificationIdentifier])
        } catch {
            coordinator.postNotice(for: payload, reply: true)
        }
    }
}
```

`HermesError.invalidResponse` is the existing error `respondToApproval` throws (HermesClient.swift:2141); if a more apt case exists (`grep -n "enum HermesError" Conduit`), use it for "not connected".

Known limit, document in D15 (Task 11): a Reply goes straight to the gateway, so the sent message appears in the local transcript when the user next opens or refreshes that session; and a Reply works only while the gateway still holds that runtime session (a reply after a gateway restart fails and posts the notice).

- [ ] **Step 4: Run to verify pass**

Run: the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacNotificationActions.swift ConduitMacTests/MacNotificationActionTests.swift
git commit -m "macOS notifications: Approve/Deny/Reply actions through a client-level gateway"
```

---

### Task 8: Router, visibility, delegate shim, runtime wiring

**Files:**
- Create: `ConduitMac/Notifications/MacNotificationRouter.swift`
- Create: `ConduitMac/Notifications/MacNotificationVisibility.swift`
- Create: `ConduitMac/Notifications/MacNotificationDelegate.swift`
- Create: `ConduitMac/Notifications/MacNotificationRuntime.swift`
- Modify: `ConduitMac/App/ConduitMacAppDelegate.swift` (Mac-only file, no gate)
- Modify: `ConduitMac/App/ConduitMacApp.swift` (Mac-only file, no gate): language hook
- Test: `ConduitMacTests/MacNotificationRouterTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 7, `MacChatRoute.isChatActive(tabRaw:)`, `MacSidebarState.tabDefaultsKey`, `MacSessionTabsActions.isMainChatWindow(_:)`, `AppState.requestOpenSession(_:onFailure:)`, `AppState.activeSessionId`, `AppState.activeRoomSurface`, `AppState.isConnected`, `AppStateRuntimeRegistry.shared.appState`.
- Produces:
  - `@MainActor final class MacNotificationRouter: MacNotificationRouting` with `init(activateApp: @escaping () -> Void, openSession: @escaping (String) -> Void, activeDashboardID: @escaping () -> UUID?, activeProfile: @escaping () -> String, isConnected: @escaping () -> Bool, removeNotifications: @escaping ([String]) -> Void)`, `func route(_ payload:)`, `func connectionChanged()` (flushes a held cold-launch click)
  - `enum MacNotificationVisibilityRules { static func evaluate(appIsActive: Bool, windowIsKey: Bool, windowIsVisible: Bool, hasAttachedSheet: Bool, chatTabShowing: Bool, roomShowing: Bool, activeSessionIDs: Set<String>, session: MacNotificationSession) -> MacNotificationVisibility }` (pure) and `@MainActor enum MacNotificationVisibilityProvider { static func current(for session:, appState:, defaults:) -> MacNotificationVisibility }` (reads `NSApp`, the window whose identifier starts with `conduit-primary`, occlusion state `.visible`, `window.attachedSheet`)
  - `enum MacNotificationPresentation { static func options(for visibility: MacNotificationVisibility, sound: Bool) -> UNNotificationPresentationOptions }` (`[]` when attended, else `[.banner, .list]` plus `.sound` when enabled)
  - `final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate`
  - `@MainActor final class MacNotificationRuntime` with `static let shared`, `func start(appState: AppState)`, `func languageDidChange()`, `var eventSource: MacNotificationEventSource?` (protocol declared here: `@MainActor protocol MacNotificationEventSource: AnyObject { func start(_ handler: @escaping @MainActor (MacNotificationEvent) -> Void); func stop() }`)

Click rules: any click activates the app and raises the main window (the router's `activateApp`). A payload whose dashboard differs from the active dashboard, or whose profile differs from the active profile, only activates (no open). When not connected (cold launch), the open is held (single slot, the latest click wins) and flushed by `connectionChanged()` once connected, with the same scope check re-applied then. The click removes the session's delivered items.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationRouterTests: XCTestCase {
    private var activated = 0
    private var opened: [String] = []
    private var removed: [[String]] = []
    private var dashboard: UUID?
    private var profile = "default"
    private var connected = true
    private var router: MacNotificationRouter!

    override func setUp() async throws {
        activated = 0; opened = []; removed = []; dashboard = nil; profile = "default"; connected = true
        router = MacNotificationRouter(
            activateApp: { [unowned self] in self.activated += 1 },
            openSession: { [unowned self] in self.opened.append($0) },
            activeDashboardID: { [unowned self] in self.dashboard },
            activeProfile: { [unowned self] in self.profile },
            isConnected: { [unowned self] in self.connected },
            removeNotifications: { [unowned self] in self.removed.append($0) }
        )
    }

    private func payload(dashboard: UUID? = nil, profile: String = "default") -> MacNotificationPayload {
        MacNotificationPayload(kind: .done, sessionId: "run-1", sessionKey: "key-1", profile: profile, dashboardID: dashboard, requestId: nil)
    }

    func testClickActivatesAndOpensTheDurableSessionKey() {
        router.route(payload())
        XCTAssertEqual(activated, 1)
        XCTAssertEqual(opened, ["key-1"])
        XCTAssertEqual(removed.flatMap { $0 }.sorted(), ["conduit.done.key-1"])
    }

    func testOtherDashboardOnlyActivates() {
        dashboard = UUID()
        router.route(payload(dashboard: UUID()))
        XCTAssertEqual(activated, 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testOtherProfileOnlyActivates() {
        router.route(payload(profile: "work"))
        XCTAssertEqual(activated, 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testColdLaunchClickIsHeldUntilConnected() {
        connected = false
        router.route(payload())
        XCTAssertEqual(activated, 1)
        XCTAssertTrue(opened.isEmpty)
        router.connectionChanged()
        XCTAssertTrue(opened.isEmpty, "still disconnected")
        connected = true
        router.connectionChanged()
        XCTAssertEqual(opened, ["key-1"])
        router.connectionChanged()
        XCTAssertEqual(opened, ["key-1"], "flushed once")
    }

    func testLatestHeldClickWins() {
        connected = false
        router.route(payload())
        router.route(MacNotificationPayload(kind: .done, sessionId: "run-2", sessionKey: "key-2", profile: "default", dashboardID: nil, requestId: nil))
        connected = true
        router.connectionChanged()
        XCTAssertEqual(opened, ["key-2"])
    }

    func testHeldClickIsDroppedWhenTheScopeChangedMeanwhile() {
        connected = false
        router.route(payload(profile: "work"))
        connected = true
        router.connectionChanged()
        XCTAssertTrue(opened.isEmpty, "profile default is active, the click was for work")
    }

    // MARK: visibility rules and presentation
    private let session = MacNotificationSession(sessionId: "run-1", sessionKey: "key-1", alternateIds: ["alt"], profile: "default", dashboardID: nil, title: "T")

    func testVisibilityRulesAttendedOnlyWhenEverythingHolds() {
        func eval(active: Bool = true, key: Bool = true, visible: Bool = true, sheet: Bool = false, chat: Bool = true, room: Bool = false, ids: Set<String> = ["key-1"]) -> MacNotificationVisibility {
            MacNotificationVisibilityRules.evaluate(appIsActive: active, windowIsKey: key, windowIsVisible: visible, hasAttachedSheet: sheet, chatTabShowing: chat, roomShowing: room, activeSessionIDs: ids, session: session)
        }
        XCTAssertTrue(eval().isAttended)
        XCTAssertFalse(eval(active: false).isAttended)
        XCTAssertFalse(eval(key: false).isAttended)
        XCTAssertFalse(eval(visible: false).isAttended, "minimized or fully occluded")
        XCTAssertFalse(eval(sheet: true).isAttended, "a sheet covers the chat")
        XCTAssertFalse(eval(chat: false).isAttended, "another pane")
        XCTAssertFalse(eval(room: true).isAttended, "a group room")
        XCTAssertFalse(eval(ids: ["other"]).isAttended, "another session is active (tab strip)")
        XCTAssertTrue(eval(ids: ["alt"]).isAttended, "matched through alternateIds")
        XCTAssertTrue(eval(ids: ["run-1"]).isAttended, "matched through the runtime id")
        XCTAssertFalse(eval(ids: []).isAttended, "no active session")
    }

    func testPresentationOptions() {
        let attended = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        XCTAssertEqual(MacNotificationPresentation.options(for: attended, sound: true), [])
        XCTAssertEqual(MacNotificationPresentation.options(for: .away, sound: true), [.banner, .list, .sound])
        XCTAssertEqual(MacNotificationPresentation.options(for: .away, sound: false), [.banner, .list])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationRouterTests`
Expected: build failure.

- [ ] **Step 3: Implement**

`MacNotificationRouter.swift`:

```swift
import Foundation

@MainActor
final class MacNotificationRouter: MacNotificationRouting {
    private let activateApp: () -> Void
    private let openSession: (String) -> Void
    private let activeDashboardID: () -> UUID?
    private let activeProfile: () -> String
    private let isConnected: () -> Bool
    private let removeNotifications: ([String]) -> Void
    private var held: MacNotificationPayload?

    init(
        activateApp: @escaping () -> Void, openSession: @escaping (String) -> Void,
        activeDashboardID: @escaping () -> UUID?, activeProfile: @escaping () -> String,
        isConnected: @escaping () -> Bool, removeNotifications: @escaping ([String]) -> Void
    ) {
        self.activateApp = activateApp; self.openSession = openSession
        self.activeDashboardID = activeDashboardID; self.activeProfile = activeProfile
        self.isConnected = isConnected; self.removeNotifications = removeNotifications
    }

    func route(_ payload: MacNotificationPayload) {
        activateApp()
        removeNotifications([
            MacNotificationPolicy.ID.done(payload.sessionKey),
            payload.requestId.map(MacNotificationPolicy.ID.approval),
            payload.requestId.map(MacNotificationPolicy.ID.question),
        ].compactMap { $0 })
        guard isConnected() else { held = payload; return }   // cold launch: wait for Hermes
        open(payload)
    }

    /// Call when the connection state changes; opens a click held at cold launch.
    func connectionChanged() {
        guard isConnected(), let payload = held else { return }
        held = nil
        open(payload)
    }

    private func open(_ payload: MacNotificationPayload) {
        // Another dashboard or profile: only the activation above.
        if let dashboard = payload.dashboardID, let active = activeDashboardID(), dashboard != active { return }
        guard payload.profile == activeProfile() else { return }
        openSession(payload.sessionKey)
    }
}
```

`MacNotificationVisibility.swift`:

```swift
import AppKit
import UserNotifications

enum MacNotificationVisibilityRules {
    static func evaluate(
        appIsActive: Bool, windowIsKey: Bool, windowIsVisible: Bool, hasAttachedSheet: Bool,
        chatTabShowing: Bool, roomShowing: Bool, activeSessionIDs: Set<String>, session: MacNotificationSession
    ) -> MacNotificationVisibility {
        MacNotificationVisibility(
            appIsActive: appIsActive,
            mainWindowKeyAndVisible: windowIsKey && windowIsVisible,
            chatSurfaceShowing: chatTabShowing && !roomShowing && !hasAttachedSheet,
            sessionIsActive: !activeSessionIDs.isDisjoint(with: session.allIDs)
        )
    }
}

enum MacNotificationPresentation {
    static func options(for visibility: MacNotificationVisibility, sound: Bool) -> UNNotificationPresentationOptions {
        if MacNotificationPolicy.shouldSuppress(visibility) { return [] }
        return sound ? [.banner, .list, .sound] : [.banner, .list]
    }
}

@MainActor
enum MacNotificationVisibilityProvider {
    /// NSApp.isActive plus the key window, never scenePhase (PLAN2_INPUTS).
    static func current(for session: MacNotificationSession, appState: AppState, defaults: UserDefaults = .standard) -> MacNotificationVisibility {
        let window = NSApp.windows.first { MacSessionTabsActions.isMainChatWindow($0) }
        return MacNotificationVisibilityRules.evaluate(
            appIsActive: NSApp.isActive,
            windowIsKey: window?.isKeyWindow ?? false,
            windowIsVisible: (window?.occlusionState.contains(.visible) ?? false) && window?.isMiniaturized == false,
            hasAttachedSheet: window?.attachedSheet != nil,
            chatTabShowing: MacChatRoute.isChatActive(tabRaw: defaults.string(forKey: MacSidebarState.tabDefaultsKey)),
            roomShowing: appState.activeRoomSurface != nil,
            activeSessionIDs: appState.activeSessionId.map { [$0] } ?? [],
            session: session
        )
    }
}
```

`MacNotificationDelegate.swift`:

```swift
import Foundation
import UserNotifications

/// A thin shim: extract Sendable values from the response and hand them to
/// the tested `MacNotificationAction`. A `UNTextInputNotificationResponse`
/// cannot be built in tests, so this file is verified by the smoke run.
final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onAction: (@MainActor (MacNotificationAction) async -> Void)?
    var presentation: (@MainActor (MacNotificationPayload?) -> UNNotificationPresentationOptions)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let userInfo = response.notification.request.content.userInfo
        let notificationID = response.notification.request.identifier
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor [weak self] in
            defer { done() }
            guard let action = MacNotificationAction.make(actionIdentifier: identifier, userText: text, userInfo: userInfo, notificationIdentifier: notificationID) else { return }
            await self?.onAction?(action)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor [weak self] in
            done(self?.presentation?(MacNotificationPayload(userInfo: userInfo)) ?? [.banner, .list, .sound])
        }
    }
}
```

`MacNotificationRuntime.swift`:

```swift
import AppKit
import Combine
import UserNotifications

@MainActor
protocol MacNotificationEventSource: AnyObject {
    func start(_ handler: @escaping @MainActor (MacNotificationEvent) -> Void)
    func stop()
}

/// Owns the live wiring. Built once at launch from the app delegate; never
/// under XCTest (tests construct the pieces with fakes).
@MainActor
final class MacNotificationRuntime {
    static let shared = MacNotificationRuntime()

    private(set) var coordinator: MacNotificationCoordinator?
    private let delegate = MacNotificationDelegate()
    private var router: MacNotificationRouter?
    private var handler: MacNotificationActionHandler?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    /// Set by Task 9 (the feed adapter). Nil until the shared base is wired.
    var eventSource: MacNotificationEventSource?

    func start(appState: AppState) {
        guard coordinator == nil else { return }
        let center = UNMacNotificationCenterClient()
        let prefs = MacNotificationPreferences.shared
        let coordinator = MacNotificationCoordinator(
            center: center, preferences: prefs, scheduler: MacTaskScheduler(),
            visibility: { [weak appState] session in
                guard let appState else { return .away }
                return MacNotificationVisibilityProvider.current(for: session, appState: appState)
            }
        )
        let router = MacNotificationRouter(
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { MacSessionTabsActions.isMainChatWindow($0) }?.makeKeyAndOrderFront(nil)
            },
            openSession: { [weak appState] id in _ = appState?.requestOpenSession(id) },
            activeDashboardID: { [weak appState] in appState?.activeDashboardID },
            activeProfile: { [weak appState] in appState?.activeProfile ?? "default" },
            isConnected: { [weak appState] in appState?.isConnected == true },
            removeNotifications: { center.removeDelivered($0); center.removePending($0) }
        )
        let handler = MacNotificationActionHandler(
            gateway: MacHermesNotificationGateway(appState: appState), coordinator: coordinator, router: router,
            removeDelivered: { center.removeDelivered($0) }
        )
        delegate.onAction = { await handler.perform($0) }
        delegate.presentation = { [weak appState] payload in
            guard let appState, let payload else { return [.banner, .list, .sound] }
            let session = MacNotificationSession(sessionId: payload.sessionId, sessionKey: payload.sessionKey, alternateIds: [], profile: payload.profile, dashboardID: payload.dashboardID, title: "")
            return MacNotificationPresentation.options(for: MacNotificationVisibilityProvider.current(for: session, appState: appState), sound: prefs.soundEnabled)
        }
        // The delegate must be set before applicationDidFinishLaunching returns,
        // or a cold-launch click is not delivered.
        UNUserNotificationCenter.current().delegate = delegate

        self.coordinator = coordinator; self.router = router; self.handler = handler

        let nc = NotificationCenter.default
        let recheck: (Notification) -> Void = { [weak coordinator] _ in Task { @MainActor in coordinator?.recheckAttention() } }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, .macSessionOpenRequested] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main, using: recheck))
        }
        appState.$activeSessionId.dropFirst().sink { [weak coordinator] _ in Task { @MainActor in coordinator?.recheckAttention() } }.store(in: &cancellables)
        appState.$isConnected.removeDuplicates().sink { [weak router] _ in Task { @MainActor in router?.connectionChanged() } }.store(in: &cancellables)

        eventSource?.start { [weak coordinator] in coordinator?.handle($0) }
    }

    func languageDidChange() { coordinator?.languageDidChange() }
}
```

Edit `ConduitMacAppDelegate.applicationDidFinishLaunching`: after `_ = MacUpdater.shared` add

```swift
        if !MacDefaults.isRunningUnderXCTest {
            MacNotificationRuntime.shared.start(appState: AppStateRuntimeRegistry.shared.appState)
        }
```

(the registry's `appState` is the same instance the `@StateObject` in `ConduitMacApp` adopts). Edit `ConduitMacApp.rootContent`'s `.onChange(of: appLanguage.selection)` body: add `MacNotificationRuntime.shared.languageDidChange()` after `appState.appLanguageDidChange()`.

Verify before editing: `grep -n "appState" Conduit/Services/AppStateRuntimeRegistry.swift` (or wherever `AppStateRuntimeRegistry` lives) confirms `shared.appState` is a stable singleton. If it is created lazily with side effects that must wait for the scene, move the `start` call to a `.task` in `rootContent` (where `appState` is in scope) and keep the delegate assignment there too; cold-launch delivery still works because the system holds the response until a delegate is set, but note it in D15.

- [ ] **Step 4: Run to verify pass, then build**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationRouterTests`
Expected: PASS. Then the full Mac build command from Global Constraints. Expected: BUILD SUCCEEDED (Swift 6 concurrency diagnostics in the delegate shim are the likely failure; fix inside the shim only).

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Notifications/MacNotificationRouter.swift ConduitMac/Notifications/MacNotificationVisibility.swift ConduitMac/Notifications/MacNotificationDelegate.swift ConduitMac/Notifications/MacNotificationRuntime.swift ConduitMac/App/ConduitMacAppDelegate.swift ConduitMac/App/ConduitMacApp.swift ConduitMacTests/MacNotificationRouterTests.swift
git commit -m "macOS notifications: router, visibility, delegate shim and runtime wiring"
```

---

### Task 9: Feed adapter (requires shared base merged)

**Files:**
- Create: `ConduitMac/Notifications/MacNotificationFeedAdapter.swift`
- Modify: `ConduitMac/Notifications/MacNotificationRuntime.swift` (set `eventSource`)
- Test: `ConduitMacTests/MacNotificationFeedAdapterTests.swift`

**Interfaces:**
- Consumes: the shared base's `AgentActivityFeed` and its event type. This plan does not define them. Step 1 is to read them; the mapping table below is the contract, and only this file may reference feed types.
- Produces: `@MainActor final class MacAgentActivityFeedSource: MacNotificationEventSource` and `static func map(_ event: <feed event>) -> MacNotificationEvent?` (pure; nil for event kinds this feature ignores).

Mapping (spec "Events consumed from AgentActivityFeed"; every feed event carries `sessionId` (runtime), `sessionKey` with `alternateIds`, `profile`, `dashboardID`, `title`, `eventId`):

| Feed event | MacNotificationEvent.Kind |
|---|---|
| `turnStarted(turnId, at)` | `.turnStarted(turnId:at:)` |
| `turnFinished(turnId, at, outcome, replyPreview)` | `.turnFinished(...)`, outcome `completed`/`failed`/`interrupted` one to one |
| `approvalRequested(requestId, description, command, choices, allowPermanent)` | `.approvalRequested(...)` one to one |
| `questionRequested(requestId, firstQuestionText, openQuestionCount)` | `.questionRequested(...)` |
| `decisionResolved(requestId, reason)` | `.decisionResolved(requestId:reason:)`, reason `answered`/`expired`/`withdrawn`/`sessionClosed` |
| `sessionTitleChanged(title)` | `.sessionTitleChanged(title:)` |

- [ ] **Step 1: Read the shared base**

Run: `grep -rn "AgentActivityFeed" ConduitMac Conduit --include='*.swift' -l` and read the type, its event enum, `subscribe` shape (snapshot on subscribe, main-actor delivery, at-least-once) and the test helpers the shared-base plan added for injecting synthetic events. If the type is absent, STOP: the shared base is not merged. If a field in the table above is named differently, adapt the mapping inside this file only; if a field is missing (for example `choices` or `replyPreview`), stop and report it instead of inventing a value.

- [ ] **Step 2: Write the failing tests**

Using the shared base's own test injection (do not build a second fake feed), write `MacNotificationFeedAdapterTests` with one test per table row asserting the mapped `MacNotificationEvent` (session fields, `eventId`, payload fields), plus:

```swift
    func testSnapshotEventsAreForwardedLikeLiveOnes()      // subscribe after a pending approval exists: one approvalRequested arrives
    func testStopUnsubscribes()                             // after stop(), further feed events reach no handler
    func testTitleOfTheSessionTravelsOnEveryMappedEvent()
    func testUnknownFeedEventsMapToNil()
```

Write each body against the feed's real injection API found in Step 1 (the assertions are the mapping table; there is nothing to guess about expected values).

- [ ] **Step 3: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationFeedAdapterTests`
Expected: build failure (adapter missing).

- [ ] **Step 4: Implement**

`MacAgentActivityFeedSource.start(_:)` subscribes to the feed once (idempotent), keeps the subscription token, maps each event with `map`, and calls the handler on the main actor in feed order. `stop()` cancels the token. In `MacNotificationRuntime.start(appState:)`, before `eventSource?.start`, set `eventSource = eventSource ?? MacAgentActivityFeedSource(feed: <the shared feed instance>)` (the exact accessor is whatever Step 1 found). The snapshot-on-subscribe means a Mac launched mid-turn posts without having seen the start; `turnStarted.at` for a snapshot turn is the observation time, so the threshold undercounts (accepted, spec).

- [ ] **Step 5: Run to verify pass, then commit**

Run: the Step 3 command. Expected: PASS.

```bash
git add ConduitMac/Notifications/MacNotificationFeedAdapter.swift ConduitMac/Notifications/MacNotificationRuntime.swift ConduitMacTests/MacNotificationFeedAdapterTests.swift
git commit -m "macOS notifications: AgentActivityFeed adapter"
```

---

### Task 10: Settings section and its single gated insert

**Files:**
- Create: `ConduitMac/Views/MacNotificationSettingsView.swift`
- Modify: `Conduit/Views/AuxiliaryViews.swift` (`NotificationsSettingsDetail.body`, the first child of `SettingsDetailContainer`, about line 2124): gate
- Modify: `docs/macos/PORTING_LEDGER.md`
- Test: `ConduitMacTests/MacNotificationSettingsViewTests.swift`

**Interfaces:**
- Consumes: `MacNotificationPreferences` (Task 3), `UNMacNotificationCenterClient` (Task 4), `ConduitSettingsSection(title:symbol:tint:content:)`, `SettingsMetricRow(label:value:valueColor:)` (see how `NotificationsSettingsDetail` uses them at AuxiliaryViews.swift:2124).
- Produces: `enum MacNotificationAuthorizationState: Equatable { case notDetermined, denied, allowed; init(_ status: UNAuthorizationStatus); var statusText: String; var needsSystemSettings: Bool }` and `struct MacNotificationSettingsView: View` (no required environment; uses `MacNotificationPreferences.shared` by default through `@ObservedObject var preferences`, injectable).

View content: section "On this Mac" with the master Toggle, three kind Toggles (Done, Approvals, Questions), a threshold `Picker` (10 s, 30 s, 60 s, 2 min displayed with `Duration`/`DateComponentsFormatter` using `AppLocalization.formattingLocale`), a sound Toggle, and a status row from `notificationSettings().authorizationStatus` (refreshed in `.task` and on `NSApplication.didBecomeActiveNotification`). When denied, a button opens System Settings > Notifications; the URL is `x-apple.systempreferences:com.apple.Notifications-Settings.extension`; verify it opens the pane on the build machine's macOS and fall back to `x-apple.systempreferences:com.apple.preference.notifications` if not, recording which one worked in D15. Kind toggles and the threshold picker are `.disabled(!preferences.isEnabled)`.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationSettingsViewTests: XCTestCase {
    func testAuthorizationStateMapping() {
        XCTAssertEqual(MacNotificationAuthorizationState(.notDetermined), .notDetermined)
        XCTAssertEqual(MacNotificationAuthorizationState(.denied), .denied)
        XCTAssertEqual(MacNotificationAuthorizationState(.authorized), .allowed)
        XCTAssertEqual(MacNotificationAuthorizationState(.provisional), .allowed)
    }

    func testStatusTextAndSystemSettingsButtonPerState() {
        XCTAssertEqual(MacNotificationAuthorizationState.denied.statusText, "Blocked in System Settings")
        XCTAssertTrue(MacNotificationAuthorizationState.denied.needsSystemSettings)
        XCTAssertFalse(MacNotificationAuthorizationState.allowed.needsSystemSettings)
        XCTAssertFalse(MacNotificationAuthorizationState.notDetermined.needsSystemSettings)
        XCTAssertNotEqual(MacNotificationAuthorizationState.allowed.statusText, MacNotificationAuthorizationState.notDetermined.statusText)
    }

    func testViewHostsInLightAndDarkWithNonEmptyLayout() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let prefs = MacNotificationPreferences(defaults: suite.defaults)
        for scheme in [ColorScheme.light, .dark] {
            let window = HostedTestSupport.host(
                MacNotificationSettingsView(preferences: prefs, authorization: .allowed).preferredColorScheme(scheme),
                size: NSSize(width: 520, height: 520)
            )
            defer { HostedTestSupport.tearDown(window) }
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(window.contentView?.fittingSize.height ?? 0, 100, "\(scheme)")
        }
    }

    func testKindTogglesFollowTheMasterToggle() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let prefs = MacNotificationPreferences(defaults: suite.defaults)
        prefs.isEnabled = false
        XCTAssertFalse(MacNotificationSettingsView.kindControlsEnabled(prefs))
        prefs.isEnabled = true
        XCTAssertTrue(MacNotificationSettingsView.kindControlsEnabled(prefs))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacNotificationSettingsViewTests`
Expected: build failure.

- [ ] **Step 3: Implement**

```swift
import AppKit
import SwiftUI
import UserNotifications

enum MacNotificationAuthorizationState: Equatable {
    case notDetermined, denied, allowed

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .allowed
        }
    }

    var statusText: String {
        switch self {
        case .notDetermined: return AppLocalization.string("Conduit will ask the first time it needs to")
        case .denied: return AppLocalization.string("Blocked in System Settings")
        case .allowed: return AppLocalization.string("Allowed")
        }
    }

    var needsSystemSettings: Bool { self == .denied }
}

struct MacNotificationSettingsView: View {
    @ObservedObject var preferences: MacNotificationPreferences
    @State var authorization: MacNotificationAuthorizationState

    init(preferences: MacNotificationPreferences = .shared, authorization: MacNotificationAuthorizationState = .notDetermined) {
        self.preferences = preferences
        _authorization = State(initialValue: authorization)
    }

    static func kindControlsEnabled(_ preferences: MacNotificationPreferences) -> Bool { preferences.isEnabled }

    private static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("On this Mac"), symbol: "bell.badge", tint: .conduitAccent) {
            Toggle(AppLocalization.string("Notify me when Conduit needs me"), isOn: $preferences.isEnabled)
            Group {
                Toggle(AppLocalization.string("A long reply finishes"), isOn: $preferences.notifiesDone)
                Toggle(AppLocalization.string("Hermes needs an approval"), isOn: $preferences.notifiesApprovals)
                Toggle(AppLocalization.string("Hermes asks a question"), isOn: $preferences.notifiesQuestions)
                Picker(AppLocalization.string("Count a reply as long after"), selection: $preferences.threshold) {
                    ForEach(MacNotificationPolicy.thresholdChoices, id: \.self) { seconds in
                        Text(Self.thresholdLabel(seconds)).tag(seconds)
                    }
                }
                Toggle(AppLocalization.string("Play a sound"), isOn: $preferences.soundEnabled)
            }
            .disabled(!Self.kindControlsEnabled(preferences))
            SettingsMetricRow(
                label: AppLocalization.string("Status"),
                value: authorization.statusText,
                valueColor: authorization == .allowed ? .green : .secondary
            )
            if authorization.needsSystemSettings {
                Button(AppLocalization.string("Open System Settings")) { NSWorkspace.shared.open(Self.systemSettingsURL) }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorization = MacNotificationAuthorizationState(status)
    }

    private static func thresholdLabel(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 120 ? [.minute] : [.second]
        formatter.calendar = {
            var calendar = Calendar.current
            calendar.locale = AppLocalization.formattingLocale
            return calendar
        }()
        return formatter.string(from: seconds) ?? "\(Int(seconds))"
    }
}
```

The authorization refresh in the test host reads the real `UNUserNotificationCenter`; the hosted test passes `authorization:` explicitly and asserts only layout, so a failed status read cannot affect it. If `UNUserNotificationCenter.current()` traps in the XCTest host (no bundle proxy), guard `refresh()` with `MacDefaults.isRunningUnderXCTest` and return early.

Gate in `Conduit/Views/AuxiliaryViews.swift`, as the first child inside `SettingsDetailContainer {` in `NotificationsSettingsDetail.body`:

```swift
            #if os(macOS) // MAC: local notifications section (D15)
            MacNotificationSettingsView()
            #endif // MAC:
```

Ledger row in `docs/macos/PORTING_LEDGER.md` (add after the last R4 row, matching its column format):

```
| Conduit/Views/AuxiliaryViews.swift `NotificationsSettingsDetail.body` | R4 (1 region) | the iOS push settings page has no Mac local-notification controls | `MacNotificationSettingsView()` inserted first, `// MAC:` (ConduitMac/Views/MacNotificationSettingsView.swift) |
```

- [ ] **Step 4: Run to verify pass, then build**

Run: the Step 2 command, then the Mac build command, then `git diff $BASE -- Conduit Shared | grep '^-[^-]'` (expect no output) and the iOS check `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` (the gate must compile out).
Expected: PASS, BUILD SUCCEEDED, empty diff output.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Views/MacNotificationSettingsView.swift Conduit/Views/AuxiliaryViews.swift docs/macos/PORTING_LEDGER.md ConduitMacTests/MacNotificationSettingsViewTests.swift
git commit -m "macOS notifications: settings section and gated insert"
```

---

### Task 11: Localization, docs, smoke, full verification

**Files:**
- Modify: `docs/macos/DECISIONS.md` (D15), `docs/macos/PORTING_LEDGER.md` (two skipped rows), `docs/macos/SMOKE_CHECKLIST.md`
- Modify (if the checker scans ConduitMac): `Conduit/Localizable.xcstrings` via `scripts/l10n.py` worksheets only

- [ ] **Step 1: Localization**

Collect every new key: `grep -rhn 'AppLocalization.string(' ConduitMac/Notifications ConduitMac/Views/MacNotificationSettingsView.swift`. The keys are: Open, Approve, Deny, Reply, Send, Message, Conduit, Finished, Stopped with an error, `%lld conversations finished` (plural, count only), Couldn't send your reply. Open Conduit., Couldn't send your answer. Open Conduit., On this Mac, Notify me when Conduit needs me, A long reply finishes, Hermes needs an approval, Hermes asks a question, Count a reply as long after, Play a sound, Status, Open System Settings, Allowed, Blocked in System Settings, Conduit will ask the first time it needs to.

Run `python3 scripts/check-l10n-coverage.py --repo-root .` and inspect whether it scans `ConduitMac` (`grep -n "ConduitMac" scripts/check-l10n-coverage.py`; today existing Mac-only strings such as "Close Tab" are not in `Conduit/Localizable.xcstrings`). Two cases:
- Not scanned and the Mac strings are not catalogued (current behaviour): keep English keys via `AppLocalization.string`, do not edit the catalog, and record in D15 "Mac notification strings are English-only like the other ConduitMac strings; catalog entries pending". Shared keys that already exist in the catalog (Open, Reply, Send, Status, Message, Deny, Approve, Conduit, Allowed) resolve there automatically.
- Scanned or the checker fails on the new keys: write a worksheet per shipped language (`python3 scripts/l10n.py export <lang> -o <scratch>/<lang>.json`), fill each new entry (plural forms for `%lld conversations finished` per the language's CLDR categories, placeholders in order, no `\uXXXX` escapes), `python3 scripts/l10n.py import --create` them together, and re-run the checker to green. Delete the worksheets afterwards.

Stage `Conduit/Localizable.xcstrings` explicitly only in the second case.

- [ ] **Step 2: DECISIONS D15**

Append to `docs/macos/DECISIONS.md` (check `grep -n '^## D15' docs/macos/DECISIONS.md` first; if another plan already took D15, use the next free number and fix the references in this plan's ledger rows):

```
## D15: Mac done and approval notifications (2026-10-15)
Spec: docs/superpowers/specs/2026-10-15-mac-notifications-design.md. Plan: docs/superpowers/plans/2026-10-15-mac-notifications.md. Local notifications only (no relay/APNs; PushNotificationService is not used). Events come from AgentActivityFeed (shared base) through MacAgentActivityFeedSource into a feed-neutral MacNotificationEvent; policy (MacNotificationPolicy), coordinator (MacNotificationCoordinator), content, categories, actions, router, delegate and runtime live in ConduitMac/Notifications.
Defaults: master on, 30 s threshold (10/30/60/120), permission requested on the first eligible event while Conduit is inactive, never at launch. Interruption level stays active (Focus is respected).
Approvals: choices are once/session/always/deny, built per request (smart-denied: once+deny). Approve sends once, Deny sends deny; always and session are never offered; Approve is dropped if once is absent. Reply and Approve/Deny call HermesClient with explicit session ids through MacHermesNotificationGateway, so the active session is never switched and no AppState or HermesClient edit exists. 4009/"no pending"/resolved 0 is success; any other failure posts "Couldn't send" (Open only). A disconnected gateway or a different dashboard/profile sends nothing and posts the notice; nothing is queued.
Clicks: activate and raise the main window, open the durable session key; a notification from another dashboard or profile only activates; a cold-launch click is held until connected.
Categories: setNotificationCategories replaces the whole set and HermesCallNotifications.registerCategory also calls it (skipped on Mac). MacNotificationCategories.register reads the current set, drops only CONDUIT_* and writes the union, at first post and on app-language change. If HermesCallNotifications.registerCategory is ever enabled on Mac it must use the same merge.
Limits: events arrive push-based only for sessions this dashboard socket has attached to; sessions run by another process (a terminal Hermes, another client's session this socket never attached) never notify. A snapshot turn's start time is the observation time, so its duration undercounts. Reply goes straight to the gateway: the sent message shows in the local transcript when the session is next opened, and a Reply after a gateway restart fails with the notice. A question Reply sends a request-level answer (no question id) and only for one open question; a multi-select question may reject a free-text answer, which posts the notice.
Held decisions: an approval or question that fires while the user is looking at the session is held and posted when attention leaves (app deactivates, window unkeyed or covered, other pane or session).
Settings: ConduitMac/Views/MacNotificationSettingsView, inserted first in NotificationsSettingsDetail by one gated edit (ledger row). System Settings URL used: <fill in after the Task 10 check>.
Strings: <English-only like other ConduitMac strings | catalogued, see Task 11 outcome>.
```

Fill the two bracketed items with what Tasks 10 and 11 found.

- [ ] **Step 3: Ledger and smoke checklist**

In `docs/macos/PORTING_LEDGER.md`, rows 40 and 42 (the two "skipped" notification rows): change the Mac-side column from `none (Plan 2)` / `none` to `local notifications: ConduitMac/Notifications (D15); relay push still skipped` for the `notificationRouteKey` row and `ConduitMac/Notifications/MacNotificationCategories.swift (merged registration, re-run on language change)` for the `registerCategory` row. Leave the `PushNotificationService.shared.refresh()` row untouched.

Append a "Notifications (D15)" section to `docs/macos/SMOKE_CHECKLIST.md`:

```
## Notifications (D15)

- [ ] Fresh defaults: no permission prompt at launch. Background the app, run a 40 s turn: the prompt appears once, then a Done banner with Reply and Open
- [ ] Type a reply inline in the banner (banner and alert styles): it is sent to that session; open the session and the message is there
- [ ] Trigger an approval while another app is frontmost: banner after about 3 s with Approve, Deny, Open; Approve resumes the turn; there is no Always or Session button
- [ ] Answer the same approval in the app inside 3 s: no banner. Answer on a second Mac after delivery: the first Mac's banner disappears
- [ ] Ask a single-question clarify: Reply answers it; a multi-question clarify has Open only
- [ ] Look at an approving session (app frontmost, that session active): no banner; switch to another tab or app while it is still pending: the banner arrives
- [ ] Focus on holds banners; they appear when Focus ends and disappear if the session was opened meanwhile
- [ ] Quit, then click a delivered notification from a cold launch: the app opens the session once connected
- [ ] Click a notification from a different dashboard or profile: the app activates only
- [ ] Disconnect Wi-Fi, then press Approve on an older banner: "Couldn't send" with Open, and the card is still pending in the app
- [ ] Interrupt a long turn with Stop: no notification. Five quick long turns across sessions: three banners and one "5 conversations finished"
- [ ] Settings > Notifications > On this Mac: toggles and threshold apply immediately; with notifications blocked in System Settings the status says so and the button opens the pane
- [ ] Limit check: a session started from a terminal Hermes (not attached to this socket) does not notify
```

- [ ] **Step 4: Run everything**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO` twice, then `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`, then `git diff $BASE -- Conduit Shared | grep '^-[^-]'` (expect no output) and `git diff $BASE --stat -- Conduit Shared` (expect only `Conduit/Views/AuxiliaryViews.swift`, plus `Conduit/Localizable.xcstrings` in the catalogued case).
Expected: all pass except the known flaky orb test; `** TEST SUCCEEDED **` twice.

- [ ] **Step 5: Smoke, clean up, commit**

Run the smoke list above on a Mac that is not the user's running instance, or ask the user to run it; do not drive their live Conduit. Delete scratch worksheets and any `build/dd` you no longer need.

```bash
git add docs/macos/DECISIONS.md docs/macos/PORTING_LEDGER.md docs/macos/SMOKE_CHECKLIST.md
git commit -m "macOS notifications: D15, ledger rows, smoke checklist"
```

(Add `Conduit/Localizable.xcstrings` to the `git add` only in the catalogued case.)

---

## Execution notes

- Order: 1, 2, 3 (any order, independent), then 4, then 5, 6, 7 (5 before 6; 7 needs 4 and 5), then 8, then 10, then 9 (needs the shared base merged), then 11. Tasks 1 to 3 may run in parallel worktrees branched from the same commit; merge them before Task 4.
- Tasks 5 and 6 edit the same file; do not parallelise them. Task 6 also edits `finish` from Task 5, which is why Task 5's tests must be re-run in Task 6 Step 4.
- Never two xcodebuilds on one checkout. Per the workspace cleanup rules: after a task's worktree branch is merged and the gate passed, remove the worktree, delete its branch, drop its derived data (`build/dd`) when no agent is using it.
- After all tasks: whole-branch review against the spec, the "Resolved after the spec" list at the top and this plan's Review Focus, then merge into `macos`, run the full suite on the merge, remove worktrees.
