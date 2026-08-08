---
name: conduit-failure-archaeology
description: >
  The incident chronicle for Hermes Conduit (native SwiftUI iOS client for the
  Hermes Agent dashboard). Load this BEFORE debugging any symptom that smells
  familiar: app stuck on "Synchronizing", WebSocket ticket minting fails,
  DashboardTicketBridge returns nothing, 401 right after login, sessions from
  the wrong profile appearing in the sidebar, scroll-to-latest button missing,
  composer frozen after creating a conversation, push notification opens the
  wrong session, voice capture dies after a phone call, or a build error in
  AuxiliaryViews.swift @AppStorage lines. Load this when a symptom smells
  familiar or before re-fighting what may be a settled battle in
  ConnectionURLPolicy.swift, DashboardTicketBridge.swift, HermesClient.swift,
  PushNotificationService.swift, or AVAudioCaptureService.swift. (For live
  triage of a new symptom start with conduit-debugging-playbook; for the
  invariants gate on those files use conduit-architecture-contract.) Every
  entry is symptom -> root cause -> evidence -> status. This file is also the accumulation point for NEW incidents: append,
  never rewrite.
---

# Conduit Failure Archaeology

Every known investigation and incident in this repo, recorded so no future
session re-fights a settled battle. Read the entry for your symptom before
opening the debugger.

**Jargon used below (defined once):**

| Term | Meaning |
|---|---|
| Hermes Agent | The self-hosted server this app is a client for. Conduit talks ONLY to its dashboard, never to the gateway directly (project hard rule #2). |
| Dashboard | The Hermes web UI, default port 9119 (README); note the client only accepts http for loopback hosts — remote dashboards must be HTTPS (see `conduit-run-and-operate`, "README vs. code conflict"). All RPC goes through its WebSocket endpoint `/api/ws` after dashboard auth (verified: `Conduit/Services/HermesClient.swift:365`, `README.md:82`). |
| DashboardTicketBridge | `Conduit/Services/DashboardTicketBridge.swift`. A zero-UI `WKWebView` that keeps the dashboard's HttpOnly session cookie alive inside WebKit and mints WebSocket tickets via `POST /api/auth/ws-ticket`. |
| Ticket | Token minted by the bridge; passed to `HermesClient` to open the `/api/ws` socket. Treated as single-use by the client (a fresh ticket is minted per (re)connect); server-side single-use/TTL enforcement is [candidate -- unverified]. |
| `ConnectionURLPolicy` | `Conduit/Services/ConnectionURLPolicy.swift`. Central URL/origin validation: HTTPS-only for remote hosts, origin matching for bridge messages. |
| Turn state | `AppState` enum driving the composer UI: `.idle` / `.synchronizing` / `.reconnecting` / etc. "Stuck on Synchronizing" means this never left `.synchronizing`. |
| RN builds | React Native builds 17-30 of a pre-native prototype, referenced in code comments. That codebase is not in this repo. |

**Scope warning:** public git history is squashed to 5 commits
(`830c09b` initial public release + 4 fixes, all dated 2026-08-07). Everything
before the squash is lost except what survives in code comments and
user-reported memory. This file is the accumulation point going forward: when
you close an investigation, append an entry here (see template at the bottom).

---

## Index

| # | Entry | Status |
|---|---|---|
| 1 | WKSecurityOrigin port 0 drops all bridge responses (stuck "Synchronizing") | fixed (`d0873ec`) |
| 2 | Truncated `@AppStorage` default for `customRelayURL` | fixed (`859162b`) |
| 3 | Push relay shipped pointing at placeholder `push.example.com` | fixed (`e3cdb49` + `e4318c5`) |
| 4 | RN builds 17-30: liveness derivation and cross-profile session leakage | fixed by design (native rewrite) |
| 5 | RPC race on just-opened WebSocket | fixed by design |
| 6 | Composer stuck synchronizing after `session.create` | fixed by design |
| 7 | False 401 right after cookie restore (WebKit cookie-store lag) | fixed by design (retry loop) |
| 8 | URLSession vs WebKit: two separate cookie jars | permanent constraint |
| 9 | Stale scroll-to-latest state (LazyVStack unloads measured child) | fixed by design |
| 10 | Sidebar animation jank during streaming | fixed by design |
| 11 | Push notification resolves against stale session catalog | fixed by design |
| 12 | AVAudioSession interruptions kill voice capture | mitigated; user-reported broader conflict OPEN |
| 13 | App Store review / signing failures | user-reported, OPEN, needs detail |
| 14 | WebSocket/session reliability (reconnects, stale sessions, ticket expiry, background resume) | LIVE campaign |
| 15 | Type-check timeout on the reasoning-delta `??` chain in HermesClient | fixed |
| 16 | ConduitTests bitrot on newer toolchains (`@MainActor` statics, `\/` escaping) | fixed |

---

## 1. WKSecurityOrigin port 0 drops all bridge responses

- **Symptom:** App stuck on "Synchronizing" forever against an HTTPS dashboard
  on the default port (443). No error surfaced. `requestJSON` continuations in
  DashboardTicketBridge never resumed, so no ticket was ever minted.
- **Root cause:** `WKSecurityOrigin.port` returns `0` (not 443) for
  default-port connections. The bridge's script-message origin check
  (`DashboardTicketBridge.swift:347-356`) passes
  `message.frameInfo.securityOrigin.port` into
  `ConnectionURLPolicy.originMatches`, whose `effectivePort` treated `0` as a
  literal port. `0 != 443` failed the guard, which **silently `return`s** —
  every dashboard API response was dropped on the floor.
- **Fix:** `effectivePort` now treats `port <= 0` the same as `nil`, falling
  back to the scheme default (80 for http/ws, 443 for https/wss).
  `Conduit/Services/ConnectionURLPolicy.swift:131-140`.
- **Evidence:** commit `d0873ec` (full write-up in the commit message; read it
  with `git log -p d0873ec`). Inline comment at the fix site.
- **Status:** fixed in `d0873ec`, released as 0.1.1 (the same commit batch
  bumped `MARKETING_VERSION` to 0.1.1 in `project.yml`).
- **Lesson:** the bridge's message handler fails CLOSED and SILENT by design
  (a `guard ... else { return }` with no logging). Any future origin-matching
  bug will present as "stuck Synchronizing" with zero diagnostics. If you see
  that symptom, check the origin guard chain in
  `DashboardTicketBridge.swift:347-361` first.

## 2. Truncated `@AppStorage` default for `customRelayURL`

- **Symptom:** Dangling initializer in `Conduit/Views/AuxiliaryViews.swift`
  (`NotificationsSettingsDetail`): a `String` `@AppStorage` property with
  nothing after the `=`.
- **Root cause:** Commit `e3cdb49` added the push-relay settings field as
  `@AppStorage("conduit.relayURL") private var customRelayURL: String = ` —
  the line ends after `=` with no value (byte-verified via `git show e3cdb49`).
  The empty-string literal was dropped somewhere between authoring and commit.
  Whether `e3cdb49` compiled is [candidate -- not built to confirm]; whether
  the bug reached users / shipped is [candidate -- user report, unresolved].
- **Fix:** `859162b` appended the missing `""` (byte-verified via
  `git show 859162b`). Current state: `Conduit/Views/AuxiliaryViews.swift:1209`.
- **Evidence:** `git log -p 859162b` (one-line diff) and `git log -p e3cdb49`
  (shows the truncated line being introduced).
- **Status:** fixed in `859162b`.
- **Lesson:** literal-dropping happened once in this repo's tooling chain.
  After any automated edit touching string literals, eyeball the diff for
  dangling `= ` before committing.

## 3. Push relay shipped pointing at a placeholder host

- **Symptom:** Push notification pairing could not work out of the box: the
  initial public release's `PushNotificationService` fell back to
  `https://push.example.com` (a non-existent placeholder) when no relay URL
  was saved, and there was no UI to set one.
- **Root cause:** Placeholder default left in at release time; the relay URL
  was stored under `conduit.relayURL` but had no settings surface.
- **Fix:** `e3cdb49` changed the default to `https://push.milim.dev` and added
  a "Push relay" text field under Settings > Notifications (blank = default).
  `e4318c5` documented it in the README. Current code:
  `Conduit/Services/PushNotificationService.swift:52` (default URL, keyed off
  saved `conduit.relayURL`), `Conduit/Views/AuxiliaryViews.swift:1307-1318`
  (settings field).
- **Evidence:** `git log -p e3cdb49` and `git log -p e4318c5`.
- **Status:** fixed. Note the relay is the ONE deliberate exception to
  "device talks only to the dashboard": it exists solely for APNs push
  delivery and is user-replaceable (self-hostable). It is not telemetry and
  must never become a telemetry channel (project hard rule #1). Relay
  server-side behavior is not visible from this repo
  [candidate -- unverified: anything about what push.milim.dev does
  server-side].

## 4. RN builds 17-30: liveness derivation and cross-profile leakage

Pre-native history. Before this SwiftUI app there was a React Native client;
its builds 17-30 fought battles that are memorialized as load-bearing rules in
the `HermesClient.swift` header (`Conduit/Services/HermesClient.swift:7-23`,
"LESSONS FROM RN BUILDS 17-30"):

- **`running` is authoritative.** `session.resume.running` and
  `session.info.running` are the authoritative turn state. A gateway response
  missing `running` means the server is too old for safe chat controls. Never
  derive liveness from message roles.
- **Use `resumed.messages` from the `session.resume` RPC** (including
  in-flight transcript state) rather than reconstructing state.
- **Never merge gateway RPC `session.list` into the UI list.** It reads the
  main DB containing ALL profiles — merging it leaks other profiles' sessions
  into the sidebar. Use the profile-scoped endpoint only.

- **Evidence:** the header comment itself; the RN codebase is gone.
- **Status:** fixed by design in the native rewrite. These are standing
  contracts — see `hermes-protocol-reference` for the full RPC surface and
  `conduit-architecture-contract` for the thin-client rule (HermesClient does
  transport + RPC correlation ONLY; all session/busy/reconnect state lives in
  `AppState.syncSession()`).

## 5. RPC race on a just-opened WebSocket

- **Symptom (historical class):** first `session.resume` after connect
  intermittently failed or hung.
- **Root cause:** URLSession only confirms the WebSocket handshake through its
  delegate callback. Issuing RPCs (or painting the green connected indicator)
  before `didOpenWithProtocol` fires races the handshake.
- **Fix:** `WebSocketOpenDelegate` in
  `Conduit/Services/HermesClient.swift:302-317` gates everything on the
  delegate callback; the doc comment at line 303-305 states the rule.
- **Status:** fixed by design. Do not "simplify" connect by removing the
  open-continuation gate.

## 6. Composer stuck synchronizing after `session.create`

- **Symptom:** create a new conversation -> composer freezes in synchronizing
  state.
- **Root cause:** `session.create` already returns the active runtime session,
  but some Hermes versions do not make its history-resume record available
  immediately. Calling `session.resume` right after create races the server's
  persistence layer and the resume never completes usefully
  [candidate -- unverified: exact server-side persistence behavior; described
  per the client comment].
- **Fix:** after create, the client adopts the returned runtime session
  directly (`setActiveSessionState`) and does NOT resume it. Comment at
  `Conduit/Services/AppState.swift:913-916`.
- **Status:** fixed by design. If you refactor the create path, keep the
  no-resume-after-create rule.

## 7. False 401 immediately after cookie restore

- **Symptom:** freshly launched app with a valid saved session gets a 401 /
  sign-in-required from the first ticket mint, bouncing the user to login even
  though their session is fine.
- **Root cause:** a restored session cookie can reach WebKit's cookie store a
  moment before WebKit's *network process* sees it. The first request after
  restore can therefore 401 spuriously.
- **Fix:** `mintTicket()` retries up to 3 attempts, reloading the bridge page
  and sleeping 350ms between attempts, before concluding the durable session
  is actually dead. `Conduit/Services/DashboardTicketBridge.swift:153-171`
  (comment at 154-156).
- **Status:** fixed by design. A single 401 after cookie restore is NOT
  evidence of session expiry; do not shortcut the retry loop.

## 8. URLSession and WebKit keep separate cookie jars (permanent constraint)

- **Symptom class:** auth works in one path (native password login via
  `NativeAuthClient`, which uses URLSession) but the WebKit bridge is
  unauthenticated, or vice versa.
- **Root cause:** iOS fact, not a bug: URLSession and WKWebView maintain
  independent cookie stores. The dashboard issues an HttpOnly session cookie,
  which native code cannot read from a response and must instead mirror.
- **Design that holds it together (all in `DashboardTicketBridge.swift`):**
  - `DashboardCookiePersistence` mirrors authenticated dashboard cookies into
    Keychain and restores them into WebKit's `httpCookieStore` before the
    cold-launch bridge loads (lines 14-17, 295-300).
  - Native password-login session is copied into WebKit before the bridge's
    first request (comment at 64-66).
  - After a fresh URLSession login during reconnect, the bridge is
    `reload()`ed so WebKit picks up the new session
    (`Conduit/Services/AppState.swift:1135-1137`).
  - A `didFinish` navigation landing on `/login` marks the bridge not-ready
    and rejects pending work with `signInRequired`; the comment at
    `DashboardTicketBridge.swift:314-315` forbids minting a "misleading"
    ticket in that state.
- **Status:** permanent constraint; the ticket-bridge cookie machinery exists
  BECAUSE of it. User-reported: this whole cookie/ticket extraction area was
  one of the costliest failure zones historically; entry 1 is the one fight
  from it that is visible in git. Treat any change here as high-risk (see
  `conduit-change-control`).

## 9. Stale scroll-to-latest state in ChatView

- **Symptom:** the scroll-to-latest button stops appearing after the user
  scrolls away from the bottom of a long chat.
- **Root cause:** the bottom-of-chat detection measured a child view inside
  the `LazyVStack`. SwiftUI can unload that child once it scrolls offscreen,
  leaving the last-measured "at bottom" value stuck true and suppressing the
  button.
- **Fix:** measure the lazy stack itself via a `GeometryReader` in
  `.background` (plus a persistent 1pt bottom anchor), not a final child.
  `Conduit/Views/ChatView.swift:55-75` (comments at 55-57 and 64-68).
- **Status:** fixed by design.

## 10. Sidebar animation jank during streaming

- **Symptom (historical class):** opening the sidebar drawer while a response
  streams stuttered — token deltas were driving full presentation updates at
  streaming cadence during the animation.
- **Fix:** when `showSidebar` flips true, the pending streaming-publish task
  is cancelled; the live buffer stays authoritative and is republished when
  the drawer closes. `Conduit/Services/AppState.swift:126-141`.
- **Status:** fixed by design. The buffer/publish split is deliberate; do not
  publish streaming text directly to `@Published` state at token cadence.

## 11. Push notification resolves against a stale session catalog

- **Symptom:** tapping a push notification opened the wrong session or
  bounced back to the newest entry of the old session list.
- **Root cause:** two races, both documented at
  `Conduit/Services/AppState.swift:1420-1432`:
  1. Pushes can arrive before this device has ever seen the scheduled run, so
     the local catalog does not contain the target session.
  2. The sidebar refresh guard could swallow the needed refresh if a visual
     refresh was already in progress, resolving the notification against the
     stale catalog.
- **Fix:** the notification route always does `loadSessions(forceRefresh:
  true)` with its own authoritative read (it deliberately does NOT share the
  sidebar refresh guard), then matches the pushed session ID against both
  primary and `alternateIds`.
- **Status:** fixed by design.

## 12. AVAudioSession interruptions kill voice capture

- **Symptom:** an incoming call, Siri, or another app's audio kills the voice
  conversation; historically (user-reported) wake-word listening, speech
  playback, and interruptions fought over the shared `AVAudioSession`.
- **What the code does now (verified):**
  - `AVAudioCaptureService` observes `AVAudioSession.interruptionNotification`
    and on `.began` stops the engine and yields `.interrupted`
    (`Conduit/Voice/AVAudioCaptureService.swift:218-225`). There is no
    `.ended`-with-`shouldResume` auto-recovery branch — recovery is pushed up
    to the controller.
  - `VoiceConversationController` converts `.interrupted` into
    `failForAudioInterruption()` (`Conduit/Voice/VoiceConversationController.swift:405-414, 491`).
  - Route changes rebuild the format converter lazily (nil-format tap follows
    the input node's route format) and restart a stopped engine without
    churning a running one (`AVAudioCaptureService.swift:227-236`).
  - Capture and playback both use category `.playAndRecord`, mode
    `.voiceChat`; capture adds `.allowBluetoothA2DP` and prefers 16kHz
    (`AVAudioCaptureService.swift:119-126`,
    `AVSpeechPlaybackService.swift:27-29, 73-75`). Capture deactivates with
    `.notifyOthersOnDeactivation` on stop (`AVAudioCaptureService.swift:116`).
  - `WakeLifecycleCoordinator.disarmImmediately()` is called synchronously on
    scene inactive/background so wake-word capture never runs outside the
    foreground (`Conduit/Voice/Wake/WakeLifecycleCoordinator.swift:45-47`).
- **Status:** mitigated in code; **user-reported broader conflict OPEN /
  needs-detail.** The specific historical failure modes (which combination of
  wake listening + TTS playback + interruption misbehaved, on which iOS
  versions) are not recoverable from the squashed history. If you hit an
  AVAudioSession conflict, record the exact reproduction here and see
  `conduit-voice-pipeline` for the pipeline's intended state machine.

## 13. App Store review / signing failures (user-reported, OPEN)

- **User-reported:** App Store review and code-signing problems were among the
  costliest past failures. Specifics (rejection reasons, which entitlement or
  profile broke, resolution) are lost to the squash.
- **What is verifiable in-repo:** manual signing
  (`CODE_SIGN_STYLE: Manual`, `DEVELOPMENT_TEAM: U2TH557QA8`) in `project.yml`;
  `aps-environment: production` in `Conduit/Conduit.entitlements`; `.gitignore`
  excludes `*.p8/*.p12/*.mobileprovision`; and one review-adjacent artifact:
  `WakeModelDescriptor.licenseReviewNote` requiring model redistribution terms
  and upstream SHA-256 verification before wake-model assets are downloaded or
  committed (`Conduit/Voice/Wake/WakeModelDescriptor.swift:41,55`) — that note
  exists because third-party model licensing is an App Store review surface
  [candidate -- unverified: whether a review rejection specifically prompted
  it].
- **Status:** OPEN / needs-detail. Next time signing or review breaks, append
  the specifics here. Runbook home for the process itself:
  `conduit-appstore-and-signing`.

## 14. WebSocket/session reliability (LIVE campaign)

- **User-reported:** the hardest live problem — reconnects, stale sessions,
  auth ticket expiry, resume-after-background.
- **Current machinery (verified, so you know the baseline before "fixing" it):**
  - Reconnect backoff: `min(5.0, 2^attempts)` seconds, or 0.1s immediately if
    a turn was running when the socket dropped; attempts reset after a
    connection that survived >10s (`Conduit/Services/AppState.swift:1087-1110`).
  - Reconnect mints a FRESH ticket via the bridge every time (tickets are
    single-use); on `signInRequired` it falls back to saved Keychain
    credentials via `NativeAuthClient`, then reloads the bridge
    (`AppState.swift:1112-1150`).
  - `syncSession()` is "the only entry point for cold start, foreground
    refresh, reconnect, and manual refresh" and "never derives liveness from
    transcript shape" (`AppState.swift:733-735`).
- **Status:** LIVE. This file records only *settled* incidents; the active
  campaign — open hypotheses, experiments, current suspect list — lives in
  `conduit-ws-reliability-campaign`. When that campaign closes an incident,
  its post-mortem entry belongs HERE.

---

## 15. Type-check timeout on the reasoning-delta `??` chain in HermesClient

- **Symptom:** `error: the compiler is unable to type-check this expression in
  reasonable time` at the `reasoning.delta` case of
  `HermesClient.handleStreamEvent` — surfaced 2026-08-08 while adding the
  (unrelated) Kanban feature; deterministic across clean builds on Xcode 26.
- **Root cause:** a 7-term `??` chain over `AnyCodable?` subscript lookups sat
  at the edge of the type-checker's expression budget; any change in
  module-wide compilation load can tip such expressions over.
- **Fix:** split into `payloadText` / `objText` sub-expressions with explicit
  `String?` annotations (`Conduit/Services/HermesClient.swift`, `reasoning.delta` case).
  Behavior identical.
- **Evidence:** `grep -n "payloadText" Conduit/Services/HermesClient.swift`
- **Status:** fixed.
- **Lesson:** in this codebase's normalizer style, cap `??` fallback chains at
  ~4 terms or bind intermediates with explicit types; the same idiom appears
  throughout `MessageNormalizer` and `KanbanNormalizer`.

---

## 16. ConduitTests bitrot on newer toolchains

- **Symptom:** the unit-test target failed to compile (calls to `@MainActor`
  statics `AppState.unpersistedInflightAssistantText` /
  `normalizedGeneratedSessionTitle` from nonisolated sync tests), and once
  compiling, `testInlineScriptSerializationEscapesScriptTerminators` failed —
  discovered 2026-08-08; the suite had not been run on this toolchain since
  before the public release.
- **Root cause:** (a) stricter actor-isolation enforcement in the current
  toolchain; (b) `JSONSerialization` on the current simulator runtime escapes
  `/` as `\/`, so the expected literal `</script>` became
  `<\/script>`. The underlying security property (literal `</script>`
  never appears in inline script source) was never violated.
- **Fix:** `MessageNormalizerTests` is now `@MainActor`; the escaping test now
  pins the invariant (`XCTAssertFalse(value.contains("</script>"))`) instead of
  the incidental slash-escaping form.
- **Evidence:** run the suite (see `conduit-diagnostics-and-tooling`); both
  fixes are in `ConduitTests/MessageNormalizerTests.swift:4` and
  `ConduitTests/SecurityBoundaryTests.swift`.
- **Status:** fixed.
- **Lesson:** pin invariants, not incidental runtime formatting, in tests; and
  run the suite after toolchain updates even when the app target builds.

---

## When NOT to use this skill

| You want... | Go to |
|---|---|
| To debug a NEW symptom with no matching entry | `conduit-debugging-playbook` |
| The active WS-reliability investigation (open, unsettled) | `conduit-ws-reliability-campaign` |
| The RPC method/event catalog (`session.resume`, etc.) | `hermes-protocol-reference` |
| Layering rules (why HermesClient is thin, who owns state) | `conduit-architecture-contract` |
| Voice pipeline design (wake, capture, playback state machine) | `conduit-voice-pipeline` |
| Signing/review process runbook | `conduit-appstore-and-signing` |
| Build commands, xcodegen, environment setup | `conduit-build-and-env` |
| Settings keys and feature flags (e.g. `conduit.relayURL`) | `conduit-config-and-flags` |

## Adding a new entry (template)

Append under a new number; never delete or rewrite settled entries. Keep the
index table in sync.

```
## N. <One-line title>
- **Symptom:** what the user/dev observed.
- **Root cause:** the actual mechanism, not the patch.
- **Fix:** what changed, with file:line and commit SHA.
- **Evidence:** commands/paths a stranger can use to re-verify.
- **Status:** fixed <sha> | fixed by design | mitigated | OPEN / needs-detail | user-reported.
- **Lesson:** the rule that prevents a re-fight (omit if none).
```

## Provenance and maintenance

Repo root: `/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`.
Ground truth verified at commit `859162b` (main).
All facts verified 2026-08-08 by reading source; no build or network commands were
run. Volatile facts and how to re-verify each (paste-ready; run from repo root):

```bash
# History is still squashed to 5 commits (if this grows, mine the new ones):
git log --oneline

# Entry 1: port-0 fix still present in ConnectionURLPolicy
grep -n "port > 0" Conduit/Services/ConnectionURLPolicy.swift
git log -p d0873ec -- Conduit/Services/ConnectionURLPolicy.swift

# Entry 1: silent-fail origin guard in the bridge message handler
grep -n "securityOrigin" Conduit/Services/DashboardTicketBridge.swift

# Entry 2: @AppStorage default restored
grep -n 'conduit.relayURL' Conduit/Views/AuxiliaryViews.swift
git log -p 859162b

# Entry 3: relay default URL and settings field
grep -n "push.milim.dev" Conduit/Services/PushNotificationService.swift README.md
git log -p e3cdb49 e4318c5 -- Conduit README.md

# Entry 4: RN builds 17-30 lessons header
sed -n '7,23p' Conduit/Services/HermesClient.swift

# Entry 5: WebSocket open-delegate gate
grep -n "WebSocketOpenDelegate" Conduit/Services/HermesClient.swift

# Entry 6: no-resume-after-create comment
grep -n "stuck synchronizing" Conduit/Services/AppState.swift

# Entry 7: mintTicket 401-retry loop
grep -n -A2 "first 401" Conduit/Services/DashboardTicketBridge.swift

# Entry 8: cookie-jar mirroring and /login rejection
grep -n -iE "cookie store|/login" Conduit/Services/DashboardTicketBridge.swift

# Entry 9: LazyVStack bottom-marker measurement
grep -n -B2 "value stuck" Conduit/Views/ChatView.swift

# Entry 10: streaming publish pause while sidebar animates
grep -n -A3 "streaming\s*$" Conduit/Services/AppState.swift | sed -n '1,6p'
sed -n '126,141p' Conduit/Services/AppState.swift

# Entry 11: notification route forces its own catalog refresh
sed -n '1420,1434p' Conduit/Services/AppState.swift

# Entry 12: interruption/route-change handling and session categories
grep -n -E "setCategory|handleInterruption|handleRouteChange" Conduit/Voice/AVAudioCaptureService.swift
grep -n "disarmImmediately" Conduit/Voice/Wake/WakeLifecycleCoordinator.swift

# Entry 13: signing config and license review note
grep -n -E "CODE_SIGN_STYLE|MARKETING_VERSION" project.yml
grep -n "licenseReviewNote" Conduit/Voice/Wake/WakeModelDescriptor.swift

# Entry 14: reconnect backoff and syncSession single entry point
sed -n '1099,1110p' Conduit/Services/AppState.swift
grep -n "only entry point" Conduit/Services/AppState.swift

# WS endpoint + default port (hard rule #2 grounding)
grep -n '"/api/ws"' Conduit/Services/HermesClient.swift
grep -n "9119" README.md
```

Run log:

- 2026-08-08 (build): initial authoring
- 2026-08-08 (build): appended entries 15-16 (type-check timeout in HermesClient; ConduitTests toolchain bitrot) found while building the read-only Kanban board
