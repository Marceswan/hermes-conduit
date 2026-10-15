# Mac System Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Conduit reachable from the rest of macOS: a Services menu item "Send to Hermes" (prefill a new chat), Core Spotlight indexing of chat titles (opt-in), and two new App Intents (New Conduit Chat, Open Conduit Chat).

**Architecture:** Three independently shippable parts that share one tiny prerequisite (Part 0, `MacNewChatPrefiller`: create a new session, then prefill its composer). Each part has a pure, unit-tested core (text normalizer, item factory + diff indexer, entity catalog), a main-actor hand-off object, and exactly one added modifier line in `ConduitMacApp.swift`. Everything uses existing public `AppState` API; no `AppState.swift` edits, no second connection, no daemon.

**Tech Stack:** Swift 6 / SwiftUI / AppKit on macOS 14+, CoreSpotlight, AppIntents, Combine, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-15-mac-system-integration-design.md` (approved; open questions resolved to the spec defaults, see Global Constraints).

## Global Constraints

- Mac only. New code under `ConduitMac/`; iOS behaviour unchanged. Upstream edits (`Conduit/`, `Shared/`): `#if os(macOS)` gate, every gate tagged `// MAC:`, one row each in `docs/macos/PORTING_LEDGER.md`. `git diff <base> -- Conduit Shared` removes zero lines.
- No edits to `Conduit/Services/AppState.swift`. Do not touch the unrelated uncommitted edits already present in `AppState.swift` and `ChatView.swift`; stage only the files each task names.
- Resolved decisions: Services is prefill-only into a NEW chat (never send, never touch the active chat); Spotlight indexes title + metadata only and is OFF by default; new intents live in `ConduitMac/Intents/`; the "Ask Hermes returns reply" intent is OUT of this plan (follow-up, needs a headless-turn spike).
- Services text: plain text only, trimmed, empty rejected with `"No text selected"`, capped at 20,000 characters, longer input truncated with a trailing `[truncated]`. Menu title "Send to Hermes". No key equivalent.
- Spotlight: opt-in toggle persisted as `conduit.mac.spotlight.enabled` (default false); snapshot key `conduit.mac.spotlight.<dashboardID or "none">.<profile>`; 2 s debounce; cap 1,000 items per profile, newest first; bot chats and cron sessions never indexed; absence from a loaded page is NOT deletion.
- Intents: `AskHermesAboutScreenIntent` parameter names are a stability contract (add optional parameters only). `StartVoiceConversationIntent`'s `openAppWhenRun` must stay a boolean literal. One `AppShortcutsProvider` per app (`ConduitVoiceShortcuts`); max 10 `AppShortcut`s; phrases must contain `\(.applicationName)`. Deployment target macOS 14: anything macOS 26 only (`supportedModes`, `IntentModes`) needs `@available(iOS 26.0, macOS 26.0, *)` and `// MAC:` if in `Conduit/`.
- Localization per `docs/LOCALIZATION.md`: user-visible strings go through `AppLocalization.string("...")`; new keys land in every shipped language via `scripts/l10n.py export/import --create`, then `python3 scripts/check-l10n-coverage.py --repo-root .` must pass. Intent phrases/short titles live in `Conduit/AppShortcuts.xcstrings`.
- Tests: injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`), explicit teardown, no fixed sleeps. Never touch the live app's defaults or the real Spotlight index (inject a fake).
- Build: `xcodegen generate` after adding or removing files. Build: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`. Test: same flags with `test -only-testing:ConduitMacTests/<Class>` (this plan abbreviates it as `TEST <Class>`). Never two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`. In zsh, quote globs.
- Safety: the user's own Conduit is running. Do not quit it, click it or type into it; never touch a Conduit login form. Manual steps below that need Conduit running are for the human at release time, not for agents.
- Cleanup: delete your scratch output and `build/dd` when a worktree is done; remove a merged worktree and its branch immediately.

## Parallel execution and merge order

Part 0 merges first (about 30 minutes). Then Parts 1, 2 and 3 run in separate worktrees. Their only shared files are append-only or one-line: `ConduitMac/App/ConduitMacApp.swift` (one `.modifier(...)` line each), `docs/macos/PORTING_LEDGER.md`, `docs/macos/DECISIONS.md` (D15, one section appended per part, sub-headed), `docs/macos/SMOKE_CHECKLIST.md` (one "System integration" subsection per part). Resolve any conflict by keeping both sides. Each part's last task re-runs the full suite after rebasing on whatever has merged.

## Review Focus

1. Cold launch via Service, connection never arrives: the parked text must not leak into a later profile or dashboard (dropped on scope change) and must not be applied twice. Tested in Task 1.3.
2. Service fired while a turn streams in the active chat: the active chat's draft and turn are untouched; the text lands in the new chat only. If `createNewSession` refuses (profile switching), nothing is prefilled anywhere. Tested in Task 0.1.
3. Session ids containing dots, pipes or odd characters, and profiles with odd characters, must round-trip through the Spotlight identifier. Tested in Task 2.2.
4. A chat missing from the loaded page is not removed from Spotlight; a renamed chat re-indexes once; a deleted chat is removed; toggle off leaves the index empty and later catalog changes index nothing. Tested in Task 2.3 and 2.4.
5. A Spotlight result for another dashboard or a malformed identifier must not open anything. Tested in Task 2.5.
6. Intents run for any imported shortcut: `NewChatIntent` must never send, and an unknown profile must fail with a readable error rather than create a chat on the wrong profile. Tested in Task 3.3.

## File Map

- Part 0: Create `ConduitMac/App/MacNewChatPrefiller.swift`; Test `ConduitMacTests/MacNewChatPrefillerTests.swift`.
- Part 1: Create `ConduitMac/App/MacServicesProvider.swift`, `ConduitMac/App/MacServiceInbox.swift`, `ConduitMac/App/MacServiceRouting.swift`; Modify `ConduitMac/Resources/Info.plist`, `ConduitMac/App/ConduitMacAppDelegate.swift`, `ConduitMac/App/ConduitMacApp.swift` (one line); Tests `MacServicesProviderTests.swift`, `MacServiceInboxTests.swift`.
- Part 2: Create `ConduitMac/Spotlight/MacSpotlightItem.swift` (factory + id codec), `MacSpotlightIndexer.swift` (diff indexer + `SearchableIndexing` + live adapter), `MacSpotlightBinder.swift` (AppState binding), `MacSpotlightContinuation.swift`, `ConduitMac/Views/MacSpotlightSettingsRow.swift`; Modify `ConduitMac/App/ConduitMacApp.swift` (one line), `Conduit/Views/AuxiliaryViews.swift` (one gate, `homeSection("On this device")` about line 882); Tests `MacSpotlightItemTests.swift`, `MacSpotlightIndexerTests.swift`, `MacSpotlightContinuationTests.swift`.
- Part 3: Create `ConduitMac/Intents/MacIntentInbox.swift`, `MacIntentDataSource.swift`, `ConduitSessionEntity.swift`, `NewChatIntent.swift`, `OpenSessionIntent.swift`, `MacIntentRouting.swift`; Modify `Conduit/Intents/StartVoiceConversationIntent.swift` (gated provider entries), `Conduit/AppShortcuts.xcstrings`, `ConduitMac/App/ConduitMacApp.swift` (one line); Tests `MacIntentInboxTests.swift`, `ConduitSessionEntityTests.swift`, `MacNewChatIntentTests.swift`.
- Docs (each part appends): `docs/macos/DECISIONS.md` (next free number is D15; the spec's "D12" is already taken by Releases), `PORTING_LEDGER.md`, `SMOKE_CHECKLIST.md`.

`ConduitMac/` sources are picked up by the `path: ConduitMac` glob in `project.yml` (target `ConduitMac`, tests `path: ConduitMacTests`). Confirm with `grep -n "path: ConduitMac" project.yml` and re-run `xcodegen generate` after adding files. The built product is `Conduit.app` (TEST_HOST), so the app's bundle name is `Conduit`.

---

# Part 0: Shared prerequisite

### Task 0.1: New-chat prefiller

Why shared: Services (Part 1) and `NewChatIntent` (Part 3) both do "create a new session, then put text in its composer". `AppState.prefillComposer` keys the draft on `activeSessionId`, so it must run after the new session is active. `createNewSession()` is `async` and returns after reconciliation (verified: it awaits `createAndReconcileSession`), so no polling is needed; it silently returns when disconnected, connecting, or profile-switching, which the prefiller detects by `activeSessionId` not changing.

**Files:**
- Create: `ConduitMac/App/MacNewChatPrefiller.swift`
- Test: `ConduitMacTests/MacNewChatPrefillerTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor struct MacNewChatPrefiller` with `var activeSessionId: () -> String?`, `var createNewSession: () async -> Void`, `var prefill: (String) -> Void`
  - `func run(_ text: String) async -> Bool` (true when a new session became active and the text was prefilled)
  - `static func live(_ appState: AppState) -> MacNewChatPrefiller`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacNewChatPrefillerTests: XCTestCase {
    private var active: String? = "old"
    private var prefilled: [String] = []

    private func prefiller(creating newID: String?) -> MacNewChatPrefiller {
        MacNewChatPrefiller(
            activeSessionId: { [unowned self] in self.active },
            createNewSession: { [unowned self] in if let newID { self.active = newID } },
            prefill: { [unowned self] in self.prefilled.append($0) }
        )
    }

    func testPrefillsAfterTheNewSessionIsActive() async {
        let ok = await prefiller(creating: "new").run("hello")
        XCTAssertTrue(ok)
        XCTAssertEqual(prefilled, ["hello"])
        XCTAssertEqual(active, "new")
    }

    func testRefusedCreateNeverPrefillsTheActiveChat() async {
        let ok = await prefiller(creating: nil).run("hello")
        XCTAssertFalse(ok)
        XCTAssertTrue(prefilled.isEmpty, "the open chat's draft must not be overwritten")
    }

    func testPrefillSeesTheNewSessionNotTheOldOne() async {
        var seen: String?
        let p = MacNewChatPrefiller(
            activeSessionId: { [unowned self] in self.active },
            createNewSession: { [unowned self] in self.active = "new" },
            prefill: { [unowned self] _ in seen = self.active }
        )
        _ = await p.run("x")
        XCTAssertEqual(seen, "new")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacNewChatPrefillerTests`
Expected: build failure, `cannot find 'MacNewChatPrefiller' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Starts a new chat and puts text in its composer without sending it (D15).
/// Prefill keys the draft on the active session, so it runs only after the
/// new session is active. A refused create (disconnected, connecting, profile
/// switching) leaves the active chat alone.
@MainActor
struct MacNewChatPrefiller {
    var activeSessionId: () -> String?
    var createNewSession: () async -> Void
    var prefill: (String) -> Void

    func run(_ text: String) async -> Bool {
        let before = activeSessionId()
        await createNewSession()
        guard let after = activeSessionId(), after != before else { return false }
        prefill(text)
        return true
    }

    static func live(_ appState: AppState) -> MacNewChatPrefiller {
        MacNewChatPrefiller(
            activeSessionId: { [weak appState] in appState?.activeSessionId },
            createNewSession: { [weak appState] in await appState?.createNewSession() },
            prefill: { [weak appState] in appState?.prefillComposer($0) }
        )
    }
}
```

If `AppState.activeSessionId` is not readable from the `ConduitMac` module, run `grep -n "var activeSessionId" Conduit/Services/AppState.swift` and use the accessor the session-tab store uses (`MacSessionTabsStore.bind`).

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacNewChatPrefillerTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/App/MacNewChatPrefiller.swift ConduitMacTests/MacNewChatPrefillerTests.swift
git commit -m "macOS: new-chat prefiller shared by Services and Shortcuts (D15)"
```

---

# Part 1: Send to Hermes (Services)

### Task 1.1: Verify the Services keys and API (no product code)

**Files:** none (findings go into the Task 1.4 `DECISIONS.md` entry).

- [ ] **Step 1: Check the Info.plist key shape against a shipping app**

Run: `plutil -p /System/Applications/TextEdit.app/Contents/Info.plist | sed -n '/NSServices/,/^  \]/p' | head -60`
Expected (already seen while planning): each dict has `NSMenuItem` = `{default = "..."}`, `NSMessage` (selector name without colon), `NSPortName` (app name), `NSSendTypes` (array of UTIs such as `public.plain-text`). Confirm `NSReturnTypes` is absent for a send-only service.

- [ ] **Step 2: Check the AppKit API**

Run: `SDK=$(xcrun --show-sdk-path); grep -n "servicesProvider\|NSUpdateDynamicServices\|NSRegisterServicesProvider" "$SDK/System/Library/Frameworks/AppKit.framework/Headers/NSApplication.h"; grep -rn "NSPasteboardTypeString\|NSStringPboardType" "$SDK/System/Library/Frameworks/AppKit.framework/Headers/NSPasteboard.h" | head`
Expected: `@property (nullable, strong) id servicesProvider;` (seen at NSApplication.h:549). Record whether `NSStringPboardType` is deprecated (use `NSPasteboard.PasteboardType.string`, UTI `public.utf8-plain-text`).

- [ ] **Step 3: Decide `NSSendTypes`**

Use `public.utf8-plain-text` and `public.plain-text` (UTIs, as TextEdit does). Add `NSStringPboardType` only if Step 2 or the Services Implementation Guide says the OS still needs it for legacy senders; record the decision. Also confirm the localization mechanism: Apple apps localize the menu title with `ServicesMenu.strings` in each `.lproj` (`ls /System/Applications/TextEdit.app/Contents/Resources/en.lproj` shows it). Record: `ConduitMac` needs `Resources/<lang>.lproj/ServicesMenu.strings` with key `Send to Hermes` for each shipped language, otherwise only the English `NSMenuItem.default` shows. Check `docs/LOCALIZATION.md` and `scripts/check-l10n-coverage.py` for whether lproj `.strings` files are covered; if not, list the languages by `ls Conduit/*.lproj 2>/dev/null` or the catalog and note the gap for Task 1.4.

- [ ] **Step 4: Confirm the app is unsandboxed**

Run: `cat ConduitMac/Resources/ConduitMac.entitlements`
Expected: no `com.apple.security.app-sandbox` key (only audio-input and camera). A Service needs no entitlement.

No commit.

### Task 1.2: Text normalizer and provider

**Files:**
- Create: `ConduitMac/App/MacServicesProvider.swift`
- Test: `ConduitMacTests/MacServicesProviderTests.swift`

**Interfaces:**
- Consumes: `MacServiceInbox.submit(_:)` (Task 1.3; until then the provider takes the sink as a closure).
- Produces:
  - `enum MacServiceText { static let limit = 20_000; static let truncationNote = "[truncated]"; static func normalize(_ raw: String?) -> String? }`
  - `final class MacServicesProvider: NSObject` with `init(sink: @escaping @MainActor (String) -> Void)`, `@objc func sendToHermes(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>)`
  - `static let selectorName = "sendToHermes"`

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class MacServicesProviderTests: XCTestCase {
    private var board: NSPasteboard!
    private var received: [String] = []

    override func setUp() {
        board = NSPasteboard(name: NSPasteboard.Name("conduit.tests.\(UUID().uuidString)"))
        received = []
    }
    override func tearDown() { board.releaseGlobally(); board = nil }

    private func call(_ provider: MacServicesProvider) -> String? {
        var message: NSString = ""
        provider.sendToHermes(board, userData: "", error: &message)
        return message.length == 0 ? nil : message as String
    }

    private func provider() -> MacServicesProvider {
        MacServicesProvider { [unowned self] in self.received.append($0) }
    }

    func testNormalizeTrimsAndRejectsEmpty() {
        XCTAssertEqual(MacServiceText.normalize("  hi \n"), "hi")
        XCTAssertNil(MacServiceText.normalize("   \n\t"))
        XCTAssertNil(MacServiceText.normalize(nil))
    }

    func testNormalizeTruncatesAtTheCapWithANote() {
        let long = String(repeating: "a", count: MacServiceText.limit + 500)
        let out = MacServiceText.normalize(long)!
        XCTAssertTrue(out.hasSuffix("\n[truncated]"))
        XCTAssertEqual(out.count, MacServiceText.limit + "\n[truncated]".count)
        let exact = String(repeating: "b", count: MacServiceText.limit)
        XCTAssertEqual(MacServiceText.normalize(exact), exact, "exactly at the cap is not truncated")
    }

    func testNormalizeCountsCharactersNotBytes() {
        let emoji = String(repeating: "\u{1F600}", count: MacServiceText.limit)
        XCTAssertEqual(MacServiceText.normalize(emoji)?.count, MacServiceText.limit)
    }

    func testProviderDeliversPlainText() {
        board.clearContents()
        board.setString("  selected text ", forType: .string)
        XCTAssertNil(call(provider()))
        XCTAssertEqual(received, ["selected text"])
    }

    func testProviderFlattensRichText() {
        board.clearContents()
        let rtf = try! NSAttributedString(string: "bold words").data(
            from: NSRange(location: 0, length: 10),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(rtf, forType: .rtf)
        XCTAssertNil(call(provider()))
        XCTAssertEqual(received, ["bold words"])
    }

    func testProviderRejectsEmptyAndNonStringBoards() {
        board.clearContents()
        XCTAssertEqual(call(provider()), "No text selected")
        board.setString("   ", forType: .string)
        XCTAssertEqual(call(provider()), "No text selected")
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertEqual(call(provider()), "No text selected")
        XCTAssertTrue(received.isEmpty)
    }

    func testSelectorNameMatchesTheMethod() {
        XCTAssertTrue(MacServicesProvider.instancesRespond(to: Selector(("\(MacServicesProvider.selectorName):userData:error:"))))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacServicesProviderTests`
Expected: build failure, `cannot find 'MacServicesProvider' in scope`.

- [ ] **Step 3: Implement**

```swift
import AppKit

/// Cleans the text a Service hands over (D15): plain, trimmed, capped.
enum MacServiceText {
    static let limit = 20_000
    static let truncationNote = "[truncated]"

    static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n" + truncationNote
    }
}

/// The object behind `NSApp.servicesProvider`. Info.plist `NSServices[0].NSMessage`
/// names `sendToHermes`; AppKit calls `sendToHermes:userData:error:`.
final class MacServicesProvider: NSObject {
    static let selectorName = "sendToHermes"

    private let sink: @MainActor (String) -> Void

    init(sink: @escaping @MainActor (String) -> Void) {
        self.sink = sink
    }

    @objc func sendToHermes(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // `string(forType: .string)` converts rich text to plain text.
        guard let text = MacServiceText.normalize(pboard.string(forType: .string)) else {
            error.pointee = "No text selected"
            return
        }
        // Services calls arrive on the main thread; hop explicitly rather than assume.
        let sink = self.sink
        Task { @MainActor in sink(text) }
    }
}
```

Note: `testProviderDeliversPlainText` must wait for the `Task`: replace the direct `XCTAssertEqual(received, ...)` with `XCTAssertTrue(HostedTestSupport.waitUntil { received == [...] })` in the two delivering tests when the sink hop makes them flaky. If `string(forType: .string)` returns nil for the RTF-only board, fall back to `NSAttributedString(rtf:documentAttributes:)?.string`, and keep the test.

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacServicesProviderTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/App/MacServicesProvider.swift ConduitMacTests/MacServicesProviderTests.swift
git commit -m "macOS: Services provider and text normalizer (D15)"
```

### Task 1.3: Inbox, routing, plist, delegate wiring

**Files:**
- Create: `ConduitMac/App/MacServiceInbox.swift`, `ConduitMac/App/MacServiceRouting.swift`
- Modify: `ConduitMac/Resources/Info.plist`, `ConduitMac/App/ConduitMacAppDelegate.swift`, `ConduitMac/App/ConduitMacApp.swift` (one line)
- Test: `ConduitMacTests/MacServiceInboxTests.swift`; add the plist test to `MacServicesProviderTests.swift`

**Interfaces:**
- Consumes: `MacServicesProvider(sink:)`, `MacServiceText` (Task 1.2); `MacNewChatPrefiller.live(_:)` (Task 0.1); `AppState.isConnected`, `activeDashboardID`, `activeProfile`.
- Produces:
  - `@MainActor final class MacServiceInbox: ObservableObject` with `static let shared`, `@Published private(set) var revision: Int`, `var currentScope: () -> String`, `func submit(_ text: String)`, `func take() -> String?` (returns nil and clears when the scope changed since submit), `func discard()`, `var hasPending: Bool`
  - `static func scope(dashboardID: UUID?, profile: String) -> String`
  - `struct MacServiceRouting: ViewModifier` with `init(appState: AppState, inbox: MacServiceInbox = .shared)`; `extension View { func macServiceRouting(appState: AppState) -> some View }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacServiceInboxTests: XCTestCase {
    private var scope = "d1.default"
    private var inbox: MacServiceInbox!

    override func setUp() {
        inbox = MacServiceInbox()
        inbox.currentScope = { [unowned self] in self.scope }
    }

    func testLastWriteWins() {
        inbox.submit("first"); inbox.submit("second")
        XCTAssertEqual(inbox.take(), "second")
        XCTAssertNil(inbox.take(), "applied exactly once")
    }

    func testTakeDropsTextParkedForAnotherProfileOrDashboard() {
        inbox.submit("secret")
        scope = "d1.work"
        XCTAssertNil(inbox.take())
        XCTAssertFalse(inbox.hasPending, "dropped, not kept for later")
        inbox.submit("again")
        scope = "d2.work"
        XCTAssertNil(inbox.take())
    }

    func testSubmitBumpsRevisionSoTheRouteTaskRearms() {
        let before = inbox.revision
        inbox.submit("a")
        XCTAssertGreaterThan(inbox.revision, before)
    }

    func testDiscardClears() {
        inbox.submit("a"); inbox.discard()
        XCTAssertNil(inbox.take())
    }

    func testScopeKeyFormat() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(MacServiceInbox.scope(dashboardID: id, profile: "p"), "00000000-0000-0000-0000-000000000001.p")
        XCTAssertEqual(MacServiceInbox.scope(dashboardID: nil, profile: "p"), "none.p")
    }
}
```

Plist test, appended to `MacServicesProviderTests` (the test bundle runs inside `Conduit.app`, so read the host's plist):

```swift
    func testInfoPlistDeclaresTheService() throws {
        let services = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(service["NSMessage"] as? String, MacServicesProvider.selectorName)
        XCTAssertEqual(service["NSPortName"] as? String, "Conduit")
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Send to Hermes")
        XCTAssertNotNil(service["NSSendTypes"] as? [String])
        XCTAssertNil(service["NSReturnTypes"], "nothing is returned to the sender")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacServiceInboxTests`
Expected: build failure, `cannot find 'MacServiceInbox' in scope`.

- [ ] **Step 3: Implement the inbox**

```swift
import Foundation

/// Text a Service handed over, parked until Hermes is connected (D15).
/// One slot, last write wins; dropped when the dashboard or profile changed
/// since it arrived (the text was meant for the other workspace's context).
@MainActor
final class MacServiceInbox: ObservableObject {
    static let shared = MacServiceInbox()

    @Published private(set) var revision = 0
    var currentScope: () -> String = { "" }

    private var pending: (text: String, scope: String)?

    var hasPending: Bool { pending != nil }

    static func scope(dashboardID: UUID?, profile: String) -> String {
        "\(dashboardID?.uuidString ?? "none").\(profile)"
    }

    func submit(_ text: String) {
        pending = (text, currentScope())
        revision += 1
    }

    func take() -> String? {
        defer { pending = nil }
        guard let pending, pending.scope == currentScope() else { return nil }
        return pending.text
    }

    func discard() { pending = nil }
}
```

- [ ] **Step 4: Implement the routing modifier**

```swift
import AppKit
import SwiftUI

/// Applies a parked Service request once Hermes is connected: bring the
/// window forward, start a new chat, put the text in its composer (D15).
struct MacServiceRouting: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var inbox: MacServiceInbox

    init(appState: AppState, inbox: MacServiceInbox = .shared) {
        self.appState = appState
        self.inbox = inbox
    }

    func body(content: Content) -> some View {
        content
            .task {
                inbox.currentScope = { [weak appState] in
                    MacServiceInbox.scope(dashboardID: appState?.activeDashboardID, profile: appState?.activeProfile ?? "")
                }
            }
            .task(id: "\(inbox.revision):\(appState.isConnected)") {
                guard appState.isConnected, let text = inbox.take() else { return }
                MacServiceRouting.bringConduitForward()
                _ = await MacNewChatPrefiller.live(appState).run(text)
            }
    }

    @MainActor
    static func bringConduitForward() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("conduit-primary") ?? false }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

extension View {
    func macServiceRouting(appState: AppState) -> some View {
        modifier(MacServiceRouting(appState: appState))
    }
}
```

The `.task` that installs `currentScope` and the `submit` must be ordered: a Service fired at cold launch can call `submit` before the view's first `.task` runs, which would stamp the parked text with the default scope `""`. Guard against it: in `submit`, if `currentScope` is still the default closure, store scope `nil` and have `take()` accept a nil-scope entry once, stamping the current scope. Implement as `pending = (text, scopeInstalled ? currentScope() : nil)` with `scopeInstalled` set by a `func install(scope:)` method that replaces the bare `currentScope` assignment, and add a test `testTextParkedBeforeScopeIsInstalledIsAccepted`.

- [ ] **Step 5: Wire the plist, delegate and app**

`ConduitMac/Resources/Info.plist`, before the closing `</dict>` (keys per Task 1.1 findings; adjust `NSSendTypes` to what 1.1 recorded):

```xml
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Send to Hermes</string></dict>
            <key>NSMessage</key><string>sendToHermes</string>
            <key>NSPortName</key><string>Conduit</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
```

`ConduitMacAppDelegate`: add a stored property and set it at launch.

```swift
    private let servicesProvider = MacServicesProvider { text in MacServiceInbox.shared.submit(text) }
    // in applicationDidFinishLaunching, after MacDefaults.register():
    NSApp.servicesProvider = servicesProvider
```

`ConduitMacApp.rootContent`, one line next to `.task { SiriProfileShortcuts.refresh() }`:

```swift
            .macServiceRouting(appState: appState)
```

- [ ] **Step 6: Run to verify pass**

Run: `TEST MacServiceInboxTests`, then `TEST MacServicesProviderTests`, then the full build command from Global Constraints.
Expected: pass; build succeeds.

- [ ] **Step 7: Commit**

```bash
git add ConduitMac/App/MacServiceInbox.swift ConduitMac/App/MacServiceRouting.swift ConduitMac/Resources/Info.plist ConduitMac/App/ConduitMacAppDelegate.swift ConduitMac/App/ConduitMacApp.swift ConduitMacTests/MacServiceInboxTests.swift ConduitMacTests/MacServicesProviderTests.swift
git commit -m "macOS: Send to Hermes service, parked until connected (D15)"
```

### Task 1.4: Localization, docs, manual pass

**Files:**
- Modify: `docs/macos/DECISIONS.md`, `docs/macos/SMOKE_CHECKLIST.md`; `Conduit/Localizable.xcstrings` (key `No text selected` if shown to a user); `ConduitMac/Resources/<lang>.lproj/ServicesMenu.strings` per Task 1.1 Step 3 (only if required).
- No ledger row (zero upstream edits).

- [ ] **Step 1: Localize**

Add `No text selected` through the `scripts/l10n.py export <lang>` / `import --create` flow for every shipped language (see `docs/LOCALIZATION.md`). Add the `ServicesMenu.strings` files if Task 1.1 found they are required; each contains `"Send to Hermes" = "<translation>";`. Run `python3 scripts/check-l10n-coverage.py --repo-root .`.

- [ ] **Step 2: DECISIONS.md D15 (Services part)**

Append a `## D15: Mac system integration (2026-10-15)` section (Part 2 and 3 append their own paragraphs): prefill over send (selections are partial, may hold secrets, fire from other apps without confirmation, sending starts a billed turn); always a new chat; plain text, 20,000 character cap; parked until connected and dropped on scope change; no URL scheme (text in URL handlers, any app could trigger it); no share extension; the Task 1.1 findings (key shape, UTIs, localization mechanism).

- [ ] **Step 3: SMOKE_CHECKLIST.md**

Add a "System integration: Services" subsection:
- [ ] Run `/System/Library/CoreServices/pbs -flush`, relaunch Conduit once; System Settings > Keyboard > Keyboard Shortcuts > Services > Text lists "Send to Hermes"; its toggle works
- [ ] Select text in TextEdit and Safari, run the Service with Conduit closed: Conduit opens, new chat, text in the composer, not sent
- [ ] Same with Conduit connected and mid-turn: the running chat is untouched, the text is in a new chat
- [ ] Select text in a Mail message and an image-only selection: Service is absent or reports "No text selected"; nothing breaks
- [ ] Switch profile before the cold launch connects: the parked text is not applied to the other profile

- [ ] **Step 4: Full verification and commit**

Run: full build, `xcodebuild ... test` (all of ConduitMacTests), iOS check `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. Expected: green except the known flaky test. Run `git diff <base> -- Conduit Shared | grep '^-[^-]'` and expect no output.

```bash
git add docs/macos/DECISIONS.md docs/macos/SMOKE_CHECKLIST.md Conduit/Localizable.xcstrings
git commit -m "docs(mac): Services decisions, smoke checklist, localization (D15)"
```

---

# Part 2: Spotlight session indexing

### Task 2.1: Verify the Core Spotlight API (no product code)

**Files:** none (record findings in Task 2.6's `DECISIONS.md` entry).

- [ ] **Step 1: Check names in the macOS SDK headers**

Run: `H="$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreSpotlight.framework/Headers"; grep -n "CSSearchableItemActionType\|CSSearchableItemActivityIdentifier" "$H/CSSearchableItem.h"; grep -n "deleteSearchableItemsWithIdentifiers\|deleteSearchableItemsWithDomainIdentifiers\|deleteAllSearchableItemsWithCompletionHandler\|indexSearchableItems" "$H/CSSearchableIndex.h"; grep -n "initWithUniqueIdentifier\|domainIdentifier" "$H/CSSearchableItem.h"; grep -n "contentDescription\|displayName\|contentModificationDate" "$H"/CSSearchableItemAttributeSet_*.h`
Expected (seen while planning, SDK 27.0): `CSSearchableItemActionType`, `CSSearchableItemActivityIdentifier`, `init(uniqueIdentifier:domainIdentifier:attributeSet:)`, `indexSearchableItems:completionHandler:`, `deleteSearchableItemsWithIdentifiers:`, `deleteSearchableItemsWithDomainIdentifiers:`, `deleteAllSearchableItemsWithCompletionHandler:`, and the three attribute-set properties. Note the Swift spellings the compiler gives (`deleteSearchableItems(withIdentifiers:)`, `deleteSearchableItems(withDomainIdentifiers:)`, `deleteAllSearchableItems()`): the spec's `deleteAllSearchableItems` has an async/completion Swift form; confirm by compiling a 5-line scratch file in the scratchpad directory, not in the repo.

- [ ] **Step 2: Check the SwiftUI continuation hook**

Run: `grep -rn "onContinueUserActivity" "$(xcrun --show-sdk-path)/System/Library/Frameworks/SwiftUI.framework" 2>/dev/null | head -3` (the swiftinterface may be under `usr/lib/swift`; if nothing is found, compile `Text("x").onContinueUserActivity(CSSearchableItemActionType) { _ in }` in a scratch file). Confirm it is available on macOS 14. Note: `.onContinueUserActivity` on a `WindowGroup` root view fires for Spotlight launches; if Task 2.5's manual pass shows it does not fire on a cold launch, add `application(_:continue:restorationHandler:)` to `ConduitMacAppDelegate` as the documented AppKit route and record it.

- [ ] **Step 3: Check identifier-shape rules**

The `CSSearchableItem.h` comment on `domainIdentifier` mentions period-separated forms for mail only. Decision used by this plan (do not use dots as separators): unique id `conduit|<dashboardKey>|<percent-encoded profile>|<session id>`, domain `conduit|<dashboardKey>|<percent-encoded profile>`, parsed with at most 3 splits so a session id containing `|` or `.` survives.

- [ ] **Step 4: Check the sandbox/entitlement need**

Core Spotlight needs no entitlement for an unsandboxed Developer ID app (matches Task 1.1 Step 4). Record it.

No commit.

### Task 2.2: Item factory and identifier codec

**Files:**
- Create: `ConduitMac/Spotlight/MacSpotlightItem.swift`
- Test: `ConduitMacTests/MacSpotlightItemTests.swift`

**Interfaces:**
- Consumes: `SessionSummary` (`id`, `title`, `model`, `messageCount`, `lastActivityAt`, `source`, `isArchived`).
- Produces:
  - `struct MacSpotlightScope: Equatable { var dashboardID: UUID?; var profile: String; var key: String; var domainIdentifier: String }`
  - `struct MacSpotlightItem: Equatable { var uniqueIdentifier: String; var domainIdentifier: String; var title: String; var contentDescription: String; var modified: Date? }`
  - `struct MacSpotlightItemID: Equatable { var dashboardKey: String; var profile: String; var sessionID: String; static func make(scope:sessionID:) -> String; static func parse(_ raw: String) -> MacSpotlightItemID? }`
  - `enum MacSpotlightItemFactory { static func isIndexable(_ s: SessionSummary) -> Bool; static func item(for s: SessionSummary, scope: MacSpotlightScope) -> MacSpotlightItem }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacSpotlightItemTests: XCTestCase {
    private let dash = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func scope(_ profile: String = "default", dashboard: UUID? = nil) -> MacSpotlightScope {
        MacSpotlightScope(dashboardID: dashboard ?? dash, profile: profile)
    }

    private func summary(_ id: String, title: String = "T", source: SessionSource = .chat,
                         archived: Bool = false, count: Int? = 4, at: TimeInterval? = 1_700_000_000) -> SessionSummary {
        SessionSummary.macTestSummary(id: id, alternateIds: [], title: title, source: source,
                                      isArchived: archived, messageCount: count, lastActivityAt: at)
    }

    func testItemFields() {
        let item = MacSpotlightItemFactory.item(for: summary("s1", title: "Laravel queues"), scope: scope())
        XCTAssertEqual(item.title, "Laravel queues")
        XCTAssertTrue(item.contentDescription.contains("4"), "message count shows")
        XCTAssertEqual(item.modified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(item.domainIdentifier, scope().domainIdentifier)
        XCTAssertTrue(item.uniqueIdentifier.hasPrefix(scope().domainIdentifier + "|"))
    }

    func testBlankTitleFallsBack() {
        let item = MacSpotlightItemFactory.item(for: summary("s1", title: "  "), scope: scope())
        XCTAssertFalse(item.title.isEmpty)
    }

    func testIdentifierRoundTripsOddSessionIDsAndProfiles() {
        for sid in ["abc", "a.b.c", "a|b|c", "id with spaces", "\u{1F600}", "x/y"] {
            for profile in ["default", "My Profile", "a|b", "p.q", "r/s", "ü"] {
                let raw = MacSpotlightItemID.make(scope: scope(profile), sessionID: sid)
                let parsed = MacSpotlightItemID.parse(raw)
                XCTAssertEqual(parsed?.sessionID, sid, raw)
                XCTAssertEqual(parsed?.profile, profile, raw)
                XCTAssertEqual(parsed?.dashboardKey, scope(profile).dashboardKey)
            }
        }
    }

    func testNilDashboardKeyIsNone() {
        let s = MacSpotlightScope(dashboardID: nil, profile: "p")
        XCTAssertEqual(MacSpotlightItemID.parse(MacSpotlightItemID.make(scope: s, sessionID: "x"))?.dashboardKey, "none")
    }

    func testDomainIsPerProfileAndDashboard() {
        XCTAssertNotEqual(scope("a").domainIdentifier, scope("b").domainIdentifier)
        XCTAssertNotEqual(scope("a").domainIdentifier, scope("a", dashboard: UUID()).domainIdentifier)
    }

    func testMalformedIdentifiersDoNotParse() {
        for raw in ["", "nope", "conduit|only|two", "other|a|b|c", "conduit||p|s", "conduit|d|p|"] {
            XCTAssertNil(MacSpotlightItemID.parse(raw), raw)
        }
    }

    func testIndexableRules() {
        XCTAssertTrue(MacSpotlightItemFactory.isIndexable(summary("a")))
        XCTAssertFalse(MacSpotlightItemFactory.isIndexable(summary("a", source: .cron)))
        XCTAssertFalse(MacSpotlightItemFactory.isIndexable(summary("a", source: .voiceJob)))
        XCTAssertFalse(MacSpotlightItemFactory.isIndexable(summary("a", archived: true)))
    }
}
```

`SessionSummary.macTestSummary` already exists in `ConduitMacTests/MacSessionTabsStoreTests.swift` (from the session-tabs work) with parameters `id`, `alternateIds`, `title`. Extend it in place with optional `source: SessionSource = .chat`, `isArchived: Bool = false`, `messageCount: Int? = nil`, `lastActivityAt: TimeInterval? = nil` (defaults keep existing callers compiling); if Parts 1 to 3 run in parallel, only Part 2 touches this helper.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacSpotlightItemTests`
Expected: build failure, `cannot find 'MacSpotlightScope' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which dashboard and profile an index belongs to (D15).
struct MacSpotlightScope: Equatable {
    var dashboardID: UUID?
    var profile: String

    var dashboardKey: String { dashboardID?.uuidString ?? "none" }
    var encodedProfile: String { MacSpotlightItemID.encode(profile) }
    var domainIdentifier: String { "conduit|\(dashboardKey)|\(encodedProfile)" }
    /// UserDefaults key for this scope's snapshot.
    var snapshotKey: String { "conduit.mac.spotlight.\(dashboardKey).\(profile)" }
}

struct MacSpotlightItem: Equatable {
    var uniqueIdentifier: String
    var domainIdentifier: String
    var title: String
    var contentDescription: String
    var modified: Date?
}

/// `conduit|<dashboardKey>|<percent-encoded profile>|<session id>`. The session
/// id is last and unencoded so it may hold any character; parsing splits at
/// most three times.
struct MacSpotlightItemID: Equatable {
    var dashboardKey: String
    var profile: String
    var sessionID: String

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func make(scope: MacSpotlightScope, sessionID: String) -> String {
        "\(scope.domainIdentifier)|\(sessionID)"
    }

    static func parse(_ raw: String) -> MacSpotlightItemID? {
        let parts = raw.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "conduit",
              !parts[1].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty,
              let profile = parts[2].removingPercentEncoding else { return nil }
        return MacSpotlightItemID(dashboardKey: parts[1], profile: profile, sessionID: parts[3])
    }
}

enum MacSpotlightItemFactory {
    /// Bot chats are removed upstream by `activeProfileSessions`; cron and voice
    /// job rows and archived rows are never indexed.
    static func isIndexable(_ s: SessionSummary) -> Bool {
        guard !s.isArchived else { return false }
        return s.source != .cron && s.source != .voiceJob
    }

    static func item(for s: SessionSummary, scope: MacSpotlightScope) -> MacSpotlightItem {
        let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var details: [String] = []
        if !s.model.isEmpty { details.append(s.model) }
        if let count = s.messageCount {
            details.append(AppLocalization.string("\(count) messages"))
        }
        return MacSpotlightItem(
            uniqueIdentifier: MacSpotlightItemID.make(scope: scope, sessionID: s.id),
            domainIdentifier: scope.domainIdentifier,
            title: title.isEmpty ? AppLocalization.string("New conversation") : title,
            contentDescription: details.joined(separator: " \u{00B7} "),
            modified: s.lastActivityAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
```

The "N messages" string is a counted plural: per `docs/LOCALIZATION.md` it must be an `Int` interpolation named so the checker reads it as `%lld`, with plural forms in the catalog (`\(count) messages` where `count` is the `.messageCount` unwrap; rename the local to `messageCount`). Add the key and its plural forms in every shipped language in Task 2.6. `"New conversation"` already exists.

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacSpotlightItemTests`
Expected: all pass. If `AppLocalization.string` with a plural key does not resolve in the test host, assert on the digit only (as written).

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Spotlight/MacSpotlightItem.swift ConduitMacTests/MacSpotlightItemTests.swift ConduitMacTests/MacSessionTabsStoreTests.swift
git commit -m "macOS: Spotlight item factory and identifier codec (D15)"
```

### Task 2.3: Diff indexer with an injected index

**Files:**
- Create: `ConduitMac/Spotlight/MacSpotlightIndexer.swift`
- Test: `ConduitMacTests/MacSpotlightIndexerTests.swift`

**Interfaces:**
- Consumes: `MacSpotlightScope`, `MacSpotlightItem`, `MacSpotlightItemFactory` (Task 2.2).
- Produces:
  - `protocol SearchableIndexing: AnyObject { func index(_ items: [MacSpotlightItem]); func delete(ids: [String]); func delete(domains: [String]); func deleteAll() }`
  - `final class CoreSpotlightIndex: SearchableIndexing` (the only file that imports `CoreSpotlight`)
  - `@MainActor final class MacSpotlightIndexer` with `static let itemCap = 1_000`, `init(index: SearchableIndexing, defaults: UserDefaults = .standard)`, `var isEnabled: Bool { get }`, `func setEnabled(_ on: Bool, catalog: [SessionSummary])`, `func setScope(_ scope: MacSpotlightScope?, catalog: [SessionSummary])`, `func catalogChanged(_ sessions: [SessionSummary])`, `func sessionDeleted(_ id: String)`, `func removeAll()`
  - `static let enabledKey = "conduit.mac.spotlight.enabled"`, `static let lastScopeKey = "conduit.mac.spotlight.lastScope"`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class FakeSearchableIndex: SearchableIndexing {
    var indexed: [[MacSpotlightItem]] = []
    var deletedIDs: [[String]] = []
    var deletedDomains: [[String]] = []
    var deleteAllCount = 0
    var allIndexedIDs: [String] { indexed.flatMap { $0 }.map(\.uniqueIdentifier) }
    func index(_ items: [MacSpotlightItem]) { indexed.append(items) }
    func delete(ids: [String]) { deletedIDs.append(ids) }
    func delete(domains: [String]) { deletedDomains.append(domains) }
    func deleteAll() { deleteAllCount += 1 }
}

@MainActor
final class MacSpotlightIndexerTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var index: FakeSearchableIndex!
    private var indexer: MacSpotlightIndexer!
    private let scopeA = MacSpotlightScope(dashboardID: nil, profile: "default")
    private let scopeB = MacSpotlightScope(dashboardID: nil, profile: "work")

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        index = FakeSearchableIndex()
        indexer = MacSpotlightIndexer(index: index, defaults: suite.defaults)
    }
    override func tearDown() async throws {
        indexer = nil; index = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func s(_ id: String, _ title: String = "T", at: TimeInterval = 100) -> SessionSummary {
        SessionSummary.macTestSummary(id: id, alternateIds: [], title: title, lastActivityAt: at)
    }
    private func enabled(scope: MacSpotlightScope? = nil, _ catalog: [SessionSummary] = []) {
        indexer.setEnabled(true, catalog: catalog)
        indexer.setScope(scope ?? scopeA, catalog: catalog)
    }

    func testDisabledByDefaultIndexesNothing() {
        indexer.setScope(scopeA, catalog: [])
        indexer.catalogChanged([s("a")])
        XCTAssertTrue(index.indexed.isEmpty)
        XCTAssertFalse(indexer.isEnabled)
    }

    func testInitialIndexThenOnlyChangedRowsReindex() {
        enabled()
        indexer.catalogChanged([s("a"), s("b")])
        XCTAssertEqual(index.indexed.last?.count, 2)
        index.indexed = []
        indexer.catalogChanged([s("a"), s("b")])
        XCTAssertTrue(index.indexed.isEmpty, "unchanged catalog does nothing")
        indexer.catalogChanged([s("a", "Renamed"), s("b")])
        XCTAssertEqual(index.indexed.last?.map(\.title), ["Renamed"])
    }

    func testActivityChangeReindexes() {
        enabled()
        indexer.catalogChanged([s("a", at: 1)])
        index.indexed = []
        indexer.catalogChanged([s("a", at: 2)])
        XCTAssertEqual(index.indexed.last?.count, 1)
    }

    func testAbsenceFromThePageRemovesNothing() {
        enabled()
        indexer.catalogChanged([s("a"), s("b")])
        indexer.catalogChanged([s("a")])
        XCTAssertTrue(index.deletedIDs.isEmpty, "a paged catalog hides rows without deleting them")
    }

    func testSessionDeletedRemovesOneItemAndForgetsIt() {
        enabled()
        indexer.catalogChanged([s("a"), s("b")])
        indexer.sessionDeleted("a")
        XCTAssertEqual(index.deletedIDs.last, [MacSpotlightItemID.make(scope: scopeA, sessionID: "a")])
        index.indexed = []
        indexer.catalogChanged([s("b")])
        XCTAssertTrue(index.indexed.isEmpty)
    }

    func testArchivedRowIsRemoved() {
        enabled()
        indexer.catalogChanged([s("a")])
        let archived = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "T", isArchived: true, lastActivityAt: 100)
        indexer.catalogChanged([archived])
        XCTAssertEqual(index.deletedIDs.last, [MacSpotlightItemID.make(scope: scopeA, sessionID: "a")])
    }

    func testProfileSwitchDeletesOldDomainAndIndexesNew() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.setScope(scopeB, catalog: [s("w")])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
        XCTAssertEqual(index.indexed.last?.first?.domainIdentifier, scopeB.domainIdentifier)
        indexer.setScope(scopeA, catalog: [s("a")])
        XCTAssertEqual(index.indexed.last?.count, 1, "switching back re-indexes from scratch")
    }

    func testScopeChangeAfterRelaunchDeletesTheStaleDomain() {
        enabled()
        let relaunched = MacSpotlightIndexer(index: index, defaults: suite.defaults)
        relaunched.setScope(scopeB, catalog: [])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
    }

    func testNilScopeDeletesTheCurrentDomain() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.setScope(nil, catalog: [])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
        index.indexed = []
        indexer.catalogChanged([s("a")])
        XCTAssertTrue(index.indexed.isEmpty, "signed out: nothing indexes")
    }

    func testToggleOffDeletesEverythingAndLaterChangesIndexNothing() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.setEnabled(false, catalog: [])
        XCTAssertEqual(index.deleteAllCount, 1)
        index.indexed = []
        indexer.catalogChanged([s("b")])
        XCTAssertTrue(index.indexed.isEmpty)
    }

    func testToggleOnIndexesTheCurrentCatalog() {
        indexer.setScope(scopeA, catalog: [])
        indexer.setEnabled(true, catalog: [s("a")])
        XCTAssertEqual(index.indexed.last?.count, 1)
    }

    func testCapKeepsTheNewest() {
        enabled()
        let catalog = (0..<(MacSpotlightIndexer.itemCap + 50)).map { s("s\($0)", at: TimeInterval($0)) }
        indexer.catalogChanged(catalog)
        let ids = index.allIndexedIDs
        XCTAssertEqual(ids.count, MacSpotlightIndexer.itemCap)
        XCTAssertTrue(ids.contains(MacSpotlightItemID.make(scope: scopeA, sessionID: "s\(MacSpotlightIndexer.itemCap + 49)")))
        XCTAssertFalse(ids.contains(MacSpotlightItemID.make(scope: scopeA, sessionID: "s0")))
    }

    func testNonIndexableRowsAreSkipped() {
        enabled()
        let cron = SessionSummary.macTestSummary(id: "c", alternateIds: [], title: "job", source: .cron)
        indexer.catalogChanged([cron])
        XCTAssertTrue(index.indexed.isEmpty)
    }

    func testSnapshotSurvivesRelaunchSoNothingReindexes() {
        enabled()
        indexer.catalogChanged([s("a")])
        let relaunched = MacSpotlightIndexer(index: FakeSearchableIndex(), defaults: suite.defaults)
        relaunched.setScope(scopeA, catalog: [])
        let fake = FakeSearchableIndex()
        let again = MacSpotlightIndexer(index: fake, defaults: suite.defaults)
        again.setScope(scopeA, catalog: [s("a")])
        XCTAssertTrue(fake.indexed.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacSpotlightIndexerTests`
Expected: build failure, `cannot find type 'SearchableIndexing' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The slice of Core Spotlight the indexer uses, so tests inject a fake.
@MainActor
protocol SearchableIndexing: AnyObject {
    func index(_ items: [MacSpotlightItem])
    func delete(ids: [String])
    func delete(domains: [String])
    func deleteAll()
}

/// The real index. Errors are logged, never thrown: Spotlight is best effort.
@MainActor
final class CoreSpotlightIndex: SearchableIndexing {
    private let index = CSSearchableIndex.default()

    func index(_ items: [MacSpotlightItem]) {
        guard !items.isEmpty else { return }
        let converted = items.map { item -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = item.title
            attributes.displayName = item.title
            attributes.contentDescription = item.contentDescription
            attributes.contentModificationDate = item.modified
            return CSSearchableItem(uniqueIdentifier: item.uniqueIdentifier,
                                    domainIdentifier: item.domainIdentifier,
                                    attributeSet: attributes)
        }
        index.indexSearchableItems(converted) { Self.log("index", $0) }
    }

    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        index.deleteSearchableItems(withIdentifiers: ids) { Self.log("delete ids", $0) }
    }

    func delete(domains: [String]) {
        guard !domains.isEmpty else { return }
        index.deleteSearchableItems(withDomainIdentifiers: domains) { Self.log("delete domains", $0) }
    }

    func deleteAll() {
        index.deleteAllSearchableItems { Self.log("delete all", $0) }
    }

    private nonisolated static func log(_ what: String, _ error: Error?) {
        if let error { NSLog("Conduit Spotlight %@ failed: %@", what, error.localizedDescription) }
    }
}

/// Mirrors the loaded session catalog into Spotlight (D15): opt-in, title and
/// metadata only, diff based. A row missing from the loaded page is not a
/// deletion; deletions come from `sessionDeleted` and archive flags.
@MainActor
final class MacSpotlightIndexer {
    static let itemCap = 1_000
    static let enabledKey = "conduit.mac.spotlight.enabled"
    static let lastScopeKey = "conduit.mac.spotlight.lastScope"

    private struct Row: Codable, Equatable { var title: String; var at: Double? }

    private let index: SearchableIndexing
    private let defaults: UserDefaults
    private var scope: MacSpotlightScope?
    private var snapshot: [String: Row] = [:]

    init(index: SearchableIndexing, defaults: UserDefaults = .standard) {
        self.index = index
        self.defaults = defaults
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func setEnabled(_ on: Bool, catalog: [SessionSummary]) {
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            catalogChanged(catalog)
        } else {
            removeAll()
        }
    }

    /// Removes everything Conduit indexed and forgets the snapshots.
    func removeAll() {
        index.deleteAll()
        snapshot = [:]
        if let scope { defaults.removeObject(forKey: scope.snapshotKey) }
        defaults.removeObject(forKey: Self.lastScopeKey)
    }

    func setScope(_ new: MacSpotlightScope?, catalog: [SessionSummary]) {
        guard new != scope || scope == nil else { return }
        let previous = scope ?? lastPersistedScope()
        if let previous, previous != new, isEnabled {
            index.delete(domains: [previous.domainIdentifier])
            defaults.removeObject(forKey: previous.snapshotKey)
        }
        scope = new
        snapshot = [:]
        if let new {
            persist(scope: new)
            snapshot = load(new)
        } else {
            defaults.removeObject(forKey: Self.lastScopeKey)
        }
        catalogChanged(catalog)
    }

    func catalogChanged(_ sessions: [SessionSummary]) {
        guard isEnabled, let scope else { return }
        let eligible = sessions.filter(MacSpotlightItemFactory.isIndexable)
        let newest = eligible
            .sorted { ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0) }
            .prefix(Self.itemCap)
        var changed: [MacSpotlightItem] = []
        for session in newest {
            let row = Row(title: session.title, at: session.lastActivityAt)
            guard snapshot[session.id] != row else { continue }
            snapshot[session.id] = row
            changed.append(MacSpotlightItemFactory.item(for: session, scope: scope))
        }
        let archived = sessions.filter { $0.isArchived && snapshot[$0.id] != nil }
        for session in archived { snapshot[session.id] = nil }
        index.index(changed)
        index.delete(ids: archived.map { MacSpotlightItemID.make(scope: scope, sessionID: $0.id) })
        if !changed.isEmpty || !archived.isEmpty { save(scope) }
    }

    func sessionDeleted(_ id: String) {
        guard isEnabled, let scope, snapshot[id] != nil else { return }
        snapshot[id] = nil
        index.delete(ids: [MacSpotlightItemID.make(scope: scope, sessionID: id)])
        save(scope)
    }

    // MARK: Persistence

    private func save(_ scope: MacSpotlightScope) {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: scope.snapshotKey) }
    }

    private func load(_ scope: MacSpotlightScope) -> [String: Row] {
        guard let data = defaults.data(forKey: scope.snapshotKey),
              let rows = try? JSONDecoder().decode([String: Row].self, from: data) else { return [:] }
        return rows
    }

    private func persist(scope: MacSpotlightScope) {
        let stored: [String: String] = ["dashboard": scope.dashboardID?.uuidString ?? "", "profile": scope.profile]
        defaults.set(stored, forKey: Self.lastScopeKey)
    }

    private func lastPersistedScope() -> MacSpotlightScope? {
        guard let stored = defaults.dictionary(forKey: Self.lastScopeKey) as? [String: String],
              let profile = stored["profile"] else { return nil }
        let id = stored["dashboard"].flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
        return MacSpotlightScope(dashboardID: id, profile: profile)
    }
}
```

`testScopeChangeAfterRelaunchDeletesTheStaleDomain` relies on `lastPersistedScope()`. In `setScope`, `guard new != scope || scope == nil` lets the first call through even when `new == nil`; keep that.

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacSpotlightIndexerTests`
Expected: all pass. If `deleteSearchableItems(withIdentifiers:completionHandler:)` or `indexSearchableItems(_:completionHandler:)` do not compile under Swift 6 concurrency (Sendable completion), mark the completion `@Sendable` and keep `log` `nonisolated`, as written.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Spotlight/MacSpotlightIndexer.swift ConduitMacTests/MacSpotlightIndexerTests.swift
git commit -m "macOS: Spotlight diff indexer (D15)"
```

### Task 2.4: Bind the indexer to AppState (debounce, deletion, scope)

**Files:**
- Create: `ConduitMac/Spotlight/MacSpotlightBinder.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift` (one line)
- Test: add `MacSpotlightBinderTests` to `ConduitMacTests/MacSpotlightIndexerTests.swift`

**Interfaces:**
- Consumes: `MacSpotlightIndexer`, `MacSpotlightScope` (Tasks 2.2, 2.3); `MacSessionDeletionDetector.mutationChanged(to:catalog:)` from `ConduitMac/Tabs/MacSessionTabsStore.swift`; `AppState.activeProfileSessions`, `activeProfile`, `activeDashboardID`, `$sessions`, `$sessionMutationID`, `$activeProfile`.
- Produces:
  - `@MainActor final class MacSpotlightBinder` with `static let shared`, `init(indexer: MacSpotlightIndexer = MacSpotlightIndexer(index: CoreSpotlightIndex()), debounce: DispatchQueue.SchedulerTimeType.Stride = .seconds(2))`, `func bind(to appState: AppState)`, `let indexer`
  - `extension View { func macSpotlightBinding(appState: AppState) -> some View }`

- [ ] **Step 1: Write the failing tests**

Test the pure seam: the binder takes a `catalog: () -> [SessionSummary]` and exposes `catalogDidChange()`, `scopeDidChange(_:)`, `mutationDidChange(to:)` so tests need no `AppState` publishers; `bind(to:)` only wires publishers to those three methods (covered by the Task 2.4 manual pass and by the debounce test below).

```swift
@MainActor
final class MacSpotlightBinderTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var index: FakeSearchableIndex!
    private var catalog: [SessionSummary] = []
    private var binder: MacSpotlightBinder!
    private let scope = MacSpotlightScope(dashboardID: nil, profile: "default")

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        index = FakeSearchableIndex()
        catalog = []
        binder = MacSpotlightBinder(
            indexer: MacSpotlightIndexer(index: index, defaults: suite.defaults),
            debounce: .milliseconds(50),
            catalog: { [unowned self] in self.catalog }
        )
        binder.indexer.setEnabled(true, catalog: [])
        binder.scopeDidChange(scope)
    }
    override func tearDown() async throws {
        binder = nil; index = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func row(_ id: String) -> SessionSummary { .macTestSummary(id: id, alternateIds: [], title: id, lastActivityAt: 1) }

    func testDebounceCoalescesBurstsIntoOneIndexCall() {
        for i in 0..<5 {
            catalog.append(row("s\(i)"))
            binder.catalogDidChange()
        }
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        HostedTestSupport.settle(0.2)
        XCTAssertEqual(index.indexed.count, 1)
        XCTAssertEqual(index.indexed.first?.count, 5)
    }

    func testDeletionIsAMutationWhoseRowLeftTheCatalog() {
        catalog = [row("a")]
        binder.catalogDidChange()
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        binder.mutationDidChange(to: "a")
        catalog = []
        binder.mutationDidChange(to: nil)
        XCTAssertEqual(index.deletedIDs.last, [MacSpotlightItemID.make(scope: scope, sessionID: "a")])
    }

    func testRenameIsNotADeletion() {
        catalog = [row("a")]
        binder.catalogDidChange()
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        binder.mutationDidChange(to: "a")
        binder.mutationDidChange(to: nil)
        XCTAssertTrue(index.deletedIDs.isEmpty)
    }
}
```

`HostedTestSupport.settle(_:)` already exists (it spins the run loop for the given seconds). Prefer waiting for a state over settling where possible; the only use here proves a negative (no second call).

- [ ] **Step 2: Run to verify failure**

Run: `TEST MacSpotlightBinderTests`
Expected: build failure, `cannot find 'MacSpotlightBinder' in scope`.

- [ ] **Step 3: Implement**

```swift
import Combine
import Foundation
import SwiftUI

/// Feeds `AppState`'s catalog, scope and deletions to the indexer (D15).
@MainActor
final class MacSpotlightBinder {
    static let shared = MacSpotlightBinder()

    let indexer: MacSpotlightIndexer
    private let debounce: DispatchQueue.SchedulerTimeType.Stride
    private var catalog: () -> [SessionSummary]
    private var deletionDetector = MacSessionDeletionDetector()
    private var pendingSync: DispatchWorkItem?
    private var bindings: Set<AnyCancellable> = []

    init(indexer: MacSpotlightIndexer = MacSpotlightIndexer(index: CoreSpotlightIndex()),
         debounce: DispatchQueue.SchedulerTimeType.Stride = .seconds(2),
         catalog: @escaping () -> [SessionSummary] = { [] }) {
        self.indexer = indexer
        self.debounce = debounce
        self.catalog = catalog
    }

    func catalogDidChange() {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.indexer.catalogChanged(self.catalog())
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce.timeInterval, execute: work)
    }

    func scopeDidChange(_ scope: MacSpotlightScope?) {
        pendingSync?.cancel()
        indexer.setScope(scope, catalog: catalog())
    }

    func mutationDidChange(to id: String?) {
        if let deleted = deletionDetector.mutationChanged(to: id, catalog: catalog()) {
            indexer.sessionDeleted(deleted)
        }
    }

    func bind(to appState: AppState) {
        guard bindings.isEmpty else { return }
        catalog = { [weak appState] in appState?.activeProfileSessions ?? [] }
        let currentScope: () -> MacSpotlightScope? = { [weak appState] in
            guard let appState else { return nil }
            return MacSpotlightScope(dashboardID: appState.activeDashboardID, profile: appState.activeProfile)
        }
        appState.$activeProfile
            .sink { [weak self] _ in DispatchQueue.main.async { self?.scopeDidChange(currentScope()) } }
            .store(in: &bindings)
        appState.$sessions
            .sink { [weak self] _ in DispatchQueue.main.async { self?.catalogDidChange() } }
            .store(in: &bindings)
        appState.$sessionMutationID
            .sink { [weak self] id in DispatchQueue.main.async { self?.mutationDidChange(to: id) } }
            .store(in: &bindings)
        scopeDidChange(currentScope())
    }
}

private extension DispatchQueue.SchedulerTimeType.Stride {
    var timeInterval: TimeInterval { TimeInterval(magnitude) / 1_000_000_000 }
}

extension View {
    func macSpotlightBinding(appState: AppState) -> some View {
        task { MacSpotlightBinder.shared.bind(to: appState) }
    }
}
```

Dashboard switch and sign-out: `activeDashboardID` changes without `activeProfile` changing. Add a fourth subscription on whatever AppState publishes for the dashboard: run `grep -n "activeDashboardID\|savedDashboardRegistry" Conduit/Services/AppState.swift | head`; if there is no publisher, observe `appState.objectWillChange` coalesced with `.debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)` and call `scopeDidChange(currentScope())` (idempotent: `setScope` ignores an unchanged scope). Add a test using the `scopeDidChange` seam with a different `dashboardID`.

One-line wiring in `ConduitMacApp.rootContent`, next to the other tasks:

```swift
            .macSpotlightBinding(appState: appState)
```

Sync note: the binder calls `deleteAll`-style removal only through the indexer; do not index while `appState.isConnected` is false (the catalog may be a stale cached copy): wrap `catalog` in `bind` as `appState.isConnected ? appState.activeProfileSessions : []` only if the manual pass shows stale rows indexing; otherwise leave as written. The `MacSessionDeletionDetector` ordering note from the session-tabs plan applies (`deleteSession` sets `sessionMutationID`, removes the row, clears the id in `defer`; the main-queue hop reads the catalog after removal).

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacSpotlightBinderTests` and `TEST MacSpotlightIndexerTests`.
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Spotlight/MacSpotlightBinder.swift ConduitMac/App/ConduitMacApp.swift ConduitMacTests/MacSpotlightIndexerTests.swift
git commit -m "macOS: bind Spotlight indexer to the session catalog (D15)"
```

### Task 2.5: Open a result (continuation)

**Files:**
- Create: `ConduitMac/Spotlight/MacSpotlightContinuation.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift` (extend the Part 2 modifier line; no second line)
- Test: `ConduitMacTests/MacSpotlightContinuationTests.swift`

**Interfaces:**
- Consumes: `MacSpotlightItemID.parse` (Task 2.2); `ConduitAppLink.session(id:profile:)`; `AppState.openAppLink(_:)`, `activeDashboardID`.
- Produces:
  - `enum MacSpotlightContinuation { enum Outcome: Equatable { case open(ConduitAppLink), foreignDashboard, ignored }; static func outcome(userInfo: [AnyHashable: Any]?, currentDashboardKey: String) -> Outcome }`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreSpotlight
import XCTest
@testable import ConduitMac

final class MacSpotlightContinuationTests: XCTestCase {
    private let scope = MacSpotlightScope(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"), profile: "work")

    private func info(_ id: String) -> [AnyHashable: Any] { [CSSearchableItemActivityIdentifier: id] }

    func testOwnItemOpensTheSessionOnItsProfile() {
        let raw = MacSpotlightItemID.make(scope: scope, sessionID: "sess.1")
        XCTAssertEqual(
            MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: scope.dashboardKey),
            .open(.session(id: "sess.1", profile: "work")))
    }

    func testForeignDashboardIsReportedNotOpened() {
        let raw = MacSpotlightItemID.make(scope: scope, sessionID: "x")
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: info(raw), currentDashboardKey: "other"), .foreignDashboard)
    }

    func testMalformedOrMissingIsIgnored() {
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: info("garbage"), currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: [:], currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: nil, currentDashboardKey: "none"), .ignored)
        XCTAssertEqual(MacSpotlightContinuation.outcome(userInfo: [CSSearchableItemActivityIdentifier: 42], currentDashboardKey: "none"), .ignored)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacSpotlightContinuationTests`
Expected: build failure, `cannot find 'MacSpotlightContinuation' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreSpotlight
import SwiftUI

enum MacSpotlightContinuation {
    enum Outcome: Equatable {
        case open(ConduitAppLink)
        case foreignDashboard
        case ignored
    }

    static func outcome(userInfo: [AnyHashable: Any]?, currentDashboardKey: String) -> Outcome {
        guard let raw = userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = MacSpotlightItemID.parse(raw) else { return .ignored }
        guard id.dashboardKey == currentDashboardKey else { return .foreignDashboard }
        return .open(.session(id: id.sessionID, profile: id.profile))
    }
}
```

Hand the link into the existing connected-then-open path. `ConduitMacApp.pendingExternalLink` is a `@State` on the App struct, so extend the Part 2 modifier instead of adding a second `ConduitMacApp` line: change `.macSpotlightBinding(appState:)` to `.macSpotlightBinding(appState: appState, openLink: { pendingExternalLink = $0 })` and implement it as:

```swift
extension View {
    func macSpotlightBinding(appState: AppState, openLink: @escaping (ConduitAppLink) -> Void) -> some View {
        task { MacSpotlightBinder.shared.bind(to: appState) }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                let key = appState.activeDashboardID?.uuidString ?? "none"
                switch MacSpotlightContinuation.outcome(userInfo: activity.userInfo, currentDashboardKey: key) {
                case .open(let link): openLink(link)
                case .foreignDashboard:
                    appState.errorMessage = AppLocalization.string("That chat belongs to a different Hermes dashboard.")
                case .ignored: break
                }
            }
    }
}
```

`appState.errorMessage` is `@Published var errorMessage: String?` (AppState.swift:1425). The existing external-link task (`externalLinkRouteKey`) drains `pendingExternalLink` once connected and calls `openAppLink`, which switches profile through `routeLinkedSession` when needed and shows "That chat is no longer available." for a deleted chat. A stale result for a deleted session is covered by that path; do not add another.

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacSpotlightContinuationTests`, then the full build.
Expected: pass. Per Task 2.1 Step 2, if a cold-launch Spotlight open does not reach `.onContinueUserActivity` in the manual pass, add the AppKit delegate route and a test for it.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Spotlight/MacSpotlightContinuation.swift ConduitMac/Spotlight/MacSpotlightBinder.swift ConduitMac/App/ConduitMacApp.swift ConduitMacTests/MacSpotlightContinuationTests.swift
git commit -m "macOS: open a chat from a Spotlight result (D15)"
```

### Task 2.6: Settings toggle, localization, docs

There is no Mac-only Settings Privacy pane: Settings is the shared `SettingsView` (`Conduit/Views/AuxiliaryViews.swift`; its home list has `homeSection(AppLocalization.string("On this device"), ...)`, about line 882). The toggle therefore lives in a Mac view under `ConduitMac/Views/` shown through one gated insertion there.

**Files:**
- Create: `ConduitMac/Views/MacSpotlightSettingsRow.swift`
- Modify: `Conduit/Views/AuxiliaryViews.swift` (one `#if os(macOS) // MAC:` block), `docs/macos/PORTING_LEDGER.md`, `docs/macos/DECISIONS.md`, `docs/macos/SMOKE_CHECKLIST.md`, `Conduit/Localizable.xcstrings` (via `scripts/l10n.py`)
- Test: add `MacSpotlightSettingsTests` to `ConduitMacTests/MacSpotlightIndexerTests.swift`

**Interfaces:**
- Consumes: `MacSpotlightBinder.shared.indexer` (`isEnabled`, `setEnabled(_:catalog:)`, `removeAll()`), `AppState.activeProfileSessions`.
- Produces:
  - `@MainActor final class MacSpotlightSettingsModel: ObservableObject` with `init(indexer:catalog:)`, `@Published var isOn: Bool`, `func setOn(_:)`, `func removeAll()`
  - `struct MacSpotlightSettingsRow: View` (toggle "Show chats in Spotlight" + button "Remove from Spotlight" + footnote)

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
final class MacSpotlightSettingsTests: XCTestCase {
    func testToggleOnIndexesAndOffRemovesEverything() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let fake = FakeSearchableIndex()
        let indexer = MacSpotlightIndexer(index: fake, defaults: suite.defaults)
        indexer.setScope(MacSpotlightScope(dashboardID: nil, profile: "default"), catalog: [])
        let catalog = [SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A", lastActivityAt: 1)]
        let model = MacSpotlightSettingsModel(indexer: indexer, catalog: { catalog })
        XCTAssertFalse(model.isOn, "off by default")
        model.setOn(true)
        XCTAssertEqual(fake.indexed.last?.count, 1)
        XCTAssertTrue(suite.defaults.bool(forKey: MacSpotlightIndexer.enabledKey))
        model.setOn(false)
        XCTAssertEqual(fake.deleteAllCount, 1)
        XCTAssertFalse(suite.defaults.bool(forKey: MacSpotlightIndexer.enabledKey))
    }

    func testRemoveAllButtonDeletesWithoutChangingTheToggle() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let fake = FakeSearchableIndex()
        let model = MacSpotlightSettingsModel(indexer: MacSpotlightIndexer(index: fake, defaults: suite.defaults), catalog: { [] })
        model.setOn(true)
        model.removeAll()
        XCTAssertEqual(fake.deleteAllCount, 1)
        XCTAssertTrue(model.isOn)
    }
}
```

Note the second test: `removeAll()` in the indexer clears snapshots, so with the toggle still on the next catalog change re-indexes the visible rows. That is the intended meaning of "Remove from Spotlight" while enabled; the footnote says so ("Chats you open or rename are added again while this is on").

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacSpotlightSettingsTests`
Expected: build failure, `cannot find 'MacSpotlightSettingsModel' in scope`.

- [ ] **Step 3: Implement the model and row**

```swift
import SwiftUI

@MainActor
final class MacSpotlightSettingsModel: ObservableObject {
    @Published private(set) var isOn: Bool
    private let indexer: MacSpotlightIndexer
    private let catalog: () -> [SessionSummary]

    init(indexer: MacSpotlightIndexer, catalog: @escaping () -> [SessionSummary]) {
        self.indexer = indexer
        self.catalog = catalog
        self.isOn = indexer.isEnabled
    }

    func setOn(_ on: Bool) {
        indexer.setEnabled(on, catalog: catalog())
        isOn = on
    }

    func removeAll() { indexer.removeAll() }
}

struct MacSpotlightSettingsRow: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model: MacSpotlightSettingsModel

    init() {
        _model = StateObject(wrappedValue: MacSpotlightSettingsModel(
            indexer: MacSpotlightBinder.shared.indexer,
            catalog: { [] }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(AppLocalization.string("Show chats in Spotlight"), isOn: Binding(
                get: { model.isOn }, set: { model.setOn($0) }))
            Text(AppLocalization.string("Chat titles and message counts, not message text. Titles can contain sensitive words; this is off by default."))
                .font(.footnote).foregroundStyle(.secondary)
            Button(AppLocalization.string("Remove from Spotlight")) { model.removeAll() }
        }
        .padding(.horizontal, 10)
    }
}
```

`MacSpotlightSettingsRow` must hand the live catalog to the model. Because `@EnvironmentObject` is unavailable in `init`, store the model's `catalog` closure after appear: add `var catalog: () -> [SessionSummary]` as a `var` on the model and set it in `.onAppear { model.catalog = { appState.activeProfileSessions } }`, or have `MacSpotlightBinder` own a `liveCatalog()` accessor set in `bind(to:)` and pass `MacSpotlightBinder.shared.currentCatalog` here. Prefer the second (one source of truth); add `var currentCatalog: () -> [SessionSummary] { catalog }` to the binder.

Gate in `Conduit/Views/AuxiliaryViews.swift`, inside the `homeSection(AppLocalization.string("On this device"), ...)` closure, after the `settingsLink(.about, ...)` line:

```swift
                        #if os(macOS) // MAC: Spotlight opt-in (D15)
                        MacSpotlightSettingsRow()
                        #endif // MAC:
```

If `homeSection`'s content builder rejects `#if` around a view, wrap the row in a Mac-only `Group`; if `SettingsView.homeSection` is not the Mac Settings entry (check `grep -n "settingsLink" Conduit/Views/AuxiliaryViews.swift | head` and how `RootView` line 199 presents it), put the row where the Mac user actually finds privacy settings (the "About & privacy" page) and record the choice in D15.

Ledger row (follow the table format; rule is an additive gate, as the RootView tab gate was recorded):

`| Conduit/Views/AuxiliaryViews.swift (SettingsView home, "On this device") | R3 gate | MacSpotlightSettingsRow added on Mac (D15, Spotlight opt-in); iOS path unchanged |`

- [ ] **Step 4: Localize**

New strings: `Show chats in Spotlight`, `Remove from Spotlight`, the footnote, `%lld messages` (plural, Task 2.2), `That chat belongs to a different Hermes dashboard.`. Add every key for every shipped language through `scripts/l10n.py` (see `docs/LOCALIZATION.md`), then run `python3 scripts/check-l10n-coverage.py --repo-root .` and expect no missing entries.

- [ ] **Step 5: Docs**

D15 paragraph: Spotlight is opt-in and metadata-only (titles can hold sensitive text; message text would also need a per-session fetch); mirrors the loaded catalog best-effort; absence is not deletion; per-profile domain so a profile switch is one domain delete; identifier format and why not dots; Task 2.1 verified API names and SDK version (27.0); rejected alternatives (`NSUserActivity.isEligibleForSearch`, an importer plugin).

SMOKE_CHECKLIST "System integration: Spotlight":
- [ ] Settings shows "Show chats in Spotlight", off by default
- [ ] Turn on, wait a few seconds, Cmd-Space a chat title: the chat is listed
- [ ] Open the result with Conduit closed: Conduit opens on that chat once connected
- [ ] Rename a chat: Spotlight shows the new title; delete a chat: its result disappears
- [ ] Switch profile: the other profile's chats are listed, the first profile's are gone
- [ ] Turn off: searching the title finds nothing; "Remove from Spotlight" empties the index while on

- [ ] **Step 6: Full verification and commit**

Run: full build; full `ConduitMacTests`; iOS build check; `git diff <base> -- Conduit Shared | grep '^-[^-]'` shows no removed line.

```bash
git add ConduitMac/Views/MacSpotlightSettingsRow.swift Conduit/Views/AuxiliaryViews.swift docs/macos/PORTING_LEDGER.md docs/macos/DECISIONS.md docs/macos/SMOKE_CHECKLIST.md Conduit/Localizable.xcstrings ConduitMacTests/MacSpotlightIndexerTests.swift ConduitMac/Spotlight/MacSpotlightBinder.swift
git commit -m "macOS: Spotlight opt-in setting, docs, localization (D15)"
```

---

# Part 3: Shortcuts / App Intents

### Task 3.1: Verify App Intents on Mac and the provider constraints (no product code)

**Files:** none (record findings in Task 3.5's `DECISIONS.md` entry).

- [ ] **Step 1: Confirm what already compiles on Mac**

Run: `grep -n "Intents" project.yml` (expect no exclude naming `Conduit/Intents/`), then the build command from Global Constraints and `grep -c "warning:.*AppIntents\|appintentsmetadataprocessor" <build log>`. Expected: build succeeds; note any existing metadata warnings so new ones are distinguishable.

- [ ] **Step 2: Check the AppIntents API names in the SDK**

Run: `SDK=$(xcrun --show-sdk-path); find "$SDK/System/Library/Frameworks/AppIntents.framework" -name '*.swiftinterface' | head -2` then grep the macOS swiftinterface for `EntityStringQuery`, `IntentModes`, `supportedModes`, `openAppWhenRun`, `AppShortcutsBuilder`, `IntentDialog`, `CustomLocalizedStringResourceConvertible`. Record availability annotations (`macOS 14` vs `macOS 26`). If the swiftinterface is not under the SDK, use `https://developer.apple.com/documentation/appintents` for each name.

- [ ] **Step 3: Check the provider builder accepts `#if os(macOS)`**

In a scratch package in the scratchpad directory (not the repo), or by a throwaway edit reverted before commit, confirm `static var appShortcuts: [AppShortcut]` with a builder body accepts a `#if os(macOS)` block that adds an `AppShortcut`. Also confirm whether `AppShortcut(intent: OpenSessionIntent(), ...)` is allowed when the intent has a required, non-optional parameter and the phrases do not reference it. Record the answer: if not allowed, Task 3.5 skips the `OpenSessionIntent` shortcut entry (the action stays available in the Shortcuts app and Spotlight actions through the entity, just without a Siri phrase).

- [ ] **Step 4: Confirm the in-process hand-off**

Intents compiled into the app run in the app process on macOS (no extension), so `MacIntentInbox.shared` set in `perform()` reaches the running app. Confirm via the existing `StartVoiceConversationIntent` path (`PendingVoiceIntentStore.shared.enqueue` drained by `ConduitMacApp`). Record any `openAppWhenRun` behavior difference on macOS 14/15 vs the macOS 26 `supportedModes`.

No commit.

### Task 3.2: Inbox, data source, and routing

**Files:**
- Create: `ConduitMac/Intents/MacIntentInbox.swift`, `ConduitMac/Intents/MacIntentDataSource.swift`, `ConduitMac/Intents/MacIntentRouting.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift` (one line)
- Test: `ConduitMacTests/MacIntentInboxTests.swift`

**Interfaces:**
- Consumes: `MacNewChatPrefiller.live(_:)` (Task 0.1); `AppState.isConnected`, `switchProfile(to:)`, `openAppLink(_:)`, `activeProfile`, `activeProfileSessions`.
- Produces:
  - `enum MacIntentRequest: Equatable { case newChat(profile: String?, message: String?); case openSession(id: String, profile: String?) }`
  - `@MainActor final class MacIntentInbox: ObservableObject` with `static let shared`, `@Published private(set) var revision: Int`, `func enqueue(_ r: MacIntentRequest)`, `func take() -> MacIntentRequest?`, `var hasPending: Bool`; one slot, last write wins
  - `@MainActor final class MacIntentDataSource` with `static let shared`, `func bind(to appState: AppState)`, `var sessions: [SessionSummary]`, `var isAvailable: Bool`
  - `struct MacIntentRouting: ViewModifier`; `extension View { func macIntentRouting(appState: AppState) -> some View }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacIntentInboxTests: XCTestCase {
    func testLastWriteWinsAndTakeIsOneShot() {
        let inbox = MacIntentInbox()
        inbox.enqueue(.newChat(profile: nil, message: "a"))
        inbox.enqueue(.openSession(id: "s", profile: "p"))
        XCTAssertEqual(inbox.take(), .openSession(id: "s", profile: "p"))
        XCTAssertNil(inbox.take())
        XCTAssertFalse(inbox.hasPending)
    }

    func testEnqueueBumpsRevision() {
        let inbox = MacIntentInbox()
        let before = inbox.revision
        inbox.enqueue(.newChat(profile: nil, message: nil))
        XCTAssertGreaterThan(inbox.revision, before)
    }

    func testDataSourceIsEmptyAndUnavailableBeforeBinding() {
        let source = MacIntentDataSource()
        XCTAssertTrue(source.sessions.isEmpty)
        XCTAssertFalse(source.isAvailable)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && TEST MacIntentInboxTests`
Expected: build failure, `cannot find 'MacIntentInbox' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum MacIntentRequest: Equatable {
    case newChat(profile: String?, message: String?)
    case openSession(id: String, profile: String?)
}

/// What a Shortcuts action asked Conduit to do, parked until Hermes is
/// connected (D15). One slot; the intents are foreground actions, so the
/// newest request is the one the user is looking at.
@MainActor
final class MacIntentInbox: ObservableObject {
    static let shared = MacIntentInbox()

    @Published private(set) var revision = 0
    private var pending: MacIntentRequest?

    var hasPending: Bool { pending != nil }

    func enqueue(_ request: MacIntentRequest) {
        pending = request
        revision += 1
    }

    func take() -> MacIntentRequest? {
        defer { pending = nil }
        return pending
    }
}
```

```swift
import Foundation

/// Read access for intent queries to the live catalog. The app owns the only
/// AppState; this holds it weakly and answers empty when the app is not
/// running or not bound yet (entity resolution by id still works without it).
@MainActor
final class MacIntentDataSource {
    static let shared = MacIntentDataSource()

    private weak var appState: AppState?

    var isAvailable: Bool { appState != nil }
    var sessions: [SessionSummary] { appState?.activeProfileSessions ?? [] }
    var activeProfile: String? { appState?.activeProfile }

    func bind(to appState: AppState) { self.appState = appState }
}
```

```swift
import AppKit
import SwiftUI

/// Applies a parked intent request once Hermes is connected (D15).
struct MacIntentRouting: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var inbox: MacIntentInbox

    init(appState: AppState, inbox: MacIntentInbox = .shared) {
        self.appState = appState
        self.inbox = inbox
    }

    func body(content: Content) -> some View {
        content
            .task { MacIntentDataSource.shared.bind(to: appState) }
            .task(id: "\(inbox.revision):\(appState.isConnected)") {
                guard appState.isConnected, let request = inbox.take() else { return }
                MacServiceRouting.bringConduitForward()
                await MacIntentRouting.apply(request, appState: appState)
            }
    }

    @MainActor
    static func apply(_ request: MacIntentRequest, appState: AppState) async {
        switch request {
        case .newChat(let profile, let message):
            if let profile, profile != appState.activeProfile {
                await appState.switchProfile(to: profile)
                guard appState.activeProfile == profile else { return }
            }
            if let message, !message.isEmpty {
                _ = await MacNewChatPrefiller.live(appState).run(message)
            } else {
                await appState.createNewSession()
            }
        case .openSession(let id, let profile):
            appState.openAppLink(.session(id: id, profile: profile))
        }
    }
}

extension View {
    func macIntentRouting(appState: AppState) -> some View {
        modifier(MacIntentRouting(appState: appState))
    }
}
```

`MacServiceRouting.bringConduitForward()` is Part 1's. If Part 3 merges before Part 1, move `bringConduitForward()` into Part 0's `MacNewChatPrefiller.swift` as `static func bringConduitForward()` on a small `MacWindowActivation` enum and have both parts call it; do this as part of Task 0.1 instead if the parts start together. Pick one before the worktrees fork.

One-line wiring in `ConduitMacApp.rootContent`:

```swift
            .macIntentRouting(appState: appState)
```

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacIntentInboxTests`, then the full build.
Expected: pass; build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Intents ConduitMac/App/ConduitMacApp.swift ConduitMacTests/MacIntentInboxTests.swift
git commit -m "macOS: intent inbox, data source and routing (D15)"
```

### Task 3.3: NewChatIntent

**Files:**
- Create: `ConduitMac/Intents/NewChatIntent.swift`
- Test: `ConduitMacTests/MacNewChatIntentTests.swift`

**Interfaces:**
- Consumes: `MacIntentInbox.shared.enqueue`, `ConduitProfileEntity` (`id`, `displayName`; `Conduit/Intents/StartVoiceConversationIntent.swift`).
- Produces:
  - `struct NewChatIntent: AppIntent` with `@Parameter profile: ConduitProfileEntity?`, `@Parameter message: String?`, `init()`, `init(profile:message:)`
  - `enum NewChatIntentCore { static func request(profileID: String?, message: String?, knownProfiles: [String]) throws -> MacIntentRequest }`
  - `enum MacIntentError: Error, CustomLocalizedStringResourceConvertible { case unknownProfile(String); case unknownChat }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacNewChatIntentTests: XCTestCase {
    func testNoProfileNoMessage() throws {
        XCTAssertEqual(try NewChatIntentCore.request(profileID: nil, message: nil, knownProfiles: ["default"]),
                       .newChat(profile: nil, message: nil))
    }

    func testKnownProfileAndMessagePassThrough() throws {
        XCTAssertEqual(try NewChatIntentCore.request(profileID: "work", message: "hi", knownProfiles: ["default", "work"]),
                       .newChat(profile: "work", message: "hi"))
    }

    func testBlankMessageBecomesNil() throws {
        XCTAssertEqual(try NewChatIntentCore.request(profileID: nil, message: "  \n", knownProfiles: []),
                       .newChat(profile: nil, message: nil))
    }

    func testUnknownProfileThrowsAUserVisibleError() {
        XCTAssertThrowsError(try NewChatIntentCore.request(profileID: "gone", message: "x", knownProfiles: ["default"])) { error in
            guard case MacIntentError.unknownProfile("gone") = error else { return XCTFail("\(error)") }
        }
    }

    func testMessageIsCappedLikeAService() throws {
        let long = String(repeating: "a", count: MacServiceText.limit + 10)
        let request = try NewChatIntentCore.request(profileID: nil, message: long, knownProfiles: [])
        guard case .newChat(_, let text?) = request else { return XCTFail() }
        XCTAssertTrue(text.hasSuffix("[truncated]"))
    }

    @MainActor
    func testPerformEnqueuesAndNeverSends() async throws {
        MacIntentInbox.shared.take()
        let intent = NewChatIntent(profile: nil, message: "draft")
        _ = try await intent.perform()
        XCTAssertEqual(MacIntentInbox.shared.take(), .newChat(profile: nil, message: "draft"))
    }
}
```

`testMessageIsCappedLikeAService` reuses `MacServiceText` from Part 1. If Part 3 starts before Part 1 merges, hoist `MacServiceText` into Part 0 (`ConduitMac/App/MacServiceText.swift`) and change Task 1.2 to consume it; decide with the Task 3.2 `bringConduitForward` hoist.

- [ ] **Step 2: Run to verify failure**

Run: `TEST MacNewChatIntentTests`
Expected: build failure, `cannot find 'NewChatIntentCore' in scope`.

- [ ] **Step 3: Implement**

Mirror `StartVoiceConversationIntent` (read `Conduit/Intents/StartVoiceConversationIntent.swift` lines 49 to 85 first): the literal `openAppWhenRun`, the `supportedModes` redeclaration with `@available(iOS 26.0, macOS 26.0, *)`. In `ConduitMac/` the iOS clauses are unnecessary: this file only compiles on Mac, so the availability line is `@available(macOS 26.0, *)` with no `// MAC:` tag (it is Mac-only code).

```swift
import AppIntents
import Foundation

enum MacIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unknownProfile(String)
    case unknownChat

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unknownProfile(let name): return "Conduit has no profile named \(name)."
        case .unknownChat: return "That chat is no longer available."
        }
    }
}

enum NewChatIntentCore {
    static func request(profileID: String?, message: String?, knownProfiles: [String]) throws -> MacIntentRequest {
        if let profileID, !knownProfiles.contains(profileID) { throw MacIntentError.unknownProfile(profileID) }
        return .newChat(profile: profileID, message: MacServiceText.normalize(message))
    }
}

struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Conduit Chat"
    static var description = IntentDescription(
        "Open Conduit on a new chat, optionally with text in the message box. The text is never sent for you.")

    static var openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Profile") var profile: ConduitProfileEntity?
    @Parameter(title: "Message") var message: String?

    init() {}
    init(profile: ConduitProfileEntity?, message: String?) {
        self.profile = profile
        self.message = message
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let known = (try await ConduitProfileEntityQuery().suggestedEntities()).map(\.id)
        let request = try NewChatIntentCore.request(profileID: profile?.id, message: message, knownProfiles: known)
        MacIntentInbox.shared.enqueue(request)
        return .result()
    }
}
```

`ConduitProfileEntityQuery.profiles()` is `private`; `suggestedEntities()` is its public face and reads `conduit.knownProfiles.v1` from `UserDefaults.standard`, the same list Siri uses. If `@available(macOS 26.0, *)` on a stored `static var` conflicts with the metadata processor (the processor rejects computed values only for `openAppWhenRun`), follow Task 3.1 Step 2 findings.

- [ ] **Step 4: Run to verify pass**

Run: `TEST MacNewChatIntentTests`, then the full build and check the build log: `grep -n "appintentsmetadataprocessor" <log>` shows no warning mentioning `NewChatIntent`.
Expected: pass; no metadata warnings.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Intents/NewChatIntent.swift ConduitMacTests/MacNewChatIntentTests.swift
git commit -m "macOS: New Conduit Chat intent (D15)"
```

### Task 3.4: Session entity and OpenSessionIntent

**Files:**
- Create: `ConduitMac/Intents/ConduitSessionEntity.swift`, `ConduitMac/Intents/OpenSessionIntent.swift`
- Test: `ConduitMacTests/ConduitSessionEntityTests.swift`

**Interfaces:**
- Consumes: `MacIntentDataSource.shared`, `MacIntentInbox.shared`, `SessionSummary` (`id`, `title`, `profile`).
- Produces:
  - `struct ConduitSessionEntity: AppEntity, Identifiable` (`id: String`, `title: String`, `profile: String?`)
  - `enum ConduitSessionCatalog { static func suggestions(_ sessions: [SessionSummary], limit: Int) -> [ConduitSessionEntity]; static func resolve(_ ids: [String], in sessions: [SessionSummary]) -> [ConduitSessionEntity]; static func matching(_ text: String, in sessions: [SessionSummary]) -> [ConduitSessionEntity] }`
  - `struct ConduitSessionEntityQuery: EntityStringQuery`
  - `struct OpenSessionIntent: AppIntent` with `@Parameter session: ConduitSessionEntity`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class ConduitSessionEntityTests: XCTestCase {
    private func s(_ id: String, _ title: String, profile: String? = "default", at: TimeInterval = 1) -> SessionSummary {
        SessionSummary.macTestSummary(id: id, alternateIds: [], title: title, profile: profile, lastActivityAt: at)
    }
    private let catalog: [SessionSummary] = []

    func testSuggestionsAreNewestFirstAndLimited() {
        let list = [s("a", "A", at: 1), s("b", "B", at: 3), s("c", "C", at: 2)]
        XCTAssertEqual(ConduitSessionCatalog.suggestions(list, limit: 2).map(\.id), ["b", "c"])
    }

    func testResolveByIdWorksWithAnEmptyCatalog() {
        let resolved = ConduitSessionCatalog.resolve(["x"], in: [])
        XCTAssertEqual(resolved.map(\.id), ["x"], "a saved shortcut must resolve when the app was just launched")
    }

    func testResolveUsesTheTitleWhenListedAndMatchesAlternateIds() {
        let row = SessionSummary.macTestSummary(id: "real", alternateIds: ["draft"], title: "Real", lastActivityAt: 1)
        XCTAssertEqual(ConduitSessionCatalog.resolve(["draft"], in: [row]).first?.id, "real")
        XCTAssertEqual(ConduitSessionCatalog.resolve(["real"], in: [row]).first?.title, "Real")
    }

    func testMatchingIsCaseInsensitiveOnTitle() {
        let list = [s("a", "Laravel queues"), s("b", "Swift tips")]
        XCTAssertEqual(ConduitSessionCatalog.matching("LARA", in: list).map(\.id), ["a"])
        XCTAssertEqual(ConduitSessionCatalog.matching("", in: list).count, 2)
    }

    func testBlankTitleDisplaysAFallback() {
        XCTAssertFalse(ConduitSessionCatalog.suggestions([s("a", "  ")], limit: 5).first!.title.isEmpty)
    }
}
```

Extend `SessionSummary.macTestSummary` with an optional `profile: String? = nil` parameter (default keeps callers compiling) in `ConduitMacTests/MacSessionTabsStoreTests.swift`; if Part 2 also edits that helper, merge both parameter lists.

- [ ] **Step 2: Run to verify failure**

Run: `TEST ConduitSessionEntityTests`
Expected: build failure, `cannot find 'ConduitSessionCatalog' in scope`.

- [ ] **Step 3: Implement**

```swift
import AppIntents
import Foundation

enum ConduitSessionCatalog {
    static func displayTitle(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? AppLocalization.string("New conversation") : t
    }

    private static func entity(_ s: SessionSummary) -> ConduitSessionEntity {
        ConduitSessionEntity(id: s.id, title: displayTitle(s.title), profile: s.profile)
    }

    static func suggestions(_ sessions: [SessionSummary], limit: Int) -> [ConduitSessionEntity] {
        sessions
            .sorted { ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0) }
            .prefix(limit).map(entity)
    }

    /// Resolves saved ids. An id the catalog does not list still resolves (the
    /// app may have just launched, or the chat is on an unloaded page);
    /// opening it reports "That chat is no longer available." if it is gone.
    static func resolve(_ ids: [String], in sessions: [SessionSummary]) -> [ConduitSessionEntity] {
        ids.map { id in
            if let row = sessions.first(where: { $0.id == id || $0.alternateIds.contains(id) }) { return entity(row) }
            return ConduitSessionEntity(id: id, title: AppLocalization.string("Conduit chat"), profile: nil)
        }
    }

    static func matching(_ text: String, in sessions: [SessionSummary]) -> [ConduitSessionEntity] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = needle.isEmpty ? sessions : sessions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        return suggestions(rows, limit: 50)
    }
}

struct ConduitSessionEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conduit chat")
    static var defaultQuery = ConduitSessionEntityQuery()

    let id: String
    let title: String
    let profile: String?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct ConduitSessionEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ConduitSessionEntity] {
        ConduitSessionCatalog.resolve(identifiers, in: MacIntentDataSource.shared.sessions)
    }

    @MainActor func entities(matching string: String) async throws -> [ConduitSessionEntity] {
        ConduitSessionCatalog.matching(string, in: MacIntentDataSource.shared.sessions)
    }

    @MainActor func suggestedEntities() async throws -> [ConduitSessionEntity] {
        ConduitSessionCatalog.suggestions(MacIntentDataSource.shared.sessions, limit: 25)
    }
}
```

```swift
import AppIntents

struct OpenSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Conduit Chat"
    static var description = IntentDescription("Open a chat in Conduit.")

    static var openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Chat") var session: ConduitSessionEntity

    init() {}
    init(session: ConduitSessionEntity) { self.session = session }

    @MainActor
    func perform() async throws -> some IntentResult {
        MacIntentInbox.shared.enqueue(.openSession(id: session.id, profile: session.profile))
        return .result()
    }
}
```

The entity's `profile` is nil when resolved without the catalog; `openAppLink(.session(id:profile: nil))` opens on the active profile, and a chat on another profile then reports unavailable. That is acceptable for v1; record it in D15.

- [ ] **Step 4: Run to verify pass**

Run: `TEST ConduitSessionEntityTests`, then the full build and the metadata-warning check from Task 3.3 Step 4.
Expected: pass; no warnings.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Intents/ConduitSessionEntity.swift ConduitMac/Intents/OpenSessionIntent.swift ConduitMacTests/ConduitSessionEntityTests.swift ConduitMacTests/MacSessionTabsStoreTests.swift
git commit -m "macOS: Open Conduit Chat intent and session entity (D15)"
```

### Task 3.5: Shortcut entries, localization, docs

**Files:**
- Modify: `Conduit/Intents/StartVoiceConversationIntent.swift` (gated entries inside `ConduitVoiceShortcuts.appShortcuts`), `Conduit/AppShortcuts.xcstrings`, `docs/macos/PORTING_LEDGER.md`, `docs/macos/DECISIONS.md`, `docs/macos/SMOKE_CHECKLIST.md`, `Conduit/Localizable.xcstrings`

- [ ] **Step 1: Add the gated shortcut entries**

Inside `ConduitVoiceShortcuts.appShortcuts`, after the existing `AppShortcut(...)`:

```swift
        #if os(macOS) // MAC: Mac-only intents live in ConduitMac/Intents (D15)
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a new chat in \(.applicationName)",
                "New \(.applicationName) chat"
            ],
            shortTitle: "New Conduit Chat",
            systemImageName: "square.and.pencil"
        )
        #endif // MAC:
```

Add an `OpenSessionIntent` entry the same way only if Task 3.1 Step 3 found it allowed (required parameter, no parameter in the phrases); otherwise omit it. Count: the provider has 1 plus these, well under the limit of 10. Every phrase contains `\(.applicationName)`. Do not use `\(\.$session)` in a phrase (sessions are chosen in the Shortcuts UI in v1, so `updateAppShortcutParameters()` needs no new call site).

Ledger row:

`| Conduit/Intents/StartVoiceConversationIntent.swift (ConduitVoiceShortcuts.appShortcuts) | R3 gate | Mac-only AppShortcut entries for NewChatIntent (and OpenSessionIntent if allowed); one provider per app, intents live in ConduitMac/Intents; iOS path unchanged |`

If the iOS build fails because the file `ConduitMac/Intents/` types are not visible, that confirms the gate is needed on the right lines; check `#if os(macOS)` is balanced.

- [ ] **Step 2: Localize**

Phrases and short titles go in `Conduit/AppShortcuts.xcstrings` (existing entries such as `"Talk to ${applicationName}"` show the key format: `${applicationName}` replaces `\(.applicationName)`). Intent titles, descriptions, parameter titles and the entity type name (`New Conduit Chat`, `Open Conduit Chat`, `Profile`, `Message`, `Chat`, `Conduit chat`, the two `MacIntentError` messages) go in whichever catalog the existing `Talk to Conduit` title lives in (`grep -n '"Talk to Conduit"' Conduit/*.xcstrings` showed `Conduit/AppShortcuts.xcstrings`); follow the same file. Add every key for every shipped language via `scripts/l10n.py export/import --create`, then `python3 scripts/check-l10n-coverage.py --repo-root .`.

- [ ] **Step 3: Docs**

D15 paragraph: the intents are Mac-only and live in `ConduitMac/Intents/` (no iOS exposure, no ledger row for the intent files themselves); `NewChatIntent` prefills, never sends; `OpenSessionIntent` resolves saved ids without a catalog; one provider means the entries are added to `ConduitVoiceShortcuts` behind a gate; the Task 3.1 findings; "Ask Hermes returns reply" is deferred: it needs an AppState entry point that runs a headless turn and returns the final text, with a 120 s timeout, a disconnected error and "Needs approval in Conduit" failure instead of waiting on an approval prompt.

SMOKE_CHECKLIST "System integration: Shortcuts":
- [ ] Shortcuts app lists "New Conduit Chat" and "Open Conduit Chat" under Conduit on macOS 14 and on macOS 26
- [ ] Run "New Conduit Chat" with Conduit closed and with a Message: Conduit opens a new chat with the text in the composer, not sent
- [ ] Same with a Profile that is not active: the profile switches first
- [ ] Run "Open Conduit Chat" with a chat picked from the list; with Conduit closed; with a deleted chat (shows "That chat is no longer available.")
- [ ] Spotlight (Cmd-Space) shows the app shortcut "New Conduit Chat"
- [ ] The existing "Ask Hermes About Screen" shortcut and "Talk to Conduit" still run

- [ ] **Step 4: Full verification and commit**

Run: full build; full `ConduitMacTests`; iOS build check; `git diff <base> -- Conduit Shared | grep '^-[^-]'` shows no removed line; the build log has no new App Intents metadata warning.

```bash
git add Conduit/Intents/StartVoiceConversationIntent.swift Conduit/AppShortcuts.xcstrings Conduit/Localizable.xcstrings docs/macos/PORTING_LEDGER.md docs/macos/DECISIONS.md docs/macos/SMOKE_CHECKLIST.md
git commit -m "macOS: register New Conduit Chat shortcut, docs, localization (D15)"
```

---

## Follow-ups (not in this plan)

- `AskHermesIntent` (returns the reply): needs a spike for a headless turn entry point on `AppState`, approval handling, and the shared connection (spec open question 4).
- Indexing message text in Spotlight (needs a per-session fetch and a privacy decision).
- Quick Actions beyond App Shortcuts; Services for files, images and URLs.

## Self-review notes

- Spec coverage: Services behaviour and architecture (Tasks 1.2, 1.3), Services testing (1.2, 1.3, 1.4 smoke); Spotlight behaviour, deindex rules, open path, settings (2.2 to 2.6); Shortcuts intents 1 and 2, data source, provider, security (3.2 to 3.5); docs and ledger (1.4, 2.6, 3.5). Spec's "3 only after a spike" intent is excluded as instructed.
- Deviations from the spec, all deliberate and recorded in the tasks: `createNewSession()` is awaitable, so no polling and no "prefill the current chat" fallback (a refused create prefills nothing); the decision record is D15, not D12 (taken); Spotlight identifiers use `|` not dots; the Spotlight toggle lives in the shared `SettingsView` through one gate because no Mac Privacy pane exists.
