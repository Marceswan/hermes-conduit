# Mac Settings (Cmd-,) and Switch Dashboard (Cmd-Shift-D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App menu "Settings..." on Cmd-, opens Conduit's existing Settings sheet, and Go > "Switch Dashboard..." on Cmd-Shift-D opens the saved-dashboards switcher, with no upstream (`Conduit/`, `Shared/`) edits.

**Architecture:** One small `MacAppActions` helper (beside `MacPaletteActions`) resolves the primary chat window (forwarding from a D21 session window), applies the `commandsBlocked` sheet guard, dismisses the palette, then acts. Settings posts the existing `.macOpenSettingsRequested` that D18 already wired to a gated `RootView` observer. Switch Dashboard presents a Mac-owned sheet (`MacDashboardSwitcherStore` + modifier on `ConduitMacApp.rootContent`) that hosts the unmodified `SavedDashboardsSettingsDetail` under a `ConduitSheetHeader`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit on macOS 14+, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-16-mac-settings-dashboard-shortcuts-design.md`

## Global Constraints

- Mac only. Never run an iOS build or iOS tests. iOS behaviour is unchanged.
- ZERO edits under `Conduit/` or `Shared/`. Verify at the end of every task: `git diff <base-commit> --stat -- Conduit Shared` prints nothing. (If an upstream edit ever becomes unavoidable it must be wrapped in `#if os(macOS) // MAC: <reason>` ... `#endif // MAC:`, add exactly one `docs/macos/PORTING_LEDGER.md` row, and be raised with the controller first.)
- New Mac code lives under `ConduitMac/Dashboards/` (switcher) and `ConduitMac/App/MacKeyboardShortcuts.swift` (`MacAppActions`); tests under `ConduitMacTests/`.
- Menu rules (D10): menu items are NEVER `.disabled`; every action guards with `MacKeyboardActions.commandsBlocked(by:)` (a stale disabled item swallows its key). Shortcuts: Settings is `,` with `.command`; Switch Dashboard is `d` with `[.shift, .command]`. Neither may share a key with another item (`MacKeyboardMenuTests` pins this).
- Menu titles are SwiftUI literals with a real ellipsis: `"Settings\u{2026}"`, `"Switch Dashboard\u{2026}"`. The sheet title reuses the catalogued key via `AppLocalization.string("Saved Dashboards")`. No new `Localizable.xcstrings` entries (spec open question 2).
- Session windows (D21, branch `mac-session-windows`) are in flight. Do not touch `focusComposer`, do not add `openWindow`, do not edit the File menu or `ConduitMacApp.body`'s scene list. This plan's edits to the shared files are confined to: one new `CommandGroup(replacing: .appSettings)` block directly after the `CommandGroup(after: .appInfo)` block, one new `Button` in the Go menu directly after "Command Palette", one modifier line in `ConduitMacApp.rootContent` after `.tint(.conduitAccent)`, one appended enum at the end of `MacKeyboardShortcuts.swift`, and appended rows in `MacKeyboardTests.shortcuts()` after the `/Go/Command Palette` row. The D21 session window scene id is `"conduit-session"` (must not start with `conduit-primary`).
- The working tree may have unrelated uncommitted edits. Never `git add -A` or `git add .`; add explicit paths. Never revert or reformat other people's changes.
- After adding a file run `xcodegen generate` (`ConduitMac/` and `ConduitMacTests/` are picked up by folder globs in `project.yml`).
- Test command (one class): `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/<Class>' CODE_SIGNING_ALLOWED=NO`. Never run two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- zsh: quote every path or glob containing `*`, `[`, `?`.
- Tests use injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), injected `NotificationCenter`, polling waits (`HostedTestSupport.waitUntil`, `settle`), explicit window teardown, no fixed sleeps. Never fire a real menu item and never post on `NotificationCenter.default` from a test (that would reach the user's running app's observers only in-process, but the live defaults must stay untouched).
- Chat window id prefix is `conduit-primary` (`MacSessionTabsActions.isMainChatWindow`); session window prefix is `conduit-session`.

## Review Focus

1. Either shortcut pressed while a sheet is attached (Settings, model picker, the dashboard sheet itself) or the sheet is the key window: nothing happens and nothing stacks. Tested in Task 1 (Settings) and Task 2 (switcher).
2. Either shortcut pressed with a D21 session window key: the primary window comes forward and acts; with no primary window open, nothing happens (no crash, no orphan sheet). Tested in Tasks 1 and 2.
3. Key window that is not a Conduit chat window (SwiftUI Settings window id, Sparkle dialog, Quick Ask panel, no window): nothing happens. Tested in Tasks 1 and 2.
4. Cmd-Shift-D pressed twice, or `present()` called while presented: exactly one sheet. Tested in Task 2 (store and hosted).
5. Add Dashboard inside the sheet sets `showLogin` and closes the sheet, so the login screen is not left hidden under it. Tested in Task 2 (hosted, inherited page behaviour).
6. Command palette open when either shortcut runs: the palette closes first. Tested in Tasks 1 and 2.

---

### Task 1: `MacAppActions` and Settings on Cmd-,

**Files:**
- Modify: `ConduitMac/App/MacKeyboardShortcuts.swift` (append `MacAppActions` at the end of the file, after `MacPaletteActions`)
- Modify: `ConduitMac/App/ConduitCommands.swift` (new `CommandGroup(replacing: .appSettings)` block directly after the `CommandGroup(after: .appInfo)` block, currently lines 25-28)
- Modify: `ConduitMacTests/MacKeyboardTests.swift` (one test in `MacKeyboardMenuTests`)
- Create: `ConduitMacTests/MacAppActionsTests.swift`

**Interfaces:**
- Consumes: `MacSessionTabsActions.isMainChatWindow(_ window: NSWindow?) -> Bool`; `MacKeyboardActions.commandsBlocked(by:) -> Bool`; `MacPaletteStore.shared`, `MacPaletteStore(defaults:)`, `MacPaletteStore.dismiss()`, `isPresented`, `present(restoreFocus:)`; `Notification.Name.macOpenSettingsRequested` (`ConduitMac/App/MacChatRoute.swift`).
- Produces (Task 2 relies on these exact names):

```swift
@MainActor
enum MacAppActions {
    static let sessionWindowPrefix: String               // "conduit-session"
    static func isSessionWindow(_ window: NSWindow?) -> Bool
    static func chatWindow(for window: NSWindow?, windows: [NSWindow]? = nil) -> NSWindow?
    /// Resolve, guard, dismiss the palette, bring the chat window forward. True = the caller may act.
    static func prepare(window: NSWindow?, windows: [NSWindow]? = nil, palette: MacPaletteStore? = nil) -> Bool
    @discardableResult
    static func openSettings(window: NSWindow?, windows: [NSWindow]? = nil,
                             palette: MacPaletteStore? = nil, center: NotificationCenter = .default) -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

Create `ConduitMacTests/MacAppActionsTests.swift`:

```swift
import AppKit
import XCTest
@testable import ConduitMac

/// Settings (Cmd-,) and Switch Dashboard (Cmd-Shift-D) actions (D22). Windows
/// are bare NSWindows with the identifiers SwiftUI gives the real ones; the
/// notification centre is injected so nothing reaches the live app.
@MainActor
final class MacAppActionsTests: XCTestCase {
    final class PostCounter { var count = 0 }

    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []
    private var center: NotificationCenter!
    private var counter: PostCounter!
    private var observer: NSObjectProtocol?

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        center = NotificationCenter()
        counter = PostCounter()
        let counter = counter!
        observer = center.addObserver(forName: .macOpenSettingsRequested, object: nil, queue: nil) { _ in
            counter.count += 1
        }
    }

    override func tearDown() async throws {
        if let observer { center.removeObserver(observer) }
        windows.forEach { $0.close() }
        windows = []
        HostedTestSupport.dropSuite(suite)
    }

    private func window(_ identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        if let identifier { w.identifier = NSUserInterfaceItemIdentifier(identifier) }
        windows.append(w)
        return w
    }

    private func primary() -> NSWindow { window("conduit-primary-AppWindow-1") }
    private func session() -> NSWindow { window("conduit-session-AppWindow-1") }

    private func attachSheet(to parent: NSWindow) -> NSWindow {
        let sheet = window(nil)
        parent.beginSheet(sheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { parent.attachedSheet != nil })
        return sheet
    }

    // MARK: window resolution

    func testChatWindowIsThePrimaryWindowItself() {
        let main = primary()
        XCTAssertTrue(MacAppActions.chatWindow(for: main, windows: [main]) === main)
    }

    func testSessionWindowResolvesToThePrimaryWindow() {
        let main = primary(), side = session()
        XCTAssertTrue(MacAppActions.chatWindow(for: side, windows: [side, main]) === main)
        XCTAssertNil(MacAppActions.chatWindow(for: side, windows: [side]), "no primary window open")
    }

    func testOtherWindowsResolveToNothing() {
        let main = primary()
        XCTAssertNil(MacAppActions.chatWindow(for: window("com_apple_SwiftUI_Settings_window"), windows: [main]))
        XCTAssertNil(MacAppActions.chatWindow(for: window(nil), windows: [main]))
        XCTAssertNil(MacAppActions.chatWindow(for: nil, windows: [main]))
        XCTAssertFalse(MacAppActions.isSessionWindow(main))
        XCTAssertTrue(MacAppActions.isSessionWindow(session()))
    }

    // MARK: Settings

    func testSettingsPostsOnceFromThePrimaryWindow() {
        let store = MacPaletteStore(defaults: suite.defaults)
        XCTAssertTrue(MacAppActions.openSettings(window: primary(), palette: store, center: center))
        XCTAssertEqual(counter.count, 1)
    }

    func testSettingsDoesNothingFromNonChatWindows() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let main = primary()
        for w in [window("com_apple_SwiftUI_Settings_window"), window(nil), nil] as [NSWindow?] {
            XCTAssertFalse(MacAppActions.openSettings(window: w, windows: [main], palette: store, center: center))
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testSettingsDoesNothingUnderASheetOrFromTheSheetItself() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let main = primary()
        main.orderFront(nil)
        let sheet = attachSheet(to: main)
        defer { main.endSheet(sheet) }
        XCTAssertFalse(MacAppActions.openSettings(window: main, palette: store, center: center), "sheet attached")
        XCTAssertFalse(MacAppActions.openSettings(window: sheet, windows: [main], palette: store, center: center), "the sheet is key")
        XCTAssertEqual(counter.count, 0)
    }

    func testSettingsFromASessionWindowBringsThePrimaryForwardAndPosts() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let main = primary(), side = session()
        XCTAssertFalse(main.isVisible)
        XCTAssertTrue(MacAppActions.openSettings(window: side, windows: [side, main], palette: store, center: center))
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(main.isVisible, "the sheet appears in the primary window, so it must be on screen")
    }

    func testSettingsFromASessionWindowWithNoPrimaryWindowDoesNothing() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let side = session()
        XCTAssertFalse(MacAppActions.openSettings(window: side, windows: [side], palette: store, center: center))
        XCTAssertEqual(counter.count, 0)
    }

    func testSettingsClosesAnOpenPaletteFirst() {
        let store = MacPaletteStore(defaults: suite.defaults)
        store.present()
        XCTAssertTrue(store.isPresented)
        XCTAssertTrue(MacAppActions.openSettings(window: primary(), palette: store, center: center))
        XCTAssertFalse(store.isPresented)
    }

    func testBlockedSettingsLeavesAnOpenPaletteAlone() {
        let store = MacPaletteStore(defaults: suite.defaults)
        store.present()
        let main = primary()
        main.orderFront(nil)
        let sheet = attachSheet(to: main)
        defer { main.endSheet(sheet) }
        XCTAssertFalse(MacAppActions.openSettings(window: main, palette: store, center: center))
        XCTAssertTrue(store.isPresented)
    }
}
```

In `ConduitMacTests/MacKeyboardTests.swift`, inside `MacKeyboardMenuTests`, directly after `testOurShortcutsAreUnique()`, add:

```swift
    func testSettingsIsInTheAppMenuOnCmdCommaAndNothingElseOwnsIt() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(main.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let settings = try XCTUnwrap(appMenu.items.first { $0.title == "Settings\u{2026}" }, "\(titles)")
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), .command)
        let about = try XCTUnwrap(titles.firstIndex { $0.hasPrefix("About") }, "\(titles)")
        XCTAssertGreaterThan(try XCTUnwrap(appMenu.items.firstIndex(of: settings)), about)
        let comma = entries(main).filter { matches($0, key: ",", mask: .command) }.map(\.path)
        XCTAssertEqual(comma.count, 1, "Cmd-, belongs to one item: \(comma)")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacAppActionsTests' CODE_SIGNING_ALLOWED=NO`
Expected: build failure, `cannot find 'MacAppActions' in scope`.

- [ ] **Step 3: Write the implementation**

Append to the end of `ConduitMac/App/MacKeyboardShortcuts.swift`:

```swift
/// App-level menu commands (D22): Settings (Cmd-,) and Switch Dashboard
/// (Cmd-Shift-D). Both surfaces live in the primary chat window only (the
/// Settings sheet is `MainView`'s, the dashboard sheet hangs on `rootContent`),
/// so a D21 session window forwards to it instead of acting on itself.
@MainActor
enum MacAppActions {
    /// The D21 session window scene id (`WindowGroup(id: "conduit-session")`).
    /// Once the session-windows branch merges, use `MacSessionWindows.sceneID`.
    static let sessionWindowPrefix = "conduit-session"

    static func isSessionWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix(sessionWindowPrefix) ?? false
    }

    /// The window the command acts in: the key window when it is the chat
    /// window, the chat window when the key window is a session window, else
    /// nil (a sheet, the Settings window, a Sparkle dialog, a panel, no window).
    /// `windows` is injectable; the parameter is optional because an `NSApp`
    /// default argument trips Swift 6 isolation.
    static func chatWindow(for window: NSWindow?, windows: [NSWindow]? = nil) -> NSWindow? {
        if MacSessionTabsActions.isMainChatWindow(window) { return window }
        guard isSessionWindow(window) else { return nil }
        return (windows ?? NSApp.windows).first { MacSessionTabsActions.isMainChatWindow($0) }
    }

    /// True when the caller may act. Does nothing under a sheet (the guard runs
    /// here, never as `.disabled` on the item: D10). Closes the palette so its
    /// overlay does not stay up under the new sheet, and brings the chat
    /// window forward when the command came from a session window.
    static func prepare(window: NSWindow?, windows: [NSWindow]? = nil, palette: MacPaletteStore? = nil) -> Bool {
        guard let chat = chatWindow(for: window, windows: windows),
              !MacKeyboardActions.commandsBlocked(by: chat) else { return false }
        (palette ?? .shared).dismiss()
        if chat !== window {
            if chat.isMiniaturized { chat.deminiaturize(nil) }
            chat.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Cmd-,: the D18 observer in `RootView` presents Settings (it keeps its own
    /// "already presenting" guard). With the login screen showing there is no
    /// `MainView`, nobody observes, and nothing happens, as in the sidebar.
    @discardableResult
    static func openSettings(
        window: NSWindow?,
        windows: [NSWindow]? = nil,
        palette: MacPaletteStore? = nil,
        center: NotificationCenter = .default
    ) -> Bool {
        guard prepare(window: window, windows: windows, palette: palette) else { return false }
        center.post(name: .macOpenSettingsRequested, object: nil)
        return true
    }
}
```

In `ConduitMac/App/ConduitCommands.swift`, directly after the `CommandGroup(after: .appInfo) { ... }` block, add:

```swift
        // There is no `Settings` scene (Settings is MainView's sheet, which needs
        // RootView-owned closures), so the app menu has no "Settings..." until
        // this adds it. The D18 observer in RootView does the presenting (D22).
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { MacAppActions.openSettings(window: NSApp.keyWindow) }
                .keyboardShortcut(",", modifiers: .command)
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacAppActionsTests' -only-testing:'ConduitMacTests/MacKeyboardMenuTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS. If `testSettingsIsInTheAppMenuOnCmdCommaAndNothingElseOwnsIt` fails because `Settings...` is missing from the app menu, apply spec open question 5: change the group to `CommandGroup(after: .appInfo)` placed with "Check for Updates" and re-run; record the outcome in D22.

- [ ] **Step 5: Verify no upstream edit, then commit**

Run: `git diff --stat -- Conduit Shared` (Expected: empty)

```bash
git add ConduitMac/App/MacKeyboardShortcuts.swift ConduitMac/App/ConduitCommands.swift ConduitMacTests/MacKeyboardTests.swift ConduitMacTests/MacAppActionsTests.swift
git commit -m "feat(mac): Settings on Cmd-, via the existing macOpenSettingsRequested route (D22)"
```

---

### Task 2: Switch Dashboard sheet on Cmd-Shift-D, docs

**Files:**
- Create: `ConduitMac/Dashboards/MacDashboardSwitcher.swift`
- Modify: `ConduitMac/App/MacKeyboardShortcuts.swift` (add `switchDashboard` to `MacAppActions`)
- Modify: `ConduitMac/App/ConduitCommands.swift` (Go menu: one `Button` directly after "Command Palette")
- Modify: `ConduitMac/App/ConduitMacApp.swift` (`rootContent`: one modifier line after `.tint(.conduitAccent)`)
- Modify: `ConduitMacTests/MacKeyboardTests.swift` (`shortcuts()` table: one row after `/Go/Command Palette`)
- Modify: `ConduitMacTests/MacAppActionsTests.swift` (switcher matrix)
- Create: `ConduitMacTests/MacDashboardSwitcherTests.swift`
- Modify: `docs/macos/DECISIONS.md`, `docs/macos/PORTING_LEDGER.md`, `docs/macos/SMOKE_CHECKLIST.md`

**Interfaces:**
- Consumes (Task 1): `MacAppActions.prepare(window:windows:palette:) -> Bool`, `MacAppActions.chatWindow`. Existing: `SavedDashboardsSettingsDetail(close: () -> Void)` (`Conduit/Views/SavedDashboardsView.swift:15`, needs `@EnvironmentObject AppState`), `ConduitSheetHeader(title:close:)`, `View.macFormSheetSize(minWidth:idealWidth:minHeight:idealHeight:)`, `AppState.themePreference.colorScheme`, `AppLocalization.string(_:)`.
- Produces:

```swift
@MainActor
final class MacDashboardSwitcherStore: ObservableObject {
    static let shared: MacDashboardSwitcherStore
    @Published private(set) var isPresented: Bool
    init()
    func present()      // idempotent
    func dismiss()
}
struct MacDashboardSwitcherView: View { init(close: @escaping () -> Void) }   // needs AppState in the environment
extension View { func macDashboardSwitcher(appState: AppState, store: MacDashboardSwitcherStore? = nil) -> some View }
extension MacAppActions {
    @discardableResult
    static func switchDashboard(window: NSWindow?, windows: [NSWindow]? = nil,
                                palette: MacPaletteStore? = nil, switcher: MacDashboardSwitcherStore? = nil) -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

Create `ConduitMacTests/MacDashboardSwitcherTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacDashboardSwitcherTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var window: NSWindow?
    private var boostWasOn = false

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDashboardSwitcherTests.\(UUID().uuidString)", isDirectory: true)
        // Isolated AppState (same construction as MacPaletteBindingTests): no saved
        // connection, no network, nothing in the live app's defaults.
        appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: store

    func testPresentIsIdempotentAndDismissCloses() {
        let store = MacDashboardSwitcherStore()
        XCTAssertFalse(store.isPresented)
        store.present()
        store.present()
        XCTAssertTrue(store.isPresented)
        store.dismiss()
        XCTAssertFalse(store.isPresented)
        store.dismiss()
        XCTAssertFalse(store.isPresented)
    }

    // MARK: content

    private func hostView(close: @escaping () -> Void) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let view = MacDashboardSwitcherView(close: close).environmentObject(appState)
        let w = HostedTestSupport.host(view.frame(width: 520, height: 520), size: NSSize(width: 520, height: 520))
        window = w
        return w
    }

    func testSheetShowsTheSavedDashboardsPageUnderASheetHeader() throws {
        let w = try hostView(close: {})
        XCTAssertTrue(HostedTestSupport.waitUntil {
            let labels = AccessibilityProbe.labels(in: w)
            return labels.contains("Add Dashboard") && labels.contains("Close Saved Dashboards")
        }, "\(AccessibilityProbe.labels(in: w))")
    }

    func testHeaderCloseCallsCloseOnce() throws {
        var closed = 0
        let w = try hostView(close: { closed += 1 })
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: w).contains("Close Saved Dashboards") })
        XCTAssertTrue(AccessibilityProbe.press("Close Saved Dashboards", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { closed == 1 })
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(closed, 1)
    }

    func testAddDashboardRaisesTheLoginAndClosesTheSheet() throws {
        var closed = 0
        let w = try hostView(close: { closed += 1 })
        XCTAssertFalse(appState.showLogin)
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: w).contains("Add Dashboard") })
        XCTAssertTrue(AccessibilityProbe.press("Add Dashboard", in: w))
        XCTAssertTrue(HostedTestSupport.waitUntil { closed == 1 })
        XCTAssertTrue(appState.showLogin, "the login surface must not stay hidden under the sheet")
    }

    // MARK: modifier

    func testModifierPresentsOneSheetAndDismissesIt() {
        let store = MacDashboardSwitcherStore()
        let host = HostedTestSupport.host(Color.clear.macDashboardSwitcher(appState: appState, store: store),
                                          size: NSSize(width: 600, height: 600))
        window = host
        store.present()
        XCTAssertTrue(HostedTestSupport.waitUntil { host.attachedSheet != nil }, "the sheet attaches to the window")
        let first = host.attachedSheet
        store.present()
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(host.attachedSheet === first, "presenting again keeps the one sheet")
        store.dismiss()
        XCTAssertTrue(HostedTestSupport.waitUntil { host.attachedSheet == nil })
    }
}
```

Append inside `MacAppActionsTests` (before its closing brace) in `ConduitMacTests/MacAppActionsTests.swift`:

```swift
    // MARK: Switch Dashboard

    func testSwitchDashboardPresentsFromThePrimaryWindow() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        XCTAssertTrue(MacAppActions.switchDashboard(window: primary(), palette: palette, switcher: switcher))
        XCTAssertTrue(switcher.isPresented)
        XCTAssertTrue(MacAppActions.switchDashboard(window: primary(), palette: palette, switcher: switcher))
        XCTAssertTrue(switcher.isPresented, "a second press keeps one presentation")
    }

    func testSwitchDashboardDoesNothingFromNonChatWindows() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        let main = primary()
        for w in [window("com_apple_SwiftUI_Settings_window"), window(nil), nil] as [NSWindow?] {
            XCTAssertFalse(MacAppActions.switchDashboard(window: w, windows: [main], palette: palette, switcher: switcher))
        }
        XCTAssertFalse(switcher.isPresented)
    }

    func testSwitchDashboardDoesNothingUnderASheetOrFromTheSheetItself() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        let main = primary()
        main.orderFront(nil)
        let sheet = attachSheet(to: main)
        defer { main.endSheet(sheet) }
        XCTAssertFalse(MacAppActions.switchDashboard(window: main, palette: palette, switcher: switcher))
        XCTAssertFalse(MacAppActions.switchDashboard(window: sheet, windows: [main], palette: palette, switcher: switcher))
        XCTAssertFalse(switcher.isPresented)
    }

    func testSwitchDashboardFromASessionWindowBringsThePrimaryForward() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        let main = primary(), side = session()
        XCTAssertTrue(MacAppActions.switchDashboard(window: side, windows: [side, main], palette: palette, switcher: switcher))
        XCTAssertTrue(switcher.isPresented)
        XCTAssertTrue(main.isVisible)
        let lone = MacDashboardSwitcherStore()
        XCTAssertFalse(MacAppActions.switchDashboard(window: side, windows: [side], palette: palette, switcher: lone))
        XCTAssertFalse(lone.isPresented, "no primary window: no orphan sheet")
    }

    func testSwitchDashboardClosesAnOpenPaletteFirst() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        palette.present()
        let switcher = MacDashboardSwitcherStore()
        XCTAssertTrue(MacAppActions.switchDashboard(window: primary(), palette: palette, switcher: switcher))
        XCTAssertFalse(palette.isPresented)
        XCTAssertTrue(switcher.isPresented)
    }
```

In `ConduitMacTests/MacKeyboardTests.swift`, in `shortcuts()`, add this row to the last `table += [ ... ]` array directly after `("/Go/Command Palette", "k", .command),`:

```swift
            ("/Go/Switch Dashboard\u{2026}", "d", [.shift, .command]),
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacDashboardSwitcherTests' CODE_SIGNING_ALLOWED=NO`
Expected: build failure, `cannot find 'MacDashboardSwitcherStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ConduitMac/Dashboards/MacDashboardSwitcher.swift`:

```swift
import SwiftUI

/// Presentation state of the Cmd-Shift-D dashboard switcher (D22). The sheet
/// itself is `MacDashboardSwitcherView` hosted by `macDashboardSwitcher`.
@MainActor
final class MacDashboardSwitcherStore: ObservableObject {
    static let shared = MacDashboardSwitcherStore()

    @Published private(set) var isPresented = false

    init() {}

    func present() { isPresented = true }
    func dismiss() { isPresented = false }
}

/// The existing Saved Dashboards settings page, unchanged, under a sheet
/// header. Every behaviour (Switch, Sign In, sign out, remove, Add Dashboard,
/// closing when the login surface takes over) is the page's own; this view
/// only frames it. Needs `AppState` in the environment.
struct MacDashboardSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    let close: () -> Void

    init(close: @escaping () -> Void) {
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            ConduitSheetHeader(title: AppLocalization.string("Saved Dashboards"), close: close)
            SavedDashboardsSettingsDetail(close: close)
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
        .macFormSheetSize(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 520)
    }
}

private struct MacDashboardSwitcherModifier: ViewModifier {
    let appState: AppState
    @ObservedObject private var store: MacDashboardSwitcherStore

    init(appState: AppState, store: MacDashboardSwitcherStore) {
        self.appState = appState
        self._store = ObservedObject(wrappedValue: store)
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { store.isPresented },
            set: { if !$0 { store.dismiss() } }
        )) {
            MacDashboardSwitcherView(close: { store.dismiss() })
                .environmentObject(appState)
        }
    }
}

extension View {
    /// Hangs the Cmd-Shift-D sheet on this view. Attach it to `RootView` in
    /// `ConduitMacApp.rootContent`, after the environment and tint modifiers
    /// (the sheet inherits them), so it also shows over the login screen.
    func macDashboardSwitcher(appState: AppState, store: MacDashboardSwitcherStore? = nil) -> some View {
        modifier(MacDashboardSwitcherModifier(appState: appState, store: store ?? .shared))
    }
}
```

Add to `MacAppActions` in `ConduitMac/App/MacKeyboardShortcuts.swift`, after `openSettings` (inside the enum):

```swift
    /// Cmd-Shift-D: the saved-dashboards sheet, over the chat or the login screen.
    @discardableResult
    static func switchDashboard(
        window: NSWindow?,
        windows: [NSWindow]? = nil,
        palette: MacPaletteStore? = nil,
        switcher: MacDashboardSwitcherStore? = nil
    ) -> Bool {
        guard prepare(window: window, windows: windows, palette: palette) else { return false }
        (switcher ?? .shared).present()
        return true
    }
```

In `ConduitMac/App/ConduitCommands.swift`, in `CommandMenu("Go")`, directly after the "Command Palette" button line (`.keyboardShortcut("k", modifiers: .command)`) and before its `Divider()`, add:

```swift
            // Opens the saved-dashboards sheet hosted in ConduitMacApp (D22). Never
            // `.disabled`: the action checks the window and any sheet.
            Button("Switch Dashboard\u{2026}") { MacAppActions.switchDashboard(window: NSApp.keyWindow) }
                .keyboardShortcut("d", modifiers: [.shift, .command])
```

In `ConduitMac/App/ConduitMacApp.swift`, `rootContent`, directly after `.tint(.conduitAccent)`, add:

```swift
            // Cmd-Shift-D saved-dashboards sheet (D22): after the environment and tint it inherits.
            .macDashboardSwitcher(appState: appState)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacDashboardSwitcherTests' -only-testing:'ConduitMacTests/MacAppActionsTests' -only-testing:'ConduitMacTests/MacKeyboardMenuTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (includes `testEveryShortcutIsInTheMenuAndWinsItsKey` and `testOurShortcutsAreUnique` with the new Cmd-Shift-D row, and `testComposerDoesNotSwallowAnyOfTheShortcuts`). If `testModifierPresentsOneSheetAndDismissesIt` cannot attach a sheet in the headless host (no sheet after 5 s), keep the store/action tests, replace that test with an `XCTSkip` carrying the reason, and add a SMOKE_CHECKLIST line; do not weaken the other tests.

- [ ] **Step 5: Docs**

`docs/macos/DECISIONS.md`: append at the end of the file (if D21 landed first, keep both; D22 goes after it):

```markdown
## D22: Settings on Cmd-, and Switch Dashboard on Cmd-Shift-D (2026-10-16)
Spec: docs/superpowers/specs/2026-10-16-mac-settings-dashboard-shortcuts-design.md. App menu "Settings..." (Cmd-,) posts the existing `.macOpenSettingsRequested` (the D18 gated RootView observer presents Settings; no `Settings` scene, because Settings needs MainView's closures). Go > "Switch Dashboard..." (Cmd-Shift-D) presents a Mac-owned sheet (`MacDashboardSwitcherStore`, `macDashboardSwitcher` on `ConduitMacApp.rootContent`) around the unmodified `SavedDashboardsSettingsDetail` (the saved-dashboards UI is a Settings page, not RootView state; the page's own Add / Switch / sign-out logic and its `close` handling are reused). Both go through `MacAppActions`: the primary chat window only (a D21 session window forwards to it and brings it forward; other windows do nothing), nothing under a sheet (`commandsBlocked`, never `.disabled`), the palette is closed first. Zero upstream edits. Cmd-, on the login screen does nothing (no MainView); Cmd-Shift-D works there. Menu strings are SwiftUI literals (not catalogued). Fallbacks: if the app menu does not take `CommandGroup(replacing: .appSettings)`, use `after: .appInfo`; if Cmd-Shift-D is claimed later, Option-Command-D. Tripwires: `MacAppActionsTests`, `MacDashboardSwitcherTests`, `MacKeyboardMenuTests` (table row and `testSettingsIsInTheAppMenuOnCmdCommaAndNothingElseOwnsIt`).
```

In the D10 shortcut table of the same file, add two rows after the `Cmd-K` row:

```markdown
| Cmd-, (D22) | Conduit > Settings... | opens Settings (posts `macOpenSettingsRequested`); primary chat window only, ignored under a sheet |
| Cmd-Shift-D (D22) | Go > Switch Dashboard... | saved-dashboards sheet (`MacDashboardSwitcherStore`); primary chat window only, ignored under a sheet |
```

`docs/macos/PORTING_LEDGER.md`: replace the two deferred rows (currently lines 46-47) with:

```markdown
| Conduit/Views/AuxiliaryViews.swift `SettingsView` Cmd-, Settings scene | n/a (done, D22) | no `Settings` scene: SettingsView needs `MainView`-owned closures (`RootView.swift:199-219`). Cmd-, is an app-menu item that posts `.macOpenSettingsRequested`, already observed by the D18 gated RootView region (row above) | ConduitMac/App/MacKeyboardShortcuts.swift (`MacAppActions.openSettings`), ConduitMac/App/ConduitCommands.swift. No upstream edit. Tests: MacAppActionsTests, MacKeyboardMenuTests |
| Menu: Switch Dashboard (Cmd-Shift-D) | n/a (done, D22) | the saved-dashboards UI is the Settings page `SavedDashboardsSettingsDetail` (not RootView state); a Mac-owned sheet hosts it unchanged | ConduitMac/Dashboards/MacDashboardSwitcher.swift (store, view, `macDashboardSwitcher` modifier on `ConduitMacApp.rootContent`), `MacAppActions.switchDashboard`. No upstream edit. Tests: MacDashboardSwitcherTests, MacAppActionsTests |
```

`docs/macos/SMOKE_CHECKLIST.md`: add under the "Keyboard checks (D10)" list, after the palette lines:

```markdown
  - [ ] Settings (D22): Cmd-, and Conduit > Settings... open Settings from the composer, the sidebar and Bots / Cron / Kanban; with Settings or the model picker already open, Cmd-, does nothing; on the login screen it does nothing. With a session window key (D21) it brings the main window forward and opens Settings there.
  - [ ] Switch Dashboard (D22): Cmd-Shift-D (Go > Switch Dashboard...) opens the Saved Dashboards sheet over the chat and over the login screen; Switch to another saved dashboard works and closes the sheet when it ends at sign-in; Add Dashboard closes the sheet and shows login; Esc and the X close it; with another sheet up it does nothing; with the palette open the palette closes first.
```

- [ ] **Step 6: Whole-suite and diff checks**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO` twice.
Expected: PASS both times (allow the one known flaky test).
Run: `git diff --stat -- Conduit Shared` (Expected: empty).

- [ ] **Step 7: Commit**

```bash
git add ConduitMac/Dashboards/MacDashboardSwitcher.swift ConduitMac/App/MacKeyboardShortcuts.swift ConduitMac/App/ConduitCommands.swift ConduitMac/App/ConduitMacApp.swift ConduitMacTests/MacKeyboardTests.swift ConduitMacTests/MacAppActionsTests.swift ConduitMacTests/MacDashboardSwitcherTests.swift docs/macos/DECISIONS.md docs/macos/PORTING_LEDGER.md docs/macos/SMOKE_CHECKLIST.md
git commit -m "feat(mac): Switch Dashboard on Cmd-Shift-D, hosting the saved-dashboards page in a Mac sheet (D22)"
```
