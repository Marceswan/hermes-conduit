---
name: conduit-voice-pipeline
description: >
  Load this skill when working on Conduit's voice subsystem: anything under
  Conduit/Voice/ or Conduit/Voice/Wake/, VoiceConversationController,
  AVAudioCaptureService, AVSpeechPlaybackService, AppleOnDeviceSpeechTranscriber,
  HermesVoiceGateway, HermesVoiceConfigurationService, VoiceTypes,
  SherpaWakeWordService, WakePhraseCompiler, WakeLifecycleCoordinator,
  WakeConfigurationStore, WakeModelDescriptor, PendingVoiceIntentStore,
  StartVoiceConversationIntent, VoiceConversationSheet, VoiceSettingsView.
  Symptoms that route here: mic capture not starting, "Audio was interrupted.",
  AVAudioSession category/activation conflicts, wake word questions, barge-in
  not triggering, assistant speech not playing, TTS fallback loops, transcription
  returning empty, voice sheet stuck in "thinking", Siri "Talk to Conduit"
  shortcut, speech test buttons in settings, sherpa-onnx questions.
  Task types: adding a voice feature, changing turn-taking/VAD thresholds,
  debugging audio-session ownership, wiring the wake-word runtime, changing
  STT/TTS provider configuration.
---

# Conduit Voice Pipeline

End-to-end runbook for Conduit's voice subsystem: microphone capture ->
transcription (server Whisper on the Hermes host, or Apple on-device) ->
turn-taking -> streamed speech playback, plus the (currently dormant)
wake-word stack.

Jargon, defined once:

| Term | Meaning in this repo |
|---|---|
| Hermes | The self-hosted agent server. Conduit is its native iOS client. |
| Dashboard | Hermes' web UI/API surface. All Conduit RPC goes through it after dashboard auth. Conduit NEVER contacts the Hermes gateway process directly (project hard rule). |
| DashboardTicketBridge | `Conduit/Services/DashboardTicketBridge.swift` — hidden WKWebView that holds the dashboard auth cookie; exposes `requestJSON(path:method:body:...)` and `mintTicket()` for authenticated HTTP/WS. Owned by the conduit-architecture-contract skill; here we only consume it. |
| VAD | Voice activity detection: peak-level thresholding done client-side in `VoiceConversationController.ingestAudioLevel`. |
| Barge-in | User speaking over the assistant while it is thinking/speaking, which cancels the assistant turn and starts a new listen. |
| Turn | One user utterance + one assistant response inside a voice session. |
| Wake word | On-device hotword detection (sherpa-onnx design). Scaffolding only; not active in shipping builds (see Wake section). |
| STT / TTS / ASR | Speech-to-text / text-to-speech; ASR = automatic speech recognition (same thing as STT in this codebase's UI copy). |

## File map

All paths relative to repo root `/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`.

| File | Lines | Role |
|---|---|---|
| `Conduit/Voice/VoiceConversationController.swift` | 679 | THE orchestrator. State machine, VAD, turn-taking, barge-in, speech drain. `@MainActor ObservableObject`. |
| `Conduit/Voice/VoiceTypes.swift` | 235 | All voice enums/structs/protocols (`VoiceConversationState`, `AudioCaptureService`, `SpeechPlaybackService`, `VoiceGatewayService`, `WakeWordService`, ...). Deliberately SwiftUI-free so tests inject doubles. |
| `Conduit/Voice/AVAudioCaptureService.swift` | 289 | AVAudioEngine mic capture -> 16 kHz mono PCM16, pre-roll ring buffer, interruption/route-change observers. Owns session activation for capture. |
| `Conduit/Voice/AVSpeechPlaybackService.swift` | 135 | AVAudioEngine + AVAudioPlayerNode PCM16 streaming playback; AVAudioPlayer for encoded fallback audio. |
| `Conduit/Voice/AppleOnDeviceSpeechTranscriber.swift` | 132 | SFSpeechRecognizer with `requiresOnDeviceRecognition = true` always — audio never goes to Apple servers. |
| `Conduit/Voice/HermesVoiceGateway.swift` | 301 | Server voice endpoints: `/api/audio/transcribe`, `/api/audio/speak-stream` (WS), `/api/audio/speak` (fallback). Includes private `HermesSpeechStream`. |
| `Conduit/Voice/HermesVoiceConfigurationService.swift` | 511 | Loads/saves profile STT/TTS config and credential *presence* from the dashboard. `VoiceConfigurationParser` is pure and unit-tested. |
| `Conduit/Voice/Wake/SherpaWakeWordService.swift` | 98 | Adapter over `SherpaWakeRuntime` protocol. Does NOT import sherpa-onnx. |
| `Conduit/Voice/Wake/WakePhraseCompiler.swift` | 163 | Phrase -> phoneme/pinyin token compiler with validation errors and FNV-1a stable alias. |
| `Conduit/Voice/Wake/WakeLifecycleCoordinator.swift` | 51 | Arms/disarms wake service from a `WakeLifecycleSnapshot` (foreground + authed + connected + mic + idle). |
| `Conduit/Voice/Wake/WakeConfigurationStore.swift` | 73 | Device-local wake phrase prefs in UserDefaults key `conduit.wakeConfiguration.v1`. |
| `Conduit/Voice/Wake/WakeModelDescriptor.swift` | 74 | Metadata for the sherpa KWS model pack; `packagingStatus: .blockedPendingLicenseReview`. |
| `Conduit/Voice/Wake/PendingVoiceIntentStore.swift` | 49 | Single-slot handoff for "open voice" requests (Siri/composer) + `PendingVoiceIntentRouter`. |
| `Conduit/Intents/StartVoiceConversationIntent.swift` | 83 | App Intents / Siri entry ("Talk to Conduit"). Enqueues, never opens the mic itself. |
| `Conduit/Views/VoiceConversationSheet.swift` | 224 | Presentation-only sheet bound to the controller. |
| `Conduit/Views/VoiceSettingsView.swift` | 520 | Per-profile voice settings (providers, credentials, ASR/TTS test buttons, static wake-phrase notice). |
| `Conduit/Services/AppState.swift` (voice sections ~3824-4073, 1184-1219, 3396-3443) | — | Wiring: gateway construction, assistant event fan-out, scene phase, open/close voice, prefs persistence. |

## The state machine (VoiceConversationController)

States (`VoiceConversationState` in VoiceTypes.swift): `idle`, `listening`,
`transcribing`, `thinking`, `speaking`, `muted`, `failed(String)`.

Tunables (`VoiceConversationController.Configuration`, defaults asserted by
`testVoiceDefaultsMirrorHermesDesktopVAD` — user-reported: these mirror the
Hermes desktop VAD defaults):

| Knob | Default | Effect |
|---|---|---|
| `voiceActivityThreshold` | 0.075 | Peak PCM level (0...1) that counts as speech. |
| `trailingSilence` | 1.25 s | Silence after speech that ends the utterance. |
| `idleSilence` | 12 s | Listening with NO speech at all -> pause mic (not fail). |
| `maximumUtterance` | 60 s | Hard cap; utterance is finished regardless. |
| `bargeInDuration` | 0.3 s | Sustained speech over the assistant required to barge in. |

Transitions:

```
idle --startListening()--> listening
   (requires: foreground + gateway set + mic permission; else failed(...))

listening --trailingSilence OR maximumUtterance--> transcribing
listening --idleSilence with zero speech--> (stays listening, mic paused)

transcribing --transcript empty--> listening        (re-listen, NOT an error)
transcribing --transcript is a stop phrase--> interrupt() -> listening
transcribing --otherwise--> thinking  (+ submit(transcript) via AppState)

thinking --assistant .delta + speech stream onStart--> speaking
thinking/speaking/muted --sustained speech >= 0.3s--> barge-in:
    playback.stop, cancel drain, interrupt(), startListening(includePreRoll: true)
speaking --setOutputMuted(true)--> muted   (muted --unmute--> thinking)
speaking --assistant .completed + playback drained--> listening   (continuous loop)

any --assistant .failed (non-stale)--> failed(message)
any --assistant .interrupted--> idle
any --AVAudioSession interruption--> failed("Audio was interrupted.")
any --stop() / background / scene inactive--> idle
```

Concurrency guards you MUST preserve when editing:

- `operationGeneration: UInt64` — bumped by `stop()` and
  `failForAudioInterruption()`. Every async continuation checks
  `isCurrent(generation)` which also requires `isForegroundActive` and
  `isVoiceSessionActive`. A stale task silently returns.
- `speechDrainRevision: UInt64` — bumped by `cancelSpeechDrainAndStream()`;
  the drain loop checks `isSpeechDrainCurrent(operation:revision:)` after
  every await so a cancelled drain cannot resurrect playback.
- Assistant-event ownership: `beginVoiceTurn(sessionID:)` pins
  `expectedAssistantSessionID`; `receiveAssistantEvent` drops events for other
  sessions. `awaitedAssistantResponseStarted` gates `.completed`/`.failed`/
  `.interrupted` so a late terminal event from a barged-in turn cannot fail
  the NEXT turn (`isCancellationMessage` additionally filters stale
  "cancelled"/"canceled" failures). See tests
  `testStaleCancelledAssistantFailureAfterBargeInCannotFailNextVoiceTurn` and
  `testUnrelatedAssistantSessionIsIgnored`.
- Speech deltas are queued in `speechDeltas: [String]` and drained into ONE
  persistent `VoiceSpeechStream` per response
  (`testAssistantDeltasStayInOnePersistentSpeechStream`). The final
  `.completed` content is a recovery snapshot, only spoken if no delta arrived.

## AVAudioSession ownership map (READ BEFORE TOUCHING AUDIO)

User-reported: AVAudioSession conflicts between wake-word listening, speech
playback, and interruptions were a top-3 historical time sink. The complete,
verified inventory of every `setCategory`/`setActive` call in the app — there
are exactly four sites, all in `Conduit/Voice/`:

| # | Site | Call | When |
|---|---|---|---|
| 1 | `AVAudioCaptureService.configureSession()` (AVAudioCaptureService.swift:119) | `setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])` then `setPreferredSampleRate(16_000)` then `setActive(true)` | From `startListening`, `beginBargeInMonitoring`, `resume` |
| 2 | `AVAudioCaptureService.stop()` (line 116) | `try? session.setActive(false, options: .notifyOthersOnDeactivation)` | The ONLY deactivation in the app |
| 3 | `AVSpeechPlaybackService.start(sampleRate:)` (AVSpeechPlaybackService.swift:28) | `setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])` then `setActive(true)` | PCM streaming playback start |
| 4 | `AVSpeechPlaybackService.playEncodedAudioData(_:)` (line 74) | same as #3 | Encoded fallback audio |

Rules that fall out of this map:

- Category is ALWAYS `.playAndRecord` + `.voiceChat`. Capture and playback can
  therefore coexist (needed for barge-in: the mic tap stays live while the
  assistant speaks via `beginBargeInMonitoring`).
- Asymmetry to know about: capture requests `.allowBluetoothA2DP`; playback
  does not. Re-asserting the category from playback (#3/#4) while capture is
  running drops the A2DP option. [candidate -- unverified] whether this
  asymmetry is intentional or a latent route bug; do not "fix" silently — see
  conduit-change-control.
- Only `AVAudioCaptureService.stop()` deactivates the session. Playback never
  calls `setActive(false)`. If you add a deactivation anywhere else you will
  break barge-in and continuous conversation.
- Nothing outside `Conduit/Voice/` touches AVAudioSession (verified by grep;
  the Wake/ directory has zero AVAudioSession usage — the sherpa runtime that
  would capture audio is not present).
- There is NO `UIBackgroundModes` key in `Conduit/Info.plist`. Voice is
  foreground-only by design. `AppState.handleScenePhase` (AppState.swift:1184,
  invoked from RootView.swift:34) calls
  `voiceConversationController.setForegroundActive(false)` on `.inactive` and
  `.background` (background also closes the sheet), which runs `stop()` and
  releases the session. Never leave the mic running past foreground.
- Interruptions: `AVAudioCaptureService` observes
  `AVAudioSession.interruptionNotification`; on `.began` it calls `stop()` and
  yields `.interrupted`, which the controller turns into
  `failed("Audio was interrupted.")` via `failForAudioInterruption()`. There is
  deliberately no auto-resume on `.ended` — the user taps Listen again.
- Route changes (Bluetooth/wired): the capture tap is installed with
  `format: nil` so it follows the route's format; `handleRouteChange` only
  resets the AVAudioConverter lazily and restarts the engine if
  `shouldKeepEngineRunning`, then yields `.routeChanged` (controller just
  resets the barge-in timer). Do not tear the session down on route change.

Capture format facts: hardware format -> AVAudioConverter -> 16 kHz mono
Float32 -> PCM16 little-endian (`VoicePCMEncoding.encode`, tested by
`testFloatMicrophoneSamplesEncodeAsLittleEndianPCM16`). Tap buffers are
deep-copied before hopping to MainActor because AVAudioEngine recycles them.
Pre-roll ring buffer keeps the last 5 seconds (`maximumPreRollBytes =
16_000 * 2 * 5`) so barge-in capture includes what the user said while the
assistant was still talking (`startListening(includePreRoll: true)`).

## Transcription routes

`VoiceProfilePreferences.resolvedTranscriptionMode` selects the route; nil
(old prefs) decodes as `.hermes` (`testOlderVoicePreferencesDefaultToHermesTranscription`).

| Mode | Component | Mechanics |
|---|---|---|
| `.hermes` (default) | `HermesVoiceGateway.transcribe` | POST `/api/audio/transcribe` (+`?profile=<p>` when profile != "default", via `DashboardPath.withProfile`) through DashboardTicketBridge with body `{"data_url": "data:audio/wav;base64,...", "mime_type": "audio/wav"}`, 90 s timeout. Reads `transcript` or `text` from the JSON reply. Whisper runs on the Hermes HOST ("local" provider = host-local Whisper install, per VoiceSettingsView copy). Empty transcript = quiet audio/filtered hallucination -> controller re-listens, never fails. |
| `.appleOnDevice` | `AppleOnDeviceSpeechTranscriber` | Writes WAV to a temp file, `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true` (always — privacy hard rule), `shouldReportPartialResults = false`, `.dictation` hint, punctuation on. Availability gate: `AppleOnDeviceSpeechTranscriber.currentAvailability()` checks `supportsOnDeviceRecognition` for the current locale + authorization status. |

Server-side behavior beyond these request/response shapes is
[candidate -- unverified] from the client repo; see hermes-protocol-reference.

## Speech playback (TTS)

`HermesVoiceGateway.openSpeechStream` mints a one-shot auth ticket
(`bridge.mintTicket()`) and opens `URLSession` WebSocket to
`/api/audio/speak-stream?ticket=<t>&profile=<p>` on the dashboard base URL
(note: this voice WS is separate from the main `/api/ws` chat socket owned by
HermesClient — see conduit-ws-reliability-campaign).

Client -> server: JSON TEXT frames (`{"text": chunk}` per delta, then
`{"done": true}`) — the code comments that Hermes uses `receive_json()` so
binary frames would break it [candidate -- unverified server detail].

Server -> client, handled in `HermesSpeechStream`:

| Frame | Handling |
|---|---|
| Binary, non-JSON | Raw PCM16 -> `onPCM16(data, sampleRate)` -> `AVSpeechPlaybackService.enqueuePCM16` (odd trailing byte held in `remainder`; odd tail at `finish()` is discarded). |
| JSON `{"type":"start","sample_rate":N}` | `onStart(rate)` -> playback engine starts; default rate 24 000 if absent. |
| JSON `{"type":"end"}` | Stream completes successfully. |
| JSON `{"type":"fallback"}` | Server opts out of streaming -> HTTP fallback (below). |
| JSON `{"type":"error","message":...}` | Stream fails. |

Fallback path: POST `/api/audio/speak` with `{"text": <all accumulated text>}`,
response `data_url` (or `dataUrl`) decoded to an encoded audio blob played via
`AVAudioPlayer` (`playEncodedAudioData`). Fallback triggers on: explicit
`fallback` frame, receive-loop error before any PCM arrived, `finish()` send
failure before PCM, or the 20-second finish timeout with no PCM. `finish()`
after PCM that then times out is a hard failure ("Hermes speech streaming
timed out."), not a fallback. `fallbackAttempted` guarantees at most one
fallback per stream.

## Turn-taking wiring (AppState is the authority)

- The controller is constructed lazily in AppState (line ~168) with
  `submit: submitVoiceTranscript` (which just calls `submitComposer`) and
  `interrupt: interruptForVoice` (which calls `cancelCurrent()`). Voice reuses
  the exact composer submission path — never submit chat turns from voice code
  directly.
- Assistant events: `AppState.applyStreamEvent` maps main-socket stream events
  to `VoiceAssistantEvent` via `notifyVoiceAssistant`: `messageStart` ->
  `.started`, `messageDelta` -> `.delta`, `messageComplete` -> `.completed`,
  `messageError` -> `.failed`, `messageInterrupted` -> `.interrupted`
  (AppState.swift:3396-3443). The controller never scrapes UI text.
- Opening voice: `AppState.openVoiceConversation(_ intent: PendingVoiceIntent)`
  (line ~3926): switch profile if requested -> cancel a running turn (only if
  `startsFreshConversation`) -> `refreshVoiceCapabilities()` ->
  `createNewSession()` when fresh/no session -> `makeVoiceGateway()` ->
  `controller.setGateway` + `controller.beginVoiceTurn(sessionID:)` ->
  `showVoiceSheet = true`. The sheet (RootView.swift:134) auto-starts
  listening via its `.task`.
- Closing: sheet dismiss -> `closeVoiceConversation()` persists `outputMuted`
  into the per-profile prefs and calls `endVoiceSession()`.
- Preference keys (UserDefaults):
  `conduit.voice.enabled.v1.<lowercased-baseUrl>.<profile>` (voice starts
  DISABLED until the user opts in per gateway+profile) and
  `conduit.voice.preferences.v1.<lowercased-baseUrl>.<profile>`
  (`VoiceProfilePreferences`: outputMuted, continuousConversation,
  continueWakeConversation, spokenStopPhrases = ["stop", "stop talking",
  "be quiet"], transcriptionMode).
- Stop phrases only trigger when the WHOLE normalized utterance equals a
  phrase (`isWholeUtteranceStopCommand`).

## Voice configuration (settings surface)

`HermesVoiceConfigurationService.reload()` fans out five GETs through the
bridge (all profile-suffixed): `/api/config/schema`, `/api/config`,
`/api/tools/toolsets/stt/config`, `/api/tools/toolsets/tts/config`,
`/api/env`. Saves: `PUT /api/config` (full config with dotted key patched in)
and `PUT /api/env` for credentials. Privacy invariants baked into the code:
Conduit only ever learns whether a credential `is_set`; it deliberately never
calls `/api/env/reveal`. Defaults when absent: `stt.provider` = "local",
`tts.provider` = "edge". Known provider catalog: local (Whisper models
tiny...large-v3), stepfun, xiaomi_mimo; credential keys `STEPFUN_API_KEY`,
`MIMO_API_KEY`. Missing toolset endpoints = "gateway too old", a capability
limitation, not a connection failure.

Capability gating: `AppState.voiceUnavailableReason` (nil ==
`canStartVoiceConversation`) requires connected + enabled + selected STT ready
(or Apple availability) + TTS ready.

Settings test buttons: `runVoiceASRTest` -> `controller.runTranscriptionTest`
(4 s record, transcribe, no chat turn); `runVoiceTTSTest` ->
`controller.runSpeechTest(text:)` (fixed phrase through the real
stream/fallback path). Both foreground-only.

## Wake-word stack: scaffolding, NOT active

Verified facts, because this trips people up:

- sherpa-onnx is NOT a linked dependency. `project.yml` declares no package or
  framework dependencies at all, and `SherpaWakeWordService.swift`'s header
  states it "intentionally does not import sherpa-onnx". The service takes a
  `SherpaWakeRuntime` protocol whose default is `nil`.
- `WakeModelDescriptor.bundledBilingualPack`
  (id `sherpa-onnx-kws-zipformer-zh-en-3m-chunk8`, sherpa 1.13.2, release
  2025-12-20) has `packagingStatus: .blockedPendingLicenseReview`; asset
  SHA-256s are nil; `BundledWakeModelPackResolver.localURL` returns nil.
  Result: `SherpaWakeWordService.availability` is always `.unavailable` in
  shipping builds.
- The wake classes are referenced NOWHERE in app code outside `Conduit/Voice/Wake/`
  (only tests). `VoiceSettingsView.wakeSection` is a static notice: the model
  is inactive pending license review; Siri is the supported lock-screen entry.
- `PendingVoiceIntent.Source.wakePhrase` exists but nothing constructs it yet
  (only `.siri` and `.composer` have call sites).
- `WakePhraseCompiler` validates phrases against injectable tokenization
  tables (`testFixtures` for tests; `unavailableProductionTables` is empty on
  purpose) producing per-phrase FNV-1a aliases `conduit-<hex>`; English words
  need CMU-style pronunciations, CJK characters need pinyin tokens.
- `WakeLifecycleCoordinator.update(for:)` arms only when
  foreground + authenticated + gateway connected + mic permitted + voice state
  `.idle`; `disarmImmediately()` is the synchronous backgrounding hook. Wake
  prefs are device-local (`conduit.wakeConfiguration.v1`) and never written to
  Hermes profile config.

To actually enable wake words you must (in order): clear the license review
and record checksums in `WakeModelDescriptor`, bundle the XCFramework + model
pack, implement `SherpaWakeRuntime`, replace the empty production tokenization
tables, wire a `WakeLifecycleCoordinator` into AppState scene/connection
state, and enqueue `PendingVoiceIntent(source: .wakePhrase)` on detection.
Audio-session sharing between an armed wake runtime and
capture/playback is unimplemented territory — re-read the ownership map first.

## Entry points

| Entry | Path | Behavior |
|---|---|---|
| Composer mic button | `Conduit/Views/Components/ComposerBar.swift` (~line 467) | Calls `appState.openVoiceConversation` directly with `startsFreshConversation: false`, `source: .composer`. Disabled while a turn is running. |
| Siri / Shortcuts | `StartVoiceConversationIntent` (`openAppWhenRun = true`) | Enqueues `PendingVoiceIntent(source: .siri, startsFreshConversation: true)` into `PendingVoiceIntentStore.shared`; `ConduitApp` routes it via `.task(id: voiceIntentRouteKey)` ONLY once `appState.isConnected`. Profile parameter options come from UserDefaults `conduit.knownProfiles.v1`. Siri never opens the mic itself. |
| Wake phrase | — | Reserved; not wired (see Wake section). |

Info.plist strings (required for both permissions):
`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.

## Tests as executable documentation

Run via Xcode/xcodebuild against the `ConduitTests` target (build/run
mechanics belong to conduit-build-and-env). The voice suites inject the
`VoiceTypes` protocols, so they run without hardware audio:

| Suite | What it proves |
|---|---|
| `ConduitTests/VoiceConversationControllerTests.swift` (669 lines, 26 tests) | The whole state machine: permission gating, trailing-silence submit, barge-in requires 0.3 s sustained speech, Apple-mode bypasses Hermes STT, one persistent speech stream per response, stop-during-transcription cannot ghost-submit, audio interruption cannot ghost-submit, idle-silence pauses instead of failing, session-ID ownership, stale-cancellation filtering, mute semantics, transcript accretion, VAD defaults. Start here before changing ANY controller behavior. |
| `ConduitTests/HermesVoiceConfigurationServiceTests.swift` | Parser: schema/config merge, credential redaction ("never carries a secret value"), provider-name normalization ("Local Whisper" -> "local"), StepFun/Xiaomi field catalogs. |
| `ConduitTests/WakePhraseCompilerTests.swift` | Bilingual tokenization, stable aliases, duplicate/unsupported rejection. |
| `ConduitTests/WakeLifecycleTests.swift` | Arm/disarm matrix; asserts the sherpa adapter stays unavailable behind the packaging gate and pins the reviewed archive SHA-256. |
| `ConduitTests/WakeConfigurationStoreTests.swift` | Per gateway+profile storage, phrase dedup. |

## When NOT to use this skill

- Main chat WebSocket (`/api/ws`), reconnects, stale sessions, resume-after-
  background: conduit-ws-reliability-campaign (the voice controller only
  consumes `VoiceAssistantEvent`s from that path).
- DashboardTicketBridge internals, cookie/ticket extraction, WKSecurityOrigin
  port-mismatch history: conduit-architecture-contract and
  conduit-failure-archaeology (fix commit d0873ec).
- Hermes endpoint semantics beyond what the client observably sends/receives:
  hermes-protocol-reference.
- Building, signing, xcodegen, App Store review: conduit-build-and-env and
  conduit-appstore-and-signing.
- General debugging entry points and log capture: conduit-debugging-playbook /
  conduit-diagnostics-and-tooling.
- Feature flags and non-voice settings: conduit-config-and-flags.
- Running the app / operational runbook: conduit-run-and-operate.
- QA passes: conduit-validation-and-qa. Change process: conduit-change-control.

## Provenance and maintenance

Re-verification one-liners (paste from repo root; all facts above were read
from source, not inferred):

```bash
# The only AVAudioSession category/activation sites in the app (expect 4 setCategory/setActive(true) + 1 setActive(false), all in Conduit/Voice/):
grep -rn "setCategory\|setActive" Conduit --include='*.swift'
# VAD defaults:
grep -n "voiceActivityThreshold\|trailingSilence\|idleSilence\|maximumUtterance\|bargeInDuration" Conduit/Voice/VoiceConversationController.swift | head -6
# State enum:
grep -n "case " Conduit/Voice/VoiceTypes.swift | head -8
# Voice endpoints used by the gateway:
grep -n "api/audio" Conduit/Voice/HermesVoiceGateway.swift
# Config endpoints:
grep -n "api/config\|api/env\|toolsets" Conduit/Voice/HermesVoiceConfigurationService.swift | head
# On-device privacy invariant:
grep -n "requiresOnDeviceRecognition" Conduit/Voice/AppleOnDeviceSpeechTranscriber.swift
# Wake stack is not linked (expect: no packages in project.yml; header disclaims import):
grep -n "dependencies\|packages" project.yml; head -8 Conduit/Voice/Wake/SherpaWakeWordService.swift
# Wake gate status:
grep -n "packagingStatus" Conduit/Voice/Wake/WakeModelDescriptor.swift
# Wake classes unused outside Voice/Wake (expect no app-code hits):
grep -rn "WakeLifecycleCoordinator\|SherpaWakeWordService\|WakeConfigurationStore" Conduit --include='*.swift' | grep -v "Voice/Wake"
# Assistant event fan-out:
grep -n "notifyVoiceAssistant" Conduit/Services/AppState.swift
# Foreground-only (expect no UIBackgroundModes):
grep -n "UIBackgroundModes" Conduit/Info.plist
# Preference keys:
grep -n "conduit.voice\.\|conduit.wakeConfiguration\|conduit.knownProfiles" -r Conduit --include='*.swift'
# Entry points:
grep -rn "PendingVoiceIntent(" Conduit --include='*.swift'
# Scene-phase teardown:
grep -n "setForegroundActive" Conduit/Services/AppState.swift
# Test inventory:
grep -c "func test" ConduitTests/VoiceConversationControllerTests.swift
# Post-release fix commits (none touched Voice/ as of 2026-08-08):
git log --oneline; git show --name-only 859162b d0873ec e4318c5 e3cdb49 | grep -c "Voice/" || true
```

Run log:
- 2026-08-08 (build): initial authoring
