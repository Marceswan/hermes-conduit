# Mac Desktop Widgets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Native and Conduit-chan launcher widgets on the Mac desktop and in Notification Center as a sandboxed WidgetKit extension embedded in Conduit.app, fed by the snapshot the app already publishes and opened through the existing `conduit://widget/v1/...` route.

**Architecture:** A new macOS app-extension target `ConduitMacWidgets` compiles the iOS widget sources (`ConduitWidgets/`, `Shared/Widgets/`, assets, `Localizable.xcstrings`) through `project.yml` paths; nothing is copied. The app and the extension share one team-prefixed app group (`58XKRG9VMA.com.meswan.hermes.mac.widgets`), selected by one gated constant in `Shared/Widgets/WidgetSnapshotStore.swift`; the Mac app registers the `conduit` URL scheme so a widget tap reaches the existing `routeWidgetLaunchURL`. A bundle verifier script runs from `mac-release.sh` (before notarization) and standalone against a signed Release archive.

**Tech Stack:** Swift 5.9 / SwiftUI / WidgetKit / AppIntents on macOS 14+, XCTest, xcodegen (`project.yml`), bash 3.2 + python3 for the verifier, codesign.

**Spec:** `docs/superpowers/specs/2026-10-16-mac-widgets-design.md` (draft; its open questions are resolved to the defaults listed under "Resolved Decisions").

## Global Constraints

- Mac only. Never run an iOS build or iOS tests (project scope). iOS behaviour is unchanged; the iOS `ConduitWidgets` target keeps its sources, bundle id `com.milim.relay.widgets` and group `group.com.milim.relay.widgets`.
- Deployment target macOS `14.0`. Families: `.systemMedium` only (both widgets, as on iOS); no accessory families exist on macOS and none are added.
- Extension target name `ConduitMacWidgets`, bundle id `com.meswan.hermes.mac.widgets` (child of `com.meswan.hermes.mac`), product `ConduitMacWidgets.appex` at `Conduit.app/Contents/PlugIns/`. Mac-only files live in `ConduitMacWidgets/` (Info.plist, entitlements; no Swift).
- Team `58XKRG9VMA`. Signing: manual, `Developer ID Application`, `PROVISIONING_PROFILE_SPECIFIER: ""`, hardened runtime, no provisioning profile on either bundle.
- App group on macOS: `58XKRG9VMA.com.meswan.hermes.mac.widgets` (team-prefixed; no `group.` prefix). The same string appears in exactly three places that must agree: `WidgetSnapshotStore.appGroup` (macOS branch), `ConduitMac/Resources/ConduitMac.entitlements`, `ConduitMacWidgets/ConduitMacWidgets.entitlements`.
- The extension is sandboxed (`com.apple.security.app-sandbox` true). The main app stays unsandboxed (no sandbox key in `ConduitMac.entitlements`).
- Sharing, not copying: `ConduitMacWidgets/` contains no `.swift` file; widget code is the iOS code.
- Upstream edits are exactly: `Shared/Widgets/WidgetSnapshotStore.swift` (one `#if os(macOS) // MAC:` region, `#else` keeps the original line, zero removed lines) and `ConduitWidgets/LauncherWidgets.swift` lines 76 and 138 (availability widened to `iOS 18.0, macOS 15.0, *`, tagged `// MAC:`; exactly 2 changed lines). One ledger row per edited file. Everything else is Mac-owned (`ConduitMac/`, `ConduitMacWidgets/`, `project.yml`, `scripts/`, `docs/`).
- Do not edit `AppState+Widgets.swift`, `AppState+WidgetLaunch.swift`, `WidgetLaunchCoordinator.swift` or any other `Conduit/` file.
- The widget never receives credentials, tickets or transcripts: the snapshot is display metadata and ids only (unchanged).
- Release scripts publish nothing in this plan: no tag, no `gh release`, no notarization submit, no push. Do not run `scripts/mac-ship.sh` without `--dry-run`.
- After adding or removing any file or target run `xcodegen generate`.
- Mac test command (one class): `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/<Class>' CODE_SIGNING_ALLOWED=NO`. Never run two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- Tests use injected stores and defaults (`widgetSnapshotStoreOverride`, `MacSharedBaseAppStateFixture`, `HostedTestSupport`); no test touches the real app group, the user's defaults, or the running Conduit. Do not quit, click or type into the user's running Conduit; do not copy a build over `/Applications/Conduit.app`.
- zsh: quote every glob and every path containing `*`, `[`, `?`. Stage explicit paths only; never `git add -A` or `git add .`.
- All text ASCII (no smart quotes, em dashes, ellipsis characters).
- Clean up as you go: `build/mac-verify` and other scratch are deleted when a task is done (the verifier's default). Check `df -h` first; prune if under about 20 GB.

## Resolved Decisions (spec open questions, spec defaults)

1. Families: medium only in v1; small is the first follow-up (not in this plan).
2. Group id: team-prefixed `58XKRG9VMA.com.meswan.hermes.mac.widgets`. Fallback (`group.` id plus Developer ID profiles) only if Task 5 shows the entitlement is rejected; then stop and report, do not improvise.
3. Register the `conduit` scheme on Mac for everything (the app already validates both hosts).
4. No draft-localization strip phase on the Mac extension (matches `ConduitMac`; `ConduitDraftLanguages` is empty).
5. D21 session windows must keep `.onOpenURL` on one window; recorded in D25 (Task 6).
6. Mac bundle id family `com.meswan.hermes.mac.*`, not the iOS ids.

## Review Focus

1. A widget tap while the app has no window, is hidden, or is quit: the URL must be consumed and held until the scene is ready, not dropped or turned into a second window. Test: Task 3 (pending request after receive; deferral) plus the manual matrix in Task 6.
2. The snapshot file is absent, unreadable, or from a different schema version (first launch, signed out, container missing, version skew between app and extension after a Sparkle update): the widget shows "Open Conduit" with the generic open link, never a crash or a stale conversation. Test: Task 3.
3. A malformed `conduit://widget/...` URL is consumed (no fall-through to session-link parsing) and a non-widget `conduit://` URL is not consumed. Test: Task 3.
4. The three app-group strings drift apart (constant, app entitlements, extension entitlements): the failure is silent (widget shows the placeholder forever). Test: Tasks 1 and 2 pin all three.
5. The extension is present in Debug but missing or unsigned in the Release archive (or its version differs from the app's): Sparkle/notarization problems appear only at ship time. Test: Task 2 (embedding, version equality) and Tasks 4 and 5 (signed archive check).

## File Map

- Modify `Shared/Widgets/WidgetSnapshotStore.swift:4`: macOS app-group constant (Task 1).
- Modify `ConduitMac/Resources/ConduitMac.entitlements`: add application-groups (Task 1).
- Modify `ConduitMac/Resources/Info.plist`: add `CFBundleURLTypes` for `conduit` (Task 1).
- Modify `ConduitMac/App/ConduitMacApp.swift:72-75`: call `publishWidgetLanguage()` (Task 1).
- Create `ConduitMacTests/MacWidgetAppSideTests.swift` (Task 1).
- Modify `project.yml`: new `ConduitMacWidgets` target; `ConduitMac` embeds it (Task 2).
- Create `ConduitMacWidgets/Info.plist`, `ConduitMacWidgets/ConduitMacWidgets.entitlements` (Task 2).
- Modify `ConduitWidgets/LauncherWidgets.swift:76,138`: availability widen (Task 2).
- Create `ConduitMacTests/MacWidgetsEmbeddingTests.swift` (Task 2).
- Create `ConduitMacTests/MacWidgetLaunchRoutingTests.swift`, `ConduitMacTests/MacWidgetSnapshotHandoffTests.swift` (Task 3).
- Create `scripts/lib/mac-bundle.sh`, `scripts/mac-verify-bundle.sh`, `scripts/tests/test-mac-verify-bundle.sh`; modify `scripts/mac-release.sh` (Task 4).
- No file changes in Task 5 (verification run).
- Modify `docs/macos/DECISIONS.md`, `docs/macos/PORTING_LEDGER.md`, `docs/macos/RELEASING.md`, `docs/macos/SMOKE_CHECKLIST.md`, `docs/macos/PLAN2_INPUTS.md` (Task 6).

---

### Task 1: Mac app side (group, entitlement, URL scheme, language publish)

**Files:**
- Modify: `Shared/Widgets/WidgetSnapshotStore.swift:4`
- Modify: `ConduitMac/Resources/ConduitMac.entitlements`
- Modify: `ConduitMac/Resources/Info.plist`
- Modify: `ConduitMac/App/ConduitMacApp.swift:72-75`
- Test: `ConduitMacTests/MacWidgetAppSideTests.swift`

**Interfaces:**
- Consumes: `WidgetSnapshotStore` (`init(directory:fileManager:writeObserver:)`, `appGroup`, `read()`, `write(_:)`), `WidgetSnapshot(appLanguage:currentWorkspaceID:workspaces:)`, `AppState.publishWidgetLanguage()`, `AppState.widgetSnapshotReloadOverride`, `MacSharedBaseAppStateFixture` (`ConduitMacTests/MacSharedBaseTestSupport.swift`: `appState`, `scratch`, `tearDown()`), `AppLanguageStore.shared.selection.rawValue`.
- Produces: on macOS `WidgetSnapshotStore.appGroup == "58XKRG9VMA.com.meswan.hermes.mac.widgets"`; `ConduitMac.entitlements` declares that group; `Info.plist` registers scheme `conduit`; the language `onChange` republishes the widget language. Task 2 reuses the group string.

- [ ] **Step 1: Write the failing test**

Create `ConduitMacTests/MacWidgetAppSideTests.swift`:

```swift
import XCTest
@testable import ConduitMac

/// The Mac app's half of the widget hand-off (D25): which app group the
/// snapshot goes to, that the app declares it, that the `conduit` scheme is
/// registered so a widget tap reaches the app, and that a language change
/// republishes the widget copy. The extension half is MacWidgetsEmbeddingTests.
@MainActor
final class MacWidgetAppSideTests: XCTestCase {
    static let teamGroup = "58XKRG9VMA.com.meswan.hermes.mac.widgets"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(value as? [String: Any])
    }

    func testMacAppGroupIsTeamPrefixedNotGroupPrefixed() {
        XCTAssertEqual(WidgetSnapshotStore.appGroup, Self.teamGroup)
        XCTAssertFalse(WidgetSnapshotStore.appGroup.hasPrefix("group."))
    }

    func testAppEntitlementsDeclareTheGroupAndStayUnsandboxed() throws {
        let entitlements = try plist("ConduitMac/Resources/ConduitMac.entitlements")
        XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String], [Self.teamGroup])
        XCTAssertNil(entitlements["com.apple.security.app-sandbox"], "only the widget extension is sandboxed")
        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true, "existing entitlements are kept")
        XCTAssertEqual(entitlements["com.apple.security.device.camera"] as? Bool, true)
    }

    func testInfoPlistRegistersTheConduitScheme() throws {
        let info = try plist("ConduitMac/Resources/Info.plist")
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, ["conduit"])
    }

    func testLanguageChangeHandlerRepublishesTheWidgetLanguage() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("ConduitMac/App/ConduitMacApp.swift"), encoding: .utf8)
        let range = try XCTUnwrap(source.range(of: ".onChange(of: appLanguage.selection)"))
        let handler = source[range.upperBound...].prefix(400)
        XCTAssertTrue(handler.contains("appState.publishWidgetLanguage()"))
    }

    func testPublishWidgetLanguageRewritesTheStoredLanguageAndReloadsOnce() throws {
        let fixture = MacSharedBaseAppStateFixture()
        defer { fixture.tearDown() }
        let directory = fixture.scratch.appendingPathComponent("widgets", isDirectory: true)
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(WidgetSnapshot(appLanguage: "zz-stale", currentWorkspaceID: nil, workspaces: []))
        var reloads = 0
        fixture.appState.widgetSnapshotReloadOverride = { reloads += 1 }

        fixture.appState.publishWidgetLanguage()

        XCTAssertEqual(store.read()?.appLanguage, AppLanguageStore.shared.selection.rawValue)
        XCTAssertEqual(reloads, 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacWidgetAppSideTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL. `testMacAppGroupIsTeamPrefixedNotGroupPrefixed` (value is `group.com.milim.relay.widgets`), `testAppEntitlementsDeclareTheGroupAndStayUnsandboxed` (no groups key), `testInfoPlistRegistersTheConduitScheme` (`CFBundleURLTypes` missing) and `testLanguageChangeHandlerRepublishesTheWidgetLanguage` fail. `testPublishWidgetLanguageRewritesTheStoredLanguageAndReloadsOnce` already passes (the AppState method exists); that is expected.

- [ ] **Step 3: Gate the app-group constant (the only `Shared/` edit)**

In `Shared/Widgets/WidgetSnapshotStore.swift`, replace line 4 with the following (the original iOS line stays byte-identical inside `#else`; nothing is removed):

```swift
    #if os(macOS) // MAC: a macOS app group is `<TeamID>.<name>`; `group.` ids need a provisioning profile and prompt on macOS 15 (docs/macos/DECISIONS.md D25)
    static let appGroup = "58XKRG9VMA.com.meswan.hermes.mac.widgets"
    #else
    static let appGroup = "group.com.milim.relay.widgets"
    #endif // MAC:
```

- [ ] **Step 4: Declare the group in the Mac app entitlements**

Replace the body of `ConduitMac/Resources/ConduitMac.entitlements` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.camera</key><true/>
    <!-- Widgets (D25): team-prefixed macOS app group shared with ConduitMacWidgets; needs no provisioning profile. The app stays unsandboxed. -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>58XKRG9VMA.com.meswan.hermes.mac.widgets</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 5: Register the `conduit` scheme**

In `ConduitMac/Resources/Info.plist`, insert directly after the `LSFileQuarantineEnabled` line:

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLName</key><string>$(PRODUCT_BUNDLE_IDENTIFIER).chat-link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>conduit</string>
            </array>
        </dict>
    </array>
```

- [ ] **Step 6: Republish the widget language on a language change**

In `ConduitMac/App/ConduitMacApp.swift`, change the `.onChange(of: appLanguage.selection)` block (lines 72-75) to:

```swift
            .onChange(of: appLanguage.selection) { _, _ in
                appState.appLanguageDidChange()
                appState.publishWidgetLanguage()   // D25: ported from ConduitApp.swift
                MacNotificationRuntime.shared.languageDidChange()
            }
```

- [ ] **Step 7: Run the test to verify it passes**

Run the same command as Step 2.
Expected: PASS (5 tests).

- [ ] **Step 8: Check the upstream diff is only the gate**

Run: `git diff -U0 -- Shared Conduit | grep '^-[^-]' | wc -l`
Expected: `0` (no removed upstream lines). `git diff --stat -- Shared Conduit` lists only `Shared/Widgets/WidgetSnapshotStore.swift`.

- [ ] **Step 9: Commit**

```bash
git add 'Shared/Widgets/WidgetSnapshotStore.swift' 'ConduitMac/Resources/ConduitMac.entitlements' 'ConduitMac/Resources/Info.plist' 'ConduitMac/App/ConduitMacApp.swift' 'ConduitMacTests/MacWidgetAppSideTests.swift'
git commit -m "feat(mac): widget app group, conduit URL scheme and language republish (D25)"
```

---

### Task 2: The `ConduitMacWidgets` extension target, embedded in ConduitMac

**Files:**
- Modify: `project.yml` (new target after `ConduitMac`; one dependency line in `ConduitMac`)
- Create: `ConduitMacWidgets/Info.plist`
- Create: `ConduitMacWidgets/ConduitMacWidgets.entitlements`
- Modify: `ConduitWidgets/LauncherWidgets.swift:76,138`
- Test: `ConduitMacTests/MacWidgetsEmbeddingTests.swift`

**Interfaces:**
- Consumes: Task 1's group string `58XKRG9VMA.com.meswan.hermes.mac.widgets` and `WidgetSnapshotStore.appGroup`; the iOS widget sources (`NativeLauncherWidget`, `CharacterLauncherWidget`, `ConduitWidgets: WidgetBundle`, `LauncherTimelineProvider`, `LauncherWidgetConfigurationIntent`).
- Produces: `Conduit.app/Contents/PlugIns/ConduitMacWidgets.appex` (bundle id `com.meswan.hermes.mac.widgets`, extension point `com.apple.widgetkit-extension`, version equal to the app's) that Tasks 3 to 5 verify.

- [ ] **Step 1: Write the failing test**

Create `ConduitMacTests/MacWidgetsEmbeddingTests.swift`. The test host is the real Conduit.app, so `Bundle.main` is the built app:

```swift
import XCTest
@testable import ConduitMac

/// D25: the Mac widget extension is embedded, versioned like the app, shares
/// the app's group, is sandboxed, and is built from the iOS sources.
final class MacWidgetsEmbeddingTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appexURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("ConduitMacWidgets.appex")
    }

    func testHostAppEmbedsTheWidgetExtension() throws {
        let url = try XCTUnwrap(appexURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.path) is missing")
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.bundleIdentifier, "com.meswan.hermes.mac.widgets")
        let ext = try XCTUnwrap(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.widgetkit-extension")
    }

    func testExtensionIdIsAChildOfTheAppIdAndVersionsMatch() throws {
        let bundle = try XCTUnwrap(appexURL.flatMap { Bundle(url: $0) })
        let appID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertTrue(try XCTUnwrap(bundle.bundleIdentifier).hasPrefix(appID + "."))
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            let app = try XCTUnwrap(Bundle.main.infoDictionary?[key] as? String, key)
            let ext = try XCTUnwrap(bundle.infoDictionary?[key] as? String, key)
            XCTAssertEqual(ext, app, "\(key) must match the app (Sparkle replaces both together)")
        }
    }

    func testExtensionEntitlementsAreSandboxedAndShareTheAppGroup() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("ConduitMacWidgets/ConduitMacWidgets.entitlements"))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        let entitlements = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String], [WidgetSnapshotStore.appGroup])
    }

    func testExtensionIsBuiltFromSharedIOSSourcesNotCopies() throws {
        let folder = repoRoot.appendingPathComponent("ConduitMacWidgets")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["ConduitMacWidgets.entitlements", "Info.plist"])
        let project = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let block = try XCTUnwrap(project.range(of: "  ConduitMacWidgets:\n"))
        let target = String(project[block.lowerBound...].prefix(1800))
        XCTAssertTrue(target.contains("- path: ConduitWidgets\n"))
        XCTAssertTrue(target.contains("- path: Shared/Widgets\n"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacWidgetsEmbeddingTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL (all four: no appex in the host app, no `ConduitMacWidgets/` folder).

- [ ] **Step 3: Create the extension's Info.plist**

Create `ConduitMacWidgets/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>Conduit Widgets</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 4: Create the extension's entitlements**

Create `ConduitMacWidgets/ConduitMacWidgets.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>58XKRG9VMA.com.meswan.hermes.mac.widgets</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 5: Widen the two iOS availability checks**

`widgetAccentedRenderingMode` is macOS 15; a bare `iOS 18.0, *` check fails to compile for macOS 14. Run:

```bash
sed -i '' \
  -e '76s|if #available(iOS 18.0, \*), renderingMode == .accented {|if #available(iOS 18.0, macOS 15.0, *), renderingMode == .accented { // MAC: widgetAccentedRenderingMode is macOS 15 (R4-widen)|' \
  -e '138s|if #available(iOS 18.0, \*), renderingMode == .accented {|if #available(iOS 18.0, macOS 15.0, *), renderingMode == .accented { // MAC: widgetAccentedRenderingMode is macOS 15 (R4-widen)|' \
  'ConduitWidgets/LauncherWidgets.swift'
git diff -U0 -- 'ConduitWidgets/LauncherWidgets.swift' | grep -c '^[-+][^-+]'
```

Expected: `4` (two removed lines, two added lines), the added lines being the ones at 76 and 138 with `macOS 15.0`.

- [ ] **Step 6: Add the target to project.yml and embed it**

In `project.yml`, add this dependency to the `ConduitMac` target (directly after `- package: Sparkle`, the last entry of its `dependencies`):

```yaml
      # Widgets (D25): embedded as Conduit.app/Contents/PlugIns/ConduitMacWidgets.appex.
      - target: ConduitMacWidgets
        embed: true
        codeSign: true
```

Then add the new target between `ConduitMac` and `ConduitMacTests`:

```yaml
  # Mac desktop widgets (D25, docs/superpowers/specs/2026-10-16-mac-widgets-design.md).
  # The iOS widget sources, shared by path (nothing is copied). Sandboxed, as a
  # macOS widget extension must be; the team-prefixed group needs no profile.
  ConduitMacWidgets:
    type: app-extension
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: ConduitWidgets
        excludes:
          - "Info.plist"
          - "ConduitWidgets.entitlements"
          - "Resources/**"
      - path: ConduitWidgets/Resources/Assets.xcassets
        buildPhase: resources
      - path: Shared/Widgets
      - path: Conduit/Localizable.xcstrings
        buildPhase: resources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.meswan.hermes.mac.widgets
        PRODUCT_NAME: ConduitMacWidgets
        GENERATE_INFOPLIST_FILE: NO
        INFOPLIST_FILE: ConduitMacWidgets/Info.plist
        CODE_SIGN_ENTITLEMENTS: ConduitMacWidgets/ConduitMacWidgets.entitlements
        # Keep equal to ConduitMac; scripts/mac-release.sh overrides both for every target.
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        DEVELOPMENT_TEAM: 58XKRG9VMA
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
        PROVISIONING_PROFILE_SPECIFIER: ""
        ENABLE_HARDENED_RUNTIME: YES
        APPLICATION_EXTENSION_API_ONLY: YES
        SKIP_INSTALL: YES
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacWidgetsEmbeddingTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (4 tests). If the build fails inside `ConduitMacWidgets`, the likely causes are an iOS-only API in `ConduitWidgets/` (fix with the smallest R4/R4-widen edit, tagged `// MAC:`, and add it to the Task 6 ledger row) or an asset-catalog idiom error (the imagesets are universal).

- [ ] **Step 8: Confirm the app still builds and the earlier class still passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacWidgetAppSideTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (5 tests).

- [ ] **Step 9: Commit**

```bash
git add 'project.yml' 'ConduitMacWidgets/Info.plist' 'ConduitMacWidgets/ConduitMacWidgets.entitlements' 'ConduitWidgets/LauncherWidgets.swift' 'ConduitMacTests/MacWidgetsEmbeddingTests.swift'
git commit -m "feat(mac): ConduitMacWidgets extension target sharing the iOS widget sources (D25)"
```

---

### Task 3: Launch routing and snapshot hand-off tests (pin existing behaviour on Mac)

**Files:**
- Test: `ConduitMacTests/MacWidgetLaunchRoutingTests.swift`
- Test: `ConduitMacTests/MacWidgetSnapshotHandoffTests.swift`

**Interfaces:**
- Consumes: `AppState.routeWidgetLaunchURL(_:) -> Bool`, `AppState.widgetLaunchCoordinator` (`hasPendingRequest`, `supersede()`), `WidgetLaunchLink(action:workspace:reference:)` / `init?(url:)` / `.url` / `.action`, `MacOpenURLPolicy.decision(for:routeWidgetLaunch:openAppLink:)` (`ConduitMac/App/ConduitMacApp.swift:19`), `MacSharedBaseAppStateFixture`, `WidgetSnapshotPublisher(store:reload:)` (`@MainActor`; `publish(_:current:language:)`), `WidgetSelection.resolve(snapshot:workspace:conversation:)` returning `WidgetEntryModel` (`titleCopy`, `title`, `resumeLink`, `newChatLink`, `talkLink`), `WidgetSnapshotStore`.
- Produces: no production code. These are the regression net for Review Focus 1 to 3.

- [ ] **Step 1: Write the routing tests**

Create `ConduitMacTests/MacWidgetLaunchRoutingTests.swift`:

```swift
import XCTest
@testable import ConduitMac

/// A widget tap reaches the Mac app as a `conduit://widget/v1/...` URL (D25).
/// These use a real AppState with no connection, so the scene is not ready and
/// the coordinator holds the request; that deferral is the behaviour pinned.
@MainActor
final class MacWidgetLaunchRoutingTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!
    private var appState: AppState { fixture.appState }

    override func setUp() {
        super.setUp()
        fixture = MacSharedBaseAppStateFixture()
    }

    override func tearDown() {
        appState.widgetLaunchCoordinator.supersede()
        fixture.tearDown()
        fixture = nil
        super.tearDown()
    }

    private let workspace = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, profile: "default")

    private var reference: WidgetConversationReference {
        WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil, sessionID: "s1", isUnverified: false)
    }

    func testEveryLinkTheExtensionCanEmitIsConsumedAndHeldUntilReady() throws {
        let links: [WidgetLaunchLink?] = [
            WidgetLaunchLink(action: .open, workspace: nil, reference: nil),
            WidgetLaunchLink(action: .open, workspace: workspace, reference: nil),
            WidgetLaunchLink(action: .resume, workspace: workspace, reference: reference),
            WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil),
            WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil),
        ]
        XCTAssertEqual(links.compactMap { $0 }.count, 5)
        for link in links.compactMap({ $0 }) {
            XCTAssertTrue(appState.routeWidgetLaunchURL(link.url), "\(link.url) was not consumed")
            XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest, "\(link.url) was dropped")
            appState.widgetLaunchCoordinator.supersede()
            XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest)
        }
    }

    func testMalformedWidgetUrlIsConsumedWithoutARequest() throws {
        let bad = [
            "conduit://widget/v1/bogus",
            "conduit://widget/v1/newChat",                      // needs a workspace
            "conduit://widget/v2/open",
            "conduit://widget/v1/open?dashboard=not-a-uuid&profile=p",
            "conduit://widget/v1/open?extra=1",
        ]
        for string in bad {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertTrue(appState.routeWidgetLaunchURL(url), "\(string) must be consumed so it cannot reach session-link parsing")
            XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest, "\(string) must not start a launch")
        }
    }

    func testOtherConduitUrlsAreNotConsumed() throws {
        for string in ["conduit://session/abc", "conduit://settings/voice", "https://example.com/widget"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(appState.routeWidgetLaunchURL(url), string)
        }
        XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest)
    }

    func testPolicyHandlesAWidgetUrlBeforeAppLinkParsing() throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let decision = MacOpenURLPolicy.decision(
            for: link.url,
            routeWidgetLaunch: { self.appState.routeWidgetLaunchURL($0) },
            openAppLink: { _ in XCTFail("a widget URL must not become an app link") }
        )
        XCTAssertEqual(decision, .handled)
        XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest)
    }

    func testANewTapSupersedesAnOlderOne() throws {
        let first = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let second = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        XCTAssertTrue(appState.routeWidgetLaunchURL(first.url))
        XCTAssertTrue(appState.routeWidgetLaunchURL(second.url))
        XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest)
        appState.widgetLaunchCoordinator.supersede()
        XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest)
    }
}
```

- [ ] **Step 2: Write the hand-off tests**

Create `ConduitMacTests/MacWidgetSnapshotHandoffTests.swift`. Two `WidgetSnapshotStore` values on one directory model the app (writer) and the extension (reader):

```swift
import XCTest
@testable import ConduitMac

/// The app publishes, the extension reads (D25). Two stores on one directory
/// stand in for the two processes sharing the app group container.
@MainActor
final class MacWidgetSnapshotHandoffTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWidgetHandoff.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let workspace = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, profile: "default")

    private func reference(_ id: String) -> WidgetConversationReference {
        WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil, sessionID: id, isUnverified: false)
    }

    private func workspaceSnapshot() -> WidgetWorkspaceSnapshot {
        let last = reference("s1")
        return WidgetWorkspaceSnapshot(
            id: workspace,
            dashboardLabel: "Home",
            profileLabel: "Default",
            lastConversation: last,
            choices: [WidgetConversationChoice(reference: last, title: "Weekly sync", isPinned: false, recency: 5)],
            recency: 5
        )
    }

    func testExtensionSideReadsWhatTheAppPublishedAndBuildsTheRightLinks() throws {
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(store: WidgetSnapshotStore(directory: directory), reload: { reloads += 1 })
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        XCTAssertEqual(reloads, 1)

        let extensionStore = WidgetSnapshotStore(directory: directory)
        let model = WidgetSelection.resolve(snapshot: extensionStore.read(), workspace: nil, conversation: nil)

        XCTAssertEqual(model.title, "Weekly sync")
        XCTAssertEqual(model.dashboardLabel, "Home")
        XCTAssertEqual(model.profileLabel, "Default")
        XCTAssertEqual(model.resumeLink.action, .resume)
        XCTAssertEqual(model.resumeLink.reference, reference("s1"))
        XCTAssertEqual(model.newChatLink?.action, .newChat)
        XCTAssertEqual(model.talkLink?.action, .talk)
        for link in [model.resumeLink, model.newChatLink, model.talkLink].compactMap({ $0 }) {
            XCTAssertEqual(WidgetLaunchLink(url: link.url), link, "the URL a widget Link opens must parse back to the same launch")
        }
    }

    func testRepublishingUnchangedStateDoesNotReloadTheWidgets() throws {
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(store: WidgetSnapshotStore(directory: directory), reload: { reloads += 1 })
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        XCTAssertEqual(reloads, 1)
    }

    func testNoSnapshotYieldsOpenConduitWithTheGenericOpenLink() {
        let store = WidgetSnapshotStore(directory: directory)
        XCTAssertNil(store.read())
        let model = WidgetSelection.resolve(snapshot: store.read(), workspace: nil, conversation: nil)
        XCTAssertEqual(model.titleCopy, .openConduit)
        XCTAssertEqual(model.resumeLink.action, .open)
        XCTAssertNil(model.resumeLink.workspace)
        XCTAssertNil(model.newChatLink)
        XCTAssertNil(model.talkLink)
    }

    func testUnknownSchemaOrCorruptFileYieldsTheSamePlaceholder() throws {
        let url = directory.appendingPathComponent(WidgetSnapshotStore.filename)
        for body in ["{\"schemaVersion\":99,\"appLanguage\":\"en\",\"workspaces\":[]}", "not json", ""] {
            try Data(body.utf8).write(to: url)
            let store = WidgetSnapshotStore(directory: directory)
            XCTAssertNil(store.read(), body)
            let model = WidgetSelection.resolve(snapshot: store.read(), workspace: nil, conversation: nil)
            XCTAssertEqual(model.titleCopy, .openConduit, body)
        }
    }

    func testStaleConversationShowsRefreshInsteadOfAnotherChat() throws {
        // The configured conversation is no longer in the snapshot.
        let publisher = WidgetSnapshotPublisher(store: WidgetSnapshotStore(directory: directory), reload: {})
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        let model = WidgetSelection.resolve(
            snapshot: WidgetSnapshotStore(directory: directory).read(),
            workspace: workspace,
            conversation: reference("gone"),
            conversationWorkspace: workspace
        )
        XCTAssertEqual(model.titleCopy, .openConduitToRefresh)
    }
}
```

- [ ] **Step 3: Run both classes**

Run:
`xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacWidgetLaunchRoutingTests' -only-testing:'ConduitMacTests/MacWidgetSnapshotHandoffTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (5 + 5 tests). These characterize behaviour that already exists on Mac, so they pass on first run. If a malformed-URL case in `testMalformedWidgetUrlIsConsumedWithoutARequest` is accepted by `WidgetLaunchLink(url:)` (for example `?extra=1`), read `Shared/Widgets/WidgetLaunchLink.swift:47-50` and correct the test URL, not the parser. If `WidgetLaunchLink` is not `Equatable` on `reference` in the form used, use the property comparisons the compiler accepts.

- [ ] **Step 4: Mutation check (prove the net catches a regression)**

Temporarily change `return true` to `return false` at `Conduit/Services/AppState+WidgetLaunch.swift:11`, rerun the command from Step 3, and expect `testMalformedWidgetUrlIsConsumedWithoutARequest` to FAIL. Restore the file: `git checkout -- 'Conduit/Services/AppState+WidgetLaunch.swift'` and confirm `git diff --stat -- Conduit` is empty.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMacTests/MacWidgetLaunchRoutingTests.swift' 'ConduitMacTests/MacWidgetSnapshotHandoffTests.swift'
git commit -m "test(mac): widget launch routing and snapshot hand-off (D25)"
```

---

### Task 4: Bundle verifier and release-script integration

**Files:**
- Create: `scripts/lib/mac-bundle.sh`
- Create: `scripts/mac-verify-bundle.sh`
- Create: `scripts/tests/test-mac-verify-bundle.sh`
- Modify: `scripts/mac-release.sh` (after the `DMG=` line; after `stapler staple "$APP"`)

**Interfaces:**
- Consumes: `codesign`, python3 (`plistlib`), the layout `Conduit.app/Contents/PlugIns/ConduitMacWidgets.appex`, the constants `TEAM=58XKRG9VMA`, `GROUP=58XKRG9VMA.com.meswan.hermes.mac.widgets`, `APPEX_ID=com.meswan.hermes.mac.widgets`.
- Produces: `mac_plist_value FILE KEY`, `mac_plist_has_line FILE KEY LINE`, `mac_url_schemes FILE`, `mac_extension_point FILE`, `mac_cs_field TEXT FIELD`, `mac_cs_has_runtime TEXT`, `mac_starts_with STRING PREFIX` (all in `scripts/lib/mac-bundle.sh`); `scripts/mac-verify-bundle.sh --app <Conduit.app> [--require-timestamp]` and `scripts/mac-verify-bundle.sh --archive [--keep]` (exit 0 when every check is `ok:`). Task 5 runs `--archive`.

- [ ] **Step 1: Write the failing helper tests**

Create `scripts/tests/test-mac-verify-bundle.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/lib/mac-bundle.sh. Run: bash scripts/tests/test-mac-verify-bundle.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/mac-bundle.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
eq() { if [ "$1" != "$2" ]; then echo "FAIL: $3: expected '$2', got '$1'"; FAILS=$((FAILS + 1)); fi; }
expect_ok() { local msg="$1"; shift; if ! "$@" >/dev/null 2>&1; then echo "FAIL: $msg"; FAILS=$((FAILS + 1)); fi; }
expect_fail() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $msg"; FAILS=$((FAILS + 1)); fi; }

GROUP="58XKRG9VMA.com.meswan.hermes.mac.widgets"

cat > "$TMP/ext.ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array><string>58XKRG9VMA.com.meswan.hermes.mac.widgets</string></array>
</dict></plist>
EOF
cat > "$TMP/app.ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.camera</key><true/>
<key>com.apple.security.application-groups</key><array><string>group.com.milim.relay.widgets</string></array>
</dict></plist>
EOF
cat > "$TMP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.1.4</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>conduit</string></array></dict></array>
<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict></plist>
EOF
printf 'not a plist' > "$TMP/broken.ent"

eq "$(mac_plist_value "$TMP/ext.ent" com.apple.security.app-sandbox)" "true" "sandbox true"
eq "$(mac_plist_value "$TMP/app.ent" com.apple.security.app-sandbox)" "" "app has no sandbox key"
eq "$(mac_plist_value "$TMP/broken.ent" com.apple.security.app-sandbox)" "" "broken plist reads as empty, no traceback"
eq "$(mac_plist_value "$TMP/Info.plist" CFBundleShortVersionString)" "0.1.4" "string value"
expect_ok   "extension has the team group" mac_plist_has_line "$TMP/ext.ent" com.apple.security.application-groups "$GROUP"
expect_fail "app fixture has the iOS group, not the team group" mac_plist_has_line "$TMP/app.ent" com.apple.security.application-groups "$GROUP"
expect_fail "missing file is not a match" mac_plist_has_line "$TMP/nope.ent" com.apple.security.application-groups "$GROUP"
eq "$(mac_url_schemes "$TMP/Info.plist")" "conduit" "url schemes"
eq "$(mac_extension_point "$TMP/Info.plist")" "com.apple.widgetkit-extension" "extension point"
eq "$(mac_extension_point "$TMP/ext.ent")" "" "no NSExtension"

SAMPLE=$'Executable=/x/ConduitMacWidgets\nIdentifier=com.meswan.hermes.mac.widgets\nCodeDirectory v=20500 size=640 flags=0x10000(runtime) hashes=10+7 location=embedded\nAuthority=Developer ID Application: Marc Swan (58XKRG9VMA)\nAuthority=Developer ID Certification Authority\nTimestamp=Oct 16, 2026 at 10:00:00\nTeamIdentifier=58XKRG9VMA'
eq "$(mac_cs_field "$SAMPLE" TeamIdentifier)" "58XKRG9VMA" "team field"
eq "$(mac_cs_field "$SAMPLE" Authority)" "Developer ID Application: Marc Swan (58XKRG9VMA)" "first authority is the leaf"
eq "$(mac_cs_field "$SAMPLE" Timestamp)" "Oct 16, 2026 at 10:00:00" "timestamp field"
expect_ok   "runtime flag" mac_cs_has_runtime "$SAMPLE"
expect_fail "no runtime flag" mac_cs_has_runtime $'CodeDirectory v=20400 size=640 flags=0x0(none) hashes=10+7'
expect_fail "unsigned sample has no team" test -n "$(mac_cs_field $'Signature=adhoc\nTeamIdentifier=not set' TeamIdentifier | grep -E '^[A-Z0-9]{10}$' || true)"
expect_ok   "starts_with" mac_starts_with "Developer ID Application: X" "Developer ID Application:"
expect_fail "starts_with no" mac_starts_with "Apple Development: X" "Developer ID Application:"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS failure(s)"; exit 1; fi
echo "mac-bundle: all passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/tests/test-mac-verify-bundle.sh`
Expected: FAIL immediately with `scripts/lib/mac-bundle.sh: No such file or directory`.

- [ ] **Step 3: Implement the helpers**

Create `scripts/lib/mac-bundle.sh`:

```bash
# Helpers for scripts/mac-verify-bundle.sh (D25). bash 3.2; python3 for plists.

# mac_plist_value FILE KEY: the value, one line per array item, true/false for
# booleans; nothing when the key, the file or the plist is missing or invalid.
mac_plist_value() {
  python3 -I - "$1" "$2" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        data = plistlib.load(handle)
    value = data.get(sys.argv[2])
except Exception:
    sys.exit(0)
if value is None:
    sys.exit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    for item in value:
        print(item)
else:
    print(value)
PY
}

# mac_plist_has_line FILE KEY LINE: success when LINE is one of the printed lines.
mac_plist_has_line() {
  mac_plist_value "$1" "$2" | grep -Fxq -- "$3"
}

# mac_url_schemes FILE: every scheme in CFBundleURLTypes, one per line.
mac_url_schemes() {
  python3 -I - "$1" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        data = plistlib.load(handle)
    for entry in data.get("CFBundleURLTypes", []):
        for scheme in entry.get("CFBundleURLSchemes", []):
            print(scheme)
except Exception:
    sys.exit(0)
PY
}

# mac_extension_point FILE: NSExtension.NSExtensionPointIdentifier, or nothing.
mac_extension_point() {
  python3 -I - "$1" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        data = plistlib.load(handle)
    print(data.get("NSExtension", {}).get("NSExtensionPointIdentifier", ""))
except Exception:
    sys.exit(0)
PY
}

# mac_cs_field TEXT FIELD: first "FIELD=value" line of `codesign -dvv` output.
mac_cs_field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# mac_cs_has_runtime TEXT: the hardened-runtime flag is set.
mac_cs_has_runtime() {
  printf '%s\n' "$1" | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime'
}

# mac_starts_with STRING PREFIX
mac_starts_with() {
  [[ "$1" == "$2"* ]]
}
```

- [ ] **Step 4: Run the helper tests to verify they pass**

Run: `bash scripts/tests/test-mac-verify-bundle.sh`
Expected: `mac-bundle: all passed`.

- [ ] **Step 5: Write the verifier**

Create `scripts/mac-verify-bundle.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# Verify that a built Conduit.app embeds and correctly signs the widget extension (D25).
# Usage: scripts/mac-verify-bundle.sh --app <Conduit.app> [--require-timestamp]
#        scripts/mac-verify-bundle.sh --archive [--keep]
# --archive builds a signed Release archive under build/mac-verify and verifies the app
# inside it (deleted afterwards unless --keep). It never exports, notarizes, tags or
# publishes anything. Exit 0 only when every check prints "ok:".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/mac-bundle.sh"

TEAM="58XKRG9VMA"
GROUP="$TEAM.com.meswan.hermes.mac.widgets"
APPEX_NAME="ConduitMacWidgets.appex"
APPEX_ID="com.meswan.hermes.mac.widgets"
EXTENSION_POINT="com.apple.widgetkit-extension"

MODE=""
APP=""
REQUIRE_TS=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) MODE=app; APP="${2:?--app needs a path}"; shift ;;
    --archive) MODE=archive ;;
    --require-timestamp) REQUIRE_TS=1 ;;
    --keep) KEEP=1 ;;
    *) echo "usage: scripts/mac-verify-bundle.sh --app <Conduit.app> [--require-timestamp] | --archive [--keep]" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "usage: scripts/mac-verify-bundle.sh --app <Conduit.app> | --archive" >&2; exit 2; }

FAILS=0
check() { # check "description" command args...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok:   $desc" >&2; else echo "FAIL: $desc" >&2; FAILS=$((FAILS + 1)); fi
}

verify_app() {
  local app="$1" appex="$1/Contents/PlugIns/$APPEX_NAME" work
  work="$(mktemp -d)"
  check "app bundle exists" test -d "$app"
  check "codesign --verify --deep --strict (app)" codesign --verify --deep --strict --verbose=2 "$app"
  check "Sparkle.framework is embedded and signed" codesign --verify --strict "$app/Contents/Frameworks/Sparkle.framework"
  check "extension embedded at Contents/PlugIns/$APPEX_NAME" test -d "$appex"
  if [ -d "$appex" ]; then
    check "codesign --verify --strict (extension)" codesign --verify --strict --verbose=2 "$appex"
    local ext_info app_info
    ext_info="$(codesign -dvv "$appex" 2>&1 || true)"
    app_info="$(codesign -dvv "$app" 2>&1 || true)"
    check "extension TeamIdentifier is $TEAM" test "$(mac_cs_field "$ext_info" TeamIdentifier)" = "$TEAM"
    check "extension signed by a Developer ID Application certificate" mac_starts_with "$(mac_cs_field "$ext_info" Authority)" "Developer ID Application:"
    check "extension has the hardened runtime flag" mac_cs_has_runtime "$ext_info"
    check "app TeamIdentifier is $TEAM" test "$(mac_cs_field "$app_info" TeamIdentifier)" = "$TEAM"
    if [ "$REQUIRE_TS" = 1 ]; then
      check "extension has a secure timestamp" test -n "$(mac_cs_field "$ext_info" Timestamp)"
      check "app has a secure timestamp" test -n "$(mac_cs_field "$app_info" Timestamp)"
    fi

    codesign -d --entitlements :- "$appex" >"$work/ext.ent" 2>/dev/null || true
    codesign -d --entitlements :- "$app" >"$work/app.ent" 2>/dev/null || true
    check "extension is sandboxed" test "$(mac_plist_value "$work/ext.ent" com.apple.security.app-sandbox)" = "true"
    check "extension has the team app group $GROUP" mac_plist_has_line "$work/ext.ent" com.apple.security.application-groups "$GROUP"
    check "app has the team app group $GROUP" mac_plist_has_line "$work/app.ent" com.apple.security.application-groups "$GROUP"
    check "app is not sandboxed" test -z "$(mac_plist_value "$work/app.ent" com.apple.security.app-sandbox)"

    check "extension bundle id is $APPEX_ID" test "$(mac_plist_value "$appex/Contents/Info.plist" CFBundleIdentifier)" = "$APPEX_ID"
    check "extension point is $EXTENSION_POINT" test "$(mac_extension_point "$appex/Contents/Info.plist")" = "$EXTENSION_POINT"
    check "extension CFBundleShortVersionString equals the app's" test "$(mac_plist_value "$appex/Contents/Info.plist" CFBundleShortVersionString)" = "$(mac_plist_value "$app/Contents/Info.plist" CFBundleShortVersionString)"
    check "extension CFBundleVersion equals the app's" test "$(mac_plist_value "$appex/Contents/Info.plist" CFBundleVersion)" = "$(mac_plist_value "$app/Contents/Info.plist" CFBundleVersion)"
  fi
  check "app registers the conduit URL scheme" test "$(mac_url_schemes "$app/Contents/Info.plist")" = "conduit"
  rm -rf "$work"
}

if [ "$MODE" = archive ]; then
  OUT="$ROOT/build/mac-verify"
  rm -rf "$OUT"; mkdir -p "$OUT"
  if [ "$KEEP" != 1 ]; then trap 'rm -rf "$OUT"' EXIT; fi
  echo "::progress::1/3 Generating project" >&2
  xcodegen generate 2>&1 | tail -3
  echo "::progress::2/3 Archiving (Release, signed; nothing is exported or published)" >&2
  xcodebuild archive -scheme ConduitMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/Conduit.xcarchive" 2>&1 | tee "$OUT/archive.log" | tail -3
  APP="$OUT/Conduit.xcarchive/Products/Applications/Conduit.app"
  echo "::progress::3/3 Verifying $APP" >&2
fi

verify_app "$APP"
if [ "$FAILS" -ne 0 ]; then echo "mac-verify-bundle: $FAILS check(s) failed for $APP" >&2; exit 1; fi
echo "mac-verify-bundle: all checks passed for $APP" >&2
```

Run: `chmod +x scripts/mac-verify-bundle.sh && bash -n scripts/mac-verify-bundle.sh && echo syntax-ok`
Expected: `syntax-ok`.

- [ ] **Step 6: Verify against a deliberately wrong bundle (the verifier must fail loudly)**

Run:
```bash
mkdir -p build/mac-verify-selftest/Fake.app/Contents && printf '<plist version="1.0"><dict/></plist>' > build/mac-verify-selftest/Fake.app/Contents/Info.plist
scripts/mac-verify-bundle.sh --app build/mac-verify-selftest/Fake.app; echo "exit=$?"
rm -rf build/mac-verify-selftest
```
Expected: lines beginning `FAIL:` (at least `codesign --verify --deep --strict (app)` and `extension embedded at Contents/PlugIns/ConduitMacWidgets.appex`), then `mac-verify-bundle: N check(s) failed`, `exit=1`.

- [ ] **Step 7: Wire the verifier into the release script**

In `scripts/mac-release.sh`, directly after the line `DMG="$OUT/Conduit-$VERSION.dmg"` (line 36) add:

```bash

# D25: the exported app must embed and sign the widget extension before notarization is spent on it.
scripts/mac-verify-bundle.sh --app "$APP" --require-timestamp
```

and directly after `xcrun stapler staple "$APP"` (line 41) add:

```bash
spctl --assess --type execute -vv "$APP"
```

Run: `bash -n scripts/mac-release.sh && echo syntax-ok && git diff -U0 -- scripts/mac-release.sh | grep -c '^+[^+]'`
Expected: `syntax-ok` and `3` (one comment line, the verifier call, the `spctl` line). `git diff -- scripts/mac-ship.sh` must be empty: ship needs no change because it only calls `mac-release.sh`.

- [ ] **Step 8: Commit**

```bash
git add 'scripts/lib/mac-bundle.sh' 'scripts/mac-verify-bundle.sh' 'scripts/tests/test-mac-verify-bundle.sh' 'scripts/mac-release.sh'
git commit -m "feat(mac): bundle verifier for the widget extension, run before notarization (D25)"
```

---

### Task 5: Verify a signed Release archive embeds and signs the extension (publishes nothing)

**Files:** none changed (verification run). If a defect is found, fix it in the file that owns it (`project.yml`, an entitlements file, or the verifier) in a separate commit.

**Interfaces:**
- Consumes: `scripts/mac-verify-bundle.sh --archive` (Task 4), the Developer ID Application certificate for team `58XKRG9VMA` in the login keychain, the target from Task 2.
- Produces: evidence recorded in D25 (Task 6): the archive's verifier output, and the codesign output for the appex.

- [ ] **Step 1: Preconditions**

Run: `df -h . | tail -1 && security find-identity -v -p codesigning | grep 'Developer ID Application' | head -3`
Expected: at least 20 GB free and one `Developer ID Application: Marc Swan (58XKRG9VMA)` identity. If the identity is missing, stop and report; do not switch to ad-hoc signing (it would not prove the release path).

- [ ] **Step 2: Build and verify the signed Release archive**

Run (several minutes; archive only, no export, no notarization, no upload):
`scripts/mac-verify-bundle.sh --archive --keep`
Expected: `::progress::` lines, then a line `ok:` for every check and `mac-verify-bundle: all checks passed for .../build/mac-verify/Conduit.xcarchive/Products/Applications/Conduit.app`; exit 0.

- [ ] **Step 3: Run the literal checks the release will rely on**

Run:
```bash
APP=build/mac-verify/Conduit.xcarchive/Products/Applications/Conduit.app
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP/Contents/PlugIns/ConduitMacWidgets.appex" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|CodeDirectory|Timestamp)'
codesign -d --entitlements :- "$APP/Contents/PlugIns/ConduitMacWidgets.appex" 2>/dev/null | grep -A3 -E 'app-sandbox|application-groups'
ls "$APP/Contents/PlugIns"
```
Expected: `valid on disk` and `satisfies its Designated Requirement` for the app; the appex shows `Identifier=com.meswan.hermes.mac.widgets`, `TeamIdentifier=58XKRG9VMA`, `Authority=Developer ID Application: ...`, `flags=0x10000(runtime)`; entitlements show the sandbox and the team group; `PlugIns` lists `ConduitMacWidgets.appex`. (The archive may lack a secure `Timestamp`; the exported app is checked for one by `mac-release.sh`.)

- [ ] **Step 4: Decide**

- All green: proceed.
- `xcodebuild archive` fails with a provisioning/entitlement error naming `com.apple.security.application-groups`, or `codesign`/`spctl` rejects the appex, or the verifier reports the group missing: STOP. Record the exact message. This is the case where the team-prefixed group is not accepted without a profile; the fallback is a `group.` id with Developer ID provisioning profiles for both bundles (Resolved Decision 2). Do not change the group id or signing without the owner's decision.
- Any other FAIL line: fix the owning file, re-run Step 2, and commit the fix separately (`git add <file>` explicit path).

- [ ] **Step 5: Confirm the release script wiring without publishing**

Run: `bash -n scripts/mac-release.sh && bash -n scripts/mac-ship.sh && grep -n 'mac-verify-bundle' scripts/mac-release.sh`
Expected: no syntax errors and one hit. Do NOT run `scripts/mac-release.sh` (it notarizes) or `scripts/mac-ship.sh` without `--dry-run`. Optional once the branch is clean and pushed: `scripts/mac-ship.sh --dry-run` still passes its preconditions and prints the plan (publishes nothing).

- [ ] **Step 6: Clean up**

Run: `rm -rf build/mac-verify && git status --short`
Expected: no untracked build output (`build/` is git-ignored) and no unintended changes.

---

### Task 6: Docs, ledger, smoke checklist

**Files:**
- Modify: `docs/macos/DECISIONS.md` (new D25 after the last decision)
- Modify: `docs/macos/PORTING_LEDGER.md` (rows at lines 41 and 43; three new rows)
- Modify: `docs/macos/RELEASING.md`
- Modify: `docs/macos/SMOKE_CHECKLIST.md`
- Modify: `docs/macos/PLAN2_INPUTS.md:10`

**Interfaces:**
- Consumes: the results of Tasks 1 to 5.
- Produces: the written record future syncs and releases rely on.

- [ ] **Step 1: DECISIONS.md**

Append after the last decision (D20 at the time of writing; place D25 in numeric order if D21 to D24 have landed):

```
## D25: Mac desktop widgets (2026-10-16)
Spec: docs/superpowers/specs/2026-10-16-mac-widgets-design.md. Plan: docs/superpowers/plans/2026-10-16-mac-widgets.md. The iOS Native and Conduit-chan launcher widgets run on the Mac desktop and in Notification Center as `ConduitMacWidgets`, a sandboxed WidgetKit app extension embedded at Conduit.app/Contents/PlugIns/ConduitMacWidgets.appex (bundle id com.meswan.hermes.mac.widgets, macOS 14, family systemMedium only, both widgets; macOS has no accessory families). The extension compiles the iOS sources by path (ConduitWidgets/, Shared/Widgets/, its asset catalog, Conduit/Localizable.xcstrings); ConduitMacWidgets/ holds only Info.plist and entitlements. Data: the app's existing snapshot publisher writes launcher-v1.json into the shared app group and reloads the two widget kinds; no AppState change.

App group: `58XKRG9VMA.com.meswan.hermes.mac.widgets`, team-prefixed. Evidence (Apple DTS and macOS 15 release notes as quoted in Developer Forums threads 758375, 763826, 758478; the Apple "Configuring app groups" page was not fetchable when this was written, confirm there): on macOS app groups are not allow-listed by a provisioning profile and the macOS-style id is `<TeamID>.<name>`; a `group.` id is accepted only when a provisioning profile authorizes it; macOS 15 shows "would like to access data from other apps" unless the id is team-prefixed or profile-authorized or the app is Mac App Store; a widget extension with a `group.` id and no profile exited at launch. Conduit is a notarized Developer ID app with no provisioning profile, so the team-prefixed form is the one that works without profiles. `WidgetSnapshotStore.appGroup` is gated `#if os(macOS)` (iOS keeps `group.com.milim.relay.widgets`). The constant, ConduitMac.entitlements and ConduitMacWidgets.entitlements must agree; MacWidgetAppSideTests and MacWidgetsEmbeddingTests pin all three.

Sandbox: the extension is sandboxed (required on macOS); the app stays unsandboxed and declares the group only. Taps: SwiftUI Link opens conduit://widget/v1/<action>; the Mac Info.plist now registers the `conduit` scheme (it did not, PLAN2_INPUTS), so .onOpenURL and routeWidgetLaunchURL receive it unchanged. This also makes conduit://session links from other apps reach the app (code already present). D21 session windows must keep `.onOpenURL` on one window so a tap is routed once.

Release: scripts/mac-verify-bundle.sh runs codesign --verify --deep --strict and checks the appex is embedded, signed by team 58XKRG9VMA with the hardened runtime, sandboxed, in the group, versioned like the app. mac-release.sh runs it on the exported app (with --require-timestamp) before notarization and adds spctl --assess on the stapled app; mac-ship.sh is unchanged. `scripts/mac-verify-bundle.sh --archive` checks a signed Release archive and publishes nothing. Sparkle is unchanged; the first update that adds the extension simply adds PlugIns/ConduitMacWidgets.appex. Fallback if a profile-less team-prefixed group is ever rejected: a `group.` id with Developer ID provisioning profiles for both bundles and `provisioningProfiles` in scripts/mac-export-options.plist.

Upstream edits: Shared/Widgets/WidgetSnapshotStore.swift (1 `#if os(macOS)` gate), ConduitWidgets/LauncherWidgets.swift (2 availability widenings, macOS 15 for widgetAccentedRenderingMode). Not verified until the release gate: desktop behaviour on a quarantined, notarized install; macOS 14 versus 15 tint rendering. Out of scope: small and large families, live status, Home metrics widget (D24), interactive widgets.
```

Then append one sentence to that D25 paragraph, before "Not verified until", stating the actual Task 5 result: the date, the macOS version, that `scripts/mac-verify-bundle.sh --archive` passed every check, and the appex `codesign -dvv` Identifier, TeamIdentifier and flags lines you saw. Write what you observed; if Task 5 stopped on the fallback case, do not write this decision up as accepted, report instead.

- [ ] **Step 2: PORTING_LEDGER.md**

Change the two skipped rows (lines 41 and 43) to:

```
| ConduitApp.swift modifier: `appState.publishWidgetLanguage()` in language `onChange` | ported | widgets (D25) | ConduitMac/App/ConduitMacApp.swift `rootContent` language `onChange` calls it |
```
```
| ConduitApp.swift modifier: `.modifier(WidgetLaunchUITestFixture.modifier(...))` (DEBUG) | skipped | iOS XCUITest launch fixture (ConduitUITests); Mac covers the same routes with MacWidgetLaunchRoutingTests (D25) | none |
```

Append three rows to the table (after the last table row, before "## Sync routine"):

```
| Shared/Widgets/WidgetSnapshotStore.swift | R4 | `appGroup`: a macOS app group is `<TeamID>.<name>`; `group.` ids need a provisioning profile and prompt on macOS 15 (D25) | `#if os(macOS)` returns `58XKRG9VMA.com.meswan.hermes.mac.widgets`; `#else` keeps the iOS id. Same string in ConduitMac.entitlements and ConduitMacWidgets/ConduitMacWidgets.entitlements |
| ConduitWidgets/LauncherWidgets.swift | R4-widen | two `#available(iOS 18.0, *)` guarding `widgetAccentedRenderingMode` (macOS 15) need `macOS 15.0` named, else Mac 14 fails to compile (lines 76, 138) | `macOS 15.0` added to both availability lists (R8); the full-colour branch runs on Mac 14 |
| ConduitWidgets/*, Shared/Widgets/*, ConduitWidgets/Resources/Assets.xcassets, Conduit/Localizable.xcstrings | shared source | the Mac widget extension compiles the iOS widget sources by path (D25); no copies | project.yml target `ConduitMacWidgets`; Mac-only plist and entitlements in ConduitMacWidgets/. Re-check after each upstream merge: new iOS-only API in ConduitWidgets/ or Shared/Widgets/ breaks the Mac extension build |
```

- [ ] **Step 3: RELEASING.md**

Add a section before "## Back up the signing key":

```
## Widget extension

Conduit.app embeds `Contents/PlugIns/ConduitMacWidgets.appex` (D25). `scripts/mac-release.sh` runs `scripts/mac-verify-bundle.sh --app <exported app> --require-timestamp` after export and before notarization; a failure stops the release. To check a release build without exporting, notarizing or publishing anything, run `scripts/mac-verify-bundle.sh --archive` (builds a signed Release archive in `build/mac-verify`, verifies it, deletes it; `--keep` leaves it). The extension version must equal the app's: the release script's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` overrides apply to every target, and `project.yml` pins the same defaults on both. If the verifier reports the app group missing or `xcodebuild` asks for a provisioning profile, see the fallback in D25.
```

- [ ] **Step 4: SMOKE_CHECKLIST.md**

Add one line to "Release gate":

```
- [ ] Widgets: the notarized app from the DMG, installed in /Applications and launched once, lists `ConduitMacWidgets` in `pluginkit -mAvvv -p com.apple.widgetkit-extension`, and adding a Conduit widget shows no consent prompt
```

and a new section after "## Notch status (D16)" block (end of file):

```
## Widgets (D25)

Install the exported app in /Applications (quit the running Conduit first), launch it, connect to a dashboard.

- [ ] Edit Widgets lists Conduit with Native and Conduit-chan, medium only; add one of each to the desktop and one to Notification Center
- [ ] Before connecting (or signed out) the widget reads "Open Conduit"; after the app connects and loads sessions, the dashboard and profile labels and the last chat title appear within a few seconds
- [ ] Edit Widget: the Workspace and Conversation pickers list your dashboards and chats; picking a chat changes the title; Hide conversation title shows "Resume chat"
- [ ] Tap the title: the chat opens. Tap New Chat: a new chat opens. Tap Talk: a voice call starts (microphone prompt only the first time). Each from: Conduit frontmost, Conduit in the background, all windows closed (Cmd-W), and Conduit quit
- [ ] A tap while signed out or with the dashboard unreachable ends with a visible failure message, not a hang (30 s limit)
- [ ] Switch App Language in Settings: the widget copy follows
- [ ] Sign out / remove the dashboard: the widget falls back to "Open Conduit" or "Open Conduit to refresh"
- [ ] Update through Sparkle from the previous build: the widgets keep working without re-adding
- [ ] macOS 15 desktop with a tinted widget style: the mark and character render accented; on macOS 14 they render full colour
- [ ] With D21 session windows, a widget tap opens one chat once (not once per window)
```

- [ ] **Step 5: PLAN2_INPUTS.md**

Change line 10 to:

```
- `conduit://` is registered on Mac as of D25 (widgets: `CFBundleURLTypes` in ConduitMac/Resources/Info.plist); external session links and widget taps reach `.onOpenURL`. In-app links route through `MacOpenURLPolicy`.
```

- [ ] **Step 6: Final verification**

Run in order, one xcodebuild at a time:
1. `xcodegen generate`
2. Full Mac suite: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO` (all green except the known flaky orb test)
3. `bash scripts/tests/test-mac-verify-bundle.sh` and `bash scripts/tests/test-mac-version.sh`
4. `git diff <base-commit> -- Conduit Shared ConduitWidgets --stat` lists only `Shared/Widgets/WidgetSnapshotStore.swift` and `ConduitWidgets/LauncherWidgets.swift`; `git diff <base-commit> -U0 -- Conduit Shared ConduitWidgets | grep '^-[^-]' | wc -l` prints `2`.
5. `grep -n 'Verified:\|Task 5 result' docs/macos/DECISIONS.md` shows nothing unfinished, and the D25 paragraph contains the observed archive result sentence.

- [ ] **Step 7: Cleanup and commit**

Delete regenerable scratch (`build/dd` only if disk is tight), stop anything you started, remove your worktree and branch after merge (workspace rules).

```bash
git add 'docs/macos/DECISIONS.md' 'docs/macos/PORTING_LEDGER.md' 'docs/macos/RELEASING.md' 'docs/macos/SMOKE_CHECKLIST.md' 'docs/macos/PLAN2_INPUTS.md'
git commit -m "docs(mac): D25 desktop widgets, ledger rows, release and smoke notes"
```

---

## Execution notes

- Order: Task 1, then 2 (needs 1's group string), then 3 (independent of 2 in code but run after it so the suite builds with the extension), then 4, 5 (needs 2 and 4), then 6. Merge and run the full suite after each merge.
- Tasks 1 to 3 are Debug and unsigned (`CODE_SIGNING_ALLOWED=NO`); only Task 5 uses real signing. Task 5 is the gate for the group-id decision.
- Coordination: D21 (session windows) and D24 (Home) are in flight. D25 touches `ConduitMacApp.swift` (one line) and `project.yml` (one target, one dependency line); expect trivial merge conflicts there. D21 must keep `.onOpenURL` on one window.
- Manual checks (Task 6 smoke list) need the exported app installed in /Applications; they are the release owner's, not part of the automated run. Do not install over the user's Conduit without asking.
- Effort check against the spec (about 3 days): Task 1 0.5, Task 2 1.0, Task 3 0.5, Tasks 4 and 5 1.0, Task 6 0.5 (the extra 0.5 over the spec's split is the routing tests).
