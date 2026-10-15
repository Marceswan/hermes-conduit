# Mac Quick Ask Implementation Plan

> **REQUIRES SHARED BASE MERGED.** This plan does not build `MacFloatingPanel` / `MacFloatingPanelController`, the Mac stream-event tap hub, or connection-state reporting (and the Mac reconnect-while-inactive exemption). They come from `docs/superpowers/plans/2026-10-15-mac-shared-base.md`. Do not start Task 3 or later until that plan's work is on the branch (`grep -rn "MacFloatingPanelController" ConduitMac | head -1` must hit).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A global hotkey (Option-Shift-Space) opens a floating panel from any app; the user types one question, the reply streams into the panel, Esc hides it, Cmd-Return promotes the exchange to the main window.

**Architecture:** A pure reducer (`MacQuickAskModel`) turns user actions and `StreamEvent`s for the sessions it owns into panel state. A main-actor controller (`MacQuickAskController`) owns the model, performs `createSession` / `sendPrompt` / `cancel` on the app's shared socket through injected closures, and drives a `MacFloatingPanelController` (shared base). Events reach the model through the shared base's stream tap, which sees every session's events before AppState's active-session filter, so the chat open in the main window is never touched. A Carbon `RegisterEventHotKey` wrapper plus an always-working Chat menu command open the panel.

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Carbon.HIToolbox on macOS 14+, Combine, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-15-mac-quick-ask-design.md` (approved; open questions resolved to the spec's proposals: 120 s reuse of the last exchange, profile default model, Esc hides and lets the turn finish, no launch-at-login in v1, Quick Ask sessions are ordinary sidebar sessions). Read it first; the "MacFloatingPanel API" section is the contract this plan consumes.

## Global Constraints

- Mac only. New code lives under `ConduitMac/QuickAsk/`; tests under `ConduitMacTests/`. iOS is unchanged.
- This plan makes NO edit under `Conduit/` or `Shared/` (the stream tap upstream gate belongs to the shared base). Verify at the end: `git diff <base> -- Conduit Shared` is empty for this plan's commits. If an upstream edit turns out to be unavoidable, gate it `#if os(macOS)`, tag it `// MAC:`, add one row to `docs/macos/PORTING_LEDGER.md`.
- Shared-file Mac edits (`ConduitMac/App/ConduitMacApp.swift`, `ConduitMacAppDelegate.swift`, `ConduitCommands.swift`) are Mac-only files: no ledger row.
- Hotkey: Carbon `RegisterEventHotKey`, key code 49 (Space), modifiers Option+Shift. No `NSEvent` global monitor, no `CGEventTap` (they need Accessibility / Input Monitoring prompts). Fixed in v1; `MacQuickAskHotKey.default` is a value so a recorder can replace it.
- macOS 15.0 and 15.1 return `-9868` (`eventInternalErr`) for Option-only / Option-Shift-only hotkeys. Registration failure is a visible, non-fatal state; the Chat menu command "Quick Ask" always works.
- New session per invocation: the first Return calls `client.createSession(inProfile: nil)` with NO model or provider (profile default). Nothing is created if the user dismisses without sending. Reopening within 120 s of the last panel activity restores the last exchange and continues the same session; after that, or on Cmd-N, the panel opens empty.
- Esc / hotkey / click-outside hides the panel and does NOT stop a running turn. Cmd-. stops it (`client.cancel`).
- Only event cases that exist in `StreamEvent` (`Conduit/Services/HermesClient.swift` line 256) are used.
- Approvals, clarify and input prompts are never answered in the panel; they hand off to the main window via promotion.
- One setting: `@AppStorage("conduit.mac.quickAsk.enabled")`, default on, toggle in the Chat menu.
- Not in v1: attachments, slash commands, dictation, model picker, panel history, rebinding, launch at login, menu-bar item.
- Localization per `docs/LOCALIZATION.md`: every new UI string is a catalog key in `Conduit/Localizable.xcstrings` with all 13 shipped languages (de es fr id it ja ko pl pt-BR ru tr zh-Hans zh-Hant), whole sentences, no verb-in-a-shared-sentence keys; translate via `scripts/l10n.py`; `python3 scripts/check-l10n-coverage.py --repo-root .` must pass.
- Build: `xcodegen generate` first, then `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`. Tests: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/<Class>`. Never two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- Tests use injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`), explicit teardown, no fixed sleeps. Never touch the live app's defaults. Under XCTest (`MacDefaults.isRunningUnderXCTest`) the real hotkey is never registered and no real panel is shown by non-view tests.
- In zsh, quote globs (`'ConduitMac/**/*.swift'`).
- **Commits: stage explicit paths only (`git add <path> <path>`), never `git add -A` or `git add .`.** Unrelated uncommitted edits exist in `Conduit/Services/AppState.swift` and `Conduit/Views/ChatView.swift` and untracked plan files under `docs/superpowers/plans/`; they must not enter these commits.
- Safety: the user's own Conduit may be running. Do not quit it, click it or type into it. Smoke steps that need a live gateway are for the user to run.
- Cleanup: delete scratch files, `build/dd` leftovers you created for probes, and stop any app you launched before reporting done.

## Review Focus

1. Events that arrive before `sendPrompt` returns (fast gateway): the reply must not be lost or reset when the RPC result lands afterwards. Test in Task 1 (`testDeltaBeforePromptAcceptedIsKept`).
2. A tool-using turn that emits several `messageComplete` segments, or a `messageStart` after a completion: the earlier text must survive and the turn must stay open. Test in Task 1 (`testSecondSegment...`).
3. Events for another session (the open main-window chat, a Voice job) must never change the panel. Tests in Task 1 (`testForeignSessionEventsAreIgnored`) and Task 4.
4. Hotkey registration failing (-9868, already taken) must leave the app fully usable with a visible reason and a working menu command. Tests in Tasks 2 and 6.
5. `session.create` refused with 4090 (max concurrent sessions) must keep the typed prompt, say why in plain words, and offer Open Conduit and Retry. Test in Task 4.

## File Map

- Create `ConduitMac/QuickAsk/MacQuickAskModel.swift`: pure reducer (Task 1).
- Create `ConduitMac/QuickAsk/MacGlobalHotKey.swift`: `MacHotKey`, `MacQuickAskHotKey`, `MacHotKeyRegistering`, `MacCarbonHotKey` (Task 2).
- Create `ConduitMac/QuickAsk/MacQuickAskHotKeyManager.swift`: enabled/registered/unavailable state (Task 2).
- Create `ConduitMac/QuickAsk/MacQuickAskStreamTap.swift`: adapter from the shared base hub to the model (Task 3).
- Create `ConduitMac/QuickAsk/MacQuickAskController.swift`: orchestration, RPCs, promotion, panel lifecycle (Task 4).
- Create `ConduitMac/QuickAsk/MacQuickAskView.swift`: SwiftUI panel content and `MacQuickAskPanelConfig` (Task 5).
- Modify `ConduitMac/App/ConduitMacApp.swift`, `ConduitMac/App/ConduitMacAppDelegate.swift`, `ConduitMac/App/ConduitCommands.swift`: wiring and menu (Task 6).
- Tests: `ConduitMacTests/MacQuickAskModelTests.swift`, `MacQuickAskHotKeyTests.swift`, `MacQuickAskStreamTapTests.swift`, `MacQuickAskControllerTests.swift`, `MacQuickAskViewTests.swift`, `MacQuickAskCommandsTests.swift`; fixture `ConduitMacTests/Fixtures/quickask-tool-turn.jsonl` (Task 1).
- Docs/strings: `Conduit/Localizable.xcstrings` (via `scripts/l10n.py`), `docs/macos/DECISIONS.md`, `docs/macos/SMOKE_CHECKLIST.md` (Task 7).

`ConduitMac/` sources and `ConduitMacTests/` are picked up by folder globs in `project.yml`; re-run `xcodegen generate` after adding files. `Fixtures/` needs a resources entry only if the test loads it from the bundle: instead load it with `URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/quickask-tool-turn.jsonl")` so no `project.yml` change is needed.

---

### Task 1: Reducer (`MacQuickAskModel`) and recorded-trace test

**Files:**
- Create: `ConduitMac/QuickAsk/MacQuickAskModel.swift`
- Create: `ConduitMacTests/Fixtures/quickask-tool-turn.jsonl`
- Test: `ConduitMacTests/MacQuickAskModelTests.swift`

**Interfaces:**
- Consumes: `StreamEvent` (cases `messageStart(sessionId:)`, `messageDelta(sessionId:text:)`, `messageComplete(sessionId:messageId:content:reasoning:)`, `messageError(sessionId:message:)`, `messageInterrupted(sessionId:)`, `sessionBusy(sessionId:busy:)`, `sessionTitle(runtimeSessionId:storedSessionId:title:)`, `toolStart(sessionId:toolName:toolInput:toolID:)`, `toolComplete(sessionId:toolName:toolOutput:toolID:)`, `approval(sessionId:activity:)`, `clarify(sessionId:activity:)`, `inputPrompt(sessionId:activity:)`); `StreamEventParser.parse(params:)`.
- Produces:
  - `struct MacQuickAskModel: Equatable`
  - `enum MacQuickAskModel.State: Equatable { case idle, creating, sending; case streaming(text: String, status: String?); case done(text: String); case needsInput(text: String); case failed(message: String, partial: String, kind: FailureKind) }`
  - `enum MacQuickAskModel.FailureKind: Equatable { case generic, sessionLimit }`
  - `static let restoreWindow: TimeInterval = 120`
  - read: `state`, `runtimeID: String?`, `storedID: String?`, `lastPrompt: String`, `lastActivity: Date?`, `text: String`, `isTurnRunning: Bool`, `canSubmit: Bool`, `hasExchange: Bool`, `promoteID: String?` (stored id, else runtime id), `func owns(_ id: String) -> Bool`
  - mutating: `submit(_ text: String, now: Date) -> Bool`, `sessionCreated(runtimeID: String, storedID: String?)`, `promptStarted()`, `fail(_ message: String, kind: FailureKind, now: Date)`, `apply(_ event: StreamEvent, now: Date)`, `panelOpened(now: Date)`, `panelClosed(now: Date)`, `reset()`, `detach()`

Rules the reducer implements (state them in the doc comment):
- `submit` is accepted from `idle`, `done`, `failed` (retry) only, and only for a non-blank trimmed prompt. It clears the turn text, sets `lastPrompt`, and moves to `.creating` when no session exists yet, else `.sending`.
- Events count only when `owns(sessionId)` and the state is `sending`, `streaming` or `done` (a `done` state accepts a continuation segment). `idle`, `creating`, `failed` and `needsInput` ignore events.
- `messageStart` opens a segment: remembers where this segment's text starts; from `done` with text it inserts a blank-line separator before the next delta.
- `messageComplete(content)` replaces only the current segment with `content` when non-nil, so earlier segments survive; then `.done`.
- `sessionBusy(busy: false)` ends only a `streaming` turn (never `sending`: it can precede the turn).
- Every accepted event and every submit/open/close refreshes `lastActivity`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacQuickAskModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let sid = "rt-1"
    private let stored = "st-1"

    private func started() -> MacQuickAskModel {
        var m = MacQuickAskModel()
        XCTAssertTrue(m.submit("hello", now: t0))
        m.sessionCreated(runtimeID: sid, storedID: stored)
        m.promptStarted()
        return m
    }

    private func delta(_ text: String, _ id: String? = nil) -> StreamEvent {
        .messageDelta(sessionId: id ?? sid, text: text)
    }

    func testSubmitRejectsBlankAndBusy() {
        var m = MacQuickAskModel()
        XCTAssertFalse(m.submit("   \n", now: t0))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.submit(" hi ", now: t0))
        XCTAssertEqual(m.state, .creating)
        XCTAssertEqual(m.lastPrompt, "hi")
        XCTAssertFalse(m.submit("again", now: t0), "no second send while a turn runs")
    }

    func testFirstSubmitCreatesThenFollowUpSendsOnSameSession() {
        var m = started()
        m.apply(delta("A"), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "Answer", reasoning: nil), now: t0)
        XCTAssertEqual(m.state, .done(text: "Answer"))
        XCTAssertTrue(m.submit("more", now: t0))
        XCTAssertEqual(m.state, .sending, "session exists: no second create")
        XCTAssertEqual(m.runtimeID, sid)
        XCTAssertEqual(m.text, "")
    }

    func testDeltasAccumulateAndToolStatusShows() {
        var m = started()
        m.apply(.messageStart(sessionId: sid), now: t0)
        m.apply(delta("Hel"), now: t0)
        m.apply(.toolStart(sessionId: sid, toolName: "web_search", toolInput: nil), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "Hel", status: "web_search"))
        m.apply(.toolComplete(sessionId: sid, toolName: "web_search", toolOutput: nil), now: t0)
        m.apply(delta("lo"), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "Hello", status: nil))
    }

    func testDeltaBeforePromptAcceptedIsKept() {
        var m = MacQuickAskModel()
        _ = m.submit("q", now: t0)
        m.sessionCreated(runtimeID: sid, storedID: stored)
        m.apply(delta("early"), now: t0)          // event beats the sendPrompt result
        m.promptStarted()
        XCTAssertEqual(m.state, .streaming(text: "early", status: nil))
    }

    func testCompletionReplacesSegmentWithFinalContent() {
        var m = started()
        m.apply(.messageStart(sessionId: sid), now: t0)
        m.apply(delta("Hel"), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: "m", content: "Hello!", reasoning: nil), now: t0)
        XCTAssertEqual(m.state, .done(text: "Hello!"))
        var nilContent = started()
        nilContent.apply(delta("Hi"), now: t0)
        nilContent.apply(.messageComplete(sessionId: sid, messageId: nil, content: nil, reasoning: nil), now: t0)
        XCTAssertEqual(nilContent.state, .done(text: "Hi"), "nil content keeps the streamed text")
    }

    func testSecondSegmentAfterCompletionKeepsEarlierTextAndReopensTheTurn() {
        var m = started()
        m.apply(.messageStart(sessionId: sid), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: "1", content: "Let me check.", reasoning: nil), now: t0)
        m.apply(.messageStart(sessionId: sid), now: t0)
        XCTAssertTrue(m.isTurnRunning, "a start after a completion keeps the turn open")
        m.apply(delta("Found it."), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "Let me check.\n\nFound it.", status: nil))
        m.apply(.messageComplete(sessionId: sid, messageId: "2", content: "Found it, done.", reasoning: nil), now: t0)
        XCTAssertEqual(m.state, .done(text: "Let me check.\n\nFound it, done."))
    }

    func testErrorKeepsPartialInterruptEndsWithPartial() {
        var m = started()
        m.apply(delta("part"), now: t0)
        m.apply(.messageError(sessionId: sid, message: "boom"), now: t0)
        XCTAssertEqual(m.state, .failed(message: "boom", partial: "part", kind: .generic))
        XCTAssertTrue(m.canSubmit, "retry is a submit from failed")
        var i = started()
        i.apply(delta("part"), now: t0)
        i.apply(.messageInterrupted(sessionId: sid), now: t0)
        XCTAssertEqual(i.state, .done(text: "part"))
    }

    func testSessionBusyFalseEndsOnlyAStreamingTurn() {
        var m = started()
        m.apply(.sessionBusy(sessionId: sid, busy: false), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "", status: nil), "promptStarted already moved to streaming")
        var sending = MacQuickAskModel()
        _ = sending.submit("q", now: t0)
        sending.sessionCreated(runtimeID: sid, storedID: nil)
        sending.apply(.sessionBusy(sessionId: sid, busy: false), now: t0)
        XCTAssertEqual(sending.state, .sending, "an idle notice before the turn starts is not an end")
        m.apply(delta("x"), now: t0)
        m.apply(.sessionBusy(sessionId: sid, busy: false), now: t0)
        XCTAssertEqual(m.state, .done(text: "x"))
    }

    func testNeedsInputFromApprovalClarifyAndPrompt() {
        for event in [StreamEvent.approval(sessionId: sid, activity: .macTestStub),
                      .clarify(sessionId: sid, activity: .macTestStub),
                      .inputPrompt(sessionId: sid, activity: .macTestStub)] {
            var m = started()
            m.apply(delta("partial"), now: t0)
            m.apply(event, now: t0)
            XCTAssertEqual(m.state, .needsInput(text: "partial"))
            m.apply(delta("ignored"), now: t0)
            XCTAssertEqual(m.state, .needsInput(text: "partial"), "the panel never continues past a prompt")
        }
    }

    func testForeignSessionEventsAreIgnored() {
        var m = started()
        m.apply(delta("other", "someone-else"), now: t0)
        m.apply(.messageError(sessionId: "someone-else", message: "x"), now: t0)
        XCTAssertEqual(m.state, .streaming(text: "", status: nil))
    }

    func testRuntimeAndStoredIdsBothMatch() {
        var m = started()
        m.apply(delta("a", stored), now: t0)
        m.apply(delta("b", sid), now: t0)
        XCTAssertEqual(m.text, "ab")
        XCTAssertTrue(m.owns(stored) && m.owns(sid) && !m.owns("zzz"))
        XCTAssertEqual(m.promoteID, stored)
    }

    func testSessionTitleEventLearnsMissingStoredId() {
        var m = MacQuickAskModel()
        _ = m.submit("q", now: t0)
        m.sessionCreated(runtimeID: sid, storedID: nil)
        XCTAssertEqual(m.promoteID, sid)
        m.apply(.sessionTitle(runtimeSessionId: sid, storedSessionId: stored, title: "T"), now: t0)
        XCTAssertEqual(m.promoteID, stored)
    }

    func testFailBeforeStreamingKeepsKindAndPrompt() {
        var m = MacQuickAskModel()
        _ = m.submit("q", now: t0)
        m.fail("limit", kind: .sessionLimit, now: t0)
        XCTAssertEqual(m.state, .failed(message: "limit", partial: "", kind: .sessionLimit))
        XCTAssertEqual(m.lastPrompt, "q")
        XCTAssertNil(m.runtimeID)
        XCTAssertTrue(m.submit("q", now: t0), "retry after a failed create creates again")
        XCTAssertEqual(m.state, .creating)
    }

    func testRestoreWithinWindowKeepsExchange() {
        var m = started()
        m.apply(delta("x"), now: t0)
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "X", reasoning: nil), now: t0)
        m.panelClosed(now: t0.addingTimeInterval(10))
        m.panelOpened(now: t0.addingTimeInterval(10 + 119))
        XCTAssertEqual(m.state, .done(text: "X"))
        XCTAssertEqual(m.runtimeID, sid)
    }

    func testRestoreAfterWindowOpensEmptyAndForgetsSession() {
        var m = started()
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "X", reasoning: nil), now: t0)
        m.panelClosed(now: t0)
        m.panelOpened(now: t0.addingTimeInterval(MacQuickAskModel.restoreWindow + 1))
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.runtimeID)
        XCTAssertFalse(m.owns(sid))
        XCTAssertFalse(m.hasExchange)
    }

    func testEventsDuringHiddenTurnRefreshActivity() {
        var m = started()
        m.panelClosed(now: t0)
        m.apply(delta("late"), now: t0.addingTimeInterval(100))
        m.apply(.messageComplete(sessionId: sid, messageId: nil, content: "late", reasoning: nil),
                now: t0.addingTimeInterval(200))
        m.panelOpened(now: t0.addingTimeInterval(300))
        XCTAssertEqual(m.state, .done(text: "late"), "120 s counts from the last activity, not the hide")
    }

    func testResetAndDetach() {
        var m = started()
        m.apply(delta("x"), now: t0)
        m.reset()
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.runtimeID)
        var d = started()
        d.detach()
        XCTAssertEqual(d.state, .idle)
        XCTAssertFalse(d.owns(sid), "after promotion the main chat owns the session")
    }

    func testRecordedToolTurnTrace() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quickask-tool-turn.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 4)
        var m = MacQuickAskModel()
        _ = m.submit("trace", now: t0)
        m.sessionCreated(runtimeID: "trace-session", storedID: nil)
        m.promptStarted()
        for line in lines {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let event = StreamEventParser.parse(params: AnyCodable.from(obj)) { m.apply(event, now: t0) }
        }
        guard case .done(let text) = m.state else { return XCTFail("trace must end done, got \(m.state)") }
        XCTAssertFalse(text.isEmpty)
    }
}
```

`.macTestStub` for `ApprovalActivity`, `ClarifyActivity`, `InputPromptActivity` are test helpers: add `extension ApprovalActivity { static var macTestStub: ApprovalActivity { ... } }` (and the other two) at the bottom of the test file. Read each struct (`grep -n "struct ApprovalActivity\|struct ClarifyActivity\|struct InputPromptActivity" Conduit -r`) and use its memberwise initializer with minimal values. If an existing test already builds these (`grep -rn "ApprovalActivity(" ConduitTests ConduitMacTests`), copy that construction. Do not invent field names.

- [ ] **Step 2: Capture the fixture**

The fixture is the gateway's real event sequence for a tool-using turn, one JSON object per line, each being the `params` of a stream event (`{"type": "message.start", "session_id": "trace-session"}` shape, as in `ConduitTests/StreamEventParserTests.swift`). Capture it from a live gateway: read `HermesClient.handleMessage` for where `StreamEventParser.parse(params:)` is called; run Conduit (a Debug build, NOT the user's running app) against a test profile, ask "search the web for the current macOS version", and log the raw params to a scratch file with a temporary `print` that you delete again. Rewrite every `session_id` to `"trace-session"`, and strip anything private. Keep: `message.start`, at least one `tool.start`, `tool.complete`, further `message.start` / `message.delta`, and the closing `message.complete`. If no gateway is reachable, write the fixture by hand from the parser tests' sample shapes, mark the first line of this test class with `// FIXTURE-SYNTHETIC: re-record against a live gateway`, and say so in the final report (spec: whether a tool turn emits several `message.complete` segments is unconfirmed).

If the real trace shows a different segment/busy behavior than the reducer rules above, change the rules and the tests together before continuing; the trace wins over this plan.

- [ ] **Step 3: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskModelTests`
Expected: build failure, `cannot find 'MacQuickAskModel' in scope`.

- [ ] **Step 4: Implement**

```swift
import Foundation

/// Quick Ask's panel state (D15): pure, no AppKit, no AppState. It owns the
/// session ids Quick Ask created and turns StreamEvents for them into state.
///
/// - submit() is accepted from idle, done and failed only, for a non-blank prompt.
/// - Events count only for owned ids and only in sending, streaming or done
///   (done accepts a continuation segment of a tool turn).
/// - messageComplete replaces only the current segment, so earlier segments survive.
/// - sessionBusy(false) ends a streaming turn, never a sending one.
struct MacQuickAskModel: Equatable {
    static let restoreWindow: TimeInterval = 120

    enum FailureKind: Equatable { case generic, sessionLimit }

    enum State: Equatable {
        case idle
        case creating
        case sending
        case streaming(text: String, status: String?)
        case done(text: String)
        case needsInput(text: String)
        case failed(message: String, partial: String, kind: FailureKind)
    }

    private(set) var state: State = .idle
    private(set) var runtimeID: String?
    private(set) var storedID: String?
    private(set) var lastPrompt = ""
    private(set) var lastActivity: Date?

    private var turnText = ""
    private var segmentStart = 0
    private var separatorPending = false

    var text: String {
        switch state {
        case .streaming(let text, _), .done(let text), .needsInput(let text): return text
        case .failed(_, let partial, _): return partial
        case .idle, .creating, .sending: return ""
        }
    }

    var isTurnRunning: Bool {
        switch state {
        case .creating, .sending, .streaming: return true
        default: return false
        }
    }

    var canSubmit: Bool {
        switch state {
        case .idle, .done, .failed: return true
        default: return false
        }
    }

    var hasExchange: Bool { state != .idle }
    var promoteID: String? { storedID ?? runtimeID }

    func owns(_ id: String) -> Bool { id == runtimeID || id == storedID }

    mutating func submit(_ text: String, now: Date) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !prompt.isEmpty else { return false }
        lastPrompt = prompt
        turnText = ""
        segmentStart = 0
        separatorPending = false
        state = runtimeID == nil ? .creating : .sending
        lastActivity = now
        return true
    }

    mutating func sessionCreated(runtimeID: String, storedID: String?) {
        self.runtimeID = runtimeID
        self.storedID = storedID
        if state == .creating { state = .sending }
    }

    /// sendPrompt returned. Events may have beaten it: only move on from sending.
    mutating func promptStarted() {
        if state == .sending { state = .streaming(text: turnText, status: nil) }
    }

    mutating func fail(_ message: String, kind: FailureKind, now: Date) {
        state = .failed(message: message, partial: turnText, kind: kind)
        lastActivity = now
    }

    mutating func apply(_ event: StreamEvent, now: Date) {
        if case .sessionTitle(let runtime, let stored, _) = event {
            guard owns(runtime) || owns(stored) else { return }
            if storedID == nil { storedID = stored }
            if runtimeID == nil { runtimeID = runtime }
            lastActivity = now
            return
        }
        guard accepts(event) else { return }
        lastActivity = now
        switch event {
        case .messageStart:
            separatorPending = !turnText.isEmpty
            segmentStart = turnText.count + (separatorPending ? 2 : 0)
            setStreaming(status: nil)
        case .messageDelta(_, let text):
            if separatorPending { turnText += "\n\n"; separatorPending = false }
            turnText += text
            setStreaming(status: currentStatus)
        case .toolStart(_, let toolName, _, _):
            setStreaming(status: toolName)
        case .toolComplete:
            setStreaming(status: nil)
        case .messageComplete(_, _, let content, _):
            if let content {
                if separatorPending { turnText += "\n\n"; separatorPending = false }
                turnText = String(turnText.prefix(segmentStart)) + content
            }
            state = .done(text: turnText)
        case .messageInterrupted:
            state = .done(text: turnText)
        case .messageError(_, let message):
            state = .failed(message: message, partial: turnText, kind: .generic)
        case .approval, .clarify, .inputPrompt:
            state = .needsInput(text: turnText)
        case .sessionBusy(_, let busy):
            if !busy, case .streaming = state { state = .done(text: turnText) }
        default:
            break
        }
    }

    /// 120 s counts from the last activity (a hidden turn that kept streaming
    /// counts), not from the hide.
    mutating func panelOpened(now: Date) {
        guard hasExchange, let lastActivity, now.timeIntervalSince(lastActivity) <= Self.restoreWindow else {
            reset()
            return
        }
        self.lastActivity = now
    }

    mutating func panelClosed(now: Date) {
        if hasExchange { lastActivity = max(lastActivity ?? now, now) }
    }

    /// Cmd-N, or the window ran out.
    mutating func reset() { self = MacQuickAskModel() }

    /// After promotion the main chat owns the session.
    mutating func detach() { reset() }

    private var currentStatus: String? {
        if case .streaming(_, let status) = state { return status }
        return nil
    }

    private mutating func setStreaming(status: String?) {
        state = .streaming(text: turnText, status: status)
    }

    private func accepts(_ event: StreamEvent) -> Bool {
        guard let id = Self.sessionID(of: event), owns(id) else { return false }
        switch state {
        case .sending, .streaming, .done: return true
        case .idle, .creating, .needsInput, .failed: return false
        }
    }

    private static func sessionID(of event: StreamEvent) -> String? {
        switch event {
        case .messageStart(let id), .messageInterrupted(let id): return id
        case .messageDelta(let id, _), .messageError(let id, _), .sessionBusy(let id, _): return id
        case .messageComplete(let id, _, _, _): return id
        case .toolStart(let id, _, _, _), .toolComplete(let id, _, _, _): return id
        case .approval(let id, _), .clarify(let id, _), .inputPrompt(let id, _): return id
        default: return nil
        }
    }
}
```

Fix-ups to expect when running: `panelClosed` must not move `lastActivity` backwards; the test `testRestoreWithinWindowKeepsExchange` closes at t0+10 and expects restore at t0+129, i.e. 119 s after the close. If `panelClosed` stamps `now`, that holds; `testEventsDuringHiddenTurnRefreshActivity` holds because later events overwrite it. Adjust the test arithmetic, not the 120 s rule, if a case disagrees.

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskModelTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/QuickAsk/MacQuickAskModel.swift ConduitMacTests/MacQuickAskModelTests.swift ConduitMacTests/Fixtures/quickask-tool-turn.jsonl
git commit -m "macOS: Quick Ask reducer with recorded tool-turn trace (D15)"
```

---

### Task 2: Global hotkey wrapper and state manager

**Files:**
- Create: `ConduitMac/QuickAsk/MacGlobalHotKey.swift`
- Create: `ConduitMac/QuickAsk/MacQuickAskHotKeyManager.swift`
- Test: `ConduitMacTests/MacQuickAskHotKeyTests.swift`

**Interfaces:**
- Produces:
  - `struct MacHotKey: Equatable { var keyCode: UInt32; var modifiers: UInt32 }` (Carbon modifier bits)
  - `enum MacQuickAskHotKey { static let `default`: MacHotKey }` (key code 49, `optionKey | shiftKey`)
  - `enum MacHotKeyRegistrationError: Error, Equatable { case unavailableOnThisMacOS, conflict, other(Int32) }` and `static func map(_ status: OSStatus) -> MacHotKeyRegistrationError`
  - `@MainActor protocol MacHotKeyRegistering: AnyObject { func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws; func unregister() }`
  - `@MainActor final class MacCarbonHotKey: MacHotKeyRegistering`
  - `enum MacQuickAskHotKeyState: Equatable { case disabled, registered, unavailable(MacHotKeyRegistrationError) }`
  - `@MainActor final class MacQuickAskHotKeyManager: ObservableObject` with `static let enabledKey = "conduit.mac.quickAsk.enabled"`, `@Published private(set) var state`, `init(registrar: MacHotKeyRegistering, defaults: UserDefaults = .standard, isUnderTest: Bool = MacDefaults.isRunningUnderXCTest)`, `var onHotKey: @MainActor () -> Void`, `func refresh()` (register or unregister per the defaults key; idempotent), `var unavailableMessage: String?`

- [ ] **Step 1: Write the failing tests**

```swift
import Carbon.HIToolbox
import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskHotKeyTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws { HostedTestSupport.dropSuite(suite) }

    private final class FakeRegistrar: MacHotKeyRegistering {
        var registered: [MacHotKey] = []
        var unregisters = 0
        var failure: MacHotKeyRegistrationError?
        var handler: (@MainActor () -> Void)?
        func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws {
            if let failure { throw failure }
            registered.append(key); self.handler = handler
        }
        func unregister() { unregisters += 1; handler = nil }
    }

    private func manager(_ fake: FakeRegistrar, underTest: Bool = false) -> MacQuickAskHotKeyManager {
        MacQuickAskHotKeyManager(registrar: fake, defaults: suite.defaults, isUnderTest: underTest)
    }

    func testDefaultIsOptionShiftSpace() {
        XCTAssertEqual(MacQuickAskHotKey.default.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(MacQuickAskHotKey.default.modifiers, UInt32(optionKey | shiftKey))
    }

    func testStatusMapping() {
        XCTAssertEqual(MacHotKeyRegistrationError.map(-9868), .unavailableOnThisMacOS)
        XCTAssertEqual(MacHotKeyRegistrationError.map(OSStatus(eventHotKeyExistsErr)), .conflict)
        XCTAssertEqual(MacHotKeyRegistrationError.map(-50), .other(-50))
    }

    func testEnabledByDefaultRegistersOnce() {
        let fake = FakeRegistrar()
        let m = manager(fake)
        m.refresh(); m.refresh()
        XCTAssertEqual(fake.registered, [MacQuickAskHotKey.default], "idempotent")
        XCTAssertEqual(m.state, .registered)
        XCTAssertNil(m.unavailableMessage)
    }

    func testHandlerForwardsToOnHotKey() {
        let fake = FakeRegistrar()
        let m = manager(fake)
        var fired = 0
        m.onHotKey = { fired += 1 }
        m.refresh()
        fake.handler?()
        XCTAssertEqual(fired, 1)
    }

    func testDisabledUnregistersAndEnablingRegistersAgain() {
        let fake = FakeRegistrar()
        let m = manager(fake)
        m.refresh()
        suite.defaults.set(false, forKey: MacQuickAskHotKeyManager.enabledKey)
        m.refresh()
        XCTAssertEqual(m.state, .disabled)
        XCTAssertEqual(fake.unregisters, 1)
        suite.defaults.set(true, forKey: MacQuickAskHotKeyManager.enabledKey)
        m.refresh()
        XCTAssertEqual(m.state, .registered)
        XCTAssertEqual(fake.registered.count, 2)
    }

    func testSequoiaFailureIsVisibleAndNonFatal() {
        let fake = FakeRegistrar()
        fake.failure = .unavailableOnThisMacOS
        let m = manager(fake)
        m.refresh()
        XCTAssertEqual(m.state, .unavailable(.unavailableOnThisMacOS))
        XCTAssertNotNil(m.unavailableMessage)
    }

    func testConflictMessageDiffersFromSequoiaMessage() {
        let a = FakeRegistrar(); a.failure = .unavailableOnThisMacOS
        let b = FakeRegistrar(); b.failure = .conflict
        let ma = manager(a), mb = manager(b)
        ma.refresh(); mb.refresh()
        XCTAssertNotEqual(ma.unavailableMessage, mb.unavailableMessage)
    }

    func testRefreshRetriesAfterFailureOnActivation() {
        let fake = FakeRegistrar()
        fake.failure = .conflict
        let m = manager(fake)
        m.refresh()
        fake.failure = nil
        m.refresh()
        XCTAssertEqual(m.state, .registered, "re-register on app activation recovers")
    }

    func testNeverRegistersUnderXCTest() {
        let fake = FakeRegistrar()
        let m = manager(fake, underTest: true)
        m.refresh()
        XCTAssertTrue(fake.registered.isEmpty)
        XCTAssertEqual(m.state, .disabled)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskHotKeyTests`
Expected: build failure, `cannot find 'MacQuickAskHotKey' in scope`.

- [ ] **Step 3: Implement the wrapper**

```swift
import Carbon.HIToolbox
import Foundation

struct MacHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// Option-Shift-Space. A value, so a recorder can replace it later.
enum MacQuickAskHotKey {
    static let `default` = MacHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
}

enum MacHotKeyRegistrationError: Error, Equatable {
    /// -9868 (eventInternalErr): macOS 15.0 and 15.1 reject Option / Option-Shift-only hotkeys.
    case unavailableOnThisMacOS
    /// eventHotKeyExistsErr: another app owns the combination.
    case conflict
    case other(Int32)

    static func map(_ status: OSStatus) -> MacHotKeyRegistrationError {
        switch status {
        case -9868: return .unavailableOnThisMacOS
        case OSStatus(eventHotKeyExistsErr): return .conflict
        default: return .other(status)
        }
    }
}

@MainActor
protocol MacHotKeyRegistering: AnyObject {
    func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws
    func unregister()
}

/// Carbon RegisterEventHotKey: one combination, delivered while the app runs
/// in the background, consumed (Space is not typed into the front app), and no
/// Accessibility or Input Monitoring prompt.
@MainActor
final class MacCarbonHotKey: MacHotKeyRegistering {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?
    private static let signature: OSType = 0x51414B31 // 'QAK1'

    func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws {
        unregister()
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let this = Unmanaged<MacCarbonHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in this.handler?() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installStatus == noErr else {
            self.handler = nil
            throw MacHotKeyRegistrationError.map(installStatus)
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            unregister()
            throw MacHotKeyRegistrationError.map(status)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        handler = nil
    }
}
```

If `OSStatus(eventHotKeyExistsErr)` does not compile as a `case` pattern, hoist it to `private let hotKeyExists = OSStatus(eventHotKeyExistsErr)` and use `case hotKeyExists`. Confirm its value (-9878) once with a throwaway `print` in a scratch test and delete the print. Under Swift 6 strict concurrency, if the C callback rejects the `@MainActor` hop, keep the `Task { @MainActor in }` form (it is the supported one).

- [ ] **Step 4: Implement the manager**

```swift
import Foundation

enum MacQuickAskHotKeyState: Equatable {
    case disabled
    case registered
    case unavailable(MacHotKeyRegistrationError)
}

@MainActor
final class MacQuickAskHotKeyManager: ObservableObject {
    static let enabledKey = "conduit.mac.quickAsk.enabled"

    @Published private(set) var state: MacQuickAskHotKeyState = .disabled
    var onHotKey: @MainActor () -> Void = {}

    private let registrar: MacHotKeyRegistering
    private let defaults: UserDefaults
    private let isUnderTest: Bool

    init(registrar: MacHotKeyRegistering, defaults: UserDefaults = .standard,
         isUnderTest: Bool = MacDefaults.isRunningUnderXCTest) {
        self.registrar = registrar
        self.defaults = defaults
        self.isUnderTest = isUnderTest
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Idempotent: call at launch, on app activation and when the toggle changes.
    func refresh() {
        guard !isUnderTest, isEnabled else {
            if state != .disabled { registrar.unregister() }
            state = .disabled
            return
        }
        if state == .registered { return }
        do {
            try registrar.register(MacQuickAskHotKey.default) { [weak self] in self?.onHotKey() }
            state = .registered
        } catch let error as MacHotKeyRegistrationError {
            state = .unavailable(error)
        } catch {
            state = .unavailable(.other(-1))
        }
    }

    /// Chat-menu text, nil when nothing is wrong. Localized in Task 7.
    var unavailableMessage: String? {
        guard case .unavailable(let error) = state else { return nil }
        switch error {
        case .unavailableOnThisMacOS:
            return AppLocalization.string("Quick Ask shortcut unavailable on this macOS version. Use Chat > Quick Ask.")
        case .conflict:
            return AppLocalization.string("Quick Ask shortcut is taken by another app. Use Chat > Quick Ask.")
        case .other:
            return AppLocalization.string("Quick Ask shortcut could not be registered. Use Chat > Quick Ask.")
        }
    }
}
```

`AppLocalization.string` is in `Conduit/Services/AppLanguage.swift` (line ~267); copy a neighbouring Mac call (`MacSessionTabStrip` uses `AppLocalization.string("Close tab")`). The `state == .registered` early return means a failed state retries on every `refresh()`, which is the spec's "re-register on app activation and on toggle, no retry loop".

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskHotKeyTests`
Expected: all pass. Do not call `MacCarbonHotKey` in any test.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/QuickAsk/MacGlobalHotKey.swift ConduitMac/QuickAsk/MacQuickAskHotKeyManager.swift ConduitMacTests/MacQuickAskHotKeyTests.swift
git commit -m "macOS: Quick Ask Carbon hotkey wrapper and registration state (D15)"
```

---

### Task 3: Stream tap adapter

**Files:**
- Create: `ConduitMac/QuickAsk/MacQuickAskStreamTap.swift`
- Test: `ConduitMacTests/MacQuickAskStreamTapTests.swift`

**Interfaces:**
- Consumes: the shared base's stream-event hub. Read `docs/superpowers/plans/2026-10-15-mac-shared-base.md` and `grep -rn "StreamTap\|StreamHub\|subscribe" ConduitMac | head` for the real subscribe API and use its names; the Quick Ask spec names only `MacQuickAskStreamTap.shared.observe(_ event:)`. Everything below keeps `observe(_:)` as the one entry point, so only the single subscription line in Step 3 depends on the hub's name.
- Produces: `@MainActor final class MacQuickAskStreamTap { static let shared; var handler: ((StreamEvent) -> Void)?; func observe(_ event: StreamEvent); func attach() }` (`attach()` subscribes `observe` to the shared hub once; idempotent).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskStreamTapTests: XCTestCase {
    func testObserveWithNoHandlerIsANoOp() {
        let tap = MacQuickAskStreamTap()
        tap.observe(.messageStart(sessionId: "s"))   // must not crash or retain
    }

    func testObserveForwardsToHandler() {
        let tap = MacQuickAskStreamTap()
        var seen: [String] = []
        tap.handler = { if case .messageDelta(_, let text) = $0 { seen.append(text) } }
        tap.observe(.messageDelta(sessionId: "s", text: "a"))
        tap.observe(.messageStart(sessionId: "s"))
        XCTAssertEqual(seen, ["a"])
    }

    func testClearingHandlerStopsForwarding() {
        let tap = MacQuickAskStreamTap()
        var count = 0
        tap.handler = { _ in count += 1 }
        tap.observe(.messageStart(sessionId: "s"))
        tap.handler = nil
        tap.observe(.messageStart(sessionId: "s"))
        XCTAssertEqual(count, 1)
    }

    func testAttachIsIdempotent() {
        let tap = MacQuickAskStreamTap()
        tap.attach(); tap.attach()
        XCTAssertEqual(tap.attachCount, 1)
    }
}
```

Add a second test class in the same file after Step 3 if the hub exposes an injectable instance: publish one event through it and assert `handler` sees it exactly once (not twice after `attach()` twice). Use the hub's own test seam; do not reach for the real `AppState`.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskStreamTapTests`
Expected: build failure, `cannot find 'MacQuickAskStreamTap' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Quick Ask's door into the shared base's stream-event hub (D15). The hub sees
/// every session's events before AppState's active-session filter, so Quick Ask
/// can render a reply for a session the main window never opened.
@MainActor
final class MacQuickAskStreamTap {
    static let shared = MacQuickAskStreamTap()

    /// Set by the controller while it owns an exchange; nil keeps the tap free.
    var handler: ((StreamEvent) -> Void)?
    private(set) var attachCount = 0

    func observe(_ event: StreamEvent) {
        handler?(event)
    }

    /// Subscribes `observe` to the shared hub once.
    func attach() {
        guard attachCount == 0 else { return }
        attachCount = 1
        // SHARED-BASE: replace this one line with the hub's real subscribe call,
        // e.g. `MacStreamEventHub.shared.subscribe { [weak self] in self?.observe($0) }`.
        MacStreamEventHub.shared.subscribe { [weak self] event in self?.observe(event) }
    }
}
```

`MacStreamEventHub.shared.subscribe` is the placeholder name; the build fails until it is the shared base's real API, which is the intended signal. Keep subscriber closures main-actor, matching `AppState.handleStreamEvent` (it runs in `Task { @MainActor }`). If the hub hands events on another actor, hop with `Task { @MainActor in self?.observe(event) }` here.

- [ ] **Step 4: Run to verify pass**

Run: same as Step 2. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/QuickAsk/MacQuickAskStreamTap.swift ConduitMacTests/MacQuickAskStreamTapTests.swift
git commit -m "macOS: Quick Ask stream tap adapter over the shared hub (D15)"
```

---

### Task 4: Controller (RPCs, promotion, hand-off, connection, 4090)

**Files:**
- Create: `ConduitMac/QuickAsk/MacQuickAskController.swift`
- Test: `ConduitMacTests/MacQuickAskControllerTests.swift`

**Interfaces:**
- Consumes: `MacQuickAskModel` (Task 1); `MacQuickAskStreamTap.shared` (Task 3); `MacQuickAskHotKeyManager` (Task 2); `MacFloatingPanelController` (shared base: `isVisible`, `show()`, `hide()`, `toggle()`, `updateContentHeight(_:)`); `HermesClient.createSession(model:provider:reasoningEffort:fast:cwd:inProfile:)`, `sendPrompt(_:text:surface:voiceTurn:)`, `cancel(_:)`; `RpcError` (`code`, `reason`, `isSessionNotOwned`); `UserFacingError.message(for:)`; `AppState.isConnected`, `isConnecting`, `isProfileSwitching`, `activeProfile`, `client`, `requestOpenSession(_:onFailure:)`, `loadSessions(forceRefresh:)`.
- Produces:
  - `enum MacQuickAskConnection: Equatable { case connected, connecting, disconnected }` (profile switching maps to `.connecting`)
  - `protocol MacQuickAskPanelHosting: AnyObject { var isVisible: Bool { get }; func show(); func hide(); func toggle() }` with `extension MacFloatingPanelController: MacQuickAskPanelHosting {}`; `var onDismiss` is wired through the panel config in Task 5, so the controller exposes `func panelDidDismiss()`
  - `struct MacQuickAskEnvironment` with closures `connection: () -> MacQuickAskConnection`, `activeProfile: () -> String`, `createSession: () async throws -> (sessionId: String, storedSessionId: String?, profile: String?)`, `sendPrompt: (String, String) async throws -> PromptSubmissionOutcome`, `cancel: (String) async throws -> Void`, `openSession: (String) -> Void`, `activateMainWindow: () -> Void`, `refreshSessions: () -> Void`, `now: () -> Date` (all with inert defaults for tests)
  - `@MainActor final class MacQuickAskController: ObservableObject` with `static let shared`, `@Published private(set) var model`, `@Published var draft: String`, `@Published private(set) var connection: MacQuickAskConnection`, `var environment: MacQuickAskEnvironment`, `var panel: MacQuickAskPanelHosting?` (built lazily in Task 5/6 via `makePanel`), `var makePanel: (MacQuickAskController) -> MacQuickAskPanelHosting`
  - intents: `toggle()`, `show()`, `hide()`, `panelDidDismiss()`, `submit()`, `retry()`, `stop()`, `newConversation()`, `promote()`, `openConduit()`, `bind(to appState: AppState)`
  - `static func classify(_ error: Error) -> (message: String, kind: MacQuickAskModel.FailureKind)`

Behavior:
- `submit()` needs `connection == .connected`, else does nothing (the view disables the field). Accepts `draft`; clears `draft` only after `model.submit` accepted; on any failure puts the prompt back in `draft` (preserved, spec "Error handling").
- Create path: `environment.createSession()`; if the returned `profile` differs from `activeProfile()`, fail with "Hermes created this in <profile>" (localized key with `%@`, same guard as `createAndReconcileSession`); else `model.sessionCreated`, `environment.refreshSessions()`, then `sendPrompt(runtimeID, prompt)`, then `model.promptStarted()`.
- `retry()` resubmits `model.lastPrompt` (same session when one exists).
- `classify`: `RpcError` with `code == 4090` and `!isSessionNotOwned` is `.sessionLimit` with the localized "Hermes is already running the most sessions it allows. Finish or close one in Conduit, then try again."; any other error is `.generic` with `UserFacingError.message(for:)`. (4090 on `prompt.submit` with `SESSION_NOT_OWNED` is a different refusal and stays generic.)
- `promote()`: requires `model.promoteID`; calls `activateMainWindow()` then `openSession(id)` exactly once, then `model.detach()`, clears the tap handler's ownership via the model, and `panel.hide()`. In `needsInput` the view makes this the default action; the controller has no approval/clarify code.
- `panelDidDismiss()`: `model.panelClosed(now:)`. Hiding never cancels. `show()`: `model.panelOpened(now:)`, then `panel.show()`.
- `stop()`: `environment.cancel(runtimeID)` when `isTurnRunning`; errors are swallowed into `.failed`.
- Connection lost mid-turn: when `connection` flips away from `.connected` while `isTurnRunning`, nothing is cancelled; the view reads `connection` to show "Connection lost. The reply may still finish; open it in Conduit." and promote stays enabled.
- The tap handler is `{ [weak self] in self?.model.apply($0, now: environment.now()) }` installed in `bind`/init so events flow whether or not the panel is visible.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskControllerTests: XCTestCase {
    private final class FakePanel: MacQuickAskPanelHosting {
        var isVisible = false
        var shows = 0, hides = 0
        func show() { isVisible = true; shows += 1 }
        func hide() { isVisible = false; hides += 1 }
        func toggle() { isVisible ? hide() : show() }
    }

    private struct Calls {
        var creates = 0
        var sends: [(String, String)] = []
        var cancels: [String] = []
        var opens: [String] = []
        var activations = 0
        var refreshes = 0
        var order: [String] = []
    }

    private var calls = Calls()
    private var clock = Date(timeIntervalSince1970: 5_000)
    private var panel = FakePanel()
    private var connection = MacQuickAskConnection.connected
    private var profile = "default"
    private var createResult: Result<(sessionId: String, storedSessionId: String?, profile: String?), Error> =
        .success(("rt", "st", "default"))
    private var sendResult: Result<PromptSubmissionOutcome, Error> = .success(.accepted)

    private func controller() -> MacQuickAskController {
        calls = Calls()
        let c = MacQuickAskController()
        c.panel = panel
        c.environment = MacQuickAskEnvironment(
            connection: { [unowned self] in connection },
            activeProfile: { [unowned self] in profile },
            createSession: { [unowned self] in calls.creates += 1; return try createResult.get() },
            sendPrompt: { [unowned self] id, text in calls.sends.append((id, text)); return try sendResult.get() },
            cancel: { [unowned self] id in calls.cancels.append(id) },
            openSession: { [unowned self] id in calls.opens.append(id); calls.order.append("open") },
            activateMainWindow: { [unowned self] in calls.activations += 1; calls.order.append("activate") },
            refreshSessions: { [unowned self] in calls.refreshes += 1 },
            now: { [unowned self] in clock })
        c.connection = connection
        return c
    }

    private func settle(_ c: MacQuickAskController, until: @escaping () -> Bool) {
        XCTAssertTrue(HostedTestSupport.waitUntil { until() })
    }

    func testDismissWithoutSendingCreatesNoSession() {
        let c = controller()
        c.show(); c.hide(); c.panelDidDismiss()
        XCTAssertEqual(calls.creates, 0)
    }

    func testFirstReturnCreatesExactlyOneSessionThenSends() {
        let c = controller()
        c.show()
        c.draft = "what is 2+2"
        c.submit()
        settle(c) { c.model.state != .creating && c.model.state != .sending }
        XCTAssertEqual(calls.creates, 1)
        XCTAssertEqual(calls.sends.count, 1)
        XCTAssertEqual(calls.sends.first?.0, "rt")
        XCTAssertEqual(calls.sends.first?.1, "what is 2+2")
        XCTAssertEqual(calls.refreshes, 1)
        XCTAssertEqual(c.draft, "")
    }

    func testFollowUpReusesSessionAndDoesNotCreate() {
        let c = controller()
        c.draft = "one"; c.submit()
        settle(c) { calls.sends.count == 1 }
        c.model.apply(.messageComplete(sessionId: "rt", messageId: nil, content: "A", reasoning: nil), now: clock)
        c.draft = "two"; c.submit()
        settle(c) { calls.sends.count == 2 }
        XCTAssertEqual(calls.creates, 1)
        XCTAssertEqual(calls.sends.last?.0, "rt")
    }

    func testTapEventsReachTheModel() {
        let c = controller()
        c.bindTap()
        c.draft = "q"; c.submit()
        settle(c) { calls.sends.count == 1 }
        MacQuickAskStreamTap.shared.observe(.messageDelta(sessionId: "rt", text: "Hi"))
        XCTAssertEqual(c.model.text, "Hi")
        MacQuickAskStreamTap.shared.observe(.messageDelta(sessionId: "other", text: "NO"))
        XCTAssertEqual(c.model.text, "Hi")
        MacQuickAskStreamTap.shared.handler = nil
    }

    func testHideKeepsModelAndReopenWithinWindowRestores() {
        let c = controller()
        c.show()
        c.draft = "q"; c.submit()
        settle(c) { calls.sends.count == 1 }
        c.model.apply(.messageComplete(sessionId: "rt", messageId: nil, content: "A", reasoning: nil), now: clock)
        c.hide(); c.panelDidDismiss()
        clock = clock.addingTimeInterval(60)
        c.show()
        XCTAssertEqual(c.model.state, .done(text: "A"))
        XCTAssertEqual(calls.cancels, [], "Esc never stops the turn")
    }

    func testNewConversationDiscardsExchange() {
        let c = controller()
        c.draft = "q"; c.submit()
        settle(c) { calls.sends.count == 1 }
        c.newConversation()
        XCTAssertEqual(c.model.state, .idle)
        c.draft = "q2"; c.submit()
        settle(c) { calls.creates == 2 }
    }

    func testPromoteActivatesThenOpensStoredIdOnceAndHides() {
        let c = controller()
        c.show()
        c.draft = "q"; c.submit()
        settle(c) { calls.sends.count == 1 }
        c.promote()
        XCTAssertEqual(calls.order, ["activate", "open"])
        XCTAssertEqual(calls.opens, ["st"])
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(c.model.state, .idle, "the main chat owns the session now")
        c.promote()
        XCTAssertEqual(calls.opens, ["st"], "a second promote has nothing to open")
    }

    func testPromoteWithNothingToOpenDoesNothing() {
        let c = controller()
        c.promote()
        XCTAssertEqual(calls.activations, 0)
    }

    func testNeedsInputKeepsPanelAndPromoteStillWorks() {
        let c = controller()
        c.draft = "q"; c.submit()
        settle(c) { calls.sends.count == 1 }
        c.model.apply(.approval(sessionId: "rt", activity: .macTestStub), now: clock)
        XCTAssertEqual(c.model.state, .needsInput(text: ""))
        c.promote()
        XCTAssertEqual(calls.opens, ["st"])
    }

    func testSessionLimit4090KeepsPromptAndOffersRetry() {
        let c = controller()
        createResult = .failure(RpcError(code: 4090, message: "max concurrent sessions"))
        c.draft = "keep me"; c.submit()
        settle(c) { if case .failed = c.model.state { return true } else { return false } }
        guard case .failed(_, _, let kind) = c.model.state else { return XCTFail() }
        XCTAssertEqual(kind, .sessionLimit)
        XCTAssertEqual(c.draft, "keep me", "the typed prompt is preserved")
        XCTAssertEqual(calls.sends.count, 0)
        createResult = .success(("rt", "st", "default"))
        c.retry()
        settle(c) { calls.sends.count == 1 }
        XCTAssertEqual(calls.sends.first?.1, "keep me")
    }

    func testClassifySeparatesLimitFromNotOwned() {
        XCTAssertEqual(MacQuickAskController.classify(RpcError(code: 4090, message: "m")).kind, .sessionLimit)
        XCTAssertEqual(MacQuickAskController.classify(RpcError(code: 4090, message: "m", reason: "SESSION_NOT_OWNED")).kind, .generic)
        XCTAssertEqual(MacQuickAskController.classify(HermesError.notConnected).kind, .generic)
    }

    func testSendFailureKeepsPromptAndShowsMessage() {
        let c = controller()
        sendResult = .failure(HermesError.connectionClosed)
        c.draft = "q"; c.submit()
        settle(c) { if case .failed = c.model.state { return true } else { return false } }
        XCTAssertEqual(c.draft, "q")
    }

    func testProfileMismatchFailsWithoutSending() {
        let c = controller()
        createResult = .success(("rt", "st", "work"))
        c.draft = "q"; c.submit()
        settle(c) { if case .failed = c.model.state { return true } else { return false } }
        XCTAssertEqual(calls.sends.count, 0)
    }

    func testDisconnectedBlocksSubmit() {
        connection = .disconnected
        let c = controller()
        c.draft = "q"; c.submit()
        XCTAssertEqual(calls.creates, 0)
        XCTAssertEqual(c.draft, "q")
        XCTAssertEqual(c.model.state, .idle)
    }

    func testConnectionLossMidTurnDoesNotCancelAndKeepsPromoteAvailable() {
        let c = controller()
        c.draft = "q"; c.submit()
        settle(c) { calls.sends.count == 1 }
        c.connectionChanged(.disconnected)
        XCTAssertEqual(calls.cancels, [])
        XCTAssertTrue(c.model.isTurnRunning)
        XCTAssertNotNil(c.model.promoteID)
    }

    func testStopCancelsRunningTurnOnly() {
        let c = controller()
        c.stop()
        XCTAssertEqual(calls.cancels, [])
        c.draft = "q"; c.submit()
        settle(c) { calls.sends.count == 1 }
        c.stop()
        settle(c) { calls.cancels == ["rt"] }
    }

    func testToggleHidesWhenVisible() {
        let c = controller()
        c.toggle(); XCTAssertTrue(panel.isVisible)
        c.toggle(); XCTAssertFalse(panel.isVisible)
    }
}
```

`RpcError(code:message:)` and `(code:message:reason:)` calls assume the memberwise init (`code: Int?`, `message: String`, `reason: String? = nil`); `RpcError` declares a custom `init(from:)` in an extension, so the memberwise init stays available. If it does not compile, build the error by decoding a JSON literal instead (see `ConduitTests/HermesClientTests.swift` for how existing tests make one). `c.bindTap()` is a small internal method that installs `MacQuickAskStreamTap.shared.handler` (what `bind(to:)` calls); keep it `internal` for the test.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskControllerTests`
Expected: build failure, `cannot find 'MacQuickAskController' in scope`.

- [ ] **Step 3: Implement**

```swift
import AppKit
import Combine
import Foundation

enum MacQuickAskConnection: Equatable { case connected, connecting, disconnected }

@MainActor
protocol MacQuickAskPanelHosting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func toggle()
}

extension MacFloatingPanelController: MacQuickAskPanelHosting {}

struct MacQuickAskEnvironment {
    var connection: () -> MacQuickAskConnection = { .disconnected }
    var activeProfile: () -> String = { "default" }
    var createSession: () async throws -> (sessionId: String, storedSessionId: String?, profile: String?) =
        { throw HermesError.notConnected }
    var sendPrompt: (String, String) async throws -> PromptSubmissionOutcome = { _, _ in throw HermesError.notConnected }
    var cancel: (String) async throws -> Void = { _ in }
    var openSession: (String) -> Void = { _ in }
    var activateMainWindow: () -> Void = {}
    var refreshSessions: () -> Void = {}
    var now: () -> Date = { Date() }
}

private struct MacQuickAskProfileMismatch: Error { let profile: String }

/// Orchestrates Quick Ask (D15). Holds no AppState state of its own: every
/// RPC goes through the injected environment, bound to AppState at app start.
@MainActor
final class MacQuickAskController: ObservableObject {
    static let shared = MacQuickAskController()

    @Published private(set) var model = MacQuickAskModel()
    @Published var draft = ""
    @Published private(set) var connection: MacQuickAskConnection = .disconnected

    var environment = MacQuickAskEnvironment()
    var panel: MacQuickAskPanelHosting?
    /// Builds the real panel on first show (Task 5 supplies the default).
    var makePanel: (MacQuickAskController) -> MacQuickAskPanelHosting = { _ in fatalError("makePanel not set") }

    private var turnTask: Task<Void, Never>?
    private var bindings: Set<AnyCancellable> = []

    // MARK: Panel lifecycle

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        model.panelOpened(now: environment.now())
        if panel == nil { panel = makePanel(self) }
        panel?.show()
    }

    func hide() { panel?.hide() }

    /// Called from the panel's onDismiss. Hiding never cancels a turn.
    func panelDidDismiss() { model.panelClosed(now: environment.now()) }

    // MARK: Intents

    func submit() {
        guard connection == .connected, model.canSubmit else { return }
        let typed = draft
        guard model.submit(typed, now: environment.now()) else { return }
        draft = ""
        run(prompt: model.lastPrompt)
    }

    func retry() {
        guard connection == .connected, model.canSubmit, !model.lastPrompt.isEmpty else { return }
        guard model.submit(model.lastPrompt, now: environment.now()) else { return }
        draft = ""
        run(prompt: model.lastPrompt)
    }

    func stop() {
        guard model.isTurnRunning, let id = model.runtimeID else { return }
        Task { [environment] in try? await environment.cancel(id) }
    }

    func newConversation() {
        turnTask?.cancel()
        model.reset()
        draft = ""
    }

    func promote() {
        guard let id = model.promoteID else { return }
        environment.activateMainWindow()
        environment.openSession(id)
        model.detach()
        hide()
    }

    func openConduit() { environment.activateMainWindow(); hide() }

    func connectionChanged(_ value: MacQuickAskConnection) { connection = value }

    // MARK: Turn

    private func run(prompt: String) {
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                if model.runtimeID == nil {
                    let created = try await environment.createSession()
                    if let profile = created.profile, profile != environment.activeProfile() {
                        throw MacQuickAskProfileMismatch(profile: profile)
                    }
                    model.sessionCreated(runtimeID: created.sessionId, storedID: created.storedSessionId)
                    environment.refreshSessions()
                }
                guard let id = model.runtimeID else { return }
                _ = try await environment.sendPrompt(id, prompt)
                model.promptStarted()
            } catch {
                let failure = Self.classify(error)
                draft = prompt   // preserved for Retry and for editing
                model.fail(failure.message, kind: failure.kind, now: environment.now())
            }
        }
    }

    nonisolated static func classify(_ error: Error) -> (message: String, kind: MacQuickAskModel.FailureKind) {
        if let mismatch = error as? MacQuickAskProfileMismatch {
            return (String(format: AppLocalization.string("Hermes created this in %@. Switch profiles in Conduit and try again."),
                           mismatch.profile), .generic)
        }
        if let rpc = error as? RpcError, rpc.code == 4090, !rpc.isSessionNotOwned {
            return (AppLocalization.string("Hermes is already running the most sessions it allows. Finish or close one in Conduit, then try again."),
                    .sessionLimit)
        }
        return (UserFacingError.message(for: error), .generic)
    }

    // MARK: Binding

    func bindTap() {
        MacQuickAskStreamTap.shared.handler = { [weak self] event in
            guard let self else { return }
            model.apply(event, now: environment.now())
        }
    }

    func bind(to appState: AppState) {
        guard bindings.isEmpty else { return }
        environment = MacQuickAskEnvironment(
            connection: { [weak appState] in Self.connection(of: appState) },
            activeProfile: { [weak appState] in appState?.activeProfile ?? "default" },
            createSession: { [weak appState] in
                guard let client = appState?.client else { throw HermesError.notConnected }
                return try await client.createSession(inProfile: nil)
            },
            sendPrompt: { [weak appState] id, text in
                guard let client = appState?.client else { throw HermesError.notConnected }
                return try await client.sendPrompt(id, text: text)
            },
            cancel: { [weak appState] id in
                guard let client = appState?.client else { throw HermesError.notConnected }
                try await client.cancel(id)
            },
            openSession: { [weak appState] id in _ = appState?.requestOpenSession(id) },
            activateMainWindow: { MacQuickAskController.activateMainWindow() },
            refreshSessions: { [weak appState] in Task { await appState?.loadSessions(forceRefresh: true) } },
            now: { Date() })
        bindTap()
        connection = Self.connection(of: appState)
        Publishers.CombineLatest3(appState.$isConnected, appState.$isConnecting, appState.$isProfileSwitching)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak appState] _, _, _ in
                self?.connectionChanged(Self.connection(of: appState))
            }
            .store(in: &bindings)
    }

    private static func connection(of appState: AppState?) -> MacQuickAskConnection {
        guard let appState else { return .disconnected }
        if appState.isConnected && !appState.isProfileSwitching { return .connected }
        return appState.isConnecting || appState.isProfileSwitching ? .connecting : .disconnected
    }

    /// Same path as ConduitMacAppDelegate.applicationShouldHandleReopen.
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("conduit-primary") }
            ?? NSApp.windows.first { $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
    }
}
```

Checks before building: (1) `appState.$isProfileSwitching` is `@Published private(set)`; the projected publisher is readable, confirm with the compiler. (2) `client.createSession(inProfile: nil)` leaves model and provider nil (the signature defaults), which is the spec's "profile default" rule. (3) `requestOpenSession` resolves stored ids (the sidebar passes `SessionSummary.id`): read `openSessionOutcome` (`Conduit/Services/AppState.swift` ~line 16207) and confirm a runtime id from `session.create` is accepted too, which is why `promoteID` prefers the stored id. If neither resolves, the controller must wait for `.sessionTitle` (which carries both ids) before enabling promote: in that case disable the button while `model.storedID == nil` and add a test.

- [ ] **Step 4: Run to verify pass**

Run: same as Step 2. Expected: all pass; then run `MacQuickAskModelTests` and `MacQuickAskStreamTapTests` once more.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/QuickAsk/MacQuickAskController.swift ConduitMacTests/MacQuickAskControllerTests.swift
git commit -m "macOS: Quick Ask controller with create/send, promotion and 4090 handling (D15)"
```

---

### Task 5: Panel view and panel configuration

**Files:**
- Create: `ConduitMac/QuickAsk/MacQuickAskView.swift`
- Test: `ConduitMacTests/MacQuickAskViewTests.swift`

**Interfaces:**
- Consumes: `MacQuickAskController` (Task 4); `MacFloatingPanelController(config:content:)`, `MacFloatingPanelConfig`, `MacFloatingPanelPlacement.screenCenterTop(fromTop:)` (shared base, spec "MacFloatingPanel API"); `MarkdownText(source:isStreaming:)`; `AccessibilityProbe` (`ConduitMacTests/HostedTestSupport.swift`).
- Produces: `struct MacQuickAskView: View { @ObservedObject var controller: MacQuickAskController; var onHeight: (CGFloat) -> Void }`; `enum MacQuickAskPanelConfig { static func make(screenHeight: CGFloat, onDismiss: @escaping () -> Void) -> MacFloatingPanelConfig }`; `extension MacQuickAskController { func installDefaultPanel() }` setting `makePanel` to build a `MacFloatingPanelController` hosting `MacQuickAskView`.

View content, top to bottom (one glass/material layer; no nested glass, D7):
1. Disconnected strip when `connection != .connected`: "Not connected" (or "Reconnecting") with an Open Conduit button; the field is disabled.
2. Field (`TextField`, single line, `onSubmit` sends, focused on show via `@FocusState`), prompt placeholder "Ask Hermes".
3. Reply: `MarkdownText(source: model.text, isStreaming: model.isTurnRunning)` inside a `ScrollView`, shown only when there is text.
4. Status line: current tool name while a tool runs; "Connection lost. The reply may still finish; open it in Conduit." when the connection drops during a running turn.
5. Needs input: "Hermes needs your input" and Open in Conduit as the default (prominent) action.
6. Failed: the message, Retry button; for `.sessionLimit` also Open Conduit.
7. Footer buttons: Open in Conduit (Cmd-Return), Stop (Cmd-.) while running. Hidden buttons carry Cmd-N ("New conversation"). Return is the field's `onSubmit`; Esc is the panel's `cancelOperation`.

Panel config: `size` 640 x 72, `maxHeight` 480, `placement .screenCenterTop(fromTop: screenHeight * 0.22)`, `canBecomeKey` true, `dismissOnResignKey` true, `dismissOnEscape` true, `onDismiss` calling `controller.panelDidDismiss()`.

- [ ] **Step 1: Write the failing tests**

```swift
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskViewTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    private func controller(connection: MacQuickAskConnection = .connected) -> MacQuickAskController {
        let c = MacQuickAskController()
        c.connectionChanged(connection)
        return c
    }

    private func host(_ c: MacQuickAskController) -> NSWindow {
        let view = MacQuickAskView(controller: c, onHeight: { _ in }).frame(width: 640)
        let w = HostedTestSupport.host(view, size: NSSize(width: 640, height: 200))
        window = w
        return w
    }

    private func labels(_ w: NSWindow) -> [String] {
        HostedTestSupport.settle(0.3)
        return AccessibilityProbe.nodes(in: w).compactMap(\.label)
    }

    func testConfigMatchesTheSpec() {
        let config = MacQuickAskPanelConfig.make(screenHeight: 1000, onDismiss: {})
        XCTAssertEqual(config.maxHeight, 480)
        XCTAssertTrue(config.canBecomeKey)
        XCTAssertTrue(config.dismissOnResignKey)
        XCTAssertTrue(config.dismissOnEscape)
        guard case .screenCenterTop(let fromTop) = config.placement else { return XCTFail() }
        XCTAssertEqual(fromTop, 220, accuracy: 0.5)
    }

    func testConnectedIdleShowsTheField() {
        let l = labels(host(controller()))
        XCTAssertTrue(l.contains("Ask Hermes"), "\(l)")
        XCTAssertFalse(l.contains("Not connected"))
    }

    func testDisconnectedShowsNotConnectedAndOpenConduit() {
        let l = labels(host(controller(connection: .disconnected)))
        XCTAssertTrue(l.contains("Not connected"), "\(l)")
        XCTAssertTrue(l.contains("Open Conduit"), "\(l)")
    }

    func testReconnectingSaysSo() {
        let l = labels(host(controller(connection: .connecting)))
        XCTAssertTrue(l.contains("Reconnecting"), "\(l)")
    }

    func testNeedsInputOffersOpenInConduit() {
        let c = controller()
        _ = c.model.submitForTest("q")
        c.forceStateForTest(.needsInput(text: "partial"))
        let l = labels(host(c))
        XCTAssertTrue(l.contains("Hermes needs your input"), "\(l)")
        XCTAssertTrue(l.contains("Open in Conduit"), "\(l)")
    }

    func testFailedShowsMessageAndRetry() {
        let c = controller()
        c.forceStateForTest(.failed(message: "Nope", partial: "", kind: .generic))
        let l = labels(host(c))
        XCTAssertTrue(l.contains("Nope"), "\(l)")
        XCTAssertTrue(l.contains("Retry"), "\(l)")
    }

    func testSessionLimitOffersOpenConduit() {
        let c = controller()
        c.forceStateForTest(.failed(message: "limit", partial: "", kind: .sessionLimit))
        XCTAssertTrue(labels(host(c)).contains("Open Conduit"))
    }

    func testConnectionLostDuringTurnShowsNotice() {
        let c = controller()
        c.forceStateForTest(.streaming(text: "so far", status: nil))
        c.connectionChanged(.disconnected)
        let l = labels(host(c))
        XCTAssertTrue(l.contains { $0.hasPrefix("Connection lost") }, "\(l)")
        XCTAssertTrue(l.contains("Open in Conduit"), "promote stays enabled")
    }

    func testEveryButtonHasAName() {
        let c = controller()
        c.forceStateForTest(.streaming(text: "x", status: "web_search"))
        let nodes = AccessibilityProbe.nodes(in: host(c))
        HostedTestSupport.settle(0.3)
        for node in AccessibilityProbe.nodes(in: window!) where node.role.contains("Button") {
            XCTAssertFalse((node.label ?? "").isEmpty, "unnamed button \(node)")
        }
        _ = nodes
    }

    func testRendersInLightAndDark() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let c = controller()
            c.forceStateForTest(.done(text: "**Hi** there"))
            let w = host(c)
            w.appearance = NSAppearance(named: name)
            HostedTestSupport.settle()
            let rep = try XCTUnwrap(w.contentView?.bitmapImageRepForCachingDisplay(in: w.contentView!.bounds))
            w.contentView!.cacheDisplay(in: w.contentView!.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            w.close(); window = nil
        }
    }
}
```

`forceStateForTest` / `submitForTest` are `#if DEBUG` internal test seams on the controller and model (`func forceStateForTest(_ state: MacQuickAskModel.State)` sets `model` to a model in that state via a test-only initializer). Add them in the same file as the type, guarded with `#if DEBUG`, tagged `// test seam`, and keep them out of Release. If `MacQuickAskModel` makes `state` `private(set)`, give it a `#if DEBUG init(testState:)`.

The label strings asserted above ("Ask Hermes", "Not connected", "Open Conduit", "Reconnecting", "Hermes needs your input", "Open in Conduit", "Retry") are the English catalog keys; `AppLocalization` falls back to the key when no catalog entry exists yet, so these pass before Task 7.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskViewTests`
Expected: build failure, `cannot find 'MacQuickAskView' in scope`.

- [ ] **Step 3: Implement the view**

```swift
import AppKit
import SwiftUI

enum MacQuickAskPanelConfig {
    static func make(screenHeight: CGFloat, onDismiss: @escaping () -> Void) -> MacFloatingPanelConfig {
        MacFloatingPanelConfig(
            size: NSSize(width: 640, height: 72),
            maxHeight: 480,
            placement: .screenCenterTop(fromTop: screenHeight * 0.22),
            canBecomeKey: true,
            dismissOnResignKey: true,
            dismissOnEscape: true,
            onDismiss: onDismiss)
    }
}

struct MacQuickAskView: View {
    @ObservedObject var controller: MacQuickAskController
    var onHeight: (CGFloat) -> Void
    @FocusState private var fieldFocused: Bool

    private var model: MacQuickAskModel { controller.model }
    private var connected: Bool { controller.connection == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !connected { connectionStrip }
            TextField(AppLocalization.string("Ask Hermes"), text: $controller.draft)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .disabled(!connected || model.isTurnRunning || model.state == .needsInput(text: model.text))
                .onSubmit { controller.submit() }
                .accessibilityLabel(AppLocalization.string("Ask Hermes"))
            if !model.text.isEmpty {
                ScrollView {
                    MarkdownText(source: model.text, isStreaming: model.isTurnRunning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }
            statusArea
            footer
        }
        .padding(16)
        .frame(width: 640)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MacQuickAskHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(MacQuickAskHeightKey.self) { onHeight($0) }
        .onAppear { fieldFocused = true }
        .background { hiddenShortcuts }
    }

    private var connectionStrip: some View {
        HStack {
            Text(controller.connection == .connecting
                 ? AppLocalization.string("Reconnecting")
                 : AppLocalization.string("Not connected"))
                .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.string("Open Conduit")) { controller.openConduit() }
        }
    }

    @ViewBuilder private var statusArea: some View {
        switch model.state {
        case .streaming(_, let status?):
            Text(status).font(.caption).foregroundStyle(.secondary)
        case .needsInput:
            Text(AppLocalization.string("Hermes needs your input")).font(.callout)
        case .failed(let message, _, let kind):
            HStack {
                Text(message).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if kind == .sessionLimit {
                    Button(AppLocalization.string("Open Conduit")) { controller.openConduit() }
                }
                Button(AppLocalization.string("Retry")) { controller.retry() }
            }
        default:
            EmptyView()
        }
        if model.isTurnRunning, controller.connection != .connected {
            Text(AppLocalization.string("Connection lost. The reply may still finish; open it in Conduit."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.promoteID != nil {
            HStack {
                if model.isTurnRunning {
                    Button(AppLocalization.string("Stop")) { controller.stop() }
                }
                Spacer()
                let needsInput = { if case .needsInput = model.state { return true } else { return false } }()
                Button(AppLocalization.string("Open in Conduit")) { controller.promote() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(needsInput ? AnyButtonStyle.prominent : AnyButtonStyle.plain)
            }
        }
    }

    private var hiddenShortcuts: some View {
        Group {
            Button(AppLocalization.string("Stop")) { controller.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Button(AppLocalization.string("New conversation")) { controller.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct MacQuickAskHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension MacQuickAskController {
    /// The real panel: shared-base MacFloatingPanelController around MacQuickAskView.
    func installDefaultPanel() {
        makePanel = { controller in
            let height = NSScreen.main?.visibleFrame.height ?? 900
            var host: MacFloatingPanelController?
            let config = MacQuickAskPanelConfig.make(screenHeight: height) { [weak controller] in
                controller?.panelDidDismiss()
            }
            host = MacFloatingPanelController(config: config) {
                MacQuickAskView(controller: controller) { host?.updateContentHeight($0) }
            }
            return host!
        }
    }
}
```

Replace the `AnyButtonStyle` shorthand with the app's real styling: use `.buttonStyle(.borderedProminent)` when `needsInput`, `.buttonStyle(.bordered)` otherwise, applied through two branches of an `if`, because `buttonStyle` takes a static type. Check `ConduitMac/Views/MacControlMetrics.swift` and D7 for button chrome rules (32 pt compact height, no second glass layer, hover outline shape) and follow them; the panel's own material is the single glass layer. Test the Mac `MacFloatingPanelConfig` init labels against the shared base's real struct (spec lists the fields; defaults exist for `dismissOnEscape`, `level`, `joinsAllSpaces`, `onDismiss`).

- [ ] **Step 4: Run to verify pass**

Run: same as Step 2. Expected: all pass. Then run `AccessibilityLabelAuditTests` and `ButtonGeometryTests` once (the audit scans `Conduit/Views` only, but confirm nothing else regressed).

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/QuickAsk/MacQuickAskView.swift ConduitMac/QuickAsk/MacQuickAskController.swift ConduitMac/QuickAsk/MacQuickAskModel.swift ConduitMacTests/MacQuickAskViewTests.swift
git commit -m "macOS: Quick Ask panel view and config (D15)"
```

---

### Task 6: App wiring, Chat menu command and toggle

**Files:**
- Modify: `ConduitMac/App/ConduitMacApp.swift` (bind next to `.task { MacSessionTabsStore.shared.bind(to: appState) }`, line ~65; pass the hotkey manager to commands)
- Modify: `ConduitMac/App/ConduitMacAppDelegate.swift` (install the hotkey in `applicationDidFinishLaunching`; refresh on `applicationDidBecomeActive`)
- Modify: `ConduitMac/App/ConduitCommands.swift` (Chat menu items)
- (No new file: the `shared` instance is an extension at the bottom of `ConduitMac/QuickAsk/MacQuickAskHotKeyManager.swift`, shown in Step 3.)
- Test: `ConduitMacTests/MacQuickAskCommandsTests.swift`

**Interfaces:**
- Consumes: `MacQuickAskController.shared` (`bind(to:)`, `installDefaultPanel()`, `toggle()`, `show()`), `MacQuickAskStreamTap.shared.attach()`, `MacQuickAskHotKeyManager.shared` (`refresh()`, `onHotKey`, `state`, `unavailableMessage`, `enabledKey`).
- Produces: `ConduitCommands` gains `@ObservedObject var quickAsk: MacQuickAskHotKeyManager` and `@AppStorage(MacQuickAskHotKeyManager.enabledKey) private var quickAskEnabled = true`; Chat menu items:
  - Button "Quick Ask" (no key equivalent; calls `MacQuickAskController.shared.show()`); never `.disabled`.
  - Toggle "Quick Ask Shortcut" bound to `quickAskEnabled`; `onChange` calls `quickAsk.refresh()`.
  - A disabled `Text(quickAsk.unavailableMessage)` row when the state is `.unavailable`.
- Hotkey press is `controller.toggle()`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacQuickAskCommandsTests: XCTestCase {
    func testHotKeyManagerSharedUsesTheDocumentedDefaultsKey() {
        XCTAssertEqual(MacQuickAskHotKeyManager.enabledKey, "conduit.mac.quickAsk.enabled")
    }

    func testHotKeyTogglesTheController() {
        let controller = MacQuickAskController()
        let panel = StubPanel()
        controller.panel = panel
        let manager = MacQuickAskHotKeyManager(registrar: NoopRegistrar(), defaults: UserDefaults(suiteName: "q.\(UUID())")!, isUnderTest: false)
        manager.onHotKey = { controller.toggle() }
        manager.refresh()
        manager.onHotKey()
        XCTAssertTrue(panel.isVisible)
        manager.onHotKey()
        XCTAssertFalse(panel.isVisible)
    }

    func testMenuCommandOpensPanelEvenWhenRegistrationFailed() {
        let controller = MacQuickAskController()
        let panel = StubPanel()
        controller.panel = panel
        let reg = NoopRegistrar(); reg.failure = .unavailableOnThisMacOS
        let manager = MacQuickAskHotKeyManager(registrar: reg, defaults: UserDefaults(suiteName: "q.\(UUID())")!, isUnderTest: false)
        manager.refresh()
        XCTAssertEqual(manager.state, .unavailable(.unavailableOnThisMacOS))
        controller.show()      // what the Chat > Quick Ask button calls
        XCTAssertTrue(panel.isVisible)
    }

    func testQuickAskMenuItemHasNoGlobalKeyEquivalent() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConduitMac/App/ConduitCommands.swift"), encoding: .utf8)
        let line = try XCTUnwrap(source.split(separator: "\n").first { $0.contains("\"Quick Ask\"") })
        XCTAssertFalse(line.contains("keyboardShortcut"))
    }

    private final class StubPanel: MacQuickAskPanelHosting {
        var isVisible = false
        func show() { isVisible = true }
        func hide() { isVisible = false }
        func toggle() { isVisible.toggle() }
    }

    private final class NoopRegistrar: MacHotKeyRegistering {
        var failure: MacHotKeyRegistrationError?
        func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws { if let failure { throw failure } }
        func unregister() {}
    }
}
```

Also update `ConduitMacTests/MacKeyboardTests.swift` only if its menu-table test enumerates every `ConduitCommands` item (read `MacKeyboardMenuTests`); add the two new items there if so.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskCommandsTests`
Expected: fails on the missing `ConduitCommands` menu line (`testQuickAskMenuItemHasNoGlobalKeyEquivalent`) and, until Step 3, nothing else; the other tests already compile against Tasks 2 to 5.

- [ ] **Step 3: Implement**

Append to `ConduitMac/QuickAsk/MacQuickAskHotKeyManager.swift`:

```swift
extension MacQuickAskHotKeyManager {
    static let shared = MacQuickAskHotKeyManager(registrar: MacCarbonHotKey())
}
```

`ConduitMacApp.swift`, next to the tabs bind (line ~65):

```swift
            .task { MacSessionTabsStore.shared.bind(to: appState) }
            .task {
                MacQuickAskController.shared.installDefaultPanel()
                MacQuickAskController.shared.bind(to: appState)
                MacQuickAskStreamTap.shared.attach()
            }
```

and the commands call (line ~58): `ConduitCommands(appState: appState, tabs: .shared, updater: .shared, quickAsk: .shared)`.

`ConduitMacAppDelegate.swift`:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacDefaults.register()
        _ = MacUpdater.shared
        if !MacDefaults.isRunningUnderXCTest { HoverAccessibilityEngine.install() }
        MacQuickAskHotKeyManager.shared.onHotKey = { MacQuickAskController.shared.toggle() }
        MacQuickAskHotKeyManager.shared.refresh()   // no-op under XCTest
        // (existing sweep stays)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MacQuickAskHotKeyManager.shared.refresh()   // retry a failed registration; no retry loop
    }
```

Keep the existing body of `applicationDidFinishLaunching` intact; only add the two hotkey lines after `MacUpdater.shared`. The app keeps running with no window open (`applicationShouldTerminateAfterLastWindowClosed` is false), so the hotkey works then; if `MacQuickAskController.shared.panel` has no `bind` yet because the `.task` has not run (window never opened since launch), call `bind` from the delegate too: `bind(to:)` needs the `AppState`, so instead make the first hotkey press fall through to `openConduit()`-style behavior only when `environment` is unbound (`connection == .disconnected` already shows "Not connected" with Open Conduit), and record this in the smoke checklist. Check which instance owns `AppState` (`grep -n "AppStateRuntimeRegistry" ConduitMac/App/ConduitMacApp.swift`) and, if the registry exposes `appState` before any window exists, bind from the delegate with `AppStateRuntimeRegistry.shared.appState` instead of the `.task`.

`ConduitCommands.swift`:

```swift
    @ObservedObject var quickAsk: MacQuickAskHotKeyManager
    @AppStorage(MacQuickAskHotKeyManager.enabledKey) private var quickAskEnabled = true
```

Chat menu (after Stop Response):

```swift
        CommandMenu("Chat") {
            Button("Stop Response") { Task { await appState.cancelCurrent() } }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Quick Ask") { MacQuickAskController.shared.show() }
            Toggle("Quick Ask Shortcut", isOn: $quickAskEnabled)
                .onChange(of: quickAskEnabled) { _, _ in quickAsk.refresh() }
            if let message = quickAsk.unavailableMessage {
                Text(message)
            }
        }
```

Cmd-. in the Chat menu is Stop Response for the main window; the panel's own Cmd-. button shortcut wins while the panel is key because the panel is a different key window, so verify in smoke that Cmd-. in the panel stops the Quick Ask turn and not the main chat's.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ConduitMacTests/MacQuickAskCommandsTests -only-testing:ConduitMacTests/MacKeyboardMenuTests -only-testing:ConduitMacTests/AppShellTests`
Expected: pass. Then build the app once with the Mac build command from Global Constraints (expect `** BUILD SUCCEEDED **`), without launching it.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/App/ConduitMacApp.swift ConduitMac/App/ConduitMacAppDelegate.swift ConduitMac/App/ConduitCommands.swift ConduitMac/QuickAsk/MacQuickAskHotKeyManager.swift ConduitMacTests/MacQuickAskCommandsTests.swift
git commit -m "macOS: wire Quick Ask hotkey, Chat menu command and toggle (D15)"
```

(Stage `ConduitMacTests/MacKeyboardTests.swift` too only if Step 1 changed it.)

---

### Task 7: Localization, docs, smoke checklist, final verification

**Files:**
- Modify: `Conduit/Localizable.xcstrings` (through `scripts/l10n.py` only)
- Modify: `docs/macos/DECISIONS.md` (new decision), `docs/macos/SMOKE_CHECKLIST.md`
- Modify: `docs/macos/PORTING_LEDGER.md` ONLY if an upstream edit was unavoidable (see Global Constraints)

**Interfaces:** none produced; consumes every string key from Tasks 2, 4, 5, 6.

New catalog keys (exact English source strings; every shipped language needs a translation):

1. `Ask Hermes`
2. `Not connected`
3. `Reconnecting`
4. `Open Conduit`
5. `Open in Conduit`
6. `Hermes needs your input`
7. `Retry`
8. `Stop`
9. `New conversation`
10. `Connection lost. The reply may still finish; open it in Conduit.`
11. `Hermes is already running the most sessions it allows. Finish or close one in Conduit, then try again.`
12. `Hermes created this in %@. Switch profiles in Conduit and try again.`
13. `Quick Ask shortcut unavailable on this macOS version. Use Chat > Quick Ask.`
14. `Quick Ask shortcut is taken by another app. Use Chat > Quick Ask.`
15. `Quick Ask shortcut could not be registered. Use Chat > Quick Ask.`
16. `Quick Ask` (Chat menu item)
17. `Quick Ask Shortcut` (Chat menu toggle)

Before adding any, check which already exist: `python3 - <<'E'` loading `Conduit/Localizable.xcstrings` and testing each key (several, such as `Retry` and `Stop`, probably do). Reuse existing keys; do not add duplicates. Note `Open in Conduit` and `Stop` may carry a different meaning elsewhere: if an existing key has the same wording but a different sense, use a distinct wording instead of sharing (docs/LOCALIZATION.md "Whole sentences").

- [ ] **Step 1: Find which keys are missing**

Run: `python3 scripts/l10n.py export de -o <scratch dir>/de.json` (any scratch directory outside the repo), after the new strings are in code. Expected: the worksheet lists the new keys that German lacks. Repeat per language, or use `python3 scripts/check-l10n-coverage.py --repo-root .` to list every gap.

- [ ] **Step 2: Translate and import**

For each of the 13 languages write a worksheet filling every missing new key (`Quick Ask` stays the product feature name; follow the neighbouring translations' register for "Hermes" and "Conduit", which are not translated), then `python3 scripts/l10n.py import <worksheet> --create` for new keys. Per the doc, `%@` stays in key 12 in every language.

- [ ] **Step 3: Verify coverage**

Run: `python3 scripts/check-l10n-coverage.py --repo-root .`
Expected: passes, no missing or malformed entries. Then run `xcodegen generate` and the `MacQuickAskViewTests` (they assert English labels, which are the keys).

- [ ] **Step 4: Docs**

`docs/macos/DECISIONS.md`: check the last heading with `grep -n "^## D" docs/macos/DECISIONS.md | tail -3` (D14 at plan time; other Mac plans written the same day may also claim D15, so take the next free number at execution and update every "D15" in `ConduitMac/QuickAsk/` comments, the commit messages after that point, and the smoke checklist to match). Entry content (one block, same register as D11):

- Spec path `docs/superpowers/specs/2026-10-15-mac-quick-ask-design.md`.
- Hotkey API: Carbon `RegisterEventHotKey` over `NSEvent` global monitors (observation only, needs Accessibility) and `CGEventTap` (needs Input Monitoring); Apple DTS calls it the best of the three but legacy; no prompt; fixed Option-Shift-Space, `MacQuickAskHotKey.default` is the replacement seam.
- Sequoia caveat: macOS 15.0 and 15.1 return -9868 for Option / Option-Shift-only hotkeys (Apple engineer, developer.apple.com/forums/thread/763878: intentional, fixed in 15.2 beta 2); failure is a visible non-fatal Chat-menu state, the menu command always works, registration retried on app activation and toggle.
- Tap over active-session switch: Quick Ask reads every session's events through the shared base stream tap and keeps its own reducer; AppState and the open chat are untouched; approvals, clarify, reasoning cards and attachments are not rebuilt in the panel and hand off through promotion.
- New session per invocation with a 120 s restore window counted from the last activity; Cmd-N resets; nothing is created on dismiss without sending.
- Model: the profile default (`createSession` with no model or provider), not `runtime.model`, which mirrors the open chat's possible override.
- Esc hides and the turn finishes; Quick Ask sessions are ordinary sidebar sessions; promotion uses `requestOpenSession` with the stored id, activating the main window first.
- 4090 on `session.create` is shown as a plain-language limit message with the prompt kept, Retry and Open Conduit.
- Reconnect while Conduit is inactive depends on the shared base's Mac exemption (state this dependency).
- Out of scope list from the spec.

`docs/macos/SMOKE_CHECKLIST.md`: add a "Quick Ask (D15)" group of lines in the existing `  - [ ]` style:

```
  - [ ] Quick Ask (D15), macOS 14 and 15.2 or later: press Option-Shift-Space from Safari, from a full-screen app and from a window on a second display. The panel appears under the mouse near the top center, the field is focused, the front app keeps its menu bar, and typing does not leak into the front app.
  - [ ] Ask "what is 2+2", watch the reply stream with markdown; press Esc while it streams, wait ten seconds, press the hotkey again within 120 s: the finished reply is shown and the sidebar lists one new session. After 120 s the panel opens empty. Cmd-N in the panel clears a restored exchange.
  - [ ] Cmd-Return mid-stream: Conduit comes forward, the Quick Ask session opens as a tab and the reply keeps streaming in the main chat. The chat that was open before is not changed by the panel at any point.
  - [ ] Cmd-. in the panel stops the Quick Ask turn and does not stop a turn running in the main chat.
  - [ ] Ask something that triggers an approval or clarify prompt: the panel says "Hermes needs your input" with Open in Conduit as the default action and never shows an answer control.
  - [ ] Disconnect from the network (or stop the gateway): the panel shows "Not connected" or "Reconnecting" with Open Conduit and a disabled field; reconnect and it recovers without reopening. With Conduit in the background (not the active app), the reconnect still happens (shared base exemption).
  - [ ] Start two Quick Ask turns in separate invocations (wait 120 s between) while the main chat also streams: all three replies are correct and none appears in the wrong place. When the gateway refuses with its session limit (4090), the panel says so, keeps the typed prompt, and Retry works after a session is freed.
  - [ ] macOS 15.0 or 15.1 only: the Chat menu shows "Quick Ask shortcut unavailable on this macOS version. Use Chat > Quick Ask." and Chat > Quick Ask still opens the panel. Any macOS: switch Chat > Quick Ask Shortcut off and the hotkey stops (Space types normally), on again and it works.
  - [ ] With Conduit running and no window open (red close button), the hotkey opens the panel; if it shows "Not connected" until the main window is opened once, record it.
  - [ ] Quick Ask in VoiceOver: the field is "Ask Hermes", every button is announced, and the panel is reachable while key.
```

- [ ] **Step 5: Full verification**

Run, one at a time (never two xcodebuilds on one checkout):
1. `xcodegen generate`
2. `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -destination 'platform=macOS' -derivedDataPath build/dd` twice. Expected: `** TEST SUCCEEDED **` both times (note the known flaky test if it alone fails).
3. `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` only if any file under `Conduit/` other than the catalog was touched; otherwise skip and say so (macOS-only scope).
4. `git diff <base> --stat -- Conduit Shared` shows only `Conduit/Localizable.xcstrings`; `git diff <base> -- Conduit Shared | grep '^-' | grep -v '^---'` is empty or limited to catalog lines that `scripts/l10n.py` rewrote.
5. `grep -rn "TODO\|SHARED-BASE" ConduitMac/QuickAsk` returns nothing.
6. Delete scratch worksheets, probe files and any `build/dd` you do not need.

- [ ] **Step 6: Commit**

```bash
git add Conduit/Localizable.xcstrings docs/macos/DECISIONS.md docs/macos/SMOKE_CHECKLIST.md
git commit -m "macOS: Quick Ask strings, decision record and smoke checklist (D15)"
```

(Add `docs/macos/PORTING_LEDGER.md` only if it changed. Never stage `Conduit/Services/AppState.swift`, `Conduit/Views/ChatView.swift` or the untracked plan files.)

---

## Self-Review Notes

- Spec coverage: hotkey + Sequoia -9868 + conflict + always-working menu command (Tasks 2, 6); toggle default on (6); reducer incl. 120 s, Cmd-N, needs-input, segments, ids (1); create/send on the shared socket, profile guard, profile-default model (4); tap from shared base (3); streaming render, tool status, cap 480, Return/Esc/Cmd-Return/Cmd-./Cmd-N (5); promotion order and stored id (4); approval/clarify hand-off (1, 4, 5); disconnected/reconnecting and mid-turn loss (4, 5); 4090 (4, 5); localization and docs (7); recorded-trace test (1). Panel/placement/hosted-panel tests belong to the shared base plan, not here.
- Types: `MacQuickAskModel.State.failed` has three associated values everywhere (kind added to the spec's two); `MacQuickAskConnection` is used by the controller, view and tests; `MacQuickAskPanelHosting` is defined in Task 4 and used in Tasks 5 and 6.
