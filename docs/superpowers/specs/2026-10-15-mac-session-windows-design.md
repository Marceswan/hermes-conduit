# Mac session windows: design

Date: 2026-10-15. Status: draft for review (nothing built; no product code written). Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

Pop a chat session out into its own window, so two conversations can sit side by side. Each window streams its own session, has its own composer, and keeps going when the main window switches to another session. Entry points: a tab context menu item, a File menu command with a shortcut, and a sidebar row context menu item.

Single user, several Macs. No sync of windows between Macs.

## What the code says (the hard part)

Facts checked in the tree, branch `macos`, 2026-10-15.

Wire level (HermesClient, `Conduit/Services/HermesClient.swift`, 4,207 lines, `@MainActor`):
- Every session RPC takes an explicit `session_id`: `sendPrompt` (:1907), `steer` (:1953), `cancel` (:1971), `respondToApproval` (:2118), `respondToClarification` (:2008), `respondToInputPrompt` (:2113), `attachImage`/`attachFile` (:2365/:2378). `openSession(_:profile:)` (:1612, `session.resume`) returns a `SessionResumeResult` (runtime id, messages, snapshot).
- Every `StreamEvent` (:256) carries its `sessionId`. `activeSessions()` (:1941, `session.active_list`) lists the gateway's live runtimes, so the gateway holds several at once.
- So the protocol is addressed per session. The client is not: it has ONE `onEvent` callback (:750), and `AppState.makeClient` (:9505) installs it. `AppState.eventBelongsToActiveSession` (:23687) then drops every event that is not for `activeSessionId`. A background session is re-read with `session.resume` when you return to it (tabs spec, Constraints).
- NOT established by client code: whether the gateway keeps delivering events for session X to this socket after the same socket resumes session Y. The client only filters; it never proves the server fans out. Gating spike S1 below.
- `HermesClient.profile` + `scopeParams` (:1384) scope every RPC to one profile, and AppState builds a fresh client per reconnect (comment at :713-716), so runtime attachments are rebuilt on every reconnect.

App level (`Conduit/Services/AppState.swift`, 27,072 lines, one `ObservableObject`, `AppStateRuntimeRegistry.shared` hands out the single instance):
- One `activeSessionId` (:715, 140 mentions), one `messages` (:728, 308 mentions of `messages`), one `turnState` (:824, 127 mentions, 23 `setRunning` edges), one `reconciliation` buffer (`bufferIfReconciling`), one chat viewport transition machine (`ChatViewportTransition` :3124, `beginExplicitChatViewportTransition` :6433), one composer prefill/quote/focus set (:1468-1480), one `composerDraftStore`, and the send path (`submitComposer` :17375, `sendMessage` :18206, interrupt/steer/ambiguous-delivery recovery, thousands of lines around them).
- The chat views are bound to it: `ChatView.swift` (3,336 lines) has 99 `appState.` references; `ComposerBar` reads `appState.activeSessionId`, `composerDraftStore`, `slashCommands`, pending screenshot, mention candidates. 27 view files take `@EnvironmentObject AppState`. `MessageBubble` (ChatView.swift:741) only needs `appState.profileDisplayName` and `activeProfile`, so the bubble layer is reusable with the shared AppState in the environment.
- A second main-style window today would show the SAME AppState (a mirror), not a second session. The Mac WindowGroup is `conduit-primary` (ConduitMacApp.swift:53); Cmd-N is New Chat, not New Window (ConduitCommands.swift:22).

Conclusion: two live sessions need either per-window session state that does not exist, or a second consumer of the events that does not touch AppState's single-session state.

## Constraints

- Porting rules (docs/macos/PORTING_LEDGER.md, D11): Mac code under `ConduitMac/`, upstream edits gated `#if os(macOS)` and tagged `// MAC:`, one ledger row each. D11 set the precedent of no edits to `AppState.swift`; upstream merges regularly and AppState is its busiest file.
- Window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing = false`, D11), so a pop-out is always a real separate window and can never merge into the main window as a native tab. In-app tabs (ConduitMac/Tabs/*) stay main-window only.
- Cmd-W closes a tab only in windows whose identifier has the `conduit-primary` prefix (MacKeyboardShortcuts.swift:267); any other window closes normally. The new scene id must not use that prefix.
- Rooms (`activeRoomSurface`) and Bots/Cron/Kanban are not poppable in v1.

## Options

### A) Extract per-window session state from AppState (`ChatSessionController`)

Move `activeSessionId`, `messages`, `turnState`, reconciliation, composer draft/prefill, viewport machinery and the send path into a controller; AppState owns a dictionary of them; ChatView and ComposerBar take a controller instead of reading AppState.
- Scope: AppState (large regions of the 27k lines), ChatView, ComposerBar, ComposerFullEditor, GroupChatView overlap, RootView, SidebarView/SessionList selection logic, about 27 view files, plus the 73 ConduitTests files that mention `AppState` (e.g. ConduitTests/SettledMessageIsolationTests.swift).
- Upside: full fidelity; every feature (slash, mentions, attachments, steer, ambiguous-delivery recovery, resume restoration) works per window; iOS iPad could reuse it.
- Downside: every one of those edits is in a shared file that upstream also edits. Each `git merge upstream/main` becomes a manual re-port of the chat core, with silent-regression risk (turn-state races are the app's most fragile area; see the stale-idle comments at :827-870). Violates the D11 precedent and cannot be gated with `#if os(macOS)` because iOS runs the same code.
- Effort: 25 to 40 working days including stabilisation. Not recommended.

### B) Secondary window, lighter

Two readings, only one works.
- B1 (literal): the window shows a live transcript, its composer calls the main AppState, so sending switches the main window to that session. Cheap (about 3 days) but it fails the goal: it cannot show two chats at once, because AppState holds one session and drops the other's events. Rejected.
- B2 (recommended, below): the window owns a small Mac-only controller that talks to the shared `HermesClient` directly, so main and pop-out run independently. Fidelity is lower than A; AppState is untouched.

### C) One AppState per window, sharing the HermesClient

- Sharing the client does not work as is: `AppState.client` is created and torn down by AppState (`makeClient`, reconnect, profile switch), so a second AppState cannot borrow it; `onEvent` is single-valued. A second AppState with its OWN client works mechanically (tests already call `AppState()`), but:
  - `AppState.init` runs the cold-launch bootstrap and saved-connection restore; a second instance repeats connect, catalog refresh, `session.active_list` polling, widget snapshot publishing, push registration and Siri hooks. It also touches process-wide singletons: `PushNotificationService.shared`, `CarPlayVoiceCoordinator.shared`, `CustomHeaderStore.shared`, `SessionPresentationCache.shared`, `PendingVoiceIntentStore.shared`, `AppStateRuntimeRegistry.shared`. Persisted per-dashboard stores (resume store, yolo store, composer drafts, tab model) would have two writers; last write wins.
  - A second attached socket is a second client for the gateway's approval accounting (HermesClient.swift:1052-1060, :1159): approvals and clarifications for one session could be presented in two windows and race.
  - Fixing the above needs a "secondary instance" mode threaded through a 27k-line file: the same shared-file edits as A, spread thinner.
- Effort: 8 to 12 days for something that works, with open-ended cleanup. Not recommended.

## Recommendation: B2, a Mac-only session window with its own light controller

Trade-offs, stated plainly:
- Gets: two live chats at once, independent streaming, composer and scroll per window, main switching sessions does not affect the window. Zero edits to `AppState.swift`, `ChatView.swift` or `ComposerBar.swift`; at most one new upstream gate (none expected).
- Costs: the window is a second implementation of transcript assembly and send. v1 omits slash commands, @mentions, voice, screenshot carry, steer/queue while busy, read-aloud, branch, quote, resume viewport restoration, group rooms. A message sent from the window while the gateway is mid-turn is not accepted (composer shows Stop instead). Drift risk against AppState's streaming reducer is real and is managed by settling from persisted history (see Architecture).
- Gate: spike S1 must show the gateway delivers events for two resumed sessions on one socket. If it does not, fall back to a second `HermesClient` owned by the window (own socket, same connection and profile; `HermesClient.init` takes a `HermesConnection`), which the controller design below supports unchanged. Cost: one extra socket per open window and the approval-race caveat from C, mitigated by the window answering only requests for its own session.

## Behaviour

- Open. Tab context menu "Open in New Window"; File > "Open Session in New Window" (Opt-Cmd-N, free in the D10 table; verify against MacKeyboardMenuTests); sidebar row context menu "Open in New Window". The menu command acts on the main window's active session. Opening a session that already has a window focuses that window (WindowGroup(for:) with an equal value activates the existing window; verify on macOS 14).
- Main window on pop-out. The session's tab leaves the strip as if closed, with no entry on the closed stack; the main window activates the neighbour (right, else left), and popping out the last tab starts a new chat (tabs spec Close rules). Popping out an inactive tab changes nothing else.
- Close. Closing the window cancels its event subscription and drops its state. The tab is not re-added; the session is one click away in the sidebar. Running turns keep running on the gateway.
- Same session in both. Allowed in v1 (user opens it from the sidebar while a window has it): both views converge from gateway events and settle from history. No ownership rules.
- Window content: title bar shows the session title (live, from the catalog); transcript with follow-bottom scrolling; a Stop button while a turn runs; composer at the bottom (text, Return sends per D9, Shift-Return newline, paste via `ComposerPasteTextView`); inline approval, clarify and sudo/secret cards that call `respondToApproval`, `respondToClarification`, `respondToInputPrompt` for this window's session; connection banner when disconnected or when the window's profile differs from the connected profile.
- Reconnect. A new `HermesClient` (after reconnect) triggers a fresh `openSession` for the window's session, then settling.
- Profile/dashboard scope. The window token carries dashboard id, profile and session id. If main switches to another dashboard or profile, the window shows "Belongs to <profile>" and does not send or resume until the scope matches again; it never uses a client whose `profile` differs from its token.
- Relaunch. Windows are not restored in v1 (the tab strip and sidebar are the way back).
- Deleted session. If `deleteSession` removes it (detected like tabs: `MacSessionDeletionDetector`), the window shows a "Conversation deleted" state and closes on dismiss.

## Interaction with the Mac tab strip

- `MacSessionTabsModel` gains `detach(id)`: remove the tab, pick the neighbour, no closed-stack push, same last-tab rule as `close`. `MacSessionTabsStore` exposes `popOut(tabID:)` which calls it then asks the window opener. Pure model tests cover it.
- `MacSessionTabStrip` context menu (ConduitMac/Tabs/MacSessionTabStrip.swift:126) adds the item. Mac-only file, no ledger row.
- Popped-out ids are not tabs, but a sidebar open of that session adds a tab in main as today (duplicate view allowed, above).
- `macSessionOpenRequested` (R4 notification) is not changed.

## Architecture (recommendation)

New folder `ConduitMac/Windows/` (all Mac-only, no gates):
- `MacSessionWindowToken` (Codable, Hashable): `dashboardID`, `profile`, `sessionID`. The `WindowGroup(for:)` value.
- `MacClientEventTee` (MainActor): observes `appState.$client`; for each new client, once per `ObjectIdentifier`, wraps `client.onEvent` (internal var, readable) as `{ ev in original?(ev); subscribers.forEach { $0(ev) } }`. AppState behaviour is unchanged because `original` runs first and unmodified. Re-wrap on every client change; unsubscribe on window close. Installed from `ConduitMacApp.rootContent` next to the existing `MacSessionTabsStore.shared.bind(to:)` call.
- `MacSessionWindowController` (ObservableObject, MainActor, one per window): state `messages: [ChatMessage]`, `streaming`, `turn` (idle/running/needsInput), `runtimeSessionID`, `phase` (connecting/ready/disconnected/wrongScope/deleted). Methods: `attach(client:)` (calls `client.openSession`, buffers tee events during the call, then replays those matching the session), `send(text:)` (`client.sendPrompt`; before sending after a reconnect, probes `client.activeSessions()` to clear a possibly stale idle state, the same hazard AppState documents at :827), `stop()` (`client.cancel`), `respond...`. Event filter matches `SessionSummary.id` and `alternateIds` (session identity rules, spec 2026-09-06), never raw string equality alone.
- `MacSessionTranscriptReducer` (pure value type, no AppKit, no AppState): folds `messageStart/Delta/reasoningDelta/Complete/Error/Interrupted`, `toolStart/Complete`, `sessionBusy`, `contextUpdate`, `statusUpdate` into `[ChatMessage]`. On `messageComplete` and on `sessionBusy(false)` the controller re-runs `openSession` (compact resume) to replace the transcript with the persisted rows, so reducer drift cannot accumulate beyond one turn.
- `MacSessionWindowView`: `ScrollViewReader` + `LazyVStack` of the existing `MessageBubble`/`StreamingBubble` (needs `.environmentObject(appState)` for profile names only), `MacSessionWindowComposer` (new; wraps `ComposerPasteTextView` from ConduitMac/Chat), approval/clarify cards reusing the existing card views if they take plain values (verify; else minimal Mac cards).
- `ConduitMacApp`: add `WindowGroup("Conduit Chat", id: "conduit-session", for: MacSessionWindowToken.self)` sharing `rootContent`'s environment (locale, tint, appearance) via a small shared modifier; default size 640 x 760; window identifier must not start with `conduit-primary`.
- `ConduitCommands`: File item + `openWindow(value:)`; action no-ops while a sheet is attached (D10 guard) and when no session is active.
- Sidebar context menu: `SessionActionMenuItems` is shared upstream; use the Mac tab strip menu only in v1, and add the sidebar item in a follow-up if a gate is acceptable (own ledger row).
- Docs: D15 in DECISIONS.md, SMOKE_CHECKLIST window section, ledger row only if the sidebar item is added.

## Risks

1. Server fan-out (S1). If the gateway sends events only for the most recently resumed session on a socket, one shared client cannot serve two windows. Mitigation: own-client fallback in the same controller (above); cost and approval caveat noted.
2. Reducer parity. The window's streaming assembly can differ from AppState's (tool card ordering, reasoning, interrupted-turn notices, steer rows). Mitigation: settle from persisted history after every turn; share fixtures with AppState streaming tests where the inputs are plain `StreamEvent`s.
3. `onEvent` wrapping. Wrapping a property AppState owns is order-sensitive: a wrapper installed late misses early events; a second wrap after AppState reassigns `onEvent` is lost. Mitigation: wrap on every `$client` change, assert in a test that `makeClient`-style reassignment keeps both consumers; replay-from-resume covers the gap.
4. Approval accounting. With a shared client there is one attached client, so a card shown in both main and a window for the same session answers the same server request twice (second answer errors harmlessly); verify the error path. With the own-client fallback, double presentation is real.
5. Memory and CPU. Each window holds a full transcript and re-renders on every delta. Cap open windows at 4 in v1 (menu item disabled message, not a crash).
6. Upstream drift. `StreamEvent` or `ChatMessage` gaining cases breaks the exhaustive reducer at compile time (good); behavioural changes in AppState's reducer do not (documented, settle-from-history masks them).
7. Input routing. Cmd-W, Cmd-L (focus composer), Cmd-F and the D10 guards are keyed to the primary window; the new window needs its own focus routing for Cmd-L and Return (D9) and must not post `macFocusComposerRequested` into main.

## Testing

- Pure: `MacSessionWindowToken` coding round trip; `MacSessionTabsModel.detach` (neighbour pick, last tab starts new chat, no closed-stack entry, inactive tab leaves active unchanged); `MacSessionTranscriptReducer` over recorded event sequences (plain turn, tool turn, interrupted, error, busy edges, alias ids).
- Controller with a fake `HermesWebSocketTransport` (the existing injection point, :806): attach hydrates via resume; events buffered during resume are replayed; reconnect triggers a fresh resume; send calls `sendPrompt` once with the right `session_id`; stale-idle probe runs after reconnect; wrong profile blocks send.
- Tee: AppState still receives every event after wrapping; two subscribers both receive; re-wrap after a client swap; unsubscribe on close.
- Two controllers on one fake client: events for session A never appear in B (alias-aware).
- Commands: menu mapping, sheet guard, no-op without a session, Cmd-W closes a session window but not the tab (identifier prefix).
- Hosted view: window renders light and dark, composer Return/Shift-Return, accessibility labels.
- Live (manual, SMOKE_CHECKLIST): two sessions streaming side by side against a real gateway; main switches sessions mid-stream; reconnect; profile switch.
- Full Mac suite twice; iOS simulator build; `git diff -- Conduit Shared` removes zero lines outside gates (expected: no diff at all).

## Open questions (max 5)

1. S1: does the gateway deliver events for two resumed sessions on one WebSocket? Needs a read of upstream `tui_gateway/server.py` and a live two-session test. Gates the shared-client design.
2. Is the v1 fidelity cut acceptable (no slash, mentions, voice, attachments beyond paste, no send while busy)? Attachments via `attachFile`/`attachImage` could be added for about 1.5 days.
3. Same session in main and a window: allow (v1 as written) or focus the window instead of opening it in main?
4. Should closing a window re-add its tab to the strip, and should windows be restored at relaunch?
5. Is a sidebar-row "Open in New Window" worth a gated edit to the shared `SessionActionMenuItems` (one ledger row)?

## Effort

| Item | Days |
|---|---|
| S1 spike (server read + live two-session probe) | 0.5 |
| Tee, token, controller, reducer | 3 |
| Window view, composer, approval cards | 3 |
| Tabs model/store/strip + menu + scene wiring | 1 |
| Tests (pure, controller, tee, hosted) | 2 |
| Docs, smoke checklist, live verification | 1 |
| Total (recommended B2) | 10.5 |

For comparison: A 25 to 40, B1 about 3 (does not meet the goal), C 8 to 12 plus open-ended cleanup.
