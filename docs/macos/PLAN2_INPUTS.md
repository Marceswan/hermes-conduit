# Plan 2 inputs (from the final review)

Seams to design in Plan 2. None is fixed in Plan 1.

- Scene-active semantics on Mac: three notions exist and disagree: SwiftUI `scenePhase`, `PhoneScenePresence`, and `NSApp.isActive`. `AppState` code gated on `isSceneActive` was expected to stop on Cmd-Tab. Logs from 0.1.15 on macOS 27.3 with Stage Manager show otherwise: `handleScenePhase(.active)` appears not to run when the app comes to the front, and `isSceneActive` appears to stay true while another app is frontmost. The cause is not proven. D36 adds a log line in that handler to settle it.
- Notification suppression should use `NSApp.isActive` plus the key window, not `scenePhase`.
- `PhoneScenePresence` ignores occlusion; consider `window.occlusionState`.
- App Nap: hold a `ProcessInfo.beginActivity` token for the socket while a stream or call is live. Done in D29.
- "Close window mid-stream" is the proof item (SMOKE_CHECKLIST release gate): reply must complete after 30 s.
- `conduit://` is registered on Mac as of D25 (widgets: `CFBundleURLTypes` in ConduitMac/Resources/Info.plist); external session links and widget taps reach `.onOpenURL`. In-app links route through `MacOpenURLPolicy`.
