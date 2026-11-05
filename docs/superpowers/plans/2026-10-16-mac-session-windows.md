# Mac Session Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pop a chat session out of the main window into its own window, so two conversations stream side by side, each with its own composer and Stop button.

**Architecture:** Option B2 of the spec. Each window owns a Mac-only `MacSessionWindowController` that talks to the shared `HermesClient` (`appState.client`) through injected closures, the same pattern as `MacQuickAskController` (D15). Events come from the existing `MacStreamEventHub` (it already receives every session's events before AppState's active-session filter), so the spec's `MacClientEventTee` is not built. A pure reducer, `MacSessionTranscript`, folds events into `[ChatMessage]`; after each turn the controller re-reads the persisted transcript (`openSessionLegacy`), so reducer drift lasts at most one turn. AppState, ChatView and ComposerBar are not edited.

**Tech Stack:** Swift 5.9, SwiftUI with AppKit (macOS 14 target), Combine, XCTest (`ConduitMacTests`), xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-15-mac-session-windows-design.md` (recommendation B2). Executors read the spec's Behaviour, Interaction with the Mac tab strip and Risks sections before their task.

## Facts that change the spec (checked 2026-10-16)

- **S1 is answered: YES.** The gateway keeps no per-socket "current session". Each session has its own transport set; `session.resume` adds the socket and never detaches others (`tui_gateway/session_lifecycle.py:830-849`); `write_json` routes every event by `params.session_id` (`tui_gateway/server.py:681-699`); `prompt.submit` for session A after resuming Y re-attaches the socket to A (`tui_gateway/methods_prompt.py:795-802`). So one shared `HermesClient` serves the main window and every pop-out. The own-client fallback is not built.
- Approval and clarify answers are matched by request id, first answer wins, any socket may answer (`tui_gateway/server_requests.py:291`). A card shown both in main and in a window for the same session: the second answer gets an error. The window shows that error on the card; nothing else breaks.
- A send backlog overflow (256 frames or 4 MiB) closes the whole socket with 1011 (`tui_gateway/transport.py:262-277`). AppState reconnects; the window re-reads on the new client (Task 3).
- `MacStreamEventHub` (ConduitMac/Shared/MacStreamEventHub.swift) replaces the spec's tee.
- `openSession` is a compact resume (`omit_messages: true`): its `messages` are empty. The window uses `openSessionLegacy`, which carries the transcript.
- The existing approval, clarify and input-prompt cards call AppState with a message id from AppState's own `messages`. The window gets its own minimal cards (Task 4). `MessageBubble` is reused for every other row.
- `ComposerPasteTextView.updateNSView` only takes focus while the MAIN window shows the chat pane (`MacChatRoute.isChatActive(tabRaw:)`). Task 4 adds a parameter to turn that off for the window.
- `MacKeyboardActions.focusComposer` (MacKeyboardShortcuts.swift:240-250) switches the main sidebar to Sessions before it posts Cmd-L. From a session window it must not. Task 5 fixes it.
- `WindowGroup(for:)` restores windows at relaunch by default; the spec says v1 does not. `.restorationBehavior(.disabled)` is macOS 15 only, so Task 1's registry closes any window it did not open in this run.
- Decision number: D15 is Quick Ask and D20 is the latest. This feature is **D21**.

## Global Constraints

- macOS app only (`ConduitMac`). iOS is unchanged. At the end, `git diff macos --stat -- Conduit Shared` lists only `Conduit/Localizable.xcstrings` (no upstream code edits).
- New code lives under `ConduitMac/Windows/`. `project.yml` globs `ConduitMac/` and `ConduitMacTests/`: after adding files run `xcodegen generate`. `Conduit.xcodeproj` is gitignored.
- Scene id `conduit-session`. It must not start with `conduit-primary` (Cmd-W closes tabs only in windows with that prefix, `MacSessionTabsActions.isMainChatWindow`).
- Menu command: File > "Open Session in New Window", Option-Command-N. Menu items are never `.disabled`; actions guard with `MacKeyboardActions.commandsBlocked(by: NSApp.keyWindow)` (D10 rule, ConduitCommands.swift:47-50).
- Open windows cap: 4. At the cap, the open does nothing and beeps (`NSSound.beep()`); the tab context menu item is disabled at the cap.
- Window default size 640 x 760; minimum 420 x 420.
- Return sends, Shift-Return inserts a newline (D9).
- v1 omits: slash commands, @mentions, voice, attachments (a pasted image shows "Images can't be attached in this window."), screenshot carry, steer or queue while busy (the composer shows Stop while a turn runs), read-aloud, branch, quote, resume viewport restoration, group rooms, window restore at relaunch.
- Gateway-controlled strings in window chrome (title, error text, tool names in the status line) pass through `MacUntrustedText.sanitize(_:maxGraphemes:)`.
- User-visible strings go through `AppLocalization.string(...)` and are added to `Conduit/Localizable.xcstrings` (English only; `scripts/check-l10n-coverage.py` must pass).
- Session identity: an event belongs to the window when its id is any of the window's ids (row id, stored id, alternate ids, runtime id). Never compare against one raw id.
- Test command (zsh: quote every `-only-testing` value; never run two xcodebuilds on one checkout):
  `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/<Class>' CODE_SIGNING_ALLOWED=NO`

## Review Focus

1. **The window's session switches to another runtime id mid-life** (resume returns a new runtime id, `session.title` names the stored id). Expected: events under any of the ids keep streaming into the same window. Test: Task 2 `testAdoptsIdsFromResumeAndTitle`, Task 3 `testResumeAdoptsRuntimeIdForSend`.
2. **Main switches profile or dashboard while a window is open.** Expected: the window shows "Belongs to <profile>", its composer is disabled, and it sends nothing on the other profile's client. Test: Task 3 `testWrongScopeBlocksSendAndResume`.
3. **The connection drops and comes back** (new `HermesClient`). Expected: the window re-reads the transcript once on the new client and asks `session.active_list` whether its turn is still running, so a turn that ended during the gap does not leave Stop showing forever. Test: Task 3 `testNewClientRehydratesAndProbesBusy`.
4. **A main-window delta storm while a window is open.** Expected: events for other sessions never write the window's published state. Test: Task 3 `testForeignEventsDoNotPublish`.
5. **Relaunch with a pop-out open.** Expected: no stray, empty window comes back. Test: Task 1 `testUnrequestedTokenIsRejected` (registry) plus the smoke checklist line in Task 6.

---

### Task 1: Window token, registry and tab detach

**Files:**
- Create: `ConduitMac/Windows/MacSessionWindowToken.swift`
- Create: `ConduitMac/Windows/MacSessionWindowRegistry.swift`
- Modify: `ConduitMac/Tabs/MacSessionTabsModel.swift` (add `detach`)
- Modify: `ConduitMac/Tabs/MacSessionTabsStore.swift` (add `popOut`, `sessionDeletions`)
- Test: `ConduitMacTests/MacSessionWindowRegistryTests.swift`, `ConduitMacTests/MacSessionTabsModelTests.swift`, `ConduitMacTests/MacSessionTabsStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct MacSessionWindowToken: Codable, Hashable { var dashboardID: UUID?; var profile: String; var sessionID: String }`
  - `@MainActor final class MacSessionWindowRegistry: ObservableObject` with `static let shared`, `static let limit = 4`, `@Published private(set) var open: Set<MacSessionWindowToken>`, `var isFull: Bool`, `func request(_:) -> Bool`, `func appeared(_:) -> Bool`, `func disappeared(_:)`
  - `MacSessionTabsModel.detach(_ id: String) -> CloseResult`
  - `MacSessionTabsStore.popOut(_ id: String, openWindow: (String) -> Bool)`
  - `MacSessionTabsStore.sessionDeletions: PassthroughSubject<String, Never>`

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacSessionWindowRegistryTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowRegistryTests: XCTestCase {
    private func token(_ id: String) -> MacSessionWindowToken {
        MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: id)
    }

    func testTokenCodingRoundTrip() throws {
        let original = MacSessionWindowToken(dashboardID: UUID(), profile: "work", sessionID: "s1")
        let decoded = try JSONDecoder().decode(MacSessionWindowToken.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRequestedTokenAppears() {
        let registry = MacSessionWindowRegistry()
        XCTAssertTrue(registry.request(token("a")))
        XCTAssertTrue(registry.appeared(token("a")))
        XCTAssertEqual(registry.open, [token("a")])
    }

    func testUnrequestedTokenIsRejected() {
        // A window SwiftUI restored at relaunch was never requested in this run.
        let registry = MacSessionWindowRegistry()
        XCTAssertFalse(registry.appeared(token("restored")))
        XCTAssertTrue(registry.open.isEmpty)
    }

    func testCapAllowsReopeningAnOpenToken() {
        let registry = MacSessionWindowRegistry()
        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(registry.request(token(id)))
            XCTAssertTrue(registry.appeared(token(id)))
        }
        XCTAssertTrue(registry.isFull)
        XCTAssertFalse(registry.request(token("e")), "a fifth window is refused")
        XCTAssertTrue(registry.request(token("b")), "an open window is focused, not counted again")
    }

    func testDisappearFreesTheSlotAndForgetsTheRequest() {
        let registry = MacSessionWindowRegistry()
        _ = registry.request(token("a")); _ = registry.appeared(token("a"))
        registry.disappeared(token("a"))
        XCTAssertTrue(registry.open.isEmpty)
        XCTAssertFalse(registry.appeared(token("a")), "closing forgets the request")
    }

    func testPendingRequestsCountTowardTheCap() {
        let registry = MacSessionWindowRegistry()
        for id in ["a", "b", "c", "d"] { XCTAssertTrue(registry.request(token(id))) }
        XCTAssertFalse(registry.request(token("e")))
    }
}
```

Append to `ConduitMacTests/MacSessionTabsModelTests.swift` (before `testCodableRoundTripDropsClosedStack`):

```swift
    func testDetachActivatesNeighbourWithoutClosedEntry() {
        var m = model(["a", "b", "c"], active: "b")
        XCTAssertEqual(m.detach("b"), .activate("c"))
        XCTAssertEqual(m.tabs.map(\.id), ["a", "c"])
        XCTAssertEqual(m.activeID, "c")
        XCTAssertNil(m.reopen(), "a popped-out tab is not on the closed stack")
    }

    func testDetachLastTabIsClosedLast() {
        var m = model(["a"], active: "a")
        XCTAssertEqual(m.detach("a"), .closedLast)
        XCTAssertTrue(m.tabs.isEmpty)
        XCTAssertNil(m.activeID)
    }

    func testDetachInactiveKeepsActive() {
        var m = model(["a", "b"], active: "a")
        XCTAssertEqual(m.detach("b"), .closedInactive)
        XCTAssertEqual(m.activeID, "a")
    }

    func testDetachUnknownIsNotFound() {
        var m = model(["a"], active: "a")
        XCTAssertEqual(m.detach("x"), .notFound)
    }
```

Append to `ConduitMacTests/MacSessionTabsStoreTests.swift` (inside `MacSessionTabsStoreTests`, after `testCatalogMergesTabsKeyedByTheStoredId`):

```swift
    func testPopOutDetachesAndOpensNeighbour() {
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0) }
        var windows: [String] = []
        store.popOut("b") { windows.append($0); return true }
        XCTAssertEqual(windows, ["b"])
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"])
        XCTAssertEqual(opened, ["a"], "main activates the neighbour")
    }

    func testPopOutLastTabStartsNewChat() {
        store.activeSessionChanged("a", title: "A")
        store.popOut("a") { _ in true }
        XCTAssertTrue(store.model.tabs.isEmpty)
        XCTAssertEqual(newChats, 1)
    }

    func testPopOutRefusedKeepsTheTab() {
        store.activeSessionChanged("a", title: "A")
        store.popOut("a") { _ in false }
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"])
        XCTAssertEqual(newChats, 0)
    }

    func testSessionDeletedIsPublished() {
        store.activeSessionChanged("a", title: "A")
        var deleted: [String] = []
        let sink = store.sessionDeletions.sink { deleted.append($0) }
        store.sessionDeleted("a")
        XCTAssertEqual(deleted, ["a"])
        sink.cancel()
    }
```

Add `import Combine` to the top of `MacSessionTabsStoreTests.swift` if it is not there.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacSessionWindowRegistryTests' -only-testing:'ConduitMacTests/MacSessionTabsModelTests' -only-testing:'ConduitMacTests/MacSessionTabsStoreTests' CODE_SIGNING_ALLOWED=NO`
Expected: build FAILS: `cannot find 'MacSessionWindowToken' in scope`, `value of type 'MacSessionTabsModel' has no member 'detach'`.

- [ ] **Step 3: Implement**

`ConduitMac/Windows/MacSessionWindowToken.swift`:

```swift
import Foundation

/// The `WindowGroup(for:)` value of a session window (D21). Equal tokens are
/// the same window: SwiftUI focuses the open one instead of opening a second.
struct MacSessionWindowToken: Codable, Hashable {
    var dashboardID: UUID?
    var profile: String
    var sessionID: String
}
```

`ConduitMac/Windows/MacSessionWindowRegistry.swift`:

```swift
import Foundation

/// Which session windows exist (D21). A window counts from its request until
/// it closes, so four quick opens cannot overshoot the cap. A window that
/// appears without a request in this run is one SwiftUI restored at relaunch;
/// v1 does not restore windows, so the view closes it.
@MainActor
final class MacSessionWindowRegistry: ObservableObject {
    static let shared = MacSessionWindowRegistry()
    static let limit = 4

    @Published private(set) var open: Set<MacSessionWindowToken> = []
    private var requested: Set<MacSessionWindowToken> = []

    var isFull: Bool { requested.union(open).count >= Self.limit }

    /// False at the cap. An already requested or open token is always allowed (it focuses).
    func request(_ token: MacSessionWindowToken) -> Bool {
        if requested.contains(token) || open.contains(token) { return true }
        guard !isFull else { return false }
        requested.insert(token)
        return true
    }

    /// False for a window this run never requested (a restored one).
    func appeared(_ token: MacSessionWindowToken) -> Bool {
        guard requested.contains(token) else { return false }
        open.insert(token)
        return true
    }

    func disappeared(_ token: MacSessionWindowToken) {
        open.remove(token)
        requested.remove(token)
    }
}
```

In `ConduitMac/Tabs/MacSessionTabsModel.swift`, after `close(_:)`:

```swift
    /// Pop-out (D21): like `close`, but the tab does not go on the closed
    /// stack, because the session lives on in its own window.
    mutating func detach(_ id: String) -> CloseResult {
        let closedBefore = closed
        let result = close(id)
        closed = closedBefore
        return result
    }
```

In `ConduitMac/Tabs/MacSessionTabsStore.swift`:
- add the property under `@Published private(set) var model`:

```swift
    /// Sessions deleted while tabs were bound (D21: an open session window shows "deleted").
    let sessionDeletions = PassthroughSubject<String, Never>()
```

- replace `sessionDeleted(_:)` with:

```swift
    func sessionDeleted(_ id: String) {
        model.remove(id)
        save()
        sessionDeletions.send(id)
    }
```

- add after `reopen()`:

```swift
    /// Moves a tab into its own window (D21). `openWindow` returns false at the
    /// window cap; the tab then stays. Main activates the neighbour, or starts
    /// a new chat when the popped tab was the last.
    func popOut(_ id: String, openWindow: (String) -> Bool) {
        guard model.index(of: id) != nil, openWindow(id) else { return }
        switch model.detach(id) {
        case .activate(let next): openSession(next)
        case .closedLast: startNewChat()
        case .closedInactive, .notFound: break
        }
        save()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Windows ConduitMac/Tabs ConduitMacTests/MacSessionWindowRegistryTests.swift ConduitMacTests/MacSessionTabsModelTests.swift ConduitMacTests/MacSessionTabsStoreTests.swift
git commit -m "feat(mac): session window token, registry and tab detach (D21)"
```

---

### Task 2: Transcript reducer

**Files:**
- Create: `ConduitMac/Windows/MacSessionTranscript.swift`
- Test: `ConduitMacTests/MacSessionTranscriptTests.swift`

**Interfaces:**
- Consumes: `StreamEvent`, `ChatMessage`, `ToolActivity`, `ApprovalActivity`, `ClarifyActivity`, `InputPromptActivity`, `SessionResumeResult`, `SessionRuntimeSnapshot` (all upstream, read-only).
- Produces:

```swift
struct MacSessionTranscript: Equatable {
    enum Turn: Equatable { case idle, running, needsInput }
    enum Effect: Equatable { case none, turnEnded }
    private(set) var ids: Set<String>
    private(set) var runtimeID: String?
    private(set) var messages: [ChatMessage]
    private(set) var streamingText: String
    private(set) var turn: Turn
    private(set) var title: String?
    init(sessionID: String)
    func owns(_ id: String) -> Bool
    func isRelevant(_ event: StreamEvent) -> Bool
    mutating func adopt(_ ids: [String])
    mutating func hydrate(_ result: SessionResumeResult)
    mutating func userSent(_ text: String, timestamp: String)
    mutating func setTurn(_ turn: Turn)
    mutating func updateMessage(id: String, _ change: (inout ChatMessage) -> Void)
    @discardableResult mutating func apply(_ event: StreamEvent, timestamp: String) -> Effect
}
```

Rules (put them in the type's doc comment):
- `messageStart`: turn running; a non-empty `streamingText` is flushed first as an assistant row.
- `messageDelta`: append to `streamingText`; turn running.
- `reasoningDelta`: ignored (the settled transcript shows reasoning).
- `messageComplete`: one assistant row with `content ?? streamingText` and `reasoning`, id `messageId ?? "local-assistant-<n>"`; `streamingText` cleared; returns `.turnEnded` (the controller debounces, because a tool turn continues with another `messageStart`).
- `messageInterrupted`: flush, turn idle, `.turnEnded`.
- `messageError`: flush, one `.system` row with the sanitized text, turn idle, `.turnEnded`.
- `sessionBusy(busy)`: true sets running; false sets needsInput when a card is pending, else idle, and returns `.turnEnded`.
- `toolStart`: flush, append a `.tool` row with `ToolActivity(status: .running)`, id `"tool-<toolID or n>"`.
- `toolComplete`: the newest running tool row with the same `toolID` (or same name when `toolID` is nil) gets `output` and `.complete`.
- `approval` / `clarify` / `inputPrompt`: flush, append a card row (role `.approval` / `.clarify` / `.inputPrompt`), turn needsInput. Id `"approval-<requestId>"`, `"clarify-<requestId>"`, `"input-<requestId>"`.
- `approvalWithdrawn(requestId)`: that approval's status `.expired`, `error = reason`.
- `clarifyExpire(requestId)`: that clarify's `isExpired = true`.
- `inputPromptExpire(requestId)`: that prompt's status `.expired`.
- `sessionTitle(runtime, stored, title)`: when either id is owned, adopt both and set `title`.
- Everything else, and every event whose id is not owned: no change.
- `hydrate`: adopt `result.sessionId` (it becomes `runtimeID`) and `result.storedSessionId`; `messages = result.messages` plus a pending-card row (when not already in the rows) for `snapshot.pendingClarify`, each of `snapshot.additionalPendingClarifies`, each of `snapshot.pendingInputPrompts`, and the approval parsed by `MessageNormalizer.approvalActivity(from: snapshot.pendingApprovalPayload, sessionId: result.sessionId)` (the parser AppState uses at AppState.swift:11966); `streamingText = ""`; turn = running when `snapshot.running == true`, else needsInput when a card is pending, else idle.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacSessionTranscriptTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class MacSessionTranscriptTests: XCTestCase {
    private let ts = "2026-10-16T00:00:00Z"

    private func resume(_ id: String, stored: String? = nil, messages: [ChatMessage] = [], running: Bool? = nil) -> SessionResumeResult {
        SessionResumeResult(sessionId: id, storedSessionId: stored, messages: messages,
                            snapshot: .macTestSnapshot(running: running))
    }

    func testPlainTurnStreamsThenCompletes() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageStart(sessionId: "s"), timestamp: ts)
        t.apply(.messageDelta(sessionId: "s", text: "Hel"), timestamp: ts)
        t.apply(.messageDelta(sessionId: "s", text: "lo"), timestamp: ts)
        XCTAssertEqual(t.streamingText, "Hello")
        XCTAssertEqual(t.turn, .running)
        let effect = t.apply(.messageComplete(sessionId: "s", messageId: "m1", content: "Hello!", reasoning: nil), timestamp: ts)
        XCTAssertEqual(effect, .turnEnded)
        XCTAssertEqual(t.messages.map(\.id), ["m1"])
        XCTAssertEqual(t.messages.first?.content, "Hello!")
        XCTAssertEqual(t.streamingText, "")
    }

    func testForeignSessionIsIgnored() {
        var t = MacSessionTranscript(sessionID: "s")
        XCTAssertFalse(t.isRelevant(.messageDelta(sessionId: "other", text: "x")))
        t.apply(.messageDelta(sessionId: "other", text: "x"), timestamp: ts)
        XCTAssertEqual(t, MacSessionTranscript(sessionID: "s"))
    }

    func testAdoptsIdsFromResumeAndTitle() {
        var t = MacSessionTranscript(sessionID: "row")
        t.hydrate(resume("runtime-1", stored: "stored-1"))
        XCTAssertEqual(t.runtimeID, "runtime-1")
        XCTAssertTrue(t.isRelevant(.messageDelta(sessionId: "stored-1", text: "x")))
        t.apply(.sessionTitle(runtimeSessionId: "runtime-2", storedSessionId: "stored-1", title: "Plan"), timestamp: ts)
        XCTAssertEqual(t.title, "Plan")
        XCTAssertTrue(t.isRelevant(.messageDelta(sessionId: "runtime-2", text: "x")))
    }

    func testToolTurnFlushesTextAndCompletesTheTool() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageStart(sessionId: "s"), timestamp: ts)
        t.apply(.messageDelta(sessionId: "s", text: "Checking"), timestamp: ts)
        t.apply(.toolStart(sessionId: "s", toolName: "terminal", toolInput: "ls", toolID: "t1"), timestamp: ts)
        XCTAssertEqual(t.messages.map(\.role), [.assistant, .tool])
        XCTAssertEqual(t.messages.last?.tool?.status, .running)
        t.apply(.toolComplete(sessionId: "s", toolName: "terminal", toolOutput: "a.txt", toolID: "t1"), timestamp: ts)
        XCTAssertEqual(t.messages.last?.tool?.status, .complete)
        XCTAssertEqual(t.messages.last?.tool?.output, "a.txt")
    }

    func testToolCompleteWithoutIdMatchesNewestRunningByName() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.toolStart(sessionId: "s", toolName: "web", toolInput: nil, toolID: nil), timestamp: ts)
        t.apply(.toolStart(sessionId: "s", toolName: "web", toolInput: nil, toolID: nil), timestamp: ts)
        t.apply(.toolComplete(sessionId: "s", toolName: "web", toolOutput: "ok", toolID: nil), timestamp: ts)
        XCTAssertEqual(t.messages.map { $0.tool?.status }, [.running, .complete])
    }

    func testInterruptedAndErrorEndTheTurn() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageDelta(sessionId: "s", text: "partial"), timestamp: ts)
        XCTAssertEqual(t.apply(.messageInterrupted(sessionId: "s"), timestamp: ts), .turnEnded)
        XCTAssertEqual(t.messages.last?.content, "partial")
        XCTAssertEqual(t.turn, .idle)
        XCTAssertEqual(t.apply(.messageError(sessionId: "s", message: "Model busy"), timestamp: ts), .turnEnded)
        XCTAssertEqual(t.messages.last?.role, .system)
    }

    func testBusyFalseEndsTurnOrWaitsForCard() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.sessionBusy(sessionId: "s", busy: true), timestamp: ts)
        XCTAssertEqual(t.turn, .running)
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        XCTAssertEqual(t.turn, .needsInput)
        XCTAssertEqual(t.apply(.sessionBusy(sessionId: "s", busy: false), timestamp: ts), .turnEnded)
        XCTAssertEqual(t.turn, .needsInput, "a pending card keeps needsInput")
    }

    func testApprovalWithdrawnExpiresTheCard() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.approval(sessionId: "s", activity: .macTest(requestId: "r1")), timestamp: ts)
        t.apply(.approvalWithdrawn(sessionId: "s", requestId: "r1", reason: "timeout"), timestamp: ts)
        XCTAssertEqual(t.messages.last?.approval?.status, .expired)
        XCTAssertEqual(t.messages.last?.approval?.error, "timeout")
    }

    func testHydrateReplacesRowsAndReadsRunning() {
        var t = MacSessionTranscript(sessionID: "s")
        t.apply(.messageDelta(sessionId: "s", text: "drift"), timestamp: ts)
        let row = ChatMessage(id: "p1", role: .assistant, content: "persisted", timestamp: ts)
        t.hydrate(resume("s", messages: [row], running: true))
        XCTAssertEqual(t.messages.map(\.id), ["p1"])
        XCTAssertEqual(t.streamingText, "")
        XCTAssertEqual(t.turn, .running)
    }

    func testHydrateShowsPendingApproval() {
        var t = MacSessionTranscript(sessionID: "s")
        let snapshot = SessionRuntimeSnapshot(object: [
            "running": .bool(true),
            "pending_approval": .object(["request_id": .string("r9"), "command": .string("make"), "description": .string("Build")])
        ])
        t.hydrate(SessionResumeResult(sessionId: "s", storedSessionId: nil, messages: [], snapshot: snapshot))
        XCTAssertEqual(t.messages.last?.role, .approval)
        XCTAssertEqual(t.messages.last?.approval?.requestId, "r9")
    }

    func testUserSentAppendsAndRuns() {
        var t = MacSessionTranscript(sessionID: "s")
        t.userSent("Hi", timestamp: ts)
        XCTAssertEqual(t.messages.last?.role, .user)
        XCTAssertEqual(t.messages.last?.content, "Hi")
        XCTAssertEqual(t.turn, .running)
    }
}
```

Test helpers, in the same file below the class:

```swift
extension SessionRuntimeSnapshot {
    /// The parser init MissingSessionRecoveryTests uses (ConduitMacTests/MissingSessionRecoveryTests.swift:53).
    static func macTestSnapshot(running: Bool?) -> SessionRuntimeSnapshot {
        SessionRuntimeSnapshot(object: running.map { ["running": .bool($0)] } ?? [:])
    }
}

extension ApprovalActivity {
    static func macTest(requestId: String) -> ApprovalActivity {
        ApprovalActivity(sessionId: "s", requestId: requestId, command: "rm -rf build", description: "Delete build output",
                         choices: nil, allowPermanent: false, smartDenied: false, status: .pending, choice: nil, error: nil)
    }
}
```

If `ApprovalActivity`'s memberwise init differs from the call above (check `Conduit/Models/Models.swift:420-445`), match the real one.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacSessionTranscriptTests' CODE_SIGNING_ALLOWED=NO`
Expected: build FAILS: `cannot find 'MacSessionTranscript' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Windows/MacSessionTranscript.swift`:

```swift
import Foundation

/// A session window's transcript (D21): pure, no AppKit, no AppState. Folds
/// the window's own StreamEvents into rows. After every turn the controller
/// replaces it from the persisted transcript (`hydrate`), so any difference
/// from AppState's streaming reducer lasts one turn at most.
///
/// (Paste the rule list from the plan's Task 2 Interfaces section here.)
struct MacSessionTranscript: Equatable {
    enum Turn: Equatable { case idle, running, needsInput }
    enum Effect: Equatable { case none, turnEnded }

    static let maxErrorGraphemes = 300

    private(set) var ids: Set<String>
    private(set) var runtimeID: String?
    private(set) var messages: [ChatMessage] = []
    private(set) var streamingText = ""
    private(set) var turn: Turn = .idle
    private(set) var title: String?
    private var localCounter = 0

    init(sessionID: String) { ids = [sessionID] }

    func owns(_ id: String) -> Bool { ids.contains(id) }

    func isRelevant(_ event: StreamEvent) -> Bool {
        if case .sessionTitle(let runtime, let stored, _) = event { return owns(runtime) || owns(stored) }
        guard let id = Self.sessionID(of: event) else { return false }
        return owns(id)
    }

    mutating func adopt(_ newIDs: [String]) {
        for id in newIDs where !id.isEmpty { ids.insert(id) }
    }

    mutating func hydrate(_ result: SessionResumeResult) {
        runtimeID = result.sessionId
        adopt([result.sessionId, result.storedSessionId].compactMap { $0 })
        var rows = result.messages
        let pending = [result.snapshot.pendingClarify].compactMap { $0 } + result.snapshot.additionalPendingClarifies
        let stamp = rows.last?.timestamp ?? ""
        for clarify in pending where !rows.contains(where: { $0.clarify?.requestId == clarify.requestId }) {
            rows.append(ChatMessage(id: "clarify-\(clarify.requestId)", role: .clarify, content: "",
                                    timestamp: stamp, clarify: clarify))
        }
        for prompt in result.snapshot.pendingInputPrompts where !rows.contains(where: { $0.inputPrompt?.requestId == prompt.requestId }) {
            rows.append(ChatMessage(id: "input-\(prompt.requestId)", role: .inputPrompt, content: prompt.prompt,
                                    timestamp: stamp, inputPrompt: prompt))
        }
        if let payload = result.snapshot.pendingApprovalPayload,
           let approval = MessageNormalizer.approvalActivity(from: payload, sessionId: result.sessionId),
           !rows.contains(where: { $0.approval != nil && $0.approval?.requestId == approval.requestId }) {
            rows.append(ChatMessage(id: "approval-\(approval.requestId ?? "pending")", role: .approval,
                                    content: approval.description, timestamp: stamp, approval: approval))
        }
        messages = rows
        streamingText = ""
        if result.snapshot.running == true { turn = .running }
        else { turn = hasPendingCard ? .needsInput : .idle }
    }

    mutating func userSent(_ text: String, timestamp: String) {
        messages.append(ChatMessage(id: nextLocalID("user"), role: .user, content: text, timestamp: timestamp))
        turn = .running
    }

    mutating func setTurn(_ newTurn: Turn) { turn = newTurn }

    mutating func updateMessage(id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    @discardableResult
    mutating func apply(_ event: StreamEvent, timestamp: String) -> Effect {
        guard isRelevant(event) else { return .none }
        switch event {
        case .sessionTitle(let runtime, let stored, let newTitle):
            adopt([runtime, stored])
            title = newTitle
        case .messageStart:
            flush(timestamp)
            turn = .running
        case .messageDelta(_, let text):
            streamingText += text
            turn = .running
        case .messageComplete(_, let messageID, let content, let reasoning):
            let text = content ?? streamingText
            streamingText = ""
            messages.append(ChatMessage(id: messageID ?? nextLocalID("assistant"), role: .assistant,
                                        content: text, timestamp: timestamp, reasoning: reasoning))
            return .turnEnded
        case .messageInterrupted:
            flush(timestamp)
            turn = .idle
            return .turnEnded
        case .messageError(_, let message):
            flush(timestamp)
            messages.append(ChatMessage(id: nextLocalID("error"), role: .system,
                                        content: MacUntrustedText.sanitize(message, maxGraphemes: Self.maxErrorGraphemes),
                                        timestamp: timestamp))
            turn = .idle
            return .turnEnded
        case .sessionBusy(_, let busy):
            if busy { turn = .running; return .none }
            turn = hasPendingCard ? .needsInput : .idle
            return .turnEnded
        case .toolStart(_, let name, let input, let toolID):
            flush(timestamp)
            messages.append(ChatMessage(id: "tool-\(toolID ?? nextLocalID("t"))", role: .tool, content: "", timestamp: timestamp,
                                        tool: ToolActivity(id: toolID, name: name, input: input, output: nil, status: .running)))
        case .toolComplete(_, let name, let output, let toolID):
            let index = messages.lastIndex { row in
                guard let tool = row.tool, tool.status == .running else { return false }
                return toolID != nil ? tool.id == toolID : tool.name == name
            }
            if let index {
                messages[index].tool?.output = output
                messages[index].tool?.status = .complete
            }
        case .approval(_, let activity):
            flush(timestamp)
            messages.append(ChatMessage(id: "approval-\(activity.requestId ?? nextLocalID("a"))", role: .approval,
                                        content: activity.description, timestamp: timestamp, approval: activity))
            turn = .needsInput
        case .clarify(_, let activity):
            flush(timestamp)
            messages.append(ChatMessage(id: "clarify-\(activity.requestId)", role: .clarify, content: "",
                                        timestamp: timestamp, clarify: activity))
            turn = .needsInput
        case .inputPrompt(_, let activity):
            flush(timestamp)
            messages.append(ChatMessage(id: "input-\(activity.requestId)", role: .inputPrompt, content: activity.prompt,
                                        timestamp: timestamp, inputPrompt: activity))
            turn = .needsInput
        case .approvalWithdrawn(_, let requestID, let reason):
            if let index = messages.lastIndex(where: { $0.approval?.requestId == requestID }) {
                messages[index].approval?.status = .expired
                messages[index].approval?.error = reason
            }
        case .clarifyExpire(_, let requestID, _):
            if let index = messages.lastIndex(where: { $0.clarify?.requestId == requestID }) {
                messages[index].clarify?.isExpired = true
            }
        case .inputPromptExpire(_, let requestID, _):
            if let index = messages.lastIndex(where: { $0.inputPrompt?.requestId == requestID }) {
                messages[index].inputPrompt?.status = .expired
            }
        default:
            break
        }
        return .none
    }

    // MARK: Private

    private var hasPendingCard: Bool {
        messages.contains { row in
            if row.approval?.status == .pending { return true }
            if let clarify = row.clarify, !clarify.isExpired, clarify.questions.contains(where: { $0.status == .pending }) { return true }
            if row.inputPrompt?.status == .pending { return true }
            return false
        }
    }

    private mutating func flush(_ timestamp: String) {
        guard !streamingText.isEmpty else { return }
        messages.append(ChatMessage(id: nextLocalID("assistant"), role: .assistant, content: streamingText, timestamp: timestamp))
        streamingText = ""
    }

    private mutating func nextLocalID(_ kind: String) -> String {
        localCounter += 1
        return "local-\(kind)-\(localCounter)"
    }

    private static func sessionID(of event: StreamEvent) -> String? {
        switch event {
        case .messageStart(let id), .messageInterrupted(let id): return id
        case .messageDelta(let id, _), .reasoningDelta(let id, _), .messageError(let id, _), .sessionBusy(let id, _): return id
        case .messageComplete(let id, _, _, _): return id
        case .toolStart(let id, _, _, _), .toolComplete(let id, _, _, _): return id
        case .approval(let id, _), .clarify(let id, _), .inputPrompt(let id, _): return id
        case .approvalWithdrawn(let id, _, _), .clarifyExpire(let id, _, _), .inputPromptExpire(let id, _, _): return id
        default: return nil
        }
    }
}
```

If the compiler rejects a field name used above (for example `ClarifyQuestion.Status.pending` or `InputPromptActivity.status` mutability), read the type in `Conduit/Models/Models.swift` and use the real name. Do not change upstream types.

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`, 11 tests. If `testHydrateShowsPendingApproval` fails because the parser needs other keys, read `MessageNormalizer.approvalActivity` (HermesClient.swift:3794) and add the keys it requires to the test payload; do not loosen the assertion.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Windows/MacSessionTranscript.swift ConduitMacTests/MacSessionTranscriptTests.swift
git commit -m "feat(mac): session window transcript reducer (D21)"
```

---

### Task 3: Window controller

**Files:**
- Create: `ConduitMac/Windows/MacSessionWindowController.swift`
- Test: `ConduitMacTests/MacSessionWindowControllerTests.swift`

**Interfaces:**
- Consumes: `MacSessionTranscript` (Task 2), `MacSessionWindowToken` (Task 1), `MacStreamEventHub`, `MacSessionTabsStore.sessionDeletions` (Task 1), `HermesClient` RPCs, `AppState` publishers (`$client`, `$isConnected`, `$activeProfile`, `$savedDashboardRegistry`, `$sessions`).
- Produces:

```swift
struct MacSessionWindowScope: Equatable { var dashboardID: UUID?; var profile: String; var connected: Bool }

struct MacSessionWindowEnvironment {
    var scope: () -> MacSessionWindowScope
    var clientID: () -> ObjectIdentifier?
    var resume: (String) async throws -> SessionResumeResult
    var sendPrompt: (String, String) async throws -> PromptSubmissionOutcome
    var cancel: (String) async throws -> Void
    var activeSessions: () async throws -> [LiveSessionStatus]
    var respondToApproval: (String, String?, String) async throws -> Bool
    var respondToClarification: (String, String, String?) async throws -> HermesClient.ClarifyResponseOutcome
    var respondToInputPrompt: (String, String) async throws -> Void
    var catalogRow: (String) -> SessionSummary?
    var now: () -> Date
}

@MainActor final class MacSessionWindowController: ObservableObject {
    enum Phase: Equatable { case loading, ready, disconnected, wrongScope(String), deleted, failed(String) }
    @Published private(set) var transcript: MacSessionTranscript
    @Published private(set) var phase: Phase
    @Published var draft: String
    let token: MacSessionWindowToken
    var title: String { get }
    var canSend: Bool { get }
    init(token: MacSessionWindowToken, environment: MacSessionWindowEnvironment, hub: MacStreamEventHub? = nil, settleDelay: Duration = .milliseconds(600))
    func start()            // subscribe to the hub, first resume (when the scope matches)
    func stop()             // unsubscribe; cancel tasks
    func send()
    func stopTurn()
    func approve(messageID: String, choice: String)
    func answerClarify(messageID: String, questionID: String, answer: String)
    func answerInputPrompt(messageID: String, value: String?)
    func handle(_ event: StreamEvent)
    func scopeChanged()
    func clientChanged()
    func catalogChanged()
    func sessionDeleted(_ id: String)
    func bind(to appState: AppState, tabs: MacSessionTabsStore)
    static func environment(for appState: AppState, token: MacSessionWindowToken) -> MacSessionWindowEnvironment
    @Published private(set) var lastError: String?   // last send failure, cleared on the next send
}
```

Behaviour:
- `start()`: subscribe to the hub; if the scope matches, `phase = .loading` and resume; else `.wrongScope(token.profile)` (or `.disconnected` when not connected).
- Resume: `environment.resume(id)` where `id = transcript.runtimeID ?? token.sessionID`. Events that arrive while the resume is in flight are buffered and replayed after `hydrate`, in order. Success: `phase = .ready`. Failure: `phase = .failed(UserFacingError.message(for: error))`.
- `catalogChanged()`: adopt `catalogRow(token.sessionID)?.macTabIDs` (the row's ids).
- `handle(event)`: drop it unless `transcript.isRelevant(event)` (so a foreign delta never writes `@Published` state). While a resume is in flight, buffer it. Otherwise apply; on `.turnEnded` schedule a settle after `settleDelay`, cancelled by any later relevant `messageStart`, `messageDelta` or `toolStart`. A settle is a resume.
- `send()`: only when `canSend` (`phase == .ready`, `transcript.turn == .idle`, scope matches, draft not blank). Appends the user row (`userSent`), clears the draft, calls `sendPrompt(runtimeID ?? token.sessionID, text)`. If the outcome is not `.accepted` (`isBusySubmission`), a system row "Hermes was busy; your message was queued." is not built in v1: instead the turn stays running and the next settle shows what the server did. On error: restore the draft, set `lastError` (sanitized), turn idle. The next `send()` clears `lastError`.
- After `clientChanged()` sees a new non-nil `clientID`, the NEXT resume (now, or when the scope matches again if the new client is not connected yet) is followed by `activeSessions()`; if no row with a `runtimeSessionId` or `storedSessionId` the window owns `isRunning`, set turn idle (or needsInput with a pending card). This is the stale-idle hazard AppState documents near AppState.swift:827.
- `scopeChanged()`: when the scope no longer matches, `phase = .wrongScope(token.profile)`; when it matches again and the phase was wrongScope or disconnected, resume.
- `sessionDeleted(id)`: when the window owns `id`, `phase = .deleted`, unsubscribe.
- `approve` / `answerClarify` / `answerInputPrompt`: mark the row submitting, call the RPC with the activity's ids, then mark approved/answered/submitted, or set `error` on failure and back to pending. `answerInputPrompt(value: nil)` is Skip: there is no skip RPC in the window's v1 environment, so mark the row skipped locally and call `respondToInputPrompt(requestId, "")` only if the upstream `InputPromptCard` does the same (read ChatView.swift:3011-3030 and AppState.swift:24450 before writing this; copy what upstream sends for skip).
- No RPC runs while the scope does not match. Every closure in `environment(for:)` throws `HermesError.notConnected` when `appState.client` is nil, and refuses when `client.profile` differs from `token.profile`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacSessionWindowControllerTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowControllerTests: XCTestCase {
    private var hub: MacStreamEventHub!
    private var scope = MacSessionWindowScope(dashboardID: nil, profile: "default", connected: true)
    private var clientID: ObjectIdentifier? = ObjectIdentifier(NSObject())
    private var resumes: [String] = []
    private var resumeResult: SessionResumeResult!
    private var resumeGate: CheckedContinuation<Void, Never>?
    private var holdResume = false
    private var sends: [(String, String)] = []
    private var live: [LiveSessionStatus] = []
    private var liveCalls = 0
    private var failSend = false

    override func setUp() async throws {
        hub = MacStreamEventHub()
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: false))
        resumes = []; sends = []; live = []; liveCalls = 0; holdResume = false; failSend = false
    }

    private func makeController(sessionID: String = "row-1") -> MacSessionWindowController {
        var env = MacSessionWindowEnvironment()
        env.scope = { [unowned self] in scope }
        env.clientID = { [unowned self] in clientID }
        env.resume = { [unowned self] id in
            resumes.append(id)
            if holdResume { await withCheckedContinuation { resumeGate = $0 } }
            return resumeResult
        }
        env.sendPrompt = { [unowned self] id, text in
            if failSend { throw HermesError.notConnected }
            sends.append((id, text)); return .accepted
        }
        env.activeSessions = { [unowned self] in liveCalls += 1; return live }
        env.catalogRow = { _ in nil }
        let token = MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: sessionID)
        return MacSessionWindowController(token: token, environment: env, hub: hub, settleDelay: .milliseconds(10))
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testStartResumesAndBecomesReady() async {
        let c = makeController()
        c.start()
        await settle()
        XCTAssertEqual(resumes, ["row-1"])
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.transcript.runtimeID, "rt-1")
        XCTAssertEqual(hub.subscriberCount, 1)
        c.stop()
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testEventsDuringResumeAreReplayed() async {
        holdResume = true
        let c = makeController()
        c.start()
        await settle()
        hub.publish(.messageDelta(sessionId: "rt-1", text: "early"))
        XCTAssertEqual(c.transcript.streamingText, "", "buffered, not applied before hydrate")
        resumeGate?.resume()
        await settle()
        XCTAssertEqual(c.transcript.streamingText, "early")
    }

    func testResumeAdoptsRuntimeIdForSend() async {
        let c = makeController()
        c.start(); await settle()
        c.draft = "Hello"
        c.send(); await settle()
        XCTAssertEqual(sends.map(\.0), ["rt-1"])
        XCTAssertEqual(sends.map(\.1), ["Hello"])
        XCTAssertEqual(c.draft, "")
        XCTAssertEqual(c.transcript.turn, .running)
    }

    func testSendIsRefusedWhileRunning() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        c.draft = "Again"
        c.send(); await settle()
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(c.draft, "Again")
    }

    func testForeignEventsDoNotPublish() async {
        let c = makeController()
        c.start(); await settle()
        var publishes = 0
        let sink = c.objectWillChange.sink { publishes += 1 }
        for _ in 0..<50 { hub.publish(.messageDelta(sessionId: "main-chat", text: "x")) }
        XCTAssertEqual(publishes, 0)
        sink.cancel()
    }

    func testTurnEndSettlesFromHistory() async throws {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.messageComplete(sessionId: "rt-1", messageId: nil, content: "done", reasoning: nil))
        try await Task.sleep(for: .milliseconds(50))
        await settle()
        XCTAssertEqual(resumes.count, 2, "one start resume, one settle resume")
    }

    func testToolContinuationCancelsTheSettle() async throws {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.messageComplete(sessionId: "rt-1", messageId: nil, content: "step 1", reasoning: nil))
        hub.publish(.toolStart(sessionId: "rt-1", toolName: "terminal", toolInput: nil, toolID: "t1"))
        try await Task.sleep(for: .milliseconds(50))
        await settle()
        XCTAssertEqual(resumes.count, 1)
    }

    func testWrongScopeBlocksSendAndResume() async {
        let c = makeController()
        c.start(); await settle()
        scope.profile = "work"
        c.scopeChanged()
        XCTAssertEqual(c.phase, .wrongScope("default"))
        c.draft = "Hi"
        c.send(); await settle()
        XCTAssertTrue(sends.isEmpty)
        scope.profile = "default"
        c.scopeChanged(); await settle()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(resumes.count, 2)
    }

    func testNewClientRehydratesAndProbesBusy() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        XCTAssertEqual(c.transcript.turn, .running)
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: true))
        live = []   // the turn ended while disconnected
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()
        XCTAssertEqual(resumes.count, 2)
        XCTAssertEqual(liveCalls, 1)
        XCTAssertEqual(c.transcript.turn, .idle, "no live row says it is still running")
    }

    func testClientBeforeConnectProbesOnConnect() async {
        let c = makeController()
        c.start(); await settle()
        hub.publish(.sessionBusy(sessionId: "rt-1", busy: true))
        scope.connected = false
        c.scopeChanged()
        XCTAssertEqual(c.phase, .disconnected)
        clientID = ObjectIdentifier(NSObject())
        c.clientChanged(); await settle()      // new client, not connected yet
        XCTAssertEqual(resumes.count, 1)
        resumeResult = SessionResumeResult(sessionId: "rt-1", storedSessionId: "st-1", messages: [],
                                           snapshot: .macTestSnapshot(running: true))
        scope.connected = true
        c.scopeChanged(); await settle()
        XCTAssertEqual(resumes.count, 2)
        XCTAssertEqual(liveCalls, 1, "the probe still runs after the late connect")
        XCTAssertEqual(c.transcript.turn, .idle)
    }

    func testSendFailureRestoresDraftAndShowsError() async {
        let c = makeController()
        c.start(); await settle()
        failSend = true
        c.draft = "Hello"
        c.send(); await settle()
        XCTAssertEqual(c.draft, "Hello")
        XCTAssertNotNil(c.lastError)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.transcript.turn, .idle)
    }

    func testSameClientDoesNotRehydrate() async {
        let c = makeController()
        c.start(); await settle()
        c.clientChanged(); await settle()
        XCTAssertEqual(resumes.count, 1)
    }

    func testDeletionEndsTheWindow() async {
        let c = makeController()
        c.start(); await settle()
        c.sessionDeleted("st-1")
        XCTAssertEqual(c.phase, .deleted)
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testDisconnectedAtStartWaits() async {
        scope.connected = false
        let c = makeController()
        c.start(); await settle()
        XCTAssertEqual(c.phase, .disconnected)
        XCTAssertTrue(resumes.isEmpty)
    }
}
```

`SessionRuntimeSnapshot.macTestSnapshot` comes from Task 2's test file (same test target).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacSessionWindowControllerTests' CODE_SIGNING_ALLOWED=NO`
Expected: build FAILS: `cannot find 'MacSessionWindowController' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Windows/MacSessionWindowController.swift`:

```swift
import Combine
import Foundation

struct MacSessionWindowScope: Equatable {
    var dashboardID: UUID?
    var profile: String
    var connected: Bool
}

/// Everything the window does on the wire, injected (D21; the Quick Ask pattern, D15).
struct MacSessionWindowEnvironment {
    var scope: () -> MacSessionWindowScope = { MacSessionWindowScope(dashboardID: nil, profile: "default", connected: false) }
    var clientID: () -> ObjectIdentifier? = { nil }
    var resume: (String) async throws -> SessionResumeResult = { _ in throw HermesError.notConnected }
    var sendPrompt: (String, String) async throws -> PromptSubmissionOutcome = { _, _ in throw HermesError.notConnected }
    var cancel: (String) async throws -> Void = { _ in }
    var activeSessions: () async throws -> [LiveSessionStatus] = { [] }
    var respondToApproval: (String, String?, String) async throws -> Bool = { _, _, _ in throw HermesError.notConnected }
    var respondToClarification: (String, String, String?) async throws -> HermesClient.ClarifyResponseOutcome =
        { _, _, _ in throw HermesError.notConnected }
    var respondToInputPrompt: (String, String) async throws -> Void = { _, _ in throw HermesError.notConnected }
    var catalogRow: (String) -> SessionSummary? = { _ in nil }
    var now: () -> Date = { Date() }
}

/// One session window's state and wire traffic (D21). Holds no AppState state:
/// the shared HermesClient is reached only through `environment`.
@MainActor
final class MacSessionWindowController: ObservableObject {
    enum Phase: Equatable { case loading, ready, disconnected, wrongScope(String), deleted, failed(String) }

    static let maxTitleGraphemes = 80

    @Published private(set) var transcript: MacSessionTranscript
    @Published private(set) var phase: Phase = .loading
    @Published var draft = ""
    @Published private(set) var lastError: String?

    let token: MacSessionWindowToken
    private let environment: MacSessionWindowEnvironment
    private let hub: MacStreamEventHub
    private let settleDelay: Duration
    private var hubToken: MacStreamEventHub.Token?
    private var resumeInFlight = false
    private var buffered: [StreamEvent] = []
    private var settleTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var lastClientID: ObjectIdentifier?
    /// Set by a client change; the next resume then asks the live list (stale idle).
    private var probeOnNextResume = false
    private var bindings: Set<AnyCancellable> = []
    private static let timestampFormatter = ISO8601DateFormatter()

    init(token: MacSessionWindowToken, environment: MacSessionWindowEnvironment,
         hub: MacStreamEventHub? = nil, settleDelay: Duration = .milliseconds(600)) {
        self.token = token
        self.environment = environment
        self.hub = hub ?? .shared
        self.settleDelay = settleDelay
        self.transcript = MacSessionTranscript(sessionID: token.sessionID)
    }

    var title: String {
        let raw = transcript.title ?? environment.catalogRow(token.sessionID)?.title ?? AppLocalization.string("Conversation")
        return MacUntrustedText.sanitize(raw, maxGraphemes: Self.maxTitleGraphemes)
    }

    var canSend: Bool {
        phase == .ready && transcript.turn == .idle && scopeMatches
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scopeMatches: Bool {
        let scope = environment.scope()
        return scope.connected && scope.profile == token.profile && scope.dashboardID == token.dashboardID
    }

    // MARK: Lifecycle

    func start() {
        if hubToken == nil {
            hubToken = hub.subscribe { [weak self] event in self?.handle(event) }
        }
        lastClientID = environment.clientID()
        catalogChanged()
        refreshPhaseForScope()
    }

    func stop() {
        if let hubToken { hub.unsubscribe(hubToken) }
        hubToken = nil
        settleTask?.cancel()
        resumeTask?.cancel()
        bindings.removeAll()
    }

    // MARK: Events

    func handle(_ event: StreamEvent) {
        guard transcript.isRelevant(event) else { return }
        if resumeInFlight { buffered.append(event); return }
        apply(event)
    }

    private func apply(_ event: StreamEvent) {
        switch event {
        case .messageStart, .messageDelta, .toolStart: settleTask?.cancel()
        default: break
        }
        if transcript.apply(event, timestamp: timestamp()) == .turnEnded { scheduleSettle() }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        let delay = settleDelay
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    // MARK: Resume

    private func resume() {
        guard scopeMatches, phase != .deleted else { return }
        let probeBusy = probeOnNextResume
        probeOnNextResume = false
        resumeTask?.cancel()
        resumeInFlight = true
        let id = transcript.runtimeID ?? token.sessionID
        resumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await environment.resume(id)
                guard !Task.isCancelled else { return }
                transcript.hydrate(result)
                let replay = buffered
                buffered = []
                resumeInFlight = false
                replay.forEach(apply)
                phase = .ready
                if probeBusy { await probeLiveStatus() }
            } catch {
                guard !Task.isCancelled else { return }
                resumeInFlight = false
                buffered = []
                phase = .failed(MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300))
            }
        }
    }

    /// After a reconnect the resume can report a turn that already ended; the
    /// gateway's live list is the authority (AppState.swift:827, stale idle).
    private func probeLiveStatus() async {
        guard transcript.turn == .running, let rows = try? await environment.activeSessions() else { return }
        let stillRunning = rows.contains { row in
            row.isRunning && (transcript.owns(row.runtimeSessionId) || transcript.owns(row.storedSessionId))
        }
        if !stillRunning { transcript.setTurn(.idle) }
    }

    // MARK: Changes from AppState

    func scopeChanged() { refreshPhaseForScope() }

    func clientChanged() {
        let current = environment.clientID()
        guard current != lastClientID else { return }
        lastClientID = current
        guard current != nil, phase != .deleted else { refreshPhaseForScope(); return }
        probeOnNextResume = true
        if scopeMatches {
            phase = .loading
            resume()
        } else {
            refreshPhaseForScope()
        }
    }

    func catalogChanged() {
        guard let row = environment.catalogRow(token.sessionID) else { return }
        transcript.adopt(row.macTabIDs)
    }

    func sessionDeleted(_ id: String) {
        guard transcript.owns(id) else { return }
        phase = .deleted
        if let hubToken { hub.unsubscribe(hubToken) }
        hubToken = nil
        settleTask?.cancel()
    }

    /// Matching scope: resume unless already ready or a resume is in flight.
    private func refreshPhaseForScope() {
        guard phase != .deleted else { return }
        let scope = environment.scope()
        if !scope.connected { phase = .disconnected; return }
        if scope.profile != token.profile || scope.dashboardID != token.dashboardID {
            phase = .wrongScope(token.profile)
            return
        }
        switch phase {
        case .ready: return
        case .loading where resumeInFlight: return
        default:
            phase = .loading
            resume()
        }
    }

    // MARK: Intents

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        lastError = nil
        transcript.userSent(text, timestamp: timestamp())
        let id = transcript.runtimeID ?? token.sessionID
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await environment.sendPrompt(id, text)
            } catch {
                draft = text
                transcript.setTurn(.idle)
                lastError = MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300)
            }
        }
    }

    func stopTurn() {
        guard transcript.turn != .idle, scopeMatches else { return }
        let id = transcript.runtimeID ?? token.sessionID
        let cancel = environment.cancel
        Task { try? await cancel(id) }
    }

    func approve(messageID: String, choice: String) {
        guard scopeMatches, let approval = transcript.messages.first(where: { $0.id == messageID })?.approval,
              approval.status == .pending else { return }
        transcript.updateMessage(id: messageID) { $0.approval?.status = .submitting; $0.approval?.choice = choice }
        Task { [weak self] in
            guard let self else { return }
            do {
                let accepted = try await environment.respondToApproval(approval.sessionId, approval.requestId, choice)
                transcript.updateMessage(id: messageID) {
                    $0.approval?.status = accepted ? (choice == "deny" ? .rejected : .approved) : .expired
                }
            } catch {
                transcript.updateMessage(id: messageID) {
                    $0.approval?.status = .pending
                    $0.approval?.choice = nil
                    $0.approval?.error = MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300)
                }
            }
        }
    }

    func answerClarify(messageID: String, questionID: String, answer: String) {
        guard scopeMatches, let clarify = transcript.messages.first(where: { $0.id == messageID })?.clarify,
              !clarify.isExpired else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await environment.respondToClarification(clarify.requestId, answer, questionID)
                transcript.updateMessage(id: messageID) { row in
                    if case .expired = outcome { row.clarify?.isExpired = true; return }
                    if let index = row.clarify?.questions.firstIndex(where: { $0.id == questionID }) {
                        row.clarify?.questions[index].status = .answered
                        row.clarify?.questions[index].answer = answer
                    }
                }
            } catch {
                transcript.updateMessage(id: messageID) {
                    $0.clarify?.error = MacUntrustedText.sanitize(UserFacingError.message(for: error), maxGraphemes: 300)
                }
            }
        }
    }

    func answerInputPrompt(messageID: String, value: String?) {
        guard scopeMatches, let prompt = transcript.messages.first(where: { $0.id == messageID })?.inputPrompt,
              prompt.status == .pending else { return }
        transcript.updateMessage(id: messageID) { $0.inputPrompt?.status = .submitting }
        Task { [weak self] in
            guard let self else { return }
            do {
                // Skip sends what upstream's InputPromptCard sends for skip (read ChatView.swift:3026, AppState.swift:24450).
                try await environment.respondToInputPrompt(prompt.requestId, value ?? "")
                transcript.updateMessage(id: messageID) { $0.inputPrompt?.status = value == nil ? .skipped : .submitted }
            } catch {
                transcript.updateMessage(id: messageID) { $0.inputPrompt?.status = .error }
            }
        }
    }

    private func timestamp() -> String { Self.timestampFormatter.string(from: environment.now()) }

    // MARK: Binding

    func bind(to appState: AppState, tabs: MacSessionTabsStore) {
        guard bindings.isEmpty else { return }
        appState.$client.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.clientChanged() }.store(in: &bindings)
        Publishers.CombineLatest3(appState.$isConnected, appState.$activeProfile, appState.$savedDashboardRegistry)
            .dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.scopeChanged() }.store(in: &bindings)
        appState.$sessions.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.catalogChanged() }.store(in: &bindings)
        tabs.sessionDeletions.receive(on: RunLoop.main)
            .sink { [weak self] id in self?.sessionDeleted(id) }.store(in: &bindings)
    }

    /// The real environment. A client whose profile is not the token's is never used.
    static func environment(for appState: AppState, token: MacSessionWindowToken) -> MacSessionWindowEnvironment {
        func client() throws -> HermesClient {
            guard let client = appState.client, (client.profile ?? "default") == token.profile else { throw HermesError.notConnected }
            return client
        }
        return MacSessionWindowEnvironment(
            scope: { [weak appState] in
                MacSessionWindowScope(dashboardID: appState?.activeDashboardID, profile: appState?.activeProfile ?? "default",
                                      connected: (appState?.isConnected ?? false) && !(appState?.isProfileSwitching ?? true))
            },
            clientID: { [weak appState] in appState?.client.map(ObjectIdentifier.init) },
            resume: { id in try await client().openSessionLegacy(id) },
            sendPrompt: { id, text in try await client().sendPrompt(id, text: text) },
            cancel: { id in try await client().cancel(id) },
            activeSessions: { try await client().activeSessions() },
            respondToApproval: { session, request, choice in
                try await client().respondToApproval(sessionId: session, requestId: request, choice: choice)
            },
            respondToClarification: { request, answer, question in
                try await client().respondToClarification(requestId: request, answer: answer, questionId: question)
            },
            respondToInputPrompt: { request, value in try await client().respondToInputPrompt(requestId: request, value: value) },
            catalogRow: { [weak appState] id in appState?.sessions.first { $0.macMatches(id) } },
            now: { Date() })
    }
}
```

Notes for the implementer:
- `client.profile` is `String?`; check how AppState names the default profile when `profile` is nil (grep `HermesClient(connection:` in AppState.swift). If AppState passes `nil` for "default", the comparison above is right; otherwise compare the way AppState does.
- `refreshPhaseForScope` must not start a second resume while one is in flight; `testWrongScopeBlocksSendAndResume`, `testSameClientDoesNotRehydrate` and `testClientBeforeConnectProbesOnConnect` pin this.

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`, 14 tests. Run it twice; it must pass both times (the settle tests use real sleeps).

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Windows/MacSessionWindowController.swift ConduitMacTests/MacSessionWindowControllerTests.swift
git commit -m "feat(mac): session window controller on the shared client and stream hub (D21)"
```

---

### Task 4: Window views (transcript, cards, composer)

**Files:**
- Create: `ConduitMac/Windows/MacSessionWindowView.swift`
- Create: `ConduitMac/Windows/MacSessionWindowCards.swift`
- Create: `ConduitMac/Windows/MacSessionWindowComposer.swift`
- Modify: `ConduitMac/Chat/ComposerPasteTextView.swift` (add `followsMainRoute`)
- Modify: `Conduit/Localizable.xcstrings` (new strings)
- Test: `ConduitMacTests/MacSessionWindowViewTests.swift`

**Interfaces:**
- Consumes: `MacSessionWindowController` (Task 3), `MessageBubble(message:gatewayResolver:)`, `StreamingBubble(text:active:)`, `ComposerPasteTextView`.
- Produces: `struct MacSessionWindowView: View { init(controller: MacSessionWindowController) }`; `ComposerPasteTextView.followsMainRoute: Bool` (default `true`).

View rules:
- Header: none (the window title bar shows `controller.title` via `.navigationTitle`).
- Banner above the transcript for `.loading` ("Opening conversation..."), `.disconnected` ("Not connected to Hermes"), `.wrongScope(p)` ("Belongs to %@. Switch to it in the main window to continue." with `profileDisplayName(p)`), `.deleted` ("This conversation was deleted." plus a Close button that calls `dismissWindow`), `.failed(m)` (the message plus a Retry button that calls `controller.scopeChanged()`).
- Transcript: `ScrollViewReader` + `ScrollView` + `LazyVStack(alignment: .leading, spacing: 12)`. Rows with role `.approval`, `.clarify`, `.inputPrompt` render the Mac cards; every other row renders `MessageBubble(message:gatewayResolver: appState.gatewayMediaResolver)`. While `transcript.streamingText` is not empty, a `StreamingBubble(text:active: true)` follows the rows. Follow-bottom: scroll to the last row when the row count or `streamingText` changes and the user is near the bottom (track with `onScrollGeometryChange` only on macOS 15; on 14 always follow; keep it simple: always scroll on change in v1).
- Composer: `MacSessionWindowComposer`. Above the field, `controller.lastError` in red caption text when set. Return sends (`returnKeySends: true`, `canSubmitFromReturn: controller.canSend`, `onSubmitFromReturn: { controller.send(); return true }`), Shift-Return newline. A Send button (paperplane) when idle; a Stop button (stop.fill) while `transcript.turn != .idle`, which calls `stopTurn()`. Disabled unless `phase == .ready`. Pasted image: show "Images can't be attached in this window." under the field for 4 s. Own `NotificationCenter()` instance for `focusRequestCenter` is NOT used; the default center is correct because Cmd-L posts with the key window as `object` (Task 5 stops the main-pane switch).
- Cards (MacSessionWindowCards.swift), each a small `VStack` in a rounded rect, using `.conduitAccent` for the primary button:
  - `MacWindowApprovalCard(activity:onChoose:)`: command in monospaced text, description, buttons from `activity.choices ?? ["once", "deny"]` labelled with upstream's labels (read `ApprovalCard` in ChatView.swift:2687-2860 for the label mapping and copy it), status text when not pending, `error` in red.
  - `MacWindowClarifyCard(activity:onAnswer:)`: each pending question with its choices as buttons, or a text field plus Send for free text; answered questions show their answer; expired shows "Expired".
  - `MacWindowInputPromptCard(activity:onSubmit:)`: `SecureField` for sudo, secret and vault unlock; Submit and Skip; status text when not pending.
- `.environmentObject(appState)` is required for `MessageBubble`. Pass `AppStateRuntimeRegistry.shared.appState`.

`ComposerPasteTextView` change: add `var followsMainRoute = true` after `var onUserEdit`. In `updateNSView`, replace `MacChatRoute.isChatActive(tabRaw: routeTabRaw)` with `(!followsMainRoute || MacChatRoute.isChatActive(tabRaw: routeTabRaw))`. Grep the file for every other `isChatActive` use and apply the same rule. The default keeps main unchanged.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacSessionWindowViewTests.swift`, following the hosting pattern in `ConduitMacTests/MacQuickAskViewTests.swift` (open it and reuse its helper for hosting a SwiftUI view in an `NSHostingView` and reading accessibility):

```swift
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowViewTests: XCTestCase {
    private func controller(phase setup: (inout MacSessionWindowEnvironment) -> Void = { _ in }) -> MacSessionWindowController {
        var env = MacSessionWindowEnvironment()
        env.scope = { MacSessionWindowScope(dashboardID: nil, profile: "default", connected: true) }
        env.resume = { _ in SessionResumeResult(sessionId: "rt", storedSessionId: nil,
            messages: [ChatMessage(id: "u1", role: .user, content: "Hi", timestamp: "2026-10-16T00:00:00Z")],
            snapshot: .macTestSnapshot(running: false)) }
        setup(&env)
        return MacSessionWindowController(token: MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: "s"),
                                          environment: env, hub: MacStreamEventHub())
    }

    func testRendersInLightAndDark() async throws {
        let c = controller()
        c.start()
        for _ in 0..<20 { await Task.yield() }
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: MacSessionWindowView(controller: c)
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 760)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    func testStopShowsWhileRunning() async {
        let c = controller()
        c.start()
        for _ in 0..<20 { await Task.yield() }
        c.handle(.sessionBusy(sessionId: "rt", busy: true))
        XCTAssertEqual(MacSessionWindowComposer.primaryAction(for: c), .stop)
        c.handle(.sessionBusy(sessionId: "rt", busy: false))
        XCTAssertEqual(MacSessionWindowComposer.primaryAction(for: c), .send)
    }

    func testBannerTextPerPhase() {
        XCTAssertNil(MacSessionWindowView.bannerText(for: .ready, profileName: { $0 }))
        XCTAssertEqual(MacSessionWindowView.bannerText(for: .disconnected, profileName: { $0 }),
                       AppLocalization.string("Not connected to Hermes"))
        XCTAssertTrue(MacSessionWindowView.bannerText(for: .wrongScope("work"), profileName: { $0.uppercased() })?
            .contains("WORK") ?? false)
    }

    func testComposerFollowsMainRouteByDefault() {
        let view = ComposerPasteTextView(text: .constant(""), isFocused: .constant(false), measuredHeight: .constant(0),
                                         enabled: true, onPastedImage: { _ in }, onPastedImageError: { _ in },
                                         editorIdentity: UUID())
        XCTAssertTrue(view.followsMainRoute)
    }
}
```

Add to the design of `MacSessionWindowComposer`: `enum PrimaryAction: Equatable { case send, stop }` and `static func primaryAction(for: MacSessionWindowController) -> PrimaryAction` (stop when `transcript.turn != .idle`). Add to `MacSessionWindowView`: `static func bannerText(for: MacSessionWindowController.Phase, profileName: (String) -> String) -> String?`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacSessionWindowViewTests' CODE_SIGNING_ALLOWED=NO`
Expected: build FAILS: `cannot find 'MacSessionWindowView' in scope`.

- [ ] **Step 3: Implement**

Write the three files to the View rules above. Skeleton for `MacSessionWindowView.swift`:

```swift
import SwiftUI

/// A popped-out session (D21): banner, transcript, composer. AppState is in the
/// environment only for MessageBubble (profile names, media); the session state
/// is the controller's.
struct MacSessionWindowView: View {
    @ObservedObject var controller: MacSessionWindowController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if let banner = Self.bannerText(for: controller.phase, profileName: appState.profileDisplayName) {
                MacSessionWindowBanner(text: banner, phase: controller.phase,
                                       onRetry: { controller.scopeChanged() },
                                       onClose: { dismissWindow() })
            }
            transcript
            Divider()
            MacSessionWindowComposer(controller: controller)
                .padding(12)
        }
        .navigationTitle(controller.title)
        .frame(minWidth: 420, minHeight: 420)
        .background(ConduitBackdrop(drifts: false))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.transcript.messages) { message in
                        row(message).id(message.id)
                    }
                    if !controller.transcript.streamingText.isEmpty {
                        StreamingBubble(text: controller.transcript.streamingText, active: true).id("streaming")
                    }
                }
                .padding(16)
            }
            .onChange(of: controller.transcript.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: controller.transcript.streamingText) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        switch message.role {
        case .approval:
            if let activity = message.approval {
                MacWindowApprovalCard(activity: activity) { controller.approve(messageID: message.id, choice: $0) }
            }
        case .clarify:
            if let activity = message.clarify {
                MacWindowClarifyCard(activity: activity) { question, answer in
                    controller.answerClarify(messageID: message.id, questionID: question, answer: answer)
                }
            }
        case .inputPrompt:
            if let activity = message.inputPrompt {
                MacWindowInputPromptCard(activity: activity) { controller.answerInputPrompt(messageID: message.id, value: $0) }
            }
        default:
            MessageBubble(message: message, gatewayResolver: appState.gatewayMediaResolver)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: String? = controller.transcript.streamingText.isEmpty ? controller.transcript.messages.last?.id : "streaming"
        guard let target else { return }
        proxy.scrollTo(target, anchor: .bottom)
    }

    static func bannerText(for phase: MacSessionWindowController.Phase, profileName: (String) -> String) -> String? {
        switch phase {
        case .ready: return nil
        case .loading: return AppLocalization.string("Opening conversation...")
        case .disconnected: return AppLocalization.string("Not connected to Hermes")
        case .wrongScope(let profile):
            return String(format: AppLocalization.string("Belongs to %@. Switch to it in the main window to continue."),
                          MacUntrustedText.sanitize(profileName(profile), maxGraphemes: 40))
        case .deleted: return AppLocalization.string("This conversation was deleted.")
        case .failed(let message): return message
        }
    }
}
```

Check before using: `ConduitBackdrop(drifts:)` exists (RootView uses it); `appState.profileDisplayName` takes a `String` and returns `String` (AppState.swift:8234), so it can be passed as the `profileName` closure; if not, wrap it in `{ appState.profileDisplayName($0) }`. `ChatMessage` is `Identifiable`, so `ForEach(messages)` works.

Write `MacSessionWindowBanner` (in the same file, private): an `HStack` with the text, a Retry button for `.failed`, a Close button for `.deleted`, styled like the app's existing connection banner (grep `ConnectionStatusIndicator` or a banner in ChatView for colours; reuse colours, not views).

`MacSessionWindowComposer.swift`: an `HStack(alignment: .bottom)` with `ComposerPasteTextView(text: $controller.draft, isFocused: $focused, measuredHeight: $height, enabled: controller.phase == .ready, onPastedImage: { _ in showImageNotice() }, onPastedImageError: { _ in showImageNotice() }, editorIdentity: editorID, returnKeySends: true, canSubmitFromReturn: controller.canSend, onSubmitFromReturn: { controller.send(); return true }, followsMainRoute: false)` framed to `height` clamped to `ComposerPasteTextView.minimumHeight...maximumHeight`, and the Send or Stop button. `@State private var focused = true` so the field takes focus when the window opens. Check the real argument order and labels of `ComposerPasteTextView` at ConduitMac/Chat/ComposerPasteTextView.swift:12-34 and the reference call at Conduit/Views/Components/ComposerBar.swift:515-545; match them exactly.

`MacSessionWindowCards.swift`: the three cards from the View rules. Before writing the approval buttons, read `ApprovalCard` (ChatView.swift:2687-2860) for how choices map to labels ("once", "session", "always", "deny") and copy the mapping into a private `static func label(for choice: String) -> String` in this file.

Add every new user-visible string to `Conduit/Localizable.xcstrings` (English value only), then run `python3 scripts/check-l10n-coverage.py` and fix what it reports.

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command, then the existing composer tests: `-only-testing:'ConduitMacTests/ComposerPasteTextViewTests'` (find the real class name with `ls ConduitMacTests | grep -i composer`). Expected: both `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Windows ConduitMac/Chat/ComposerPasteTextView.swift Conduit/Localizable.xcstrings ConduitMacTests/MacSessionWindowViewTests.swift
git commit -m "feat(mac): session window view, cards and composer (D21)"
```

---

### Task 5: Scene, menu command, tab menu item, Cmd-L

**Files:**
- Create: `ConduitMac/Windows/MacSessionWindows.swift` (scene content and the open helper)
- Modify: `ConduitMac/App/ConduitMacApp.swift` (second `WindowGroup`)
- Modify: `ConduitMac/App/ConduitCommands.swift` (File item)
- Modify: `ConduitMac/Tabs/MacSessionTabStrip.swift` (context menu item)
- Modify: `ConduitMac/App/MacKeyboardShortcuts.swift` (`focusComposer` must not switch the main pane from a session window)
- Modify: `ConduitMacTests/MacKeyboardTests.swift` (`shortcuts()` table)
- Test: `ConduitMacTests/MacSessionWindowsTests.swift`

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces:

```swift
@MainActor enum MacSessionWindows {
    static let sceneID = "conduit-session"
    static func isSessionWindow(_ window: NSWindow?) -> Bool
    static func token(for sessionID: String, appState: AppState) -> MacSessionWindowToken
    /// False at the cap (and it beeps). Opens or focuses the window.
    @discardableResult static func open(_ sessionID: String, appState: AppState,
                                        registry: MacSessionWindowRegistry? = nil,
                                        openWindow: (MacSessionWindowToken) -> Void) -> Bool
}
struct MacSessionWindowScene: View { let token: MacSessionWindowToken? }
```

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacSessionWindowsTests.swift`:

```swift
import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowsTests: XCTestCase {
    func testSessionWindowIdentifierIsNotMainChatWindow() {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        XCTAssertTrue(MacSessionWindows.isSessionWindow(window))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(window), "Cmd-W closes the window, not a tab")
    }

    func testOpenRequestsTokenAndCallsOpenWindow() {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        var opened: [MacSessionWindowToken] = []
        XCTAssertTrue(MacSessionWindows.open("s1", appState: appState, registry: registry) { opened.append($0) })
        XCTAssertEqual(opened.map(\.sessionID), ["s1"])
        XCTAssertEqual(opened.first?.profile, appState.activeProfile)
    }

    func testOpenAtCapDoesNotCallOpenWindow() {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        for id in ["a", "b", "c", "d"] { _ = MacSessionWindows.open(id, appState: appState, registry: registry) { _ in } }
        var opened = 0
        XCTAssertFalse(MacSessionWindows.open("e", appState: appState, registry: registry) { _ in opened += 1 })
        XCTAssertEqual(opened, 0)
    }

    func testFocusComposerFromSessionWindowKeepsMainPane() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        let center = NotificationCenter()
        var posted: [Any?] = []
        let observer = center.addObserver(forName: .macFocusComposerRequested, object: nil, queue: nil) { posted.append($0.object) }
        MacKeyboardActions.focusComposer(window: window, defaults: suite.defaults, center: center)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
        XCTAssertEqual(posted.count, 1)
        center.removeObserver(observer)
    }
}
```

Check `SidebarTab` has a `kanban` case (`grep -n "case" Conduit/Views/SidebarTab.swift`); use any non-sessions case if it does not.

In `ConduitMacTests/MacKeyboardTests.swift`, find `shortcuts()` (around :456) and add the row next to the File rows:

```swift
            ("/File/Open Session in New Window", "n", [.option, .command]),
```

Use the tuple shape the table already uses; if modifiers are written differently there, match them.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacSessionWindowsTests' -only-testing:'ConduitMacTests/MacKeyboardMenuTests' CODE_SIGNING_ALLOWED=NO`
Expected: build FAILS: `cannot find 'MacSessionWindows' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Windows/MacSessionWindows.swift`:

```swift
import AppKit
import SwiftUI

/// Opening session windows (D21) and the scene's content.
@MainActor
enum MacSessionWindows {
    static let sceneID = "conduit-session"

    static func isSessionWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix(sceneID) ?? false
    }

    static func token(for sessionID: String, appState: AppState) -> MacSessionWindowToken {
        MacSessionWindowToken(dashboardID: appState.activeDashboardID, profile: appState.activeProfile,
                              sessionID: MacQuickAskController.openableID(sessionID, in: appState.sessions))
    }

    @discardableResult
    static func open(_ sessionID: String, appState: AppState, registry: MacSessionWindowRegistry? = nil,
                     openWindow: (MacSessionWindowToken) -> Void) -> Bool {
        let token = token(for: sessionID, appState: appState)
        guard (registry ?? .shared).request(token) else {
            NSSound.beep()
            return false
        }
        openWindow(token)
        return true
    }
}

/// The `WindowGroup(for:)` content. Shares the main window's look (locale,
/// tint, colour scheme) but not `rootContent`: that claims external URL
/// events (`handlesExternalEvents`), which must stay with the main window.
struct MacSessionWindowScene: View {
    let token: MacSessionWindowToken?
    @ObservedObject private var appState = AppStateRuntimeRegistry.shared.appState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @StateObject private var holder = Holder()
    @Environment(\.dismissWindow) private var dismissWindow

    @MainActor
    final class Holder: ObservableObject { var controller: MacSessionWindowController? }

    var body: some View {
        Group {
            if let controller = holder.controller {
                MacSessionWindowView(controller: controller)
            } else {
                Color.clear
            }
        }
        .environmentObject(appState)
        .environment(\.locale, appLanguage.resolvedLocale)
        .preferredColorScheme(appState.themePreference.colorScheme)
        .tint(.conduitAccent)
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
    }

    private func appear() {
        guard let token, MacSessionWindowRegistry.shared.appeared(token) else {
            dismissWindow()   // restored at relaunch, or no value: v1 does not restore windows
            return
        }
        guard holder.controller == nil else { return }
        let controller = MacSessionWindowController(token: token,
                                                    environment: MacSessionWindowController.environment(for: appState, token: token))
        controller.bind(to: appState, tabs: .shared)
        controller.start()
        holder.controller = controller
    }

    private func disappear() {
        holder.controller?.stop()
        holder.controller = nil
        if let token { MacSessionWindowRegistry.shared.disappeared(token) }
    }
}
```

Since `holder.controller` is set in `onAppear` and `Holder` publishes nothing, call `holder.objectWillChange.send()` before assigning, or make `controller` `@Published`. Make it `@Published`.

`ConduitMac/App/ConduitMacApp.swift`, in `body` after the existing `WindowGroup`:

```swift
        WindowGroup("Conduit Chat", id: MacSessionWindows.sceneID, for: MacSessionWindowToken.self) { $token in
            MacSessionWindowScene(token: token)
        }
        .defaultSize(width: 640, height: 760)
```

The `.commands` modifier stays on the first `WindowGroup` only.

`ConduitMac/App/ConduitCommands.swift`:
- add `@Environment(\.openWindow) private var openWindow` with the other properties.
- in `CommandGroup(replacing: .newItem)`, after "New Chat":

```swift
            // A popped-out session (D21): the main window's active tab moves to its own window.
            Button("Open Session in New Window") {
                guard !MacKeyboardActions.commandsBlocked(by: NSApp.keyWindow), !MacSessionWindows.isSessionWindow(NSApp.keyWindow),
                      let id = tabs.model.activeID else { return }
                tabs.popOut(id) { sessionID in
                    MacSessionWindows.open(sessionID, appState: appState) { openWindow(value: $0) }
                }
            }
            .keyboardShortcut("n", modifiers: [.option, .command])
```

`ConduitMac/Tabs/MacSessionTabStrip.swift`:
- `MacSessionTabStrip` gets `@Environment(\.openWindow) private var openWindow` and `@ObservedObject private var windows = MacSessionWindowRegistry.shared`, and passes `onPopOut: { popOut(tab.id) }` and `canPopOut: !windows.isFull` to each `MacSessionTabButton`, with:

```swift
    private func popOut(_ id: String) {
        store.popOut(id) { sessionID in
            MacSessionWindows.open(sessionID, appState: appState) { openWindow(value: $0) }
        }
    }
```

- `MacSessionTabButton` gets `let onPopOut: () -> Void` and `let canPopOut: Bool`, and the context menu becomes:

```swift
        .contextMenu {
            if let session {
                SessionActionMenuItems(session: session, onRename: { onRename(session) }, onDelete: { onDelete(session) })
            }
            Button(AppLocalization.string("Open in New Window"), action: onPopOut)
                .disabled(!canPopOut || tab.unavailable)
            Button(AppLocalization.string("Close Tab"), action: onClose)
        }
```

`ConduitMac/App/MacKeyboardShortcuts.swift`, `focusComposer`: change `selectTab(.sessions, defaults: defaults)` to

```swift
        // A session window has its own composer; the main pane stays as it is (D21).
        if !MacSessionWindows.isSessionWindow(window) { selectTab(.sessions, defaults: defaults) }
```

Add "Open in New Window" and "Open Session in New Window" to `Conduit/Localizable.xcstrings`.

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command, then the existing tab and command suites: `-only-testing:'ConduitMacTests/MacSessionTabsCommandsTests' -only-testing:'ConduitMacTests/MacSessionTabStripTests' -only-testing:'ConduitMacTests/MacSessionTabsStoreTests'`. Expected: `** TEST SUCCEEDED **`. `MacSessionTabStripTests.testAnExtraWideTrailingItemOverflowsButNothingFlickers` is a known random failure under load; if it alone fails, re-run that one test.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac ConduitMacTests Conduit/Localizable.xcstrings
git commit -m "feat(mac): open sessions in their own window from the tab menu and File menu (D21)"
```

---

### Task 6: Docs, smoke checklist, full verification

**Files:**
- Modify: `docs/macos/DECISIONS.md` (add `## D21: Mac session windows (2026-10-16)`)
- Modify: `docs/macos/SMOKE_CHECKLIST.md` (add a "Session windows" section)
- Modify: `docs/superpowers/specs/2026-10-15-mac-session-windows-design.md` (Status line: "Built (D21), 2026-10-16"; answer the 5 open questions with the v1 choices)

- [ ] **Step 1: Write D21**

Cover, in the DECISIONS.md style (plain paragraphs, facts with file:line): S1 result and its evidence lines (from this plan's "Facts that change the spec"); the hub instead of the tee; `openSessionLegacy` for hydrate and settle, and its cost (one full transcript download per turn per window; move to the history endpoint if long sessions feel slow); the reducer rules; the 600 ms settle debounce and why (tool turns); stale-idle probe after reconnect; scope and deletion behaviour; the cap; restore suppression through the registry; the `followsMainRoute` composer parameter; the Cmd-L change; first-answer-wins for a card shown in two places; v1 omissions (copy the Global Constraints line).

- [ ] **Step 2: Write the smoke checklist section**

```markdown
## Session windows (D21)
- [ ] Right-click a tab > Open in New Window: a window opens with that chat; the main window shows the neighbour tab.
- [ ] Option-Command-N with a chat active does the same; with a sheet open it does nothing.
- [ ] Send in the window while main streams another chat: both stream at once; neither shows the other's text.
- [ ] Stop in the window stops only that turn.
- [ ] An approval in the window: Allow works; the main window is unaffected.
- [ ] Turn Wi-Fi off and on: the window says "Not connected", then catches up; no Stop button left over.
- [ ] Switch profile in main: the window says "Belongs to <profile>" and its composer is disabled; switch back: it resumes.
- [ ] Delete the chat from the sidebar: the window says "This conversation was deleted." and Close works.
- [ ] Open 4 windows; a fifth: beep, nothing opens; the tab menu item is disabled.
- [ ] Cmd-W in the window closes the window, not a main tab. Cmd-L focuses the window's composer and leaves main on its pane.
- [ ] Quit with a window open and relaunch: no session window comes back.
```

- [ ] **Step 3: Full verification**

Run, in order, on this checkout only:
1. `python3 scripts/check-l10n-coverage.py`. Expected: no missing keys.
2. `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO` twice. Expected: `** TEST SUCCEEDED **` both times, or only the known random failures (`LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`, `MacSessionTabStripTests.testAnExtraWideTrailingItemOverflowsButNothingFlickers`), each passing when re-run alone. Report any other failure; do not mark the task done.
3. iOS build: `xcodebuild -project Conduit.xcodeproj -scheme Conduit -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd-ios build CODE_SIGNING_ALLOWED=NO`. Expected: `** BUILD SUCCEEDED **`. Then `rm -rf build/dd-ios`.
4. `git diff macos --stat -- Conduit Shared` lists only `Conduit/Localizable.xcstrings`. Any other file under `Conduit/` or `Shared/` is a plan violation.

- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "docs(mac): D21 session windows, smoke checklist, spec status"
```
