# Conduit macOS Target, Plan 1 of 3: Foundation and Core Chat

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A notarized `ConduitMac.app` that logs in to a Hermes dashboard and does core chat (sessions, streaming Markdown, approvals, attachments, model switching), with admin tabs and Bot Mode compiling and usable.

**Architecture:** A new macOS target compiles upstream `Conduit/` and `Shared/` almost unchanged. iOS names resolve through a Mac-only framework whose Swift module is named `UIKit`, and iOS-only views are replaced by same-named Mac twins in `ConduitMac/`. Upstream edits are limited to `#if os(iOS)` gates tagged `// MAC:`.

**Tech Stack:** Swift 5.9 language mode, SwiftUI + AppKit (macOS 14+), WebKit, XCTest, xcodegen, `stasel/WebRTC` 153.0.0, `xcodebuild`, `notarytool`.

**Spec:** `docs/superpowers/specs/2026-10-13-macos-target-design.md`

**Follow-up plans (not in this plan):**
- Plan 2 (notifications): `MacNotificationBridge`, notification actions, Launch at Login, keeping the socket alive with the window closed.
- Plan 3 (voice): `MTKView` orb, push-to-talk hotkey, GPT-Live and Gemini Live verification on Mac.

## Global Constraints

- macOS deployment target `14.0`. iOS targets are unchanged and must keep building.
- Branch `macos`, based on `upstream/main`. Never commit to `main`.
- Bundle ID `com.meswan.hermes.mac`, team `58XKRG9VMA`, signing identity `Developer ID Application`, `CODE_SIGN_STYLE: Manual`, hardened runtime on, no App Sandbox.
- Every edit to a file under `Conduit/` or `Shared/` carries `// MAC:` on the changed line or the `#if`/`#endif` lines.
- Upstream edits use only these shapes, in order of preference:
  - **R1:** No edit. The file compiles through shims.
  - **R2:** Exclude the file in `project.yml` and add a same-named twin under `ConduitMac/`.
  - **R3:** Wrap one iOS-bound type in `#if os(iOS)` / `#endif // MAC:` and twin it under `ConduitMac/`.
  - **R4:** Wrap one statement or block in `#if os(iOS)` / `#endif // MAC:`.
- Never shim `UITextView`, `UIScrollView`, `UIViewController`, or `UIView` subclasses. Views built on them take R2 or R3.
- Shims expose only members upstream uses. Add a member when the compiler asks for it; never pre-build.
- Record every R2/R3/R4 decision in `docs/macos/PORTING_LEDGER.md`, one row per decision: file, rule, reason.
- Secrets are never committed. Notary credentials come from the keychain profile named in `$CONDUIT_NOTARY_PROFILE`.

## Review Focus

1. **App closed to the background or window closed while a reply streams.** Upstream treats a non-foreground scene as background. Expected: the reply keeps streaming and is complete when the window reopens. Pinned in Task 11 by `PhoneScenePresenceMacTests`.
2. **Return in the composer during IME composition** (Japanese/Chinese input). Expected: Return confirms the composition and does not send. Pinned in Task 8 by `testReturnDuringMarkedTextDoesNotSubmit`.
3. **Pasting an image file copied in Finder** (a file URL on the pasteboard, not bitmap data). Expected: it attaches as an image. Pinned in Task 8 by `testFileURLImagePasteBecomesPastedImage`.
4. **Very long streamed replies.** Expected: the chat stays pinned to the bottom unless the user scrolled up, and does not jump while scrolled up. Pinned in Task 9 by `testScrolledUpUserIsNotYankedToBottom`.
5. **OAuth login cancelled in the browser, or the browser never returns.** Expected: Cancel in the app stops the loopback listener, and the login screen is usable again. Pinned in Task 10 by `testCancelStopsOperation`.

---

## File Map

| Path | Responsibility |
|---|---|
| `project.yml` | Adds targets `UIKitCompat`, `ConduitMac`, `ConduitMacTests`, scheme `ConduitMac` |
| `ConduitMac/Compat/Module/*.swift` | Framework with module name `UIKit`: AppKit re-export plus UIKit-name shims |
| `ConduitMac/Compat/App/AVAudioSessionShim.swift` | `AVAudioSession` stub, kept in the app target so it shadows AVFAudio's unavailable type |
| `ConduitMac/Stubs/*.swift` | Twins for iOS-framework-bound files (CarPlay, Watch, CallKit, scene presence) |
| `ConduitMac/WebViews/*.swift` | `WKWebView` `NSViewRepresentable` twins |
| `ConduitMac/Chat/*.swift` | `SelectableTextView`, `ComposerPasteTextView`, `ChatScrollSurfaceLocator`, selection-handle twins |
| `ConduitMac/Views/*.swift` | `ImagePicker`, `CameraCapture`, `EdgePanGesture`, `LiquidOrbView` placeholder, `SafariAuthenticationView` twins |
| `ConduitMac/App/*.swift` | `@main` app, app delegate, commands, Settings scene |
| `ConduitMac/Resources/` | `Info.plist`, `ConduitMac.entitlements`, `Assets.xcassets` (app icon) |
| `ConduitMacTests/*.swift` | Tests for everything above |
| `scripts/mac-release.sh` | Archive, export, notarize, staple, DMG |
| `docs/macos/PORTING_LEDGER.md` | Every R2/R3/R4 decision |
| `docs/macos/SMOKE_CHECKLIST.md` | Manual checks run before each release |

---

### Task 0: Toolchain prerequisite (user action)

**Files:** none

- [ ] **Step 1: User installs Xcode 16 or later from the App Store, then selects it**

Run: `sudo xcode-select -s /Applications/Xcode.app && xcodebuild -version`
Expected: `Xcode 16.x` or later printed.

- [ ] **Step 2: Confirm the tools resolve**

Run: `xcodegen --version && xcrun notarytool --version && security find-identity -v -p codesigning | grep "Developer ID Application"`
Expected: three lines of output, the last containing `Developer ID Application: Marc Swan (58XKRG9VMA)`.

---

### Task 1: Spike: prove the `UIKit` module and shadowing approach

Throwaway: the probe files are deleted at the end of this task. The kept outputs are the decision in `docs/macos/DECISIONS.md` and the target skeleton.

**Files:**
- Modify: `project.yml` (append targets)
- Create: `ConduitMac/Compat/Module/UIKitCompat.swift`
- Create: `ConduitMac/Probe/ProbeApp.swift` (deleted in Step 6)
- Create: `docs/macos/DECISIONS.md`

**Interfaces:**
- Produces: targets `UIKitCompat` (module `UIKit`) and `ConduitMac` (module `ConduitMac`), used by every later task.

- [ ] **Step 1: Append the Mac targets to `project.yml`**

Add under `targets:` (keep all existing targets untouched):

```yaml
  # macOS (docs/superpowers/specs/2026-10-13-macos-target-design.md).
  # The Swift module is named UIKit so upstream `import UIKit` resolves on Mac.
  UIKitCompat:
    type: framework
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: ConduitMac/Compat/Module
    settings:
      base:
        PRODUCT_NAME: ConduitUIKitCompat
        PRODUCT_MODULE_NAME: UIKit
        PRODUCT_BUNDLE_IDENTIFIER: com.meswan.hermes.mac.uikitcompat
        GENERATE_INFOPLIST_FILE: YES
        DEVELOPMENT_TEAM: 58XKRG9VMA
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
        PROVISIONING_PROFILE_SPECIFIER: ""
        SKIP_INSTALL: YES
        ENABLE_HARDENED_RUNTIME: YES
  ConduitMac:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: ConduitMac
        excludes:
          - "Compat/Module/**"
    settings:
      base:
        PRODUCT_NAME: Conduit
        PRODUCT_MODULE_NAME: ConduitMac
        PRODUCT_BUNDLE_IDENTIFIER: com.meswan.hermes.mac
        GENERATE_INFOPLIST_FILE: YES
        DEVELOPMENT_TEAM: 58XKRG9VMA
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
        PROVISIONING_PROFILE_SPECIFIER: ""
        ENABLE_HARDENED_RUNTIME: YES
        ENABLE_USER_SCRIPT_SANDBOXING: NO
    dependencies:
      - target: UIKitCompat
      - package: WebRTC
```

- [ ] **Step 2: Write the minimal shim module**

`ConduitMac/Compat/Module/UIKitCompat.swift`:

```swift
// The Mac stand-in for UIKit. Upstream files `import UIKit`; on macOS that
// import resolves to this module (PRODUCT_MODULE_NAME = UIKit), which
// re-exports AppKit and supplies the UIKit names upstream uses.
@_exported import AppKit

public typealias UIImage = NSImage
public typealias UIColor = NSColor
public typealias UIFont = NSFont
public typealias UIResponder = NSResponder
```

- [ ] **Step 3: Write the probe app that exercises all three risks**

`ConduitMac/Probe/ProbeApp.swift`:

```swift
import SwiftUI
import UIKit
import AVFAudio

// Risk 2: a same-named type in the importing module shadows AVFAudio's
// macOS-unavailable AVAudioSession.
final class AVAudioSession {
    static func sharedInstance() -> AVAudioSession { AVAudioSession() }
}

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup {
            // Risk 1: `import UIKit` resolves to the compat module.
            let image: UIImage? = UIImage(systemSymbolName: "star", accessibilityDescription: nil)
            // Risk 2 continued.
            let session = AVAudioSession.sharedInstance()
            Text("probe \(image == nil ? "no-image" : "image") \(String(describing: type(of: session)))")
                .padding()
        }
    }
}
```

- [ ] **Step 4: Build the probe**

Run: `xcodegen generate && xcodebuild -scheme ConduitMac -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

Each possible failure has one fallback:
- `no such module 'UIKit'` or a module redefinition error: switch to the spec's fallback. Rename `PRODUCT_MODULE_NAME` to `UIKitCompat`, then in Task 4 replace each `import UIKit` in shared files with `#if canImport(UIKit)` / `import UIKit` / `#else` / `import UIKitCompat` / `#endif // MAC:`.
- `'AVAudioSession' is ambiguous`: rename the shim class to `MacAudioSession`. In Task 3, add `typealias AVAudioSession = MacAudioSession` in the app target, then rebuild. If that is still ambiguous, gate the `AVAudioSession` call sites with R4 in Task 5 and record each one in the ledger.

- [ ] **Step 5: Launch and check the window**

Run: `open "$(xcodebuild -scheme ConduitMac -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Conduit.app"`
Expected: a window reading `probe image AVAudioSession`.

- [ ] **Step 6: Record the decision and delete the probe**

Write `docs/macos/DECISIONS.md`:

```markdown
# macOS port decisions

## D1: UIKit module packaging (Task 1 spike, YYYY-MM-DD)
Result: <"module named UIKit works" | "fallback: UIKitCompat module + gated imports">
Evidence: <the build line or error text>

## D2: AVAudioSession shadowing (Task 1 spike)
Result: <"same-named class in app target shadows AVFAudio" | "MacAudioSession + typealias" | "R4 gates">
Evidence: <the build line or error text>
```

Fill in the angle-bracket fields with the actual results. Then:

Run: `rm -r ConduitMac/Probe && git add project.yml ConduitMac docs/macos && git commit -m "macOS: target skeleton and UIKit-module spike result"`

---

### Task 2: Mac app shell skeleton and test target

**Files:**
- Modify: `project.yml` (add `ConduitMacTests`, scheme, Info.plist/entitlements settings)
- Create: `ConduitMac/App/ConduitMacApp.swift`
- Create: `ConduitMac/Resources/Info.plist`
- Create: `ConduitMac/Resources/ConduitMac.entitlements`
- Create: `ConduitMacTests/ShellSmokeTests.swift`

**Interfaces:**
- Produces: `ConduitMacApp` (`@main`), which is replaced by the full shell in Task 10. Also scheme `ConduitMac` with test action `ConduitMacTests`.

- [ ] **Step 1: Write the failing test**

`ConduitMacTests/ShellSmokeTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class ShellSmokeTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.meswan.hermes.mac")
    }

    func testMicrophoneUsageStringPresent() {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        XCTAssertFalse((value ?? "").isEmpty)
    }
}
```

- [ ] **Step 2: Add the test target and scheme to `project.yml`**

In the `ConduitMac` target settings, replace `GENERATE_INFOPLIST_FILE: YES` with:

```yaml
        GENERATE_INFOPLIST_FILE: NO
        INFOPLIST_FILE: ConduitMac/Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: ConduitMac/Resources/ConduitMac.entitlements
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
```

Append under `targets:`:

```yaml
  ConduitMacTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: ConduitMacTests
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        DEVELOPMENT_TEAM: 58XKRG9VMA
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
        PROVISIONING_PROFILE_SPECIFIER: ""
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Conduit.app/Contents/MacOS/Conduit"
        BUNDLE_LOADER: "$(TEST_HOST)"
    dependencies:
      - target: ConduitMac
      - target: UIKitCompat
```

Append at the top level (after `targets:`; if a `schemes:` key exists, add the entry under it instead):

```yaml
schemes:
  ConduitMac:
    build:
      targets:
        ConduitMac: all
    test:
      targets:
        - ConduitMacTests
    archive:
      config: Release
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | tail -15`
Expected: build FAILS with `INFOPLIST_FILE ... does not exist`, or no `@main`.

- [ ] **Step 4: Write `Info.plist`, entitlements, and the skeleton app**

`ConduitMac/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Conduit</string>
    <key>CFBundleDisplayName</key><string>Conduit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Conduit uses the microphone for voice conversations with Hermes.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Conduit transcribes your voice on this Mac before sending it to Hermes.</string>
    <key>NSCameraUsageDescription</key><string>Conduit can attach a photo from your camera to a chat.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
```

`NSAllowsArbitraryLoads` matches upstream support for plain HTTP over Tailscale and LAN dashboards. Before committing, run `plutil -p Conduit/Info.plist | grep -A6 NSAppTransportSecurity`. If upstream uses narrower ATS keys, copy those instead.

`ConduitMac/Resources/ConduitMac.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
```

`ConduitMac/App/ConduitMacApp.swift`:

```swift
import SwiftUI

@main
struct ConduitMacApp: App {
    var body: some Scene {
        WindowGroup("Conduit") {
            Text("Conduit for Mac")
                .frame(minWidth: 800, minHeight: 560)
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`, 2 tests passed.

- [ ] **Step 6: Commit**

```bash
git add project.yml ConduitMac ConduitMacTests
git commit -m "macOS: app shell skeleton, Info.plist, entitlements, test target"
```

---

### Task 3: Compat shims

**Files:**
- Modify: `ConduitMac/Compat/Module/UIKitCompat.swift`
- Create: `ConduitMac/Compat/Module/UIImage+Mac.swift`
- Create: `ConduitMac/Compat/Module/UIColorFont+Mac.swift`
- Create: `ConduitMac/Compat/Module/UIPasteboard.swift`
- Create: `ConduitMac/Compat/Module/UIApplication.swift`
- Create: `ConduitMac/Compat/Module/UIDevice.swift`
- Create: `ConduitMac/Compat/Module/Haptics.swift`
- Create: `ConduitMac/Compat/App/AVAudioSessionShim.swift` (name per D2 in `docs/macos/DECISIONS.md`)
- Test: `ConduitMacTests/CompatShimTests.swift`

**Interfaces:**
- Consumes: module `UIKit` from Task 1.
- Produces:
  - `UIImage`, `UIColor`, `UIFont`, `UIResponder` typealiases
  - `NSImage.pngData()`, `jpegData(compressionQuality:)`, `cgImage`, `init?(systemName:)`, `init(cgImage:)`
  - `NSFont.lineHeight`
  - `NSColor.label`, `.secondaryLabel`, `.link`, `.systemBackground`, `.secondarySystemBackground`
  - `UIPasteboard` (`general`, `init(_:)`, `string`, `image`, `hasStrings`, `hasImages`, `url`)
  - `UIApplication` (`shared`, `State`, `applicationState`, `open(_:options:completionHandler:)`, `open(_:options:) async`, `beginBackgroundTask(withName:expirationHandler:)`, `endBackgroundTask(_:)`, `isIdleTimerDisabled`, `sendAction(_:to:from:for:)`, `supportsAlternateIcons`, `alternateIconName`, `setAlternateIconName(_:completionHandler:)`, `registerForRemoteNotifications()`, `preferredContentSizeCategory`, `openSettingsURLString`, `didBecomeActiveNotification`, `OpenExternalURLOptionsKey`)
  - `UIBackgroundTaskIdentifier`, `UIContentSizeCategory`
  - `UIDevice` (`current`, `userInterfaceIdiom == .pad`, `name`), `UIUserInterfaceIdiom`
  - `UIImpactFeedbackGenerator`, `UINotificationFeedbackGenerator`, `UISelectionFeedbackGenerator`
  - `AVAudioSession` stub

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/CompatShimTests.swift`:

```swift
import XCTest
import UIKit
@testable import ConduitMac

final class CompatShimTests: XCTestCase {
    private func redSquare() -> UIImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    func testImagePNGRoundTrip() throws {
        let data = try XCTUnwrap(redSquare().pngData())
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.cgImage?.width, 4)
    }

    func testImageJPEGEncodes() {
        XCTAssertNotNil(redSquare().jpegData(compressionQuality: 0.8))
    }

    func testSystemNameImage() {
        XCTAssertNotNil(UIImage(systemName: "star"))
    }

    func testPasteboardStringRoundTrip() {
        let board = UIPasteboard(NSPasteboard(name: NSPasteboard.Name("conduit.tests.\(UUID())")))
        board.string = "hello"
        XCTAssertEqual(board.string, "hello")
        XCTAssertTrue(board.hasStrings)
        XCTAssertFalse(board.hasImages)
    }

    func testPasteboardImageRoundTrip() {
        let board = UIPasteboard(NSPasteboard(name: NSPasteboard.Name("conduit.tests.\(UUID())")))
        board.image = redSquare()
        XCTAssertTrue(board.hasImages)
        XCTAssertNotNil(board.image)
    }

    @MainActor
    func testBackgroundTaskTokensAreValidAndDistinct() {
        let first = UIApplication.shared.beginBackgroundTask(withName: "a", expirationHandler: nil)
        let second = UIApplication.shared.beginBackgroundTask(withName: "b", expirationHandler: nil)
        XCTAssertNotEqual(first, .invalid)
        XCTAssertNotEqual(first, second)
        UIApplication.shared.endBackgroundTask(first)
        UIApplication.shared.endBackgroundTask(second)
    }

    @MainActor
    func testIdleTimerTogglesAssertion() {
        UIApplication.shared.isIdleTimerDisabled = true
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        UIApplication.shared.isIdleTimerDisabled = false
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    @MainActor
    func testDeviceIdiomIsPadSoWideLayoutsApply() {
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .pad)
    }

    func testAudioSessionCallsSucceed() throws {
        let session = AVAudioSession.sharedInstance()
        XCTAssertNoThrow(try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker]))
        XCTAssertNoThrow(try session.setActive(true, options: []))
    }

    func testFontLineHeightPositive() {
        XCTAssertGreaterThan(UIFont.preferredFont(forTextStyle: .body).lineHeight, 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed" | head`
Expected: compile errors such as `value of type 'NSImage' has no member 'pngData'`.

- [ ] **Step 3: Write the shims**

`ConduitMac/Compat/Module/UIImage+Mac.swift`:

```swift
import AppKit

public extension NSImage {
    convenience init?(systemName: String) {
        self.init(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func pngData() -> Data? {
        bitmapRepresentation?.representation(using: .png, properties: [:])
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        bitmapRepresentation?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    private var bitmapRepresentation: NSBitmapImageRep? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
}
```

`ConduitMac/Compat/Module/UIColorFont+Mac.swift`:

```swift
import AppKit

public extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var link: NSColor { .linkColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}

public extension NSFont {
    /// UIFont.lineHeight: ascender to descender plus leading.
    var lineHeight: CGFloat { ceil(ascender - descender + leading) }
}
```

`ConduitMac/Compat/Module/UIPasteboard.swift`:

```swift
import AppKit

public final class UIPasteboard {
    public static let general = UIPasteboard(.general)

    public let board: NSPasteboard

    public init(_ board: NSPasteboard) {
        self.board = board
    }

    public var string: String? {
        get { board.string(forType: .string) }
        set {
            board.clearContents()
            if let newValue { board.setString(newValue, forType: .string) }
        }
    }

    public var image: NSImage? {
        get { NSImage(pasteboard: board) }
        set {
            board.clearContents()
            if let newValue { board.writeObjects([newValue]) }
        }
    }

    public var url: URL? {
        get { board.readObjects(forClasses: [NSURL.self])?.first as? URL }
        set {
            board.clearContents()
            if let newValue { board.writeObjects([newValue as NSURL]) }
        }
    }

    public var hasStrings: Bool { board.canReadObject(forClasses: [NSString.self], options: nil) }
    public var hasImages: Bool { NSImage.canInit(with: board) }
}
```

`ConduitMac/Compat/Module/UIApplication.swift`:

```swift
import AppKit
import IOKit.pwr_mgt

public struct UIBackgroundTaskIdentifier: Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

public struct UIContentSizeCategory: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let large = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryL")
}

@MainActor
public final class UIApplication {
    public static let shared = UIApplication()
    public static let openSettingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy"
    public static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    public static let willResignActiveNotification = NSApplication.willResignActiveNotification

    public enum State: Sendable { case active, inactive, background }

    public struct OpenExternalURLOptionsKey: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    private var nextTaskID = 1
    private var idleAssertion: IOPMAssertionID?

    /// Mac apps are not suspended; "background" here means hidden.
    public var applicationState: State {
        if NSApp.isActive { return .active }
        return NSApp.isHidden ? .background : .inactive
    }

    public func open(
        _ url: URL,
        options: [OpenExternalURLOptionsKey: Any] = [:],
        completionHandler: ((Bool) -> Void)? = nil
    ) {
        completionHandler?(NSWorkspace.shared.open(url))
    }

    @discardableResult
    public func open(_ url: URL, options: [OpenExternalURLOptionsKey: Any] = [:]) async -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// No suspension on Mac, so there is nothing to extend. Tokens stay
    /// valid and distinct because callers compare against `.invalid`.
    public func beginBackgroundTask(
        withName name: String?,
        expirationHandler: (@MainActor @Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        defer { nextTaskID += 1 }
        return UIBackgroundTaskIdentifier(rawValue: nextTaskID)
    }

    public func beginBackgroundTask(expirationHandler: (@MainActor @Sendable () -> Void)?) -> UIBackgroundTaskIdentifier {
        beginBackgroundTask(withName: nil, expirationHandler: expirationHandler)
    }

    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}

    public var isIdleTimerDisabled: Bool {
        get { idleAssertion != nil }
        set {
            if newValue, idleAssertion == nil {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Conduit voice conversation" as CFString,
                    &id
                )
                if result == kIOReturnSuccess { idleAssertion = id }
            } else if !newValue, let id = idleAssertion {
                IOPMAssertionRelease(id)
                idleAssertion = nil
            }
        }
    }

    @discardableResult
    public func sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: Any?) -> Bool {
        NSApp.sendAction(action, to: target, from: sender)
    }

    public var supportsAlternateIcons: Bool { false }
    public var alternateIconName: String? { nil }

    public func setAlternateIconName(_ name: String?, completionHandler: ((Error?) -> Void)? = nil) {
        completionHandler?(nil)
    }

    public func registerForRemoteNotifications() {}

    public var preferredContentSizeCategory: UIContentSizeCategory { .large }
}
```

`ConduitMac/Compat/Module/UIDevice.swift`:

```swift
import AppKit

public enum UIUserInterfaceIdiom: Int, Sendable {
    case unspecified = -1, phone = 0, pad = 1, tv = 2, carPlay = 3, mac = 5, vision = 6
}

@MainActor
public final class UIDevice {
    public static let current = UIDevice()
    /// `.pad`: upstream's wide-layout paths (persistent sidebar) key off iPad.
    public let userInterfaceIdiom: UIUserInterfaceIdiom = .pad
    public var name: String { Host.current().localizedName ?? "Mac" }
    public var systemName: String { "macOS" }
    public var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
```

`ConduitMac/Compat/Module/Haptics.swift`:

```swift
import Foundation

/// Macs have no haptic engine for app feedback; these keep call sites compiling.
public final class UIImpactFeedbackGenerator {
    public enum FeedbackStyle: Int, Sendable { case light, medium, heavy, soft, rigid }
    public init(style: FeedbackStyle = .medium) {}
    public func prepare() {}
    public func impactOccurred() {}
    public func impactOccurred(intensity: CGFloat) {}
}

public final class UINotificationFeedbackGenerator {
    public enum FeedbackType: Int, Sendable { case success, warning, error }
    public init() {}
    public func prepare() {}
    public func notificationOccurred(_ type: FeedbackType) {}
}

public final class UISelectionFeedbackGenerator {
    public init() {}
    public func prepare() {}
    public func selectionChanged() {}
}
```

`ConduitMac/Compat/App/AVAudioSessionShim.swift`. If D2 chose `MacAudioSession`, name the class that and add `typealias AVAudioSession = MacAudioSession` at the bottom.

```swift
import AVFoundation

/// macOS has no audio session. Category, mode, and activation succeed as
/// no-ops; permission maps to AVCaptureDevice; interruption and route
/// notifications exist but never fire on Mac.
final class AVAudioSession: NSObject {
    private static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }

    struct Category: RawRepresentable, Hashable {
        let rawValue: String
        static let ambient = Category(rawValue: "ambient")
        static let soloAmbient = Category(rawValue: "soloAmbient")
        static let playback = Category(rawValue: "playback")
        static let record = Category(rawValue: "record")
        static let playAndRecord = Category(rawValue: "playAndRecord")
        static let multiRoute = Category(rawValue: "multiRoute")
    }

    struct Mode: RawRepresentable, Hashable {
        let rawValue: String
        static let `default` = Mode(rawValue: "default")
        static let voiceChat = Mode(rawValue: "voiceChat")
        static let videoChat = Mode(rawValue: "videoChat")
        static let measurement = Mode(rawValue: "measurement")
        static let spokenAudio = Mode(rawValue: "spokenAudio")
        static let voicePrompt = Mode(rawValue: "voicePrompt")
    }

    struct CategoryOptions: OptionSet {
        let rawValue: UInt
        static let mixWithOthers = CategoryOptions(rawValue: 1 << 0)
        static let duckOthers = CategoryOptions(rawValue: 1 << 1)
        static let allowBluetooth = CategoryOptions(rawValue: 1 << 2)
        static let defaultToSpeaker = CategoryOptions(rawValue: 1 << 3)
        static let interruptSpokenAudioAndMixWithOthers = CategoryOptions(rawValue: 1 << 4)
        static let allowBluetoothA2DP = CategoryOptions(rawValue: 1 << 5)
        static let allowAirPlay = CategoryOptions(rawValue: 1 << 6)
    }

    struct SetActiveOptions: OptionSet {
        let rawValue: UInt
        static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }

    enum InterruptionType: UInt { case began = 1, ended = 0 }
    struct InterruptionOptions: OptionSet {
        let rawValue: UInt
        static let shouldResume = InterruptionOptions(rawValue: 1)
    }
    enum RouteChangeReason: UInt {
        case unknown = 0, newDeviceAvailable, oldDeviceUnavailable, categoryChange,
             override, wakeFromSleep = 6, noSuitableRouteForCategory, routeConfigurationChange
    }
    enum SilenceSecondaryAudioHintType: UInt { case begin = 1, end = 0 }
    enum RecordPermission { case undetermined, denied, granted }

    struct Port: RawRepresentable, Hashable {
        let rawValue: String
        static let builtInMic = Port(rawValue: "MicrophoneBuiltIn")
        static let builtInSpeaker = Port(rawValue: "Speaker")
        static let headphones = Port(rawValue: "Headphones")
        static let bluetoothHFP = Port(rawValue: "BluetoothHFP")
        static let bluetoothA2DP = Port(rawValue: "BluetoothA2DPOutput")
        static let usbAudio = Port(rawValue: "USBAudio")
    }

    final class PortDescription: NSObject {
        let portType: Port
        let portName: String
        let uid: String
        init(portType: Port, portName: String, uid: String) {
            self.portType = portType
            self.portName = portName
            self.uid = uid
        }
    }

    final class RouteDescription: NSObject {
        let inputs: [PortDescription]
        let outputs: [PortDescription]
        init(inputs: [PortDescription], outputs: [PortDescription]) {
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    static let interruptionNotification = Notification.Name("ConduitMac.AVAudioSession.interruption")
    static let routeChangeNotification = Notification.Name("ConduitMac.AVAudioSession.routeChange")
    static let mediaServicesWereResetNotification = Notification.Name("ConduitMac.AVAudioSession.mediaServicesReset")
    static let silenceSecondaryAudioHintNotification = Notification.Name("ConduitMac.AVAudioSession.silenceHint")

    private(set) var category: Category = .soloAmbient
    private(set) var mode: Mode = .default

    func setCategory(_ category: Category, mode: Mode = .default, options: CategoryOptions = []) throws {
        self.category = category
        self.mode = mode
    }

    func setCategory(_ category: Category, options: CategoryOptions = []) throws {
        self.category = category
    }

    func setMode(_ mode: Mode) throws { self.mode = mode }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
    func setPreferredInput(_ input: PortDescription?) throws {}
    func setPreferredSampleRate(_ rate: Double) throws {}
    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {}

    var recordPermission: RecordPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func requestRecordPermission(_ response: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: response)
    }

    var currentRoute: RouteDescription {
        let input = AVCaptureDevice.default(for: .audio).map {
            PortDescription(portType: .builtInMic, portName: $0.localizedName, uid: $0.uniqueID)
        }
        let output = PortDescription(portType: .builtInSpeaker, portName: "Default Output", uid: "default-output")
        return RouteDescription(inputs: input.map { [$0] } ?? [], outputs: [output])
    }

    var availableInputs: [PortDescription]? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { PortDescription(portType: .builtInMic, portName: $0.localizedName, uid: $0.uniqueID) }
    }

    var sampleRate: Double { 48_000 }
    var isOtherAudioPlaying: Bool { false }
    var secondaryAudioShouldBeSilencedHint: Bool { false }
}
```

Add to `UIKitCompat.swift`, after the existing typealiases:

```swift
public typealias UIEdgeInsets = NSEdgeInsets
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed|SUCCEEDED|FAILED" | head`
Expected: `** TEST SUCCEEDED **`, 12 tests passed.

If `.microphone` is unavailable on the installed SDK (it is macOS 14+), use `.builtInMicrophone`. If `.external` is unavailable, use `.externalUnknown`.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac ConduitMacTests
git commit -m "macOS: UIKit-name compat shims with tests"
```

---

### Task 4: Stubs for iOS-framework-bound files

**Files:**
- Modify: `Conduit/Voice/HermesNativeCalls.swift` (R3 gate, 4 lines)
- Create: `ConduitMac/Stubs/CarPlayStubs.swift`
- Create: `ConduitMac/Stubs/WatchVoiceLinkStub.swift`
- Create: `ConduitMac/Stubs/HermesNativeCallsStub.swift`
- Create: `ConduitMac/Stubs/PhoneScenePresence.swift`
- Create: `docs/macos/PORTING_LEDGER.md`
- Modify: `project.yml` (add shared sources and exclusions)
- Test: `ConduitMacTests/StubTests.swift`

**Interfaces:**
- Consumes: upstream types `AppState`, `WatchDirectBroker`, `WatchVoiceWire.Message`, `WatchPhoneContext`, `ConduitNotificationTarget`, `HermesNativeCallPlan`.
- Produces: `CarPlayVoiceCoordinator.shared`, `CarPlayVoiceControls`, `WatchVoiceLink.shared`, `HermesNativeCalls.shared`, `PhoneScenePresence.isInForeground`.

- [ ] **Step 1: Add shared sources to the Mac target in `project.yml`**

Replace the `ConduitMac` `sources:` block with:

```yaml
    sources:
      - path: ConduitMac
        excludes:
          - "Compat/Module/**"
      - path: Shared
      - path: Conduit
        excludes:
          - "ConduitApp.swift"
          - "Info.plist"
          - "Conduit.entitlements"
          - "Resources/AlternateIcons/**"
          # iOS-only frameworks (R2): twins in ConduitMac/Stubs.
          - "CarPlay/CarPlayVoiceSceneDelegate.swift"
          - "CarPlay/CarPlayVoiceCoordinator.swift"
          - "CarPlay/CarPlayBrowseTemplates.swift"
          - "CarPlay/CarPlayVoiceTemplateFactory.swift"
          - "CarPlay/PhoneScenePresence.swift"
          - "Watch/WatchVoiceLink.swift"
```

- [ ] **Step 2: Gate the CallKit-bound class in `HermesNativeCalls.swift` (R3)**

Wrap only the iOS-bound parts. At the top of the file, change `import CallKit` and `import PushKit` to:

```swift
#if os(iOS) // MAC: CallKit/PushKit are iOS-only; ConduitMac/Stubs/HermesNativeCallsStub.swift
import CallKit
import PushKit
#endif // MAC:
```

Directly above the `@MainActor` line that precedes `final class HermesNativeCalls: NSObject {` (line 98 at `c13e234f`), add:

```swift
#if os(iOS) // MAC: class is CallKit-bound; Mac twin in ConduitMac/Stubs
```

At the very end of the file, add:

```swift
#endif // MAC:
```

If anything after the `HermesNativeCalls` class's closing brace must stay shared (check with `sed -n '99,$p'`), close the `#endif // MAC:` right after that brace instead.

- [ ] **Step 3: Write the failing tests**

`ConduitMacTests/StubTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class StubTests: XCTestCase {
    func testCarPlayAwaitConnectionReturnsFalseImmediately() async {
        let appState = AppStateRuntimeRegistry.shared.appState
        let connected = await CarPlayVoiceCoordinator.awaitConnection(of: appState, timeout: .seconds(5))
        XCTAssertFalse(connected)
    }

    func testNativeCallsNeverOfferRinging() {
        XCTAssertFalse(HermesNativeCalls.offersRinging)
    }

    func testNativeCallsAnsweredOnWatchIsNil() {
        XCTAssertNil(HermesNativeCalls.shared.answeredOnWatch(ringID: "x"))
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "error:" | head -5`
Expected: errors such as `cannot find 'CarPlayVoiceCoordinator' in scope`. Other upstream compile errors also appear; Task 5 handles those. Look only for the stub symbols here.

- [ ] **Step 5: Write the stubs**

`ConduitMac/Stubs/CarPlayStubs.swift`:

```swift
import Foundation

/// CarPlay has no Mac counterpart. Shared code reports voice state changes
/// here; on Mac nobody is listening.
@MainActor
final class CarPlayVoiceCoordinator {
    static let shared = CarPlayVoiceCoordinator()

    func voiceModeChanged(in appState: AppState) {}
    func conversationStartingOnPhone(in appState: AppState) {}

    static func awaitConnection(of appState: AppState, timeout: Duration) async -> Bool { false }
}
```

Then copy the `CarPlayVoiceControls` struct verbatim from `Conduit/CarPlay/CarPlayVoiceTemplateFactory.swift` (starting at `struct CarPlayVoiceControls: Equatable {`, line 54 at `c13e234f`, through its closing brace) into the bottom of `CarPlayStubs.swift`. It is a plain value type that `CarPlayVoiceStateMapping.swift` uses. If the build then reports other missing `CarPlay*` types that are referenced only from `Conduit/CarPlay/` files, exclude those referencing files too and log each in the ledger. If a missing `CarPlay*` type is referenced from outside `Conduit/CarPlay/`, copy it the same way.

`ConduitMac/Stubs/WatchVoiceLinkStub.swift`:

```swift
import Combine
import Foundation

/// No Apple Watch pairs with a Mac. Watch alerts reach the Watch via the
/// iPhone app (spec: Notifications), so this link never activates.
@MainActor
final class WatchVoiceLink: ObservableObject {
    static let shared = WatchVoiceLink()

    private(set) lazy var direct = WatchDirectBroker(link: self)

    func activate() {}

    func startAnsweredCall(_ start: WatchVoiceWire.Message, reply: @escaping ([String: Any]) -> Void) {
        reply([:])
    }

    func share(_ context: WatchPhoneContext) {}

    func log(_ message: String) {}
}
```

Before compiling, check `log`'s real signature with `grep -n "func log" Conduit/Watch/WatchVoiceLink.swift` and match it exactly. Also check whether the upstream class is `@MainActor`, and match that too.

`ConduitMac/Stubs/HermesNativeCallsStub.swift`:

```swift
import Foundation

/// Calls from Hermes ring through CallKit and PushKit on iPhone only.
@MainActor
final class HermesNativeCalls: NSObject {
    static let shared = HermesNativeCalls()
    static let ringsKey = "hermesCalls.ringsLikeCall"
    static var ringingWanted: Bool { false }
    static var offersRinging: Bool { false }

    func activate() {}
    func ringingSettingChanged() {}
    func routedAnswerFailed(_ target: ConduitNotificationTarget) {}
    func answeredOnWatch(ringID: String) -> ConduitNotificationTarget? { nil }
}
```

`ConduitMac/Stubs/PhoneScenePresence.swift`:

```swift
import AppKit

/// Upstream asks "is a phone window in the foreground?" before running
/// foreground-only work. On Mac that means: a visible, unminimized window.
@MainActor
enum PhoneScenePresence {
    static var isInForeground: Bool {
        !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
    }
}
```

- [ ] **Step 6: Start the porting ledger**

`docs/macos/PORTING_LEDGER.md`:

```markdown
# macOS porting ledger

Every upstream file the Mac target excludes, gates, or twins. Re-check this
list after each `git merge upstream/main`.

| File | Rule | Reason | Mac side |
|---|---|---|---|
| Conduit/CarPlay/CarPlayVoiceSceneDelegate.swift | R2 | imports CarPlay | none needed |
| Conduit/CarPlay/CarPlayVoiceCoordinator.swift | R2 | imports CarPlay | ConduitMac/Stubs/CarPlayStubs.swift |
| Conduit/CarPlay/CarPlayBrowseTemplates.swift | R2 | imports CarPlay | none needed |
| Conduit/CarPlay/CarPlayVoiceTemplateFactory.swift | R2 | imports CarPlay | CarPlayVoiceControls copied to CarPlayStubs.swift |
| Conduit/CarPlay/PhoneScenePresence.swift | R2 | UIScene foreground check | ConduitMac/Stubs/PhoneScenePresence.swift |
| Conduit/Watch/WatchVoiceLink.swift | R2 | imports WatchConnectivity | ConduitMac/Stubs/WatchVoiceLinkStub.swift |
| Conduit/Voice/HermesNativeCalls.swift | R3 | CallKit/PushKit class | ConduitMac/Stubs/HermesNativeCallsStub.swift |
```

- [ ] **Step 7: Confirm no stub-symbol errors remain**

Run: `xcodebuild build -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "error:" | grep -E "CarPlayVoiceCoordinator|WatchVoiceLink|HermesNativeCalls|PhoneScenePresence|CarPlayVoiceControls" | head`
Expected: no output. Other errors remain and are handled in Task 5. `StubTests` run green at the end of Task 5, once the target compiles.

- [ ] **Step 8: Commit**

```bash
git add project.yml Conduit/Voice/HermesNativeCalls.swift ConduitMac ConduitMacTests docs/macos
git commit -m "macOS: stubs for CarPlay, Watch link, CallKit calls, scene presence"
```

---

### Task 5: Compile the non-view layer (Services, Models, Voice, Shared)

This task is compiler-driven: the exact error list exists only after a build. The rules, the known fixes, and the exit criterion are fixed.

**Files:**
- Modify: shims in `ConduitMac/Compat/Module/` (add members on demand)
- Modify: upstream files under `Conduit/Services`, `Conduit/Voice`, `Conduit/Models`, `Conduit/Watch`, `Shared/` (R3/R4 gates only, `// MAC:` tagged)
- Modify: `docs/macos/PORTING_LEDGER.md`
- Test: `ConduitMacTests/StubTests.swift` (from Task 4) must pass

**Interfaces:**
- Consumes: shims (Task 3), stubs (Task 4).
- Produces: a target where every error left is in a file under `Conduit/Views/`.

- [ ] **Step 1: Temporarily exclude `Conduit/Views` to isolate the non-view layer**

In `project.yml`, under the `Conduit` path's `excludes:` for `ConduitMac`, add `- "Views/**"` with the comment `# TEMP Task 5: removed in Task 6`.

Run: `xcodegen generate && xcodebuild build -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "^/.*error:" | sed -E 's/:[0-9]+:[0-9]+:/:/' | sort | uniq -c | sort -rn | head -40`
Expected: a grouped error list. Save it to `$SCRATCH/task5-errors.txt` for reference.

If the build reports a missing type that is defined under `Conduit/Views/`, the non-view layer depends on a view file. Remove that one file from the temporary exclusion by adding a negated path or listing the excludes per subfolder. Keep this step's exclusion as narrow as the build allows.

- [ ] **Step 2: Apply the known fixes**

These upstream sites are known from the 2026-10-13 inventory. Apply each one, then rebuild.

1. `Conduit/Services/AppState.swift` `UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), ...)` (line ~21527): compiles through shims (R1). No edit.
2. `UIBackgroundTaskIdentifier.invalid` sites (AppState, MessageReadAloudController, WatchDirectBroker): compile through shims (R1).
3. `UIApplication.shared.applicationState` switch with an `@unknown default`-free switch: the shim enum has exactly `active`, `inactive`, `background`, so exhaustive switches compile.
4. Keychain `kSecAttrAccessGroup` (1 site): find it with `grep -rn kSecAttrAccessGroup Conduit Shared`. Wrap the line that adds the access group in `#if os(iOS)` / `#endif // MAC: no shared app group on Mac`.
5. `AppState+WakePhrase.swift`: if its errors are UIKit-audio specific and not covered by the `AVAudioSession` shim, wrap the failing method bodies' iOS-only statements with R4. Wake phrase is a non-goal on Mac, but the methods must exist.

- [ ] **Step 3: Iterate until no errors remain outside `Conduit/Views/`**

For each remaining error, in order of count, pick the first rule that applies:

- Missing member on a shimmed type (`UIImage`, `UIApplication`, `UIPasteboard`, `UIDevice`, `UIFont`, `UIColor`, `AVAudioSession`): add that member to the shim, matching the iOS signature. If it has logic, add a test to `CompatShimTests`.
- A missing UIKit type used as a value (for example `UIFont.Weight`, `UIColor` initializer forms, `UITraitCollection` in a non-view helper): add a `typealias` or a minimal type to the shim module.
- A missing UIKit type used as a view or controller (`UIView` subclass, `UIViewController`, `UITextView`): apply R3 or R4 per Global Constraints. Never shim it.
- An iOS-only Apple API (`QLPreviewController`, `SFSafariViewController`, `UIWindowScene`, `.connectedScenes`): apply R4 at the call site and add an `#else` branch with the Mac equivalent when one exists (`NSWorkspace.shared.open`, `NSSharingServicePicker`). Otherwise use a no-op.

After each fix:

Run: `xcodebuild build -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -cE "^/.*error:"`

Commit after every 10 fixes or so with message `macOS: compile <area> (Task 5)`. Add a ledger row for every R3/R4.

- [ ] **Step 4: Exit check**

Run: `xcodebuild build -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "^/.*error:" | grep -v "/Conduit/Views/" | wc -l`
Expected: `0`.

- [ ] **Step 5: Verify that iOS still builds**

Run: `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Run `xcodebuild -list` if the scheme name differs.

- [ ] **Step 6: Commit**

```bash
git add -A Conduit Shared ConduitMac project.yml docs/macos
git commit -m "macOS: non-view layer compiles (Task 5)"
```

---

### Task 6: Compile the views, with placeholder twins

**Files:**
- Modify: `project.yml` (remove the TEMP `Views/**` exclusion; add view exclusions)
- Create: `ConduitMac/Chat/SelectableTextView.swift` (placeholder, real in Task 7)
- Create: `ConduitMac/Chat/ComposerPasteTextView.swift` (placeholder, real in Task 8)
- Create: `ConduitMac/Chat/ChatScrollSurfaceLocator.swift` (detached no-op, real in Task 9)
- Create: `ConduitMac/Chat/MarkdownSelectionHandles.swift`
- Create: `ConduitMac/Views/ImagePicker.swift`
- Create: `ConduitMac/Views/CameraCapture.swift`
- Create: `ConduitMac/Views/EdgePanGesture.swift`
- Create: `ConduitMac/Views/LiquidOrbView.swift`
- Create: `ConduitMac/Views/MarkdownSelectionHighlightOverlay.swift`
- Create: `ConduitMac/WebViews/WebViewTwins.swift` (placeholders, real in Task 7)
- Create: `ConduitMac/Views/SafariAuthenticationView.swift` (placeholder, real in Task 10)
- Modify: `Conduit/Views/LoginView.swift`, `RootView.swift`, `Components/MarkdownText.swift`, `Components/MarkupBlock.swift`, `Components/MarkdownSelectionCoordinator.swift`, `Services/DashboardTicketBridge.swift`, `Services/NativeOAuth.swift` (R3 gates)
- Test: `ConduitMacTests/ViewTwinTests.swift`

**Interfaces:**
- Produces Mac twins with the exact upstream initializers:
  - `SelectableTextView(attributedText: NSAttributedString | AttributedString, text: String, font:textColor:lineSpacing:maximumNumberOfLines:wrapsLines:linkColor:textAlignment:selfSizingWidthRange:selectionCoordinator:selectionSegment:)` and `static func bridge(_:defaultFont:defaultColor:linkColor:) -> NSAttributedString`
  - `ComposerPasteTextView(text:isFocused:measuredHeight:enabled:onPastedImage:onPastedImageError:editorIdentity:programmaticRevision:programmaticCursorAtEnd:returnKeySends:canSubmitFromReturn:onSubmitFromReturn:onUserEdit:)`, `static var minimumHeight`, `static var maximumHeight`, `PastedImage`
  - `ChatScrollSurfaceLocator(engine:)`
  - `MarkupWebView(document:onEvent:)` with `enum Event { case height(CGFloat), failed(String?) }`
  - `SafeMarkupWebView(html:)`, `RemoteImageWebView(url:height:failed:)`, `AuthWebView` (same stored properties as upstream), `DashboardTicketBridgeView(bridge:)`
  - `SafariAuthenticationView(url:operation:onSuccess:onError:onCancel:)`
  - `ImagePicker(image:)`, `CameraCapture(onCapture:)` with `static var isAvailable`
  - `EdgePanGesture` (same stored properties as upstream), `LiquidOrbView(pipeline:state:speech:animates:framesPerSecond:)`
  - `MarkdownSelectionHighlightOverlay(coordinator:)`, `MarkdownSelectionHandleOverlay`, `MarkdownSelectionChromeLocator`, `MarkdownSelectionChromeRoot`

- [ ] **Step 1: Swap the TEMP exclusion for the view exclusions**

In `project.yml`, remove the `- "Views/**"` TEMP line and add:

```yaml
          # UIKit-backed views (R2): Mac twins in ConduitMac/Chat and ConduitMac/Views.
          - "Views/Components/SelectableTextView.swift"
          - "Views/Components/ComposerPasteTextView.swift"
          - "Views/Components/MarkdownSelectionHandles.swift"
          - "Views/Components/ImagePicker.swift"
          - "Views/Components/CameraCapture.swift"
          - "Views/ChatScrollSurfaceLocator.swift"
          - "Views/LiquidOrb/LiquidOrbView.swift"
```

`LiquidOrbView.swift` may hold more than the representable (the `LiquidOrbPipeline` and `LiquidOrbState` types). Check with `grep -nE "^(struct|final class|class|enum)" Conduit/Views/LiquidOrb/LiquidOrbView.swift`. If it does, keep the file compiled and gate only `struct LiquidOrbView` with R3 instead of excluding the file. Record which one you chose in the ledger.

- [ ] **Step 2: R3-gate the in-file representables**

Wrap each of these structs (and their private `UIView` helper classes) in `#if os(iOS) // MAC: Mac twin in ConduitMac/...` / `#endif // MAC:`. Remove `private` from nothing; the Mac twins are separate `internal` declarations.

| File | Struct(s) to gate | Twin path |
|---|---|---|
| `Conduit/Views/LoginView.swift` | `AuthWebView` and its Coordinator | `ConduitMac/WebViews/WebViewTwins.swift` |
| `Conduit/Views/RootView.swift` | `EdgePanGesture` | `ConduitMac/Views/EdgePanGesture.swift` |
| `Conduit/Views/Components/MarkdownText.swift` | `MarkdownSelectionHighlightOverlay`, `MarkdownSelectionHighlightView`, `RemoteImageWebView` | `ConduitMac/Views/MarkdownSelectionHighlightOverlay.swift`, `WebViewTwins.swift` |
| `Conduit/Views/Components/MarkupBlock.swift` | `MarkupWebView`, `SafeMarkupWebView` | `WebViewTwins.swift` |
| `Conduit/Services/DashboardTicketBridge.swift` | `DashboardTicketBridgeView` | `WebViewTwins.swift` |
| `Conduit/Services/NativeOAuth.swift` | `SafariAuthenticationView`, `SafariPresenterViewController` | `ConduitMac/Views/SafariAuthenticationView.swift` |
| `Conduit/Views/Components/MarkdownSelectionCoordinator.swift` | only the methods taking `UITextView`/`UIWindow` (`caretRect(for:in:)`, `highlightRects(in:)`, `selectionRects(for:in:window:)`, and any others the compiler flags), gated by R4 | none: on Mac, selection is native |

A gated struct may be `private` and referenced by a caller in the same file. In that case the Mac twin must be `internal` with the same name; the caller compiles against the twin.

- [ ] **Step 3: Write the failing tests**

`ConduitMacTests/ViewTwinTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import ConduitMac

@MainActor
final class ViewTwinTests: XCTestCase {
    func testCameraIsUnavailableOnMac() {
        XCTAssertFalse(CameraCapture.isAvailable)
    }

    func testComposerHeightBounds() {
        XCTAssertGreaterThanOrEqual(ComposerPasteTextView.minimumHeight, 32)
        XCTAssertGreaterThan(ComposerPasteTextView.maximumHeight, ComposerPasteTextView.minimumHeight)
        XCTAssertLessThanOrEqual(ComposerPasteTextView.maximumHeight, 280)
    }

    func testSelectableTextBridgeKeepsText() {
        let bridged = SelectableTextView.bridge(
            AttributedString("hello"),
            defaultFont: .preferredFont(forTextStyle: .body),
            defaultColor: .labelColor,
            linkColor: .linkColor
        )
        XCTAssertEqual(bridged.string, "hello")
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'CameraCapture' in scope` and similar.

- [ ] **Step 5: Write the twins**

`ConduitMac/Views/CameraCapture.swift`:

```swift
import SwiftUI
import UIKit

/// Not ported (spec non-goal). `isAvailable == false` hides the camera action.
struct CameraCapture: View {
    static var isAvailable: Bool { false }
    let onCapture: (UIImage) -> Void
    var body: some View { EmptyView() }
}
```

`ConduitMac/Views/ImagePicker.swift`:

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Profile and bot photos: an open panel instead of the iOS photo picker.
struct ImagePicker: View {
    @Binding var image: NSImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    image = NSImage(contentsOf: url)
                }
                dismiss()
            }
    }
}
```

`ConduitMac/Views/EdgePanGesture.swift`: copy the stored properties of upstream `EdgePanGesture` (`sed -n '586,600p' Conduit/Views/RootView.swift`; at `c13e234f` it is `var action: () -> Void` plus any others listed there) into:

```swift
import SwiftUI

/// The iPhone left-edge swipe has no Mac meaning; the sidebar is a column.
struct EdgePanGesture: View {
    var action: () -> Void
    var body: some View { EmptyView() }
}
```

`ConduitMac/Views/LiquidOrbView.swift` (placeholder until Plan 3):

```swift
import SwiftUI

/// Static placeholder; Plan 3 replaces it with the MTKView-backed shader orb.
struct LiquidOrbView: View {
    let pipeline: LiquidOrbPipeline
    var state: LiquidOrbState
    var speech: Float = 0
    var animates = true
    var framesPerSecond = 30

    var body: some View {
        Circle()
            .fill(.tint.opacity(0.35 + Double(speech) * 0.5))
            .animation(.easeOut(duration: 0.1), value: speech)
    }
}
```

Before writing it, check the full stored-property list with `sed -n '358,372p' Conduit/Views/LiquidOrb/LiquidOrbView.swift` and match it exactly.

`ConduitMac/Views/MarkdownSelectionHighlightOverlay.swift`:

```swift
import SwiftUI

/// Native NSTextView selection draws its own highlight on Mac.
struct MarkdownSelectionHighlightOverlay: View {
    @ObservedObject var coordinator: MarkdownSelectionCoordinator
    var body: some View { EmptyView() }
}
```

`ConduitMac/Chat/MarkdownSelectionHandles.swift`: run `grep -rnE "MarkdownSelectionHandleOverlay|MarkdownSelectionChromeLocator|MarkdownSelectionChromeRoot" Conduit | grep -v MarkdownSelectionHandles.swift` to see how the 4 call sites construct these. Then write no-op twins whose initializers match those call sites. The shape:

```swift
import SwiftUI

/// iOS drag handles for cross-block selection. Mac uses native selection.
struct MarkdownSelectionHandleOverlay: View {
    @ObservedObject var coordinator: MarkdownSelectionCoordinator
    var body: some View { EmptyView() }
}

@MainActor
final class MarkdownSelectionChromeLocator: ObservableObject {}

struct MarkdownSelectionChromeRoot<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content }
}
```

Adjust parameter names and generics to what the call sites pass, copying upstream's declarations at `MarkdownSelectionHandles.swift:11`, `:452`, and `:467` for the signatures.

`ConduitMac/Chat/ChatScrollSurfaceLocator.swift` (detached; the engine falls back to `ScrollViewProxy`, as upstream documents):

```swift
import SwiftUI

/// Task 6 placeholder: leaves ChatScrollEngine detached, which upstream
/// handles by falling back to ScrollViewProxy. Task 9 attaches NSScrollView.
struct ChatScrollSurfaceLocator: View {
    let engine: ChatScrollEngine
    var body: some View { Color.clear.allowsHitTesting(false) }
}
```

`ConduitMac/Chat/SelectableTextView.swift` (placeholder; Task 7 replaces the body):

```swift
import AppKit
import SwiftUI

struct SelectableTextView: View {
    let attributedText: NSAttributedString
    let font: NSFont
    let textColor: NSColor
    let lineSpacing: CGFloat
    let maximumNumberOfLines: Int
    let wrapsLines: Bool
    let linkColor: NSColor
    let textAlignment: NSTextAlignment
    let selfSizingWidthRange: ClosedRange<CGFloat>?
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?

    init(
        attributedText: NSAttributedString,
        font: NSFont = .preferredFont(forTextStyle: .body),
        textColor: NSColor = .labelColor,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: NSColor = .linkColor,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
    ) {
        self.attributedText = attributedText
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.wrapsLines = wrapsLines
        self.linkColor = linkColor
        self.textAlignment = textAlignment
        self.selfSizingWidthRange = selfSizingWidthRange
        self.selectionCoordinator = selectionCoordinator
        self.selectionSegment = selectionSegment
    }

    init(
        attributedText: AttributedString,
        font: NSFont = .preferredFont(forTextStyle: .body),
        textColor: NSColor = .labelColor,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: NSColor = .linkColor,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
    ) {
        self.init(
            attributedText: Self.bridge(attributedText, defaultFont: font, defaultColor: textColor, linkColor: linkColor),
            font: font, textColor: textColor, lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines, wrapsLines: wrapsLines, linkColor: linkColor,
            textAlignment: textAlignment, selfSizingWidthRange: selfSizingWidthRange,
            selectionCoordinator: selectionCoordinator, selectionSegment: selectionSegment
        )
    }

    init(
        text: String,
        font: NSFont = .preferredFont(forTextStyle: .body),
        textColor: NSColor = .labelColor,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: NSColor = .linkColor,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
    ) {
        self.init(
            attributedText: NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor]),
            font: font, textColor: textColor, lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines, wrapsLines: wrapsLines, linkColor: linkColor,
            textAlignment: textAlignment, selfSizingWidthRange: selfSizingWidthRange,
            selectionCoordinator: selectionCoordinator, selectionSegment: selectionSegment
        )
    }

    var body: some View {
        Text(AttributedString(attributedText))
            .textSelection(.enabled)
            .lineLimit(maximumNumberOfLines == 0 ? nil : maximumNumberOfLines)
    }
}
```

For `bridge`: copy upstream's `static func bridge(...)` verbatim. It starts at `Conduit/Views/Components/SelectableTextView.swift:487` at `c13e234f`; take everything through its closing brace, plus any private helpers it calls, into an `extension SelectableTextView` at the bottom of this file. Its UIKit names resolve through the shims. Add a `// Copied from upstream SelectableTextView.swift; keep in sync` comment above the extension, and a ledger row with the same note.

`ConduitMac/Chat/ComposerPasteTextView.swift` (placeholder; Task 8 replaces the body):

```swift
import AppKit
import SwiftUI

struct PastedImage: Equatable {
    let data: Data
    let typeIdentifier: String
}

struct ComposerPasteTextView: View {
    static var minimumHeight: CGFloat { max(36, ceil(bodyLineHeight) + 16) }
    static var maximumHeight: CGFloat { min(max(160, ceil(bodyLineHeight) * 4 + 16), 280) }
    private static var bodyLineHeight: CGFloat { NSFont.preferredFont(forTextStyle: .body).lineHeight }

    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let enabled: Bool
    let onPastedImage: (PastedImage) -> Void
    let onPastedImageError: (String) -> Void
    let editorIdentity: UUID
    var programmaticRevision: UInt64 = 0
    var programmaticCursorAtEnd = false
    var returnKeySends: Bool = false
    var canSubmitFromReturn: Bool = false
    var onSubmitFromReturn: (() -> Bool)? = nil
    var onUserEdit: (() -> Void)? = nil

    var body: some View {
        TextEditor(text: $text)
            .disabled(!enabled)
            .onChange(of: text) { _, _ in onUserEdit?() }
    }
}
```

Check `sed -n '60,100p' Conduit/Views/Components/ComposerPasteTextView.swift` for any stored property not listed above, and add it with the same default.

`ConduitMac/WebViews/WebViewTwins.swift` (placeholders; Task 7 makes them real):

```swift
import SwiftUI

struct MarkupWebView: View {
    enum Event: Equatable {
        case height(CGFloat)
        case failed(String?)
    }

    let document: MarkupDocument
    let onEvent: (Event) -> Void
    var body: some View { Color.clear.onAppear { onEvent(.failed("Not yet available on Mac")) } }
}

struct SafeMarkupWebView: View {
    let html: String
    var body: some View { EmptyView() }
}

struct RemoteImageWebView: View {
    let url: String
    @Binding var height: CGFloat
    @Binding var failed: Bool
    var body: some View { Color.clear.onAppear { failed = true } }
}

struct DashboardTicketBridgeView: View {
    let bridge: DashboardTicketBridge
    var body: some View { EmptyView() }
}
```

`AuthWebView`: copy its stored properties from `sed -n '868,880p' Conduit/Views/LoginView.swift` into a placeholder `struct AuthWebView: View { ...; var body: some View { EmptyView() } }` in the same file.

`ConduitMac/Views/SafariAuthenticationView.swift` (placeholder; Task 10 makes it real):

```swift
import SwiftUI

struct SafariAuthenticationView: View {
    let url: URL?
    let operation: @MainActor () async throws -> NativeOAuthLoginResult
    let onSuccess: @MainActor (NativeOAuthLoginResult) -> Void
    let onError: @MainActor (Error) -> Void
    let onCancel: () -> Void
    var body: some View { Button("Cancel", action: onCancel).padding() }
}
```

- [ ] **Step 6: Iterate on the remaining view errors**

Run: `xcodebuild build -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "^/.*error:" | sed -E 's/:[0-9]+:[0-9]+:/:/' | sort | uniq -c | sort -rn | head -40`

Apply the Task 5 Step 3 rules. These SwiftUI iOS-only modifiers will appear:
- `.navigationBarTitleDisplayMode`, `.textInputAutocapitalization`, `.keyboardType`, `.toolbar(placement: .navigationBarTrailing)`, `.listStyle(.insetGrouped)`, `.fullScreenCover`.

For each, first try a no-op extension in a new app-target file `ConduitMac/Compat/App/SwiftUIiOSModifiers.swift`, for example:

```swift
import SwiftUI

extension View {
    func textInputAutocapitalization(_ style: TextInputAutocapitalizationShim?) -> some View { self }
}

struct TextInputAutocapitalizationShim {
    static let never = Self()
    static let sentences = Self()
    static let words = Self()
    static let characters = Self()
}
```

If the compiler reports ambiguity or unavailability for a name, delete that shim and apply R4 at each call site instead. For `.fullScreenCover`, map to `.sheet` with the same arguments in the extension. For `.listStyle(.insetGrouped)` and `ToolbarItemPlacement.navigationBarTrailing`, use R4 with the `#else` branch `.listStyle(.inset)` / `.primaryAction`.

Commit roughly every 10 fixes with `macOS: compile views (Task 6)`.

- [ ] **Step 7: Run all tests**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED"`
Expected: `** TEST SUCCEEDED **`. That covers `ShellSmokeTests`, `CompatShimTests`, `StubTests`, and `ViewTwinTests`.

- [ ] **Step 8: Verify that iOS still builds**

Run: `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add -A Conduit Shared ConduitMac ConduitMacTests project.yml docs/macos
git commit -m "macOS: full target compiles with placeholder view twins (Task 6)"
```

---

### Task 7: Real web view twins and `SelectableTextView`

**Files:**
- Modify: `ConduitMac/WebViews/WebViewTwins.swift`
- Modify: `ConduitMac/Chat/SelectableTextView.swift`
- Test: `ConduitMacTests/SelectableTextViewTests.swift`, `ConduitMacTests/WebViewTwinTests.swift`

**Interfaces:**
- Consumes: upstream `MarkupDocument`, `MarkupHTML.page(_:presentation:)`, `CloudflareAccess` user-script helper (whatever upstream `MarkupWebView.makeUIView` calls), `DashboardTicketBridge`.
- Produces: `SelectableTextView` as an `NSViewRepresentable` with `sizeThatFits`; `MarkupWebView`, `SafeMarkupWebView`, `RemoteImageWebView`, `AuthWebView`, and `DashboardTicketBridgeView` as `NSViewRepresentable`s.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/SelectableTextViewTests.swift`:

```swift
import XCTest
import AppKit
@testable import ConduitMac

@MainActor
final class SelectableTextViewTests: XCTestCase {
    func testMeasuredHeightGrowsWhenWidthShrinks() {
        let text = String(repeating: "word ", count: 80)
        let wide = SelectableTextView.measuredHeight(of: NSAttributedString(string: text), width: 600)
        let narrow = SelectableTextView.measuredHeight(of: NSAttributedString(string: text), width: 200)
        XCTAssertGreaterThan(narrow, wide)
    }

    func testTextViewIsSelectableNotEditable() {
        let view = SelectableTextView.makeTextView()
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.drawsBackground)
    }

    func testMaximumLinesTruncates() {
        let text = NSAttributedString(string: String(repeating: "line\n", count: 20))
        let full = SelectableTextView.measuredHeight(of: text, width: 300)
        let capped = SelectableTextView.measuredHeight(of: text, width: 300, maximumNumberOfLines: 2)
        XCTAssertLessThan(capped, full)
    }
}
```

`ConduitMacTests/WebViewTwinTests.swift`:

```swift
import XCTest
import WebKit
@testable import ConduitMac

@MainActor
final class WebViewTwinTests: XCTestCase {
    func testMarkupWebViewIsTransparent() {
        let webView = MarkupWebView.makeConfiguredWebView()
        XCTAssertEqual(webView.value(forKey: "drawsBackground") as? Bool, false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "error:" | head -5`
Expected: `type 'SelectableTextView' has no member 'measuredHeight'`.

- [ ] **Step 3: Implement `SelectableTextView` on `NSTextView`**

Replace the `var body` in `ConduitMac/Chat/SelectableTextView.swift` and add the conformance. Keep the three initializers and the copied `bridge` exactly as they are.

```swift
// Change the declaration line to:
struct SelectableTextView: NSViewRepresentable {
```

Remove `var body`. Add:

```swift
extension SelectableTextView {
    static func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    static func measuredHeight(
        of text: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int = 0
    ) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maximumNumberOfLines
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    private func styledText() -> NSAttributedString {
        let styled = NSMutableAttributedString(attributedString: attributedText)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = wrapsLines ? .byWordWrapping : .byTruncatingTail
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
        return styled
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = Self.makeTextView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let styled = styledText()
        if view.attributedString() != styled {
            view.textStorage?.setAttributedString(styled)
        }
        view.textContainer?.maximumNumberOfLines = maximumNumberOfLines
        view.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        if let range = selfSizingWidthRange {
            let natural = ceil(styledText().size().width)
            let width = min(max(natural, range.lowerBound), range.upperBound)
            return CGSize(width: width, height: Self.measuredHeight(of: styledText(), width: width, maximumNumberOfLines: maximumNumberOfLines))
        }
        let width = proposal.width ?? 600
        return CGSize(width: width, height: Self.measuredHeight(of: styledText(), width: width, maximumNumberOfLines: maximumNumberOfLines))
    }
}
```

- [ ] **Step 4: Implement the web view twins**

For each of `MarkupWebView`, `SafeMarkupWebView`, `RemoteImageWebView`, `AuthWebView`, and `DashboardTicketBridgeView`:
1. Open the upstream struct (now inside `#if os(iOS)`).
2. Copy its full body, coordinator included, into `WebViewTwins.swift`, replacing the placeholder.
3. Apply these substitutions exactly:
   - `UIViewRepresentable` becomes `NSViewRepresentable`
   - `makeUIView` becomes `makeNSView`
   - `updateUIView` becomes `updateNSView`
   - `dismantleUIView` becomes `dismantleNSView`
   - `uiView` becomes `nsView` (parameter names)
   - `webView.isOpaque = false` and `webView.backgroundColor = ...` become `webView.setValue(false, forKey: "drawsBackground")`
   - delete every `webView.scrollView.*` line (5 sites at `c13e234f`). If a deleted line disabled scrolling, append `webView.enclosingScrollView?.hasVerticalScroller = false` after creation instead.
4. For `MarkupWebView`, pull the `WKWebView` creation into `static func makeConfiguredWebView() -> WKWebView` (the test calls it). `makeNSView` calls it, then sets the delegates.
5. Head each twin with `// Mac twin of <File>.swift <Struct>; keep in sync (PORTING_LEDGER).`, and add a ledger row for each.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac ConduitMacTests docs/macos
git commit -m "macOS: NSTextView SelectableTextView and WKWebView twins"
```

---

### Task 8: `ComposerPasteTextView` on `NSTextView`

**Files:**
- Modify: `ConduitMac/Chat/ComposerPasteTextView.swift`
- Test: `ConduitMacTests/ComposerPasteTextViewTests.swift`

**Interfaces:**
- Consumes: `PastedImage` (same file).
- Produces: `ComposerPasteTextView` (`NSViewRepresentable`), plus `ComposerTextView` (`NSTextView` subclass) with `static func pastedImages(from: NSPasteboard) -> [PastedImage]` and `func handleReturn(shift: Bool) -> Bool`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/ComposerPasteTextViewTests.swift`:

```swift
import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import ConduitMac

@MainActor
final class ComposerPasteTextViewTests: XCTestCase {
    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("conduit.composer.\(UUID())"))
    }

    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        return image.pngData()!
    }

    func testBitmapPasteBecomesPastedImage() {
        let pb = board()
        pb.clearContents()
        pb.setData(pngData(), forType: .png)
        let images = ComposerTextView.pastedImages(from: pb)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.typeIdentifier, UTType.png.identifier)
    }

    func testFileURLImagePasteBecomesPastedImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try pngData().write(to: url)
        let pb = board()
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        let images = ComposerTextView.pastedImages(from: pb)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.typeIdentifier, UTType.png.identifier)
    }

    func testPlainTextPasteIsNotAnImage() {
        let pb = board()
        pb.clearContents()
        pb.setString("hi", forType: .string)
        XCTAssertTrue(ComposerTextView.pastedImages(from: pb).isEmpty)
    }

    func testReturnSubmitsWhenAllowed() {
        let view = ComposerTextView()
        var submitted = false
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { submitted = true; return true }
        XCTAssertTrue(view.handleReturn(shift: false))
        XCTAssertTrue(submitted)
    }

    func testShiftReturnInsertsNewline() {
        let view = ComposerTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { XCTFail("must not submit"); return true }
        XCTAssertFalse(view.handleReturn(shift: true))
    }

    func testReturnDuringMarkedTextDoesNotSubmit() {
        let view = ComposerTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { XCTFail("must not submit during IME composition"); return true }
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.handleReturn(shift: false))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/ComposerPasteTextViewTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ComposerTextView' in scope`.

- [ ] **Step 3: Implement**

Replace the placeholder `ComposerPasteTextView` struct (keep `PastedImage` and the two static height properties) with:

```swift
struct ComposerPasteTextView: NSViewRepresentable {
    static var minimumHeight: CGFloat { max(36, ceil(bodyLineHeight) + 16) }
    static var maximumHeight: CGFloat { min(max(160, ceil(bodyLineHeight) * 4 + 16), 280) }
    private static var bodyLineHeight: CGFloat { NSFont.preferredFont(forTextStyle: .body).lineHeight }

    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let enabled: Bool
    let onPastedImage: (PastedImage) -> Void
    let onPastedImageError: (String) -> Void
    let editorIdentity: UUID
    var programmaticRevision: UInt64 = 0
    var programmaticCursorAtEnd = false
    var returnKeySends: Bool = false
    var canSubmitFromReturn: Bool = false
    var onSubmitFromReturn: (() -> Bool)? = nil
    var onUserEdit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scroll.documentView = textView
        context.coordinator.lastRevision = programmaticRevision
        configure(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        configure(textView)
        // Only an intentional programmatic replacement rewrites the editor.
        if programmaticRevision != context.coordinator.lastRevision {
            context.coordinator.lastRevision = programmaticRevision
            if textView.string != text, !textView.hasMarkedText() {
                textView.string = text
                if programmaticCursorAtEnd {
                    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                }
            }
        }
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
        context.coordinator.remeasure(textView)
    }

    private func configure(_ textView: ComposerTextView) {
        textView.isEditable = enabled
        textView.returnKeySends = returnKeySends
        textView.canSubmitFromReturn = canSubmitFromReturn
        textView.onSubmitFromReturn = onSubmitFromReturn
        textView.onPastedImages = { images in images.forEach(onPastedImage) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerPasteTextView
        var lastRevision: UInt64 = 0

        init(_ parent: ComposerPasteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onUserEdit?()
            remeasure(textView)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.isFocused = false }

        func remeasure(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let content = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
            let clamped = min(max(content, ComposerPasteTextView.minimumHeight), ComposerPasteTextView.maximumHeight)
            if abs(parent.measuredHeight - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.measuredHeight = clamped }
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var returnKeySends = false
    var canSubmitFromReturn = false
    var onSubmitFromReturn: (() -> Bool)?
    var onPastedImages: (([PastedImage]) -> Void)?

    static func pastedImages(from pasteboard: NSPasteboard) -> [PastedImage] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.compactMap { url -> PastedImage? in
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: url) else { return nil }
                return PastedImage(data: data, typeIdentifier: type.identifier)
            }
            if !images.isEmpty { return images }
        }
        if let data = pasteboard.data(forType: .png) {
            return [PastedImage(data: data, typeIdentifier: UTType.png.identifier)]
        }
        if let data = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            return [PastedImage(data: png, typeIdentifier: UTType.png.identifier)]
        }
        return []
    }

    /// True when Return was consumed as a submit.
    func handleReturn(shift: Bool) -> Bool {
        guard !shift, !hasMarkedText(), returnKeySends, canSubmitFromReturn else { return false }
        return onSubmitFromReturn?() ?? false
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, handleReturn(shift: event.modifierFlags.contains(.shift)) { return }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let images = Self.pastedImages(from: .general)
        if !images.isEmpty {
            onPastedImages?(images)
            return
        }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = Self.pastedImages(from: sender.draggingPasteboard)
        if !images.isEmpty {
            onPastedImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }
}
```

Add `import UniformTypeIdentifiers` at the top of the file.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/ComposerPasteTextViewTests 2>&1 | grep -E "Executed|SUCCEEDED|FAILED"`
Expected: `** TEST SUCCEEDED **`, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac ConduitMacTests
git commit -m "macOS: NSTextView composer with image paste, drop, Return/IME handling"
```

---

### Task 9: `NSScrollView` chat scroll surface

**Files:**
- Modify: `ConduitMac/Chat/ChatScrollSurfaceLocator.swift`
- Test: `ConduitMacTests/NSScrollViewChatSurfaceTests.swift`

**Interfaces:**
- Consumes: `ChatScrollSurface` protocol, `ChatScrollEngine` (`attach(_:)`, `detach(_:)`, `surfaceLayoutChanged()`, `surfaceScrolled()`, `userDragBegan()`, `userDragEnded()`).
- Produces: `ChatScrollSurfaceLocator: NSViewRepresentable`, `NSScrollViewChatSurface: ChatScrollSurface`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/NSScrollViewChatSurfaceTests.swift`:

```swift
import XCTest
import AppKit
@testable import ConduitMac

@MainActor
final class NSScrollViewChatSurfaceTests: XCTestCase {
    private func makeScroll(contentHeight: CGFloat, viewport: CGFloat) -> (NSScrollView, NSView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: viewport))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: contentHeight))
        scroll.documentView = document
        return (scroll, document)
    }

    func testGeometryReadsFromNSScrollView() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        XCTAssertEqual(surface.contentHeight, 2000)
        XCTAssertEqual(surface.viewportHeight, 400, accuracy: 1)
        XCTAssertEqual(surface.contentOffsetY, 0)
    }

    func testSetOffsetMovesClipView() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        surface.setContentOffsetY(1600, animated: false)
        XCTAssertEqual(surface.contentOffsetY, 1600, accuracy: 1)
        XCTAssertEqual(surface.distanceFromBottom, 0, accuracy: 1)
    }

    func testScrolledUpUserIsNotYankedToBottom() {
        let (scroll, document) = makeScroll(contentHeight: 2000, viewport: 400)
        let surface = NSScrollViewChatSurface(scrollView: scroll, locator: document, engine: nil)
        surface.setContentOffsetY(500, animated: false)
        document.setFrameSize(NSSize(width: 300, height: 2600))
        XCTAssertEqual(surface.contentOffsetY, 500, accuracy: 1)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/NSScrollViewChatSurfaceTests 2>&1 | grep error: | head -3`
Expected: `cannot find 'NSScrollViewChatSurface' in scope`.

- [ ] **Step 3: Implement**

Replace `ConduitMac/Chat/ChatScrollSurfaceLocator.swift`:

```swift
import AppKit
import SwiftUI

/// Mac twin of Conduit/Views/ChatScrollSurfaceLocator.swift. Finds the
/// NSScrollView SwiftUI renders the chat ScrollView with and adapts it to
/// ChatScrollEngine. If none is found, the engine stays detached and the
/// view falls back to ScrollViewProxy, as on iOS.
struct ChatScrollSurfaceLocator: NSViewRepresentable {
    let engine: ChatScrollEngine

    func makeNSView(context: Context) -> ChatScrollSurfaceLocatorView {
        ChatScrollSurfaceLocatorView(engine: engine)
    }

    func updateNSView(_ view: ChatScrollSurfaceLocatorView, context: Context) {
        view.engine = engine
    }

    static func dismantleNSView(_ view: ChatScrollSurfaceLocatorView, coordinator: ()) {
        view.disconnect()
    }
}

final class ChatScrollSurfaceLocatorView: NSView {
    weak var engine: ChatScrollEngine? {
        didSet {
            guard engine !== oldValue else { return }
            disconnect()
            connectIfNeeded()
        }
    }

    private(set) var surface: NSScrollViewChatSurface?

    init(engine: ChatScrollEngine) {
        self.engine = engine
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? disconnect() : connectIfNeeded()
    }

    override func layout() {
        super.layout()
        connectIfNeeded()
    }

    func disconnect() {
        guard let surface else { return }
        self.surface = nil
        surface.invalidate()
    }

    private func connectIfNeeded() {
        guard window != nil, let engine, let scrollView = enclosingScrollView else { return }
        if let surface, surface.scrollView === scrollView { return }
        disconnect()
        let surface = NSScrollViewChatSurface(scrollView: scrollView, locator: self, engine: engine)
        self.surface = surface
        engine.attach(surface)
    }
}

/// ChatScrollSurface backed by the transcript's NSScrollView. Offsets are in
/// the document view's coordinates; SwiftUI's document view is flipped, so
/// y grows downward as on iOS.
@MainActor
final class NSScrollViewChatSurface: NSObject, ChatScrollSurface {
    private(set) weak var scrollView: NSScrollView?
    private weak var locator: NSView?
    private weak var engine: ChatScrollEngine?
    private var observers: [NSObjectProtocol] = []
    private var liveScrolling = false

    init(scrollView: NSScrollView, locator: NSView, engine: ChatScrollEngine?) {
        self.scrollView = scrollView
        self.locator = locator
        self.engine = engine
        super.init()
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.surfaceScrolled() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.documentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.surfaceLayoutChanged() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.surfaceLayoutChanged() }
            },
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.liveScrolling = true
                    self?.engine?.userDragBegan()
                }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.liveScrolling = false
                    self?.engine?.userDragEnded()
                }
            },
        ]
    }

    func invalidate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine?.detach(self)
    }

    // MARK: - ChatScrollSurface

    var contentOffsetY: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }
    var contentHeight: CGFloat { scrollView?.documentView?.frame.height ?? 0 }
    var viewportHeight: CGFloat { scrollView?.contentView.bounds.height ?? 0 }
    var insetTop: CGFloat { scrollView?.contentInsets.top ?? 0 }
    var insetBottom: CGFloat { scrollView?.contentInsets.bottom ?? 0 }
    var isTracking: Bool { liveScrolling }
    var isDecelerating: Bool { false }

    var transcriptOriginY: CGFloat {
        guard let document = scrollView?.documentView, let locator else { return 0 }
        return locator.convert(CGPoint.zero, to: document).y
    }

    func setContentOffsetY(_ y: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                scrollView.contentView.animator().setBoundsOrigin(point)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
```

`ChatScrollSurface` is `@MainActor`, so the class is too. The notification observers hop to the main queue and use `MainActor.assumeIsolated`, matching upstream's `onMain` pattern.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/NSScrollViewChatSurfaceTests 2>&1 | grep -E "Executed|SUCCEEDED|FAILED"`
Expected: `** TEST SUCCEEDED **`, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac ConduitMacTests
git commit -m "macOS: NSScrollView-backed ChatScrollSurface"
```

---

### Task 10: App shell: root view, Settings, commands, OAuth browser twin

**Files:**
- Modify: `ConduitMac/App/ConduitMacApp.swift`
- Create: `ConduitMac/App/ConduitMacAppDelegate.swift`
- Create: `ConduitMac/App/ConduitCommands.swift`
- Modify: `ConduitMac/Views/SafariAuthenticationView.swift`
- Create: `ConduitMac/Resources/Assets.xcassets` (copy `AppIcon` from `Conduit/Resources/Assets.xcassets`; macOS sizes are generated in Step 5)
- Test: `ConduitMacTests/AppShellTests.swift`

**Interfaces:**
- Consumes:
  - `AppStateRuntimeRegistry.shared.appState`
  - `AppLanguageStore.shared` (`resolvedLocale`, `selection`)
  - `RootView`
  - `appState.themePreference.colorScheme`
  - `appState.appLanguageDidChange()`
  - `NativeOAuthPresentationTask` (`start(operation:onSuccess:onError:)`, `cancel()`)
  - `AttachmentStaging.sweepStaleFiles()`
- Produces: `ConduitMacApp`, `ConduitMacAppDelegate`, `ConduitCommands`, `MacDefaults.register()`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/AppShellTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class AppShellTests: XCTestCase {
    func testPersistentSidebarDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: "conduit.ipadPersistentSidebar")
        MacDefaults.register()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "conduit.ipadPersistentSidebar"))
    }

    func testClosingLastWindowDoesNotQuit() {
        XCTAssertFalse(ConduitMacAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testCancelStopsOperation() async {
        let task = NativeOAuthPresentationTask()
        var finished = false
        task.start(
            operation: {
                try await Task.sleep(for: .seconds(30))
                finished = true
                throw CancellationError()
            },
            onSuccess: { _ in XCTFail("no success after cancel") },
            onError: { _ in XCTFail("no error after cancel") }
        )
        task.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/AppShellTests 2>&1 | grep error: | head -3`
Expected: `cannot find 'MacDefaults' in scope`.

- [ ] **Step 3: Implement the shell**

`ConduitMac/App/ConduitMacAppDelegate.swift`:

```swift
import AppKit

enum MacDefaults {
    /// The persistent sidebar column is the natural Mac layout.
    static func register() {
        UserDefaults.standard.register(defaults: ["conduit.ipadPersistentSidebar": true])
    }
}

final class ConduitMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacDefaults.register()
        Task.detached(priority: .background) {
            AttachmentStaging.sweepStaleFiles()
        }
    }

    /// Closing the window keeps Conduit (and its dashboard socket) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open shows the main window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
```

`ConduitMac/App/ConduitCommands.swift`. These entry points were verified at `c13e234f`:
- `AppState.createNewSession(cwd:widgetLease:) async` (called from `SidebarView.swift:229`)
- `AppState.cancelCurrent() async` (the composer stop button, `ComposerBar.swift:991`)
- `@Published var showSidebar` (opens the sessions drawer)
- `@AppStorage("conduit.ipadPersistentSidebar")` in `RootView` (the persistent column)

```swift
import SwiftUI

struct ConduitCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage("conduit.ipadPersistentSidebar") private var persistentSidebar = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { Task { await appState.createNewSession() } }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Chat") {
            Button("Stop Response") { Task { await appState.cancelCurrent() } }
                .keyboardShortcut(".", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(persistentSidebar ? "Hide Sidebar" : "Show Sidebar") { persistentSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        TextEditingCommands()
    }
}
```

These spec items are deferred, with reasons. Record them in the ledger:
- **Switch Dashboard (Cmd-Shift-D):** no single `AppState` entry point. The saved-dashboards UI is reached through `RootView` state, so it remains reachable from the sidebar.
- **Find in Chat (Cmd-F):** each message is its own `NSTextView`, so a transcript-wide find needs its own design. `SelectableTextView` sets `usesFindBar = true` for per-message find in the meantime.
- **Push-to-Talk (Option-Space):** Plan 3.

`ConduitMac/App/ConduitMacApp.swift`:

```swift
import SwiftUI

@main
struct ConduitMacApp: App {
    @NSApplicationDelegateAdaptor(ConduitMacAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppStateRuntimeRegistry.shared.appState
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    init() {
        MacDefaults.register()
    }

    var body: some Scene {
        WindowGroup("Conduit", id: "conduit-primary") {
            RootView()
                .environmentObject(appState)
                .environment(\.locale, appLanguage.resolvedLocale)
                .onChange(of: appLanguage.selection) { _, _ in
                    appState.appLanguageDidChange()
                }
                .preferredColorScheme(appState.themePreference.colorScheme)
                .tint(.conduitAccent)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 780)
        .commands { ConduitCommands(appState: appState) }
    }
}
```

Compare with upstream `Conduit/ConduitApp.swift` lines 120-325 (`rootContent` modifiers: `openURL` handling, `onOpenURL`, scene-phase hooks). Port every modifier that does not touch `PushNotificationService` remote registration, widgets, CarPlay, or the Watch. Copy the ported block verbatim and mark it `// Ported from ConduitApp.swift; keep in sync`. Skipped modifiers go in the ledger.

Settings scene: none in Plan 1. Upstream `SettingsView` (`AuxiliaryViews.swift:465`) takes a `SettingsSnapshot` plus about 12 persistence closures wired up inside `RootView` (`RootView.swift:189`), so a standalone `Settings` scene would duplicate that wiring. Settings stay reachable from the sidebar, as on iPad. Add a ledger row: "Cmd-, Settings scene deferred: SettingsView needs RootView-owned closures."

- [ ] **Step 4: Implement the OAuth browser twin**

Replace `ConduitMac/Views/SafariAuthenticationView.swift`:

```swift
import AppKit
import SwiftUI

/// Mac twin of NativeOAuth.swift SafariAuthenticationView. Opens the
/// authorize URL in the default browser; upstream's loopback listener
/// (RFC 8252) receives the redirect, so no in-app browser is needed.
struct SafariAuthenticationView: View {
    let url: URL?
    let operation: @MainActor () async throws -> NativeOAuthLoginResult
    let onSuccess: @MainActor (NativeOAuthLoginResult) -> Void
    let onError: @MainActor (Error) -> Void
    let onCancel: () -> Void

    @State private var task = NativeOAuthPresentationTask()
    @State private var openedURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Continue signing in in your browser.")
                .font(.headline)
            if let url {
                Button("Open Browser Again") { NSWorkspace.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {
                task.cancel()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(minWidth: 380)
        .onAppear {
            task.start(operation: operation, onSuccess: onSuccess, onError: onError)
            openIfNeeded(url)
        }
        .onChange(of: url) { _, newURL in openIfNeeded(newURL) }
        .onDisappear { task.cancel() }
    }

    private func openIfNeeded(_ url: URL?) {
        guard let url, url != openedURL else { return }
        openedURL = url
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 5: App icon**

Run: `mkdir -p ConduitMac/Resources/Assets.xcassets && cp -R Conduit/Resources/Assets.xcassets/AppIcon.appiconset ConduitMac/Resources/Assets.xcassets/ && ls ConduitMac/Resources/Assets.xcassets/AppIcon.appiconset`

Edit `ConduitMac/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` so that it holds a single universal 1024 entry (`"idiom": "universal", "platform": "macos", "size": "1024x1024"`, `"filename"` = the existing 1024 PNG). Xcode 15+ generates the macOS sizes. Add `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` to the `ConduitMac` target settings.

Also copy any color sets that `Theme.swift` reads (for example `ConduitAccent`): `grep -n "Color(\"" Conduit/Theme.swift`. Copy each named `.colorset` from `Conduit/Resources/Assets.xcassets/`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Launch against a real dashboard**

Run: `open "$(xcodebuild -scheme ConduitMac -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Conduit.app"`
Expected: the login screen. Enter the Hermes dashboard URL, then log in with a password or OAuth. The session list appears in the left column.

- [ ] **Step 8: Commit**

```bash
git add ConduitMac ConduitMacTests project.yml docs/macos
git commit -m "macOS: app shell, commands, browser OAuth, app icon"
```

---

### Task 11: Foreground and background semantics, plus the smoke checklist

**Files:**
- Test: `ConduitMacTests/PhoneScenePresenceMacTests.swift`
- Create: `docs/macos/SMOKE_CHECKLIST.md`
- Modify: whichever upstream file the smoke run proves wrong (R4, ledger)

**Interfaces:**
- Consumes: `PhoneScenePresence.isInForeground` (Task 4), `AppState`'s scene-phase handling.

- [ ] **Step 1: Write the test**

`ConduitMacTests/PhoneScenePresenceMacTests.swift`:

```swift
import XCTest
import AppKit
@testable import ConduitMac

@MainActor
final class PhoneScenePresenceMacTests: XCTestCase {
    func testVisibleWindowCountsAsForeground() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.close() }
        XCTAssertTrue(PhoneScenePresence.isInForeground)
    }

    func testMiniaturizedOnlyWindowIsNotForeground() {
        NSApp.windows.forEach { $0.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.miniaturize(nil)
        defer { window.close() }
        let expectation = expectation(description: "miniaturized")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(PhoneScenePresence.isInForeground)
    }
}
```

- [ ] **Step 2: Run the test**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/PhoneScenePresenceMacTests 2>&1 | grep -E "Executed|SUCCEEDED|FAILED"`
Expected: `** TEST SUCCEEDED **`. If miniaturize animation timing makes the second test flaky in CI, keep it and raise the wait to 2 seconds. Do not delete it.

- [ ] **Step 3: Write the smoke checklist**

`docs/macos/SMOKE_CHECKLIST.md`:

```markdown
# macOS smoke checklist

Run against a real Hermes dashboard before every release build.

- [ ] Log in with password; session list appears in the left column
- [ ] Log in with OAuth: browser opens, approve, app signs in; Cancel returns to login
- [ ] Open a session; history renders; long reply scrolls; scroll up during streaming stays put
- [ ] Send a message; reply streams; code block, math, Mermaid block render
- [ ] Select text in a reply across a line; Cmd-C copies; Cmd-F finds
- [ ] Paste a screenshot (Cmd-Shift-Ctrl-4 then Cmd-V): attaches as image
- [ ] Copy a PNG in Finder, paste: attaches as image; drag a PDF onto composer: attaches
- [ ] Return sends; Shift-Return newline; Japanese IME Return confirms without sending
- [ ] Approve a tool call inline
- [ ] Switch model and reasoning effort
- [ ] Cmd-N new chat; Cmd-. stops a running response; Cmd-Ctrl-S toggles the sidebar column
- [ ] Close window mid-stream, wait 30 s, click Dock icon: reply completed
- [ ] Admin tabs: Capabilities toggle, Jobs list, Connectors, Logs, Kanban board load
- [ ] Bot Mode: bot list loads; open a Bot Chat
- [ ] Switch between two saved dashboards
```

- [ ] **Step 4: Run the checklist**

Work through the checklist on the dev Mac. For each failure, apply Task 5 Step 3 rules (R4 plus a ledger row). Add a regression test when the failing logic lives in Mac-only code.

The "close window mid-stream" item is the riskiest. If the reply stops because `AppState` treats `scenePhase == .background` as "disconnect", do NOT change that here; Plan 2 owns connection lifetime. Record the finding under `## Plan 2 inputs` at the bottom of `SMOKE_CHECKLIST.md`.

- [ ] **Step 5: Commit**

```bash
git add -A ConduitMac ConduitMacTests Conduit Shared docs/macos
git commit -m "macOS: scene presence tests, smoke checklist and fixes"
```

---

### Task 11b: Hover tooltips, pointer cursor, hover highlight

Added 2026-10-13 (spec addendum "Mac accessibility sweep"). Can run in parallel with 11c and 11d: it touches only new files, plus one line each in `ConduitMacAppDelegate.swift` and `ConduitCommands.swift`.

**Files:**
- Create: `ConduitMac/Accessibility/HoverTooltipPolicy.swift`
- Create: `ConduitMac/Accessibility/HoverAccessibilityEngine.swift`
- Create: `ConduitMac/Accessibility/HoverOverlayWindows.swift`
- Modify: `ConduitMac/App/ConduitMacAppDelegate.swift` (add `HoverAccessibilityEngine.install()` in `applicationDidFinishLaunching`)
- Modify: `ConduitMac/App/ConduitCommands.swift` (View-menu toggle)
- Test: `ConduitMacTests/HoverTooltipPolicyTests.swift`, `ConduitMacTests/HoverAccessibilityEngineTests.swift`

**Interfaces:**
- Produces:
  - `HoverElementSnapshot`
  - `HoverDecision`
  - `HoverTooltipPolicy.decide(_:highlightEnabled:) -> HoverDecision`
  - `HoverAccessibilityEngine.install()`
  - `HoverAccessibilityEngine.snapshot(at screenPoint: NSPoint, in window: NSWindow?) -> HoverElementSnapshot?`
  - `HoverAccessibilityEngine.highlightDefaultsKey = "conduit.mac.hoverHighlight"`

- [ ] **Step 1: Probe the real SwiftUI accessibility tree first**

Write a temporary test that hosts four SwiftUI button shapes in an on-screen `NSWindow` via `NSHostingView` and calls `HoverAccessibilityEngine.snapshot(at:in:)` at each button's centre. Dump `role`, `label`, `title` and `help`:

```swift
Button { } label: { Image(systemName: "xmark") }.accessibilityLabel("Close Settings")
Button("Connect") { }
Button { } label: { Label("Send", systemImage: "paperplane") }.labelStyle(.iconOnly)
Button { } label: { Image(systemName: "gear") }.help("Settings")
```

Record the observed attributes in the task report. Step 3's policy rules must match what AppKit actually reports. Adjust the rules, and the tests in Step 2, to these observations. Example: if an `.iconOnly` `Label` reports `title == "Send"` with no `label`, treat a title on an image-only button as tooltip text. Keep the probe as a permanent test (`testSwiftUIButtonShapesProduceExpectedDecisions`) that asserts the final decisions for all four.

- [ ] **Step 2: Write the failing policy tests**

`ConduitMacTests/HoverTooltipPolicyTests.swift`:

```swift
import XCTest
import AppKit
@testable import ConduitMac

final class HoverTooltipPolicyTests: XCTestCase {
    private func el(_ role: NSAccessibility.Role?, label: String? = nil, title: String? = nil,
                    help: String? = nil, enabled: Bool = true) -> HoverElementSnapshot {
        HoverElementSnapshot(role: role, label: label, title: title, help: help,
                             isEnabled: enabled, frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    }

    func testIconButtonShowsLabelPointerAndHighlight() {
        let d = HoverTooltipPolicy.decide(el(.button, label: "Close Settings"), highlightEnabled: true)
        XCTAssertEqual(d, HoverDecision(tooltip: "Close Settings", showsPointingHand: true, highlights: true))
    }

    func testHelpWinsOverLabel() {
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.button, label: "Gear", help: "Open settings"), highlightEnabled: false).tooltip, "Open settings")
    }

    func testVisibleTitleEqualToLabelHasNoTooltip() {
        XCTAssertNil(HoverTooltipPolicy.decide(el(.button, label: "Connect", title: "connect"), highlightEnabled: true).tooltip)
    }

    func testDisabledButtonGetsTooltipButNoPointer() {
        let d = HoverTooltipPolicy.decide(el(.button, label: "Send", enabled: false), highlightEnabled: true)
        XCTAssertEqual(d.tooltip, "Send")
        XCTAssertFalse(d.showsPointingHand)
        XCTAssertFalse(d.highlights)
    }

    func testLabelledImageGetsTooltipOnly() {
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.image, label: "Bot avatar"), highlightEnabled: true),
                       HoverDecision(tooltip: "Bot avatar", showsPointingHand: false, highlights: false))
    }

    func testTextAndGroupsGetNothing() {
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.staticText, label: "Hello"), highlightEnabled: true), .none)
        XCTAssertEqual(HoverTooltipPolicy.decide(el(.group, label: "Row"), highlightEnabled: true), .none)
        XCTAssertEqual(HoverTooltipPolicy.decide(el(nil), highlightEnabled: true), .none)
    }

    func testHighlightRespectsSetting() {
        XCTAssertFalse(HoverTooltipPolicy.decide(el(.button, label: "X"), highlightEnabled: false).highlights)
    }

    func testLongLabelIsTruncatedWithASCIIEllipsis() {
        let long = String(repeating: "a", count: 300)
        let tip = HoverTooltipPolicy.decide(el(.button, label: long), highlightEnabled: false).tooltip
        XCTAssertEqual(tip?.count, HoverTooltipPolicy.maxLength)
        XCTAssertTrue(tip?.hasSuffix("...") ?? false)
    }
}
```

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/HoverTooltipPolicyTests`
Expected: compile failure, `cannot find 'HoverElementSnapshot'`.

- [ ] **Step 3: Implement the policy**

`ConduitMac/Accessibility/HoverTooltipPolicy.swift`:

```swift
import AppKit

/// Accessibility facts about the element under the pointer.
struct HoverElementSnapshot: Equatable {
    var role: NSAccessibility.Role?
    var label: String?
    var title: String?
    var help: String?
    var isEnabled: Bool
    /// Screen coordinates (AppKit, bottom-left origin).
    var frame: CGRect
}

/// What the hover layer does for that element.
struct HoverDecision: Equatable {
    var tooltip: String?
    var showsPointingHand: Bool
    var highlights: Bool

    static let none = HoverDecision(tooltip: nil, showsPointingHand: false, highlights: false)
}

/// Mac-only tooltip rules. iOS has no hover, so upstream labels its icon
/// controls for VoiceOver only; on Mac the same label becomes the tooltip.
enum HoverTooltipPolicy {
    static let maxLength = 120

    static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .link, .popUpButton, .menuButton, .checkBox, .radioButton, .disclosureTriangle,
    ]

    static func decide(_ element: HoverElementSnapshot, highlightEnabled: Bool) -> HoverDecision {
        guard let role = element.role else { return .none }
        let interactive = interactiveRoles.contains(role)
        guard interactive || role == .image else { return .none }
        let pointer = interactive && element.isEnabled
        return HoverDecision(
            tooltip: tooltipText(element),
            showsPointingHand: pointer,
            highlights: pointer && highlightEnabled
        )
    }

    static func tooltipText(_ element: HoverElementSnapshot) -> String? {
        if let help = cleaned(element.help) { return truncated(help) }
        guard let label = cleaned(element.label) else { return nil }
        if let title = cleaned(element.title), title.caseInsensitiveCompare(label) == .orderedSame {
            return nil
        }
        return truncated(label)
    }

    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncated(_ text: String) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength - 3)) + "..."
    }
}
```

Adjust these rules to the Step 1 observations, and keep the tests in sync.

- [ ] **Step 4: Write the failing engine test**

`ConduitMacTests/HoverAccessibilityEngineTests.swift`:
- Host an `NSButton(image:target:action:)` (image only, `setAccessibilityLabel("Close Settings")`) in an on-screen `NSWindow` (`isReleasedWhenClosed = false`, `orderFront`).
- Compute the button's centre in screen coordinates with `window.convertPoint(toScreen:)`.
- Assert `HoverAccessibilityEngine.snapshot(at:in:)` returns role `.button` and label `"Close Settings"`.
- Add a second case for a point over empty window background: it returns `nil`, or a snapshot whose decision is `.none`.
- Add the Step 1 SwiftUI probe test.

- [ ] **Step 5: Implement the engine and overlays**

`ConduitMac/Accessibility/HoverAccessibilityEngine.swift`:

```swift
import AppKit

/// App-wide hover layer: tooltips from accessibility labels, a pointing
/// hand over controls, and an optional highlight. One local event monitor
/// serves every window, sheets included.
@MainActor
final class HoverAccessibilityEngine {
    static let shared = HoverAccessibilityEngine()
    static let highlightDefaultsKey = "conduit.mac.hoverHighlight"
    static let restDelay: TimeInterval = 0.6
    /// Elements larger than this are containers; never highlight them.
    static let maxHighlightSize = CGSize(width: 480, height: 160)

    private var monitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var restTimer: Timer?
    private let tooltip = TooltipWindow()
    private let highlight = HighlightWindow()

    static func install() { shared.start() }

    func start() {
        UserDefaults.standard.register(defaults: [Self.highlightDefaultsKey: true])
        guard monitor == nil else { return }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated { (note.object as? NSWindow)?.acceptsMouseMovedEvents = true }
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .mouseExited]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .mouseMoved, let window = event.window, window.isKeyWindow || window.isMainWindow else {
            dismissAll()
            return
        }
        tooltip.hide()
        restTimer?.invalidate()
        let point = NSEvent.mouseLocation
        let snapshot = Self.snapshot(at: point, in: window)
        let decision = snapshot.map {
            HoverTooltipPolicy.decide($0, highlightEnabled: UserDefaults.standard.bool(forKey: Self.highlightDefaultsKey))
        } ?? .none
        if decision.showsPointingHand { NSCursor.pointingHand.set() }
        if decision.highlights, let frame = snapshot?.frame,
           frame.width <= Self.maxHighlightSize.width, frame.height <= Self.maxHighlightSize.height {
            highlight.show(around: frame, over: window)
        } else {
            highlight.hide()
        }
        guard let text = decision.tooltip else { return }
        restTimer = Timer.scheduledTimer(withTimeInterval: Self.restDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tooltip.show(text, near: point) }
        }
    }

    private func dismissAll() {
        restTimer?.invalidate()
        tooltip.hide()
        highlight.hide()
    }

    /// Reads the accessibility element under `screenPoint`, climbing to the
    /// nearest interactive or labelled ancestor (SwiftUI often reports the
    /// inner image of a button).
    static func snapshot(at screenPoint: NSPoint, in window: NSWindow?) -> HoverElementSnapshot? {
        guard let content = window?.contentView else { return nil }
        var current = content.accessibilityHitTest(screenPoint) as? NSObject
        for _ in 0..<4 {
            guard let element = current else { return nil }
            let role = element.accessibilityRole()
            if let role, HoverTooltipPolicy.interactiveRoles.contains(role) || role == .image {
                return HoverElementSnapshot(
                    role: role,
                    label: element.accessibilityLabel(),
                    title: element.accessibilityTitle(),
                    help: element.accessibilityHelp(),
                    isEnabled: element.isAccessibilityEnabled(),
                    frame: element.accessibilityFrame()
                )
            }
            current = element.accessibilityParent() as? NSObject
        }
        return nil
    }
}
```

`ConduitMac/Accessibility/HoverOverlayWindows.swift`:
- `TooltipWindow` is a borderless, non-activating `NSPanel`:
  - `ignoresMouseEvents = true`, `level = .popUpMenu`, `hasShadow = true`.
  - Content: an `NSVisualEffectView` (`material = .toolTip`, `state = .active`, corner radius 4) wrapping `NSTextField(labelWithString:)` with font `NSFont.toolTipsFont(ofSize: 0)`, 6pt by 3pt padding, max width 320 with wrapping.
  - `show(_:near:)` sizes the panel to fit, places it at the pointer plus (12, -24), clamps it to the pointer's screen `visibleFrame`, then calls `orderFrontRegardless()`. `hide()` calls `orderOut(nil)`.
- `HighlightWindow` is a borderless, transparent `NSWindow` (`ignoresMouseEvents = true`, `isOpaque = false`, `backgroundColor = .clear`):
  - Its content view draws a rounded rect (radius 6) filled with `NSColor.controlAccentColor.withAlphaComponent(0.12)`.
  - `show(around:over:)` sets the frame to the element frame inset by -2, and attaches as a child of the parent window with `addChildWindow(_:ordered: .above)` if not already attached. `hide()` detaches and calls `orderOut`.
- No animations, which respects Reduce Motion by default.

`ConduitMacAppDelegate.applicationDidFinishLaunching`: add `HoverAccessibilityEngine.install()`.

`ConduitCommands`:
- Add `@AppStorage(HoverAccessibilityEngine.highlightDefaultsKey) private var hoverHighlight = true`.
- Inside `CommandGroup(after: .sidebar)`, add `Toggle("Highlight Controls on Hover", isOn: $hoverHighlight)`.

- [ ] **Step 6: Run the tests**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS'`
Expected: all pass. The new policy tests, the engine tests and the SwiftUI probe are green.

- [ ] **Step 7: Hover-only visual check (ruling R18: no clicks or keys)**
1. Launch the app.
2. Write a scratch Swift script in the workspace (never in the repo) that posts only a `CGEvent` `mouseMoved` to the centre of the login screen's "Need help connecting?" row or another labelled control, then waits 1s.
3. Take a screenshot with `screencapture -x`, Read it, and report whether a tooltip and highlight appear.

If posting events is denied, because the process lacks the Accessibility permission, mark it UNVERIFIED and move on. Never click. Delete screenshots that show the dashboard URL or username.

- [ ] **Step 8: Commit**

```bash
git add ConduitMac/Accessibility ConduitMac/App ConduitMacTests
git commit -m "macOS: hover tooltips, pointer cursor and highlight from accessibility labels"
```

---

### Task 11c: Esc dismisses sheets

Added 2026-10-13. Parallel-safe with 11b and 11d. It installs from `ConduitMacApp.init()`, not from the app delegate.

**Files:**
- Create: `ConduitMac/Accessibility/SheetEscape.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift` (call `SheetEscape.install()` in `init()`)
- Test: `ConduitMacTests/SheetEscapeTests.swift`

**Interfaces:**
- Produces:
  - `SheetEscape.install()`
  - `SheetEscape.handleEscape(in: NSWindow?) -> Bool`
  - `SheetEscape.isCloseLabel(_: String) -> Bool`
  - `SheetEscape.closeControl(in: Any?) -> NSObject?`

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/SheetEscapeTests.swift`:

```swift
import XCTest
import AppKit
@testable import ConduitMac

@MainActor
final class SheetEscapeTests: XCTestCase {
    private final class Target: NSObject { var pressed = false; @objc func press() { pressed = true } }

    func testCloseLabelMatching() {
        XCTAssertTrue(SheetEscape.isCloseLabel("Close Settings"))
        XCTAssertTrue(SheetEscape.isCloseLabel("Cancel"))
        XCTAssertTrue(SheetEscape.isCloseLabel("Done"))
        XCTAssertFalse(SheetEscape.isCloseLabel("Closet organizer"))
        XCTAssertFalse(SheetEscape.isCloseLabel("Delete"))
    }

    func testEscapeInSheetPressesCloseButton() {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let target = Target()
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: target, action: #selector(Target.press))
        close.setAccessibilityLabel("Close Settings")
        close.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        sheet.contentView?.addSubview(close)
        let presented = expectation(description: "sheet presented")
        parent.beginSheet(sheet) { _ in }
        DispatchQueue.main.async { presented.fulfill() }
        wait(for: [presented], timeout: 2)
        defer { parent.endSheet(sheet); parent.orderOut(nil) }

        XCTAssertTrue(SheetEscape.handleEscape(in: sheet))
        XCTAssertTrue(target.pressed)
    }

    func testEscapeOutsideSheetIsIgnored() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(SheetEscape.handleEscape(in: window))
        XCTAssertFalse(SheetEscape.handleEscape(in: nil))
    }
}
```

Add one more test: when the sheet's first responder is an `NSTextView` with marked text (`setMarkedText`), `handleEscape` returns false and nothing is pressed.

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/SheetEscapeTests`
Expected: compile failure, `cannot find 'SheetEscape'`.

- [ ] **Step 2: Implement**

`ConduitMac/Accessibility/SheetEscape.swift`:

```swift
import AppKit

/// Esc closes a sheet on Mac. Upstream's 60 sheets declare no
/// `.cancelAction`, so this presses the sheet's own close/cancel/done
/// control through accessibility and SwiftUI's dismiss path runs as if
/// the user had clicked it.
@MainActor
enum SheetEscape {
    private static var monitor: Any?
    static let escapeKeyCode: UInt16 = 53

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == escapeKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            return handleEscape(in: event.window) ? nil : event
        }
    }

    static func handleEscape(in window: NSWindow?) -> Bool {
        guard let window, window.sheetParent != nil else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        guard let control = closeControl(in: window.contentView) else { return false }
        return control.accessibilityPerformPress()
    }

    /// Breadth-first search for a button whose label starts with a
    /// close/cancel/done word. Bounded so a huge sheet cannot stall a key press.
    static func closeControl(in root: Any?) -> NSObject? {
        var queue: [NSObject] = (root as? NSObject).map { [$0] } ?? []
        var visited = 0
        while !queue.isEmpty, visited < 2_000 {
            let element = queue.removeFirst()
            visited += 1
            if element.accessibilityRole() == .button,
               let label = element.accessibilityLabel() ?? element.accessibilityTitle(),
               isCloseLabel(label) {
                return element
            }
            queue.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
        }
        return nil
    }

    static func isCloseLabel(_ label: String) -> Bool {
        let words = Set(["Close", "Cancel", "Done"].flatMap { [$0, AppLocalization.string($0)] })
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return words.contains { trimmed == $0 || trimmed.hasPrefix($0 + " ") }
    }
}
```

If `AppLocalization.string(_:)` has a different signature, check with `grep -n "static func string" Conduit/Services/AppLanguage.swift`, adapt the call, and note it.

`ConduitMacApp.init()`: add `SheetEscape.install()` after `MacDefaults.register()`.

- [ ] **Step 3: Run the tests**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS'`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add ConduitMac/Accessibility/SheetEscape.swift ConduitMac/App/ConduitMacApp.swift ConduitMacTests/SheetEscapeTests.swift
git commit -m "macOS: Esc dismisses sheets via their close control"
```

---

### Task 11d: Accessibility label audit

Added 2026-10-13. Parallel-safe with 11b and 11c. This is the only accessibility task that edits upstream views.

**Files:**
- Create: `ConduitMacTests/AccessibilityLabelAuditTests.swift`
- Create: `docs/macos/a11y-audit-allowlist.txt`
- Modify: upstream files under `Conduit/Views/` that the audit flags (adding `.accessibilityLabel` only)
- Modify: `docs/macos/PORTING_LEDGER.md`

- [ ] **Step 1: Write the audit test**

`ConduitMacTests/AccessibilityLabelAuditTests.swift`:
- Locate the repo root from `#filePath` (two directories up from the test file).
- Read every `.swift` file under `Conduit/Views/`.
- Flag a line containing `Image(systemName:` when both of these hold:
  - It sits inside a button label: one of the 4 preceding lines contains `Button(`, `Button {`, or `} label: {`.
  - None of the next 8 lines contains `.accessibilityLabel(`, `.accessibilityHidden(true)`, `Text(`, `Label(`, or `.help(`, and none of the 4 preceding lines contains `Label(` or `Text(`.
- Ignore any `file:line` listed in `docs/macos/a11y-audit-allowlist.txt` (one `path:line` or `path:symbol-name` per line, `#` comments allowed).
- Assert that the flagged list is empty. On failure, the message lists every flagged `path:line` with the line text.

Run it and record the RED list in the report.

- [ ] **Step 2: Triage every hit**

For each flagged site, read the code:
- **Real gap (an icon-only control with no spoken name):** add `.accessibilityLabel("…")` to the `Button`. Phrase it like nearby upstream labels, in English (e.g. `"Close \(title)"`, `"Send message"`). Put `// MAC: a11y` on the same line. This is a cross-platform improvement, so do not wrap it in `#if`.
- **False positive:** add it to the allowlist with a `#` reason. Typical false positives are labels set by a wrapping view, decorative images inside a labelled `Label`, or the heuristic window missing a label.

Do not hand-edit `Localizable.xcstrings`. New keys fall back to English in other locales. Note that in the ledger.

- [ ] **Step 3: Run the audit and the full suite**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS'`
Expected: all pass, and the audit list is empty.

Run: `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Ledger and commit**

Add one `PORTING_LEDGER.md` row: "a11y labels: N sites in M files, cross-platform `.accessibilityLabel`, tagged `// MAC: a11y`". Then:

```bash
git add ConduitMacTests/AccessibilityLabelAuditTests.swift docs/macos Conduit/Views
git commit -m "a11y: label icon-only buttons; audit test guards new gaps"
```

---

### Task 11e: Smoke-run fixes (login clipping, Mac icon, checklist accuracy)

Added 2026-10-13. Runs after 11b, 11c and 11d are merged, because it touches `LoginView.swift`, which 11d may also edit.

**Files:**
- Modify: `Conduit/Views/LoginView.swift` (one R4 gate)
- Create: `scripts/make-mac-icon.swift`
- Modify: `ConduitMac/Resources/Assets.xcassets/AppIcon.appiconset/*.png`
- Modify: `ConduitMacTests/PhoneScenePresenceMacTests.swift`
- Modify: `docs/macos/SMOKE_CHECKLIST.md`, `docs/macos/PORTING_LEDGER.md`

- [ ] **Step 1: Login clipping**

In `LoginView.swift`, find the `.onChange(of: focusedField)` handler that calls `proxy.scrollTo(..., anchor: .center)` (around lines 101-112 at `0f36195e`). Wrap only the `scrollTo` call in `#if os(iOS)` / `#endif // MAC: no soft keyboard on Mac; scrolling to focus clipped the header`, and add a ledger row. Rebuild, launch the app, and take a screenshot: the logo must be fully visible below the title bar. Ruling R18 applies: no clicks or keys, screenshot only. Delete any screenshot showing the dashboard URL or username after you check it.

- [ ] **Step 2: macOS icon**

`scripts/make-mac-icon.swift` takes `<input-1024.png> <output-dir>` and uses CoreGraphics to:
- Draw onto a 1024x1024 transparent canvas.
- Clip to a rounded rect of 824x824 centred (100pt margins) with corner radius 185 (Apple's macOS icon grid).
- Draw the source art scaled to 824x824 inside the clip.
- Add a soft drop shadow (y offset -10, blur 20, black at 30%) under the shape.
- Write `icon_1024.png`, then use `sips -z` for 16/32/64/128/256/512 into the asset set, reusing the file names already in `AppIcon.appiconset/Contents.json`.

Run it with `swift scripts/make-mac-icon.swift <upstream 1024 PNG path> ConduitMac/Resources/Assets.xcassets/AppIcon.appiconset`. Rebuild, then confirm `Conduit.app/Contents/Resources/AppIcon.icns` has transparent corners, for example with `sips -g hasAlpha`, and by rendering a size to PNG and reading it.

- [ ] **Step 3: Test and doc accuracy (Task 11 review minors)**
- `PhoneScenePresenceMacTests`: hide other windows in the positive test too, and restore the host windows afterwards. In the miniaturize test, assert `!NSApp.isHidden` and poll `window.isMiniaturized` (timeout 3s) as preconditions, replacing the fixed sleep.
- `SMOKE_CHECKLIST.md`:
  - Mark check (b) UNVERIFIED and note the predicate used.
  - Add an `## Open findings` list with file references and owners (11e for clipping and icon, user for the logged-in items).
  - Rewrite the incident note per the review: no auto-submit or auto-test path exists, agent clicks reached Connect and Test Connection, and at least 2 auth attempts reached the dashboard. Add the R18 rule.
  - Mark the clipping and icon items PASS once Steps 1-2 verify them.

- [ ] **Step 4: Run all tests and commit**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS'`, then the iOS build check.

```bash
git add Conduit/Views/LoginView.swift scripts/make-mac-icon.swift ConduitMac/Resources ConduitMacTests docs/macos
git commit -m "macOS: fix login header clipping, masked app icon, checklist accuracy"
```

---

### Task 12: Notarized release build

**Files:**
- Create: `scripts/mac-release.sh`
- Create: `scripts/mac-export-options.plist`
- Modify: `docs/macos/SMOKE_CHECKLIST.md` (add a second-Mac install line)

**Interfaces:**
- Consumes: scheme `ConduitMac`; env `CONDUIT_NOTARY_PROFILE`.
- Produces: `build/mac/Conduit-<version>.dmg`, notarized and stapled.

- [ ] **Step 1: User creates the notary profile (one time)**

The user runs this in their own terminal, because it prompts for an app-specific password:
`xcrun notarytool store-credentials conduit-notary --apple-id <apple-id-email> --team-id 58XKRG9VMA`
Expected: `Credentials saved to Keychain.`

- [ ] **Step 2: Write the export options**

`scripts/mac-export-options.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>58XKRG9VMA</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
```

- [ ] **Step 3: Write the release script**

`scripts/mac-release.sh`:

```bash
#!/usr/bin/env bash
# Build, sign, notarize, and staple Conduit for macOS as a DMG.
# Usage: CONDUIT_NOTARY_PROFILE=conduit-notary scripts/mac-release.sh
set -euo pipefail

: "${CONDUIT_NOTARY_PROFILE:?set CONDUIT_NOTARY_PROFILE to a notarytool keychain profile}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/mac"
ARCHIVE="$OUT/Conduit.xcarchive"
EXPORT="$OUT/export"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "::progress::1/6 Generating project" >&2
xcodegen generate

echo "::progress::2/6 Archiving" >&2
xcodebuild archive -scheme ConduitMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" | tail -3

echo "::progress::3/6 Exporting (Developer ID)" >&2
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/scripts/mac-export-options.plist" \
  -exportPath "$EXPORT" | tail -3

APP="$EXPORT/Conduit.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/Conduit-$VERSION.dmg"

echo "::progress::4/6 Notarizing app" >&2
ditto -c -k --keepParent "$APP" "$OUT/Conduit.zip"
xcrun notarytool submit "$OUT/Conduit.zip" --keychain-profile "$CONDUIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "::progress::5/6 Building DMG" >&2
hdiutil create -volname "Conduit" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "::progress::6/6 Notarizing DMG" >&2
xcrun notarytool submit "$DMG" --keychain-profile "$CONDUIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "$DMG"
```

Run: `chmod +x scripts/mac-release.sh`

- [ ] **Step 4: Run it**

Run: `CONDUIT_NOTARY_PROFILE=conduit-notary scripts/mac-release.sh`
Expected: the last two lines are `...: accepted` / `source=Notarized Developer ID` and the DMG path.

If notarization reports issues, fetch the log with `xcrun notarytool log <submission-id> --keychain-profile conduit-notary`. Typical causes:
- An unsigned nested binary: the `WebRTC.framework` or `ConduitUIKitCompat.framework` was not re-signed. Fix: in `project.yml`, set `embed: true, codeSign: true` on those dependencies.
- Hardened runtime missing on a framework. Fix: add `ENABLE_HARDENED_RUNTIME: YES` to that target.

- [ ] **Step 5: Install on a second Mac**

Copy the DMG to another Mac with AirDrop, open it, and drag `Conduit` to Applications. Launch it. Expected: no Gatekeeper warning, and the login screen appears. Add `- [ ] Fresh install from DMG on a second Mac: no Gatekeeper prompt` to `SMOKE_CHECKLIST.md`.

- [ ] **Step 6: Commit and push the branch**

```bash
echo "build/" >> .gitignore
git add scripts/mac-release.sh scripts/mac-export-options.plist docs/macos .gitignore
git commit -m "macOS: notarized DMG release script"
git push -u origin macos
```

---

### Task 13: Upstream-merge rehearsal

**Files:**
- Modify: `docs/macos/PORTING_LEDGER.md` (add the sync routine)

- [ ] **Step 1: Merge the latest upstream**

Run: `git fetch upstream && git merge upstream/main`
Expected: a clean merge, or conflicts only in files listed in `PORTING_LEDGER.md` or `project.yml`.

- [ ] **Step 2: Rebuild and test both platforms**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' 2>&1 | grep -E "SUCCEEDED|FAILED" && xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1`
Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

A new Mac compile error after the merge means upstream used an API the shims don't cover. Apply the Task 5 Step 3 rules.

- [ ] **Step 3: Document the routine**

Append to `docs/macos/PORTING_LEDGER.md`:

```markdown
## Sync routine

1. `git fetch upstream && git merge upstream/main` on `macos`
2. Resolve conflicts; every one should be at a `// MAC:` line, a ledger file, or `project.yml`
3. For each twin row above, diff the upstream source: `git diff ORIG_HEAD HEAD -- <upstream file>`; port relevant changes to the twin
4. `xcodegen generate`, then `xcodebuild test -scheme ConduitMac -destination 'platform=macOS'`
5. iOS build check: `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
6. Run `docs/macos/SMOKE_CHECKLIST.md`, then `scripts/mac-release.sh`
```

- [ ] **Step 4: Commit and push**

```bash
git add docs/macos/PORTING_LEDGER.md
git commit -m "macOS: document upstream sync routine"
git push
```
