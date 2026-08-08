---
name: conduit-config-and-flags
description: >
  Complete catalog of every configuration axis in Hermes Conduit: all
  @AppStorage/UserDefaults keys (the conduit.* namespace), Keychain items
  (hermes-conduit.*), Info.plist usage descriptions, Conduit.entitlements,
  per-profile server-side settings written through /api/config, and the
  device-local stores (ProfileAppearanceStore, WakeConfigurationStore,
  SessionPresentationCache). Load this skill when: adding/renaming/reading a
  setting or preference; a toggle "does not stick" or resets after relaunch;
  a value survives sign-out (or unexpectedly does not); questions about where
  credentials, cookies, tickets, or the push registration live; Face ID
  gating of saved credentials; the push relay URL (conduit.relayURL /
  push.milim.dev); @AppStorage default-value bugs (commit 859162b); or any
  question of the form "where is X stored?". Key files: AppState.swift
  (KeychainHelper + persistence keys), AuxiliaryViews.swift (SettingsView),
  Haptics.swift, PushNotificationService.swift, ProfileAppearanceStore.swift,
  WakeConfigurationStore.swift, BiometricAuth.swift, Info.plist,
  Conduit.entitlements. Not for build settings/project.yml
  (conduit-build-and-env), WS reconnect logic (conduit-ws-reliability-campaign),
  or the RPC protocol itself (hermes-protocol-reference).
---

# Conduit: Configuration and Flags Catalog

This skill is the single source of truth for every place Hermes Conduit
persists or reads configuration. Repo root:
`/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`

Definitions (used throughout):

| Term | Meaning |
|---|---|
| Hermes | The self-hosted agent server. Conduit is its native iOS client. |
| Dashboard | Hermes' web dashboard (default port 9119 per README). ALL client RPC goes through it (`/api/ws` WebSocket + `/api/*` HTTP via DashboardTicketBridge). Never contact the Hermes gateway directly (project hard rule). |
| Profile | A Hermes-side agent identity (e.g. "default"). Many local keys are namespaced per profile. |
| `@AppStorage` | SwiftUI property wrapper backed by `UserDefaults.standard`. |
| DashboardTicketBridge | Hidden WKWebView that holds the dashboard auth session and mints WS tickets (`Conduit/Services/DashboardTicketBridge.swift`). |
| KeychainHelper | `enum KeychainHelper` at the bottom of `Conduit/Services/AppState.swift` (~line 4262). The ONLY Keychain accessor in the app. |

There is no telemetry or analytics configuration anywhere in this app, and
none may ever be added (project hard rule: no telemetry, tracking, or
analytics — a hard privacy constraint, not a preference).

---

## 1. Rule: every @AppStorage MUST have an explicit default

**Incident (verified in git):** commit `e3cdb49` committed
`@AppStorage("conduit.relayURL") private var customRelayURL: String = ` —
a dangling initializer with literally nothing after the `=` (byte-verified
with `git show e3cdb49:Conduit/Views/AuxiliaryViews.swift`). Commit
`859162b` ("Fix missing empty string default for customRelayURL
@AppStorage") added the explicit `""`. Whether `e3cdb49` compiled is
[candidate -- not built to confirm]; whether the bug reached users / shipped
is [candidate -- user report, unresolved]. Canonical incident narrative:
`conduit-failure-archaeology` entry 2; this section owns the rule.

**The rule:** when declaring any `@AppStorage` property, always write the
default explicitly and completely, e.g.
`@AppStorage("conduit.relayURL") private var customRelayURL: String = ""`.
After editing, eyeball the end of the line; a truncated initializer can
survive a careless edit/generation. Also grep before shipping:

```sh
# Any @AppStorage line not ending in a concrete value is suspect
grep -rn "@AppStorage" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/
```

---

## 2. UserDefaults / @AppStorage — complete key table

All keys live in `UserDefaults.standard` under the `conduit.` prefix.
There are exactly 5 `@AppStorage` declarations; everything else is manual
`UserDefaults` access. (Complete as of initial authoring; re-verify with the
provenance commands.)

### 2a. @AppStorage keys (SwiftUI views)

| Key | Type | Default | Declared at | User-facing surface |
|---|---|---|---|---|
| `conduit.relayURL` | String | `""` (empty = use `https://push.milim.dev`) | `Views/AuxiliaryViews.swift:1209` (NotificationsSettingsDetail) | Settings > Notifications > Push relay text field. Read manually by `PushNotificationService.relayURL` (`Services/PushNotificationService.swift:48`) |
| `conduit.sidebarTab` | String (SidebarTab raw: `Sessions`/`Cron`/`Capabilities`) | `.sessions` | `Views/SidebarView.swift:13` | Sidebar tab selection (implicit; remembers last tab) |
| `conduit.sessionSourceFilter` | String | `"all"` | `Views/SidebarView.swift:153` | Sidebar session-source filter menu |
| `conduit.sessionPresentation` | String (`sessions`/`projects`) | `"sessions"` | `Views/SidebarView.swift:154` | Sidebar sessions-vs-projects switch. NOT the same key as `conduit.sessionPresentation.v1` (row in 2c) |
| `conduit.cronJobsExpanded` | Bool | `true` | `Views/SidebarView.swift:995` | Cron tab section expansion |

### 2b. AppState keys (`Services/AppState.swift`, key constants at lines 270-282)

| Key | Type | Default when absent | Written | Notes |
|---|---|---|---|---|
| `conduit.activeSessionId` | String | — | legacy only | Pre-profile-scoping "last session". Migrated into the per-profile map on init (`migrateLegacyActiveSessionStateIfNeeded`, line 357); removed on disconnect |
| `conduit.activeSessionTitle` | String | `"New conversation"` | legacy only | Companion to the above |
| `conduit.activeSessionIdsByProfile.v1` | `[String: String]` | `[:]` | on session change | profile -> last active session id. Session IDs are only meaningful within their profile (first release stored one global session — restoring it across profiles was a bug; see the code comment at line 355) |
| `conduit.activeSessionTitlesByProfile.v1` | `[String: String]` | `[:]` | on session change | profile -> last active session title |
| `conduit.pinnedSessionIdsByProfile.v1` | Data (JSON `[String: [String]]`) | `[:]` | on pin toggle | profile -> pinned session/lineage-root ids |
| `conduit.activeProfile` | String | `"default"` | on profile switch (574, 2439) | Trimmed on read; empty -> "default". Removed on disconnect |
| `conduit.themePreference` | String (`dark`/`light`/`system`) | `.dark` | `themePreference` didSet (line 123) | Settings > Appearance > Theme. Survives sign-out |
| `conduit.dashboardURL` | String (normalized base URL) | `""` | `rememberDashboardURL` (line 519) | Deliberately kept after sign-out so the next login pre-fills the server address (comment at line 511). Normalized via `ConnectionURLPolicy.normalizedBaseURL` |
| `conduit.modelVisibility.v1` | Data (JSON `ModelVisibility`) | none hidden | `saveModelVisibility` (line 529) | Hidden providers/models in the model picker |
| `conduit.profileOrder.v1` | `[String]` | `[]` | line 501 | User's profile ordering; read at line 2671 |
| `conduit.sessionFilterOrder.v1` | `[String]` (filter raw values) | built-in order | `moveSessionFilters` (line 507) | Sidebar filter chip ordering |
| `conduit.reviewSummaryCache.v1` | Data (JSON `[ReviewSummaryRecord]`) | `[]` | `persistReview` (line 316) | Bounded to last 200 records. Preserves review summaries that Hermes emits only as stream events |
| `conduit.knownProfiles.v1` | `[String]` | `["default"]` | `loadProfiles` (lines 2475, 2480) | Written after `/api/profiles` discovery. READ OUTSIDE THE APP TARGET by the Siri App Intent (`Intents/StartVoiceConversationIntent.swift:31`) to offer profile choices — keep the key name stable |
| `conduit.voice.enabled.v1.<gateway>.<profile>` | Bool | `false` | `setVoiceEnabled` (line 3894) | DYNAMIC key: `<gateway>` is `connection.baseUrl.lowercased()` (or `"disconnected"`), built at line 4014. Settings > Voice |
| `conduit.voice.preferences.v1.<gateway>.<profile>` | Data (JSON `VoiceProfilePreferences`) | struct defaults (`Voice/VoiceTypes.swift:55`: outputMuted false, continuousConversation true, stop phrases, transcriptionMode nil -> `.hermes`) | `saveVoiceProfilePreferences` (line 4045) | Same dynamic namespacing. Settings > Voice |

### 2c. Store-class keys (each class owns one key)

| Key | Type | Owner | Notes |
|---|---|---|---|
| `conduit.defaultProfileName.v1` | String | `Services/ProfileAppearanceStore.swift:14` | Display label for the "default" profile; empty/whitespace falls back to `"Hermes"`. Settings > Profile > On this device. Deliberately device-local — never sent to Hermes (header comment, lines 5-7) |
| `conduit.profileAvatars.v1` | `[String: String]` (profile -> file path) | `ProfileAppearanceStore.swift:15` | Reference map only. Avatar JPEGs live in `Documents/profile-avatars/profile-<base64url(profile)>.jpg`; `loadAvatarURLs()` also rescans the directory (and legacy `Application Support/ProfileAvatars`) so photos survive a UserDefaults reset, then rewrites the map |
| `conduit.wakeConfiguration.v1` | Data (JSON `[WakeProfileKey: WakeProfilePreferences]`) | `Voice/Wake/WakeConfigurationStore.swift:25` | Wake phrases per (gatewayID, profileID). Device-local by design (header comment). CURRENTLY DORMANT: no production call sites — referenced only by its own file and `ConduitTests/WakeConfigurationStoreTests.swift`; the Voice settings wake section is an explanatory placeholder ("bundled bilingual wake model is not active yet", `Views/VoiceSettingsView.swift:371`) |
| `conduit.haptics` | Bool | `Services/Haptics.swift:19` | Default `true`. Read by every `Haptics.*` call. See the trap in section 3 |
| `conduit.sessionPresentation.v1` | Data (JSON) | `Services/SessionPresentationCache.swift:60` | Bounded presentation cache: max 32 sessions x 320 messages, keyed `"<profile>|<sessionID>"`. Restores UI-only fields (timestamps, tool previews, attachments, pending clarify/approval cards) that Hermes' compact history omits. Gateway stays authoritative for transcript content |

`PendingVoiceIntentStore` (`Voice/Wake/PendingVoiceIntentStore.swift`) is
**in-memory only** — a `@Published` revision counter plus one pending
`PendingVoiceIntent`. It persists nothing; a Siri-launched voice intent does
not survive process death. Do not add UserDefaults to it without checking
`ConduitApp.swift`'s `voiceIntentRouteKey` routing first.

### 2d. Sign-out behavior (what `AppState.disconnect()` clears, line ~610)

Removed: `conduit.activeSessionId`, `conduit.activeSessionTitle`,
`conduit.activeSessionIdsByProfile.v1`, `conduit.activeSessionTitlesByProfile.v1`,
`conduit.pinnedSessionIdsByProfile.v1`, `conduit.activeProfile`, plus Keychain
connection, cookies, and credentials.
Kept on purpose: `conduit.dashboardURL`, theme, haptics, relay URL,
appearance/avatar keys, voice keys, caches.

---

## 3. Trap: `conduit.haptics` is dual-homed

Two independent stores use the same key string:

1. `Haptics.enabled` reads/writes **local** `UserDefaults.standard`
   `"conduit.haptics"` (`Services/Haptics.swift:19-21`). Default true.
2. Settings > Chat renders a "Haptic feedback" toggle as a
   `ProfileSettingField` with key `"conduit.haptics"`
   (`Views/AuxiliaryViews.swift:725`). ProfileSettingFields load and save
   through `AppState.loadProfileSettings` / `setProfileSetting`
   (`Services/AppState.swift:2961, 3057`), which round-trip the **server's**
   profile config via `GET/PUT /api/config` — writing
   `config["conduit"]["haptics"]` on the Hermes side.

Verified statically: there is **no** special case for `conduit.`-prefixed
keys in `loadProfileSettings`/`setProfileSetting`, and **no code anywhere
writes `Haptics.enabled`** (`grep -rn "Haptics.enabled" Conduit/` returns
nothing). So the Settings toggle persists to the server config while the
local key that actually gates haptics is never written; the toggle therefore
appears to have no effect on device haptics [candidate -- unverified: static
conclusion; not confirmed on-device]. If you touch haptics settings, fix the
save path (route `conduit.*` keys to UserDefaults) rather than working around
it, and check whether the server rejects or preserves the stray `conduit`
config object [candidate -- unverified: server-side behavior not visible from
client code]. Route the fix through `conduit-change-control` (it changes
where a user-visible setting persists).

---

## 4. Per-profile server-side settings (NOT local)

Settings screens Chat, Workspace & safety, Memory, and Model write to the
**Hermes profile config**, not to the device. Flow:
`ProfileConfigSettingsPage` (AuxiliaryViews.swift:986) ->
`AppState.loadProfileSettings` / `setProfileSetting` ->
`DashboardTicketBridge.requestJSON` `GET /api/config` then `PUT /api/config`
with body `{"config": <entire mutated config>, "profile": <name>}`.
Dotted keys map to nested JSON (`approvals.mode` ->
`config["approvals"]["mode"]`).

Server-side keys used by the client (defaults are the client's display
fallbacks, defined in AuxiliaryViews.swift; server semantics are
[candidate -- unverified] from the client alone):
`display.personality`, `timezone`, `display.show_reasoning`,
`display.tool_progress` (`all`/`off` text-toggle), `display.expand_tools`,
`display.memory_notifications`, `agent.image_input_mode`, `terminal.cwd`,
`code_execution.mode`, `approvals.mode`, `security.redact_secrets`,
`security.allow_private_urls`, `memory.provider`, `memory.memory_enabled`,
`memory.user_profile_enabled`, `context.engine`, `compression.enabled`,
`compression.threshold`, `compression.target_ratio`,
`compression.protect_last_n`, `delegation.max_concurrent_children`.

Special cases:
- On profile `default`, `context.engine` and `memory.provider` PUT to
  `/api/dashboard/plugin-providers` instead (AppState.swift:3061-3065).
- Model default: `POST /api/model/set` then config PUT of `model.default`,
  `model.provider`, `reasoning` (`setProfileMainModel`, line 3026).
- "During a response" (steer/interrupt) persists through the WebSocket client
  (`client.setBusyInputMode`, line 3169), not `/api/config`.

Full endpoint/RPC semantics belong to `hermes-protocol-reference`.

---

## 5. Keychain — all four items

Single accessor: `KeychainHelper` (AppState.swift:4262). Generic-password
class, service `com.milim.conduit`. Reads and deletes also try a **legacy
query without the service attribute** (lines 4369-4374) to migrate
early-install items. Accessibility is set only at item creation; updates
send data only (comment at 4318 — including accessibility in every update
can reject a valid cookie update).

| Account (key) | Payload | Accessibility | Written by | Cleared by |
|---|---|---|---|---|
| `hermes-conduit.connection.v1` | JSON `HermesConnection { baseUrl, ticket }` (`Models/Models.swift:370`) | AfterFirstUnlockThisDeviceOnly (default) | `saveConnection` on connect/reconnect (AppState 590, 1124, 2438) | `clearConnection()` — sign-out and auth-failure paths (620, 726) |
| `hermes-conduit.dashboard-cookies.v1` | JSON-encoded WebKit cookies for the dashboard host | AfterFirstUnlockThisDeviceOnly | `DashboardTicketBridge` cookie capture (`Services/DashboardTicketBridge.swift:75-82`) | `clearConnection()` clears it too (4351-4354) |
| `hermes-conduit.credentials.v1` | JSON `DashboardCredentials { baseURL, username, password, requiresFaceID }` (`Services/NativeAuthClient.swift:10`) | **WhenUnlockedThisDeviceOnly** (stricter, 4287) | LoginView "Save credentials" toggle (`Views/LoginView.swift:196-201`) | `clearCredentials()` on sign-out (621) |
| `hermes-conduit.push-registration.v1` | JSON `StoredRegistration { credential, installationID, preferences }` (`Services/PushNotificationService.swift:262`) | AfterFirstUnlockThisDeviceOnly | `persistRegistration()` after relay register/update | `clearPushRegistration()` in `disable()` (116). NOT cleared on app sign-out |

Face ID: `requiresFaceID` on saved credentials gates auto-restore —
`AppState` line 682 calls `BiometricAuth.authenticate(reason: "Unlock
Conduit")`. `BiometricAuth` (`Services/BiometricAuth.swift`) evaluates
`.deviceOwnerAuthentication` (device passcode is a deliberate fallback so a
transient Face ID failure is not a lockout); `isFaceIDAvailable` checks
`.deviceOwnerAuthenticationWithBiometrics` + `biometryType == .faceID`.

Rules:
- Never put credentials, tickets, or cookies in UserDefaults. Keychain only,
  via KeychainHelper — add a new account constant next to the existing four.
- Cookies + connection ticket are auth material and are cleared together.

---

## 6. Info.plist (`Conduit/Info.plist`)

Usage-description and policy keys (verbatim strings matter for App Store
review — see `conduit-appstore-and-signing`):

| Key | Value |
|---|---|
| `NSFaceIDUsageDescription` | "Conduit uses Face ID to unlock saved Hermes credentials." |
| `NSMicrophoneUsageDescription` | "Conduit uses the microphone for voice conversations and foreground wake phrases." |
| `NSSpeechRecognitionUsageDescription` | "Conduit uses on-device Apple speech recognition to turn your voice into text when you select On this iPhone." |
| `NSAppTransportSecurity` | `NSAllowsLocalNetworking = true` only (no arbitrary-loads). HTTP is additionally restricted to loopback by `ConnectionURLPolicy` |
| `ITSAppUsesNonExemptEncryption` | `false` |
| `UISupportedInterfaceOrientations` | Portrait only; `UIRequiresFullScreen = true`; single scene |
| `CFBundleIcons` / `CFBundleIcons~ipad` | Alternate icon "Light" (files `icon-light-120/152/167/180`) |

**There are NO `UIBackgroundModes`.** The app declares no background
execution; wake listening is foreground-only and pushes arrive via APNs.
Do not add a background mode casually — it is an App Store review surface
(user-reported: review/signing problems were among the costliest past
failures) and would touch the AVAudioSession minefield (see
`conduit-voice-pipeline` / `conduit-failure-archaeology`).

## 7. Entitlements (`Conduit/Conduit.entitlements`)

Exactly one entitlement:

```xml
<key>aps-environment</key>
<string>production</string>
```

No app groups, no keychain-sharing groups, no associated domains. The
entitlements file is wired in `project.yml`
(`CODE_SIGN_ENTITLEMENTS: Conduit/Conduit.entitlements`) — build/signing
details belong to `conduit-build-and-env` and `conduit-appstore-and-signing`.

## 8. Push relay configuration

- Relay URL resolution (`PushNotificationService.relayURL`, line 47): use
  `conduit.relayURL` from UserDefaults if it parses as a URL, else
  `https://push.milim.dev` (hardcoded default, line 52).
- Registration: `POST /v1/installations` with `bundle_id: "com.milim.relay"`,
  hex device token, `environment: "production"`, preference flags; response
  credential is stored in Keychain (section 5). Pairing:
  `POST /v1/installations/<id>/pairings` -> short-lived code the user feeds to
  `hermes conduit-push pair <code>` on the gateway. Relay server behavior
  beyond these request shapes is [candidate -- unverified] from client code.
- Notification preference flags (`ConduitNotificationPreferences`,
  PushNotificationService.swift:12) are stored **inside the Keychain
  registration blob** and mirrored to the relay on change — they are not
  UserDefaults keys.
- App icon choice is NOT a stored key either: it is derived from
  `UIApplication.shared.alternateIconName` (AppState.swift:328).

## 9. Checklist: adding a new setting

1. **Decide the home. One home per fact:**
   - Server/profile behavior -> add a `ProfileSettingField` to the right
     fields array in `AuxiliaryViews.swift` (sections 4). Never invent a
     server config key — verify it exists in the dashboard's `/api/config`
     response first.
   - Device-local UI preference -> `@AppStorage` in the owning view, key
     prefixed `conduit.`, **explicit default** (section 1 rule).
   - Device-local, read outside SwiftUI or by services -> manual
     UserDefaults with a `private let ...Key = "conduit.<name>.v1"` constant
     in the owning type (follow AppState lines 270-282).
   - Secret/auth material -> KeychainHelper, new `hermes-conduit.<name>.v1`
     account constant.
2. Suffix `.v1` on any key whose payload is structured (JSON/dictionary) so
   a future format change can migrate by key bump; plain scalars
   historically omit it (`conduit.haptics`, `conduit.themePreference`).
3. Do NOT reuse a key string across two stores (section 3 is the cautionary
   tale). Grep first:
   `grep -rn "conduit.<name>" Conduit/`.
4. Per-profile local values: namespace like the voice keys
   (`conduit.<thing>.v1.<gateway>.<profile>`) or use a profile-keyed
   dictionary like `conduit.activeSessionIdsByProfile.v1` — never a single
   global key (that was the active-session bug the `.v1` migration fixed,
   AppState.swift:355).
5. Decide sign-out semantics explicitly: if the value is tied to the
   authenticated account/session, clear it in `AppState.disconnect()`;
   preference-like values stay (the `conduit.dashboardURL` comment at line
   511 is the precedent).
6. Surface it in the correct Settings destination
   (`SettingsDestination`: profile, model, chat, voice, workspace, memory,
   gateway, appearance, notifications, about — AuxiliaryViews.swift:430).
7. If an App Intent or other extension-ish entry point must read it, note
   the coupling in a comment (precedent: `conduit.knownProfiles.v1` in
   `StartVoiceConversationIntent.swift:31`).
8. No new Info.plist usage keys or entitlements without treating it as an
   App Store review event (`conduit-appstore-and-signing`).
9. Classify the change per `conduit-change-control`'s gate table before
   shipping (any new networking-touching setting also triggers the README
   Privacy re-check).
10. Update THIS skill's tables and run log.

## 10. When NOT to use this skill

- Build system, project.yml, signing identities, xcodegen -> `conduit-build-and-env`
- App Store submission, provisioning, review history -> `conduit-appstore-and-signing`
- WebSocket reconnect/stale-session/ticket-expiry behavior -> `conduit-ws-reliability-campaign` (and `conduit-debugging-playbook` for live triage)
- RPC message shapes, `/api/ws`, dashboard endpoints -> `hermes-protocol-reference`
- AVAudioSession, wake-word audio, speech playback -> `conduit-voice-pipeline`
- Past incidents in narrative form -> `conduit-failure-archaeology`
- Architecture invariants (e.g. why gateway-direct calls are banned) -> `conduit-architecture-contract`
- Running the app against a server -> `conduit-run-and-operate`

## Provenance and maintenance

Ground truth verified at commit `859162b` (main).
Re-verification one-liners (paste as-is; repo root
`/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`):

```sh
# All @AppStorage declarations (expect 5; every one must end in an explicit default)
grep -rn "@AppStorage" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/
# Every conduit.* key string in the app (master list for the tables above)
grep -rn '"conduit\.' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/
# All UserDefaults touch points
grep -rn "UserDefaults" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/
# AppState key constants block
sed -n '269,285p' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift
# KeychainHelper accounts, service, accessibility
sed -n '4260,4380p' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift
# The customRelayURL incident (dangling default) and its fix
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log -p 859162b -- Conduit/Views/AuxiliaryViews.swift
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit show e3cdb49:Conduit/Views/AuxiliaryViews.swift | sed -n '1206,1212p'
# conduit.haptics dual-home trap: field definition vs local reader vs (absent) writer
grep -rn '"conduit.haptics"' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/
grep -rn "Haptics.enabled" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/ || echo "no writer (trap still present)"
# Profile settings round-trip through /api/config
grep -n "func loadProfileSettings\|func setProfileSetting" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift
# Push relay default URL and bundle id
sed -n '47,54p' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/PushNotificationService.swift
# WakeConfigurationStore still dormant? (expect: only tests outside its own file)
grep -rn "WakeConfigurationStore" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit --include="*.swift" | grep -v "Voice/Wake/WakeConfigurationStore.swift"
# PendingVoiceIntentStore still in-memory only? (expect: no UserDefaults/Keychain inside)
grep -n "UserDefaults\|Keychain" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Voice/Wake/PendingVoiceIntentStore.swift || echo "in-memory only (expected)"
# Info.plist usage keys and (absence of) UIBackgroundModes
grep -n "UsageDescription\|UIBackgroundModes\|NSAppTransportSecurity" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Info.plist
# Entitlements (expect aps-environment production only)
cat /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Conduit.entitlements
# Sign-out clearing behavior
sed -n '610,650p' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift
# Face ID gate on saved credentials
sed -n '680,690p' /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/AppState.swift
```

Volatile facts (date-stamped 2026-08-08; re-check on each pass):
- 2026-08-08: 5 @AppStorage keys; ~21 distinct conduit.* UserDefaults keys as tabled above
- 2026-08-08: 4 Keychain accounts under service com.milim.conduit
- 2026-08-08: conduit.haptics dual-home trap unfixed (no writer of Haptics.enabled)
- 2026-08-08: WakeConfigurationStore dormant (tests only); wake UI is placeholder text
- 2026-08-08: default push relay https://push.milim.dev; bundle id com.milim.relay
- 2026-08-08: no UIBackgroundModes; sole entitlement aps-environment=production

Run log:
- 2026-08-08 (build): initial authoring
