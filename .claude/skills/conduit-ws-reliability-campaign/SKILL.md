---
name: conduit-ws-reliability-campaign
description: >
  Executable, decision-gated campaign for Hermes Conduit's hardest live problem:
  WebSocket and session reliability. Load this skill when the task involves:
  the app not reconnecting after backgrounding ("stuck on Checking agent activity",
  "spinner forever after reopening the app"); stale session lists or stale busy/turn
  state after resume; reconnect loops; "Failed to refresh the dashboard session";
  "Hermes connection closed" / "Hermes is not connected" errors; auth ticket expiry;
  wifi-to-cellular network flaps; server restarts; device sleep recovery; or any change
  to the reconnect/backoff/scenePhase/liveness logic. Key files — load this skill only
  when changing their reconnect/backoff/liveness behavior (general edits gate through
  conduit-architecture-contract): HermesClient.swift (transport, receiveLoop,
  onDisconnected), AppState.swift (handleDisconnect, scheduleReconnect, reconnect,
  handleScenePhase, syncSession, reconcile), DashboardTicketBridge.swift (mintTicket,
  cookie persistence), NativeAuthClient.swift (password fallback),
  ConnectionURLPolicy.swift (URL/origin rules). This skill also owns the canonical
  description of the reconnect machinery (Phase 1.1). This is a campaign skill: run
  its phases in order and do not skip gates.
---

# Conduit WebSocket Reliability Campaign

This is a phased, gated runbook for diagnosing and fixing WebSocket/session
reliability problems in Hermes Conduit (native SwiftUI iOS client, iOS 17+).
The user reports this as the hardest LIVE problem in the app (user-reported):
reconnects, stale sessions, auth ticket expiry, and resume-after-background.

Do NOT jump to a fix. Work the phases in order. Each phase ends with a gate:
a condition you must satisfy before proceeding. Every claim below about
current behavior cites `file:line` in this repo as of the commit noted in
Provenance. Anything not verifiable from client source is tagged
`[candidate -- unverified]`.

## Hard rules (non-negotiable, user-confirmed)

1. **No telemetry, analytics, or tracking. Ever.** Instrumentation in this
   campaign means local `os.Logger` output read via Console.app / `log stream`
   on the developer's own device. Never add any network-reporting of metrics.
2. **Never contact the Hermes gateway directly.** All RPC goes through the
   dashboard WebSocket endpoint (`/api/ws`, default dashboard port 9119)
   after dashboard auth. Any "fix" that opens a second channel to the gateway
   is out of bounds, full stop.

## Vocabulary (define once)

| Term | Meaning |
|---|---|
| Dashboard | The Hermes Agent native dashboard web server (default port 9119 per README.md:33). Conduit's only server contact point. |
| Gateway | The Hermes RPC process behind the dashboard. Conduit never talks to it directly (hard rule 2). |
| Ticket | Single-use WebSocket auth token minted by the dashboard via `POST /api/auth/ws-ticket`, passed as `?ticket=` query item on the `/api/ws` URL (HermesClient.swift:363-367; NativeAuthClient.swift:91-107). Single-use/TTL semantics are server-side [candidate -- unverified]. |
| Bridge | `DashboardTicketBridge`: an invisible WKWebView that holds the dashboard's HttpOnly session cookie and mints fresh tickets via in-page `fetch` (DashboardTicketBridge.swift:107-289). |
| Reconciliation | AppState's token-guarded resync of the active session: `session.resume` RPC + dashboard REST transcript, with stream events buffered during the fetch and replayed after (AppState.swift:187-196, 799-881, 3364-3370). |
| Turn state | `TurnState` enum (`synchronizing`, `idle`, `running`, `reconnecting`, `unsupportedGateway`) driving the composer; derived ONLY from the gateway's `running` field, never from transcript shape (Models.swift:380-413). |
| Epoch | `activeClientEpoch` UUID; stream/disconnect callbacks from a superseded client are dropped when the epoch does not match (AppState.swift:207, 650-667). |

---

## Phase 1: Instrument and reproduce

Read `Conduit/Services/HermesClient.swift` and `Conduit/Services/AppState.swift`
before touching anything. Then confirm the design below still matches (files
drift; the Provenance section has one-line re-verification greps).

### 1.1 The current reconnect design (verified against source)

**Division of labor.** HermesClient is deliberately thin: WebSocket transport
plus JSON-RPC request/response correlation only. ALL session state, busy
state, and reconnection logic lives in AppState (HermesClient.swift:7-13).

**Connection open.** `connect()` builds `wss://.../api/ws?ticket=...` via
`ConnectionURLPolicy.webSocketURL` (HermesClient.swift:361-367), sets
`URLSessionConfiguration.default` with `waitsForConnectivity = true`
(HermesClient.swift:372-373), and blocks on the URLSession delegate's
`didOpenWithProtocol` callback before declaring `isConnected = true` --
never before, because a just-opened socket can otherwise race its first
`session.resume` (HermesClient.swift:302-316, 388-390). Handshake timeout:
15 seconds (HermesClient.swift:398-408). RPC frames are sent as TEXT frames;
the gateway accepts but does not dispatch binary frames
(HermesClient.swift:661-665).

**Disconnect detection.** There is NO WebSocket ping/pong and NO liveness
timer anywhere in the client (verified by grep; no `sendPing` call exists).
The ONLY disconnect detector is `receiveLoop()`: when `socket.receive()`
throws, it sets `isConnected = false` and fires `onDisconnected` unless the
close was intentional (HermesClient.swift:434-458). A dead-but-not-closed
socket is therefore invisible until a receive or send fails, or an RPC times
out. RPC timeouts: 30s default, 180s for `prompt.submit`, 90s for title
generation (HermesClient.swift:347-349). `healthCheck()` is `session.list`
with an 8s timeout (HermesClient.swift:726-728).

**Reconnect state variables** (all in AppState):
- `reconnectTask: Task?` -- single scheduled reconnect; `scheduleReconnect`
  is a no-op while one is pending (AppState.swift:226, 1099-1110).
- `reconnectAttempts: Int` -- backoff exponent (AppState.swift:231).
- `connectedAt: Date?` -- if the previous connection lasted more than 10s,
  attempts reset to 0 on disconnect (AppState.swift:232, 1093-1095).
- `scenePhaseTask: Task?` -- the foreground recovery task (AppState.swift:225).
- `reconciliationToken` / `reconciliation` -- resync guards (AppState.swift:205-206).
- `activeClientEpoch` -- drops callbacks from replaced clients (AppState.swift:207).

**Backoff.** `delay = immediately ? 0.1 : min(5.0, pow(2.0, attempts))`,
attempts incremented per non-immediate schedule (AppState.swift:1099-1102).
So: 1s, 2s, 4s, then capped at 5s forever. There is NO jitter. If a turn was
running at disconnect (`wasRunning`), the first reconnect is immediate
(0.1s) (AppState.swift:1087-1097).

**reconnect() sequence** (AppState.swift:1112-1182):
1. Mint a FRESH ticket through `dashboardTicketBridge.mintTicket()` and
   persist the new connection to Keychain (1119-1124). Ticket refresh before
   reconnect is already implemented -- do not re-invent it.
2. On `signInRequired`: if saved credentials exist for the same base URL,
   silently re-login via `NativeAuthClient.connect` (REST password login +
   ws-ticket mint, NativeAuthClient.swift:109-112), `bridge.reload()` so
   WebKit receives the fresh URLSession cookie (URLSession and WebKit have
   SEPARATE cookie stores, AppState.swift:1134-1136), and re-enter
   `connect()`. If that fails too, `requireSignIn` returns the user to
   login (1126-1147).
3. On any other mint error: set `errorMessage`
   ("Failed to refresh the dashboard session: ..."), stay in `.reconnecting`,
   and `scheduleReconnect()` (1148-1154).
4. Build a new HermesClient (new epoch), disconnect the old one, connect;
   on success reset attempts, then `syncSession()`, busy mode, profiles,
   slash commands (1158-1174). On failure, `scheduleReconnect()` (1175-1181).

**scenePhase handling** (wired in RootView.swift:33-34; logic at
AppState.swift:1184-1219):
- `.active`: if a client exists and reports `isConnected`, run
  `healthCheck()` (session.list @8s). Success -> `syncSession()`. Throw ->
  `reconnect()`. No client or not connected -> `reconnect()` (1186-1202).
- `.background`: `invalidateReconciliation()` (a suspended socket may still
  look open; incomplete snapshots must not survive to foreground) and cancel
  `scenePhaseTask` (1204-1210). The socket is NOT closed on backgrounding.
- `.inactive`: voice-only bookkeeping, nothing socket-related (1212-1214).

**syncSession() -- the single resync entry point** (AppState.swift:734-784).
"The only entry point for cold start, foreground refresh, reconnect, and
manual refresh. It never derives liveness from transcript shape." Sequence:
token-guard, fetch session catalog, pick saved-or-newest session, then
`reconcile()` which runs `session.resume` (params `session_id`, `cols: 96`,
`source: "desktop"`, HermesClient.swift:730-735) concurrently with the
dashboard REST transcript `GET /api/sessions/{id}/messages`
(AppState.swift:804-818, 2199-2235). Turn state comes exclusively from
`snapshot.running` (`nil` -> `.unsupportedGateway`, Models.swift:395-398;
AppState.swift:996-1002). Stream events arriving mid-reconcile are buffered
and replayed after the snapshot applies (AppState.swift:866-868, 3364-3370).
Note the early return: if a push-notification target is pending,
`syncSession` does nothing (AppState.swift:741, 760).

**Stale runtime session IDs.** Hermes can rotate the runtime session while
the app is backgrounded. The send path handles `"session not found"` RPC
errors by running `syncSession()` once and retrying against the recovered
runtime id (AppState.swift:2016-2027, 2074-2076).

**Cold start.** `loadSavedConnection()` tries Keychain credentials first
(re-login mints a fresh ticket), else the saved connection -- whose stored
ticket may already be consumed/expired; a failed connect then routes through
the normal `scheduleReconnect -> reconnect -> fresh ticket` path
(AppState.swift:535-549, 597-608, 669-677). A connect failure never bounces
to the login screen; only an explicit dashboard 401/403 does
(AppState.swift:603-607, DashboardTicketBridge.swift:368-371).

**Ticket minting details** (DashboardTicketBridge.swift): `mintTicket()`
waits for bridge readiness (30 x 100ms polls, 153-178), POSTs
`/api/auth/ws-ticket` via in-page fetch, and retries up to 3 times with
`reload()` + 350ms sleep on `signInRequired`, because a freshly restored
cookie can reach WebKit's cookie store before its network process (153-171).
Readiness = the WebView finished loading `/api/status` without landing on a
`/login` path (278-282, 313-333). Dashboard cookies are mirrored to Keychain
and restored on cold launch (19-88). Origin checks use
`ConnectionURLPolicy.originMatches`; WKSecurityOrigin reports port 0 for
default ports and `effectivePort` maps 0 -> scheme default -- a literal port
comparison once silently dropped all bridge responses (stuck on
Synchronizing), fixed in d0873ec; full mechanism in
conduit-failure-archaeology entry 1.

### 1.2 Instrumentation (local only)

All logging is `os.Logger`, subsystem `com.milim.conduit`. Categories:
`HermesClient` (HermesClient.swift:323), `SessionCatalog` and
`TitleGeneration` (AppState.swift:15-16).

On a Mac with the device connected (do not add any new network reporting):

```bash
# Live tail while reproducing on device
log stream --predicate 'subsystem == "com.milim.conduit"' --level debug

# After the fact
log show --last 30m --predicate 'subsystem == "com.milim.conduit"'
```

Landmark log lines to watch for (exact strings from source):
- "WebSocket handshake completed" (HermesClient.swift:390)
- "WebSocket receive failed: ..." (HermesClient.swift:450) -- the ONLY
  disconnect detection signal
- "Sending RPC id N method M" / "Received RPC response id N"
  (HermesClient.swift:647, 472)
- "Dropped undecodable inbound WebSocket frame" (HermesClient.swift:462)

If these are insufficient, add TEMPORARY `logger.notice` lines in
`handleDisconnect`, `scheduleReconnect`, `reconnect`, `handleScenePhase`,
and `DashboardTicketBridge.mintTicket` -- and remove them before promoting
any fix (route the removal through conduit-change-control like any change).

### 1.3 Canonical repro scenarios

Run each scenario against a real dashboard (see conduit-run-and-operate for
server setup). For each: the EXPECTED behavior per the code above, and the
branch to take if you observe something else.

| # | Scenario | How to reproduce | Expected behavior per code | If you observe X instead -> branch |
|---|---|---|---|---|
| S1 | Background > 5 min, then foreground | Home button, wait >5 min (past iOS suspension), reopen | `.background` invalidated reconciliation (AppState.swift:1209). On `.active`: healthCheck (8s cap). If socket died in suspension, healthCheck throws -> `reconnect()` -> fresh ticket -> connect -> `syncSession()`. Fresh list + correct turn state within roughly 10s worst case. | Spinner/"Checking agent activity..." for ~8s then recovery = working as designed but slow (Phase 3 option R2). Stuck indefinitely -> Phase 2 test C or D. Old sessions shown, no refresh -> Phase 2 test B. |
| S2 | Network flap (wifi -> cellular) | Foreground, toggle wifi off mid-idle and mid-turn | `waitsForConnectivity = true` (HermesClient.swift:373) means URLSession may STALL rather than fail; `receive()` may not throw promptly. Eventually receive/send fails -> `handleDisconnect` -> backoff reconnect (immediate if a turn was running). | Long silent stall with `isConnected` still true and no "WebSocket receive failed" log -> Phase 2 test A (undetected socket death). |
| S3 | Server restart | Restart Hermes/dashboard process while app foregrounded | Socket closes -> receive throws -> `handleDisconnect` -> reconnect loop. While the server is down, `mintTicket` fails -> "Failed to refresh the dashboard session" + retry at <=5s cap (AppState.swift:1148-1154). Recovers within ~5s of the server returning. | Never recovers after server is back -> Phase 2 test C (bridge stuck not-ready or WebView parked on error page; check `reload()` path). Recovers but composer stuck synchronizing -> Phase 2 test B/D. |
| S4 | Ticket / dashboard session expiry | Expire the dashboard HttpOnly session server-side (or wait it out), then force a reconnect (S1 or S3) | `mintTicket` gets 401/403 -> `signInRequired` -> up to 3 bridge retries -> saved-credentials silent re-login via NativeAuthClient -> `bridge.reload()` -> full `connect()`. Only if that fails: login screen with error message (AppState.swift:1126-1147). Server-side expiry windows are [candidate -- unverified]. | Reconnect loop that never escalates to re-login -> Phase 2 test C. Login screen despite valid saved credentials -> check base-URL trim comparison at AppState.swift:1128. |
| S5 | Device sleep / lock overnight | Lock the device with the app foregrounded; unlock hours later | Same as S1: suspension kills or wedges the socket; `.active` fires healthCheck -> reconnect path. Also exercises cold-relaunch if iOS jetsams the app: `loadSavedConnection` (AppState.swift:535-549) with a possibly stale saved ticket -> failed connect -> scheduled reconnect mints fresh ticket. | App relaunches to login screen -> Keychain/cookie restore failure; check DashboardCookiePersistence (DashboardTicketBridge.swift:56-88) before blaming reconnect logic. |

**GATE 1:** You have (a) confirmed the design description above against the
current source (or updated it), and (b) reproduced the reported failure in
at least one scenario with a captured `log stream` trace. If you cannot
reproduce, stop and gather a device sysdiagnose/log from the user; do not
fix blind.

---

## Phase 2: Diagnose -- separate the four failure classes

The same user-visible symptom ("app looks stale/stuck after resume") has at
least four distinct causes. Run the discriminating experiments until exactly
one class is confirmed by its stated observation.

### A. Socket-level death not detected

Theory: TCP is gone but `receive()` has not thrown, so `isConnected` is
still true and no reconnect is scheduled. Enabled by the lack of ping/pong
and by `waitsForConnectivity = true` (HermesClient.swift:373, 434-458).

Experiment: while symptomatic, trigger any RPC (pull-to-refresh calls
`refreshActiveSession` -> `reconcile`, AppState.swift:1471-1479; or
foreground-cycle to force healthCheck).

Confirming observation: `log stream` shows "Sending RPC id N ..." with NO
"Received RPC response id N", followed ~8s or ~30s later by
"Request timed out: <method>" -- and only THEN a reconnect. No
"WebSocket receive failed" line appeared at the moment connectivity was
actually lost.

### B. Socket alive but session state stale

Theory: transport is fine; the client simply never re-fetched. Candidate
paths: `syncSession` early-returned because a push target was pending
(AppState.swift:741, 760); the reconciliation token was superseded mid-sync
(756-759, 777-780); or the foreground healthCheck succeeded but a later step
threw and left `.reconnecting` with `errorMessage`
"Failed to load gateway sessions" (776-783).

Experiment: while symptomatic, check whether a plain RPC works: open the
model picker or pull-to-refresh. Watch SessionCatalog logs.

Confirming observation: RPCs round-trip instantly (Sending/Received pairs in
the log) yet the sessions list / turn state remains old, or `errorMessage`
shows the "Failed to load gateway sessions"/"Failed to restore this
conversation" strings from AppState.swift:782/878.

### C. Auth expiry so reconnect loops (or dies quietly)

Theory: the socket is being rebuilt but every attempt fails at ticket mint:
dashboard session cookie expired, bridge WebView stuck (not ready, parked on
/login, or navigated off-origin), or origin matching rejecting responses (the
d0873ec class of bug).

Experiment: trigger reconnect (S3/S4) and watch the error surface plus the
bridge. Optionally add a temporary log in
`DashboardTicketBridge.userContentController` and `didFinish` to print
`webView.url` and `isReady`.

Confirming observation: repeated
"Failed to refresh the dashboard session: ..." error banners at ~5s cadence
(AppState.swift:1152), or `mintTicket` throwing `signInRequired` on all 3
attempts, or `waitUntilReady` timing out ("The dashboard session is still
loading.", DashboardTicketBridge.swift:97-98, 173-178). If responses are
being POSTed by the page but never resumed in Swift, suspect origin matching
(ConnectionURLPolicy.swift:120-142) -- the exact d0873ec failure mode.

### D. UI not re-rendering despite fresh state

Theory: AppState holds correct data but the view tree does not reflect it.
Candidate mechanisms in this codebase: stream events dropped by the epoch
guard after a client swap (AppState.swift:654-665), events buffered under a
reconciliation that never completes (3364-3370 with 866-868 never reached),
or the sidebar-open streaming publish suppression (126-144).

Experiment: log the value of `turnState` / `sessions.count` inside AppState
at the moment of symptom (temporary print), and compare with what is on
screen. Backgrounding/foregrounding once more forces a fresh reconcile.

Confirming observation: logged state is fresh and correct while the screen
disagrees; or buffered-events list grows while `reconciliation` is non-nil
and no "reconcile finished" path ran.

**GATE 2:** Exactly one class (A-D) is confirmed by its stated observation,
with a log excerpt you can quote. If two seem true, the outer one wins
(A masks B; C masks A): fix the outermost first and re-run Phase 1
scenarios before continuing.

---

## Phase 3: Solution menu (ranked proposals)

Everything here is a **proposal**, not current behavior. Each entry lists
its theory obligation (what the Phase 2 diagnosis must have shown for this
to be the right fix) and blast radius. Route any chosen change through
conduit-change-control before implementation.

### Fenced-off wrong paths -- do not attempt

- **Contacting the gateway directly** (any host/port other than the
  dashboard base URL): FORBIDDEN by hard rule 2. No side channels, no
  "gateway health endpoint" probes.
- **Background keepalive / background ping timers**: not possible. iOS
  suspends the app shortly after `.background`; timers stop, sockets are
  frozen, and code does not run. This is why `.background` handling only
  invalidates local state (AppState.swift:1204-1210) instead of pretending
  to keep the socket alive. `beginBackgroundTask` buys ~seconds, not
  minutes; BGTaskScheduler gives no timing guarantees. A battery-burning
  keepalive is both impossible under suspension and contrary to the app's
  design. Recovery must be foreground-driven (scenePhase) plus push
  notifications for attention while backgrounded.
- **Deriving turn state from the transcript** ("last message is from
  assistant so it must be idle"): explicitly rejected design; `running`
  from the gateway is the only source (AppState.swift:5-7, Models.swift:377-379,
  HermesClient.swift:15-20).
- **Adding any telemetry/metrics upload** to "measure reliability in the
  field": FORBIDDEN by hard rule 1. Measure locally in Phase 4.
- **Merging gateway RPC `session.list` into the UI list to "freshen" it**:
  it reads the main DB across ALL profiles (HermesClient.swift:21-22);
  profile scoping is already handled -- do not bypass it.

### R1. Ping-based liveness with timeout (fixes class A)

Proposal: while FOREGROUNDED, call `URLSessionWebSocketTask.sendPing`
every N seconds (e.g. 20-30s); if the pong callback does not arrive within
a timeout (e.g. 10s), treat the socket as dead: set `isConnected = false`
and fire `onDisconnected` so the existing AppState machinery takes over.
Cancel the ping timer on `.background` (it cannot run there anyway) and on
`disconnect()`.

Theory obligation: Phase 2 confirmed A -- RPCs hang on a socket the client
still believes is connected.

Blast radius: HermesClient only (new timer + cancellation in
`connect`/`disconnect`); AppState untouched because it reuses
`onDisconnected`. Risk: false-positive disconnects on slow links causing
churn -- mitigate with a generous timeout and by keeping the existing
"attempts reset after 10s connected" rule (AppState.swift:1093-1095).

### R2. Proactive teardown on background / reconnect-first on foreground (fixes A and shrinks S1 latency)

Proposal: on `.background`, in addition to invalidating reconciliation,
explicitly `client?.disconnect()` (intentional close suppresses
`onDisconnected`, HermesClient.swift:614-632) and clear `isConnected`.
On `.active`, skip the 8s healthCheck gamble and go straight to
`reconnect()` (which already mints a fresh ticket and full-resyncs).

Theory obligation: S1/S5 show multi-second foreground stalls caused by
healthCheck timing out against a suspended-then-dead socket.

Blast radius: AppState.handleScenePhase and background/foreground UX.
Cost: brief `.inactive` flips (notification shade, app switcher, Face ID
prompts) would tear down a healthy socket -- so key the teardown on
`.background` only, never `.inactive`, and accept one extra
ticket-mint + connect per foreground. Weigh against the bridge readiness
wait (up to 3s, DashboardTicketBridge.swift:173-178). A hybrid keeps
healthCheck but drops its timeout to ~2s.

### R3. Guarantee resync always lands (fixes class B)

The full state resync already exists: `syncSession()` (catalog +
`session.resume` + REST transcript). There is no separate "resync RPC" in
the protocol beyond `session.resume` (verified across HermesClient's RPC
surface). Proposal: audit and close the paths where a foreground resync can
be silently skipped or half-finished:
- pending push target early-return (AppState.swift:741, 760): after the
  notification route completes or fails, ensure a follow-up `syncSession()`
  runs (see ConduitApp.swift:73-80 for the routing task).
- error paths that leave `.reconnecting` with only an errorMessage
  (AppState.swift:776-783, 871-880): schedule a retry instead of parking.

Theory obligation: Phase 2 confirmed B with a specific skipped/failed path
identified in the log.

Blast radius: AppState reconciliation flow; touches the push-navigation
contract (cross-check conduit-run-and-operate's notification section).

### R4. Cold-start ticket refresh (shrinks S5 relaunch failures)

Proposal: `restoreSavedConnection` currently retries the SAVED ticket
first and only mints a fresh one after that connect fails
(AppState.swift:669-677, 597-608). If the ticket is truly single-use
[candidate -- unverified server behavior], the first cold-start connect is
often doomed. Change: when credentials exist, they already take priority
(535-537); for the connection-only path, attempt `mintTicket()` first with
a short readiness budget and fall back to the saved ticket if the bridge is
not ready.

Theory obligation: cold-launch traces show the first connect consistently
failing with a handshake close and succeeding on the first scheduled
reconnect.

Blast radius: launch latency (bridge readiness wait) vs. one wasted
connect. Low risk otherwise; the fallback preserves today's behavior.

### R5. Backoff jitter and cap tuning (hygiene; fixes thundering-herd only)

Proposal: change `min(5.0, pow(2.0, attempts))` (AppState.swift:1101) to
add +/-30% random jitter and consider a higher cap (e.g. 15-30s) for the
server-down case so the app does not hammer a recovering server every 5s
forever.

Theory obligation: only worth it if S3 shows sustained tight retry loops
that matter (single-user self-hosted servers rarely herd). Do NOT let this
slow the first reconnect: keep the immediate-when-running rule
(AppState.swift:1096).

Blast radius: one line plus tests; user-visible recovery latency.

### R6. Bridge/origin hardening (fixes class C)

Proposal, in order of likelihood: (a) if `waitUntilReady` timeouts recur,
extend `mintTicket`'s retry to also handle `notReady` with a `reload()`
(today only `signInRequired` retries, DashboardTicketBridge.swift:165-168);
(b) if origin-matching drops responses on some deployment (reverse proxies,
nonstandard ports), fix `ConnectionURLPolicy` with a regression test --
this is the d0873ec lesson: a silent origin mismatch presents as "stuck on
Synchronizing" with zero errors; (c) surface bridge state in the diagnostics
UI (cross-ref conduit-diagnostics-and-tooling).

Theory obligation: Phase 2 confirmed C with the specific bridge state
(not-ready vs. signInRequired vs. dropped-response) identified.

Blast radius: auth path -- the most historically fragile area of the app
(user-reported: the WKWebView auth bridge is a top-3 past failure source).
Test on both password-login and cookie-only dashboards, HTTP-localhost and
HTTPS-remote, default and explicit ports.

**GATE 3:** One (or an explicitly ordered set) of R1-R6 chosen, with the
Phase 2 evidence quoted next to its theory obligation. Written change plan
routed through conduit-change-control. No implementation before this gate.

---

## Phase 4: Validate and promote

Never judge a reliability fix by eye. Define the pass criteria numerically
BEFORE implementing, then run the trials on a physical device (simulator
backgrounding does not faithfully reproduce suspension).

### Success criteria (adapt N to the scenario; defaults below)

| Scenario | Criterion | Trials |
|---|---|---|
| S1 resume after 30-min background | Fresh session list AND correct turn state visible within 5s of foreground, zero user action | 10/10 |
| S2 wifi->cellular flap mid-turn | Streaming resumes or turn state re-syncs within 10s; no lost/duplicated final message vs. `session.resume` transcript | 10/10 |
| S3 server restart | Auto-recovery within 10s of server availability; at most one error banner | 10/10 |
| S4 expired dashboard session | Silent re-login succeeds when credentials saved; explicit login screen (not a loop) when not | 5/5 each |
| S5 overnight lock | Same as S1 on unlock; cold relaunch lands connected without login screen | 5/5 |
| Regression | No new `.unsupportedGateway` states against a current gateway; profile-scoped lists unchanged | all runs |

Log-based measurement only (hard rule 1): timestamp deltas between the
`.active` transition (add a temporary local log) and the first post-resync
publish. Remove temporary logs before merging.

### Tests to add (cross-ref conduit-validation-and-qa)

Existing test targets live in `ConduitTests/` (TurnStateTests,
MessageNormalizerTests, SecurityBoundaryTests, etc.). Reliability changes
should add, at minimum:
- Backoff unit tests: sequence 1,2,4,5,5 today; jittered bounds if R5.
- `TurnState.fromGatewayRunning` and reconcile-token invalidation coverage
  (extend TurnStateTests).
- `ConnectionURLPolicy.originMatches`/`effectivePort` regression cases
  including port 0, explicit ports, and scheme defaults (guards the d0873ec
  class; extend SecurityBoundaryTests).
- `AppState.unpersistedInflightAssistantText` edge cases if the resume
  projection logic is touched (AppState.swift:1009-1029).
Pure lifecycle behavior (scenePhase, real sockets) is validated by the
manual trial matrix above, not unit tests -- record the trial results in
the change-control entry.

### Promotion

- Route the diff through conduit-change-control (review gates, rollback
  notes). Reliability code touches connect/auth paths that previously
  caused release-blocking failures (user-reported App Store history:
  see conduit-appstore-and-signing and conduit-failure-archaeology).
- Update THIS skill's Phase 1 design description and Provenance run log in
  the same change -- the design section must always describe the code as
  it is, not as it was.

---

## When NOT to use this skill

| Situation | Use instead |
|---|---|
| First-time connection setup, wrong URL/port, HTTPS-vs-HTTP errors, push notification setup, profile switching | conduit-run-and-operate |
| What a specific RPC method/event means, protocol field shapes | hermes-protocol-reference |
| Layering rules, who-owns-what between HermesClient and AppState, invariants | conduit-architecture-contract |
| General bug triage that is not WS/session reliability | conduit-debugging-playbook |
| Past incidents and their fixes (including d0873ec context) | conduit-failure-archaeology |
| Voice/audio session conflicts (AVAudioSession, wake word) | conduit-voice-pipeline |
| Building, signing, simulators, xcodegen | conduit-build-and-env / conduit-appstore-and-signing |
| Writing/running the test suite in general | conduit-validation-and-qa |
| Approving and landing the change itself | conduit-change-control |

---

## Provenance and maintenance

Ground truth verified by reading source at commit 859162b (branch main).
All `file:line` cites are relative to repo root
`/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`.

### One-line re-verification commands

```bash
# Repo state the cites were made against
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log --oneline -1

# No ping/pong exists (should return nothing)
grep -rn "sendPing" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit

# Disconnect detection is receive-failure only
grep -n "WebSocket receive failed\|onDisconnected" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift

# waitsForConnectivity + handshake gate + text frames
grep -n "waitsForConnectivity\|didOpenWithProtocol\|socket.send(.string" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift

# Timeouts (30/180/90 and healthCheck 8s)
grep -n "requestTimeout\|promptSubmitTimeout\|titleGenerationTimeout\|timeout: 8" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift

# Backoff formula, immediate-when-running, 10s attempt reset
grep -n "pow(2.0\|immediately: wasRunning\|timeIntervalSince(connectedAt) > 10" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift

# scenePhase handling and wiring
grep -n "func handleScenePhase" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift
grep -n "handleScenePhase" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Views/RootView.swift

# reconnect() mints ticket first; credential fallback; requireSignIn
grep -n "mintTicket\|requireSignIn\|NativeAuthClient(baseURL" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift

# mintTicket retry loop and readiness wait
grep -n "for attempt in 0..<3\|waitUntilReady\|milliseconds(350)" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/DashboardTicketBridge.swift

# syncSession is the single resync entry point; push-target early return
grep -n "func syncSession\|pendingTarget == nil" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift

# session.resume params and turn-state source of truth
grep -n "session.resume\|fromGatewayRunning" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Models/Models.swift /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift

# Stale runtime-id retry on send
grep -n "isSessionNotFound\|retriedAfterResume" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift

# d0873ec port-0 fix still present
grep -n "port 0\|port, port > 0" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/ConnectionURLPolicy.swift
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit show d0873ec --stat

# Log subsystem/categories
grep -rn 'subsystem: "com.milim.conduit"' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit | cut -d: -f1,3

# Test files available for extension
ls /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/ConduitTests/
```

### Run log

- 2026-08-08 (build): initial authoring
