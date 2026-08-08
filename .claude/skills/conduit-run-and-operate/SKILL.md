---
name: conduit-run-and-operate
description: >
  Operating Hermes Conduit against a real Hermes Agent instance. Load this skill when the
  task involves: connecting the app to a server ("cannot connect", "invalid URL", "HTTP is
  allowed only for localhost", wrong port, WebUI vs dashboard confusion, port 9119); reaching
  a remote server (Tailscale, reverse proxy, HTTPS requirement); push notification setup or
  operations (notifier plugin install, pairing codes, "hermes conduit-push", push relay,
  push.milim.dev, self-hosted relay, notification categories, notification tap navigation);
  or multi-profile runtime behavior (profile switching, per-profile sessions, profile picker).
  Key files: ConnectionURLPolicy.swift, PushNotificationService.swift, ProfilePickerSheet.swift,
  LoginView.swift, NativeAuthClient.swift, AuxiliaryViews.swift (NotificationsSettingsDetail),
  AppState.swift (switchProfile / openNotificationTarget).
---

# Conduit: Run and Operate

Runbook for running Hermes Conduit (native SwiftUI iOS client, iOS 17+) against a real,
self-hosted Hermes Agent instance, and for operating its companion pieces: the notifier
plugin, the push relay, and multi-profile workspaces.

## Vocabulary (define once, use everywhere)

| Term | Meaning |
|---|---|
| Hermes Agent | The self-hosted agent backend this app is a client for (github.com/NousResearch/hermes-agent). Conduit is an independent client, not affiliated with Nous Research. |
| Dashboard | The Hermes Agent **native dashboard** web server, default port 9119 (README-documented; the port is not hardcoded anywhere in the client). This is what Conduit connects to. |
| WebUI | A DIFFERENT Hermes web interface. Conduit does NOT connect to it. Pointing Conduit at the WebUI is a README-documented user trap. |
| Gateway | The Hermes Agent RPC process behind the dashboard. **Conduit never contacts the gateway directly** — all RPC goes through the dashboard WebSocket endpoint `/api/ws` after dashboard auth. Hard rule; do not route around it. |
| Ticket | A WebSocket auth token minted by the dashboard (`POST /api/auth/ws-ticket`, response key `ticket`). Passed as the `ticket` query item on the `/api/ws` URL. Treated as single-use by the client (a fresh ticket is minted per (re)connect); server-side single-use/TTL enforcement is [candidate -- unverified]. |
| Profile | A Hermes workspace. Sessions, settings, pins, and voice preferences are scoped per profile. `"default"` is always present. |
| Notifier plugin | `kaishi00/hermes-conduit-notifier` — a Hermes plugin installed server-side that sends push events to the relay. Lives in another repo. |
| Push relay | HTTPS service that forwards notifier events to APNs. Default shared relay: `https://push.milim.dev`. Self-hostable; URL overridable in-app. Lives in another repo. |

## Hard rules (never contradict)

1. **No telemetry, analytics, or tracking. Ever.** Besides the user's own Hermes instance,
   the external connections are the optional push relay (user-controlled, self-hostable;
   README "Privacy" section) plus one frozen pre-existing rendering surface: markdown
   rendering loads jsDelivr CDN assets and remote markdown images inside sandboxed
   WKWebViews (`MarkdownText.swift`). Do not expand that surface;
   `conduit-change-control`'s "Verified current networking surface" table is the canonical
   statement of what is allowed.
2. **Never contact the Hermes gateway directly.** All RPC goes through the dashboard
   WebSocket endpoint (`/api/ws`, default dashboard port 9119) after dashboard auth.

## What a working backend looks like

- A running Hermes Agent instance **with the native dashboard enabled**, default port 9119.
- The README's suggested sanity check: ask your agent `is the dashboard running?`
- The dashboard address is usually `http://your-server-ip:9119` per the README — but see the
  HTTP trap below: the client only accepts plain HTTP for loopback hosts.
- Conduit shares the dashboard's session database: sessions started on desktop appear on the
  phone because it is the same database.

Trap checklist when "it won't connect":

- [ ] Are you pointing at the native dashboard, not the WebUI? (README-documented trap.)
- [ ] Is the port 9119 (or whatever the dashboard actually listens on)?
- [ ] Is the scheme allowed by the client URL policy (next section)?
- [ ] For remote servers: is HTTPS terminated somewhere (reverse proxy / Tailscale serve)?

## Connection URL rules (verified in `Conduit/Services/ConnectionURLPolicy.swift`)

Full origin-matching and bridge details belong to `conduit-debugging-playbook`; the basics:

| Rule | Behavior |
|---|---|
| Accepted schemes | `https` for any host; `http` ONLY for loopback hosts. |
| Loopback hosts | Exactly `localhost`, `127.0.0.1`, `::1` (case-insensitive, brackets stripped). Private LAN IPs (192.168.x.x, 10.x.x.x) and Tailscale IPs (100.x) are NOT loopback. |
| `http` + non-loopback | Rejected with error: "Remote dashboards must use HTTPS; HTTP is allowed only for localhost." (`ConnectionURLPolicyError.insecureTransport`) |
| Userinfo in URL | Rejected (`user`/`password` components must be nil). |
| Query or fragment in base URL | Rejected. |
| Trailing slashes | Stripped during normalization. |
| WebSocket URL | Built by `ConnectionURLPolicy.webSocketURL(baseURL:path:queryItems:)`: `https` -> `wss`, `http` -> `ws`; path is `/api/ws`; the ticket rides as query item `ticket`. |
| Port | Any explicit port is preserved; there is no client-side default port. 9119 comes from the user typing it. |

**README vs. code conflict (the HTTP trap):** README line 38 says the address "is usually
`http://your-server-ip:9119`", but `normalizedBaseURL` throws `insecureTransport` for
`http` on any non-loopback host. In practice a LAN or Tailscale-IP dashboard must be
reached over HTTPS, or via a loopback tunnel. The README wording predating or ignoring
this policy is [candidate -- unverified]; the code behavior is verified.

The login field placeholder is `https://hermes.example` (`LoginView.swift` line 64).
The last-used URL is restored on the login screen (`appState.lastDashboardURL`).

## Reaching a remote server

Per the README: "If your server is not on your local network, use Tailscale or a reverse
proxy to reach it from your phone." Given the HTTPS-only policy for non-loopback hosts,
workable patterns are:

- Reverse proxy (Caddy/nginx/Traefik) terminating TLS in front of port 9119. [candidate -- unverified: specific proxy configs live outside this repo]
- Tailscale with HTTPS (e.g. `tailscale serve` issuing a cert for the tailnet hostname). [candidate -- unverified: Tailscale-side setup is outside this repo]

## Login and auth flow (context for operating, detail owned by siblings)

Verified in `LoginView.swift` and `NativeAuthClient.swift`:

1. Conduit fetches `GET /api/auth/providers`. If a provider reports
   `supports_password: true`, it does a native login: `POST /auth/password-login`, then
   mints a ticket via `POST /api/auth/ws-ticket`.
2. Otherwise it falls back to a WKWebView on the dashboard's `/login` page (OAuth/cloud
   logins), harvesting the ticket via a script message handler named `ticket`. Ownership
   of that bridge (`DashboardTicketBridge`) is split: design/invariants ->
   `conduit-architecture-contract`; wire mechanics (mintTicket, requestJSON, readiness) ->
   `hermes-protocol-reference`; incident history (incl. the WKSecurityOrigin port-mismatch
   fix in commit d0873ec) -> `conduit-failure-archaeology`.
3. Credentials are stored on-device only (Keychain), optionally Face ID-gated.

## Push notifications: operations runbook

Push requires a relay because iOS does not allow persistent background connections
(README). Three pieces: this app, the notifier plugin on the Hermes server, the relay.

### Server-side install (commands shown in README and in-app)

```
hermes plugins install kaishi00/hermes-conduit-notifier --enable
hermes gateway restart
```

These are Hermes CLI commands executed on the server. The plugin's internals live in
another repo; anything about its behavior beyond what the client displays is
[candidate -- unverified].

### In-app pairing flow (Settings > Notifications, `NotificationsSettingsDetail` in `Conduit/Views/AuxiliaryViews.swift`)

| Step | Where | Action |
|---|---|---|
| 0 | Phone | Tap "Enable notifications". Requests APNs permission, registers the device with the relay (`POST /v1/installations`). Must succeed before pairing: "Enable notifications on this phone before creating a pairing code." |
| 1 | Server | `hermes plugins install kaishi00/hermes-conduit-notifier --enable` |
| 2 | Server | `hermes gateway restart` |
| 3 | Phone | Tap "Create pairing code" (`POST /v1/installations/{id}/pairings`; response has `pairing_code` and optional `expires_at` — codes are short-lived, one per Hermes profile you want to reach). |
| 4 | Server | `hermes conduit-push pair <code>` (command string rendered by the app; plugin-side behavior [candidate -- unverified]) |
| 5 | Server | `hermes conduit-push status` — confirm the local relay credential. |
| 6 | Server | `hermes conduit-push test` — a test notification should reach the phone within a few seconds. |

### Relay URL (default vs self-hosted)

- Default relay: `https://push.milim.dev` (hardcoded fallback in
  `PushNotificationService.relayURL`).
- Override: Settings > Notifications > "Push relay" text field, `@AppStorage("conduit.relayURL")`
  with an explicit `""` default (missing default fixed in commit 859162b; full story in
  `conduit-failure-archaeology` entry 2). Leave blank to use the default relay.
- The service reads `UserDefaults` key `conduit.relayURL` at request time; a non-empty
  parseable URL wins, otherwise the default. There is no validation of the override URL
  beyond `URL(string:)` parsing — a malformed value silently falls back.

### Relay API surface the client uses (verified in `PushNotificationService.swift`)

| Call | Purpose |
|---|---|
| `POST /v1/installations` | Register. Body: `bundle_id` (`com.milim.relay`), `device_token` (hex APNs token), `environment` (`production`), `preferences`. Returns `credential` + `installation.id`; stored in Keychain. |
| `PUT /v1/installations/{id}` | Update token/preferences. `Authorization: Bearer <credential>`. |
| `DELETE /v1/installations/{id}` | Disable. Local credential is cleared even if the DELETE fails. |
| `POST /v1/installations/{id}/pairings` | Mint pairing code. |

Server-side semantics of these endpoints are [candidate -- unverified] beyond the request
and response shapes the client sends/decodes.

### Notification categories (verified in `ConduitNotificationPreferences` + settings UI)

The README summarizes "approvals, completed turns, failures, and background tasks"; the
actual client preference set is five event types plus two behavior toggles:

| Preference (wire key) | UI label | Fires when |
|---|---|---|
| `approval_needed` | Approval needed | A tool is waiting for approval |
| `input_needed` | Input needed | Hermes needs your answer |
| `response_ready` | Response ready | An active turn finishes |
| `turn_failed` | Turn failed | A turn stops with an error |
| `background_task_finished` | Background task finished | A delegated agent completes |
| `completion_sound` | Completion sound | Behavior toggle: play a sound |
| `show_previews` | Show previews | Behavior toggle: include response text (default OFF) |

All event types default ON; preferences sync to the relay via the PUT endpoint whenever
toggled.

### Notification tap -> navigation (verified in `ConduitApp.swift`, `PushNotificationService.swift`, `AppState.openNotificationTarget`)

- Payload target lives at `userInfo["conduit"]` or nested `userInfo["body"]["conduit"]`,
  with `session_id` (required), `profile`, `type`.
- On tap, `AppState.openNotificationTarget` switches to the target profile if needed
  (case-insensitive match; the profile's display name for `default` is also accepted),
  force-refreshes the session catalog, resolves runtime/alternate session IDs against the
  catalog, then opens the session. Retry loop re-attempts every 1.5s while a pending
  target exists and the app is connected.
- Privacy framing shown in-app: the notifier holds a revocable per-phone credential; the
  gateway never sees the phone's APNs push token.

## Multi-profile behavior at runtime

Verified in `AppState.swift` and `ProfilePickerSheet.swift`:

- **Discovery:** `GET /api/profiles` via the dashboard bridge (`loadProfiles()`), key
  `profiles` (array of strings or objects with `name`). `"default"` is always appended.
  Discovery failure is non-fatal — the active profile stays usable ("Profile discovery is
  additive").
- **Scoping on the wire:** `HermesClient.scopeParams` adds `"profile": <name>` to every
  RPC's params for any profile EXCEPT `"default"`, which sends no profile parameter
  (matches the React Native transport).
- **Switching (`switchProfile(to:)`):** mints a fresh ticket via the bridge, builds a new
  `HermesClient` for the target profile, connects it, and only then disconnects the old
  socket — a failed switch rolls back to the previous profile and reconnects. Session
  list, cron sessions, archived sessions, projects, and slash commands are reset per
  profile.
- **Per-profile persisted state (UserDefaults keys):** active session ID/title
  (`conduit.activeSessionIdsByProfile.v1`, `conduit.activeSessionTitlesByProfile.v1`),
  pins (`conduit.pinnedSessionIdsByProfile.v1`), active profile (`conduit.activeProfile`),
  ordering (`conduit.profileOrder.v1`), known profiles (`conduit.knownProfiles.v1`).
  The first release stored one global "last session", which could restore another
  profile's conversation after a switch — migrated code comment at
  `AppState.swift` (~line 354).
- **Cross-profile guard:** `sessionBelongsToProfile` refuses to open a session explicitly
  tagged with another profile ("That conversation belongs to another workspace."), because
  older dashboards can return foreign rows from profile-scoped requests. Related: gateway
  `session.list` reads the main DB containing ALL profiles and must never be merged into
  the UI list (header comment in `HermesClient.swift`).
- **Picker UI:** `ProfilePickerSheet` lists profiles, supports reordering (persisted) and
  per-profile avatar photos (stored on-device only). Voice preferences and busy-input mode
  are also per profile.

## When NOT to use this skill

| If the task is... | Use instead |
|---|---|
| WS message shapes, RPC methods, event semantics | `hermes-protocol-reference` |
| Reconnect loops, stale sessions, ticket expiry, resume-after-background | `conduit-ws-reliability-campaign` |
| Diagnosing a live bug (incl. ConnectionURLPolicy origin-matching detail, DashboardTicketBridge) | `conduit-debugging-playbook` |
| Building the app, xcodegen, toolchain | `conduit-build-and-env` |
| App Store review, signing, entitlements | `conduit-appstore-and-signing` |
| Voice mode / AVAudioSession behavior | `conduit-voice-pipeline` |
| Feature flags, settings keys inventory | `conduit-config-and-flags` |
| Past incidents and why fixes look the way they do | `conduit-failure-archaeology` |
| Architecture invariants and layering | `conduit-architecture-contract` |
| Making changes safely | `conduit-change-control` |
| Logging, diagnostics tooling | `conduit-diagnostics-and-tooling` |
| Test/QA procedure | `conduit-validation-and-qa` |

## Provenance and maintenance

Ground truth verified at commit `859162b` (main).
All facts verified 2026-08-08 by reading source in this repo unless tagged
[candidate -- unverified]. Server-side plugin/relay internals live in other repos
(hermes-conduit-notifier, the push relay server) — only the client-observable request and
response shapes are verified here. Re-verify volatile facts with:

```
# URL policy: schemes, loopback list, insecureTransport, ws path building
grep -n "isLoopbackHost\|insecureTransport\|wss" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/ConnectionURLPolicy.swift

# WS endpoint path and ticket query item
grep -n "api/ws\|ticket" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift | head

# Default relay URL and override key
grep -n "push.milim.dev\|conduit.relayURL" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/PushNotificationService.swift /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Views/AuxiliaryViews.swift

# Relay endpoints and registration body fields
grep -n "/v1/installations\|bundle_id\|environment" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/PushNotificationService.swift

# Notification categories (wire keys)
grep -n "CodingKeys" -A 10 /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/PushNotificationService.swift | head -15

# In-app pairing commands (hermes plugins install / conduit-push pair|status|test)
grep -n "hermes plugins install\|conduit-push" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Views/AuxiliaryViews.swift

# Profile RPC scoping and discovery endpoint
grep -n "scopeParams\|api/profiles" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift | head

# Per-profile UserDefaults keys
grep -n "ByProfileKey\|profileOrderKey\|knownProfilesKey" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift | head

# Auth endpoints (native login path, ticket mint)
grep -n "auth/providers\|password-login\|ws-ticket" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/NativeAuthClient.swift /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/DashboardTicketBridge.swift

# README claims: port 9119, WebUI trap, Tailscale/reverse proxy, relay default
grep -n "9119\|WebUI\|Tailscale\|milim.dev" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/README.md

# Post-release fix commits (squashed history; mine with -p)
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log --oneline
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log -p 859162b   # relayURL @AppStorage default
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log -p e3cdb49   # relay URL setting added
```

Run log:
- 2026-08-08 (build): initial authoring
