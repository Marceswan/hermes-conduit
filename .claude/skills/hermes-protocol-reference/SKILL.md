---
name: hermes-protocol-reference
description: >
  Load this skill whenever you need to understand or modify how Conduit talks to the
  Hermes dashboard: the WebSocket JSON-RPC protocol (/api/ws), the auth/ticket flow
  (NativeAuthClient, DashboardTicketBridge, AuthWebView), any RPC method name
  (session.resume, prompt.submit, config.set, session.steer, session.redirect,
  llm.oneshot, projects.tree, ...), stream event types (message.delta, session.busy,
  approval.request, clarify, subagent.*), streaming/turn-state semantics
  (inflight/queued, running, TurnState), dashboard REST endpoints
  (/api/profiles/sessions, /api/sessions/{id}/messages, /api/config, /api/audio/*),
  or the voice speech-stream protocol. Triggers: "what RPC does X use", "which event
  carries Y", "add a new RPC call", "message deltas not arriving", or an edit to
  HermesClient.swift, NativeAuthClient.swift, DashboardTicketBridge.swift,
  DashboardPath.swift, ConnectionURLPolicy.swift, HermesVoiceGateway.swift, or
  Models.swift ONLY when the edit changes what is sent or parsed on the wire (for
  general edits to those files the primary gate is conduit-architecture-contract;
  symptom triage such as "stuck on Synchronizing" belongs to
  conduit-debugging-playbook). This is the protocol reference the ws-reliability
  and debugging skills lean on.
---

# Hermes Protocol Reference (as the Conduit client sees it)

Everything below is verified against the source files listed in "Provenance and
maintenance" unless tagged `[candidate -- unverified]`. Server-side behavior is
described only as far as the client observably depends on it.

## Hard rules (never route around these)

1. **No telemetry, analytics, or tracking. Ever.** Hard privacy constraint (user-confirmed).
2. **Never contact the Hermes gateway directly.** ALL RPC goes through the dashboard
   WebSocket endpoint `/api/ws` (default dashboard port 9119, per README.md) after
   dashboard auth. The client never opens a socket to the gateway process itself.

## Glossary (define once, use everywhere)

| Term | Meaning |
|---|---|
| **Hermes Agent** | The self-hosted server. Runs a **gateway** (agent runtime) fronted by a **dashboard** (HTTP + WS server, default port 9119). Conduit only ever talks to the dashboard. |
| **Dashboard** | The native Hermes web dashboard (not the WebUI). Serves REST under `/api/*` and the JSON-RPC WebSocket at `/api/ws`. |
| **Ticket** | WebSocket auth token minted by `POST /api/auth/ws-ticket` using the dashboard's HttpOnly session cookie. Passed as `?ticket=` on the WS URL. Treated as single-use by the client (fresh ticket per (re)connect); server-side single-use/TTL enforcement is [candidate -- unverified]. |
| **Profile** | A Hermes-side workspace/identity. Non-`default` profiles are injected into every RPC's params (`scopeParams` in HermesClient.swift) and appended as `?profile=` on REST paths (DashboardPath.swift). |
| **Session** | One conversation. Has a runtime `session_id` and possibly a distinct `stored_session_id` (SQLite identity). Alternate IDs are tracked in `SessionSummary.alternateIds`. |
| **Turn** | One user-prompt-to-assistant-completion cycle. `running` from `session.resume`/`session.info` is the authoritative turn state (Models.swift `TurnState`). |
| **Bridge** | `DashboardTicketBridge`: a hidden WKWebView that holds the dashboard's HttpOnly cookie and executes `fetch()` on Conduit's behalf (ticket minting + all dashboard REST). |
| **Steer / Redirect / Interrupt** | Three ways to affect a running turn: inject guidance (`session.steer`), replace the goal (`session.redirect`), or stop it (`session.interrupt`). |

## Architecture: two transport planes

```
Conduit (iOS)
 ├─ Plane 1: WebSocket JSON-RPC  wss://<host>/api/ws?ticket=<ticket>
 │    HermesClient.swift — chat RPCs + stream events. TEXT frames only.
 └─ Plane 2: Dashboard REST      https://<host>/api/*
      ├─ NativeAuthClient.swift  — URLSession, login + first ticket only
      └─ DashboardTicketBridge.swift — WKWebView fetch(), cookie-authenticated,
         used for ticket refresh, session catalog, transcripts, config, voice, fs, cron
```

- URL policy (ConnectionURLPolicy.swift): `https` required; `http` allowed only for
  loopback hosts (`localhost`, `127.0.0.1`, `::1`). WS scheme is derived: `https -> wss`,
  `http -> ws`. Base URL must have no query/fragment/userinfo.
- RPC frames MUST be WebSocket **text** frames. Source comment in `HermesClient.rpc`
  states the gateway accepts the connection but does not dispatch binary JSON-RPC
  frames [candidate -- unverified: server behavior, asserted only by a client comment].
  Same for the voice stream: `HermesSpeechStream.sendJSON` comments "Hermes uses
  receive_json(), so these must be WebSocket text frames" [candidate -- unverified].

## Auth sequence (login -> ticket -> WS)

### Step 0 — Provider discovery (LoginView.swift `connect()`)

```
GET /api/auth/providers        (NativeAuthClient.authProviders)
-> { "providers": [ { "supports_password": true, ... } ] }
```

If any provider has `supports_password == true`, use the native path (Step 1a).
Otherwise present the web login sheet (Step 1b).

### Step 1a — Native password login (NativeAuthClient.swift)

```
POST /auth/password-login              body: {"provider":"basic","username":...,"password":...}
POST /api/auth/ws-ticket               -> {"ticket": "<opaque>"}
```

- Both go through `URLSession` with `HTTPCookieStorage.shared` so the HttpOnly
  session cookie lands in the shared native cookie jar.
- `SecureRedirectDelegate` blocks redirects that leave the origin or downgrade transport.
- Note the asymmetry: login is `/auth/password-login` (no `/api` prefix); ticket
  minting is `/api/auth/ws-ticket`.

### Step 1b — Web login (LoginView.swift `AuthWebView`)

1. WKWebView loads `<base>/login`.
2. On `didFinish` for any same-origin, non-`/login` URL, injected JS runs
   `fetch('/api/auth/ws-ticket', {method:'POST', credentials:'include'})` and posts
   `{type:'hermes-ticket', status, ticket}` to the `ticket` script message handler.
3. The handler validates main-frame + origin (scheme/host/port of
   `WKSecurityOrigin`) before accepting. Status 401 is ignored (still on sign-in).
4. On success, saved password credentials are cleared (OAuth gives no reusable
   password) and `appState.connect(with: HermesConnection(baseUrl:ticket:))` runs.

### Step 2 — WS connect (HermesClient.connect)

```
wss://<host>/api/ws?ticket=<ticket>
```

- Built via `ConnectionURLPolicy.webSocketURL(baseURL:path:"/api/ws", queryItems:[ticket])`.
- The client waits for the URLSession WebSocket delegate `didOpenWithProtocol`
  callback before declaring connected (15 s open timeout, `waitForSocketOpen`).
  Sending RPCs before that callback can race the handshake — this is deliberate,
  do not remove the delegate wait.
- There is **no application-level handshake message**: after socket open, the first
  traffic is a normal RPC (typically `session.list` via `syncSession`/`healthCheck`).

### Step 3 — Ticket refresh on reconnect (DashboardTicketBridge.swift)

Tickets are effectively single-use per connection: every reconnect mints a fresh
one (AppState `reconnect()` always calls `dashboardTicketBridge.mintTicket()`)
[candidate -- unverified: server-side single-use enforcement; the client behaves as
if tickets cannot be reused].

The bridge's mechanics:

- A hidden WKWebView loads `<base>/api/status` to establish "ready". Ready means:
  navigation finished, same origin, and the final URL path does not contain `/login`.
- Cookies: on init/reload the bridge restores (1) Keychain-persisted dashboard
  cookies (`DashboardCookiePersistence.restore`) and (2) native URLSession cookies
  for the host (`restoreNativeCookies`) into WebKit's cookie store — URLSession and
  WebKit have **separate** cookie jars, so the password-login session must be copied
  over explicitly. After every successful ready navigation the WebKit cookies are
  captured back to Keychain.
- `mintTicket()` retries on 401/403 (`signInRequired`) with a bridge reload between
  attempts, because a freshly restored cookie can reach WebKit's cookie store before
  its network process (retry counts/delays: conduit-ws-reliability-campaign Phase 1.1).
- `requestJSON(path:method:body:)` executes an injected `fetch()` with
  `credentials:'include'`, enforces a response-size cap (streams and aborts over
  `DataURLLimits.maxJSONResponseBytes`), wraps arrays as `{_array: [...]}` and
  scalars as `{value: ...}`, and resolves via the `dashboard-response` script
  message handler. 401/403 -> `signInRequired`; other non-OK -> `requestFailed`.
- **User-reported history:** this bridge is one of the costliest past failure areas.
  WKSecurityOrigin reports port 0 for default-port connections; a literal port
  comparison silently dropped all bridge responses (stuck on "Synchronizing") —
  fixed in d0873ec, full mechanism in conduit-failure-archaeology entry 1. Keep the
  `effectivePort` port-0-as-nil invariant when touching origin matching.

### Reconnect / expiry recovery order (AppState.swift `reconnect()`)

Auth-sequence facts this reference owns:

1. Mint fresh ticket via bridge -> new `HermesClient` -> `connect()` -> `syncSession()`.
2. If bridge says `signInRequired` and saved `DashboardCredentials` match the host:
   silent re-login via `NativeAuthClient.connect(username:password:)`, then
   `bridge.reload()` (cookie stores are separate), then connect.
3. Otherwise `requireSignIn(...)` — clears connection + bridge and shows login.

Retry/backoff numbers and the rest of the reconnect machinery are owned by
**conduit-ws-reliability-campaign** (Phase 1.1).

`HermesConnection { baseUrl, ticket }` is persisted in Keychain and is the first
cold-start attempt; the bridge is only consulted when that socket fails.

## JSON-RPC envelope

Request (client -> server, text frame):

```json
{"jsonrpc":"2.0","id":42,"method":"session.resume","params":{"session_id":"...","cols":96,"source":"desktop"}}
```

Response (server -> client): `{"id":42,"result":{...}}` or
`{"id":42,"error":{"code":...,"message":"..."}}`.

Server-push notification (no `id`):

```json
{"method":"event","params":{"type":"message.delta","session_id":"...","payload":{"text":"..."}}}
```

Rules encoded in `HermesClient`:

- `id` is a monotonically increasing Int per client instance.
- Profile scoping: `scopeParams` adds `"profile": <profile>` to every request's
  params unless the profile is `"default"` (then non-default-only).
- Responses correlate by `id`; unmatched ids are logged and dropped. Undecodable
  frames are dropped (logged with byte count).
- Per-request timeout via `Timer`; on timeout the pending continuation throws
  `HermesError.timeout(method)`. Disconnect fails all pending requests with
  `connectionClosed`.

### Timeouts (HermesClient constants + per-call overrides)

| Operation | Timeout |
|---|---|
| Default RPC | 30 s (`requestTimeout`) |
| `prompt.submit` | 180 s (`promptSubmitTimeout`) |
| `llm.oneshot` (title gen) | 90 s (`titleGenerationTimeout`) |
| `pdf.attach`, `file.attach` | 120 s |
| Health check (`session.list`) | 8 s |
| WS open handshake | 15 s |
| Bridge `requestJSON` default | 12 s (JS AbortController) |
| Voice transcribe / speak fallback | 90 s |
| Voice stream finish -> fallback | 20 s |

## RPC method catalog (complete — every method the client sends)

All call sites verified by grep. "AppState" = Conduit/Services/AppState.swift.

| RPC method | Params (beyond auto `profile`) | Purpose | Swift API (HermesClient) | Called from |
|---|---|---|---|---|
| `session.list` | none | List sessions (also used as health check) | `sessions()`, `healthCheck()` | AppState:2178 (fallback filter), AppState:1194 (scene-active health check) |
| `session.resume` | `session_id`, `cols:96`, `source:"desktop"` | Open/attach a session; returns messages + runtime snapshot (`running`, `info`, `inflight`, `queued`) | `openSession(_)` | AppState:810 |
| `session.create` | `cols:96`, `source:"desktop"`, opt `profile`, `model`, `provider`, `reasoning_effort`, `fast`, `cwd` | New session | `createSession(...)` | AppState:890 |
| `session.create` (branch form) | + `parent_session_id`, `title`, `messages:[{role,content}]` | Fork a session from a message prefix | `branchSession(...)` | AppState:1511 |
| `session.title` | `session_id`, `title` | Set title | `setSessionTitle(_:title:)` | AppState:1525, 3291 |
| `session.title` | `session_id` only | Read current title | `sessionTitle(_)` | AppState:3271 |
| `llm.oneshot` | `session_id`, `task:"title_generation"`, `instructions`, `input`, `max_tokens:500`, `temperature:0.3` | Generate a title without adding a message | `generateSessionTitle(...)` | AppState:3283 |
| `prompt.submit` | `session_id`, `text` | Send a user prompt | `sendPrompt(_:text:)` | AppState:1632 |
| `session.steer` | `session_id`, `text` | Inject guidance into a running turn; `{status:"rejected"}` -> `HermesError.steerRejected` | `steer(_:text:)` | AppState:1979 |
| `session.redirect` | `session_id`, `text` | Correct/replace the active turn; result `status`: `redirected` / `queued` (both success) / else rejected | `redirect(_:text:)` | AppState:1996 |
| `session.interrupt` | `session_id` | Stop the running turn | `cancel(_)` | AppState:2082 |
| `clarify.respond` | `request_id`, `answer` | Answer a clarification card | `respondToClarification(...)` | AppState:2118 |
| `approval.respond` | `choice`, `session_id` | Answer a command-approval card (session IS the request identity; no request id) | `respondToApproval(...)` | AppState:2503 |
| `model.options` | `explicit_only:true`, opt `session_id` | Providers/models catalog + current selection | `modelOptions(sessionId:)` | ModelPickerView:375 |
| `config.set` | `key:"busy"`, `value:"status"` | **Read** busy-input mode (yes: reading is done by writing the sentinel value `"status"`) | `busyInputMode()` | AppState:3161 |
| `config.set` | `key:"busy"`, `value:"steer"|"interrupt"` | Set busy-input mode | `setBusyInputMode(_)` | AppState:3174 |
| `config.set` | `key:"model"`, `session_id`, `value:"<model> --provider <provider> --session"` | Set session model (CLI-style value string) | `setModel(...)` | ModelPickerView:396 |
| `config.set` | `key:"reasoning"`, `session_id`, `value:<effort or "none">` | Set reasoning effort | `setReasoning(...)` | ModelPickerView:400 |
| `config.set` | `key:"fast"`, `session_id`, `value:"fast"|"normal"` | Toggle fast mode | `setFast(...)` | ModelPickerView:402 |
| `config.set` | `key:"yolo"`, `session_id`, `value:"1"|"0"` | Session-only approval bypass | `setSessionYolo(...)` | AppState:1649 |
| `session.context_breakdown` | `session_id` | Token/context usage breakdown | `contextBreakdown(_)` | AppState:1065, AuxiliaryViews:80 |
| `commands.catalog` | opt `session_id` | Slash-command catalog | `commandsCatalog(sessionId:)` | AppState:1782 |
| `slash.exec` | `session_id`, `command` (leading `/` stripped) | Execute a slash command | `executeSlash(...)` | AppState:1899 |
| `command.dispatch` | `session_id`, `name`, `arg` | Dispatch a named command with argument | `dispatchCommand(...)` | AppState:1902 |
| `image.attach_bytes` | `session_id`, `content_base64`, `filename` | Attach image; returns `{path}` | `attachImage(...)` | AppState:1614 |
| `pdf.attach` | `session_id`, `content_base64`, `filename` | Attach PDF | `attachPdf(...)` | AppState:1618 |
| `file.attach` | `session_id`, `data_url`, `name`, `path` | Attach arbitrary file | `attachFile(...)` | AppState:1622 |
| `projects.tree` | `preview_limit:3` | Server-owned project tree (optional gateway capability) | `projects()` | AppState:2538 |
| `projects.project_sessions` | `project_id` | Sessions grouped by repo/group lanes | `projectSessions(_)` | AppState:2571 |
| `projects.create` | `name`, `folders`, `primary_path`, `use:true` | Create project | `createProject(...)` | AppState:2598 |
| `cron.list` | none | Cron jobs (`{jobs:[...]}` or bare array) | `listCronJobs()` | AppState:2808 |
| `cron.runs` | none | Cron run history | `cronRuns()` | AppState:2831, 2841 |

**Critical caution (from the file-header lesson block, RN builds 17-30):** do NOT
merge gateway `session.list` results into the UI session list — it reads the main DB
containing ALL profiles. The UI catalog comes from the profile-scoped REST endpoint
`/api/profiles/sessions` (see REST table). `session.list` is only for health checks
and existence filtering.

## Stream event catalog (server -> client notifications)

Dispatched in `HermesClient.handleStreamEvent` from
`{"method":"event","params":{"type","session_id","payload"}}` into the `StreamEvent`
enum consumed by AppState's `onEvent`. Alias type strings are accepted exactly as
listed.

| Event `type` (aliases) | Payload fields read | StreamEvent case |
|---|---|---|
| `message.start` | — | `.messageStart` |
| `message.delta` | `payload.text` (fallback top-level `text`) | `.messageDelta` |
| `reasoning.delta`, `message.reasoning`, `message.reasoning.delta` | `reasoning` / `reasoning_content` / `text` / `content` (payload then top-level) | `.reasoningDelta` |
| `message.complete` | `message_id`/`id`/`message.id`; `content`/`text`/`rendered`; `reasoning` | `.messageComplete` |
| `error` | `payload.message` | `.messageError` |
| `message.interrupted`, `session.interrupted` | — | `.messageInterrupted` |
| `session.busy` | `payload.busy` (Bool) | `.sessionBusy` |
| `session.info` | full runtime snapshot object | `.sessionInfo(SessionRuntimeSnapshot)` |
| `session.title` | `payload.session_id` (stored id), `payload.title`; event-level `session_id` is the runtime id | `.sessionTitle(runtimeSessionId:storedSessionId:title:)` |
| `tool.start`, `tool_call` | `name`; input from `args_text`/`context`/`input`/`arguments`/`args` | `.toolStart` |
| `tool.complete`, `tool_result` | `name`; output from `output`/`result` | `.toolComplete` |
| `review.summary` | text beginning `💾 Self-improvement review:` + optional details/child session id | `.reviewSummary` |
| `clarify`, `clarify.request` | `request_id`/`requestId`/`id`; `question`/`prompt`/`text`; `choices`/`options` (strings or `{label,value}` objects) | `.clarify` |
| `approval.request` | `command`/`code`/`text`; `description`/`message`/`prompt`; `choices` (strings); `allow_permanent`; `smart_denied` | `.approval(ApprovalActivity)` |
| `context.update`, `session.context` | `context_percent`, `context_used`, `context_max` | `.contextUpdate` |
| `cwd.update`, `workspace.update` | `cwd` | `.cwdUpdate` |
| `model.update` | `model`, `provider` | `.modelUpdate` |
| `subagent.*` (any prefix match) | `id`/`agent_id`, `status` (or inferred from suffix: fail/interrupt/complete/finish/spawn), `goal`/`task`, `text`/`message`/`summary`, `tool`, `task_count`, `task_index` | `.delegateAgent(DelegateAgentActivity)` |
| anything else | raw object | `.unparsed(payload:)` |

Note: `StreamEvent.agentCount` exists in the enum but no event type currently
produces it — do not assume a wire event feeds it.

## Streaming and turn-state semantics

- A turn streams as: `message.start` -> N x `message.delta` / `reasoning.delta`
  (+ `tool.start`/`tool.complete`) -> `message.complete` (or `error` /
  `message.interrupted`). `session.busy` toggles around it.
- **Authoritative liveness:** `running` from `session.resume` / `session.info` is
  the single source of turn truth (`TurnState.fromGatewayRunning`). A missing
  `running` field means the gateway is too old for safe stop/steer controls ->
  `TurnState.unsupportedGateway`. Never derive liveness from transcript shape or
  the last stream event (file-header lesson, RN builds 17-30).
- **Resume projection:** `session.resume` may return `inflight`/`queued` objects
  newer than the persisted transcript. `SessionRuntimeSnapshot.hasLiveProjection`
  mirrors Desktop's `Boolean(resumed.inflight || resumed.queued)` — in particular
  `queued: false` must NOT hide the durable transcript.
  `inflightAssistantText` (from `inflight.assistant|text|content`) is the prefix a
  resumed live turn needs before accepting new deltas.
- In the resume result, top-level `running`/`status` override the same keys inside
  `info` (the resume response owns liveness; `info` supplies the rest).
- Runtime snapshot field aliases: `active_agents`|`active_subagents`,
  `reasoning_effort`|`reasoning`, `fast`|`fast_mode`,
  `approvals_mode`|`approval_mode`|`approvals.mode`.
- `context_percent` has been observed both as 0..1 and 0..100 across Hermes
  versions; `ContextBreakdown.resolvedPercent` normalizes (prefer token totals).
- Busy-input semantics: while running, typed text becomes **steer** or
  **interrupt** per the profile's `BusyInputMode` (`display.busy_input_mode` on the
  Hermes side per Models.swift doc comment); empty composer -> Stop
  (`TurnState.composerAction`). `session.redirect` returning `queued` is still a
  successful delivery (correction accepted during the turn-build window).
- Message normalization (transcript + events) lives in `MessageNormalizer`
  (bottom half of HermesClient.swift): envelope unwrapping (`message`/`payload`/
  role-bearing `data`), tool-call/result pairing by `tool_call_id` (ID is
  authoritative; name fallback only for legacy rows), `@image:` token extraction
  into attachments, `[System: ...]` notices, model-change detection, duplicate
  interrupt-correction collapsing.

## Dashboard REST endpoint catalog (via DashboardTicketBridge.requestJSON unless noted)

Non-default profiles get `?profile=<urlencoded>` appended (DashboardPath.withProfile).

| Endpoint | Method | Used for | Call site |
|---|---|---|---|
| `/api/auth/providers` | GET | Password-capable provider discovery (URLSession) | NativeAuthClient:57 |
| `/auth/password-login` | POST | Native login (URLSession) | NativeAuthClient:73 |
| `/api/auth/ws-ticket` | POST | Mint WS ticket (URLSession at login; bridge on reconnect; injected JS in AuthWebView) | NativeAuthClient:92, DashboardTicketBridge:160, LoginView:286 |
| `/api/status` | GET | Bridge readiness page + diagnostics | DashboardTicketBridge:280, AppState:3778 |
| `/api/profiles` | GET | Profile list | AppState:2468 |
| `/api/profiles/sessions?limit=200&offset=N&min_messages=1&archived=exclude|only&order=recent&exclude_sources=cron` (or `&source=cron`) | GET | THE profile-scoped session catalog (active / archived / cron variants) | AppState:2311, 2318, 2357 |
| `/api/sessions/{id}` | PATCH `{"archived":bool}` / DELETE | Archive-restore / delete a session | AppState:1298, 1337 |
| `/api/sessions/{id}/messages` | GET | Persisted rich transcript (may resolve runtime id -> stored id; older gateways can omit this endpoint — resume path is the fallback) | AppState:2234 |
| `/api/config` | GET/PUT | Profile configuration | AppState:2947+ (many), HermesVoiceConfigurationService:114,157,164 |
| `/api/config/schema` | GET | Config schema | HermesVoiceConfigurationService:113 |
| `/api/env` | GET/PUT | Environment values | HermesVoiceConfigurationService:117,183 |
| `/api/model/options?explicit_only=true`, `/api/model/info`, `/api/model/set` | GET/GET/POST | Model catalog + selection via REST plane | AppState:3006-3031 |
| `/api/skills`, `/api/skills/toggle` | GET/POST | Capability skills | AppState:2698, 2729 |
| `/api/tools/toolsets`, `/api/tools/toolsets/{name}`, `/api/tools/toolsets/stt|tts/config` | GET/PATCH | Toolsets + voice toolset config | AppState:2699, 2753; HermesVoiceConfigurationService:115-116 |
| `/api/dashboard/plugins/hub`, `/api/dashboard/plugin-providers` | GET/PUT | Plugin hub | AppState:2982, 3064 |
| `/api/cron/jobs`, `/api/cron/jobs/{id}/runs?limit=20`, `/api/cron/jobs/{id}/{action}` | GET/GET/POST | Cron management (RPC `cron.list`/`cron.runs` are the fallback) | AppState:2802-2864 |
| `/api/fs/list?path=`, `/api/fs/read-text?path=`, `/api/fs/read-data-url?path=`, `/api/fs/write-text` | GET/POST | Server-side file browsing/editing | AppState:2637-2661, 3702-3753 |
| `/api/messaging/platforms`, `/api/logs?lines=80&component=gateway` | GET | Diagnostics view | AppState:3779-3780 |

Push notifications do NOT go to the dashboard: `PushNotificationService` talks to a
separate relay (default `https://push.milim.dev`, overridable via
`conduit.relayURL` UserDefaults key / notification settings; see commits e3cdb49,
e4318c5, 859162b). That relay is out of scope here — see **conduit-config-and-flags**.

## Voice protocol (HermesVoiceGateway.swift)

Voice rides both planes; deeper pipeline behavior is **conduit-voice-pipeline**'s domain.

1. **Transcription (REST via bridge):**
   `POST /api/audio/transcribe[?profile=]` body `{"data_url": <wav data url>, "mime_type":"audio/wav"}`,
   90 s timeout. Response: `{transcript}` or `{text}`; `{error}` throws. An EMPTY
   transcript is intentional (quiet audio / filtered hallucination) and means
   re-listen, not failure.
2. **Speech streaming (dedicated WS):**
   `wss://<host>/api/audio/speak-stream?ticket=<fresh ticket>&profile=<profile>` —
   the bridge mints a fresh ticket for this socket too.
   - Client sends text frames: `{"text": "<chunk>"}` per appended chunk, then
     `{"done": true}` to finish.
   - Server sends: JSON control frames `{"type":"start","sample_rate":N}` (default
     24000), `{"type":"end"}`, `{"type":"fallback"}`, `{"type":"error","message":...}`;
     and **binary frames of raw PCM16 audio** (any binary frame that does not parse
     as JSON is PCM).
3. **Fallback TTS (REST):** if no PCM arrives (20 s finish timeout, `fallback`
   control, or socket error), `POST /api/audio/speak[?profile=]` body `{"text": <all accumulated text>}`
   -> `{data_url}` (base64 audio, decoded via `DataURLLimits.decodeBase64DataURL`).

## Core data model quick map (Models.swift)

| Type | Role |
|---|---|
| `HermesConnection` | `{baseUrl, ticket}` — the persisted connection |
| `SessionSummary` | Catalog row: `id`, `alternateIds`, `title`, `model`, `profile`, `source` (chat/discord/telegram/api/webhook/cron/other), `isArchived`, `lineageRootId` |
| `ChatMessage` | Transcript row: `role` (user/assistant/reasoning/system/partial/tool/clarify/approval), `content`, `rawContent`, `tool`, `review`, `clarify`, `approval`, `attachments` |
| `ToolActivity` | `{id, name, input, output, status: running|complete}` |
| `ClarifyActivity` / `ApprovalActivity` | Interactive cards; approval keys on `sessionId`, clarify on `requestId` |
| `TurnState` | synchronizing / idle / running / reconnecting / unsupportedGateway; drives `ComposerAction` (send/stop/steer/interrupt) |
| `BusyInputMode` | steer | interrupt (profile-scoped Hermes setting) |
| `SessionRuntimeSnapshot` (HermesClient.swift) | Runtime fields from resume/info incl. `running`, `inflight`, `queued` |
| `ProjectSummary` / `ProjectSessionDetail` / `ProjectSessionLane` | Server-owned `projects.*` grouping — never inferred locally |
| `CronJob` / `CronRun` | Cron metadata (snake_case CodingKeys) |
| `CapabilitySkill` / `CapabilityToolset` / `CapabilityMcpServer` / `SlashCommand` | Capability surfaces fed by REST + `commands.catalog` |
| `GatewayDiagnostics` / `GatewayConnector` | `/api/status` + logs view model |

## When NOT to use this skill

| If the task is... | Use instead |
|---|---|
| Diagnosing reconnect loops, stale sessions, resume-after-background bugs | **conduit-ws-reliability-campaign** (it applies this reference) |
| General bug triage / logging / repro workflow | **conduit-debugging-playbook** |
| AVAudioSession, wake word, TTS playback internals | **conduit-voice-pipeline** |
| Past incidents (auth bridge history, App Store failures) | **conduit-failure-archaeology** |
| App-level layering rules (who owns state, AppState vs HermesClient) | **conduit-architecture-contract** |
| Settings keys, UserDefaults, push relay configuration | **conduit-config-and-flags** |
| Building, signing, running, QA | **conduit-build-and-env**, **conduit-run-and-operate**, **conduit-appstore-and-signing**, **conduit-validation-and-qa** |

## Provenance and maintenance

Ground truth verified at commit `859162b` (main).
Primary sources (all paths repo-relative to
`/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`):
`Conduit/Services/HermesClient.swift`, `Conduit/Models/Models.swift`,
`Conduit/Services/NativeAuthClient.swift`, `Conduit/Services/DashboardTicketBridge.swift`,
`Conduit/Services/DashboardPath.swift`, `Conduit/Services/ConnectionURLPolicy.swift`,
`Conduit/Services/AppState.swift`, `Conduit/Views/LoginView.swift`,
`Conduit/Voice/HermesVoiceGateway.swift`, `README.md`.

### One-line re-verification commands

```bash
# WS endpoint path and ticket query param
grep -n '"/api/ws"' Conduit/Services/HermesClient.swift
# Full RPC method list (every string passed to rpc())
grep -n 'rpc("' Conduit/Services/HermesClient.swift
# Stream event type dispatch table
grep -n 'case "' Conduit/Services/HermesClient.swift | sed -n '1,40p'
# Profile scoping of RPC params
grep -n 'scopeParams' Conduit/Services/HermesClient.swift
# Timeout constants
grep -n 'Timeout\|timeout:' Conduit/Services/HermesClient.swift | head -20
# Auth REST paths
grep -n '"/api/auth\|password-login' Conduit/Services/NativeAuthClient.swift Conduit/Views/LoginView.swift Conduit/Services/DashboardTicketBridge.swift
# Bridge readiness + login detection + ticket retry loop
grep -n 'api/status\|/login\|attempt' Conduit/Services/DashboardTicketBridge.swift
# WKSecurityOrigin port-0 fix
git log --oneline -1 d0873ec && grep -n 'effectivePort' Conduit/Services/ConnectionURLPolicy.swift
# Dashboard REST endpoints in use
grep -rn '"/api' Conduit --include='*.swift'
# HermesClient call sites (RPC -> UI mapping)
grep -rn 'client\.' Conduit/Services/AppState.swift | grep -v '// ' | head -50
# Voice endpoints and speech-stream control types
grep -n 'api/audio\|"type"\|sample_rate\|done' Conduit/Voice/HermesVoiceGateway.swift
# Default dashboard port claim
grep -n '9119' README.md
# Reconnect backoff
grep -n 'pow(2.0' Conduit/Services/AppState.swift
# Push relay default (out of scope here, but referenced)
grep -n 'push.milim.dev\|conduit.relayURL' Conduit/Services/PushNotificationService.swift
```

### Run log

- 2026-08-08 (build): initial authoring
