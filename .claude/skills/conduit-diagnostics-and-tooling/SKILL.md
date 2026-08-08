---
name: conduit-diagnostics-and-tooling
description: >
  Load this skill when you need to MEASURE what Conduit is doing instead of
  guessing: capturing or filtering app logs (os.Logger, Console.app, log
  stream), finding out what the app actually logs and where logging is missing,
  running the ConduitTests unit suite from the CLI (xcodebuild test),
  inspecting the dashboard WebSocket traffic (Charles/proxy), or testing push
  notification routing in the simulator with .apns payload files. Symptoms
  that should trigger it: "why can't I see any logs", "how do I filter
  Console.app for this app", "run the tests", "simulate a push", "watch the
  WebSocket traffic", "what does HermesClient log", "no output in Xcode
  console". Relevant files: AppState.swift, HermesClient.swift,
  PushNotificationService.swift, ConduitApp.swift, project.yml, ConduitTests/.
  NOT for diagnosing a specific bug end-to-end (conduit-debugging-playbook),
  build/signing failures (conduit-build-and-env, conduit-appstore-and-signing),
  or WS reconnect design work (conduit-ws-reliability-campaign).
---

# Conduit diagnostics and tooling

How to observe this app with instruments instead of eyeballs. This skill
inventories the logging that actually exists (it is sparse -- that is a
finding, not an omission of this document), and gives copy-pasteable commands
for log capture, CLI test runs, simulator push injection, and WebSocket
inspection.

All facts below were verified by reading source on 2026-08-08 unless tagged
`[candidate -- unverified]`. Re-verification one-liners are at the bottom.

## Hard rules (never route around these)

1. **No telemetry, analytics, or tracking. Ever.** Diagnostics in this project
   means LOCAL observation: os.Logger, Console.app, Xcode, simulator tools.
   Never add a crash reporter, analytics SDK, or remote log shipper, even
   "temporarily for debugging". This is a user-confirmed hard privacy
   constraint.
2. **Never contact the Hermes gateway directly.** All RPC goes through the
   dashboard WebSocket endpoint `/api/ws` (verified:
   `Conduit/Services/HermesClient.swift:365`) after dashboard auth. Default
   dashboard port is 9119 (README.md). Any diagnostic tooling you build must
   observe that path, not bypass it.

## Jargon (defined once)

| Term | Meaning here |
|---|---|
| Hermes Agent | The self-hosted AI agent server this app is a client for. |
| Dashboard | Hermes' web UI, default `http://<host>:9119`. Conduit authenticates against it and speaks JSON-RPC over its `/api/ws` WebSocket. |
| Gateway | Hermes' lower-level API server. Off-limits for direct client calls (hard rule 2). |
| os.Logger / unified logging | Apple's system logging (`import OSLog`). Messages carry a `subsystem` and `category` and are viewable in Xcode console, Console.app, and the `log` CLI. |
| Subsystem | The string identifying this app's logs: `com.milim.conduit`. NOTE: this is NOT the bundle ID. The bundle ID is `com.milim.relay` (project.yml:34). Filtering logs by the bundle ID finds nothing. |
| xcodegen | Tool that generates `Conduit.xcodeproj` from `project.yml`. The `.xcodeproj` is gitignored; it does not exist until you run `xcodegen generate`. |
| .apns file | A JSON file fed to `xcrun simctl push` to simulate an APNs push notification in the iOS simulator. |
| Push relay | The small server (`https://push.milim.dev` by default, overridable via the `conduit.relayURL` UserDefaults key) that Conduit registers device tokens with. See conduit-config-and-flags for the setting itself. |

## 1. What the app actually logs (complete inventory)

Total logging surface: **3 Logger declarations, 15 emission callsites, zero
`print`/`os_log`/`NSLog` in the app target** (~21.6k lines of Swift). Only two
files log at all. Everything uses `Logger(subsystem: "com.milim.conduit", ...)`.

### Logger declarations

| Logger | Subsystem | Category | Declared at |
|---|---|---|---|
| `sessionCatalogLog` | `com.milim.conduit` | `SessionCatalog` | `Conduit/Services/AppState.swift:15` |
| `titleGenerationLog` | `com.milim.conduit` | `TitleGeneration` | `Conduit/Services/AppState.swift:16` |
| `logger` (private to HermesClient) | `com.milim.conduit` | `HermesClient` | `Conduit/Services/HermesClient.swift:323` |

### Every emission callsite

| File:line | Level | Message (paraphrased) | When it fires |
|---|---|---|---|
| AppState.swift:2167 | notice | "Dashboard catalog for {profile}: {n} sessions; {source summary}" | Session list loaded from dashboard history |
| AppState.swift:2172 | error | "Dashboard history failed; using gateway fallback: {err}" | Dashboard history endpoint failed; falling back |
| AppState.swift:2227 | debug | "Persisted transcript unavailable for {sessionId}: {err}" | `/api/sessions/{id}/messages` prefetch failed (older servers omit it) |
| AppState.swift:3221 | error | "Could not read title settings for {profile}: {err}" | Title-generation config read failed |
| AppState.swift:3273 | notice | "Used Hermes title for {sessionId} in {profile}" | Server-side title adopted |
| AppState.swift:3293 | notice | "Generated title for {sessionId} in {profile}" | Client-driven title generation succeeded |
| AppState.swift:3299 | error | "Title recovery failed for {sessionId} in {profile}: {err}" | Title recovery task failed (cosmetic, swallowed) |
| HermesClient.swift:390 | notice | "WebSocket handshake completed" | Socket confirmed open via URLSession delegate |
| HermesClient.swift:450 | error | "WebSocket receive failed: {err}" | Receive loop broke; socket closed or errored |
| HermesClient.swift:462 | error | "Dropped undecodable inbound WebSocket frame ({n} bytes)" | Inbound frame failed JSON-RPC decode |
| HermesClient.swift:469 | debug | "Received unmatched RPC response id {id}" | Response for an id with no pending request (stale/timed-out) |
| HermesClient.swift:472 | notice | "Received RPC response id {id}" | Normal RPC response matched |
| HermesClient.swift:486 | debug | "Received non-event WebSocket notification without an RPC id" | Unknown notification shape |
| HermesClient.swift:647 | notice | "Sending RPC id {id} method {method}" | Every outbound RPC |
| HermesClient.swift:667 | error | "RPC send failed for {method}: {err}" | Outbound send failed |

Practical payoff: streaming the `HermesClient` category gives you a full
RPC-level trace of the dashboard WebSocket (method names, request/response id
pairing, disconnects) WITHOUT a proxy. Use this first; it is usually enough
for the reconnect/stale-session class of problems (user-reported hardest live
problem; see conduit-ws-reliability-campaign).

Privacy note: interpolations tagged `privacy: .public` (profile names, session
ids, method names, error strings) are readable in release builds. Untagged
interpolations (the numeric RPC `id` at HermesClient.swift:469/472/647 and the
byte count at :462) use the default privacy level; numeric scalars normally
render readable but strings would show as `<private>` [candidate -- unverified
redaction behavior; verify on a device if it matters].

### Honest finding: where logging is absent

These subsystems have ZERO log statements. When debugging them, do not hunt
for log output that does not exist -- use the alternatives listed:

| Silent subsystem | Debug via instead |
|---|---|
| `DashboardTicketBridge.swift` (WKWebView auth bridge; user-reported top failure area, see commit d0873ec) | Xcode breakpoints; Safari Web Inspector attached to the WKWebView (Settings > Safari > Advanced > Web Inspector on device) [candidate -- unverified that the WKWebView is inspectable in release builds; `isInspectable` is not set in source] |
| `NativeAuthClient.swift`, `BiometricAuth.swift` | `AppState.errorMessage` (published, surfaces as user-visible alert; 61 assignment sites in AppState.swift as of 2026-08-08) |
| `PushNotificationService.swift` | Its published `lastError` / `statusText` shown in notification settings UI |
| Entire voice pipeline (`Conduit/Voice/**`, AVAudioSession handling; user-reported failure area) | Breakpoints; `ConduitTests` voice suites; see conduit-voice-pipeline |
| Reconnect/resume orchestration in AppState | The 15 HermesClient/SessionCatalog callsites above are the only signal; see conduit-ws-reliability-campaign before adding more |

If a future session needs more observability, the highest-value additions are
a `DashboardTicketBridge` category and a reconnect-lifecycle category --
propose them through conduit-change-control; keep hard rule 1 (local logging
only).

### Regenerate this inventory

```bash
bash /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/.claude/skills/conduit-diagnostics-and-tooling/scripts/log-inventory.sh
```

Zero dependencies (bash + grep), read-only, syntax-checked with `bash -n`.

## 2. Capturing the logs

### Simulator (live stream, includes debug level)

```bash
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.milim.conduit"' \
  --level debug --style compact
```

One category only (the WebSocket trace):

```bash
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.milim.conduit" AND category == "HermesClient"' \
  --level debug --style compact
```

`--level debug` is required to see the `.debug` callsites; without it you get
notice/error only. These are standard Apple `log` CLI invocations; the
subsystem/category strings are verified from source.

### Physical device (Console.app; TestFlight-style debugging)

For a device build (including TestFlight installs) there is no Xcode console.
Use Console.app on a Mac:

1. Connect the device via USB (or same-network Wi-Fi debugging).
2. Open Console.app, select the device in the sidebar, press Start.
3. Filter: type `com.milim.conduit` and select Subsystem from the search-token
   dropdown (or filter by process `Conduit` -- the product name, project.yml:35).
4. Action menu > Include Info Messages and Include Debug Messages, otherwise
   the `.debug` lines never appear.

Post-hoc capture from a connected device:

```bash
sudo log collect --device --last 1h --output ~/conduit-device.logarchive
open ~/conduit-device.logarchive   # opens in Console.app
```

[candidate -- unverified: `log collect --device` flags vary by macOS version;
check `log collect --help` first.]

### In-app observable surfaces (no tooling needed)

| Surface | Where | What it shows |
|---|---|---|
| Settings sheet, Connection section | `AuxiliaryViews.swift:181-207` | Server URL, Connected/Disconnected status dot, Reconnect button |
| Error alerts | `AppState.errorMessage` (`AppState.swift:151`) | Connection, session-restore, profile-mismatch failures |
| Notification settings | `PushNotificationService.lastError` / `statusText` | Push relay registration failures, permission state |

## 3. Running the unit tests from the CLI

Facts first:

- Test target: `ConduitTests` (project.yml:42-51), XCTest, depends on the
  `Conduit` app target (hosted tests). 8 files, 74 `func test` methods
  covering message normalization, security boundaries, wake word, voice
  controller, and turn state.
- `Conduit.xcodeproj` is **gitignored and generated**. Nothing builds until:

```bash
cd /Users/marcswan/Documents/Code/personal/tools/hermes-conduit
xcodegen generate   # requires: brew install xcodegen (README.md:66-68)
```

- project.yml defines **no `schemes:` section**. Xcode auto-creates a
  `Conduit` scheme on first open; whether `xcodebuild` sees a scheme before
  Xcode has opened the project once depends on xcodegen's default scheme
  generation [candidate -- unverified]. Always list first:

```bash
xcodebuild -list -project Conduit.xcodeproj
```

- Then run the suite (scheme and destination names are
  [candidate -- unverified] until confirmed by the `-list` output and
  `xcrun simctl list devices available`):

```bash
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

- Signing gotcha: project.yml pins Manual signing with an "Apple Distribution"
  identity and the "Conduit App Store" provisioning profile (project.yml:17-18,
  39-41). Simulator builds normally skip codesigning, but if the test build
  fails on signing, append `CODE_SIGNING_ALLOWED=NO` to the xcodebuild
  invocation [candidate -- unverified]. Do not change the signing settings to
  make tests pass -- that is conduit-appstore-and-signing territory.
- If a scheme is missing entirely, open the project in Xcode once
  (`open Conduit.xcodeproj`) to let it auto-create schemes, then re-run
  `-list` [candidate -- unverified].

## 4. Simulator push testing (.apns files)

The payload shape is verified from `PushNotificationService.swift:192-205`
(`notificationTarget(from:)`) and the delegate wiring in `ConduitApp.swift`:

- The app looks for a `conduit` dictionary either at the top level of
  `userInfo` or nested under `body` (`userInfo["body"]["conduit"]`).
- Required: `session_id` (non-empty string after trimming). Optional:
  `profile`, `type` (strings).
- Routing: a valid payload sets `PushNotificationService.pendingTarget`;
  `ConduitApp.swift:73-80` navigates only once `appState.isConnected` is true,
  retrying every 1.5 s otherwise. So after pushing, the app must be logged in
  and connected for navigation to happen.
- Foreground pushes are deliberately silent: `willPresent` returns `[]`
  (`ConduitApp.swift:47-56`). To see a banner, background the app first; to
  test tap-routing, tap the banner (that path goes through `didReceive`).

Write the payload:

```bash
cat > /tmp/conduit-test.apns <<'EOF'
{
  "Simulator Target Bundle": "com.milim.relay",
  "aps": {
    "alert": { "title": "Hermes", "body": "Approval needed" },
    "sound": "default"
  },
  "conduit": {
    "session_id": "test-session-123",
    "profile": "default",
    "type": "approval_needed"
  }
}
EOF
xcrun simctl push booted /tmp/conduit-test.apns
```

Bundle ID `com.milim.relay` is verified (project.yml:34,
PushNotificationService.swift:54). The `type` values the server actually sends
are not visible from client code; the client's preference CodingKeys
(`approval_needed`, `input_needed`, `response_ready`, `turn_failed`,
`background_task_finished`) are the plausible vocabulary
[candidate -- unverified server behavior]. The client treats `type` as opaque
metadata for routing, so any string works for navigation testing.

Real-device push requires the push relay (`https://push.milim.dev` or
self-hosted; `aps-environment` is `production` in Conduit.entitlements) --
that is end-to-end territory, see conduit-run-and-operate.

## 5. Inspecting the dashboard WebSocket

Prefer the built-in trace: the `HermesClient` log category (section 2) already
shows every RPC method name, id pairing, and disconnect without any proxy.

If you need actual frame payloads, a MITM proxy (Charles, Proxyman, mitmproxy)
can capture the `/api/ws` traffic [candidate -- unverified end-to-end; the
following constraints ARE verified from source and shape what will work]:

- `ConnectionURLPolicy.swift:26` enforces `https` for any non-loopback host
  (`http` is only allowed for loopback). The WS URL is derived from the base
  URL: `https` becomes `wss` (`ConnectionURLPolicy.swift:72`). So device
  traffic is TLS: the proxy's root CA must be installed AND trusted on the
  device/simulator (Settings > General > About > Certificate Trust Settings),
  and SSL proxying enabled for the dashboard host [candidate -- unverified
  operational steps].
- Info.plist ATS grants only `NSAllowsLocalNetworking` (Info.plist:63-67).
  There is no arbitrary-loads exception, so plain-http interception tricks
  will not work against remote hosts.
- The auth ticket rides the WS URL as a query item
  (`?ticket=...`, HermesClient.swift:366). Treat proxy captures as
  credential-bearing; do not paste them into issues or commits.
- Loopback shortcut: against a local dev dashboard, `http://127.0.0.1:9119`
  is allowed by policy (ws://, no TLS), which mitmproxy can relay without
  certificates [candidate -- unverified].

For protocol semantics of what you capture (RPC method list, event types),
see hermes-protocol-reference. Do not point any inspection tooling at the
gateway (hard rule 2).

## When NOT to use this skill

| You are trying to... | Use instead |
|---|---|
| Diagnose a specific bug end-to-end | conduit-debugging-playbook |
| Fix reconnects, stale sessions, ticket expiry, resume-after-background | conduit-ws-reliability-campaign |
| Understand RPC methods/event payloads on the wire | hermes-protocol-reference |
| Fix build, xcodegen, or environment problems | conduit-build-and-env |
| Fix signing/App Store review issues (incl. the test-signing gotcha above) | conduit-appstore-and-signing |
| Debug wake word / AVAudioSession / speech | conduit-voice-pipeline |
| Change settings, defaults, or feature flags | conduit-config-and-flags |
| Run the app against a real Hermes server | conduit-run-and-operate |
| Learn what broke before and why | conduit-failure-archaeology |
| Add new logging or any code change | conduit-change-control (and hard rule 1) |
| Write or extend the test suites themselves | conduit-validation-and-qa |

## Provenance and maintenance

Repo root: `/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`.
Run these from the repo root to re-verify every volatile fact above.

```bash
# Logging inventory still 3 loggers / 15 emissions / no print-os_log-NSLog:
bash .claude/skills/conduit-diagnostics-and-tooling/scripts/log-inventory.sh

# Subsystem and categories:
grep -rn 'Logger(subsystem:' Conduit/

# Bundle ID vs subsystem mismatch (com.milim.relay vs com.milim.conduit):
grep -n 'PRODUCT_BUNDLE_IDENTIFIER' project.yml

# WS endpoint path and ticket query item:
grep -n '/api/ws\|ticket' Conduit/Services/HermesClient.swift | head

# Transport policy (https-only except loopback; wss derivation):
grep -n 'scheme == "https"\|"wss"' Conduit/Services/ConnectionURLPolicy.swift

# ATS exceptions:
grep -n -A2 'NSAppTransportSecurity' Conduit/Info.plist

# Push payload keys (conduit / session_id / profile / type):
grep -n -A8 'func notificationTarget' Conduit/Services/PushNotificationService.swift

# Push relay default URL and override key:
grep -n 'conduit.relayURL\|push.milim.dev' Conduit/Services/PushNotificationService.swift

# Foreground pushes silenced + connected-gated routing:
grep -n 'willPresent\|isConnected' Conduit/ConduitApp.swift

# Test target, scheme absence, signing pins:
grep -n 'ConduitTests\|schemes:\|CODE_SIGN\|PROVISIONING' project.yml

# Test method count (was 74 on 2026-08-08):
grep -c 'func test' ConduitTests/*.swift

# xcodeproj is generated, not checked in:
grep -n 'xcodeproj' .gitignore

# Settings sheet connection status UI:
grep -n 'Connected" : "Disconnected' Conduit/Views/AuxiliaryViews.swift

# Mine the post-release fix commits (squashed history, 5 commits total):
git log --oneline
git log -p d0873ec   # WKSecurityOrigin port mismatch fix (DashboardTicketBridge)
```

Run log:

- 2026-08-08 (build): initial authoring
