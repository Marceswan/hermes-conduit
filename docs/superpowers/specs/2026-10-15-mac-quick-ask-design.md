# Mac Quick Ask: design

Date: 2026-10-15. Status: draft for review (not yet approved). Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

Ask Hermes one thing from any app without switching to Conduit. A global hotkey (Option-Shift-Space) opens a floating, Spotlight-style panel; the user types, the reply streams into the panel, Esc dismisses, and one key promotes the exchange to a full chat in the main window.

This spec also defines `MacFloatingPanel`, the shared floating-panel base. The Notch status spec reuses it; its API is in "MacFloatingPanel" below and is owned here.

## Constraints

- One chat is active at a time (`AppState.activeSessionId`; one `messages` array, one `turnState`). Quick Ask must not disturb the chat open in the main window.
- Porting rules (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`; upstream edits gated `#if os(macOS)`, tagged `// MAC:`, one ledger row each. This spec needs exactly one upstream line (see "Stream tap").
- ConduitMac is Developer ID, hardened runtime, NOT sandboxed (`ConduitMac/Resources/ConduitMac.entitlements` holds only audio-input and camera). Sandbox-only restrictions do not apply; do not add the sandbox.
- Work tree note: `Conduit/Services/AppState.swift` has uncommitted user edits. This spec is design only; the implementation branch must land the one-line gate after those edits are committed or rebased.

## Findings that decide the design

### Can a second view stream a session while another is active? Not through AppState; yes through the socket.

- AppState is single-active-session. `HermesClient.handleStreamEvent` hands every parsed event to one closure, `client.onEvent`, which `AppState.makeClient` wires to `AppState.handleStreamEvent`. `applyStreamEvent` then drops any event for which `eventBelongsToActiveSession(sessionId)` is false. Nothing is accumulated for other sessions.
- The transport is not single-session: one WebSocket per client, and every event carries `session_id` (`StreamEventParser.parse`). A session the client created is delivered whether or not it is active.
- Precedent for exactly this: Voice background jobs. `AppState.voiceBackgroundJobSupervisor` creates an ordinary session with `client.createSession(...)`, drives it with `client.sendPrompt(_:text:)`, stops it with `client.cancel(_:)` (`session.interrupt`), and consumes its events through `VoiceBackgroundJobSupervisor.observe(_:)`, which `handleStreamEvent` calls BEFORE the active-session filter. It matches events on runtime id or stored id (`VoiceThreadTarget.owns(sessionID:)` style).
- `addVoiceAssistantObserver` is NOT usable: `notifyVoiceAssistant` runs inside `applyStreamEvent`, after the active-session guard.

Options considered:

| Option | Verdict |
|---|---|
| A. Quick Ask makes its session active (`createNewSession`, `requestOpenSession`) | Rejected. It would replace the user's open transcript, run `beginReconciliation`, add a tab, and cancel/supersede viewport transitions, all while they work in another app. Keeps all streaming UI free but trashes main-window state. |
| B. Tap the event stream with a second consumer (chosen) | One gated line in `handleStreamEvent`; Quick Ask owns its own tiny reducer. Main window untouched. Same pattern as Voice jobs. |
| C. Second `HermesClient` and socket | Rejected. `makeClient` is private and tied to the connection epoch, profile switching, Cloudflare tickets and `handleDisconnect`; duplicating that is far more invasive than one tap line. |

Trade-off of B: Quick Ask renders only what the reducer understands (assistant text, a one-line tool/status hint, errors, "needs input"). Approvals, clarify cards, reasoning cards and attachments are NOT rebuilt in the panel; they hand off to the main window via promotion (see "Needs input").

### Global hotkey API (checked against Apple sources)

- `NSEvent.addGlobalMonitorForEvents`: Apple docs: "Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access (see AXIsProcessTrusted())"; it is observation-only (copies of events delivered to other apps), so it cannot swallow Space and needs a permission prompt. Rejected.
- `CGEventTap`: needs the Input Monitoring privilege (`CGPreflightListenEventAccess` / `CGRequestListenEventAccess`), per Apple DTS (developer.apple.com/forums/thread/735223). A TCC prompt for a single shortcut is a poor trade. Rejected.
- Carbon `RegisterEventHotKey` (chosen). Registers one key combination with the window server and delivers it to our app even when it is in the background; no Accessibility or Input Monitoring prompt, and the combo is consumed (Space is not typed into the front app). Apple DTS calls it the best of the three but legacy (same thread). I found no Apple page that states "no permission needed" in words; that claim rests on DTS's framing and on it being the mechanism the permission-free hotkey libraries use. Verify in the first spike on a clean user account with hardened runtime.
- Third-party package (sindresorhus/KeyboardShortcuts): wraps the same Carbon call and adds a recorder UI. Not adopted in v1 (new dependency for one fixed key). It is the cheap route to rebinding later.
- Version gate, important because the combo is Option-Shift only: on macOS 15.0 and 15.1, `RegisterEventHotKey` rejects hotkeys whose only modifiers are Option or Option-Shift, returning -9868 (`eventInternalErr`). An Apple Frameworks Engineer called it intentional (limits key-logging of Shift-Option characters) and said it was fixed in macOS 15.2 beta 2 (developer.apple.com/forums/thread/763878). One user later reported a recurrence (anecdotal, unconfirmed). The app targets macOS 14+, so 14.x and 15.2+ work; 15.0 and 15.1 can fail. Handling: registration failure is a visible, non-fatal state (see Error handling); the Chat menu command "Quick Ask" (no global effect) always works.

## Behaviour

- **Open.** Option-Shift-Space shows the panel on the screen under the mouse, near the top center, with the field focused. The frontmost app keeps its menu bar and stays active (non-activating panel). Pressing the hotkey while the panel is visible hides it.
- **Ask.** Return sends the first prompt. The reply streams into the panel as markdown (same `MarkdownText` view the chat uses). A one-line status shows the current tool name while a tool runs (`.toolStart.toolName`). Panel grows with the reply to a 480 pt cap, then scrolls.
- **Follow-up.** While the panel stays open, the field accepts another prompt (sent to the same session) once the turn ends. Input is disabled while a turn runs; Stop (Cmd-.) interrupts via `client.cancel`.
- **Dismiss.** Esc, the hotkey, or clicking outside hides the panel. Dismissing does NOT stop a running turn: it finishes on the gateway and in the session.
- **Promote.** Cmd-Return or the "Open in Conduit" button activates Conduit, brings the main window front (recreating nothing; the window survives close, see `applicationShouldHandleReopen`), opens the Quick Ask session there with the normal open path, and hides the panel. The tab strip adds the tab by itself (it observes `activeSessionId`).
- **Needs input.** If the session emits `.approval`, `.clarify` or `.inputPrompt`, the panel shows "Hermes needs your input" and makes Open in Conduit the default action. The panel never answers these.
- **New vs continue (decision): new session per invocation, restored within a short window.** First Return after opening creates a session (`session.create` via `client.createSession`); nothing is created if the user dismisses without sending. Reopening within 120 s of the last panel activity restores the previous exchange and continues the same session (covers an accidental Esc and "peek at another window"); after 120 s, or on Cmd-N in the panel, the panel opens empty and the next prompt creates a fresh session. Why not a permanent "quick" session: it grows a stale, unrelated context that the model keeps reading, it becomes a junk drawer in the sidebar, and promotion would drag all of it into view. Why not always fresh: one Esc would lose a streaming answer.
- **Profile and model (decision):** the active profile (`AppState.activeProfile`), and NO explicit model or provider, so the gateway applies the profile's default. Why not `runtime.model`: `createAndReconcileSession` uses it, but `runtime` mirrors the open chat, which can carry a per-chat override (a slow or expensive model chosen for something else). `createSession(model: nil, provider: nil)` is already a live path (`runtime.model.isEmpty`). Voice jobs show a separate "fast model" preference exists (`voiceJobSessionOptions`); a Quick Ask model setting can reuse that shape later.
- **Not in v1.** Attachments, slash commands, dictation, model picker, history inside the panel, screenshots of the front app, rebinding.

## Shortcuts

| Keys | Where | Action |
|---|---|---|
| Option-Shift-Space | global | show / hide panel |
| Return | panel | send |
| Esc | panel | hide (turn keeps running) |
| Cmd-Return | panel | promote to main window |
| Cmd-. | panel | stop the turn |
| Cmd-N | panel | discard restored exchange, start empty |

Rebinding: not cheap (recorder UI, conflict detection, persistence, or a package). v1 is fixed. `MacQuickAskHotKey.default` is a value (key code 49, modifiers option+shift) so a recorder can replace it later. The one setting is on/off, as a Toggle "Quick Ask Shortcut" in the Chat menu (`ConduitCommands.swift`, Mac-only file, `@AppStorage conduit.mac.quickAsk.enabled`, default on), so no upstream Settings edit is needed.

## Architecture and components

New files (xcodegen globs `ConduitMac/`; no project.yml change):

- `ConduitMac/Panels/MacFloatingPanel.swift`: `MacFloatingPanel` (NSPanel subclass) and `MacFloatingPanelController` (owner, placement, lifecycle). Shared base.
- `ConduitMac/Panels/MacFloatingPanelPlacement.swift`: pure placement strategies and geometry (no AppKit windows; takes screen frames).
- `ConduitMac/QuickAsk/MacGlobalHotKey.swift`: Carbon wrapper behind `protocol MacHotKeyRegistering` (`register(_:handler:) throws`, `unregister()`); `MacQuickAskHotKey` value.
- `ConduitMac/QuickAsk/MacQuickAskModel.swift`: pure reducer. State: `.idle`, `.creating`, `.sending`, `.streaming(text, status)`, `.done(text)`, `.needsInput(text)`, `.failed(message, partial)`. Input: user actions plus `StreamEvent` for owned session ids. No AppKit, no AppState.
- `ConduitMac/QuickAsk/MacQuickAskStreamTap.swift`: `MacQuickAskStreamTap.shared.observe(_ event:)`, forwards to the active model only; a no-op when Quick Ask is idle.
- `ConduitMac/QuickAsk/MacQuickAskController.swift` (`@MainActor`): owns the panel controller, hotkey, model and 120 s restore timer; performs RPCs through injected closures (`createSession`, `sendPrompt`, `cancel`, `openSession`, `activateMainWindow`) bound to `AppState` at app start.
- `ConduitMac/QuickAsk/MacQuickAskView.swift`: SwiftUI panel content (field, reply, status line, buttons).
- Upstream edit (one ledger row): `AppState.handleStreamEvent`, next to `voiceBackgroundJobSupervisor.observe(event)`: `#if os(macOS) // MAC: Quick Ask observes every session's events` then `MacQuickAskStreamTap.shared.observe(event)`. No stored property is added to AppState.
- Wiring: `ConduitMacApp.rootContent` already does `.task { MacSessionTabsStore.shared.bind(to: appState) }`; add the same-shaped `MacQuickAskController.shared.bind(to: appState)` (Mac-only file, no ledger row) and install the hotkey in `ConduitMacAppDelegate.applicationDidFinishLaunching`, skipped when `MacDefaults.isRunningUnderXCTest`. The app keeps running after the last window closes (`applicationShouldTerminateAfterLastWindowClosed` is false), so the hotkey works with no window open.
- `ConduitCommands.swift`: Chat menu items "Quick Ask" (opens the panel; no global key equivalent, so it cannot clash) and the on/off Toggle.

## Data flow

1. Hotkey handler (main thread) calls `controller.toggle()`. Panel appears, field focused; if `appState.isConnected` is false the view shows "Not connected" and a button to open Conduit.
2. Return: model `.creating`. Controller calls `client.createSession(inProfile: nil)` on `appState.client` (profile = active). Result `(sessionId, storedSessionId, profile)`. If the returned profile differs from the active one, fail with "Hermes created this in <profile>" (same guard as `createAndReconcileSession`). Model records both ids as owned.
3. Controller calls `client.sendPrompt(sessionId, text:)` (`prompt.submit`). The returned `PromptSubmissionOutcome` is the authority on whether it started; a throw maps to `.failed`.
4. Events arrive on the socket, reach `handleStreamEvent`, and the tap hands them to the model (and AppState drops them as not-active, as today). Model rules: `.messageStart` clears the status; `.messageDelta(text)` appends; `.toolStart(toolName)` sets status; `.messageComplete(content)` replaces the text with `content` when non-nil and ends the turn (`.done`); `.messageError(message)` -> `.failed`; `.messageInterrupted` -> `.done` with partial text; `.approval`, `.clarify`, `.inputPrompt` -> `.needsInput`; `.sessionBusy(busy: false)` ends a turn that never got a completion. Only event cases that exist in `StreamEvent` (HermesClient.swift) are used. Whether a tool-using turn emits several `.messageComplete` segments is unconfirmed: the first implementation task is a recorded-trace test against a live gateway; the reducer must keep the turn open when `.messageStart` follows a completion.
5. Title: not set by Quick Ask; Hermes names the session (`.sessionTitle`) and it appears in the sidebar after the next `loadSessions`. The controller calls `appState.loadSessions(forceRefresh: true)` after create so it lists promptly.
6. Promote: `activateMainWindow()` (`NSApp.activate`, then the `conduit-primary` window `makeKeyAndOrderFront`, as `applicationShouldHandleReopen` does), then `appState.requestOpenSession(sessionId)`. That path posts `.macSessionOpenRequested` (returns the main pane to chat), runs `performSessionOpen`, and resumes the session; `session.resume` includes in-flight messages (HermesClient header comment), so a turn still streaming continues in the main chat. Events that arrive during the resume are buffered by AppState's reconciliation. After promote the model detaches from the session and the panel hides.
7. Hide without promote: model keeps listening until the turn ends so a reopen within 120 s shows the finished answer.

## MacFloatingPanel API (shared with the Notch status spec)

```swift
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

enum MacFloatingPanelPlacement {
    case screenCenterTop(fromTop: CGFloat)   // screen under the mouse; x centered in visibleFrame
    case notchAnchored                       // screen with safeAreaInsets.top > 0 (else mouse screen); x centered; top flush
    case custom((_ panelSize: NSSize) -> NSRect)
    // pure: frame(panelSize:, screenFrame:, visibleFrame:, safeAreaTop:)
}

@MainActor final class MacFloatingPanelController {
    init<Content: View>(config: MacFloatingPanelConfig, @ViewBuilder content: () -> Content)
    var isVisible: Bool { get }
    func show()                 // place, orderFrontRegardless, makeKey if canBecomeKey
    func hide()                 // orderOut, fires onDismiss once
    func toggle()
    func updateContentHeight(_ h: CGFloat)   // top edge fixed, grows down, clamped to maxHeight
}
```

Behaviour contract:
- `MacFloatingPanel: NSPanel`, style `[.borderless, .nonactivatingPanel, .fullSizeContentView]`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, clear background, system shadow, `canBecomeMain = false`, `canBecomeKey` from config. Content is an `NSHostingView` (SwiftUI owns its own glass/material).
- Non-activating: showing it never activates Conduit and never steals the front app's menu bar; a key panel receives typing. Promotion is the only path that activates Conduit.
- Esc: `cancelOperation(_:)` override calls `hide()` when `dismissOnEscape`; works even when Conduit is not the active app because the panel is key.
- Resign key (click elsewhere, Cmd-Tab): `hide()` when `dismissOnResignKey`.
- Spaces: `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it appears on the current Space and over a full-screen app.
- Multi-display: placement is recomputed on every `show()` from `NSEvent.mouseLocation` and each `NSScreen.frame`; also on `NSApplication.didChangeScreenParametersNotification` while visible. The frame is clamped inside the screen's `visibleFrame`.
- `.screenCenterTop(fromTop:)`: y = visibleFrame.maxY - fromTop - height; v1 uses 0.22 of screen height. `.notchAnchored`: x centered on the screen, top = screenFrame.maxY (panel sits at the physical top edge, around the notch cut-out); the notch spec owns exact geometry using `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, supplied through `.custom` if it needs more than this default.
- Not provided (YAGNI): animations beyond a 120 ms fade, drag to move, multiple simultaneous panels per controller, persistence of position.

## Error handling

- Not connected / connecting / profile switching (`appState.isConnected`, `isConnecting`, `isProfileSwitching`): field disabled, one line explaining, Open Conduit button. Mirrors the guards at the top of `createNewSession`.
- Hotkey registration fails (OSStatus != noErr, notably -9868 on macOS 15.0 and 15.1): log once; the Chat menu shows "Quick Ask Shortcut unavailable on this macOS version"; the menu command still opens the panel. No retry loop; re-register on app activation and on toggle.
- Hotkey conflict (`eventHotKeyExistsErr`): same visible state, naming the conflict.
- `session.create` / `prompt.submit` fail or time out (`HermesError`, `RpcError`): `.failed(message)` shown inline with Retry; the typed prompt is preserved. Use `UserFacingError.message(for:)`.
- Stream error (`.messageError`): partial text kept, error shown, Retry resends the prompt as a new turn in the same session.
- Connection lost mid-turn: if `isConnected` flips false, status "Connection lost. The reply may still finish; open it in Conduit." Promote stays enabled and works after reconnect.
- Profile switched while a Quick Ask turn runs: the Quick Ask session stays in its original profile; promote goes through `requestOpenSession`, whose ownership guard shows its normal "belongs to another workspace" error. The panel keeps showing the reply.
- Window server or panel failure never blocks the main app: the controller is optional glue; all panel code runs on the main actor and holds no AppState state of its own.

## Testing

- `MacQuickAskModel` (pure): delta accumulation; completion replaces text; error keeps partial; interrupt; needs-input transitions; `.sessionBusy(false)` closes a turn; events for a non-owned session id ignored; both runtime and stored ids match; follow-up requires `.done`; 120 s restore with an injected clock; Cmd-N reset.
- Recorded-trace test: a captured gateway event sequence (including a tool turn) replayed through `StreamEventParser` into the model.
- `MacFloatingPanelPlacement` (pure): centerTop on a single screen, secondary screen left/right/below primary, mouse on the second screen, visibleFrame with Dock and menu bar, panel taller than the screen clamps, notch screen top flush.
- Hotkey: `MacHotKeyRegistering` fake; success, -9868 and exists-error mapped to visible state; not registered under `isRunningUnderXCTest`; on/off toggle unregisters.
- Panel (hosted): `canBecomeKey`/`canBecomeMain` per config, `.nonactivatingPanel` set, `level` and `collectionBehavior` as configured, Esc calls `hide()` once, resign key hides only when configured, height grows downward with fixed top edge and caps at `maxHeight`.
- Controller: promote calls activate before `requestOpenSession` exactly once with the session id; hide without promote keeps the model; first Return creates exactly one session; dismiss without sending creates none.
- Stream tap: with no handler `observe` is a no-op; AppState's own handling of the same event is unchanged (existing AppState tests unaffected).
- Accessibility: the field and buttons carry labels (existing `AccessibilityLabelAuditTests` pattern); the panel is reachable by VoiceOver when key.
- Full Mac suite twice; `git diff -- Conduit Shared` removes zero lines outside gates and adds exactly one gated line.
- Manual (SMOKE_CHECKLIST): hotkey from Safari, from a full-screen app, from a second display; typing does not leak to the front app; Esc during streaming then reopen shows the finished reply; promote mid-stream continues in the main chat; macOS 14 and 15.2+ register, 15.0/15.1 fall back to the menu command.

## Out of scope (v1)

Rebinding, attachments and screen capture, slash commands, approvals inside the panel, panel history, a dedicated Quick Ask model setting, launch at login, menu-bar item.

## Docs

New D15 in docs/macos/DECISIONS.md (hotkey API choice and the Sequoia caveat, tap over active-session switch, new-session-with-120 s-restore rule, profile-default model); ledger row for the `handleStreamEvent` gate; SMOKE_CHECKLIST "Quick Ask" section; the Notch status spec links here for `MacFloatingPanel`.

## Open questions for the user

1. Reopen rule: restore the last exchange for 120 s and continue that session (proposed), or always open empty?
2. Model: profile default (proposed), mirror the open chat's model, or a separate "Quick Ask model" setting now?
3. Esc while a turn streams: hide and let it finish (proposed), or also stop it?
4. The hotkey only works while Conduit runs. Add launch-at-login (`SMAppService.mainApp`) with this feature, or leave it to a later pass?
5. Quick Ask sessions are ordinary sessions in the sidebar. Is that acceptable, or should they be tagged or hidden until promoted? (Hiding needs a catalog filter, an upstream edit.)

## Effort

About 8 working days: MacFloatingPanel and placement 1.5; hotkey wrapper, menu, toggle, failure states 1; model, tap, controller, one upstream gate 2; SwiftUI view 1; promotion and edge cases 1; tests (pure, hosted, trace) 1; docs, smoke, review fixes 0.5. Rebinding via the KeyboardShortcuts package would add about 1 day. The Notch status work then adds only its own content and the `.notchAnchored` geometry.
