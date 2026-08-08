---
name: conduit-appstore-and-signing
description: >
  App Store release and code-signing runbook for Hermes Conduit (the native iOS
  client in this repo). Load this skill when: preparing an App Store release or
  TestFlight build; bumping MARKETING_VERSION / CURRENT_PROJECT_VERSION; editing
  signing settings in project.yml; touching Conduit/Conduit.entitlements or the
  privacy strings in Conduit/Info.plist; diagnosing archive/upload/signing errors
  ("No profiles for com.milim.relay", "doesn't include signing certificate",
  "Provisioning profile ... doesn't match", aps-environment errors, ITMS upload
  errors); answering App Store review questions or writing review notes; or
  investigating why a fresh clone fails to build on device. Also load it before
  changing the bundle id, entitlements, background modes, or any Info.plist
  privacy key -- those changes have release and review consequences documented
  here.
---

# Conduit: App Store release and signing runbook

Scope: everything between "code is done" and "build is live on the App Store"
for this app. Signing configuration, version bumping, archive/upload, and an
App Store review risk register specific to this app's traits.

Honesty note: the user reports App Store review and signing problems as one of
the costliest historical time sinks on this project (user-reported). The public
git history is squashed to 5 commits, so the repo carries almost no evidence of
those incidents. Everything below is split into VERIFIED (read from source in
this repo) and [candidate -- unverified] (standard Apple practice, or
user-reported history with no repo evidence). Future sessions: when you hit a
real rejection or signing incident, append it to the "Incident log" section at
the bottom. That is this file's whole reason for existing.

## Jargon (defined once)

| Term | Meaning here |
|---|---|
| xcodegen | CLI tool that generates `Conduit.xcodeproj` from `project.yml`. The `.xcodeproj` is gitignored; `project.yml` is the only source of truth for build settings, including signing. |
| Manual signing | `CODE_SIGN_STYLE: Manual` in `project.yml`. Xcode does NOT pick certificates/profiles automatically; the named identity and profile must exist on the build machine. |
| Provisioning profile | Apple-issued file binding an App ID (bundle id) + certificate + capabilities. This project pins one by name: "Conduit App Store". |
| Entitlements | `Conduit/Conduit.entitlements` -- capability claims baked into the signed binary. This app claims exactly one: production push (`aps-environment`). |
| MARKETING_VERSION | User-facing version string (CFBundleShortVersionString), e.g. `0.1.1`. |
| CURRENT_PROJECT_VERSION | Build number (CFBundleVersion), e.g. `114`. Must increase for every upload to App Store Connect [candidate -- standard App Store Connect rule, not enforceable from the repo]. |
| APNs topic | The bundle id, as far as Apple push routing is concerned. Relevant because this app's bundle id is hardcoded in the push client code. |

## Verified signing configuration

All from `/Users/marcswan/Documents/Code/personal/tools/hermes-conduit/project.yml`
unless noted. Version values date-stamped: as of 2026-08-08.

| Setting | Value | Where |
|---|---|---|
| App name / product | `Conduit` (`PRODUCT_NAME`) | project.yml target `Conduit` |
| App Store listing name | "Hermes Conduit", app id `6790977764` | README.md badge (`apps.apple.com/us/app/hermes-conduit/id6790977764`) |
| Bundle id | `com.milim.relay` | project.yml `PRODUCT_BUNDLE_IDENTIFIER` |
| Team | `U2TH557QA8` (`DEVELOPMENT_TEAM`) | project.yml settings.base |
| Signing style | `Manual` (`CODE_SIGN_STYLE`) | project.yml settings.base |
| Identity | `Apple Distribution` (`CODE_SIGN_IDENTITY`) | project.yml target settings |
| Profile | `Conduit App Store` (`PROVISIONING_PROFILE_SPECIFIER`) | project.yml target settings |
| Entitlements file | `Conduit/Conduit.entitlements` (`CODE_SIGN_ENTITLEMENTS`) | project.yml target settings |
| Entitlements content | exactly one key: `aps-environment` = `production` | Conduit/Conduit.entitlements |
| Marketing version | `0.1.1` (as of 2026-08-08) | project.yml `MARKETING_VERSION` |
| Build number | `114` (as of 2026-08-08) | project.yml `CURRENT_PROJECT_VERSION` |
| Deployment target | iOS 17.0, Swift 5.9, bitcode off | project.yml settings.base |
| Info.plist | hand-maintained (`GENERATE_INFOPLIST_FILE: NO`, `INFOPLIST_FILE: Conduit/Info.plist`) | project.yml target settings |
| Encryption declaration | `ITSAppUsesNonExemptEncryption` = `false` (no export-compliance prompt per build) | Conduit/Info.plist |
| ATS | `NSAllowsLocalNetworking` = `true` only; `NSAllowsArbitraryLoads` is NOT set | Conduit/Info.plist |
| Background modes | NONE. No `UIBackgroundModes` anywhere in the repo | verified by repo-wide grep |
| Third-party dependencies | NONE. project.yml has no `packages:` section; system frameworks only | project.yml |
| Fastlane / CI / ExportOptions.plist | NONE in repo. Releases are manual through Xcode | verified by repo-wide search |

Test target: `ConduitTests` (unit-test bundle, `GENERATE_INFOPLIST_FILE: YES`,
no explicit signing overrides -- it inherits `settings.base`).

## Permanent gotchas (read before every release)

1. **The bundle id does not match anything.** App is named Conduit, App Store
   listing is "Hermes Conduit", bundle id is `com.milim.relay`. This is
   permanent -- bundle ids cannot be changed after App Store release. Never
   "fix" it. Searches for `com.milim.conduit` will find nothing.
2. **The bundle id is hardcoded in push code.** `Conduit/Services/PushNotificationService.swift`
   contains `private let bundleID = "com.milim.relay"`. The bundle id is the
   APNs topic, so a fork with a different bundle id cannot receive pushes
   through the shared relay's APNs credentials [candidate -- relay server-side
   behavior is not visible from this repo; the hardcoded client constant is
   verified].
3. **`Conduit.xcodeproj` is gitignored** (see `.gitignore`: `*.xcodeproj/`).
   Any signing change made in the Xcode UI is lost on the next
   `xcodegen generate`. Make signing changes in `project.yml` only.
4. **A fresh clone will not build on a device as-is.** Manual signing pins the
   "Apple Distribution" identity and "Conduit App Store" profile of team
   `U2TH557QA8`. Outside contributors (per README "Select your team in Signing
   & Capabilities") must override signing locally -- and per gotcha 3, an Xcode
   UI override evaporates at the next xcodegen run. For local dev on this
   machine, temporarily switching `CODE_SIGN_STYLE` to Automatic in a
   never-committed project.yml edit is the pragmatic route [candidate --
   workflow suggestion, not repo-evidenced].
5. **Certificates and profiles are not in the repo.** `.gitignore` excludes
   `*.p8`, `*.p12`, `*.mobileprovision`. If the Mac is rebuilt, re-download the
   Apple Distribution certificate (with private key!) and the "Conduit App
   Store" profile from developer.apple.com [candidate -- standard practice].
6. **Build numbers in git lag reality.** The public history shows
   `MARKETING_VERSION` bumped 0.1.0 -> 0.1.1 (commit `e3cdb49`) while
   `CURRENT_PROJECT_VERSION` stayed `114`. Build 114 for a fresh 0.1.1 upload
   implies many pre-squash uploads. Before uploading, check App Store Connect
   for the highest used build number; do not trust project.yml [candidate --
   App Store Connect state is outside the repo].
7. **The entitlements file says `aps-environment: production`.** Debug builds
   installed via a development profile normally carry `development`; the
   signing step rewrites this from the profile [candidate -- standard Apple
   behavior]. If push pairing fails on a dev build, suspect environment
   mismatch first (see conduit-debugging-playbook).
8. **Alternate icons are a resources build phase, not sources.** project.yml
   deliberately excludes `Resources/AlternateIcons/**` from sources and re-adds
   the folder with `buildPhase: resources`. `Info.plist` `CFBundleAlternateIcons`
   references `icon-light-120/152/167/180` by name and all four PNGs exist in
   `Conduit/Resources/AlternateIcons/`. If you add an icon variant, update BOTH
   places or archive validation can flag missing icon files [candidate --
   validation behavior; the file/plist wiring is verified].

## Release checklist

Steps 1-3 are verified against the repo; 4-8 are standard Xcode practice with
no repo evidence (no fastlane, no CI) -- [candidate] where marked.

1. Bump versions in `project.yml` (`settings.base`):
   - `MARKETING_VERSION`: new user-facing version.
   - `CURRENT_PROJECT_VERSION`: strictly greater than the highest build number
     ever uploaded for this app in App Store Connect (see gotcha 6).
2. Regenerate the project (the checked-in `.xcodeproj` does not exist; it is
   always generated):
   ```
   cd /Users/marcswan/Documents/Code/personal/tools/hermes-conduit
   xcodegen generate
   open Conduit.xcodeproj
   ```
3. Preflight greps (10 seconds, saves an upload rejection):
   ```
   grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION\|CODE_SIGN\|PROVISIONING\|DEVELOPMENT_TEAM" project.yml
   grep -rn "UIBackgroundModes" Conduit/          # must return nothing
   grep -n "UsageDescription" Conduit/Info.plist  # exactly: FaceID, Microphone, SpeechRecognition
   plutil -lint Conduit/Info.plist Conduit/Conduit.entitlements
   ```
4. [candidate] Verify signing assets are installed: Apple Distribution cert for
   team U2TH557QA8 in the keychain, "Conduit App Store" profile installed
   (Xcode > Settings > Accounts > Download Manual Profiles).
5. [candidate] In Xcode: destination "Any iOS Device (arm64)", then
   Product > Archive.
6. [candidate] Organizer > Distribute App > App Store Connect > Upload. Because
   `ITSAppUsesNonExemptEncryption` is `false` in Info.plist, no export
   compliance question should appear.
7. [candidate] In App Store Connect: attach the build, write review notes (see
   risk register below -- ALWAYS include working demo server details), submit.
8. Commit the project.yml version bump. Nothing else in the repo changes for a
   release (the `.xcodeproj` is gitignored).

There is no fastlane lane, no CI pipeline, and no `ExportOptions.plist` in this
repo (verified absent). If you find yourself wanting one, that is a
conduit-change-control decision, not a quick add.

## App Store review risk register

This app's specific review surface. "What reviewers probe" rows are [candidate]
unless marked user-reported -- the user reports review problems were a top time
sink, but no specific rejection text survives in the repo. Append real outcomes
to the Incident log.

| Trait (verified in repo) | Where | Review risk / what to do |
|---|---|---|
| Requires a self-hosted Hermes server; login screen wants a user-supplied URL + credentials | README "Connecting"; login flow | Highest risk. Reviewers cannot evaluate the app without a reachable demo server. [candidate] Guideline 2.1 (App Completeness) rejections for "cannot log in" are the classic failure for self-hosted-client apps. Mitigation: keep a demo Hermes instance reachable from the public internet during review and put its URL + credentials in the review notes, every submission. |
| Microphone: "voice conversations and foreground wake phrases" | Info.plist `NSMicrophoneUsageDescription` | [candidate] Reviewers check the purpose string matches observed behavior and that mic use is user-initiated. "Wake phrases" wording invites always-listening questions; the string already says "foreground", which is accurate (no background modes exist). Keep string and behavior in sync -- see conduit-voice-pipeline before touching either. |
| Speech recognition, on-device | Info.plist `NSSpeechRecognitionUsageDescription` | Low risk; string explicitly says on-device and opt-in ("when you select On this iPhone"). Keep it accurate. |
| Face ID for credential unlock | Info.plist `NSFaceIDUsageDescription` | Low risk; standard usage. |
| Photo attachments WITHOUT a photo-library usage string | `Views/Components/ImagePicker.swift` (`UIImagePickerController`, `.photoLibrary`); `Views/Components/ComposerBar.swift` (SwiftUI `.photosPicker`, `.fileImporter`) | Intentional: both pickers are out-of-process and need no `NSPhotoLibraryUsageDescription` [candidate -- Apple-documented behavior, verify in current docs]. GOTCHA: if anyone adds direct `PHPhotoLibrary`/`PHAsset` access, the string becomes mandatory and its absence is an instant upload/review failure. |
| Push notifications via third-party relay (`push.milim.dev` default, user-overridable) | entitlements `aps-environment`; `Services/PushNotificationService.swift`; README | [candidate] Affects the App Privacy questionnaire: device tokens transit the relay. The README/privacy stance ("No analytics. No telemetry.") supports a minimal privacy label, but the relay must be disclosed accurately. Never add anything that would change the label without user sign-off (hard rule 1: no telemetry, ever). |
| ATS: `NSAllowsLocalNetworking` only, no arbitrary loads | Info.plist | Good review posture (no ATS-exception justification needed). GOTCHA for support, not review: plain `http://` to a non-local hostname is ATS-blocked; local/LAN targets are allowed. Do not "fix" connection bugs by adding `NSAllowsArbitraryLoads` -- that creates a review justification burden and is a conduit-change-control decision. |
| Connecting to LAN IPs triggers the iOS Local Network permission prompt; no `NSLocalNetworkUsageDescription` present | Info.plist (key absent, verified) | [candidate] iOS shows a default-worded prompt without the key. If users report "can't reach my server on LAN" after a fresh install, check this permission before debugging sockets (cross-ref conduit-debugging-playbook). |
| No background modes at all | repo-wide grep | Voice wake word and WebSocket are foreground-only by design. [candidate] Adding `UIBackgroundModes` (audio, remote-notification, etc.) is heavily probed in review and would reopen the AVAudioSession conflict class the user reports as a historical time sink (see conduit-failure-archaeology). Do not add casually. |
| Zero third-party SDKs | project.yml (no packages) | Strong privacy-label and review story. Keep it that way; any new dependency is a conduit-change-control decision. |
| `ITSAppUsesNonExemptEncryption` = false | Info.plist | Standard exempt claim (HTTPS only). Only revisit if adding non-standard cryptography. |

User-reported history with no repo evidence: "App Store review/signing
problems" were among the costliest past failures. Which of the above rows
actually bit, and what the rejection text said, is unknown [candidate].
**Future sessions: when the user mentions a specific rejection or signing
incident, append it to the Incident log below with date, guideline number, and
resolution.**

## When NOT to use this skill

- Building/running locally, xcodegen basics, simulator setup -> **conduit-build-and-env**
- WKWebView auth bridge, DashboardTicketBridge, cookie/ticket extraction (incl. the d0873ec WKSecurityOrigin port fix) -> **conduit-failure-archaeology** and **conduit-debugging-playbook**
- WebSocket reconnect/stale-session/resume-after-background work -> **conduit-ws-reliability-campaign**
- AVAudioSession, wake word, speech playback -> **conduit-voice-pipeline**
- Push relay pairing flow, relay URL setting, notification preferences at runtime -> **conduit-config-and-flags** and **conduit-run-and-operate**
- What the dashboard `/api/ws` protocol looks like -> **hermes-protocol-reference**
- Whether a risky change (bundle id, entitlements, ATS, new dependency) should happen at all -> **conduit-change-control**

Hard rules that no release step may route around: (1) no telemetry, analytics,
or tracking, ever; (2) all RPC goes through the dashboard WebSocket endpoint
`/api/ws` (default port 9119) after dashboard auth -- never the Hermes gateway
directly.

## Incident log

Append real App Store rejections, signing failures, and upload errors here as
they occur. Format: `- <date>: <guideline/error> -- <what happened> -- <fix>`.

- (none recorded in repo; pre-squash incidents lost -- user-reported that
  review/signing problems were a top historical time sink)

## Provenance and maintenance

Re-verification one-liners (paste from repo root
`/Users/marcswan/Documents/Code/personal/tools/hermes-conduit`):

- Signing block + versions: `grep -n "CODE_SIGN\|PROVISIONING\|DEVELOPMENT_TEAM\|VERSION\|BUNDLE_IDENTIFIER" project.yml`
- Entitlements content: `cat Conduit/Conduit.entitlements`
- Privacy strings: `grep -n "UsageDescription" Conduit/Info.plist`
- Background modes still absent: `grep -rn "UIBackgroundModes" Conduit/ project.yml`
- Photo-library string still safely absent: `grep -rn "NSPhotoLibraryUsageDescription\|PHPhotoLibrary" Conduit/`
- Picker implementations: `grep -n "sourceType\|photosPicker\|fileImporter" Conduit/Views/Components/ImagePicker.swift Conduit/Views/Components/ComposerBar.swift`
- Hardcoded push bundle id + relay default: `grep -rn "com.milim.relay\|push.milim.dev" Conduit/ project.yml`
- ATS keys: `grep -n -A3 "NSAppTransportSecurity" Conduit/Info.plist`
- Encryption flag: `grep -n -A1 "ITSAppUsesNonExemptEncryption" Conduit/Info.plist`
- App Store id: `grep -n "apps.apple.com" README.md`
- Alternate icons wiring: `ls Conduit/Resources/AlternateIcons/ && grep -n "icon-light" Conduit/Info.plist`
- No fastlane/CI/export config: `find . -name fastlane -o -name "ExportOptions*" -o -name "*.xcconfig" | grep -v xcodeproj`
- Version bump history: `git log -p --oneline -- project.yml | grep -n "VERSION\|^commit\|^[0-9a-f]\{7\} "`
- Signing artifacts gitignored: `grep -n "p12\|p8\|mobileprovision\|xcodeproj" .gitignore`

Run log:
- 2026-08-08 (build): initial authoring
