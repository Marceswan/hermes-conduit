# Mac Ask About Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chat > "Ask About Window..." (and a composer "+" menu item) lets the user pick one window with the system picker, captures it, and attaches the image to the current chat as a pending screenshot.

**Architecture:** `SCContentSharingPicker.shared` (single-window mode) returns an `SCContentFilter`; `SCScreenshotManager.captureImage(contentFilter:configuration:)` produces a `CGImage`. A pure helper (`MacWindowCaptureMath`) decides the pixel size, the encode ladder and the filename; a thin main-actor service (`MacWindowCaptureService`) drives the picker and capture and reports one `Outcome`; a small coordinator (`MacAskAboutWindow`) stages the result through `AttachmentStaging.stageScreenshot` and `AppState.setPendingScreenshot`, creating a chat first if none is open. The spike (`61c717d9`, `ConduitMac/App/WindowCaptureProbe.swift`) is reference only: reimplement, do not merge.

**Tech Stack:** Swift 6 / SwiftUI / AppKit on macOS 14+, ScreenCaptureKit, ImageIO, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** none written. The approved design is the spike result, restated in this plan's Goal, Architecture and Global Constraints. Read the spike with `git show 61c717d9`.

## Global Constraints

- Mac only. New code under `ConduitMac/AskAboutWindow/`. Do not touch iOS behaviour.
- Edits to shared files (`Conduit/`, `Shared/`) are `#if os(macOS)` gated, every gate tagged `// MAC:`, with one row each in `docs/macos/PORTING_LEDGER.md`. `git diff <base> -- Conduit Shared` removes zero lines. Prefer zero shared edits; the only expected one is the composer "+" menu item (Task 3).
- No new entitlements: `ConduitMac/Resources/ConduitMac.entitlements` is unchanged (only audio-input and camera today). The system picker grants per-window access without a Screen Recording prompt; `NSScreenCaptureUsageDescription` is not added.
- Do not edit `Conduit/Services/AppState.swift` (carries unrelated uncommitted edits in this checkout; leave `Conduit/Services/AppState.swift` and `Conduit/Views/ChatView.swift` alone).
- Size limit: `AttachmentSizeLimit.clampedMegabytes(UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey))` (default 16 MB, choices 8 to 256, as `AskHermesAboutScreenIntent` does at line 164). Never hard-code 20 as the spike did.
- Longest-side cap: 2560 px. Encode PNG first; if PNG exceeds 80% of the limit, JPEG at quality 0.85, then 0.7, then 0.5 with a further 0.75 scale step per round (max 3 rounds); still too big gives `.tooLarge`.
- Cancel is silent. Failure shows a visible error. Strings go through `AppLocalization.string(...)` and need keys in every shipped language in `Conduit/Localizable.xcstrings` (see `docs/LOCALIZATION.md`: one whole sentence per key, `scripts/l10n.py` worksheets, `python3 scripts/check-l10n-coverage.py --repo-root .`).
- Shortcut: Cmd-Shift-W is the candidate. Known bindings in `ConduitCommands.swift`: Cmd-N, Cmd-W (Close Tab), Cmd-Shift-T, Cmd-F, Cmd-., Cmd-1..9, Cmd-Shift-]/[, Ctrl-Tab, Ctrl-Shift-Tab, Cmd-[/], Opt-Cmd-Up/Down, Cmd-L, Ctrl-Cmd-S, Ctrl-Cmd-1..4. Task 3 re-verifies against `MacKeyboardShortcuts.swift`, `MacKeyboardTests`, the D10 table and the live menu before committing to it, with Cmd-Shift-A as the fallback.
- Menu actions use the existing guard `MacKeyboardActions.commandsBlocked(by:)` (do nothing while a sheet is attached) and are never `.disabled` (D10).
- Build: `xcodegen generate` after adding files, then `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`. Tests: same flags with `test -only-testing:ConduitMacTests/<Class>`. In zsh quote globs. Never two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- Safety: the user's own Conduit is running. Do not quit it, click it or type into it. Live picker smoke happens in the Debug build from `build/dd`, never the installed app.
- Clean up as you go: delete `build/dd` and scratch files when done.

## Review Focus

1. User cancels the picker (Esc / Cancel): no banner, no attachment, no stuck picker (a second invocation works). Test in Task 2 (`MacWindowCaptureOutcome.from`).
2. Picker or capture fails (error thrown, nil image): a visible error, and cancel and failure are never conflated. Test in Task 1 (error mapping) and Task 3 (banner text).
3. Retina 5K window, or a very tall window: output longest side is at most 2560 px and aspect ratio is kept; a 1x or tiny window is never upscaled. Test in Task 1.
4. Result exceeds the attachment limit (8 MB limit, busy window): JPEG ladder runs, then `.tooLarge` shows the existing `AttachmentSizeLimit.tooLargeMessage`. Test in Task 1 (`encodePlan`) and Task 3.
5. No chat open (`activeSessionId == nil`) or the chat is re-keyed while the picker is up: the screenshot lands in the chat that is current when capture finishes, creating one first if needed. A second invocation while one is in flight is ignored. Test in Task 3.

## File Map

- Create `ConduitMac/AskAboutWindow/MacWindowCaptureMath.swift`: pure helpers (Task 1).
- Create `ConduitMac/AskAboutWindow/MacWindowCaptureService.swift`: picker plus capture plus encode, outcome mapping (Task 2).
- Create `ConduitMac/AskAboutWindow/MacAskAboutWindow.swift`: coordinator, staging, attach, error surfacing (Task 3).
- Modify `ConduitMac/App/ConduitCommands.swift` (Chat menu item and shortcut) and `Conduit/Views/Components/ComposerBar.swift` (`attachmentButton` Menu, gated) (Task 3).
- Tests: `ConduitMacTests/MacWindowCaptureMathTests.swift`, `MacWindowCaptureServiceTests.swift`, `MacAskAboutWindowTests.swift`; extend `ConduitMacTests/MacKeyboardTests.swift` (or the menu test file it holds) with the shortcut pin.
- Docs: `docs/macos/PORTING_LEDGER.md` (one row), `docs/macos/DECISIONS.md` (D10 table row; a short new decision entry), `docs/macos/SMOKE_CHECKLIST.md`, `Conduit/Localizable.xcstrings` via `scripts/l10n.py`.

`ConduitMac/` is picked up by the folder glob in `project.yml`; confirm with `grep -n "ConduitMac" project.yml` and run `xcodegen generate` after adding files. Remove the spike's DEBUG item from consideration: it exists only on branch `worktree-agent-a55b2bf48b94e2c7e`.

---

### Task 1: Pure capture helpers

**Files:**
- Create: `ConduitMac/AskAboutWindow/MacWindowCaptureMath.swift`
- Test: `ConduitMacTests/MacWindowCaptureMathTests.swift`

**Interfaces:**
- Produces:
  - `enum MacWindowCaptureMath`
  - `static let maxLongestSide: Int = 2560`
  - `static func targetPixelSize(width: Int, height: Int, cap: Int = maxLongestSide) -> (width: Int, height: Int)` (never upscales, keeps aspect, minimum 1)
  - `enum Encoding: Equatable { case png; case jpeg(quality: Double, scale: Double) }`
  - `static func encodePlan(pngByteCount: Int, limitBytes: Int64) -> [Encoding]` (empty-ladder rule: `[.png]` if PNG is within 80% of the limit, else `[.jpeg(0.85, 1.0), .jpeg(0.7, 0.75), .jpeg(0.5, 0.5625)]`)
  - `static func filename(windowTitle: String?, appName: String?) -> String` (base name without extension, `"Window"` fallback, `/` and `:` replaced with `-`, trimmed, max 60 characters)
  - `enum Failure: Equatable { case noPicture, encodeFailed, pickerFailed }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacWindowCaptureMathTests: XCTestCase {
    func testDownscalesLongestSideAndKeepsAspect() {
        let s = MacWindowCaptureMath.targetPixelSize(width: 5120, height: 2880)
        XCTAssertEqual(s.width, 2560)
        XCTAssertEqual(s.height, 1440)
    }

    func testTallWindowCapsHeight() {
        let s = MacWindowCaptureMath.targetPixelSize(width: 800, height: 6400)
        XCTAssertEqual(s.height, 2560)
        XCTAssertEqual(s.width, 320)
    }

    func testNeverUpscalesAndNeverReachesZero() {
        let small = MacWindowCaptureMath.targetPixelSize(width: 640, height: 480)
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 480)
        let sliver = MacWindowCaptureMath.targetPixelSize(width: 5000, height: 1)
        XCTAssertEqual(sliver.width, 2560)
        XCTAssertEqual(sliver.height, 1)
    }

    func testPNGWhenWithinEightyPercent() {
        let limit = AttachmentSizeLimit.byteLimit(megabytes: 16)
        XCTAssertEqual(MacWindowCaptureMath.encodePlan(pngByteCount: Int(limit) / 2, limitBytes: limit), [.png])
    }

    func testJPEGLadderWhenPNGTooBig() {
        let limit = AttachmentSizeLimit.byteLimit(megabytes: 8)
        let plan = MacWindowCaptureMath.encodePlan(pngByteCount: Int(limit), limitBytes: limit)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.first, .jpeg(quality: 0.85, scale: 1.0))
    }

    func testFilename() {
        XCTAssertEqual(MacWindowCaptureMath.filename(windowTitle: "a/b: c", appName: "Safari"), "Safari - a-b- c")
        XCTAssertEqual(MacWindowCaptureMath.filename(windowTitle: nil, appName: nil), "Window")
        XCTAssertEqual(MacWindowCaptureMath.filename(windowTitle: "  ", appName: "Xcode"), "Xcode")
        XCTAssertLessThanOrEqual(MacWindowCaptureMath.filename(windowTitle: String(repeating: "x", count: 200), appName: nil).count, 60)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:ConduitMacTests/MacWindowCaptureMathTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL, `cannot find 'MacWindowCaptureMath' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum MacWindowCaptureMath {
    static let maxLongestSide = 2560

    enum Encoding: Equatable {
        case png
        case jpeg(quality: Double, scale: Double)
    }

    enum Failure: Equatable { case noPicture, encodeFailed, pickerFailed }

    static func targetPixelSize(width: Int, height: Int, cap: Int = maxLongestSide) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > cap, longest > 0 else { return (max(width, 1), max(height, 1)) }
        let scale = Double(cap) / Double(longest)
        return (max(Int((Double(width) * scale).rounded()), 1), max(Int((Double(height) * scale).rounded()), 1))
    }

    static func encodePlan(pngByteCount: Int, limitBytes: Int64) -> [Encoding] {
        if Double(pngByteCount) <= Double(limitBytes) * 0.8 { return [.png] }
        return [.jpeg(quality: 0.85, scale: 1.0), .jpeg(quality: 0.7, scale: 0.75), .jpeg(quality: 0.5, scale: 0.5625)]
    }

    static func filename(windowTitle: String?, appName: String?) -> String {
        func clean(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = [clean(appName), clean(windowTitle)].filter { !$0.isEmpty }
        let joined = parts.isEmpty ? "Window" : parts.joined(separator: " - ")
        return String(joined.prefix(60))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: the Step 2 command. Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/AskAboutWindow/MacWindowCaptureMath.swift ConduitMacTests/MacWindowCaptureMathTests.swift
git commit -m "macOS: Ask About Window capture math"
```

---

### Task 2: Picker and capture service

**Files:**
- Create: `ConduitMac/AskAboutWindow/MacWindowCaptureService.swift`
- Test: `ConduitMacTests/MacWindowCaptureServiceTests.swift`

**Interfaces:**
- Consumes: `MacWindowCaptureMath` (Task 1).
- Produces:
  - `enum MacWindowCaptureOutcome: Equatable { case captured(data: Data, isJPEG: Bool, suggestedName: String); case cancelled; case failed(MacWindowCaptureMath.Failure) }`
  - `static func MacWindowCaptureOutcome.from(pickerCancelled: Bool, startError: Error?, image: CGImage?) -> MacWindowCaptureOutcome`-style pure mapping, exposed as `MacWindowCaptureService.classify(cancelled: Bool, pickerError: Error?, captureError: Error?, hasImage: Bool) -> Classification` where `enum Classification: Equatable { case proceed, cancelled, failed(MacWindowCaptureMath.Failure) }` (cancelled wins only when no error is present)
  - `@MainActor final class MacWindowCaptureService: NSObject, SCContentSharingPickerObserver` with `func capture(limitBytes: Int64) async -> MacWindowCaptureOutcome` (one call in flight; a second concurrent call returns `.cancelled` immediately)
  - `static func encode(_ image: CGImage, limitBytes: Int64) -> (data: Data, isJPEG: Bool)?` using the ladder from `encodePlan` and ImageIO (`CGImageDestination`)

- [ ] **Step 1: Write the failing tests** (classification and encode only; the live picker is manual)

```swift
import XCTest
import CoreGraphics
@testable import ConduitMac

final class MacWindowCaptureServiceTests: XCTestCase {
    private struct Boom: Error {}

    func testCancelWithoutErrorIsCancelled() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: true, pickerError: nil, captureError: nil, hasImage: false), .cancelled)
    }
    func testPickerErrorIsFailureNotCancel() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: Boom(), captureError: nil, hasImage: false), .failed(.pickerFailed))
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: true, pickerError: Boom(), captureError: nil, hasImage: false), .failed(.pickerFailed))
    }
    func testCaptureErrorOrMissingImageIsNoPicture() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: nil, captureError: Boom(), hasImage: false), .failed(.noPicture))
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: nil, captureError: nil, hasImage: false), .failed(.noPicture))
    }
    func testHappyPathProceeds() {
        XCTAssertEqual(MacWindowCaptureService.classify(cancelled: false, pickerError: nil, captureError: nil, hasImage: true), .proceed)
    }

    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func testEncodeSmallImageIsPNG() {
        let out = MacWindowCaptureService.encode(solidImage(400, 300), limitBytes: AttachmentSizeLimit.byteLimit(megabytes: 16))
        XCTAssertEqual(out?.isJPEG, false)
    }
    func testEncodeDownscalesBigImageToCap() {
        let out = MacWindowCaptureService.encode(solidImage(6000, 3000), limitBytes: AttachmentSizeLimit.byteLimit(megabytes: 16))!
        let src = CGImageSourceCreateWithData(out.data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 2560)
    }
    func testEncodeReturnsNilWhenNothingFits() {
        XCTAssertNil(MacWindowCaptureService.encode(solidImage(400, 300), limitBytes: 10))
    }
}
```

Add `import ImageIO` to the test file.

- [ ] **Step 2: Run to verify it fails**

Run: Task 1 Step 2 command with `-only-testing:ConduitMacTests/MacWindowCaptureServiceTests`. Expected: FAIL, type not found.

- [ ] **Step 3: Implement**

`classify` and `encode` are pure statics. `capture(limitBytes:)` does, in order:
1. Guard single flight (`inFlight` flag, reset in a `defer`-equivalent `finish()`).
2. `var config = SCContentSharingPickerConfiguration(); config.allowedPickerModes = [.singleWindow]; config.excludedWindowIDs = NSApp.windows.map { Int($0.windowNumber) }` (exclude Conduit's own windows). If `excludedWindowIDs` is unavailable or ignored at runtime, drop it and note it in the DECISIONS entry (Task 3); the picker still works. Set `picker.defaultConfiguration = config`, `picker.add(self)`, `picker.isActive = true`, `picker.present()`.
3. Bridge the three observer callbacks (`didUpdateWith filter`, `didCancelFor`, `contentSharingPickerStartDidFailWithError`) to one `CheckedContinuation`, resumed exactly once (guard with an optional continuation set to nil after resume). Callbacks are `nonisolated` and hop with `Task { @MainActor in ... }`, as the probe does.
4. On a filter: `let cfg = SCStreamConfiguration(); let scale = CGFloat(filter.pointPixelScale); let px = MacWindowCaptureMath.targetPixelSize(width: Int(filter.contentRect.width * scale), height: Int(filter.contentRect.height * scale)); cfg.width = px.width; cfg.height = px.height; cfg.showsCursor = false`, then `try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)`. Letting ScreenCaptureKit scale to `px` means no second resample; `encode` still runs the ladder, and re-scales through `CGContext` only for the 0.75 and 0.5625 rungs.
5. Name via `MacWindowCaptureMath.filename(windowTitle: filter.includedWindows.first?.title, appName: filter.includedApplications.first?.applicationName)` (both optional; if `SCContentFilter` exposes no such properties on macOS 14, use `nil, nil` and "Window").
6. Always `picker.remove(self)` and `picker.isActive = false` before returning (the probe's `finish()`).
7. Map through `classify`; `.proceed` runs `encode`; a nil encode result returns `.failed(.encodeFailed)` only when no ladder rung fits, which the coordinator turns into the too-large message (Task 3), so return a distinct signal: add `case tooLarge(suggestedName: String)` to `MacWindowCaptureOutcome` and return it when `encode` is nil but an image existed.

`encode`: for each `Encoding` in `encodePlan(pngByteCount:limitBytes:)` (the PNG byte count comes from a first PNG encode of the capped image), encode with `CGImageDestinationCreateWithData` (`UTType.png` / `UTType.jpeg`, `kCGImageDestinationLossyCompressionQuality`), return the first result with `AttachmentSizeLimit.allows(byteCount:megabytes:)`-equivalent `Int64(data.count) <= limitBytes`.

- [ ] **Step 4: Run to verify it passes**

Run: Step 2 command. Expected: PASS (7 tests). Then the full build command from Global Constraints. Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/AskAboutWindow/MacWindowCaptureService.swift ConduitMacTests/MacWindowCaptureServiceTests.swift
git commit -m "macOS: Ask About Window picker and capture service"
```

---

### Task 3: Coordinator, menu items, strings, docs

**Files:**
- Create: `ConduitMac/AskAboutWindow/MacAskAboutWindow.swift`
- Modify: `ConduitMac/App/ConduitCommands.swift` (Chat menu, after Stop Response)
- Modify: `Conduit/Views/Components/ComposerBar.swift` (`attachmentButton` Menu, about line 905), gated
- Modify: `Conduit/Localizable.xcstrings` (via `scripts/l10n.py`)
- Modify: `docs/macos/PORTING_LEDGER.md`, `docs/macos/DECISIONS.md`, `docs/macos/SMOKE_CHECKLIST.md`
- Test: `ConduitMacTests/MacAskAboutWindowTests.swift`; extend `ConduitMacTests/MacKeyboardTests.swift`

**Interfaces:**
- Consumes: `MacWindowCaptureService.capture(limitBytes:)`, `MacWindowCaptureOutcome` (Task 2); `AttachmentStaging.stageScreenshot(data:filename:limitMegabytes:) -> StagedImport` (`.staged(Attachment)`, `.tooLarge(String)`, `.failed(String)`); `AppState.setPendingScreenshot(_:forSession:)`, `activeSessionId`, `createNewSession()`; `AttachmentSizeLimit.clampedMegabytes`, `byteLimit(megabytes:)`, `tooLargeMessage(names:megabytes:)`; `MacKeyboardActions.commandsBlocked(by:)`.
- Produces:
  - `enum MacAskAboutWindowMessage { static func message(for failure: MacWindowCaptureMath.Failure) -> String }` (localized, one sentence per case: picker failed, no picture, encode failed)
  - `@MainActor enum MacAskAboutWindow { static func run(appState: AppState, window: NSWindow?, service: MacWindowCaptureService = .shared) async }`
  - `protocol`-free seam for tests: `static func attach(_ outcome: MacWindowCaptureOutcome, appState: AppState, limitMegabytes: Int) async` holding all the post-capture logic.
  - Error surface: set `appState.errorMessage` if the Mac window already renders it (verify first with `grep -rn "errorMessage" Conduit/Views ConduitMac --include='*.swift'`; `Conduit/Views/BotRosterView.swift:250` clears it, so some view shows it). If no view in the chat route shows it, use `NSAlert.beginSheetModal(for: window)` with the same text instead; do not add a new banner view.

- [ ] **Step 1: Verify the shortcut is free**

Run: `grep -n "keyboardShortcut" ConduitMac/App/ConduitCommands.swift ConduitMac/App/MacKeyboardShortcuts.swift; grep -n -i "cmd-shift-w\|shift-cmd-w" docs/macos/DECISIONS.md`. Then run the Debug build and open the menus (File, Edit, Go, Window) looking for "Close Window"/Cmd-Shift-W (AppKit shows it only when window tabbing is on, which D11 disables). If bound anywhere, use Cmd-Shift-A and substitute it throughout this task.

- [ ] **Step 2: Write the failing tests**

```swift
@MainActor
final class MacAskAboutWindowTests: XCTestCase {
    func testCancelledIsSilent() async {
        let state = AppState()
        await MacAskAboutWindow.attach(.cancelled, appState: state, limitMegabytes: 16)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.pendingScreenshot(forSession: state.activeSessionId))
    }
    func testFailureSetsLocalizedError() async {
        let state = AppState()
        await MacAskAboutWindow.attach(.failed(.noPicture), appState: state, limitMegabytes: 16)
        XCTAssertEqual(state.errorMessage, MacAskAboutWindowMessage.message(for: .noPicture))
    }
    func testTooLargeUsesExistingMessage() async {
        let state = AppState()
        await MacAskAboutWindow.attach(.tooLarge(suggestedName: "Safari"), appState: state, limitMegabytes: 8)
        XCTAssertEqual(state.errorMessage, AttachmentSizeLimit.tooLargeMessage(names: ["Safari"], megabytes: 8))
    }
    func testCapturedStagesIntoActiveSession() async throws {
        let state = AppState()
        state.activeSessionId = "s1"
        await MacAskAboutWindow.attach(.captured(data: Self.tinyPNG, isJPEG: false, suggestedName: "Window"), appState: state, limitMegabytes: 16)
        XCTAssertNotNil(state.pendingScreenshot(forSession: "s1"))
        state.discardPendingScreenshot(forSession: "s1")
    }
}
```

`tinyPNG` is a 1x1 PNG built in the test with `CGContext` plus `CGImageDestination` (as in Task 2). Add a test for the no-chat case: with `activeSessionId == nil`, `attach` calls `createNewSession()` and stages into whatever `activeSessionId` becomes; if `AppState()` cannot create a session offline in tests, assert instead that `attach` does not stage into a nil session and surfaces no crash, and cover the creation path in the smoke line. In `MacKeyboardTests.swift` add a pin that the shortcut `W` + `[.shift, .command]` appears exactly once in the Chat menu definitions, following that file's existing pattern for the Cmd-Shift-T pin.

- [ ] **Step 3: Run to verify it fails**

Run: `-only-testing:ConduitMacTests/MacAskAboutWindowTests` build/test command. Expected: FAIL, type not found.

- [ ] **Step 4: Implement**

`run`: bail if `MacKeyboardActions.commandsBlocked(by: window)`; read the limit (`AttachmentSizeLimit.clampedMegabytes(UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey))`); `await service.capture(limitBytes: AttachmentSizeLimit.byteLimit(megabytes: limit))`; then `attach`. `attach` switch: `.cancelled` return; `.failed(f)` set `appState.errorMessage = MacAskAboutWindowMessage.message(for: f)`; `.tooLarge(name)` set the `tooLargeMessage`; `.captured`: if `appState.activeSessionId == nil { await appState.createNewSession() }`, `guard let sid = appState.activeSessionId`, then `switch AttachmentStaging.stageScreenshot(data:filename:limitMegabytes:)`: `.staged(a)` -> `appState.setPendingScreenshot(a, forSession: sid)`; `.tooLarge(n)` -> too-large message; `.failed` -> `.encodeFailed` message. Read `activeSessionId` after the await, not before the picker opens (Review Focus 5).

Menu: in `ConduitCommands` Chat menu add `Button(AppLocalization.string("Ask About Window\u{2026}")) { Task { await MacAskAboutWindow.run(appState: appState, window: NSApp.keyWindow) } }.keyboardShortcut("w", modifiers: [.shift, .command])`. Composer: inside `attachmentButton`'s Menu add, after the Workspace button, `#if os(macOS) // MAC: Ask About Window (picker capture)` a Button with `Label("Window", systemImage: "macwindow")` that calls the same `run`, `#endif`. `ComposerBar` is shared and cannot import `MacAskAboutWindow` unguarded; the gate keeps that. If `MacAskAboutWindow` is not visible to the shared `Conduit` target (it is in `ConduitMac/`), expose it through an `appState`-level closure or `@Environment` injected from `ConduitMacApp`; if that costs more than one extra shared line, skip the composer item and say so in the commit message (the design says "if cheap").

Strings: add to `Conduit/Localizable.xcstrings` the keys "Ask About Window\u{2026}", "Window" (only if the composer item ships), and the three failure sentences ("Couldn't open the window picker.", "Couldn't capture that window.", "Couldn't prepare the window image."), using `python3 scripts/l10n.py export <lang>` worksheets and `import --create` for every shipped language, then `python3 scripts/check-l10n-coverage.py --repo-root .` must pass. Use the ASCII three-dot form only if the existing catalog does for menu items (match "Check for Updates\u{2026}" in `ConduitCommands`, which uses the Unicode ellipsis).

Docs: PORTING_LEDGER row for the `ComposerBar.swift` gate (R4, one region, `// MAC:`), D10 table row (`Cmd-Shift-W | Chat > Ask About Window... | picker, capture, attach`), a short DECISIONS entry (picker-based capture, no Screen Recording prompt, `excludedWindowIDs` outcome, 2560 px cap and encode ladder), and this SMOKE_CHECKLIST line:

`  - [ ] Ask About Window (macOS 14 and 15, clean Screen Recording state: remove Conduit under System Settings > Privacy & Security > Screen & System Audio Recording first): Chat > Ask About Window... (Cmd-Shift-W) opens the system window picker with no Screen Recording permission prompt. Pick a Safari window: a screenshot chip appears in the open chat's composer. Esc in the picker: nothing happens and no error shows, and the item works again. With no chat open it creates one and attaches. Conduit's own windows are not offered (or, if the picker still lists them, record it). Set the attachment limit to 8 MB and pick a large busy window: it attaches as JPEG or shows the too-large message, never a crash. The composer + menu has the same item.`

- [ ] **Step 5: Run to verify, then full build**

Run: the Task 3 test command (Expected: PASS), `python3 scripts/check-l10n-coverage.py --repo-root .` (Expected: no errors), the full ConduitMac build (Expected: BUILD SUCCEEDED), and `git diff macos -- Conduit Shared | grep '^-[^-]'` (Expected: no removed lines). Confirm `git diff -- ConduitMac/Resources/ConduitMac.entitlements` is empty.

- [ ] **Step 6: Live smoke, then commit**

Run the Debug build from `build/dd` (not the installed Conduit) on macOS 14 and 15 and walk the SMOKE line; record results in the commit body. Then `rm -rf build/dd` and:

```bash
git add ConduitMac/AskAboutWindow ConduitMac/App/ConduitCommands.swift Conduit/Views/Components/ComposerBar.swift Conduit/Localizable.xcstrings ConduitMacTests docs/macos
git commit -m "macOS: Ask About Window (picker capture attached to chat)"
```
