# Mac notch agent status: design

Date: 2026-10-15. Status: draft for review. Target: the macOS app only (`ConduitMac`). iOS is unchanged. Replaces the earlier "menu bar item" idea.

## Goal

Show what the Hermes agent is doing without keeping the Conduit window in front. A small surface at the top-center of the screen, hidden when idle, grows out of the MacBook notch when an agent is working or needs the user. It shows sessions mid-turn, tool approvals waiting, Kanban cards that need attention and (when cheap) the next cron run. Actions: approve or deny inline, click a row to open that session in the main window, New Chat. Macs without a notch and external displays get a small pill at top-center of the active screen.

Single user, several Macs. Nothing syncs between Macs.

## Prior art (researched 2026-10-15)

- NotchPal (github.com/simonveprek/NotchPal): hidden when nothing runs; compact (mark + verb + timer) while working; brief expand on turn start/end; sticky expand while a permission request is open; expand on hover; per-row dismiss; sessions forgotten after 30 min of silence. No-notch Macs: a panel floating under the menu bar (it appears to build on DynamicNotchKit).
- NotchCode (toolradar.com/tools/notchcode): compact until a session is live; one tap jumps to the terminal for a permission prompt (no inline approve); detects crashed sessions.
- Notchy (adamlyttleapps) is a terminal panel at the notch, not a status surface. Forks add a working/waiting/done pill; agentNotch approves tool prompts from the notch.
- Adopted: hidden when idle, sticky expand for approvals, hover to expand, done flash, stale-session timeout. Not adopted: a third-party notch package (DynamicNotchKit); the shared `MacFloatingPanel` is the base.

## What the app sees today (the background-session question)

Answer: NO, not in the state the notch needs. Findings, with sources:

1. `AppState.applyStreamEvent` drops every event whose session is not the active one (`eventBelongsToActiveSession`, AppState.swift ~23700). Turn state (`turnState`), the approval card and the clarify card exist for the open chat only.
2. Events do reach `AppState.handleStreamEvent` first, for every session bound to the socket (`HermesClient.onEvent` set in `makeClient`). Only three consumers look at non-active sessions: `voiceBackgroundJobSupervisor.observe`, session-title events, and compaction `status.update`. So the raw signal exists; nothing records it.
3. The only background view is `session.active_list` (`HermesClient.activeSessions(inProfile:)`, rows = `LiveSessionStatus`: runtime id, stored id, status `working|waiting|starting|idle`, `last_active`), held in `AppState.liveSessionStatusIndex` for the sidebar Working / Needs input chips. Two gaps: it is polled only by `SidebarView` every 4 s while the chat list is on screen, and `refreshLiveSessionStatuses()` returns early when `isSceneActive` is false. `handleScenePhase(.inactive/.background)` clears it, which is the normal state when Conduit is not frontmost. It carries status only: no tool name, no approval content.
4. Approval content for a background session is not stored anywhere. `HermesClient` has `approval.pending` (`pendingApprovals(sessionId:profile:)`, "every unresolved approval for one live Hermes session") and `approval.respond` (`respondToApproval(sessionId:requestId:choice:profile:)`). Neither is called for non-active sessions today.
5. Kanban: `KanbanStore` is a `@StateObject` inside `KanbanView` (KanbanViews.swift:348), configured and polled only while the Kanban pane is mounted. No app-wide board snapshot exists. `cronJobs` (with `nextRunAt`) is loaded by `loadCronJobs()` only when the Cron pane asks.

Minimum to get it (all existing API, nothing invented):
- A. Event tap: one gated line in `handleStreamEvent`, next to the Quick Ask tap (2026-10-15 Quick Ask spec adds the same kind of line; both ride one ledger row) so the feed sees every parsed `StreamEvent` (`messageStart/Delta/Complete/Error/Interrupted`, `toolStart/Complete`, `sessionBusy`, `approval`, `approvalWithdrawn`, `clarify`, `clarifyExpire`, `inputPrompt`, `inputPromptExpire`). Gives latency under 1 s, tool names and full approval content for sessions on this socket.
- B. Feed-owned poll of `client.activeSessions()` that ignores `isSceneActive`. Catches sessions the socket gets no events for and reconciles missed edges. Cadence 4 s while anything is live or the panel is visible, 15 s when idle.
- C. `approval.pending` per session that polls as `waiting` and has no tap-captured approval, to get inline-answerable content.
- D. A feed-owned `KanbanStore` (second instance, `configure(requester: dashboardTicketBridge, serverIdentity: baseURL)`), polled every 30 s; cron read from `cronJobs`.

Assumptions to verify (open questions 1 and 2): the Mac scene-phase path leaves the gateway socket up while Conduit is inactive or its window is closed (the delegate says closing the window keeps the socket running); and sessions started outside this socket (Hermes Desktop, CLI, cron runs) show only in `session.active_list`.

## Constraints

- Porting rules apply (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`, upstream edits `#if os(macOS)`, tagged `// MAC:`, one ledger row each. The only upstream edit is the event tap (A), shared with Quick Ask.
- Read-mostly: the feed never writes `liveSessionStatusIndex`, `turnState` or any AppState field. The one write path is approve/deny (below).
- Profile scope: the active profile only in v1 (`activeSessions()` without `inProfile`). A profile or dashboard switch resets the feed silently.

## Behaviour

States of the surface:
- **Hidden** (idle): no working turn, nothing needing the user, no recent done. The panel is ordered out (no hit area, no cost). Menu bar and Dock stay as today.
- **Compact** (active): a capsule that wraps the notch. On a notch Mac it is the notch height (`safeAreaInsets.top`), with a left wing and right wing in the unobscured menu bar areas. Left: Conduit mark that pulses while working, amber dot when something waits. Right: count and the current activity ("Running terminal", tool name from `toolStart`), or an elapsed timer. Without a notch: a 28 pt pill, 160 to 260 pt wide, centered, just below the menu bar of the active screen.
- **Expanded**: the rows list, anchored to the top and growing downward. Triggers: hover (200 ms in, 400 ms out); a new approval, clarify or input prompt (sticky until resolved or the user moves the pointer away after interacting); turn finished (flash 4 s, then settles). Esc or click outside collapses a pinned panel.
- **Done flash**: finished sessions show a check for 4 s, stay as rows for 30 s (max 3), then drop. A failed turn shows red with the error text, same lifetime.

Rows, in order: **Needs you** (approvals, clarify, input prompts, Kanban blocked or review), **Working**, **Done**. Max 6 rows, then "+N more" (opens the main window). Footer: next cron run ("Nightly report in 12 min", only if `cronJobs` is already loaded, else one `loadCronJobs()` on first expand, at most every 5 min), New Chat, Open Conduit.

Actions:
- **Approve / Deny** (approval rows): buttons "Allow once" and "Deny"; "Allow for session" and "Always allow" in a menu, only when `choices` (or the default set, as `ChatView.allows`) permits and `smartDenied` is false. Sends `approval.respond` with the row's `requestId`. Success (`resolved > 0`) removes the row; `resolved == 0` means answered elsewhere. The command text shows monospaced, 2 lines, truncated at 160 chars, never logged.
- **Clarify, sudo, secret, vault prompts**: never inline (free text or secrets). The row says "Answer in Conduit" and click opens the session.
- **Click a row**: activate Conduit, show the main window, `requestOpenSession(id)` (also returns the pane to chat via `.macSessionOpenRequested`). Kanban rows switch the sidebar tab to Kanban (task deep link: open question 5). Cron row opens the Cron pane.
- **New Chat**: activate, show window, `createNewSession()`, honoring `MacNewChatAvailability`.
- **Dismiss**: hover x on done and failed rows only. Working and waiting rows cannot be dismissed (they reflect the gateway).

Accidental-click guard: after an auto-expand for attention, approval buttons are disabled for 600 ms; no default-key binding; "Always allow" is menu-only.

Position and drag (added after review): the surface is draggable and can sit at any point along any screen edge (top, bottom, left, right) of any display. The default is the notch: wings around it on a notch display, the top-center pill elsewhere. A press that moves under 4 pt is a click; past that the surface follows the pointer and, on release, snaps to the nearest edge of the screen under the pointer, keeping the dropped position along that edge. Nothing expands, collapses, announces or moves mid-drag, and a drag never triggers a row, a button or the click-outside collapse; an attention request that arrives mid-drag expands the panel when the drag ends. The position is remembered per display (display ID, UserDefaults), restored on launch and when displays change, and ignored when that display is gone (the default placement is used again; the saved spot returns with the display). Top and bottom edges: a horizontal capsule that opens vertically inward (down from the top, up from the bottom), rows stacked. Left and right edges: a vertical capsule that opens horizontally inward, rows stacked. The wings shape is the default notch placement only; every docked placement uses the pill style. Go > Reset Agent Status Position, or a double-click on the capsule or the grip, returns to the notch. Built on the shared panel's `isDraggable`, `onPlacementChanged` and `.edgeDocked` placement; persistence and the per-edge layout belong to the notch.

Where it appears: `NSScreen.main` (screen of the key window or focus). If that screen has a notch (`safeAreaInsets.top > 0` with both auxiliary areas non-empty), anchor to the notch; otherwise (external, mirrored, clamshell) the pill at top-center of that screen's `visibleFrame`. Re-evaluated when attention arrives and on `NSApplication.didChangeScreenParameters`.

Menu bar icon: not built in v1. The pill already covers Macs without a notch and external displays, Dock plus Cmd-N cover New Chat, and a second surface doubles the state to keep in sync. Revisit only if the surface is Off by default or hidden in full screen (smoke item). Setting "Notch status" in Mac Settings: Active agents (default) / Only when I'm needed / Off.

Accessibility: the panel is one accessibility group ("Agent status: 2 working, 1 needs approval") with each row and button reachable by VoiceOver; attention posts an `NSAccessibility` announcement. Hover is never the only way in: Go menu "Show Agent Status" (pins the panel open, toggles). Reduce Motion: fade only, no spring. Text and fills use the D7/D11 contrast rules (4.5:1 light and dark).

## AgentActivityFeed API (shared with the Notifications spec)

Mac-only, `@MainActor`, no AppKit imports in the model. This spec owns the type; the Notifications spec's "Events consumed" list is the requirement and is mapped below.

```swift
struct AgentActivityItem: Identifiable, Equatable {
    enum Kind { case turn, approval, clarify, inputPrompt, kanban, cron }
    enum State { case working, needsUser, finished(Outcome), blocked }   // blocked = kanban
    enum Outcome: Equatable { case completed, failed(String), interrupted }
    let id: String            // "turn:<durable|runtime id>", "approval:<queueId>", "clarify:<reqId>",
                              // "kanban:<board>/<task>", "cron:<jobId>"
    var kind: Kind
    var state: State
    var sessionId: String?    // runtime id as seen; open via requestOpenSession
    var sessionKey: String?   // durable id (stored/lineage root), plus alternateIds for matching
    var profile: String; var dashboardID: String
    var title: String         // session title (catalog join) or card/job name
    var detail: String?       // tool name, command, question, status
    var since: Date
    var approval: ApprovalActivity?   // .approval: requestId, command, description, choices, allowPermanent
    var isActiveSession: Bool
}

struct AgentActivityEvent: Equatable {
    let eventId: UInt64       // monotonic per feed instance, for consumer dedupe
    let at: Date
    enum Payload: Equatable {
        case turnStarted(AgentActivityItem)
        case turnFinished(AgentActivityItem, outcome: AgentActivityItem.Outcome, replyPreview: String?, observedGap: Bool)
        case decisionRequested(AgentActivityItem)          // approval, clarify (first question + open count), inputPrompt, kanban blocked/review
        case decisionResolved(id: String, reason: Reason)  // .answered .expired .withdrawn .sessionClosed
        case titleChanged(sessionKey: String, title: String)
    }
    let payload: Payload
}

@MainActor final class AgentActivityFeed: ObservableObject {
    static weak var shared: AgentActivityFeed?                    // target of the AppState tap line
    @Published private(set) var items: [AgentActivityItem]        // sorted: needsUser, working, finished
    @Published private(set) var availability: Availability        // .live, .eventsOnly, .offline
    let events: AnyPublisher<AgentActivityEvent, Never>           // main actor
    func snapshot() -> [AgentActivityItem]                        // pending decisions + running turns now
    func start(); func stop()                                     // idempotent
    func observe(_ event: StreamEvent)                            // called by the AppState tap
    func respond(to id: String, choice: String) async -> RespondResult   // .resolved, .alreadyResolved, .failed(String)
    func dismiss(_ id: String)                                    // finished items only
}
```

Mapping to the Notifications requirements: `turnStarted`, `turnFinished` (`replyPreview` = `messageComplete` content, trimmed to 200 chars), `approvalRequested` = `decisionRequested` with `item.approval`, `questionRequested` = `decisionRequested` with `kind == .clarify`, `decisionResolved` (answered here or elsewhere, `approvalWithdrawn`, `clarifyExpire`, `inputPromptExpire`), `sessionTitleChanged` = `titleChanged` (from `.sessionTitle`).

Contract for consumers:
- `items` is updated before the matching event is sent, so a handler can read the new state. Events are ordered per session and at-least-once across a feed restart; `eventId` is the dedupe key. Published whether or not the notch UI is shown (the feed runs even when the setting is Off).
- `snapshot()` / initial `items` give a Mac launched mid-turn or reconnecting its pending decisions and running turns. For a snapshot turn `since` is the observation time. The first reconcile after start, reconnect, profile or dashboard switch is a silent baseline: no `turnStarted` or `decisionRequested` for what is already there.
- Outcome comes from the terminal event when seen (`messageComplete` completed, `messageError` failed, `messageInterrupted` / `sessionInterrupted` interrupted). A row that only leaves `active_list` is `.completed`, and must be absent in 2 consecutive polls first, so one flaky poll does not fire "done". A turn that vanished across a reconnect gap finishes with `observedGap: true` so Notifications can suppress it.
- The feed does not know whether the user is looking at the session. Suppression ("Conduit frontmost on that chat") belongs to the consumer; `isActiveSession` is provided for it.
- Never emitted on disconnect: `availability` goes `.offline` and items clear after a 15 s grace, with no `turnFinished`.

## Architecture

New files (Mac target, XcodeGen picks up `ConduitMac/`):

- `ConduitMac/Activity/AgentActivityModels.swift`: items, events, availability.
- `ConduitMac/Activity/AgentActivityReducer.swift`: pure value type. `reduce(state, input) -> (state, [events])` for inputs: `activeList([LiveSessionStatus], at:)`, `stream(StreamEvent)`, `pendingApprovals(sessionId, [ApprovalActivity])`, `kanban([KanbanTask])`, `cron([CronJob])`, `catalog([SessionSummary])`, `activeSession(id, turnState, stale)`, `tick(now)`. Session identity matching reuses the rule in `SessionLiveStatusIndex.status(for:)` (id, `storedSessionId`, `lineageRootId`, `alternateIds`). All of the behavior above is tested here.
- `ConduitMac/Activity/AgentActivitySources.swift`: protocol `AgentActivitySources` (activeList, pendingApprovals, respondApproval, kanbanSnapshot, cron, clock) with the production implementation over `HermesClient` and `KanbanStore`, and fakes in tests. Owns the poll tasks and cadences. Calls `client.activeSessions()` directly (not `refreshLiveSessionStatuses`), guarded by `isConnected` only.
- `ConduitMac/Activity/AgentActivityFeed.swift`: the observable shell over reducer + sources; sets `AgentActivityFeed.shared` (the target of the AppState tap); forwards `respond` to `AppState.respondToApproval(messageId:choice:)` when the approval is the active session's pending card (keeps its card state coherent), else to `HermesClient.respondToApproval`. The gateway then sends `request.cancel` (`resolved`), which AppState turns into `.approvalWithdrawn` for any open card.
- `ConduitMac/Notch/NotchGeometry.swift`: pure. Input: screen frame, `safeAreaInsets`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`, visibleFrame. Output: `Placement.notch(rect, notchWidth, notchHeight)` or `.pill(anchor)`.
- `ConduitMac/Notch/NotchStatusModel.swift`: pure state machine hidden / compact / expanded(pinned: Bool) with timers injected (hover delays, flash 4 s, 600 ms guard).
- `ConduitMac/Notch/NotchStatusController.swift`: owns the `MacFloatingPanel`, picks the screen, applies placement, observes the feed and settings, handles actions.
- `ConduitMac/Notch/NotchStatusView.swift`, `NotchStatusRow.swift`, `NotchStatusSettings.swift` (`UserDefaults` key `conduit.mac.notchStatus.mode`).
- Edits to Mac files (no ledger): `ConduitMacApp` creates feed and controller from `AppStateRuntimeRegistry.shared.appState`; `ConduitCommands` adds "Show Agent Status"; Mac Settings gets the picker.
- Upstream edit (ledger, R4): `AppState`: in the same `#if os(macOS) // MAC:` block as `MacQuickAskStreamTap.shared.observe(event)` (next to `voiceBackgroundJobSupervisor.observe(event)`) add `AgentActivityFeed.shared?.observe(event)`. No stored property is added to AppState; one shared ledger row.

Notch geometry (verified in the macOS SDK header, `NSScreen.h`, all `API_AVAILABLE(macos(12.0))`):
- `safeAreaInsets` is "the obscured distance from each edge"; on a notched display `top` is the notch height (0 otherwise).
- `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are the unobscured rects at the top outside the insets; empty when there is no extra unobscured area.
- `hasNotch = top > 0 && !left.isEmpty && !right.isEmpty`; `notchWidth = frame.width - left.width - right.width`; the notch spans `left.maxX ..< right.minX`; panel top = `frame.maxY`.
- macOS 14 minimum means these are always available; no `#available` check.

### What this needs from `MacFloatingPanel` (Quick Ask spec owns it)

Config: `canBecomeKey: false`, `dismissOnResignKey: false`, `dismissOnEscape: false` (the controller handles Esc itself), `level: .statusBar`, `joinsAllSpaces: true`. Its non-activating style means Approve clicks do not take focus from the frontmost app. Placement: `.notchAnchored` as specified (top flush, x centered) for the expanded panel on a notch screen; the compact wings and the no-notch pill use `.custom` with a closure that reads `NotchGeometry` for the chosen screen (this spec picks `NSScreen.main`, not the mouse screen, see open question 4). `show()`, `hide()`, `updateContentHeight(_:)` cover the rest.

Gaps to confirm or add in `MacFloatingPanel`:
- `constrainFrameRect(_:to:)` returns the rect unchanged, so the panel can overlap the menu bar band (AppKit otherwise pushes it below).
- Width as well as height driven by content (compact capsule vs expanded list), top edge fixed, animated; `updateContentHeight` alone is not enough.
- Mouse-entered / exited callbacks (tracking area on the content view) and a hit-test shape equal to the visible shape, so the empty corners of the rectangle do not swallow clicks.
- Re-position on `NSApplication.didChangeScreenParameters` and when `.custom` input changes; `show()` must never activate the app (`orderFrontRegardless`, as specced); `hide()` is `orderOut` so Hidden leaves no hit area.
- Optional shadow off for the notch variant; full-screen and Space behavior verified on hardware.

## Data flow

1. `AgentActivityFeed.start()` (app launch, and on connect). Tap installed; polls start.
2. Stream events -> `AgentActivityFeed.observe` (AppState tap) -> reducer. `messageStart/Delta/toolStart` raise a turn row now; `approval` raises an approval row with full content; `approvalWithdrawn`, `clarifyExpire`, `inputPromptExpire` clear them.
3. Poll results -> reducer. A `waiting` row without captured approval content triggers one `approval.pending` for that session; failure keeps the row as "Needs approval, open in Conduit" with no buttons.
4. Kanban snapshot (30 s): tasks with status `blocked` or `review` raise `kanban` items when they enter the set; leaving it clears them. `running` count is shown as a number only.
5. `items` -> `NotchStatusModel` -> panel state. User action -> controller -> `feed.respond` / `requestOpenSession` / `createNewSession`.
6. Consumers (Notifications) subscribe to `events`.

## Error handling

- `session.active_list` unsupported (`isMethodUnavailable`): `availability = .eventsOnly`; the tap still serves sessions on this socket. No retry loop against that client; a new connection probes again (same rule as AppState).
- Disconnected or `isConnected` false: `.offline`, rows clear after 15 s, panel hides, no events.
- Approve fails (RPC error): row shows "Couldn't send. Open in Conduit", buttons re-enable, mirrors the card's `.error` state. `resolved == 0`: row removed, `attentionCleared(.answeredElsewhere)`.
- Stale rows: a turn row with no event for 10 min and absent from `active_list` is dropped silently; approval rows end on `request.cancel` or the gateway's block timeout (about 5 min per the 2026-08-13 spec).
- Kanban or cron fetch failure: keep the last snapshot, drop it after 3 consecutive failures, never show an error in the panel.
- Profile, dashboard or server switch: reset, new baseline, no events.
- Screen change during Expanded: re-anchor and keep state; if the target screen vanished, fall to the new `NSScreen.main`.

## Testing

- Reducer: tap-only session appears and clears; poll-only session (no events) appears; both merge to one row; `waiting` raises attention once; approval withdrawn clears with `.answeredElsewhere` vs `.answeredHere`; 2-miss rule before `finished`; terminal event finishes immediately with the right outcome; baseline is silent; gap emits `observedGap`; profile switch resets; id aliasing (stored, runtime, lineage, alternate) yields one row; Kanban enter/leave; stale expiry; sort order.
- Sources: cadence switch idle vs live (injected clock); poll runs with `isSceneActive == false`; method-unavailable stops polling; pending-approvals failure degrades to no-buttons row.
- Geometry: table of real values (14" and 16" notch rects, no-notch, external, mirrored, empty aux areas) -> notch or pill; menu bar band overlap math.
- State machine: hover delays, flash timing, sticky attention, 600 ms guard, Esc collapse, Off and Only-when-needed modes.
- Controller (hosted, panel faked): screen choice; New Chat honors `MacNewChatAvailability`; approve routes to `AppState.respondToApproval` for the active session and to `HermesClient` otherwise.
- View: rows render light and dark, accessibility labels and group summary, Reduce Motion path.
- Hardware smoke (SMOKE_CHECKLIST): notch Mac, external display, full-screen app, two Spaces, lid closed with external, background session approval answered from the notch, answered from the main window, answered from Hermes Desktop.
- Full Mac suite twice; iOS simulator build; `git diff -- Conduit Shared` removes zero lines outside gates.

## Out of scope (v1)

Menu bar icon, other profiles' sessions, group-chat rooms, token and cost meters, answering clarify or secret prompts inline, per-row Kanban task actions, sound, a Windows or iPad variant.

## Effort

About 10 working days, excluding `MacFloatingPanel` (Quick Ask spec): reducer and models 2.5, sources and AppState tap 1.5, geometry, state machine and controller 2, views 2, settings, command and accessibility 1, hardware smoke and test hardening 1.

## Open questions

1. Does the Mac scene-phase path keep the gateway socket alive while Conduit is inactive or its window is closed? `handleScenePhase(.inactive/.background)` marks turn state stale and suppresses reconnects (written for iOS). If it tears the socket down, v1 needs a gated Mac exemption (a second gated AppState edit and ledger row). Verify first; it decides whether the notch works with the window closed.
2. Does the gateway deliver events and answer `approval.pending` / `approval.respond` for sessions not attached to this socket (started in Hermes Desktop, CLI, cron)? Verify against `tui_gateway`. If not, those sessions show working and waiting only, with "Open in Conduit" instead of buttons.
3. Default on or opt-in? Proposal: on in "Active agents" mode, since it is invisible when idle.
4. Screen choice: `NSScreen.main` (follows focus) as proposed, or always the built-in display when it has a notch?
5. Kanban rows: v1 opens the Kanban pane only. A task deep link (select the card) does not exist in `KanbanView`; add it here or later?

## Docs

New D16 in docs/macos/DECISIONS.md (notch surface, no menu bar icon, feed contract; D15 is Quick Ask); the `handleStreamEvent` tap shares Quick Ask's ledger row; SMOKE_CHECKLIST gets a "Notch status" section.
