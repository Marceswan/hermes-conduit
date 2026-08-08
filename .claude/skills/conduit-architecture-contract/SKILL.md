---
name: conduit-architecture-contract
description: >
  Load-bearing architecture decisions, invariants, and known weak points for
  Hermes Conduit (native SwiftUI iOS client for the Hermes Agent dashboard).
  Load this skill when: (a) touching AppState.swift, HermesClient.swift,
  DashboardTicketBridge.swift, ConnectionURLPolicy.swift, NativeAuthClient.swift,
  RootView.swift, or project.yml (this skill is the primary invariants gate
  for edits to those files); (b) planning any refactor, new feature, or
  dependency addition; (c) you are unsure why the app talks to the dashboard
  instead of the gateway, why a hidden WKWebView exists, or why there is no
  Package.swift; (d) debugging (via conduit-debugging-playbook, which owns
  symptom triage) routed you here for the underlying invariant; (e)
  onboarding a fresh session with zero repo context. This is the
  "why and what must never break" skill, not a how-to-build or how-to-debug
  skill (see siblings at the end).
---

# Conduit Architecture Contract

Hermes Conduit is a native SwiftUI iOS app (iOS 17+) that is a full client for a
self-hosted Hermes Agent instance. This file states the design decisions that
hold the app together, the invariants you must not break, and the weak points
you should expect to hurt you. Everything below was verified against source on
the date in the run log unless tagged [candidate -- unverified].

## Glossary (define once, use everywhere)

| Term | Meaning |
|---|---|
| Hermes Agent | The self-hosted agent backend this app is a client for (github.com/NousResearch/hermes-agent). Conduit is independent, not affiliated. |
| Gateway | The Hermes agent process itself. The client models its JSON-RPC protocol (see `Conduit/Models/Models.swift` header comment) but NEVER opens a connection to it. |
| Dashboard | The Hermes native dashboard web server (default port 9119, per README). The ONLY server Conduit talks to. Serves login, REST endpoints under `/api/`, and the WebSocket at `/api/ws`. |
| Ticket | A WebSocket auth token minted by `POST /api/auth/ws-ticket` on the dashboard, passed as `?ticket=` query item when opening `/api/ws`. Treated as single-use by the client (a fresh ticket is minted per (re)connect); server-side single-use/TTL enforcement is [candidate -- unverified]. Stored in `HermesConnection` (`Conduit/Models/Models.swift:370`). |
| Bridge | `DashboardTicketBridge`: a hidden, non-interactive WKWebView that keeps the dashboard's HttpOnly session cookie alive and mints fresh tickets. Hosted invisibly (1x1, opacity 0.01) by `RootView`. |
| Profile | A named Hermes configuration scope. `HermesClient.scopeParams` injects `"profile"` into RPC params for any profile other than `"default"`. |
| Turn | One prompt/response cycle. `TurnState` (Models.swift) is driven by the server's authoritative session snapshot, never by locally guessed state. |
| Epoch | A UUID (`activeClientEpoch` in AppState) stamped on each `HermesClient`'s callbacks so events from a replaced client are dropped. |
| xcodegen | Tool that generates `Conduit.xcodeproj` from `project.yml`. The `.xcodeproj` is gitignored (`.gitignore` line `*.xcodeproj/`); `project.yml` is the source of truth. |

## System map

All paths relative to repo root `/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`.

| Component | File (lines) | Role |
|---|---|---|
| App entry | `Conduit/ConduitApp.swift` | `@main`, creates the single `AppState`, wires push-notification and voice-intent routing tasks. |
| Root view | `Conduit/Views/RootView.swift` (253) | Chooses LoginView vs MainView, hosts the hidden `DashboardTicketBridgeView`, forwards `scenePhase` changes to `AppState.handleScenePhase`. |
| State hub | `Conduit/Services/AppState.swift` (4,405) | `@MainActor final class AppState: ObservableObject`. THE single state owner: connection lifecycle, reconnect, sessions, messages, profiles, capabilities, cron, stream-event handling, Keychain helpers. ~228 funcs. |
| WS + RPC | `Conduit/Services/HermesClient.swift` (1,936) | `@MainActor`. One `URLSessionWebSocketTask` per connection. JSON-RPC requests with integer ids; server push arrives as `method: "event"` notifications. Typed API methods (`sessions()`, `openSession()`, ...). |
| Auth bridge | `Conduit/Services/DashboardTicketBridge.swift` (390) | Hidden WKWebView + `WKScriptMessageHandler` named `dashboard-response`. Mints tickets, runs authenticated dashboard JSON requests via in-page `fetch(..., credentials: 'include')`. Persists dashboard cookies to Keychain (`DashboardCookiePersistence`). |
| Password auth | `Conduit/Services/NativeAuthClient.swift` (147) | URLSession-based: `GET /api/auth/providers`, `POST /auth/password-login` (body `{provider:"basic", username, password}`), `POST /api/auth/ws-ticket`. Shares `HTTPCookieStorage.shared` so its session cookie can be copied into WebKit. |
| URL policy | `Conduit/Services/ConnectionURLPolicy.swift` (148) | Single gatekeeper for every URL the app will touch: normalization, https-only (http only for loopback), ws/wss derivation, origin matching (including the WKSecurityOrigin port-0 rule). |
| Push | `Conduit/Services/PushNotificationService.swift` (305) | Relay-based APNs. Default relay `https://push.milim.dev`; override via UserDefaults key `conduit.relayURL`. |
| Voice | `Conduit/Voice/` (7 files + `Wake/`) | Voice pipeline. Owned by the conduit-voice-pipeline skill; do not restate here. |
| Models | `Conduit/Models/Models.swift` | Data models matching the Hermes gateway JSON-RPC protocol shapes; `HermesConnection`, `TurnState`, `BusyInputMode`, diagnostics types. |
| Tests | `ConduitTests/` (8 files) | Includes `SecurityBoundaryTests.swift`, `TurnStateTests.swift`, `MessageNormalizerTests.swift`, voice/wake tests. |

Measured size: 20,414 Swift lines in the app target (`find Conduit -name "*.swift" | xargs wc -l`); tests add 1,588 more (22,002 total with `ConduitTests/`).

## Hard rules (user-confirmed, non-negotiable)

1. NO telemetry, analytics, tracking, or ad frameworks. Ever. This is a hard
   privacy constraint, not a preference. The README promises it publicly.
   Verified state: the entire codebase imports only Apple frameworks
   (AVFAudio, AppIntents, Combine, Foundation, LocalAuthentication, OSLog,
   PhotosUI, Security, Speech, SwiftUI, UIKit, UniformTypeIdentifiers,
   UserNotifications, WebKit, XCTest, os). Any PR adding an analytics SDK,
   crash reporter, or new third-party network call is a contract violation.
   Frozen pre-existing exceptions (do NOT expand them, and do not rip them
   out as "violations" without change control): markdown rendering loads
   jsDelivr CDN assets (mermaid@11.16.0, katex@0.16.22) and remote markdown
   images inside sandboxed WKWebViews
   (`Conduit/Views/Components/MarkdownText.swift:776,788,799,802`;
   `RemoteImageWebView` at 553). This surface is in tension with the README
   sentence; prefer bundling assets locally if it is ever revisited.
   conduit-change-control's "Verified current networking surface" table is
   the canonical statement of the allowed surface.
2. NEVER contact the Hermes gateway directly. ALL RPC goes over the dashboard
   WebSocket at `/api/ws` (default dashboard port 9119) after dashboard auth.
   In code: the only WebSocket URL is built in `HermesClient.connect()` at
   `HermesClient.swift:363-367` with `path: "/api/ws"` and a `ticket` query
   item, derived from the user-entered dashboard base URL. There is no other
   socket. Do not add one.

## Load-bearing decisions and WHY

1. Pure SwiftUI + Apple frameworks only; zero third-party dependencies.
   Verified: `project.yml` contains no `packages:` section, `.gitignore`
   excludes `Package.resolved`, and no non-Apple import exists (see rule 1).
   WHY: privacy promise is auditable, App Store review surface is minimal
   (App Store review was a costly past failure, user-reported), and there is
   no dependency drift. Checklist before adding ANY package: it is almost
   certainly the wrong move; escalate to the human first.

2. xcodegen owns the project. `Conduit.xcodeproj` is generated (`xcodegen
   generate`) and gitignored; `project.yml` is the only checked-in project
   definition. Editing the .xcodeproj by hand is wasted work -- it gets
   regenerated. Key settings in `project.yml`: iOS 17.0 target, Swift 5.9,
   bundle id `com.milim.relay`, product name `Conduit`, manual signing, team
   `U2TH557QA8`, profile "Conduit App Store", `MARKETING_VERSION: "0.1.1"`,
   `CURRENT_PROJECT_VERSION: "114"`. Build/signing details belong to
   conduit-build-and-env and conduit-appstore-and-signing.

3. AppState is the single state hub and session lifecycle owner. One
   `@StateObject` created in `ConduitApp` and injected via
   `.environmentObject`. It owns: connect/disconnect/reconnect, the active
   `HermesClient`, the `DashboardTicketBridge`, session catalog, messages,
   stream-event application, profiles, Keychain persistence
   (`KeychainHelper` lives at the bottom of AppState.swift, `MARK: -
   Keychain Helper`, line ~4260). WHY: one owner means one place where
   server truth is reconciled. The file header states the doctrine: "The
   session snapshot returned by Hermes is the source of truth for a turn.
   Stream events enrich that snapshot, but never replace it with a guess
   after foregrounding, reconnecting, or launching the app again."

4. HermesClient is a disposable, per-connection object. `AppState.makeClient`
   (AppState.swift:650) creates a fresh client per connect/reconnect, stamps
   an epoch UUID, and both `onEvent` and `onDisconnected` callbacks check
   `self.activeClientEpoch == epoch` before doing anything. WHY: reconnects
   replace the client; without the epoch guard, a zombie socket's events
   would corrupt state. Never reuse a HermesClient across connects.

5. RPC frames are TEXT, not binary. `HermesClient.rpc` sends
   `socket.send(.string(...))` with an explicit comment: the gateway accepts
   the connection but does not dispatch binary JSON-RPC frames (matches the
   established React Native client). Do not "optimize" to `.data`.

6. Auth is cookie-in-WebKit by design, not tokens-in-URLSession. The
   dashboard issues an HttpOnly session cookie. Instead of re-implementing
   that session handling, the bridge keeps a hidden WKWebView logged in and
   runs `fetch` inside the page with `credentials: 'include'`
   (DashboardTicketBridge.swift:183-268, comment at 180-182: "intentionally
   avoids duplicating HttpOnly session handling in URLSession"). Cookies are
   mirrored to Keychain (`DashboardCookiePersistence`) and restored on cold
   launch because WebKit may not persist session cookies itself. Password
   login (`NativeAuthClient`) deliberately uses `HTTPCookieStorage.shared`
   so its cookie can be copied into WebKit
   (`DashboardCookiePersistence.restoreNativeCookies`). URLSession and
   WebKit have SEPARATE cookie stores -- several comments in AppState and
   the bridge exist purely to defend this fact.

7. ConnectionURLPolicy is the single URL gatekeeper. Every URL the app
   builds or follows goes through it: base-URL normalization (rejects
   userinfo, query, fragment), transport policy (https required; http only
   for `localhost`/`127.0.0.1`/`::1`), ws/wss derivation, redirect policy
   (`SecureRedirectDelegate` in NativeAuthClient blocks cross-origin
   redirects), WKWebView navigation policy, and script-message origin
   checks. The `effectivePort` function treats port 0 as nil because
   WKSecurityOrigin reports 0 for default-port connections -- that is the
   d0873ec fix (see weak points). Route any new URL handling through this
   enum; do not hand-roll URL checks.

8. Cold start prefers the saved ticket over the bridge.
   `AppState.loadSavedConnection` -> `restoreSavedConnection` connects with
   the persisted `HermesConnection` FIRST; the bridge only mints a
   replacement ticket after that socket actually fails. Comment at
   AppState.swift:669-673 records the lesson: "Requiring a freshly restored
   WebKit cookie before every launch was what turned a healthy saved Hermes
   session into login." Also: only an explicit dashboard 401/403 may send
   the user back to the login screen (AppState.swift:603-606); transient
   failures must keep the shell up and retry.

9. Reconnect ladder -- contract-level facts only (the canonical, line-cited
   description of the machinery is conduit-ws-reliability-campaign Phase 1.1):
   - Every (re)connect mints a fresh ticket via the bridge; the client treats
     tickets as single-use and never reuses one across sockets.
   - Only an explicit dashboard 401/403 (`signInRequired`) may show the login
     screen; transient failures keep the shell up and schedule reconnect.
   - Server snapshot beats local guess: recovery always ends in
     `syncSession()`, never in trusting the last stream event.

10. Push notifications use an external relay because iOS forbids persistent
    background sockets. Default relay `https://push.milim.dev`
    (PushNotificationService.swift:52), user-overridable via
    `@AppStorage("conduit.relayURL")` (AuxiliaryViews.swift:1209; the
    missing-default bug was fixed in commit 859162b). This relay is the ONLY
    permitted external endpoint besides the user's own dashboard, it is
    optional, and it is self-hostable -- that is why it does not violate
    hard rule 1. Server-side relay behavior is out of client view
    [candidate -- unverified].

## Invariants (verified; breaking any of these is a regression)

| # | Invariant | Enforced at |
|---|---|---|
| I1 | Every server RPC flows through the active `HermesClient` over `/api/ws`; the only other network calls are dashboard REST for auth/tickets (bridge + NativeAuthClient), the optional push relay, and the frozen WKWebView rendering surface (jsDelivr CDN assets + remote markdown images, MarkdownText.swift — see hard rule 1; canonical table in conduit-change-control). | HermesClient.swift:363-367; DashboardTicketBridge.requestJSON; NativeAuthClient; PushNotificationService; MarkdownText.swift:776,788,799,802 |
| I2 | No connection is attempted to any URL that fails `ConnectionURLPolicy` (https-only except loopback; no userinfo/query/fragment in base URL; redirects must keep origin). | ConnectionURLPolicy.swift; NativeAuthClient.SecureRedirectDelegate; DashboardTicketBridge.decidePolicyFor |
| I3 | The bridge WKWebView never navigates off the configured dashboard origin, and script messages are accepted only from the main frame with a matching WKSecurityOrigin (port 0 == scheme default). | DashboardTicketBridge.swift:291-311, 346-361; ConnectionURLPolicy.effectivePort |
| I4 | Stale-client events are dropped via the epoch guard; a replaced client's `onEvent`/`onDisconnected` are no-ops. | AppState.makeClient (652-665) |
| I5 | Server snapshot beats local guess: after foreground/reconnect/relaunch, state is rebuilt from `session.resume` / `syncSession`, not from the last stream event. | AppState.swift header comment; MARK "Authoritative reconciliation" (732); handleScenePhase |
| I6 | Only a dashboard 401/403 (`signInRequired`) may show the login screen; transient errors keep the session shell and schedule reconnect. | AppState.connect catch (597-608); reconnect (1126-1155) |
| I7 | Tickets are minted fresh for every (re)connect and persisted with the connection in Keychain; they are never reused across sockets by design. | AppState.reconnect (1121-1124); profile switch path (~2414) |
| I8 | Credentials, connection, and dashboard cookies live in the Keychain only; explicit sign-out (`disconnect`) clears all of them plus per-profile UserDefaults state. | AppState.disconnect (611-648); KeychainHelper; DashboardCookiePersistence |
| I9 | `AppState` and `HermesClient` are `@MainActor`; all cross-thread callbacks hop via `Task { @MainActor in ... }`. Do not touch their state from other executors. | AppState.swift:18-19; HermesClient.swift:320-321 |
| I10 | RPC ids are monotonic ints matched to continuations with per-request timeouts (30s default, 180s prompt submit, 90s title generation); every pending request is failed on disconnect so no continuation leaks. | HermesClient.swift:347-349, 636-677, 614-632 |

## Known weak points (stated plainly)

- AppState.swift is a 4,405-line god object (~228 funcs). Connection,
  reconnect, catalog, streaming, profiles, cron, capabilities, Keychain all
  in one @MainActor class. Any edit risks distant side effects; read the
  MARK map (grep "MARK" AppState.swift) before touching it. Splitting it is
  desirable but is a change-control decision (see conduit-change-control),
  not something to do drive-by.
- WebSocket/session reliability is the hardest LIVE problem (user-reported):
  reconnects, stale sessions, ticket expiry, resume-after-background. The
  ladder in decision 9 works but is spread across AppState, HermesClient,
  and the bridge. Symptom triage belongs to conduit-debugging-playbook;
  the ongoing effort is tracked in conduit-ws-reliability-campaign.
- The bridge is timing-sensitive by nature. `waitUntilReady` is a 30 x 100ms
  poll; readiness is inferred from `webView.url` not containing `/login`
  after `didFinish` (DashboardTicketBridge.swift:313-333). A dashboard that
  changes its login route shape would silently break readiness detection
  [candidate -- unverified server behavior]. Canonical example of this
  failure class: WKSecurityOrigin reports port 0 for default-port
  connections, and a literal port comparison silently dropped all bridge
  responses (stuck on "Synchronizing") -- fixed in d0873ec; full mechanism
  in conduit-failure-archaeology entry 1.
- Stream-event parsing is shape-tolerant on purpose
  (`handleStreamEvent`, HermesClient.swift:490+): fields are read from
  multiple fallback keys (`payload.text` vs `obj.text`; three reasoning
  event names; several message-id locations). This absorbs server variance
  but means a new server field can be silently ignored. Protocol shapes are
  owned by hermes-protocol-reference.
- RPC timeouts use `Timer.scheduledTimer` on the main run loop inside a
  @MainActor class; a blocked main thread delays timeout delivery. Works
  today; be careful moving this code off the main actor.
- `git` history is squashed to 5 public commits (830c09b + 4 fixes), so
  `git blame` archaeology mostly dead-ends at "Initial public release".
  The 4 fix commits are the only mineable diffs.
- AVAudioSession conflicts (wake-word vs playback vs interruptions) were a
  costly past failure class (user-reported) -- owned by
  conduit-voice-pipeline; do not adjust audio session code from here.

## When NOT to use this skill

| You want to... | Use instead |
|---|---|
| Build, generate the project, set up signing env | conduit-build-and-env |
| App Store review, provisioning, signing failures | conduit-appstore-and-signing |
| Debug a live symptom (hang, disconnect, 401 loop) | conduit-debugging-playbook |
| RPC method names, event shapes, endpoint contracts | hermes-protocol-reference |
| Voice, wake word, audio session behavior | conduit-voice-pipeline |
| Settings keys, feature flags, UserDefaults/AppStorage | conduit-config-and-flags |
| Run the app / operate against a live instance | conduit-run-and-operate |
| Past incidents and why fixes look the way they do | conduit-failure-archaeology |
| The ongoing WS reliability workstream | conduit-ws-reliability-campaign |
| Making/approving a risky change (e.g. splitting AppState) | conduit-change-control |
| Test plans, QA passes | conduit-validation-and-qa |
| Logging, diagnostics tooling | conduit-diagnostics-and-tooling |

## Provenance and maintenance

Ground truth verified at commit `859162b` (main).
Re-verify volatile facts before trusting them (paste-ready; run from repo root
`/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`):

- No third-party imports: `grep -rh "^import " Conduit ConduitTests --include="*.swift" | sort -u`
- No SPM packages: `grep -n "packages" project.yml || echo "none"`
- WS endpoint and ticket param: `grep -n '"/api/ws"' Conduit/Services/HermesClient.swift`
- Ticket mint endpoint: `grep -rn "ws-ticket" Conduit/Services`
- Password login endpoint: `grep -n "password-login" Conduit/Services/NativeAuthClient.swift`
- Text-frame rule: `grep -n "socket.send(.string" Conduit/Services/HermesClient.swift`
- Timeouts: `grep -n "requestTimeout\|promptSubmitTimeout\|titleGenerationTimeout" Conduit/Services/HermesClient.swift`
- Backoff formula: `grep -n "pow(2.0" Conduit/Services/AppState.swift`
- Epoch guard: `grep -n "activeClientEpoch" Conduit/Services/AppState.swift`
- Loopback http exception: `grep -n "isLoopbackHost" Conduit/Services/ConnectionURLPolicy.swift`
- Port-0 rule (d0873ec): `grep -n "port 0" Conduit/Services/ConnectionURLPolicy.swift && git log --oneline d0873ec -1`
- Default push relay: `grep -n "push.milim.dev" Conduit/Services/PushNotificationService.swift`
- Relay override key: `grep -rn 'conduit.relayURL' Conduit`
- File sizes / god-object status: `wc -l Conduit/Services/AppState.swift Conduit/Services/HermesClient.swift Conduit/Services/DashboardTicketBridge.swift`
- Total size (app target; add ConduitTests for app+tests): `find Conduit -name "*.swift" | xargs wc -l | tail -1` (20,414) / `find Conduit ConduitTests -name "*.swift" | xargs wc -l | tail -1` (22,002)
- Version/build/signing: `grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION\|PROVISIONING_PROFILE_SPECIFIER\|DEVELOPMENT_TEAM" project.yml`
- xcodeproj gitignored: `grep -n "xcodeproj" .gitignore`
- Bridge hosting in UI: `grep -n "DashboardTicketBridgeView" Conduit/Views/RootView.swift`
- Squashed history: `git log --oneline`
- Default port 9119 (README-only; not in Swift source): `grep -rn "9119" README.md Conduit || true`

Run log:
- 2026-08-08 (build): initial authoring
