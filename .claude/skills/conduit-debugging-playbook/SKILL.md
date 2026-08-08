---
name: conduit-debugging-playbook
description: >
  Symptom-to-triage runbook for Hermes Conduit (native SwiftUI iOS client for the
  self-hosted Hermes Agent dashboard). Load this skill when a user or tester reports:
  login fails or loops back to the login screen; the app hangs on "Synchronizing";
  ticket minting fails (DashboardTicketBridge, mintTicket, signInRequired); WebSocket
  drops, never reconnects, or shows "Reconnecting" forever (HermesClient, AppState
  reconnect); session list or busy state is stale after backgrounding/resume
  (scenePhase, syncSession); push notifications never arrive (PushNotificationService,
  relay pairing, push.milim.dev); voice mode is silent or stuck (AVAudioSession,
  wake word); the dashboard URL is rejected at login (ConnectionURLPolicy,
  "Remote dashboards must use HTTPS"); or attachments fail to send or render
  (DataURLLimits, image.attach_bytes). This skill owns symptom triage. For
  EDITING DashboardTicketBridge.swift, NativeAuthClient.swift, HermesClient.swift,
  ConnectionURLPolicy.swift, PushNotificationService.swift, or AppState reconnect
  code, the primary gate is conduit-architecture-contract; load this playbook
  alongside it only when a live symptom is being chased.
---

# Conduit Debugging Playbook

Triage runbook for the real failure modes of this app. Every claim below was
verified against source on 2026-08-08 unless tagged `[candidate -- unverified]`.
Line numbers are from that date and will drift; the greps in
"Provenance and maintenance" re-locate everything.

## Glossary (define once, used everywhere below)

| Term | Meaning in this codebase |
|---|---|
| Dashboard | The Hermes Agent web dashboard the phone connects to. Default port 9119 (README.md:33,42). Conduit talks ONLY to the dashboard, never to the Hermes gateway process directly (hard rule). |
| Gateway | The Hermes agent runtime behind the dashboard. Conduit reaches it exclusively via JSON-RPC over the dashboard WebSocket `/api/ws`. |
| Ticket | WebSocket auth token minted by `POST /api/auth/ws-ticket`, passed as `?ticket=` query on the `/api/ws` URL (HermesClient.swift:363-366). Treated as single-use by the client (fresh ticket per (re)connect); server-side single-use/TTL enforcement is [candidate -- unverified]. |
| Bridge | `DashboardTicketBridge`: a hidden 1x1 `WKWebView` (RootView.swift:25-29) that holds the dashboard's HttpOnly session cookie and mints fresh tickets via in-page `fetch()`. |
| Native auth | `NativeAuthClient`: plain URLSession password login (`POST /auth/password-login`, body `{"provider":"basic","username":...,"password":...}`) for dashboards that report `supports_password` (NativeAuthClient.swift:72-89). |
| Profile | A Hermes workspace scope. `HermesClient.scopeParams` injects `"profile"` into every RPC unless the profile is `"default"` (HermesClient.swift:684-690). |
| turnState | `TurnState` (Conduit/Models/Models.swift:380-385): `.synchronizing / .idle / .running / .reconnecting / .unsupportedGateway`; drives the composer (AppState.swift:92 switches over it). "Stuck on Synchronizing" / "Checking agent activity" map to `.synchronizing` / `.reconnecting`; `.unsupportedGateway` is the "gateway too old" composer-lock state. |
| syncSession | `AppState.syncSession()` (AppState.swift:736): the ONLY entry point for cold start, foreground refresh, reconnect, and manual refresh. Never derives liveness from transcript shape. |

## Hard rules (never route around these)

1. No telemetry, analytics, or tracking. Ever. Do not add "diagnostics uploads" as a debugging aid.
2. All RPC goes through the dashboard WebSocket `/api/ws` after dashboard auth. Never add a direct gateway connection, even "temporarily for debugging".

## Architecture in one paragraph (what you must know to triage)

`HermesClient` is deliberately thin: WebSocket transport + JSON-RPC id
correlation only. It has NO reconnect, NO backoff, and NO ping/heartbeat timer
(verified: zero matches for `ping` in HermesClient.swift). All reconnection,
session state, and busy state live in `AppState` (HermesClient.swift:7-13 header
comment). Auth is two-layered: cookie-based dashboard session (WebKit, inside
the bridge; mirrored to Keychain by `DashboardCookiePersistence`) mints
short-lived tickets; the ticket opens the socket. So "login" bugs split into
bridge/cookie bugs vs. socket/ticket bugs -- the discriminating experiments
below separate them.

## Master symptom table

| # | Symptom | First check | Owner section |
|---|---|---|---|
| 1 | Login fails / bounces back to login | LoginView.swift:174 `connect()` | Login failures |
| 2 | Stuck on "Synchronizing"; ticket mint hangs | DashboardTicketBridge.swift:153 `mintTicket` | Ticket bridge hangs |
| 3 | "Reconnecting" forever; socket drops silently | AppState.swift:1087-1182 | WebSocket drops |
| 4 | Stale sessions/busy state after resume | AppState.swift:1184 `handleScenePhase` | Stale after resume |
| 5 | Push notifications never arrive | PushNotificationService.swift:47-53 | Push not arriving |
| 6 | Voice silent or stuck | AppState.swift:3848-3862 gating messages | Voice triage |
| 7 | URL rejected at login | ConnectionURLPolicy.swift:29 `normalizedBaseURL` | URL rejected |
| 8 | Attachment fails / image not rendered | DataURLLimits.swift; AppState.swift:1609-1628 | Attachments |

---

## 1. Login fails / bounces back to login

Flow (LoginView.swift:174-211): normalize URL -> `GET /api/auth/providers` ->
if no provider has `"supports_password": true`, fall back to an OAuth web view
(`AuthWebView`, which returns a ticket directly) -> else
`POST /auth/password-login` then `POST /api/auth/ws-ticket` -> `appState.connect`.

| Check | How |
|---|---|
| URL normalization rejected it first? | See section 7. Error text "Remote dashboards must use HTTPS; HTTP is allowed only for localhost" comes from ConnectionURLPolicy, not the server. |
| Provider discovery failed? | Error prefix "Could not check dashboard sign-in options:" = `authProviders()` failed (NativeAuthClient.swift:33-34,56-70). Server unreachable or non-2xx. |
| Password rejected? | Error prefix "Login failed:" = non-2xx from `/auth/password-login` (NativeAuthClient.swift:86-88). Server-side detail is parsed from `detail`/`error`/`message` JSON keys. |
| Ticket mint rejected after good login? | Error prefix "Could not get session ticket:" (NativeAuthClient.swift:98-106). |
| Unexpected OAuth web view appeared? | Providers list lacked `supports_password == true` (LoginView.swift:190). The dashboard may legitimately be OAuth-only. |
| Saved credentials silently failing on relaunch? | `restoreSavedCredentials` (AppState.swift:679-702): a rejected saved password shows login WITHOUT erasing credentials. Face ID gate failure also lands on login. |

Discriminating experiment: from a Mac on the same network, replay the exact
calls:

```bash
curl -sk https://YOUR-DASHBOARD:9119/api/auth/providers
curl -sk -X POST https://YOUR-DASHBOARD:9119/auth/password-login \
  -H 'Content-Type: application/json' \
  -d '{"provider":"basic","username":"U","password":"P"}' -c /tmp/cj -o /dev/null -w '%{http_code}\n'
curl -sk -X POST https://YOUR-DASHBOARD:9119/api/auth/ws-ticket -b /tmp/cj
```

If curl succeeds but the app fails, suspect `SecureRedirectDelegate`
(NativeAuthClient.swift:130-147): it CANCELS any redirect that leaves the
origin or uses a disallowed transport. A dashboard that redirects login through
another host/port will break native login here by design.

Fix pointers: server-side auth config is out of client scope
(hermes-protocol-reference). Do not weaken `SecureRedirectDelegate`.

## 2. Ticket bridge hangs / stuck on "Synchronizing"

The bridge loads `BASE/api/status` in the hidden web view
(DashboardTicketBridge.swift:278-281). On `didFinish`, `isReady = true` only if
the final URL is same-origin AND its path does not contain `/login`
(DashboardTicketBridge.swift:313-333). `mintTicket()` makes up to 3 attempts;
on `signInRequired` it reloads and sleeps 350 ms (lines 153-171).
`waitUntilReady` polls 30 x 100 ms, then throws `.notReady` (lines 173-178) --
so a dead bridge fails in about 3 seconds, it does not hang forever.
`requestJSON` runs an in-page `fetch()` with `credentials: 'include'`, a
configurable timeout (default 12 s) and a streamed response cap
(`DataURLLimits.maxJSONResponseBytes` = 24 MB), posting results back through the
`dashboard-response` script message handler.

| Symptom detail | Diagnosis |
|---|---|
| "The dashboard session is still loading." | `.notReady`: web view never reached a non-login same-origin page. Cookie missing/expired, or `/api/status` navigation failed. |
| "Dashboard sign-in has expired." | Bridge saw the login redirect, or a request returned 401/403 (lines 322-324, 368-371). Reconnect then falls back to saved password credentials (AppState.swift:1126-1147) before `requireSignIn`. |
| Stuck on Synchronizing, no error, forever | The historical signature of the script-message origin check silently swallowing responses -- see the WKSecurityOrigin trap below. Continuations in `pendingRequests` are only resumed by that handler. |
| "Dashboard navigation left the configured origin." | Main-frame navigation moved off the configured base URL (lines 316-320). Check for dashboard-side redirects. |

Discriminating experiment: temporarily raise WebKit visibility by checking
`webView.url` at the moment of failure (breakpoint in
`webView(_:didFinish:)`). If `url.path` ends in `/login`, it is a cookie
problem (WebKit vs URLSession cookie stores are SEPARATE; native password
login copies cookies via `DashboardCookiePersistence.restoreNativeCookies`,
DashboardTicketBridge.swift:67-73). If the page is right but `mintTicket`
still fails, put a breakpoint in `userContentController(_:didReceive:)`
(line 347) -- if it never fires or the guard falls through, the origin check
is eating the response.

### User-reported trap: the WKSecurityOrigin port-mismatch class of bug

WKSecurityOrigin reports port 0 for default-port connections; a literal port
comparison silently dropped all bridge responses (stuck on "Synchronizing") —
fixed in `d0873ec`, full mechanism in `conduit-failure-archaeology` entry 1.

Lesson for any future guard in this handler: a failed guard here does not
throw -- it silently strands a `CheckedContinuation`. When you touch the origin
check, add a temporary `else { logger... }` branch and test BOTH a
default-port HTTPS dashboard and an explicit-port one (`https://host` and
`http://localhost:9119`).

Mine the fix any time:
`git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log -p d0873ec`

## 3. WebSocket drops or never reconnects

Where the logic lives: the canonical, line-cited description of the reconnect
machinery (open/frames/drop detection in HermesClient; backoff
`min(5.0, 2^attempts)`, attempt reset, fresh-ticket-per-reconnect,
credential fallback, scenePhase health check in AppState) is
`conduit-ws-reliability-campaign` Phase 1.1. Key entry points for breakpoints:
`AppState.reconnect()` (1112), `handleDisconnect` (1087),
`handleScenePhase` (1184), `HermesClient.receiveLoop` (434-458). There is NO
ping timer; a half-dead socket is only detected on the next send/receive or
foreground health check.

Triage:

| Symptom | Discriminating experiment |
|---|---|
| "Reconnecting" forever | Breakpoint in `AppState.reconnect()` (line 1112). If it loops through the `catch` at line 1125 with a bridge error, it is really a section-2 problem (ticket minting), not the socket. |
| Never reconnects at all | Check `connection != nil` and `reconnectTask == nil` guards (line 1100). A cancelled-but-not-nilled `reconnectTask` would block scheduling; also confirm `onDisconnected` fired (epoch guard, line 660-664). |
| Drops only when phone locks/backgrounds | Expected: iOS suspends sockets. Recovery is the scenePhase path (section 4), not the backoff path. |
| RPC timeouts while "connected" | Half-open socket. `healthCheck()` is `session.list` with an 8 s timeout (HermesClient.swift:726-728); run it manually from the debugger to confirm. |

Deep-dive and campaign history: see `conduit-ws-reliability-campaign` (this is
the user-reported hardest live problem area). Protocol payloads: see
`hermes-protocol-reference`.

## 4. Stale session list / stale busy state after resume

Wiring: `RootView` observes `scenePhase` and calls
`appState.handleScenePhase` (RootView.swift:33-35 -> AppState.swift:1184-1219).

- `.active`: if the client claims connected, run `healthCheck()`; on success
  `syncSession()`, on ANY failure `reconnect()`. If not connected, `reconnect()`.
- `.background`: `invalidateReconciliation()` (a suspended socket may still
  look open; incomplete snapshots are discarded so foreground always fetches a
  fresh authoritative one), cancel `scenePhaseTask`, stop voice foreground mode.
- `.inactive`: only voice foreground flag flips.

`syncSession` (AppState.swift:736-784) refuses to run while a push
notification target is pending (`PushNotificationService.shared.pendingTarget`,
checked BOTH before and after the catalog fetch, lines 741 and 760) -- a stuck
`pendingTarget` therefore blocks all session refresh. It fetches the
profile-scoped session list, then `reconcile()` runs `session.resume`
concurrently with the dashboard REST transcript fetch; the resume RPC is
authoritative for liveness (`running`), the REST transcript for timestamps
(lines 799-869). Events arriving mid-reconcile are buffered and replayed
(line 866-868).

| Symptom | Check |
|---|---|
| Old busy spinner after foreground | Did `.active` fire? Breakpoint at AppState.swift:1190. If `healthCheck` succeeded on a zombie socket, the 8 s timeout should have caught it -- verify the failure actually reaches `reconnect()`. |
| Session list missing a new session | `syncSession` guard at line 741: is `pendingTarget` non-nil? It is only cleared via `clearPendingTarget` after navigation completes (PushNotificationService.swift:175-180). |
| Wrong session restored | Restoration order at lines 768-775: saved active session id (including `alternateIds`) -> newest `.chat` session -> any session -> create new. Cron-run sessions are excluded from the Sessions tab but eligible for restoration (lines 764-767). |
| Transcript missing timestamps mid-turn | Expected: live projection wins during an active turn; the persisted transcript replaces it only when `hasLiveProjection` is false (lines 839-861; HermesClient.swift:210-229). |

## 5. Push notifications not arriving

Client-side chain (PushNotificationService.swift):

1. `enable()` (line 81): UNUserNotificationCenter authorization -> APNs device
   token -> `POST {relay}/v1/installations` with
   `{"bundle_id":"com.milim.relay","device_token":...,"environment":"production","preferences":...}`.
   Stores `{credential, installationID}` in Keychain.
2. `createPairingCode()` (line 129): `POST {relay}/v1/installations/{id}/pairings`
   with Bearer credential -> shows `pairing_code` the user enters on the Hermes
   side. Server-side consumption of the code by the notifier plugin is not
   visible from this repo `[candidate -- unverified]`.
3. Relay URL: UserDefaults key `conduit.relayURL`; empty/invalid falls back to
   `https://push.milim.dev` (lines 47-53). Server-side requirement: the
   `kaishi00/hermes-conduit-notifier` plugin must be installed and the gateway
   restarted (README.md:50-56).
4. Tap-to-navigate: payload must contain `conduit.session_id` (top level or
   nested under `body`) to produce a `ConduitNotificationTarget`
   (lines 192-205). Remember: a pending target BLOCKS `syncSession` until
   cleared (section 4).

| Symptom | Check |
|---|---|
| statusText "Notifications denied" | iOS Settings permission. `authorizationStatus == .denied` (line 64). |
| Enabled but nothing arrives | Bisect: (a) does `createPairingCode` succeed? If yes, relay auth works. (b) Was the pairing code entered on Hermes before its expiry (`expires_at`)? (c) Is the notifier plugin installed and the gateway restarted? Server-side delivery is out of client scope `[candidate -- unverified]`. |
| Broken after setting a custom relay URL | Two known traps: the `@AppStorage("conduit.relayURL")` default had to be explicitly `""` (fix commit 859162b; full story in `conduit-failure-archaeology` entry 2); and `URL(string:)` accepts scheme-less strings, so `push.myhost` (no `https://`) produces a relative URL and every relay request fails `[candidate -- unverified: exact failure mode]`. Clear the field to fall back to the default. |
| Tap opens app but not the session | `notificationTarget` returned nil (missing/blank `session_id`), or navigation retry loop: `retryPendingTarget` re-bumps `navigationAttempt` every 1.5 s (lines 182-190). |
| Stale registration after re-enable | `disable()` deletes the installation remotely best-effort but ALWAYS clears local state, so re-enable creates a fresh installation (lines 99-117). |

Privacy note: the relay receives only the APNs token, bundle id, and
preference flags shown in `RegistrationRequest` (lines 268-274). Never add
content beyond this; `show_previews` defaults to false.

## 6. Voice mode silent or stuck (top-level triage only)

Deep dive belongs to `conduit-voice-pipeline`. First-line rows:

| Symptom | First check |
|---|---|
| Voice button missing / "Enable voice for this profile in Settings." | Gating chain at AppState.swift:3848-3862: `isVoiceEnabled` (per-profile UserDefaults) AND `voiceCapabilitySnapshot.supportsTranscription` (Hermes mode) AND `supportsSpeech`. Capability comes from `HermesVoiceConfigurationService` over the bridge. |
| Transcription returns nothing, no error | Hermes deliberately returns an EMPTY transcript for quiet audio or filtered hallucinations; the controller re-listens instead of failing (HermesVoiceGateway.swift:32-36). Not a bug by itself. |
| TTS silent | Speech streams over `wss .../api/audio/speak-stream?ticket=...&profile=...` with a freshly minted ticket (HermesVoiceGateway.swift:47-56) and falls back to `POST /api/audio/speak` returning a base64 data URL that must pass `DataURLLimits.decodeBase64DataURL` (16 MB decoded cap). A ticket-mint failure here is really section 2. |
| Voice dies after a phone call / Siri / alarm | AVAudioSession interruption `.began` stops capture and yields `.interrupted` (AVAudioCaptureService.swift:218-225). See trap below. |
| Voice stops when app backgrounds | By design: `handleScenePhase` calls `voiceConversationController.setForegroundActive(false)` and closes the voice sheet on `.background` (AppState.swift:1204-1206); the wake coordinator "never leaves local microphone capture running outside foreground use" (WakeLifecycleCoordinator.swift:46). |

### User-reported trap: AVAudioSession conflicts

Story (user-reported): among the costliest past failures were conflicts
between wake-word listening, speech playback, and system interruptions all
contending for the shared `AVAudioSession`. What the code does today:
capture configures `.playAndRecord` / `.voiceChat` /
`[.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]` at 16 kHz
(AVAudioCaptureService.swift:119-127); playback sets a compatible
`.playAndRecord` / `.voiceChat` category (AVSpeechPlaybackService.swift:27-28);
`stop()` deactivates with `.notifyOthersOnDeactivation` (line 116); route
changes rebuild the sample-rate converter lazily and restart the engine if it
should still be running (lines 227-236). When debugging "voice stuck", check
WHO last touched the session category and whether an interruption `.ended`
path restarted capture -- interruptions only handle `.began` here (line 221),
so recovery relies on the controller/wake coordinator, not the capture service.
Do not add a second `setCategory` call site without reading
`conduit-voice-pipeline` first.

## 7. URL rejected at login

(Operator-facing canonical rule table: `conduit-run-and-operate`,
"Connection URL rules". The triage-relevant rules from
`ConnectionURLPolicy.normalizedBaseURL`, ConnectionURLPolicy.swift:29-56,
in order:)

| Rule | Consequence |
|---|---|
| Must parse as URLComponents with a non-empty host | else `.invalidURL` ("Enter a valid dashboard URL.") |
| No userinfo (`user:pass@`), no query, no fragment in the base URL | else `.invalidURL` |
| Scheme must be `https` or `http` | else `.invalidURL` |
| `http` allowed ONLY for loopback hosts: `localhost`, `127.0.0.1`, `::1` (brackets stripped) | else `.insecureTransport` ("Remote dashboards must use HTTPS; HTTP is allowed only for localhost.") |
| Trailing slashes stripped | cosmetic |

Note: `http://192.168.x.x:9119` is REJECTED -- LAN IPs are not loopback. The
README's `http://your-server-ip:9119` phrasing (README.md:38) only works if
the "server ip" is the phone-visible loopback or the deployment is HTTPS.
`webSocketURL` maps https->wss, http->ws and appends the route to any base
path (lines 58-78), so a dashboard behind a path prefix is supported.
`isAllowedTransport` (lines 18-27) applies the same rules to every bridge
navigation and redirect.

Fix pointer: front the dashboard with TLS, or test against
`http://localhost:9119` via a device-to-host tunnel. Do not widen
`isLoopbackHost`.

## 8. Attachment too large / fails to send or render

`DataURLLimits` (entire file, DataURLLimits.swift:1-33):

| Constant | Value | Enforced where |
|---|---|---|
| `maxDecodedBytes` | 16 MB (16 * 1024 * 1024) | Decoding any inbound base64 data URL: transcript images (MarkdownText.swift:520, ChatView.swift:442), voice fallback audio (HermesVoiceGateway.swift:81), dashboard-fetched data (AppState.swift:3731,3761) |
| `maxBase64Characters` | ceil(16 MB * 4/3) | Same call sites, pre-decode length gate |
| `maxJSONResponseBytes` | 24 MB | Streamed cap on every bridge `requestJSON` response (DashboardTicketBridge.swift:188,221-243) -- oversize responses throw `response_too_large` |

Key asymmetry: OUTBOUND attachments are NOT size-checked client-side.
`sendMessage` (AppState.swift:1609-1628) base64-encodes the whole file
(`AttachmentHelper`, AppState.swift:4379-4394) and ships it over the RPC
socket: images via `image.attach_bytes`, PDFs via `pdf.attach` (120 s
timeout), everything else via `file.attach` as a data URL (120 s timeout)
(HermesClient.swift:994-1018). Server-side size rejection therefore surfaces
as "Attachment failed: <server message>" or a 120 s timeout, followed by an
automatic `syncSession()`. Any gateway-side limit is
`[candidate -- unverified]` from this repo.

| Symptom | Diagnosis |
|---|---|
| "Attachment failed: Request timed out: file.attach" | File too big for the link/server within 120 s. Shrink it; there is no client chunking. |
| "Could not read <name>." | `AttachmentHelper` only reads `file://` URLs (AppState.swift:4392); a non-file provider URI yields empty data. |
| "Attachments can only be sent in a new message, after the current response finishes." | By design: attachments are blocked while a turn is busy (AppState.swift:1574-1578). |
| Inbound image shows as nothing | The data URL failed `decodeBase64DataURL` -- wrong `data:image/` prefix, malformed base64, or > 16 MB decoded. Silent by design. |
| Bridge JSON call fails with `response_too_large` | Dashboard response exceeded 24 MB; raise `maxResponseBytes` per-call only with a reviewed reason. |

## When NOT to use this skill

| You are actually doing | Use instead |
|---|---|
| Sustained work on reconnect/session-resume reliability (the live campaign) | conduit-ws-reliability-campaign |
| Deep voice/wake/TTS pipeline work beyond the triage rows above | conduit-voice-pipeline |
| Looking up RPC method names, event types, payload shapes | hermes-protocol-reference |
| App Store review, signing, provisioning failures | conduit-appstore-and-signing |
| Build errors, xcodegen, simulator/device setup | conduit-build-and-env |
| Understanding why the architecture is shaped this way / change rules | conduit-architecture-contract, conduit-change-control |
| Post-mortems of past incidents and their full stories | conduit-failure-archaeology |
| Adding logging/instruments/tooling to investigate | conduit-diagnostics-and-tooling |
| Feature flags, settings keys, defaults | conduit-config-and-flags |
| Running the app / operating a deployment | conduit-run-and-operate |
| Writing or running tests for a fix | conduit-validation-and-qa |

## Provenance and maintenance

Ground truth verified at commit `859162b` (main).
All paths relative to `/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`.
One-line re-verification commands for every volatile fact (paste from repo root):

```bash
# /api/ws path, ticket query, text-frame requirement, timeouts, no ping
grep -n '"/api/ws"\|ticket\|\.string(text)\|requestTimeout\|promptSubmitTimeout\|waitsForConnectivity' Conduit/Services/HermesClient.swift | head
grep -cn 'ping' Conduit/Services/HermesClient.swift   # expect 0
# Reconnect backoff formula, attempt reset, epoch guard, scenePhase handling
grep -n 'pow(2.0\|reconnectAttempts = 0\|activeClientEpoch\|func handleScenePhase\|healthCheck' Conduit/Services/AppState.swift
# syncSession entry point and pendingTarget guard
grep -n 'func syncSession\|pendingTarget == nil' Conduit/Services/AppState.swift
# Bridge: /api/status load, /api/auth/ws-ticket, retry counts, readiness, origin check
grep -n '/api/status\|ws-ticket\|0..<3\|0..<30\|isReady\|securityOrigin' Conduit/Services/DashboardTicketBridge.swift
# WKSecurityOrigin port-0 fix still present
grep -n 'port > 0' Conduit/Services/ConnectionURLPolicy.swift && git log --oneline d0873ec -1
# Native auth endpoints and basic provider body
grep -n 'password-login\|/api/auth/providers\|supports_password\|"basic"' Conduit/Services/NativeAuthClient.swift Conduit/Views/LoginView.swift
# URL policy: loopback list, https rule
grep -n 'isLoopbackHost\|insecureTransport\|"https"' Conduit/Services/ConnectionURLPolicy.swift
# Data limits
grep -n 'maxDecodedBytes\|maxJSONResponseBytes' Conduit/Services/DataURLLimits.swift
# Outbound attachments (no client size gate) and attach RPCs
grep -n 'attachImage\|attachPdf\|attachFile\|image.attach_bytes\|pdf.attach\|file.attach' Conduit/Services/AppState.swift Conduit/Services/HermesClient.swift
# Push relay default, UserDefaults key, endpoints, pairing
grep -n 'push.milim.dev\|conduit.relayURL\|/v1/installations\|pairings\|bundleID' Conduit/Services/PushNotificationService.swift
# @AppStorage relay default fix
git show 859162b --stat
# Voice: audio session config, interruption handling, gating messages, audio endpoints
grep -n 'setCategory\|interruptionNotification\|notifyOthersOnDeactivation' Conduit/Voice/AVAudioCaptureService.swift Conduit/Voice/AVSpeechPlaybackService.swift
grep -n '/api/audio/transcribe\|speak-stream\|/api/audio/speak' Conduit/Voice/HermesVoiceGateway.swift
grep -n 'Enable voice for this profile' Conduit/Services/AppState.swift
# Default dashboard port
grep -n '9119' README.md
# Mine the four post-release fix commits (history is squashed to 5 commits)
git log --oneline   # 859162b d0873ec e4318c5 e3cdb49 830c09b
```

Run log:

- 2026-08-08 (build): initial authoring
