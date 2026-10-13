# Plan 2 inputs (from the final review)

Seams to design in Plan 2. None is fixed in Plan 1.

- Scene-active semantics on Mac: three notions exist and disagree: SwiftUI `scenePhase`, `PhoneScenePresence`, and `NSApp.isActive`. `AppState` pollers gated on `isSceneActive` stop on Cmd-Tab even though the window is still visible.
- Notification suppression should use `NSApp.isActive` plus the key window, not `scenePhase`.
- `PhoneScenePresence` ignores occlusion; consider `window.occlusionState`.
- App Nap: hold a `ProcessInfo.beginActivity` token for the socket while a stream or call is live.
- "Close window mid-stream" is the proof item (SMOKE_CHECKLIST release gate): reply must complete after 30 s.
- `conduit://` is not registered on Mac (no `CFBundleURLTypes`), so external deep links do not reach the app. In-app links route through `MacOpenURLPolicy`.
