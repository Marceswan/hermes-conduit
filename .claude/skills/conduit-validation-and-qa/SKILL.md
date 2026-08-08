---
name: conduit-validation-and-qa
description: >
  Load this skill when working with tests in the Hermes Conduit iOS repo:
  writing a new test, deciding whether a change needs a test, understanding
  what an existing test pins, running the ConduitTests suite, or judging
  whether a change is "done." Triggers: any edit under ConduitTests/;
  questions like "is this covered by tests?", "how do I add a test?",
  "what do the tests check?", "what is untested?"; failures in
  MessageNormalizerTests, VoiceConversationControllerTests,
  SecurityBoundaryTests, TurnStateTests, WakeLifecycleTests,
  WakePhraseCompilerTests, WakeConfigurationStoreTests, or
  HermesVoiceConfigurationServiceTests; changes to MessageNormalizer,
  TurnState, ConnectionURLPolicy, VoiceConversationController, or the
  Wake/ subsystem (all of which carry pinned regression tests that will
  break if you change behavior); and pre-merge "definition of done" checks.
---

# Conduit Validation and QA

This skill owns: what counts as evidence in this repo, the complete test
inventory, the established test-double patterns, the honest coverage gaps,
how to run tests, how to add tests, and the definition of done.

Jargon used once, defined once:

| Term | Meaning here |
|---|---|
| Gateway | The Hermes Agent backend the dashboard fronts. The app NEVER talks to it directly (project hard rule 2); all RPC goes through the dashboard WebSocket `/api/ws` (default port 9119) after dashboard auth. |
| Dashboard | The self-hosted Hermes web dashboard the app authenticates against. |
| Turn state | Whether the assistant is running a turn; drives which composer button shows (`TurnState` in `Conduit/Models/Models.swift:380`). |
| Normalizer | `MessageNormalizer` (`Conduit/Services/HermesClient.swift:1195`), the pure functions that convert raw gateway/dashboard JSON payloads (`AnyCodable`) into UI model types. |
| Wake | The on-device wake-word subsystem under `Conduit/Voice/Wake/`. |
| VAD | Voice activity detection: audio-level thresholds that decide when an utterance starts/ends. |
| Test double | A hand-written mock/fake conforming to a production protocol, injected through an initializer. No mocking framework is used in this repo. |

## What counts as evidence

Ranked strongest to weakest. When you claim a change works, say which of
these you have.

1. A new or updated XCTest in `ConduitTests/` that fails before your change
   and passes after. This is the only durable evidence; everything else
   evaporates when the session ends.
2. A full green run of the ConduitTests suite (all 8 files).
3. A manual on-device/simulator repro walk-through with the exact steps
   written down (see `conduit-run-and-operate` for launching).
4. "It compiles" is not evidence. "The diff looks right" is not evidence.

The suite is deliberately a regression-pinning suite: most tests encode a
specific past bug or a specific gateway payload shape that once broke the
UI (several test comments say so explicitly, e.g. "must not create a
duplicate card", "must not turn into an empty assistant row"). Treat every
existing assertion as a contract someone paid for. Do not weaken an
assertion to make your change pass; if a pinned behavior must change, that
is a `conduit-change-control` decision.

## Test inventory (all 8 files, verified)

Location: `/Users/marcswan/Documents/Code/personal/tools/hermes-conduit/ConduitTests/`
Total: 8 files, 1,588 lines (vs ~20,400 lines of app source). All are unit
tests (`@testable import Conduit`). There are zero UI tests and no UI test
target.

| File | Lines | System under test (source file) |
|---|---|---|
| MessageNormalizerTests.swift | 507 | `MessageNormalizer` + `AppState` static helpers (`Conduit/Services/HermesClient.swift`, `Conduit/Services/AppState.swift`) |
| VoiceConversationControllerTests.swift | 669 | `VoiceConversationController` (`Conduit/Voice/VoiceConversationController.swift`) |
| SecurityBoundaryTests.swift | 51 | `ConnectionURLPolicy`, `DashboardPath`, `MarkupHTML`, `DataURLLimits` |
| TurnStateTests.swift | 61 | `TurnState`, `BusyInputMode`, `SessionRedirectOutcome`, `SessionRuntimeSnapshot` |
| WakeLifecycleTests.swift | 100 | `WakeLifecycleCoordinator`, `SherpaWakeWordService`, `WakeModelDescriptor` |
| WakePhraseCompilerTests.swift | 50 | `WakePhraseCompiler` |
| WakeConfigurationStoreTests.swift | 24 | `WakeConfigurationStore` |
| HermesVoiceConfigurationServiceTests.swift | 126 | `VoiceConfigurationParser` (`Conduit/Voice/HermesVoiceConfigurationService.swift`) |

### MessageNormalizerTests.swift — transcript/payload normalization

Key invariants pinned (each one is a past rendering bug or a gateway
payload quirk; details of the wire shapes belong to
`hermes-protocol-reference`):

- Resume dedupe: inflight assistant text already present in the persisted
  transcript is dropped; only the unpersisted continuation suffix survives
  (`AppState.unpersistedInflightAssistantText`).
- Session profile ownership: explicit `profile`, `profile_name`, or
  `profile_id` keys are honored; ownership is NEVER invented when the
  payload has none and no fallback profile is given. `message_count` /
  `messageCount` (number or string) both parse.
- Tool calls: a tool result attaches to its call by `tool_call_id` only —
  an ID mismatch must NOT attach by name; an object-shaped (non-array)
  `tool_calls` metadata field must not create a duplicate tool card; a
  compact-resume tool `context` string becomes an input preview, never an
  output.
- Phantom rows: envelope objects with no role/content (e.g. Discord
  metadata) must not render as empty assistant messages.
- Desktop `@image:/path` references become attachments (name, uri, mime
  type inferred), preserving any caption text and `rawContent`.
- `[System: ...]` runtime notices rendered by the desktop client re-map to
  compact `.system` activities (model-change notice, cut-off notice);
  ordinary user sentences that merely resemble them stay `.user`.
- An interrupted-then-repeated identical user correction collapses to one
  user bubble plus one system row.
- Clarify activities accept both native string `choices` and legacy
  structured `options`; approval activities dedupe choices, keep
  `allow_permanent` / `smart_denied`, and fall back to description
  "Approval required" on a sparse event.
- Generated session titles are normalized for display (strips `Title:`
  wrappers, `<think>` blocks; whitespace-only -> nil) via
  `AppState.normalizedGeneratedSessionTitle`.

### VoiceConversationControllerTests.swift — voice turn state machine

The largest suite. Drives the controller purely through injected doubles
and synthetic audio levels (`ingestAudioLevel(_:at:)`) with short
`Task.sleep` settles. Key invariants pinned:

- PCM encoding: Float samples encode little-endian PCM16, clamped at
  +/-32767/-32768, NaN -> 0 (`VoicePCMEncoding` in
  `Conduit/Voice/AVAudioCaptureService.swift:267`).
- Permission gates: no capture without mic permission; denial produces
  `.failed("Microphone access is required for voice conversations.")`.
- VAD defaults mirror Hermes desktop: threshold 0.075, trailing silence
  1.25 s, idle silence 12 s, max utterance 60 s, barge-in 0.3 s.
- Trailing silence triggers transcription then submit through the injected
  `submit` closure (the "authoritative seam" — AppState owns real sends).
- Apple on-device transcription mode bypasses the Hermes gateway
  transcriber entirely; older persisted `VoiceProfilePreferences` JSON
  without a mode defaults to `.hermes`.
- Barge-in requires sustained speech (>= 0.3 s) and calls the injected
  `interrupt` closure exactly once.
- Race-hardening (each pins a past live bug class): `stop()` during an
  in-flight transcription cannot submit or restart capture; an audio
  interruption during transcription cannot ghost-submit; a stale
  `.failed(sessionID:)` for a barged-in cancelled turn cannot fail the
  next turn; a new assistant `.started` transactionally cancels the old
  speech stream and opens a fresh one.
- Session scoping: assistant events for a different sessionID are ignored
  (typed chat and voice chat do not cross-talk).
- Transcript authority: the conversation transcript is built from
  authoritative completions even when output is muted; empty completions
  do not erase accumulated deltas; transcript persists until the next
  `beginVoiceTurn`.
- Mic pause/resume preserves state across listening/thinking/speaking/
  muted; idle silence pauses without failing the session.

Runtime AVAudioSession behavior is NOT tested here (doubles replace it) —
see `conduit-voice-pipeline` for the real audio-session rules and
`conduit-failure-archaeology` for the user-reported AVAudioSession
conflict history.

### SecurityBoundaryTests.swift — transport and injection boundaries

Small but load-bearing; it partially enforces project hard rule 2's
transport posture. Pins:

- Remote dashboards must be HTTPS; only loopback (`127.0.0.1`,
  `localhost`) may use HTTP (`ConnectionURLPolicy`).
- WebSocket URLs upgrade to `wss`, preserve a base-URL subpath (e.g.
  `/hermes` + `/api/ws` -> `/hermes/api/ws`), and keep query items.
- `DashboardPath` profile query components escape `/` and `&`.
- `MarkupHTML.jsonString` escapes `</script>`, U+2028, U+2029 so inline
  script serialization cannot break out of a script tag.
- `DataURLLimits` rejects oversized base64 BEFORE decoding.

Any change touching `ConnectionURLPolicy`, `DashboardPath`, `MarkupHTML`,
or `DataURLLimits` REQUIRES a new pinned test here. This is the
regression-pinning culture at its clearest: security boundaries only stay
fixed if every past hole has a test.

### TurnStateTests.swift — composer state contract

Pins the gateway->UI turn-state mapping that older builds got wrong (see
the "LESSONS FROM RN BUILDS 17-30" header comment in
`Conduit/Services/HermesClient.swift`):

- `running: true/false/nil` -> `.running` / `.idle` /
  `.unsupportedGateway` (missing `running` means the gateway is too old
  for safe chat controls).
- Only `.idle` and `.running` accept composer actions; `.synchronizing`,
  `.reconnecting`, `.unsupportedGateway` do not.
- Composer action matrix: send/stop/steer/interrupt/unavailable by state,
  text presence, and busy-input mode; unknown gateway busy-mode values
  default to `.steer`.
- Redirect outcomes: `"queued"` counts as delivered; nil/unknown ->
  `.rejected`.
- `SessionRuntimeSnapshot` preserves `running`, `status`, `model`,
  `provider`, `context_percent`, `active_subagents`, `inflight`.

### WakeLifecycleTests.swift — wake arm/disarm policy

- Wake arms ONLY when all of: foreground active, authenticated, gateway
  connected, mic permitted, voice state idle. Any other combination
  disarms.
- A service failure on arm records `lastFailureReason` and never leaves
  the service armed.
- `SherpaWakeWordService` is a packaging-gated stub: `availability` is
  `.unavailable(licenseReviewNote)` and `arm()` throws. Pinned metadata:
  sherpa-onnx version `1.13.2`, packaging status
  `.blockedPendingLicenseReview`, archive SHA256
  `68447f4f...cd3616a6`, per-asset checksums `.notRecorded`. If you ship
  the model pack, these assertions are the checklist you must update
  deliberately.

### WakePhraseCompilerTests.swift — phrase tokenization

- English phrases normalize (trim, collapse whitespace, lowercase) and
  compile to ARPAbet-style tokens; Chinese to pinyin-tone tokens; aliases
  are stable per (gateway, profile, phrase) and unique.
- Duplicate phrases across profiles are rejected; words/characters outside
  the tokenization tables are rejected with typed errors.
- Uses `WakeTokenizationTables.testFixtures` — a fixture table defined IN
  PRODUCTION CODE (`Conduit/Voice/Wake/WakePhraseCompiler.swift:69`) and
  injected via the compiler initializer. Follow this pattern for any
  table-driven component: ship a small `.testFixtures` static.

### WakeConfigurationStoreTests.swift — persistence

- Preferences are stored per `(gatewayID, profileID)` key; phrases are
  normalized and deduplicated on save; values survive re-instantiation
  from the same `UserDefaults`.
- Pattern: a throwaway `UserDefaults(suiteName: <UUID>)` with
  `defer { removePersistentDomain }`. Never test against
  `UserDefaults.standard`.

### HermesVoiceConfigurationServiceTests.swift — voice config parsing

- `VoiceConfigurationParser.parse` merges schema, profile config,
  STT/TTS readiness, and environment into a snapshot; provider options
  accept both bare strings and `{"value": ...}` objects.
- Credential metadata NEVER carries the redacted or secret value — only
  key, `is_set`, description. (Privacy-adjacent: hard rule 1.)
- Missing voice endpoints -> capability off with the exact user-facing
  reason string.
- Provider catalogs pin documented voices/fields (xiaomi_mimo voice list,
  stepfun field keys stay in `tts.stepfun.*`, local Whisper canonicalizes
  to id `local` with visible default model `base`).

## Test-double patterns (match these exactly)

The repo has ONE established pattern; new tests must follow it.

1. Seams are protocols declared in production code, mostly in
   `Conduit/Voice/VoiceTypes.swift` (`AudioCaptureService`,
   `SpeechPlaybackService`, `DeviceSpeechTranscriptionService`,
   `VoiceGatewayService`, `VoiceSpeechStream`, `WakeWordService`).
2. Doubles are hand-written `private final class Mock*` / `Fake*` at the
   bottom of the test file that uses them, marked `@MainActor` when the
   protocol is. They record interactions with simple counters and arrays
   (`startCount`, `appended`, `cancelCount`) exposed as
   `private(set) var`.
3. Injection is by initializer, never by global/singleton swapping.
   Behavior seams that would otherwise need a whole object are plain
   closures (`submit: { ... }`, `interrupt: { ... }`).
4. Event-driven doubles expose an `AsyncStream` plus an `emit(_:)` helper
   holding the continuation (see `MockCapture`); doubles that must
   simulate a hung async call hold a `CheckedContinuation` and resume it
   with `URLError(.cancelled)` on cancel (see `MockSpeechStream`).
5. Async settling uses short `try? await Task.sleep(nanoseconds:)`
   (20–200 ms) after stimulus, then plain assertions. No expectation
   polling helpers, no third-party test libraries, no mocking frameworks.
6. Pure logic (normalizer, parser, URL policy) is tested with literal
   `AnyCodable` / `[String: Any]` payloads copied from real gateway
   traffic — no doubles at all. Prefer this: push logic into pure static
   functions so it can be tested this way.
7. Persistence tests use isolated `UserDefaults` suites (see
   WakeConfigurationStoreTests pattern above).

## Coverage gaps (honest, verified by cross-referencing targets)

Cross-reference: 46 app source files, 8 test files. The tested surface is
almost entirely pure logic and the voice state machine. Untested:

- `HermesClient.swift` (1,936 lines): WebSocket transport, JSON-RPC
  request/response correlation, disconnect callbacks. Zero tests. Only
  its `MessageNormalizer` and `SessionRuntimeSnapshot` corners are
  covered.
- `AppState.swift` (4,405 lines): `syncSession()` — the SINGLE entry
  point for cold start, foreground refresh, and reconnect per its own
  comments — plus the reconnect backoff task, ticket refresh, and turn
  synchronization are all untested. Only two static pure helpers
  (`unpersistedInflightAssistantText`, `normalizedGeneratedSessionTitle`)
  have tests. This is the user-reported hardest live problem area
  (WS/session reliability) and it has no automated coverage — see
  `conduit-ws-reliability-campaign`.
- `DashboardTicketBridge.swift` (390 lines): the WKWebView cookie/ticket
  extraction bridge, site of the user-reported costliest bug class and of
  fix commit d0873ec (WKSecurityOrigin port mismatch) — no tests. A
  regression here is currently only catchable manually.
- `NativeAuthClient.swift`, `PushNotificationService.swift`,
  `BiometricAuth.swift`, `SessionPresentationCache.swift`,
  `ProfileAppearanceStore.swift`: untested.
- All of `Views/` (13 files) and `ConduitApp.swift`: no UI tests exist
  and there is no UI test target in `project.yml`.
- Real audio: `AVAudioCaptureService.swift` (except `VoicePCMEncoding`),
  `AVSpeechPlaybackService.swift`, `HermesVoiceGateway.swift`,
  `AppleOnDeviceSpeechTranscriber.swift` — the doubles replace exactly
  the code where the user-reported AVAudioSession conflicts lived, so
  green voice tests do NOT prove audio-session correctness on device.
- `PendingVoiceIntentStore.swift`, `StartVoiceConversationIntent.swift`.

Implication: for changes in any untested area, manual verification steps
(item 3 under "What counts as evidence") are mandatory, and extracting a
pure testable core (pattern 6/7 above) is strongly preferred over adding
untestable code to `AppState`/`HermesClient`.

## How to run the tests

- Xcode: generate the project if `Conduit.xcodeproj` is missing
  (`xcodegen generate`, per the header comment in `project.yml`), open
  `Conduit.xcodeproj`, press Cmd+U. [candidate -- unverified: `project.yml`
  defines no explicit scheme block, so the scheme wiring that Cmd+U uses
  is whatever xcodegen/Xcode auto-generate for the `Conduit` and
  `ConduitTests` targets.]
- CLI: see `conduit-build-and-env` / `conduit-diagnostics-and-tooling`
  for the exact `xcodebuild test` invocation and simulator destination
  used in this repo. Do not guess a destination string; a wrong one fails
  in a way that looks like a code problem.
- The test target is `ConduitTests` (`project.yml` lines 42–51): type
  `bundle.unit-test`, iOS platform, depends on target `Conduit`,
  `GENERATE_INFOPLIST_FILE: YES`.

## How to add a test (checklist)

1. Put the file in `ConduitTests/` named `<TypeUnderTest>Tests.swift`.
   Target membership is automatic: `project.yml` declares the whole
   `ConduitTests` path as the target's sources, so after adding a file
   run `xcodegen generate` to refresh the project and it is included.
   No manual Xcode target-membership clicking, and never edit
   `Conduit.xcodeproj` by hand.
2. Start with `import XCTest` and `@testable import Conduit`
   (`import Foundation` only if needed). Add `@MainActor` on the test
   class when the system under test is `@MainActor` (the voice and wake
   suites are; the pure-logic suites are not).
3. One `final class <Name>Tests: XCTestCase`. Test method names are long
   behavior sentences: `test<Condition><ExpectedOutcome>` (e.g.
   `testStopDuringTranscriptionCannotSubmitOrRestartCapture`). Name the
   invariant, not the method called.
4. Reuse the double patterns above. If the production code has no seam,
   add one the repo's way: a protocol in the production file (or
   `VoiceTypes.swift` for voice), initializer injection with the real
   implementation as the default argument. Adding a seam changes
   production code — keep it minimal and check
   `conduit-architecture-contract` first.
5. If you are testing payload parsing, paste the real JSON shape into
   `AnyCodable` literals and add a comment saying which real behavior it
   mirrors (the existing suites do this, e.g. "This mirrors an incidental
   object-shaped metadata field").
6. When pinning a bug fix: write the test first, confirm it fails on the
   pre-fix code, then fix. The test's name and comment should make the
   original bug reconstructible without git archaeology.
7. Never add a test that performs real network I/O, touches the real
   Hermes gateway/dashboard, uses `UserDefaults.standard`, or introduces
   any third-party dependency. (No telemetry or tracking in test code
   either — hard rule 1 has no test-target exemption.)

## Definition of done for a change

- [ ] Entire ConduitTests suite green (all 8 files — the suite is small;
      never run just your one file and call it done).
- [ ] A new pinned test is MANDATORY when the change (a) fixes any bug —
      pin the regression; (b) touches `ConnectionURLPolicy`,
      `DashboardPath`, `MarkupHTML`, `DataURLLimits`, or anything else on
      an auth/transport/injection boundary — extend
      SecurityBoundaryTests; (c) changes `MessageNormalizer` or payload
      parsing — extend MessageNormalizerTests with the new wire shape;
      (d) changes `TurnState`/composer mapping, voice state transitions,
      or wake arm/disarm policy.
- [ ] A new test is EXPECTED (justify skipping in the PR/commit notes)
      for any new pure function or any new protocol-seamed component.
- [ ] Changes in the untested surfaces listed above carry written manual
      verification steps instead, plus an extracted-and-tested pure core
      where feasible.
- [ ] No existing assertion weakened or deleted without a
      `conduit-change-control` record.
- [ ] Build/version bumps, signing, and deploy checks are NOT part of
      test-done — see `conduit-build-and-env` and
      `conduit-appstore-and-signing`.

## When NOT to use this skill

- Diagnosing a live failure or crash: `conduit-debugging-playbook`.
- WebSocket reconnect/stale-session/ticket-expiry work specifically:
  `conduit-ws-reliability-campaign` (this skill only tells you that area
  is untested).
- Wire formats, RPC methods, payload field meanings:
  `hermes-protocol-reference`.
- Audio-session, VAD tuning, TTS/STT runtime behavior on device:
  `conduit-voice-pipeline`.
- Running or operating the app, simulators, logs:
  `conduit-run-and-operate` and `conduit-diagnostics-and-tooling`
  (including the exact CLI test command).
- Build settings, xcodegen, signing, App Store review history:
  `conduit-build-and-env`, `conduit-appstore-and-signing`,
  `conduit-failure-archaeology`.
- Architecture rules and layering: `conduit-architecture-contract`.
- Feature flags and configuration defaults: `conduit-config-and-flags`.

## Provenance and maintenance

All facts verified by reading source on date: 2026-08-08. Re-verify with:

- Test file list and line counts:
  `wc -l /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/ConduitTests/*.swift`
- App source count vs tests:
  `find /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit -name "*.swift" | wc -l`
- ConduitTests target definition (sources path, dependency):
  `sed -n '42,51p' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/project.yml`
- No UI test target exists:
  `grep -n "ui-test\|UITest" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/project.yml` (expect no matches)
- MessageNormalizer location and functions:
  `grep -n "enum MessageNormalizer\|static func normalize\|clarifyActivity\|approvalActivity" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift`
- Reconnect logic lives in AppState (untested claim):
  `grep -n "reconnect\|func syncSession" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift | head`
- Tested AppState static helpers:
  `grep -n "unpersistedInflightAssistantText\|normalizedGeneratedSessionTitle" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift`
- Voice protocol seams:
  `grep -n "^protocol" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Voice/VoiceTypes.swift`
- VAD defaults still pinned:
  `grep -n "voiceActivityThreshold\|trailingSilence\|idleSilence\|maximumUtterance\|bargeInDuration" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/ConduitTests/VoiceConversationControllerTests.swift`
- Wake pack metadata (sherpa version, SHA256, packaging gate):
  `grep -n "1.13.2\|68447f4f\|blockedPendingLicenseReview" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/ConduitTests/WakeLifecycleTests.swift /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Voice/Wake/WakeModelDescriptor.swift`
- WakePhraseCompiler fixture pattern:
  `grep -n "testFixtures" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Voice/Wake/WakePhraseCompiler.swift`
- DashboardTicketBridge still untested (no test file):
  `ls /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/ConduitTests/ | grep -i ticket` (expect no matches)
- d0873ec fix (user-reported bug area, untested):
  `git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log -p d0873ec -- Conduit/Services/DashboardTicketBridge.swift | head -60`
- `/api/ws` path used by the client:
  `grep -n '"/api/ws"' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/HermesClient.swift`

Run log:

- 2026-08-08 (build): initial authoring
