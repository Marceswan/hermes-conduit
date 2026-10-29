# Mac done and approval notifications: design

Date: 2026-10-15. Status: draft for review. Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

Tell the user, with a local macOS notification, when Conduit needs them and they are not looking: a long turn finished, or the agent is blocked on an approval or a clarifying question. The user can answer from the notification (inline reply, Approve/Deny) or click it to open the session.

Single user, several Macs. Each Mac notifies on its own; no cross-Mac sync of "already seen".

## Constraints

- Porting rules (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`, upstream edits gated `#if os(macOS)` and tagged `// MAC:`, one ledger row each. This design needs no upstream edit beyond what the Notch status spec adds.
- Local notifications only. Relay/APNs push stays out (PORTING_LEDGER: `PushNotificationService.shared.refresh()` and the `pendingTarget` route are "skipped, Plan 2"). `PushNotificationService` types (`ConduitNotificationTarget`, `ConduitNotificationPreferences`) are not reused.
- The feed is owned by the Notch status spec. This spec consumes it and does not design it.

## Existing code this builds on

- Local notification precedent: `HermesCallNotifications` (Conduit/Voice/HermesCalls.swift ~985-1060): category, `localRequest`, `post`, routing in `userInfo[localPayloadKey]`. iOS delegate `ConduitAppDelegate` (Conduit/ConduitApp.swift:13) implements `didReceive` / `willPresent`; the Mac delegate `ConduitMacAppDelegate` implements neither and sets no `UNUserNotificationCenter.delegate`.
- Approval: `StreamEvent.approval(sessionId:activity:)`, `.approvalWithdrawn(sessionId:requestId:reason:)` (HermesClient.swift:281-290). `ApprovalActivity` (Models.swift:420) carries `requestId`, `command`, `description`, `choices: [String]?`, `allowPermanent`, `smartDenied`. Answer: `HermesClient.respondToApproval(sessionId:requestId:choice:profile:) -> Bool` (HermesClient.swift:2118, RPC `approval.respond`, needs only ids, not the active session). The UI path `AppState.respondToApproval(messageId:choice:)` (AppState.swift:22166) works on the active session's `messages` only. A "no pending" / code 4009 error means already handled (helper near AppState.swift:22160).
- Clarify: `StreamEvent.clarify(sessionId:activity:)`, `.clarifyExpire(...)`. `ClarifyActivity` (Models.swift:252) has `requestId`, `questions`, `isExpired`. UI path `AppState.respondToClarify(requestId:questionId:answer:)` (AppState.swift:20510) looks up `messages` of the active session. The client-side sender `respondToClarifyServerRequest` (HermesClient.swift:2047) is private.
- Turn end: `StreamEvent.messageComplete`, `.messageError`, `.messageInterrupted`, `.messageStart` (HermesClient.swift:257-266).
- Open session: `AppState.requestOpenSession(_:onFailure:)` (AppState.swift:16214); posts `.macSessionOpenRequested` so the pane returns to chat.
- Send: `AppState.sendMessage(_:attachments:context:)` (AppState.swift:18206), active session only.
- Visibility: docs/macos/PLAN2_INPUTS.md says suppression must use `NSApp.isActive` plus the key window, not `scenePhase`.
- Platform: `UNTextInputNotificationAction` is available on macOS 10.14+ (Apple docs JSON, `usernotifications/untextinputnotificationaction`): the system shows controls to type or dictate text, and the text arrives in the response object (`UNTextInputNotificationResponse.userText`) delivered to `userNotificationCenter(_:didReceive:withCompletionHandler:)`. Actions only appear for notifications whose `categoryIdentifier` matches a category registered via `setNotificationCategories`. Verify banner vs alert presentation of text fields on the current macOS in the smoke run.

## Behavior

### What notifies

| Kind | Trigger | Title / body | Actions |
|---|---|---|---|
| Done | turn finished and was "long-running" | session title / first 140 chars of final reply, or "Finished" | Reply (text input), Open |
| Failed | long-running turn ended in `messageError` | session title / "Stopped with an error" | Open |
| Approval | approval pending | session title / `description` (command in the subtitle, truncated) | Approve, Deny, Open |
| Question | clarify pending | session title / first open question text | Reply (text input), Open |

Interrupted turns (`messageInterrupted`, user pressed Stop) never notify.

### Long-running

A turn is long-running when `finishedAt - startedAt >= 30 s` (turn = `messageStart` to `messageComplete`/`messageError`), default 30 s, user setting 10 / 30 / 60 / 120 s. Time spent waiting on an approval or question counts (the user was away because of it). Approval and question notifications have no threshold.

### When to suppress

Post only if NOT all of these hold (a visible, attended session): `NSApp.isActive`, the main window is key and `occlusionState` contains `.visible`, the chat surface is showing (`MacChatRoute.isChatActive`, no room or sheet covering it), and the event's session is `activeSessionId`. Anything else posts: app in background, window minimized or occluded, another pane open, or a different session active (the tab strip case). Suppression is evaluated at post time, not event time.

Approvals and questions wait a 3 s grace before posting; the post is dropped if `decisionResolved` arrives first (answered in-app, on another Mac, or expired).

### Actions

- Click (default action): activate the app, raise the main window, `requestOpenSession(sessionId)`. A cold-launch click is held until Hermes is connected, then opened (same idea as `pendingExternalLink` in ConduitApp). A target whose dashboard or profile differs from the active scope only activates the app.
- Approve / Deny (approval): shown only when the choice mapping resolves (see below). Calls `HermesClient.respondToApproval(sessionId:requestId:choice:profile:)`. Never sends a permanent ("always") choice, regardless of `allowPermanent`. Approve and Deny carry `.authenticationRequired`, so a locked Mac asks for unlock first. They do not bring the app forward.
- Reply on Done: `sendMessage(userText)` to that session. Reply on Question: `respondToClarify(requestId:questionId:answer:)`, only for a single open question; a batch (more than one) has no Reply, click opens the session.
- Both reply paths need that session active in `AppState` (both APIs read the active session). The handler calls `requestOpenSession` without raising the window, awaits success, then submits. On failure it posts a "Couldn't send your reply. Open Conduit." notification (Open only) and does not retry silently.
- After any action: remove the delivered notification, and treat a 4009 / "no pending" result as success (already handled).

### Dedupe and replacement

- Identifiers: `conduit.done.<sessionKey>` (a newer finish replaces the older one), `conduit.approval.<requestId>`, `conduit.question.<requestId>`. `threadIdentifier = "session-<sessionKey>"` groups a session's items. `sessionKey` is the durable id, matched through `alternateIds` (spec 2026-09-06).
- One Done per turn id; the feed may replay events after a reconnect, so a posted-set keyed by (kind, turnId or requestId) lives for the process.
- No Done is posted for a session that has a pending approval/question notification outstanding for the same turn (that item already told the user).
- On `decisionResolved`, a session becoming visible and attended, or a click, remove delivered and pending requests for it (`removeDeliveredNotifications`, `removePendingNotificationRequests`).
- Burst control: more than 3 Done posts inside 10 s collapse to one "N conversations finished" summary (identifier `conduit.done.summary`).

### Focus and permission

- Never bypass Focus: interruption level stays `.active`; no Time Sensitive or Critical. Notifications held by a Focus are delivered by the system later; the dedupe and removal rules above clear them if the user returns first.
- Authorization (`requestAuthorization([.alert, .sound])`, no badge) is requested lazily: the first time an eligible event occurs while Conduit is inactive after the user enabled notifications. Not at launch.
- Settings > Notifications (new pane section in ConduitMac/Views): master toggle (default on), per-kind toggles (Done, Approvals, Questions), threshold picker, sound toggle, and a status line from `notificationSettings().authorizationStatus`. If denied, the status line has a button that opens System Settings > Notifications (URL scheme verified at build time).
- `willPresent` returns `[]` when the suppression rule holds (should not happen, as we do not post), else `[.banner, .list, .sound]`.

### Choice mapping for Approve / Deny

`ApprovalActivity.choices` is gateway-defined (`[String]?`); this spec does not assume literal values. The mapping is read from the existing approval card logic (its primary-allow and deny choices), reused through a small pure function `MacApprovalChoiceMapper.map(choices:allowPermanent:) -> (approve: String, deny: String)?`. When `choices` is nil or the mapper returns nil, the notification has Open only.

## Events consumed from AgentActivityFeed

All carry `sessionId` (runtime), `sessionKey` (durable, with `alternateIds`), `profile`, `dashboardID`, `title`, and a monotonic `eventId` for dedupe.

1. `turnStarted(turnId, at)`
2. `turnFinished(turnId, at, outcome: completed | failed | interrupted, replyPreview: String?)`
3. `approvalRequested(requestId, description, command, choices, allowPermanent)`
4. `questionRequested(requestId, firstQuestionText, openQuestionCount)`
5. `decisionResolved(requestId, reason: answered | expired | withdrawn | sessionClosed)` (covers `approvalWithdrawn`, `clarifyExpire`, answers from any surface)
6. `sessionTitleChanged(title)` (so a notification uses the current title)

Requirements on the feed:
- Events for ALL sessions with a live turn, not only `activeSessionId` (today AppState applies stream events to the active session's `messages`; verify the gateway delivers other sessions' events on the shared socket, or that the feed polls `session.active_list`).
- A snapshot on subscribe (pending decisions, running turns) so a Mac launched mid-turn, or reconnecting, can post without having seen the start; `turnStarted.at` for a snapshot turn may be the observation time (threshold then undercounts; acceptable).
- Delivery on the main actor, at-least-once, ordered per session. No UI types in the payload.
- Events are published whether or not the Notch UI is shown.

## Architecture and file paths

New, all under `ConduitMac/Notifications/` (target ConduitMac; xcodegen picks up the folder):

- `MacNotificationPolicy.swift`: pure value logic. `isLongRunning`, `shouldSuppress(visibility:)`, dedupe set, burst collapse, identifier builders. No UserNotifications import.
- `MacNotificationCoordinator.swift`: `@MainActor` class, subscribes to the feed, asks policy, builds `UNNotificationRequest`s, owns pending grace timers. Talks to a `NotificationCenterClient` protocol (add, remove, settings, authorization) so tests inject a fake.
- `MacNotificationDelegate.swift`: `NSObject, UNUserNotificationCenterDelegate`. `didReceive` extracts a plain `NotificationAction(actionID, userText, userInfo)` and hands it to the coordinator; `willPresent` as above.
- `MacNotificationActions.swift`: the handlers (open, approve/deny, reply) over closures into `AppState` and `HermesClient`, so they are testable without a gateway.
- `MacApprovalChoiceMapper.swift`: see above.
- `ConduitMac/Views/MacNotificationSettingsView.swift`: the settings section. Preferences in `UserDefaults` keys `conduit.mac.notifications.*`, per Mac.

Edited (Mac-only files, no gate): `ConduitMac/App/ConduitMacAppDelegate.swift` sets `UNUserNotificationCenter.current().delegate` in `applicationDidFinishLaunching` (before it returns, so cold-launch clicks are delivered) and starts the coordinator, not under XCTest (`MacDefaults.isRunningUnderXCTest`).

Categories: `setNotificationCategories` REPLACES the whole set, and `HermesCallNotifications.registerCategory` also calls it (skipped on Mac today, ledger row "registerCategory ... skipped"). The Mac registers its categories (`CONDUIT_DONE`: Reply, Open; `CONDUIT_APPROVAL`: Approve, Deny, Open; `CONDUIT_QUESTION`: Reply, Open) by merging with `getNotificationCategories()`, and re-registers on app-language change so button titles localise.

Routing payload in `userInfo["conduit_mac"]`: `session_id`, `session_key`, `profile`, `dashboard_id`, `request_id`, `kind`. No message text beyond the visible content.

Docs: new D15 in docs/macos/DECISIONS.md; ledger rows for the two "skipped, Plan 2" notification lines updated to "local notifications: ConduitMac/Notifications"; SMOKE_CHECKLIST gets a notification section.

## Error handling

- Authorization denied or not determined: no posts, no retries; settings show the state.
- `UNUserNotificationCenter.add` throws: log (OSLog, like `hermesCallsLogger`), drop. No user-visible error.
- Approval RPC fails (transport, `invalidResponse`): post the "Couldn't send" notification with Open; the card in the app is still pending, so nothing is lost. 4009 / "no pending": success.
- Reply when the session cannot be opened (`requestOpenSession` onFailure) or the clarify request expired: "Couldn't send your reply" with Open.
- Gateway disconnected at action time: same failure notice; no queued replay (a stale approval must not be answered later).
- Feed replays or duplicates: absorbed by the posted-set and stable identifiers.
- Click for a deleted session: `requestOpenSession` fails, app activates only.

## Testing

- Policy: threshold boundaries (29.9 s, 30 s), interrupted never notifies, suppression truth table (active/inactive, key window, occluded, other pane, other session), dedupe on replay, burst collapse, supersede by `decisionResolved` inside the grace window.
- Mapper: nil choices, permanent-only choices, normal pair.
- Coordinator with fake center and fake feed: correct request content, category, thread id, identifiers; removal on resolve and on session becoming attended; no authorization request until first eligible event; denied status posts nothing.
- Actions: Approve calls `respondToApproval` once with the mapped choice, never a permanent one; 4009 treated as success; reply opens then sends; failure posts the notice; batch clarify has no Reply.
- Delegate: `NotificationAction` extraction from a `UNTextInputNotificationResponse` is not constructible in tests, so the delegate is a thin shim over the tested struct; verified by smoke.
- Settings view: hosted in light and dark, status line for each authorization state.
- Smoke (manual, SMOKE_CHECKLIST): background the app, run a 40 s turn, get Done, type a reply inline; trigger an approval, Approve from the banner; Focus on holds the banner; click a notification from a cold launch; second Mac answers, first Mac's banner disappears.
- Full Mac suite twice; iOS build unaffected (no shared file edits); `git diff -- Conduit Shared` empty.

## Open questions

1. Does the gateway stream events for sessions other than the active one on the shared socket, or must the feed poll `session.active_list`? Latency of approval notices depends on it (Notch spec owner).
2. Inline reply currently needs the session active in `AppState` (both `respondToClarify` and `sendMessage` read the active session), so replying switches the visible session behind the user. Acceptable, or add a public client-level clarify/send entry (an upstream edit, new gate and ledger row)?
3. What are the real `choices` strings and which one is "allow once"? The mapper must be read from the approval card; if they are not stable across gateway versions, should Approve/Deny be dropped in v1?
4. Defaults: threshold 30 s and master toggle on, with the permission prompt on first eligible background event. Confirm, or prefer an explicit first-run opt-in.
5. Cross-scope clicks (notification for another dashboard or profile): only activate the app, or also switch scope and open the session?

## Effort

About 5 days: policy and mapper with tests 1; coordinator, delegate, categories 1.5; actions and failure paths 1; settings view 0.5; smoke, docs, ledger, review fixes 1. Depends on the Notch spec delivering the feed events above first (or a stub feed protocol, +0.5 day).
