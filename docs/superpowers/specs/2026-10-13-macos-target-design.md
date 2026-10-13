# Conduit for macOS: native macOS target via compat shim

Date: 2026-10-13
Branch: `macos` (based on `upstream/main` at `c13e234f`)

## Intent

A native macOS build of Conduit for personal use on several Macs, at feature
parity with the iOS app except for features with no Mac equivalent. The fork
must keep merging upstream (`kaishi00/hermes-conduit`, very active) cheaply.

Stated by the user:
- Fork of upstream with an added macOS target (not Catalyst, not a rewrite).
- Personal use, installed on multiple Macs.
- v1 includes core chat, notifications, voice, admin tabs, and Bot Mode.
- Strategy: compat shim, so upstream files stay nearly untouched.
- Apple Watch alerts: only if easy. Resolved: they come from the existing
  iPhone push path, so no Mac work is needed.

Assumptions (approved in design review):
- macOS 14 (Sonoma) minimum, the API level that matches iOS 17.
- Single main window in v1.
- Credentials are per Mac (no iCloud Keychain sync); you log in once on each Mac.

Success criteria:
1. `ConduitMac` builds from `project.yml` with `xcodegen generate`.
2. On a Mac you can log in to a Hermes dashboard, list and switch sessions,
   stream Markdown replies (code, math, Mermaid), approve tool calls, attach
   and paste files and images, and switch models.
3. Admin tabs (capabilities, jobs, connectors, logs, Kanban) and Bot Mode work.
4. Voice works: push-to-talk, GPT-Live, and Gemini Live.
5. Local notifications fire for approvals, clarify requests, completed or
   failed turns, and background tasks while the app runs.
6. `scripts/mac-release.sh` produces a notarized, stapled `.dmg` that installs
   on another Mac with no Gatekeeper warning.
7. Merging `upstream/main` conflicts only at `// MAC:` tagged lines, in
   `project.yml`, or in Mac-only folders.

## Non-goals

- CarPlay, Apple Watch app, iOS widgets, Siri/App Intents, and camera capture
  are not ported to the Mac target. The code stays in the repo for the iOS build.
- Wake phrase (always-listening voice) is out of scope for v1.
- APNs remote push on the Mac and push relay pairing are out of scope.
- Multiple chat windows are out of scope.
- Alternate app icons are out of scope.
- Mac App Store distribution and sandboxing are out of scope.
- Contributing the work upstream is out of scope.

## Repo and git layout

- Local clone: `~/Documents/Code/conduit-macos`.
- Remotes: `origin` = `Marceswan/hermes-conduit`, `upstream` = `kaishi00/hermes-conduit`.
- `main` on origin holds 7 legacy fork commits (old OAuth, Kanban, rebrand).
  Leave them untouched; the Mac work does not build on them.
- All Mac work lives on `macos`, branched from `upstream/main`.
- Sync routine: `git fetch upstream && git merge upstream/main` into `macos`,
  then build `ConduitMac` and run `ConduitMacTests`.

New Mac-only folders (never touched by upstream):

| Folder | Contents |
|---|---|
| `ConduitMac/App/` | `@main` Mac app, window, menu commands, Settings scene, app delegate |
| `ConduitMac/Compat/` | UIKit-name shims, built as a Mac-only framework with module name `UIKit` (Section "Compat layer") |
| `ConduitMac/Chat/` | Mac-native replacements for UIKit chat views |
| `ConduitMac/Notifications/` | Local notification bridge |
| `ConduitMac/Voice/` | Mac-specific voice glue (orb view, hotkey) |
| `ConduitMac/Resources/` | `Info.plist`, entitlements, asset catalog |
| `ConduitMacTests/` | Unit tests for all Mac-only code |
| `scripts/mac-release.sh` | Archive, sign, notarize, staple, DMG |

### Upstream edit budget

Shared files are edited only where a shim cannot work. Every such edit carries
a `// MAC:` comment on or above the changed line, so
`grep -rn "// MAC:" Conduit Shared` lists every potential merge conflict.
Preferred edit shapes, in order:
1. Exclude the file from the Mac target in `project.yml` and supply a Mac file
   with the same type names.
2. Wrap a small block in `#if os(iOS)` / `#if os(macOS)`.
3. Extract a seam (protocol or function) that both platforms implement.

## `project.yml` changes

Add the target `ConduitMac`:
- `type: application`, `platform: macOS`, `deploymentTarget: "14.0"`.
- Sources: `Conduit/`, `Shared/`, `ConduitMac/`.
- Whole folders are NOT excluded. Shared code references CarPlay, Watch,
  WatchVoice, Widgets, and Intents types from 100+ files, so those folders
  compile for Mac. (AppIntents is available on macOS 13+, and most of these
  files are plain Swift.) Excluded are only the files that import a framework
  macOS lacks, plus the files replaced by Mac twins:
  - `Conduit/ConduitApp.swift`, `Conduit/Info.plist`, `Conduit/Conduit.entitlements`,
    `Conduit/Resources/AlternateIcons/**`
  - `Conduit/CarPlay/CarPlayVoiceSceneDelegate.swift`, `CarPlayVoiceCoordinator.swift`,
    `CarPlayBrowseTemplates.swift`, `CarPlayVoiceTemplateFactory.swift` (import `CarPlay`)
  - `Conduit/Watch/WatchVoiceLink.swift` (imports `WatchConnectivity`)
  - The twin-replaced view files listed under "Chat rewrites"
- Mac stubs with the same type names live in `ConduitMac/Stubs/` and expose
  only the members shared code calls: `CarPlayVoiceCoordinator`
  (`shared`, `voiceModeChanged(in:)`, `conversationStartingOnPhone(in:)`,
  `awaitConnection(of:timeout:)`), `CarPlayVoiceControls`, `WatchVoiceLink`
  (`shared`, `activate()`, `direct`, `log`, `share(_:)`, `startAnsweredCall(_:reply:)`),
  and `HermesNativeCalls`.
- `Conduit/Voice/HermesNativeCalls.swift` imports `CallKit` and `PushKit`. Its
  pure enums (`HermesNativeCallStorefront`, `HermesNativeCallPlan`) stay shared.
  The `HermesNativeCalls` class and the two imports are wrapped in
  `#if os(iOS)` with `// MAC:`, and the Mac stub supplies the class.
- The implementation plan keeps the exact exclusion list.
- Package dependency `WebRTC` (`stasel/WebRTC` 153.0.0; its package declares
  `.macOS(.v10_11)`).
- `PRODUCT_BUNDLE_IDENTIFIER: com.meswan.hermes.mac`.
- `DEVELOPMENT_TEAM: 58XKRG9VMA`, `CODE_SIGN_STYLE: Manual`,
  `CODE_SIGN_IDENTITY: "Developer ID Application"`,
  `ENABLE_HARDENED_RUNTIME: YES`, no App Sandbox.
- Entitlements: `com.apple.security.device.audio-input`,
  `com.apple.security.device.camera` (hardened runtime exceptions).
- `Info.plist` usage strings: microphone, speech recognition, camera.
- Uses the same String Catalogs as iOS, so localization carries over.

Add the target `ConduitMacTests` (`bundle.unit-test`, `platform: macOS`) hosted
by `ConduitMac`.

## Compat layer (`ConduitMac/Compat/`)

### Packaging: the `import UIKit` problem

46 shared files contain `import UIKit`, which does not resolve on native macOS.
Typealiases cannot fix an import. Approach:

- Primary: the shims live in a Mac-only framework target whose module name is
  `UIKit` (`ConduitMac/Compat/`, `PRODUCT_MODULE_NAME: UIKit`), which does
  `@_exported import AppKit` plus the shims below. Upstream `import UIKit` lines
  then compile unchanged on Mac. Native macOS has no system `UIKit` module in
  its default search paths (Catalyst's lives under `/System/iOSSupport`), so
  nothing collides.
- Fallback: if the primary approach fails in the plan's first task (a spike),
  replace each `import UIKit` with `#if canImport(UIKit) import UIKit #else
  import AppKit #endif` plus `// MAC:`. These are mechanical, low-churn lines,
  and the shims then live directly in the app target.

The plan's first task must prove one of these with a minimal build before any
other porting work.

Name collisions: AVFAudio declares `AVAudioSession` as unavailable on macOS,
and SwiftUI does the same for some iOS-only modifiers. A shim with the same
name in a different imported module may be an ambiguous reference. Shims for
such names live in the app target itself, because the importing module's
declarations shadow imported ones. The first task's spike verifies this for
`AVAudioSession`.

### Shims

Each shim exposes only the members upstream actually uses (inventoried on
2026-10-13). Add members as the compiler demands; do not pre-build unused API.

| iOS API (call sites) | Mac shim |
|---|---|
| `UIImage` (~98), `UIColor`, `UIFont` | `typealias` to `NSImage`, `NSColor`, `NSFont`, plus extensions for missing members used by upstream, such as `init?(data:)`, `pngData()`, `jpegData(compressionQuality:)`, `init(systemName:)`, `cgImage`. |
| `UIPasteboard` (~19) | Class wrapping `NSPasteboard.general`: `general`, `string`, `image`, `hasImages`, `hasStrings`, `items`/`setItems` as used. |
| `UIApplication` (~30) | Class with `shared` and these mappings: `open(_:)` to `NSWorkspace.shared.open`; `beginBackgroundTask`/`endBackgroundTask` as no-ops returning a token; `applicationState` from `NSApp.isActive`; `isIdleTimerDisabled` via an `IOPMAssertion`; `connectedScenes` empty; `supportsAlternateIcons` false; `preferredContentSizeCategory` `.large`; `registerForRemoteNotifications` no-op; `didBecomeActiveNotification` to `NSApplication.didBecomeActiveNotification`; `openSettingsURLString` to the System Settings privacy URL. |
| `AVAudioSession` (~87) | Stub class: `sharedInstance()`; `setCategory`/`setMode`/`setActive`/`setPreferredInput` succeed as no-ops; `recordPermission`/`requestRecordPermission` map to `AVCaptureDevice` audio authorization; `currentRoute`/`availableInputs` map to Core Audio devices; nested types (`Category`, `Mode`, `CategoryOptions`, `SetActiveOptions`, `InterruptionType`, `RouteChangeReason`, `Port`, `SilenceSecondaryAudioHintType`) and notification names exist but never fire. |
| Haptics, `UIImpactFeedbackGenerator`, `UINotificationFeedbackGenerator` | No-op classes. |
| `UIDevice` | `current.userInterfaceIdiom` returns `.pad`, so upstream's iPad paths, including the persistent sidebar (`SidebarLayoutPolicy` requires `.pad`), apply on Mac. `name` maps to `Host.current().localizedName`. |
| `UIViewRepresentable` | Not shimmed. Each user is excluded and rewritten (next section). |

Expected behavior gap: upstream code paths triggered only by iOS events (audio
interruptions, route changes, backgrounding) never run on Mac. This is correct,
and those paths stay untested on Mac.

## Chat rewrites (`ConduitMac/Chat/`)

Shared, unchanged: Markdown parsing (`MarkdownParsedDocument`, `MarkdownBlock`,
`MarkdownRenderCache`), `ChatScrollEngine` and its `ChatScrollSurface` protocol,
and all chat state in `AppState`.

| Excluded iOS file | Mac replacement (same public type name and init signature as upstream call sites need) |
|---|---|
| `Views/Components/SelectableTextView.swift` | `NSTextView` wrapper (`NSViewRepresentable`): native selection, copy, find, link clicks, height measuring for the layout the chat list expects. |
| `Views/Components/MarkdownSelectionHandles.swift` | Excluded. Native Mac selection replaces the drag handles. No-op twins of `MarkdownSelectionHandleOverlay`, `MarkdownSelectionChromeLocator`, and `MarkdownSelectionChromeRoot` keep the 4 referencing files compiling. `MarkdownSelectionCoordinator.swift` stays shared (only light UIKit use, covered by shims). |
| `Views/Components/ComposerPasteTextView.swift` | `NSTextView` composer: Return sends, Shift-Return adds a newline, image paste and file drag-drop produce the existing `PastedImage` model, IME composition is respected. |
| `Views/Components/MarkupBlock.swift` (`MarkupWebView`) | `NSViewRepresentable` around `WKWebView` with the same configuration, including the Cloudflare Access document-start user script. |
| `Views/ChatScrollSurfaceLocator.swift` | Locates the `NSScrollView` and adapts it to `ChatScrollSurface`. |
| `Views/Components/ImagePicker.swift` | `NSOpenPanel`-based picker plus drop target. |
| `Views/Components/CameraCapture.swift` | Mac twin with `isAvailable == false`, so `ComposerBar` hides the camera action without an upstream edit. |
| `LoginView.swift` `AuthWebView`, `DashboardTicketBridge.swift` `DashboardTicketBridgeView`, `MarkdownText.swift` `RemoteImageWebView`, `MarkupBlock.swift` `SafeMarkupWebView` | `WKWebView` `NSViewRepresentable` twins in `ConduitMac/WebViews/`. Each upstream struct is wrapped in `#if os(iOS)` (`// MAC:`) because it shares a file with code that stays shared. |
| `RootView.swift` `EdgePanGesture` | No-op twin (an iPhone edge swipe has no Mac meaning); upstream struct gated. |
| `MarkdownText.swift` `MarkdownSelectionHighlightOverlay` | No-op twin; upstream struct gated. |
| `LiquidOrb/LiquidOrbView.swift` | Plan 1: static placeholder twin. Plan 3 (voice): `MTKView` twin. |
| `NativeOAuth.swift` `SafariAuthenticationView` (`SFSafariViewController`) | Twin that opens the authorize URL in the default browser with `NSWorkspace` and shows a "Continue in your browser" panel with Cancel. Upstream's loopback listener (RFC 8252) receives the callback unchanged. |

Accepted Plan 1 placeholder (R29): `MediaPreviewPresenterMac` reveals the staged file in Finder instead of previewing it; `QLPreviewPanel` preview is backlog.

If an excluded file also defines types used elsewhere (for example
`PastedImage` in `ComposerPasteTextView.swift`), the Mac file redefines them
identically, or the type moves to a shared file with a `// MAC:` note. The
implementation plan must check each excluded file for such types.

## App shell (`ConduitMac/App/`)

- `ConduitMacApp` (`@main`): one `WindowGroup` (single main window), a
  `Settings` scene, and `Commands`.
- Root content: the upstream `RootView`, forced into the wide sidebar
  presentation (`SidebarPresentation`) used on iPad. This gives a
  `NavigationSplitView` with the session/bots/admin sidebar and the chat detail.
- `Settings` scene hosts upstream settings views.
- Menu commands:
  - New Chat: Cmd-N
  - Interrupt Turn: Cmd-.
  - Switch Dashboard: Cmd-Shift-D
  - Find in Chat: Cmd-F
  - Toggle Sidebar: Cmd-Ctrl-S
  - Push-to-Talk: Option-Space while the app is active
- Revision (plan research, 2026-10-13): the `Settings` scene, Switch Dashboard,
  and transcript-wide Find are deferred. Upstream `SettingsView` needs about 12
  closures owned by `RootView`, and no single `AppState` entry point opens the
  dashboard switcher. Both stay reachable from the sidebar. Find works per
  message via the `NSTextView` find bar. Cmd-. maps to `AppState.cancelCurrent()`.
- App delegate: `applicationShouldTerminateAfterLastWindowClosed` returns
  false; reopening from the Dock shows the main window again.
- Login: upstream `LoginView` and `NativeOAuth`, with the web view and Safari
  presenter twins listed under "Chat rewrites".
- First launch registers `conduit.ipadPersistentSidebar = true` in
  `UserDefaults`, so the persistent sidebar column is on by default.
- Face ID lock maps to `LocalAuthentication` (Touch ID or password on Mac).

Shared SwiftUI views (admin tabs, Kanban, Bot Mode, model and profile pickers,
voice settings) compile through the shims. Fix only what visibly breaks on Mac,
for example iOS-only modifiers like `.navigationBarTitleDisplayMode` and
`.textInputAutocapitalization`. Prefer no-op `View` extensions in
`ConduitMac/Compat/` where the compiler accepts them. SwiftUI marks some of
these unavailable on macOS, along with their argument types, which can make a
same-name shim ambiguous. Where that happens, use `// MAC:` gates.

## Notifications (`ConduitMac/Notifications/`)

- While the app runs, the dashboard WebSocket stays open (the app is never
  suspended).
- A `MacNotificationBridge` observes the same `AppState` events the iOS app
  maps to pushes: approval request, clarify request, completed turn, failed
  turn, background task finished. It posts a `UNUserNotificationCenter` local
  notification for each.
- Approval notifications carry Approve/Reject actions, routed to the existing
  approval RPC in `AppState`.
- No notification is posted for the session currently visible in a key window.
- Clicking a notification focuses the window and opens the session.
- "Launch at login" toggle in Settings uses `SMAppService.mainApp`.
- Apple Watch: not handled by the Mac. Watch alerts come from the iPhone
  Conduit app and the `hermes-conduit-notifier` plugin, mirrored by iOS.
  Alerts may appear on both the Mac and the iPhone/Watch; accepted.

## Voice

- GPT-Live: shared WebRTC code over `stasel/WebRTC` on macOS.
- Gemini Live: shared WebSocket code (`Shared/GeminiLive`).
- Push-to-talk: shared `SFSpeechRecognizer` and server Whisper paths.
- Microphone permission goes through the `AVAudioSession` shim to `AVCaptureDevice`.
- Liquid orb: shared Metal shader; `LiquidOrbView`'s `UIViewRepresentable`
  is replaced with an `MTKView` `NSViewRepresentable` in `ConduitMac/Voice/`.
- Background audio, interruptions, and CarPlay routing are not applicable.
- Wake phrase is excluded (non-goal). `AppState+WakePhrase.swift` is compiled
  out or gated.

## Credentials and multiple Macs

- Keychain items keep upstream attributes (`...ThisDeviceOnly`); each Mac logs in once.
- `kSecAttrAccessGroup` usage (1 site) is gated or set to nil on Mac, since the
  Mac target has no shared app group.
- Saved dashboards and settings live in the Mac app's `UserDefaults`.
  Sessions live on the Hermes server, so they are the same on every Mac.

## Build and distribution

Prerequisite: Xcode 16+ installed and selected (`xcode-select -s`). As of
2026-10-13 only Command Line Tools are active on the dev Mac.

`scripts/mac-release.sh`:
1. `xcodegen generate`
2. `xcodebuild archive -scheme ConduitMac`
3. Export with the Developer ID method (team `58XKRG9VMA`)
4. `xcrun notarytool submit --wait` using a stored keychain profile
5. `xcrun stapler staple`
6. `hdiutil create` a `.dmg`, then sign, notarize, and staple the DMG

The notary credentials profile is created once by the user
(`xcrun notarytool store-credentials`); the script reads the profile name from
an env var and never stores secrets in the repo.

## Testing

- `ConduitMacTests` covers:
  - Each compat shim: image data round-trip, pasteboard write/read, permission mapping, background-task token no-op.
  - The `NSScrollView` `ChatScrollSurface` adapter against `ChatScrollEngine`'s protocol.
  - The composer key handling (Return vs Shift-Return).
  - The notification bridge's event-to-notification mapping and suppression rule.
- Upstream `ConduitTests` stays iOS-only; Mac work must not break it. Run the
  iOS build and tests before each merge to `origin/macos`.
- Manual smoke checklist (in the plan): log in, stream a reply, Mermaid and
  math render, paste an image, approve a tool call from a notification, voice
  round-trip on each provider, install the notarized DMG on a second Mac.

## Risks

- `AppState.swift` (26.8k lines) has ~113 iOS API hits. Most compile through
  shims; the rest need `// MAC:` gates in the file with the highest merge-conflict rate.
- Chat height measuring and scroll pinning are tuned for `UITextView`; the
  `NSTextView` versions may need iteration to match streaming behavior.
- Shim names shadow UIKit names. A future upstream use of an unshimmed member
  shows up as a Mac compile error after merge, which is the intended signal.

## Addendum (2026-10-13): Mac accessibility sweep

Requested by the user after the Task 11 smoke run. It ships before the first
release build. Chosen approach: a global Mac layer, with zero edits to
upstream views for coverage.

- **Hover tooltips.** An app-level hover engine (`ConduitMac/Accessibility/`)
  hit-tests the accessibility tree under the resting pointer (0.6 s).
  - It shows the element's `accessibilityHelp`, else its
    `accessibilityLabel`, in a system-style tooltip for buttons, links,
    pop-up/menu buttons, checkboxes, radio buttons, disclosure triangles,
    and labelled images.
  - It shows nothing when the visible title equals the label.
  - It hides on any click, key, scroll, or mouse exit.
- **Hover feedback.** A pointing-hand cursor over enabled interactive
  controls, and a subtle accent highlight drawn over the hovered control.
  The highlight can be toggled from the View menu
  (`conduit.mac.hoverHighlight`, default on).
- **Esc in sheets.** Upstream has 60 sheets and none declares a
  `.cancelAction`. On Esc in a sheet window, the Mac layer finds the
  sheet's close/cancel/done button in the accessibility tree and presses
  it (`accessibilityPerformPress`), so SwiftUI's own dismiss path runs.
  It does nothing during IME composition or outside sheets.
- **Label audit.** A test scans `Conduit/Views` for icon-only buttons with
  no accessibility label. Gaps get `.accessibilityLabel` added upstream:
  cross-platform, tagged `// MAC: a11y`, with a ledger row. Reviewed false
  positives go in `docs/macos/a11y-audit-allowlist.txt`.
- **Smoke-run fixes.**
  - Login logo clipping: the Mac skips the focus-driven `scrollTo` in
    `LoginView`, via a single R4 gate.
  - The macOS app icon gets a proper rounded-rect mask with margins.
- **Out of scope:** detecting truncated text for overflow popovers.
- **Safety (ruling R18):** agents never send clicks or keys to the running
  app while the login form holds credentials. UI checks use hover and
  screenshots only.
