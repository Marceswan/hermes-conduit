# Mac desktop widgets: design

Date: 2026-10-16. Status: draft for review. Decision: D25. Target: the macOS app only (`ConduitMac`). iOS behaviour is unchanged.

## Goal

Ship the two iOS launcher widgets (Native, Conduit-chan) on the Mac desktop and in Notification Center as a WidgetKit app extension embedded in Conduit.app, reusing the iOS widget source, the snapshot the app already publishes, and the `conduit://widget/v1/...` launch route. A tap on a widget resumes a chat, starts a new chat, or starts voice, through the same coordinator the iOS app uses.

Out of scope: new widget content, live status or counts, a Home-view metrics widget (D24 may feed one later; v1 does not depend on it), interactive (button) widgets, Live Activities, accessory families (macOS has none), session windows (D21).

## Facts (surveyed 2026-10-16, branch `macos`)

### The iOS widgets

- One extension target `ConduitWidgets` (`project.yml:145`), bundle id `com.milim.relay.widgets` (`project.yml:162`), embedded by the iOS app (`project.yml:68`). Sources: `ConduitWidgets/` (minus plist, entitlements, Resources), `ConduitWidgets/Resources/Assets.xcassets`, `Shared/Widgets/`, `Conduit/Localizable.xcstrings` (`project.yml:148-158`).
- A `WidgetBundle` with two widgets (`ConduitWidgets/LauncherWidgets.swift:35-41`): `NativeLauncherWidget` (kind `com.milim.relay.widgets.native`, `:9-20`) and `CharacterLauncherWidget` (kind `...character`, `:22-33`). Kinds are constants in `Shared/Widgets/WidgetSnapshot.swift:5-8`.
- Families: `.systemMedium` only, both widgets (`LauncherWidgets.swift:18`, `:31`). No small, large or accessory family exists on iOS.
- Timeline: `LauncherTimelineProvider: AppIntentTimelineProvider` (`ConduitWidgets/LauncherTimelineProvider.swift:24-40`). One entry, policy `.never`: the app drives refresh by `WidgetCenter.reloadTimelines`.
- Intent: `LauncherWidgetConfigurationIntent: WidgetConfigurationIntent` (`Shared/Widgets/WidgetConfiguration.swift:208-223`) with workspace, conversation and hide-title parameters. The pickers are `AppEntity` queries (`:147-206`) that read the snapshot through `WidgetSnapshotStore.production`. No other AppIntents (no button intents).
- Data read: the file `launcher-v1.json` (`WidgetSnapshotStore.filename`, `Shared/Widgets/WidgetSnapshotStore.swift:5`), a `WidgetSnapshot` (`WidgetSnapshot.swift:147-179`): schema version 1, app language, current workspace, up to 100 workspaces with up to 20 conversation choices each. Display metadata and ids only; no credentials.
- The view turns a snapshot into `WidgetEntryModel` links with `WidgetSelection.resolve` (`Shared/Widgets/WidgetSelection.swift:31-95`). Taps are SwiftUI `Link(destination:)` (`LauncherWidgets.swift:125`, `:167`), not intents.
- iOS-only API in the shared view: `widgetAccentedRenderingMode` behind `#available(iOS 18.0, *)` (`LauncherWidgets.swift:76`, `:138`). That modifier is macOS 15 and later; a bare `iOS 18.0, *` check compiles for macOS 14 and fails (same class of fix as ledger row `Conduit/Views/Components/ComposerBar.swift`, R4-widen).

### How data reaches the widget

- App group constant: `WidgetSnapshotStore.appGroup = "group.com.milim.relay.widgets"` (`WidgetSnapshotStore.swift:4`). `production` resolves it with `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` (`:16-19`) and the store reads and writes one JSON file there (atomic replace, `:29-40`). It is a file, not a UserDefaults suite.
- Entitlements (iOS): app `Conduit/Conduit.entitlements` lists `group.com.milim.relay.notifications` and `group.com.milim.relay.widgets`; extension `ConduitWidgets/ConduitWidgets.entitlements:5-8` lists the widgets group.
- Publisher: `AppState+Widgets.swift:17-90` (`publishWidgetSnapshot`), `:92-98` (`publishWidgetLanguage`), `:100-106` (`publishWidgetCurrentWorkspace`), `:108-120` (remove, retain). Reload: `WidgetCenter.shared.reloadTimelines(ofKind:)` for both kinds (`:9-15`). `WidgetSnapshotPublisher` writes only when bytes change and reloads only then (`Conduit/Services/WidgetSnapshotPublisher.swift:64-68`).
- Call sites: `AppState.swift:581` and `:3584` (current workspace), `:1053` (bot roster `didSet`), `:4083` (pin sync), `ConduitApp.swift:139` (language, `publishWidgetLanguage`).
- Compiled on macOS today: yes, with no gate. `ConduitMac` compiles all of `Conduit/` (minus listed excludes) and all of `Shared/` (`project.yml:249-250`), so `AppState+Widgets.swift`, `AppState+WidgetLaunch.swift`, `WidgetLaunchCoordinator.swift` and `Shared/Widgets/*` are already in the Mac binary and `import WidgetKit` already resolves. On the Mac the store targets `group.com.milim.relay.widgets`, which the Mac app does not declare (`ConduitMac/Resources/ConduitMac.entitlements` holds only audio-input and camera). So today Mac publishing is a no-op or writes to an unentitled path (UNKNOWN which; `~/Library/Group Containers/group.com.milim.relay.widgets` does not exist on the dev Mac, which is consistent with a nil container).
- Mac gaps: `ConduitMacApp.swift:72-75` omits `publishWidgetLanguage()` (ledger skip, `PORTING_LEDGER.md:41`); the DEBUG `WidgetLaunchUITestFixture` is skipped (ledger `:43`; it serves the iOS XCUITest target and stays skipped).

### Launch path

- `routeWidgetLaunchURL` (`AppState+WidgetLaunch.swift:7-15`) consumes every `conduit://widget/...` URL (a malformed one is consumed so it cannot fall through to `ConduitAppLink`), cancels chat-resume restoration and hands a typed `WidgetLaunchLink` to `WidgetLaunchCoordinator` (30 s deadline, `WidgetLaunchCoordinator.swift:101`). It defers until `widgetForegroundReady = isSceneActive && sceneHasBeenActive` (`AppState.swift:632`).
- Mac already calls it from both entry points: `.onOpenURL` (`ConduitMacApp.swift:90-91`) and the `openURL` environment via `MacOpenURLPolicy` (`:19-35`, `:80-86`). `.handlesExternalEvents(preferring: ["*"], allowing: ["*"])` (`:87`) keeps one window.
- Gap: `ConduitMac/Resources/Info.plist` has no `CFBundleURLTypes` (confirmed; `docs/macos/PLAN2_INPUTS.md:10` says the same). iOS registers the `conduit` scheme (`Conduit/Info.plist:61-73`). Without it, LaunchServices will not send a widget tap to the Mac app, so the route above never fires for an external tap. This is the one launch-path change.

### Mac app signing and sandbox

- `ConduitMac`: Developer ID Application, manual, team `58XKRG9VMA`, hardened runtime, no provisioning profile (`project.yml:274-295`). Entitlements: audio-input and camera only. It is not sandboxed.
- A WidgetKit extension on macOS must be sandboxed (`com.apple.security.app-sandbox`); an unsandboxed extension is not loaded. It reads the shared container through its group entitlement.

### Release path

- `scripts/mac-release.sh`: xcodegen, `xcodebuild archive -scheme ConduitMac -configuration Release`, `-exportArchive` with `scripts/mac-export-options.plist` (`developer-id`, manual, generic "Developer ID Application", no profile mapping), zip + notarize + staple the app, DMG, sign, notarize, staple DMG (`mac-release.sh:24-61`). `mac-ship.sh` wraps it (version, tag, GitHub Release, Sparkle feed) and does not touch the bundle.
- Version overrides (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) are passed as xcodebuild command-line settings (`scripts/lib/mac-version.sh`), which apply to every target, so an embedded extension picks them up if it does not pin different values on the command line.
- Sparkle 2.10.0 (D12) replaces the whole bundle from a DMG verified by EdDSA signature; nested code only has to be validly signed.

## Apple documentation: app group on macOS (evidence for the decision)

Sources read 2026-10-16 (Apple Developer Forums, quoting the macOS 15 Sequoia release notes and Apple DTS; the Apple "Configuring app groups" page itself was not fetchable from this environment, so confirm there):

- On macOS, app groups are not mediated by the developer website and are not allow-listed by a provisioning profile; the macOS-style id is `<TeamID>.<name>`. The iOS style `group.<name>` is accepted on macOS only when a provisioning profile authorizes it (Xcode 16.3 and later support it in Mac profiles). (Apple DTS, forums thread 758375 and related.)
- macOS 15 release notes: an app reads a group container without the "would like to access data from other apps" prompt only if it is distributed through the Mac App Store, or the group id is prefixed with the Team ID, or the id is authorized by an embedded provisioning profile. (forums thread 763826, quoting the notes.)
- A macOS widget extension using a `group.` id without a profile showed the prompt and exited at launch; switching to a team-prefixed id fixed it. (forums thread 758478.)

Conclusion: for a notarized Developer ID build with no provisioning profile, use a team-prefixed group id. A `group.` id would need a Developer ID provisioning profile on both the app and the extension, plus `provisioningProfiles` entries in the export options, and would still prompt on macOS 15 unless the profile authorizes it.

## Options

1. **Shared sources, new Mac extension target, team-prefixed group (recommended).** `ConduitMacWidgets` (macOS app-extension) compiles the iOS widget files and assets through `project.yml` paths. One upstream gate switches the app group constant on macOS. Smallest code surface; the views, provider, intent and snapshot are exactly the iOS code.
2. **Copy the widget sources into `ConduitMac/Widgets/`.** Rejected: two copies drift (the ledger sync routine cannot diff them) and violates "prefer sharing".
3. **`group.` id plus a Developer ID provisioning profile.** Rejected for v1: needs a portal App ID and profiles for two bundles, export-options profile mapping, a release Mac holding the profiles, and still depends on Xcode/portal support for iOS-style groups on Mac. Kept as the fallback if Task 5's launch check shows the team-prefixed entitlement is rejected.
4. **No app group: the app writes into the extension's container, or pushes data by other IPC.** Rejected: the extension's container path is private, and widgets cannot hold open XPC to the app.
5. **Add `.systemSmall` and `.systemLarge` layouts now.** Deferred (see open question 1): needs new view code and iOS-neutral design; v1 reuses the medium layout unchanged.

## Recommendation and design

### Target

A new `ConduitMacWidgets` target in `project.yml`: `type: app-extension`, `platform: macOS`, `deploymentTarget: "14.0"`, embedded in `ConduitMac` (`embed: true`, code-sign on copy), installed at `Conduit.app/Contents/PlugIns/ConduitMacWidgets.appex`.

- Sources (shared with iOS, nothing copied): `ConduitWidgets` (excluding `Info.plist`, `ConduitWidgets.entitlements`, `Resources/**`), `ConduitWidgets/Resources/Assets.xcassets` as resources, `Shared/Widgets`, `Conduit/Localizable.xcstrings` as a resource (the widget strings and `WidgetLocalization` bundle lookups already live there).
- Mac-only files in `ConduitMacWidgets/` (new folder, no Swift): `Info.plist`, `ConduitMacWidgets.entitlements`.
- Bundle id `com.meswan.hermes.mac.widgets` (a child of `com.meswan.hermes.mac`, as an embedded extension requires).
- Signing: same as `ConduitMac` (team `58XKRG9VMA`, manual, Developer ID Application, empty provisioning profile, hardened runtime), `APPLICATION_EXTENSION_API_ONLY: YES`, `SKIP_INSTALL: YES`, `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` pinned to the app's values (the release script overrides both on the command line for every target).
- Entitlements: `com.apple.security.app-sandbox = true`, `com.apple.security.application-groups = [58XKRG9VMA.com.meswan.hermes.mac.widgets]`. No network, no file access: the extension only reads the group container.

### Widgets and families

Both widgets ship: Native and Conduit-chan, family `.systemMedium` (unchanged from iOS). Same configuration intent (workspace, conversation, hide title), same kinds, same view, same `.never` timeline. macOS has no accessory families and iOS ships none, so nothing is dropped. Small and large are not offered in v1.

### App group and snapshot

`WidgetSnapshotStore.appGroup` becomes `58XKRG9VMA.com.meswan.hermes.mac.widgets` on macOS (one `#if os(macOS) // MAC:` / `#else` / `#endif // MAC:` region around the constant; the iOS line is untouched). The same constant feeds the app's `production` store and the extension's, so the three places that must agree are: the constant, `ConduitMac.entitlements` and `ConduitMacWidgets.entitlements` (a unit test pins all three). `ConduitMac.entitlements` gains `com.apple.security.application-groups`; the app stays unsandboxed. An unsandboxed app that declares a team-prefixed group opens `~/Library/Group Containers/58XKRG9VMA.com.meswan.hermes.mac.widgets` without a prompt (macOS 15 rule 2). The existing release-gate smoke line "no 'would like to access data from other apps' prompt" must still pass.

No change to `AppState+Widgets.swift`: it already publishes, coalesces and reloads on macOS; once the group is entitled the store becomes live. One Mac-side addition: `appState.publishWidgetLanguage()` in the language `onChange` of `ConduitMacApp.rootContent` (a Mac file; the ledger skip row becomes "ported").

### Tap handling

`Link(destination:)` in a macOS widget opens the URL through LaunchServices, which sends `conduit://widget/v1/<action>?...` to the app registered for the `conduit` scheme. Add `CFBundleURLTypes` (scheme `conduit`, role Viewer, name `$(PRODUCT_BUNDLE_IDENTIFIER).chat-link`) to `ConduitMac/Resources/Info.plist`. The URL then reaches `.onOpenURL` (`ConduitMacApp.swift:90`) and `routeWidgetLaunchURL`, unchanged. Registering the scheme also lets `ConduitAppLink(externalURL:)` session links from other apps open Conduit (code already present, previously unreachable); only session links are accepted, as on iOS.

### Behaviour

- Add widget: right-click desktop or Notification Center > Edit Widgets > Conduit. Native and Conduit-chan appear, medium only. "Edit Widget" opens the workspace / conversation pickers backed by the snapshot.
- Before the app has published (fresh install, signed out, or the container is unreadable): the widget shows "Open Conduit" with a generic open link. After the app connects and the catalog settles, `publishWidgetSnapshot` writes the file and reloads both kinds.
- Tap title: resume the chosen or last conversation. Tap New Chat or Talk: new chat or fresh voice in the widget's workspace. Cold launch, a hidden app, or a closed window: LaunchServices launches or activates the app, SwiftUI opens the window, the coordinator waits (up to 30 s) for connection and an active scene, then performs the action. If it cannot, `WidgetLaunch.Expired` / `WorkspaceUnavailable` messages show as on iOS.
- Language: in-app language changes republish; the extension renders titles through `WidgetLocalization` from the extension bundle.
- macOS 15 desktop tinting: the accented branch is widened to `macOS 15.0`; on macOS 14 the full-colour branch runs.

## Release impact and risks

1. **App group entitlement on a profile-less Developer ID app.** Per Apple DTS a team-prefixed macOS group is not restricted and needs no profile, so `codesign`, notarization and launch should accept it. UNVERIFIED on this build. Mitigation: Task 5 builds a signed Release archive and the verifier checks signatures and entitlements; the smoke checklist has a launch check of the exported app. Fallback: option 3.
2. **Signing the nested extension.** The export uses manual signing with the generic "Developer ID Application" certificate (`mac-export-options.plist`), which re-signs nested bundles with hardened runtime and a secure timestamp. No `provisioningProfiles` entry is needed because neither bundle uses a profile. New `scripts/mac-verify-bundle.sh` runs `codesign --verify --deep --strict` on the app, checks the appex is present, signed by team `58XKRG9VMA` with the `runtime` flag, has the sandbox and group entitlements, and (exported app only) has a secure timestamp; `mac-release.sh` calls it after export, before notarization, so a bad bundle never reaches `notarytool`.
3. **Notarization.** `ditto -c -k --keepParent` zips the whole app including `PlugIns`, so the appex is submitted with it. Notarization fails on an unsigned or non-runtime nested binary; the verifier catches that earlier. `stapler staple "$APP"` staples the app ticket, which covers nested code. `mac-release.sh` also gains `spctl --assess --type execute` on the stapled app, a check that now includes the extension.
4. **Sparkle.** Updates still replace the whole bundle from the EdDSA-verified DMG. The first update from a build without the extension simply adds `PlugIns/ConduitMacWidgets.appex`. Risk: a malformed nested signature makes Sparkle's post-extract validation fail; covered by item 2. The extension version must equal the app version (the verifier checks `CFBundleShortVersionString` and `CFBundleVersion`), or the Sparkle build number in the feed and the extension disagree.
5. **Widget registration lag.** `chronod` registers an extension when the app is first launched from a stable path (Applications). A copy in the DMG, DerivedData, or a second copy with the same bundle id may not appear or may pick the wrong copy. Manual checks use the installed copy; `pluginkit -mAvvv -p com.apple.widgetkit-extension` shows what is registered.
6. **Single-delivery of the widget URL with multiple windows (D21).** `.onOpenURL` is attached to the window root. If session windows put it on every window, one tap is delivered once by AppKit but `WidgetLaunchCoordinator.receive` only coalesces an in-flight identical link. D21 must keep the URL handler to one window; noted in the D25 decision text.
7. **Mac `widgetForegroundReady`.** It depends on `scenePhase` of the primary window (`RootView.swift:39-45`). PLAN2_INPUTS lists scene-active semantics on Mac as unsettled. A tap with all windows closed relies on SwiftUI opening a window and the scene becoming active within 30 s. Manual check; no code change in v1.
8. **Draft localizations.** The iOS widget target strips draft lprojs after build; the Mac app target does not, and `ConduitDraftLanguages` is empty today. The Mac extension does not run the script (matches `ConduitMac`). If a draft language is introduced, both Mac targets need the step.
9. **Debug and test builds.** `CODE_SIGNING_ALLOWED=NO` builds embed an unsigned, entitlement-less extension; unit tests inject the snapshot store (`widgetSnapshotStoreOverride`) as they do today, so no test touches the real group.

## Porting rules compliance

Upstream (non-Mac) files edited, 2 files, 3 regions:

| File | Edit | Rule |
|---|---|---|
| `Shared/Widgets/WidgetSnapshotStore.swift:4` | `#if os(macOS) // MAC:` team-prefixed group / `#else` original line / `#endif // MAC:` (1 gate; zero removed lines) | R4 |
| `ConduitWidgets/LauncherWidgets.swift:76`, `:138` | `iOS 18.0, *` becomes `iOS 18.0, macOS 15.0, *` with a `// MAC:` comment (2 availability widenings, no `#if`) | R4-widen |

Everything else is Mac-owned: `ConduitMac/Resources/{Info.plist,ConduitMac.entitlements}`, `ConduitMac/App/ConduitMacApp.swift`, `ConduitMacWidgets/*`, `project.yml`, scripts, docs. Ledger: 2 new rows (one per edited file), 1 row for the shared-source target, 2 existing skip rows updated.

## Testing

Automated (`ConduitMacTests`, command in the plan):

- `MacWidgetAppSideTests`: the Mac app group is team-prefixed and not `group.`; `ConduitMac.entitlements` declares it and stays unsandboxed; `Info.plist` registers `conduit`; `ConduitMacApp.swift` still calls `publishWidgetLanguage()`; `publishWidgetLanguage()` rewrites the stored language and reloads once.
- `MacWidgetsEmbeddingTests` (reads the hosted app bundle): `PlugIns/ConduitMacWidgets.appex` exists, id `com.meswan.hermes.mac.widgets`, extension point `com.apple.widgetkit-extension`, versions equal the app's, the extension entitlements file is sandboxed with the same group, and `ConduitMacWidgets/` contains no Swift (sharing, not copying).
- `MacWidgetLaunchRoutingTests` (real `AppState`): every link kind the extension can emit is consumed by `routeWidgetLaunchURL` and becomes a pending coordinator request; a malformed widget URL is consumed without a request; a non-widget `conduit://` URL is not consumed; `MacOpenURLPolicy` handles a widget URL before app-link parsing.
- `MacWidgetSnapshotHandoffTests`: a second `WidgetSnapshotStore` on the same directory (the extension's view) reads what `WidgetSnapshotPublisher` published, resolves the expected links, an unchanged republish does not reload, a missing or wrong-schema file yields the "Open Conduit" model with the generic open link.
- `scripts/tests/test-mac-verify-bundle.sh`: the verifier's plist helpers.
- `scripts/mac-verify-bundle.sh --archive` (Task 5): signed Release archive embeds and verifies the extension; publishes nothing.

Manual (added to `docs/macos/SMOKE_CHECKLIST.md`, release gate): install the exported app in /Applications, launch once; `pluginkit -mAvvv -p com.apple.widgetkit-extension | grep ConduitMacWidgets` lists it; widget gallery shows both widgets; add each, set a workspace and conversation; with Conduit connected the title and labels fill in within seconds; New Chat, Talk and title taps each do the right thing from warm, from a hidden app, from a closed window, and from a quit app; switch the app language and see the widget copy change; sign out and see "Open Conduit"; no consent prompt after login; Sparkle update from the previous build keeps the widget working.

## Open questions (default chosen)

1. Families: medium only, as on iOS. Default: medium only in v1; small (new-chat only) is the first follow-up.
2. Group id: `58XKRG9VMA.com.meswan.hermes.mac.widgets` (team-prefixed). Default: this; fall back to a `group.` id plus Developer ID profiles only if Task 5 shows the entitlement is rejected.
3. Register `conduit://` on Mac for everything (widgets and session links), or only widgets? macOS cannot scope a scheme by host. Default: register the scheme; the app already validates both hosts.
4. Strip draft localizations on the Mac extension? Default: no (matches `ConduitMac`).
5. Should D21 session windows keep `.onOpenURL` on one window? Default: yes, recorded in D25 for D21's author.
6. Should the Mac widgets bundle id mirror iOS (`com.milim.relay.widgets`)? Default: no; Mac targets use `com.meswan.hermes.mac.*`.

## Effort

About 3 days: app side and tests 0.5; extension target and embedding tests 1.0; verifier, release script and archive check 1.0; docs, smoke checklist and review fixes 0.5.

## Docs

New decision D25 in `docs/macos/DECISIONS.md`; ledger rows; `docs/macos/RELEASING.md` gains a widget verification note; `SMOKE_CHECKLIST.md` gains a Widgets section and a release-gate line; `PLAN2_INPUTS.md` line 10 notes that `conduit://` is now registered.
