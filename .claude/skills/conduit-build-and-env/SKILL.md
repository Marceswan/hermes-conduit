---
name: conduit-build-and-env
description: >
  Recreate the Hermes Conduit dev environment from scratch and avoid its known
  build traps. Load this skill when: setting up a fresh clone; "No such file
  Conduit.xcodeproj"; missing files in Xcode after adding new Swift files;
  signing errors mentioning "Apple Distribution", "Conduit App Store"
  provisioning profile, or team U2TH557QA8; questions about xcodegen,
  project.yml, .gitignore of the xcodeproj, adding files/resources, alternate
  app icons not appearing, version/build-number bumps, or whether the project
  uses Swift Package Manager (it does not). Not for App Store submission
  (conduit-appstore-and-signing), running the app against a server
  (conduit-run-and-operate), or runtime settings (conduit-config-and-flags).
---

# Conduit: Build and Environment Setup

Hermes Conduit is a native SwiftUI iOS app (iOS 17+, pure Apple frameworks, no
third-party dependencies) that is a client for a self-hosted Hermes Agent
dashboard. This skill covers getting from `git clone` to a running local build,
and the traps that waste time along the way.

Jargon, defined once:

| Term | Meaning |
|---|---|
| xcodegen | CLI tool that generates `Conduit.xcodeproj` from the YAML spec `project.yml`. Installed via Homebrew. |
| `project.yml` | The single source of truth for the Xcode project: targets, build settings, signing, file inclusion. Lives at repo root. |
| `Conduit.xcodeproj` | Generated artifact. Gitignored (`.gitignore` line 2: `*.xcodeproj/`). Never edit expecting persistence; never commit. |
| Hermes dashboard | The web dashboard served by a self-hosted Hermes Agent instance (default port 9119 per README). The app talks ONLY to it, never to the Hermes gateway directly. |
| Alternate icons | Loose PNGs in `Conduit/Resources/AlternateIcons/` referenced by name from `Info.plist` `CFBundleAlternateIcons` (the "Light" icon). |

## Hard rules (project-wide, non-negotiable)

1. No telemetry, analytics, or tracking. Ever. Concretely for build/env work:
   never add an analytics/crash-reporting SDK, and never introduce an SPM/
   CocoaPods dependency that phones home. The dependency count is zero by
   design (see "No package manager" below).
2. All RPC goes through the dashboard WebSocket endpoint `/api/ws` after
   dashboard auth. Never add code or configuration that contacts the Hermes
   gateway directly. Contract details: see `conduit-architecture-contract`.

## Prerequisites

| Requirement | Version | Source of truth |
|---|---|---|
| Xcode | 16 or later | README "Building from source" |
| iOS SDK | 17 (deployment target is iOS 17.0) | `project.yml` `deploymentTarget`, README |
| xcodegen | any recent (installed via brew) | README |
| Swift | project pins `SWIFT_VERSION: "5.9"` | `project.yml` settings |
| macOS able to run Xcode 16 | -- | implied by Xcode requirement |

No Node, no Ruby/CocoaPods, no server-side checkout needed to build the app.

## The exact sequence (fresh clone to running)

```bash
git clone https://github.com/kaishi00/hermes-conduit.git
cd hermes-conduit
brew install xcodegen
xcodegen generate
open Conduit.xcodeproj
```

Then in Xcode: select the `Conduit` scheme, fix signing for local dev (next
section), pick a destination, build and run.

Checklist for a working fresh environment:

- [ ] `xcodegen generate` succeeded and `Conduit.xcodeproj` exists at repo root
- [ ] Xcode opens the project with two targets: `Conduit` (application) and
      `ConduitTests` (unit test bundle, depends on `Conduit`)
- [ ] Signing switched to YOUR team + Automatic (see below) -- the committed
      settings will not sign on your machine
- [ ] App builds for a simulator or your device

## THE key mental model: project.yml is the project

`Conduit.xcodeproj` is a build artifact, exactly like `DerivedData`. The
`.gitignore` excludes `*.xcodeproj/` and `*.xcworkspace/`, so:

- After ANY change to `project.yml`: run `xcodegen generate` again.
- After a fresh clone or a `git pull` that touched `project.yml`: run
  `xcodegen generate` again.
- Any change you make in the Xcode project editor (build settings, signing,
  file membership, new build phases) lives only in the generated `.xcodeproj`
  and is WIPED the next time anyone runs `xcodegen generate`. If a setting
  must persist, it goes in `project.yml`.
- Version bumps: edit `MARKETING_VERSION` (currently "0.1.1") and
  `CURRENT_PROJECT_VERSION` (currently "114") in `project.yml`, then
  regenerate. `Info.plist` reads them via `$(MARKETING_VERSION)` /
  `$(CURRENT_PROJECT_VERSION)` -- do not hardcode versions in `Info.plist`.

## Adding files

The `Conduit` target's sources are declared as a directory path:

```yaml
sources:
  - path: Conduit
    excludes:
      - "Resources/AlternateIcons/**"
  - path: Conduit/Resources/AlternateIcons
    buildPhase: resources
```

Consequences:

- Any new `.swift` file placed anywhere under `Conduit/` (e.g.
  `Conduit/Services/`, `Conduit/Views/`, `Conduit/Voice/`) is picked up
  automatically by the next `xcodegen generate`. Same for test files under
  `ConduitTests/`. You do NOT edit `project.yml` to add a normal source file --
  you DO re-run `xcodegen generate` so the new file appears in the project.
- Adding a file through Xcode's "New File" works for the current session, but
  target membership recorded only in the `.xcodeproj` is regenerated from the
  directory scan anyway; the on-disk location under `Conduit/` is what matters.

### Why AlternateIcons is special-cased

`Conduit/Resources/AlternateIcons/` contains four loose PNGs
(`icon-light-120.png`, `icon-light-152.png`, `icon-light-167.png`,
`icon-light-180.png`). `Info.plist` references them by bare filename in
`CFBundleIcons` / `CFBundleAlternateIcons` (`CFBundleIconFiles` entries like
`icon-light-120`), plus an iPad variant under `CFBundleIcons~ipad`. The primary
icon is the asset catalog's `AppIcon`
(`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`), but the alternate "Light" icon
is NOT in `Assets.xcassets` -- iOS resolves `CFBundleIconFiles` names against
loose files copied flat into the app bundle, so these PNGs must land in the
Copy Bundle Resources phase as plain files [candidate -- unverified: the
"asset catalogs cannot serve CFBundleAlternateIcons on this toolchain"
rationale is inferred from the Info.plist mechanism, not stated in-repo].

The `project.yml` split (exclude from the main sources tree, re-add the folder
with `buildPhase: resources`) forces exactly that: the PNGs ship as flat
bundle resources and can never be misclassified into another build phase.

Trap: if you add a new alternate icon, you must (1) drop correctly named PNGs
into `Conduit/Resources/AlternateIcons/`, (2) add the name to BOTH
`CFBundleAlternateIcons` dicts in `Conduit/Info.plist` (iPhone and `~ipad`),
(3) re-run `xcodegen generate`. Missing any step yields
`setAlternateIconName` failures at runtime [candidate -- unverified: exact
runtime error surface not exercised here].

## Signing: local dev vs the committed App Store settings

`project.yml` commits the maintainer's RELEASE signing configuration:

| Setting | Committed value |
|---|---|
| `CODE_SIGN_STYLE` | `Manual` |
| `DEVELOPMENT_TEAM` | `U2TH557QA8` |
| `CODE_SIGN_IDENTITY` | `Apple Distribution` |
| `PROVISIONING_PROFILE_SPECIFIER` | `Conduit App Store` |
| `CODE_SIGN_ENTITLEMENTS` | `Conduit/Conduit.entitlements` (contains `aps-environment: production`) |
| Bundle ID | `com.milim.relay` (product name `Conduit`) |

A fresh contributor CANNOT build with these: you do not have that team,
certificate, or profile. Per the README: open Signing & Capabilities in Xcode,
switch to Automatically manage signing, and select your own team. Expect to
also change the bundle identifier to something under your own team's namespace
[candidate -- unverified: whether Xcode requires a bundle-id change depends on
your team's registered App IDs].

Two traps:

1. These Xcode-side signing changes are wiped on every `xcodegen generate`
   (see mental model above). Re-apply them after each regenerate, or keep a
   local uncommitted patch to `project.yml` -- but NEVER commit signing
   changes; the committed Manual/App Store values are intentional. Deeper
   signing/App Store history (user-reported as one of the costliest past
   failure classes) lives in `conduit-appstore-and-signing` and
   `conduit-failure-archaeology`.
2. The entitlements file requires the Push Notifications capability
   (`aps-environment`). Teams without that capability (e.g. free personal
   teams) will fail signing until the entitlement is removed locally
   [candidate -- unverified: exact failure mode per account type].

The `ConduitTests` target declares no signing overrides, so it inherits the
base `Manual` style; simulator test runs are the low-friction path for a
fresh clone [candidate -- unverified: device test-run behavior under the
committed manual settings].

## No package manager, no third-party code

`project.yml` declares NO `packages:` section and no target `dependencies`
other than `ConduitTests -> Conduit`. Verified by grep: every `import` across
`Conduit/` and `ConduitTests/` is an Apple framework (SwiftUI, UIKit,
Foundation, Combine, WebKit, Speech, AVFAudio, PhotosUI, AppIntents,
LocalAuthentication, Security, UserNotifications, UniformTypeIdentifiers,
OSLog/os, XCTest). The `.gitignore` SPM entries (`.build/`,
`Package.resolved`) are boilerplate -- there is no `Package.swift`.

Do not introduce a dependency to solve a task; every current feature ships on
Apple frameworks alone, and the zero-dependency posture backs the no-telemetry
hard rule.

## Environment notes that bite during local dev

- Transport policy: the client rejects `http://` for any non-loopback host
  (`ConnectionURLPolicy.normalizedBaseURL` throws `insecureTransport`; only
  `localhost`, `127.0.0.1`, `::1` may use http). A LAN Hermes dashboard at
  `http://192.168.x.x:9119` will NOT connect; use HTTPS (Tailscale/reverse
  proxy) or a loopback tunnel. `Info.plist` sets ATS `NSAllowsLocalNetworking`
  accordingly. Full connection/runtime guidance: `conduit-run-and-operate` and
  `conduit-config-and-flags`.
- Port 9119 is the Hermes dashboard default documented in the README; it is
  NOT hardcoded in Swift source -- the user enters the full base URL at login.
- The app is portrait-only, full-screen, single-scene (`Info.plist`:
  `UISupportedInterfaceOrientations` portrait only, `UIRequiresFullScreen`,
  `UIApplicationSupportsMultipleScenes: false`).
- Xcode updates silently re-trigger the license gate: `xcodebuild -version`
  still works, but every build/test action exits 69 with "You have not agreed
  to the Xcode license agreements" (observed 2026-08-08 mid-session on Xcode
  26.2). Fix: `sudo xcodebuild -license accept` (needs an interactive
  terminal). Also note `cmd | grep ... ; echo $?` reports grep's exit, not
  xcodebuild's -- a masked failure looks like success; check for the license
  string when a previously-green build suddenly produces no test output.
- Two toolchain-strictness traps already bit once (2026-08-08, entries 15-16
  in `conduit-failure-archaeology`): long `??` chains over `AnyCodable`
  time out the type-checker (cap at ~4 terms or bind typed intermediates),
  and pure statics on a `@MainActor` type need `nonisolated` to be callable
  from synchronous nonisolated tests.
- Device run fails with `DVTDeviceSymbolsCoordinatorErrorDomain` code 908
  (worker `IDEInstallCoreDeviceWorker`, operation `dscExtractor`): Xcode
  could not extract the device's dyld shared-cache symbols. Observed
  2026-08-08 on beta-to-beta (Xcode 27 beta -> iOS 27 beta iPhone) with the
  startup disk nearly full. Fix: free disk space (extraction needs ~10+ GB
  scratch) and delete the device's folders under
  `~/Library/Developer/Xcode/iOS DeviceSupport/` (regenerated on next run —
  a half-extracted folder from a failed attempt also causes repeat 908s).
  Escalation if it recurs with ample disk: reboot phone + Mac, use a cable,
  then suspect the Xcode beta seed vs that iOS build.

### Simulator vs device

| Feature | Simulator | Device |
|---|---|---|
| Chat/WebSocket, WKWebView auth bridge | Works [candidate -- unverified] | Works |
| Voice mode (mic capture, wake word, on-device speech) | Unreliable/partial; the pipeline uses AVFAudio + Speech and mic permission (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`) [candidate -- unverified] | Required for real testing; AVAudioSession conflicts are a user-reported top failure class -- see `conduit-voice-pipeline` |
| Push notifications (APNs pairing flow) | Not representative; entitlement is `aps-environment: production` [candidate -- unverified whether simulator APNs on Apple Silicon works with this setup] | Required |
| Face ID credential lock (`LocalAuthentication`) | Simulator Face ID menu simulation [candidate -- unverified] | Works |

Rule of thumb: UI and protocol work on simulator; anything touching audio,
push, or biometrics gets verified on a physical iPhone before calling it done.

## When NOT to use this skill

| If the task is... | Use instead |
|---|---|
| App Store submission, TestFlight, certificates/profiles beyond "make it build locally" | `conduit-appstore-and-signing` |
| Launching against a real Hermes server, login, day-to-day operation | `conduit-run-and-operate` |
| Runtime settings, feature flags, `@AppStorage` keys, push relay URL | `conduit-config-and-flags` |
| WebSocket protocol, RPC shapes, `/api/ws` behavior | `hermes-protocol-reference` |
| Reconnect/stale-session/auth-ticket reliability work | `conduit-ws-reliability-campaign` |
| Debugging a live failure | `conduit-debugging-playbook` |
| Voice/audio pipeline (AVAudioSession, wake word) | `conduit-voice-pipeline` |
| Past incidents and why things are the way they are | `conduit-failure-archaeology` |
| Architecture invariants (dashboard-only RPC, no telemetry) | `conduit-architecture-contract` |
| Tests and release QA gates | `conduit-validation-and-qa` |

## Provenance and maintenance

Re-verify volatile facts before trusting them (paste-ready):

```bash
# project.yml: targets, signing (Manual / U2TH557QA8 / Apple Distribution / profile), versions, iOS 17, Swift 5.9, AlternateIcons special-case, no packages
cat /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/project.yml
# .xcodeproj is gitignored (generated artifact)
grep -n "xcodeproj" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/.gitignore
# README build steps and requirements (Xcode 16, iOS 17 SDK, brew xcodegen)
grep -n -A 15 "## Building from source" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/README.md
# No SPM manifest anywhere
ls /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Package.swift 2>/dev/null || echo "no Package.swift (expected)"
# All imports are Apple frameworks
grep -rhE "^import " /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/ConduitTests | sort -u
# Alternate icon PNGs and their Info.plist references
ls /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Resources/AlternateIcons
grep -n -A 4 "CFBundleAlternateIcons" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Info.plist
# Entitlements (aps-environment)
cat /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Conduit.entitlements
# HTTP-only-for-loopback transport policy
grep -n -B 2 -A 4 "insecureTransport" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit/Services/ConnectionURLPolicy.swift
# /api/ws is the single RPC entry point in client code
grep -rn "api/ws" /Users/marcswan/Documents/Code/personal/tools/hermes-conduit/Conduit
# Mine the 4 post-release fix commits (history is squashed to 5 commits total)
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log --oneline
git -C /Users/marcswan/Documents/Code/personal/tools/hermes-conduit log -p d0873ec  # example: WKSecurityOrigin port-mismatch fix
```

Volatile facts (re-check on each pass, date-stamped 2026-08-08):
- 2026-08-08: MARKETING_VERSION "0.1.1", CURRENT_PROJECT_VERSION "114" (project.yml)
- 2026-08-08: team U2TH557QA8, profile "Conduit App Store", bundle id com.milim.relay (project.yml)
- 2026-08-08: README requires Xcode 16+, iOS 17 SDK, xcodegen via brew
- 2026-08-08: zero third-party dependencies; no packages: section in project.yml

Run log:
- 2026-08-08 (build): initial authoring
- 2026-08-08 (build): added Xcode license-gate trap and toolchain-strictness notes discovered during Kanban phases 1-3
- 2026-08-08 (build): added DVT error 908 dscExtractor trap (disk-full symbol extraction on beta-to-beta device runs)
