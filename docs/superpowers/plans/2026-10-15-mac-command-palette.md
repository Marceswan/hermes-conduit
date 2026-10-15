# Mac Command Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Cmd-K, in-window command palette on the Mac app that jumps to sessions, runs slash commands, switches profile, opens the model picker, changes pane, and runs New Chat / Settings / sidebar / update commands, entirely from the keyboard.

**Architecture:** Pure-Swift item, matcher, recents and provider layers (no AppKit, no `AppState`) feed a main-actor `MacPaletteStore` that owns query, sections and selection. Actions are an `Equatable` enum dispatched through an injectable `MacPaletteCalls` closure struct, so tests never touch `AppState`. A SwiftUI overlay (`MacPaletteView`) is attached in `ConduitMacApp.rootContent` around `RootView`; a Go menu item in `ConduitCommands` toggles it. The only upstream edit is one gated `RootView` observer that opens Settings.

**Tech Stack:** Swift 6 / SwiftUI / AppKit on macOS 14+, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-15-mac-command-palette-design.md` (approved; its open questions are resolved to the spec's own proposed defaults, see "Resolved Decisions").

## Global Constraints

- Mac only. Never run an iOS build or iOS tests (project scope). iOS behaviour is unchanged.
- New code lives under `ConduitMac/Palette/`; tests under `ConduitMacTests/`.
- Any edit to a shared `Conduit/` or `Shared/` file is wrapped in `#if os(macOS) // MAC: <reason>` ... `#endif // MAC:` and gets one row in `docs/macos/PORTING_LEDGER.md`. `git diff <base> -- Conduit Shared | grep '^-[^-]'` must print nothing (zero removed lines). Only the Settings observer in `Conduit/Views/RootView.swift` is planned (Task 5); no `AppState.swift` edits.
- The working tree has unrelated uncommitted edits in `Conduit/Services/AppState.swift` and `Conduit/Views/ChatView.swift`. Never stage them: never run `git add -A` or `git add .`; add explicit file paths only. Never revert or reformat them.
- After adding any file run `xcodegen generate` (`ConduitMac/` is picked up by the folder glob in `project.yml`).
- Build: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`
- Test one class: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/<ClassName>`. Never run two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- zsh: quote every glob and every path containing `*`, `[`, `?` (for example `git add 'ConduitMac/Palette/MacPaletteItem.swift'`, `grep -rn "x" 'ConduitMac/**/*.swift'`).
- TDD: failing test, run to see it fail, minimal implementation, run to see it pass, commit.
- Tests: injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`, `settle`), explicit teardown, no fixed sleeps. Never touch the live app's defaults. The user's own Conduit may be running: do not quit, click or type into it.
- Localization (docs/LOCALIZATION.md): every user-visible string is `AppLocalization.string("...")` (or a SwiftUI literal for `Text`/`Button` titles) with an English source key; no `String` ternary branches with raw literals; no singular built in code. Task 8 adds the keys to `Conduit/Localizable.xcstrings` for every shipped language through `scripts/l10n.py` and runs `scripts/check-l10n-coverage.py`.
- Palette never sends free text as a prompt. It only dispatches existing app actions. Cmd-K does nothing while a sheet is attached (`MacKeyboardActions.commandsBlocked(by:)`); items that open a sheet close the palette first.
- Look: 560 pt wide, at most 9 visible rows, scrollable, flat-pill rows, `Color.conduitAccent` selection with dark foreground (same contrast rule as `MacSessionTabButton`), scrim behind, no second glass layer (D7).
- Data limits: recents max 20 ids (`kind:id`), shown Recent section max 8; result list capped at 50 rows; empty-query slash section collapsed to 5; fuzzy needs at least 3 query characters.
- Persistence key: `conduit.mac.palette.recents.<dashboardID or "none">.<profile>` (same scope as `conduit.mac.sessionTabs.*`).

## Resolved Decisions (spec open questions, spec defaults)

1. Model rows: v1 is one command "Switch Model..." that sets `appState.showModelPicker = true`. No inline model list.
2. Slash command with `argsHint`: close the palette, put `/name ` in the composer, focused, do not execute. Verified: `AppState.prefillComposer(_:)` already exists (AppState.swift ~6794), so no AppState edit and no gate. Note it REPLACES the composer draft (it does not append).
3. Sessions: loaded catalog only. No server search.
4. Settings: spec proposed `settingsLinkRequest`; verified it only carries `ConduitAppLink.SettingsLink` pages (`calls`, `voice`), so it cannot open Settings at its start. Use a gated `RootView` observer for `.macOpenSettingsRequested` (Task 5), one ledger row.
5. Tab commands (Close Tab, Reopen Closed Tab, open tabs first): out of scope for v1.

## Review Focus

1. Return while an IME is composing in the search field must confirm the composition and not run the row. Use `TextField.onSubmit`, never a raw `.return` key handler. Test in Task 6.
2. The catalog or profile changing while the palette is open (a session finishes, a profile switch replaces the slash list): the selected row may vanish. Selection must re-clamp to the first enabled row and never point at a missing id. Test in Task 4.
3. Zero results, or only disabled results: Return does nothing, Up/Down do not crash, the empty state is shown. Test in Tasks 4 and 6.
4. A bare prefix (`>`, `/`, `@`, `#`), a whitespace-only query, and a prefix typed after text (`a/b`) behave as specified: bare prefix lists that whole scope, whitespace-only equals empty, mid-text prefix is plain text. Test in Task 3.
5. Cmd-K from the composer with a draft: draft untouched, focus returns on close; Cmd-K with a sheet up does nothing; Cmd-K from a non-chat window (Settings window) does nothing. Test in Task 7.
6. A very large catalog (5000 sessions): at most 50 rows are produced and the matcher stays single-pass. Test in Task 1.

## File Map

- Create `ConduitMac/Palette/MacPaletteItem.swift`: kinds, action enum, item, section, scope parsing (Task 1, scope in Task 3).
- Create `ConduitMac/Palette/MacPaletteMatcher.swift`: pure scoring and ranking (Task 1).
- Create `ConduitMac/Palette/MacPaletteRecents.swift`: recents value type plus `UserDefaults` store (Task 2).
- Create `ConduitMac/Palette/MacPaletteProvider.swift`: snapshot, item building, scoping, empty-query sections (Task 3).
- Create `ConduitMac/Palette/MacPaletteStore.swift`: `MacPaletteCalls`, dispatcher, store (Task 4).
- Create `ConduitMac/Palette/MacPaletteBinding.swift`: `bind(to: AppState)`, live calls, snapshot (Task 5).
- Create `ConduitMac/Palette/MacPaletteView.swift`: overlay view (Task 6).
- Modify `ConduitMac/App/MacKeyboardShortcuts.swift`: `MacPaletteActions` beside `MacSessionTabsActions` (Task 5).
- Modify `ConduitMac/App/MacChatRoute.swift` or the file that declares `.macSessionOpenRequested`: add `.macOpenSettingsRequested` (Task 5).
- Modify `Conduit/Views/RootView.swift`: one gated Settings observer (Task 5).
- Modify `ConduitMac/App/ConduitMacApp.swift`: bind store, attach overlay, pass store to commands (Tasks 5, 7).
- Modify `ConduitMac/App/ConduitCommands.swift`: Go > Command Palette, Cmd-K (Task 7).
- Tests: `ConduitMacTests/MacPaletteMatcherTests.swift`, `MacPaletteRecentsTests.swift`, `MacPaletteProviderTests.swift`, `MacPaletteStoreTests.swift`, `MacPaletteBindingTests.swift`, `MacPaletteViewTests.swift`, `MacPaletteCommandsTests.swift`; shared fixtures `MacPaletteFixtures.swift`; update `MacKeyboardTests.swift` (menu table).
- Docs: `docs/macos/DECISIONS.md` (D15, D10 table row), `docs/macos/PORTING_LEDGER.md`, `docs/macos/SMOKE_CHECKLIST.md`; localization entries in `Conduit/Localizable.xcstrings` (Task 8).

Existing facts the tasks rely on (verified in the repo):
- `MacSessionCursor.moved(_ move: Move, from base: String?, in ids: [String]) -> String?`, `Move { up, down, first, last }`, stops at ends (`MacKeyboardShortcuts.swift`).
- `MacKeyboardActions.commandsBlocked(by:)`, `.selectTab(_:window:defaults:)`, `.focusSessionSearch(defaults:requests:)`, `.focusComposer(window:...)`.
- `MacSessionTabsActions.isMainChatWindow(_:)`; `SessionSummary.macMatches(_:)` (tabs store); test helper `SessionSummary.macTestSummary(id:alternateIds:title:)` at the bottom of `ConduitMacTests/MacSessionTabsStoreTests.swift`; `AccessibilityProbe` in `ConduitMacTests/HostedTestSupport.swift`.
- `ComposerTextView` (`ConduitMac/Chat/ComposerPasteTextView.swift`) is the composer's `NSTextView`.
- `AppState`: `activeProfileSessions`, `isSessionUnread(_:)`, `activeSessionId`, `slashCommands`, `profiles`, `activeProfile`, `activeDashboardID`, `isBusy`, `prefillComposer(_:)`, `executeSlashCommand(_:context:)`, `switchProfile(to:)`, `showModelPicker`, `createNewSession(cwd:widgetLease:)`, `cancelCurrent() -> Bool`, `requestOpenSession(_:onFailure:)`, `dismissSidebarDrawer()`.
- `SlashCommand { name, aliases, description, category, argsHint }`; `SessionSummary.lastActivityAt` is epoch seconds (`TimeInterval?`); `SessionSummary.isUnread` is optional and not authoritative (use `isSessionUnread`); `SessionSummary` has no `category` property.
- `SidebarTab` cases `sessions, bots, cron, kanban` with `displayName`; `MacSidebarState.defaultsKey`, `.tabDefaultsKey`, `.toggleVisible(defaults:)`; `MacUpdater.shared.checkForUpdates()` and `canCheckForUpdates`.

---

### Task 1: Item types and matcher

**Files:**
- Create: `ConduitMac/Palette/MacPaletteItem.swift`, `ConduitMac/Palette/MacPaletteMatcher.swift`
- Create: `ConduitMacTests/MacPaletteFixtures.swift`
- Test: `ConduitMacTests/MacPaletteMatcherTests.swift`

**Interfaces:**
- Produces:
  - `enum MacPaletteKind: String, CaseIterable { case session, slash, profile, model, pane, command }`
  - `enum MacPaletteAction: Equatable { case openSession(String), runSlash(String), insertSlash(String), switchProfile(String), openModelPicker, selectPane(SidebarTab), newChat, openSettings, toggleSidebar, stopResponse, searchSessions, checkForUpdates }`
  - `struct MacPaletteItem: Identifiable, Equatable { let id: String; let kind: MacPaletteKind; var title: String; var subtitle: String; var keywords: [String]; var isEnabled: Bool; var disabledReason: String?; var isCurrent: Bool; var isUnread: Bool; var isActiveSession: Bool; var lastActivityAt: TimeInterval?; var action: MacPaletteAction }` with a memberwise `init` whose defaults are `subtitle: ""`, `keywords: []`, `isEnabled: true`, `disabledReason: nil`, `isCurrent: false`, `isUnread: false`, `isActiveSession: false`, `lastActivityAt: nil`
  - `struct MacPaletteSection: Equatable { let title: String?; let items: [MacPaletteItem] }`
  - `enum MacPaletteMatcher` with `static let rowLimit = 50`, `static func normalize(_:) -> String`, `static func recencyBoost(rank: Int?) -> Int`, `static func rank(_ items: [MacPaletteItem], query: String, recentIDs: [String], now: Date) -> [MacPaletteItem]`

- [ ] **Step 1: Write the fixtures and failing tests**

`ConduitMacTests/MacPaletteFixtures.swift`:

```swift
import Foundation
@testable import ConduitMac

extension MacPaletteItem {
    /// A command-kind item with a stable id, for matcher tests.
    static func fixture(
        _ title: String,
        kind: MacPaletteKind = .command,
        id: String? = nil,
        keywords: [String] = [],
        enabled: Bool = true,
        unread: Bool = false,
        active: Bool = false,
        lastActivityAt: TimeInterval? = nil
    ) -> MacPaletteItem {
        MacPaletteItem(
            id: id ?? "\(kind.rawValue):\(title)", kind: kind, title: title, keywords: keywords,
            isEnabled: enabled, isUnread: unread, isActiveSession: active,
            lastActivityAt: lastActivityAt, action: .newChat
        )
    }
}

extension SessionSummary {
    /// A palette-test session: `macTestSummary` plus the fields the palette reads.
    static func paletteFixture(
        id: String, title: String, model: String = "", archived: Bool = false,
        pinned: Bool? = nil, lastActivityAt: TimeInterval? = nil
    ) -> SessionSummary {
        var s = SessionSummary.macTestSummary(id: id, alternateIds: [], title: title)
        s.model = model
        s.isArchived = archived
        s.isPinned = pinned
        s.lastActivityAt = lastActivityAt
        return s
    }
}
```

`ConduitMacTests/MacPaletteMatcherTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class MacPaletteMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ranked(_ items: [MacPaletteItem], _ query: String, recents: [String] = []) -> [String] {
        MacPaletteMatcher.rank(items, query: query, recentIDs: recents, now: now).map(\.title)
    }

    func testTierOrderExactPrefixWordStartSubstringFuzzyKeyword() {
        let items = [
            MacPaletteItem.fixture("Zebra", keywords: ["settings"]),       // keyword
            .fixture("Sound effects tab"),                                  // fuzzy s-e-t
            .fixture("Reset"),                                              // substring
            .fixture("Chat Settings"),                                      // word start
            .fixture("Settings"),                                           // prefix
            .fixture("Set"),                                                // exact
        ]
        XCTAssertEqual(ranked(items, "set"),
                       ["Set", "Settings", "Chat Settings", "Reset", "Sound effects tab", "Zebra"])
    }

    func testCaseAndDiacriticInsensitive() {
        let items = [MacPaletteItem.fixture("Caf\u{E9} Menu")]
        XCTAssertEqual(ranked(items, "CAFE"), ["Caf\u{E9} Menu"])
        XCTAssertEqual(ranked([.fixture("cafe")], "Caf\u{E9}"), ["cafe"])
    }

    func testAllTokensMustMatchAndShortFuzzyDoesNot() {
        let items = [MacPaletteItem.fixture("New Chat")]
        XCTAssertEqual(ranked(items, "new ch"), ["New Chat"])
        XCTAssertEqual(ranked(items, "  new   ch  "), ["New Chat"])
        XCTAssertEqual(ranked(items, "new xx"), [])
        XCTAssertEqual(ranked(items, "nc"), [], "fuzzy needs 3 characters")
        XCTAssertEqual(ranked(items, "nch"), ["New Chat"], "3 characters fuzzy-match in order")
        XCTAssertEqual(ranked(items, "hcn"), [], "out of order never matches")
    }

    func testSlashTitleMatchesWithoutItsSlash() {
        let items = [MacPaletteItem.fixture("/model", kind: .slash), .fixture("Model Picker")]
        XCTAssertEqual(ranked(items, "model"), ["/model", "Model Picker"], "exact beats prefix")
    }

    func testKindWeightsBreakTiesWithinATier() {
        let items = ["session", "profile", "slash", "pane", "command"].map { kind in
            MacPaletteItem.fixture("Alpha", kind: MacPaletteKind(rawValue: kind)!, id: "\(kind):x")
        }
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "alpha", recentIDs: [], now: now).map(\.id),
                       ["command:x", "pane:x", "slash:x", "profile:x", "session:x"])
    }

    func testRecencyBoostDecaysAndNeverCrossesATier() {
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 0), 60)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 1), 54)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 9), 6)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: 10), 0)
        XCTAssertEqual(MacPaletteMatcher.recencyBoost(rank: nil), 0)

        let both = [MacPaletteItem.fixture("Beta one", id: "b"), .fixture("Alpha one", id: "a")]
        XCTAssertEqual(ranked(both, "one", recents: ["b"]), ["Beta one", "Alpha one"], "recent wins a tie")
        let tiers = [MacPaletteItem.fixture("Open", id: "o"), .fixture("Reopen", id: "r")]
        XCTAssertEqual(ranked(tiers, "open", recents: ["r"]), ["Open", "Reopen"], "exact still beats a recent substring")
    }

    func testTieBreaksRecencyThenTitleThenID() {
        let items = [MacPaletteItem.fixture("Same", id: "z"), .fixture("Same", id: "a"), .fixture("Same", id: "m")]
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "same", recentIDs: [], now: now).map(\.id), ["a", "m", "z"])
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "same", recentIDs: ["m"], now: now).map(\.id), ["m", "a", "z"])
    }

    func testDisabledRanksLastWithinItsTier() {
        let items = [MacPaletteItem.fixture("Alpha disabled", id: "d", enabled: false), .fixture("Alpha enabled", id: "e")]
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "alpha", recentIDs: ["d"], now: now).map(\.id), ["e", "d"])
        let tiers = [MacPaletteItem.fixture("Alpha", id: "x", enabled: false), .fixture("Big alpha", id: "y")]
        XCTAssertEqual(MacPaletteMatcher.rank(tiers, query: "alpha", recentIDs: [], now: now).map(\.id), ["x", "y"],
                       "a disabled exact match still beats an enabled word-start match")
    }

    func testSessionActivityBoost() {
        let day: TimeInterval = 86_400
        let items = [
            MacPaletteItem.fixture("Chat plain", kind: .session, id: "session:plain"),
            .fixture("Chat unread", kind: .session, id: "session:unread", unread: true),
            .fixture("Chat fresh", kind: .session, id: "session:fresh", lastActivityAt: now.timeIntervalSince1970 - 3600),
            .fixture("Chat active", kind: .session, id: "session:active", unread: true, active: true,
                     lastActivityAt: now.timeIntervalSince1970 - 60),
            .fixture("Chat old", kind: .session, id: "session:old", lastActivityAt: now.timeIntervalSince1970 - 3 * day),
        ]
        // unread +10, fresh +5, then the zero-boost rows by title: active, old, plain
        XCTAssertEqual(MacPaletteMatcher.rank(items, query: "chat", recentIDs: [], now: now).map(\.id),
                       ["session:unread", "session:fresh", "session:active", "session:old", "session:plain"])
    }

    func testCapAtFiftyAndLargeCatalog() {
        let items = (0..<5000).map { MacPaletteItem.fixture("Session \($0)", kind: .session, id: "session:\($0)") }
        let result = MacPaletteMatcher.rank(items, query: "session", recentIDs: [], now: now)
        XCTAssertEqual(result.count, MacPaletteMatcher.rowLimit)
        XCTAssertEqual(MacPaletteMatcher.rowLimit, 50)
    }

    func testEmptyOrWhitespaceQueryRanksNothing() {
        XCTAssertEqual(ranked([.fixture("Alpha")], ""), [])
        XCTAssertEqual(ranked([.fixture("Alpha")], "   "), [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPaletteMatcherTests`
Expected: build failure, `cannot find type 'MacPaletteItem' in scope`.

- [ ] **Step 3: Implement**

`ConduitMac/Palette/MacPaletteItem.swift`:

```swift
import Foundation

enum MacPaletteKind: String, CaseIterable {
    case session, slash, profile, model, pane, command
}

/// What running a row does. Equatable so tests assert it directly; the store
/// dispatches it through `MacPaletteCalls` (Task 4).
enum MacPaletteAction: Equatable {
    case openSession(String)
    case runSlash(String)
    case insertSlash(String)
    case switchProfile(String)
    case openModelPicker
    case selectPane(SidebarTab)
    case newChat
    case openSettings
    case toggleSidebar
    case stopResponse
    case searchSessions
    case checkForUpdates
}

struct MacPaletteItem: Identifiable, Equatable {
    /// "kind:rawID", stable across rebuilds (recents key on it).
    let id: String
    let kind: MacPaletteKind
    var title: String
    var subtitle: String = ""
    var keywords: [String] = []
    var isEnabled = true
    var disabledReason: String?
    /// The active profile's check row.
    var isCurrent = false
    var isUnread = false
    var isActiveSession = false
    var lastActivityAt: TimeInterval?
    var action: MacPaletteAction
}

struct MacPaletteSection: Equatable {
    let title: String?
    let items: [MacPaletteItem]
}
```

`ConduitMac/Palette/MacPaletteMatcher.swift`:

```swift
import Foundation

/// Pure scoring and ranking for the command palette (D15). No AppKit, no AppState.
enum MacPaletteMatcher {
    static let rowLimit = 50
    static let fuzzyMinimumLength = 3

    /// Highest first. Tier values are 1000 apart so no bonus crosses a tier.
    enum Tier: Int {
        case keyword = 1, fuzzy, substring, wordStart, prefix, exact
    }

    struct Match: Equatable {
        let tier: Tier
        /// Within-tier detail, always below 1000.
        let detail: Int
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func tokens(of query: String) -> [String] {
        normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Slash titles match without their leading "/".
    static func matchTitle(of item: MacPaletteItem) -> String {
        normalize(item.title.hasPrefix("/") ? String(item.title.dropFirst()) : item.title)
    }

    static func recencyBoost(rank: Int?) -> Int {
        guard let rank else { return 0 }
        return max(0, 60 - 6 * rank)
    }

    private static func kindWeight(_ kind: MacPaletteKind) -> Int {
        switch kind {
        case .command, .model: return 30
        case .slash, .pane: return 20
        case .profile: return 10
        case .session: return 0
        }
    }

    private static func activityBoost(_ item: MacPaletteItem, now: Date) -> Int {
        guard item.kind == .session, !item.isActiveSession else { return 0 }
        var boost = item.isUnread ? 10 : 0
        if let last = item.lastActivityAt, now.timeIntervalSince1970 - last <= 86_400 { boost += 5 }
        return boost
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Greedy in-order subsequence. Returns the number of skipped characters
    /// between the first and last matched one, nil when not a subsequence.
    private static func fuzzyGaps(_ query: String, in title: String) -> Int? {
        var needle = query.makeIterator()
        guard var wanted = needle.next() else { return nil }
        var first: Int?, last = 0
        for (offset, character) in title.enumerated() where character == wanted {
            if first == nil { first = offset }
            last = offset
            guard let next = needle.next() else { return last - (first ?? 0) + 1 - query.count }
            wanted = next
        }
        return nil
    }

    static func match(tokens: [String], item: MacPaletteItem) -> Match? {
        guard !tokens.isEmpty else { return nil }
        let title = matchTitle(of: item)
        let joined = tokens.joined(separator: " ")
        if title == joined { return Match(tier: .exact, detail: 0) }
        if title.hasPrefix(joined) { return Match(tier: .prefix, detail: 0) }
        let titleWords = words(of: title)
        if tokens.allSatisfy({ token in titleWords.contains { $0.hasPrefix(token) } }) {
            return Match(tier: .wordStart, detail: 0)
        }
        if tokens.allSatisfy({ title.contains($0) }) {
            let position = title.range(of: tokens[0]).map { title.distance(from: title.startIndex, to: $0.lowerBound) } ?? 0
            return Match(tier: .substring, detail: max(0, 100 - position))
        }
        if tokens.count == 1, tokens[0].count >= fuzzyMinimumLength, let gaps = fuzzyGaps(tokens[0], in: title) {
            return Match(tier: .fuzzy, detail: max(0, 150 - gaps * 10))
        }
        let haystack = normalize(item.keywords.joined(separator: " "))
        if !haystack.isEmpty, tokens.allSatisfy({ haystack.contains($0) }) {
            return Match(tier: .keyword, detail: 0)
        }
        return nil
    }

    /// Matching items, best first, at most `rowLimit`. An empty query ranks
    /// nothing (the provider builds the empty-query sections).
    /// `recentIDs` is most recent first and already limited to existing items.
    static func rank(_ items: [MacPaletteItem], query: String, recentIDs: [String], now: Date) -> [MacPaletteItem] {
        let tokens = tokens(of: query)
        guard !tokens.isEmpty else { return [] }
        let recentRank = Dictionary(recentIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        struct Scored { let item: MacPaletteItem; let tier: Int; let score: Int; let recent: Int }
        var scored: [Scored] = []
        scored.reserveCapacity(min(items.count, 256))
        for item in items {
            guard let match = match(tokens: tokens, item: item) else { continue }
            let rank = recentRank[item.id]
            let score = match.tier.rawValue * 1000 + match.detail + kindWeight(item.kind)
                + recencyBoost(rank: rank) + activityBoost(item, now: now)
            scored.append(Scored(item: item, tier: match.tier.rawValue, score: score, recent: rank ?? Int.max))
        }
        scored.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.item.isEnabled != b.item.isEnabled { return a.item.isEnabled }
            if a.score != b.score { return a.score > b.score }
            if a.recent != b.recent { return a.recent < b.recent }
            if a.item.title != b.item.title { return a.item.title < b.item.title }
            return a.item.id < b.item.id
        }
        return scored.prefix(rowLimit).map(\.item)
    }
}
```

Check: the fuzzy gap formula returns `last - first + 1 - query.count` (skipped characters). Verify `"Sound effects tab"` matches "set" and `"New Chat"` matches "nch", `"hcn"` does not. If `testTierOrder...` shows "Sound effects tab" in the substring tier, recheck that "sound effects tab" contains no "set" substring (it does not).

- [ ] **Step 4: Run to verify pass**

Run the Step 2 command. Expected: all `MacPaletteMatcherTests` pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Palette/MacPaletteItem.swift' 'ConduitMac/Palette/MacPaletteMatcher.swift' 'ConduitMacTests/MacPaletteFixtures.swift' 'ConduitMacTests/MacPaletteMatcherTests.swift'
git commit -m "macOS: command palette item types and matcher (D15)"
```

---

### Task 2: Recents

**Files:**
- Create: `ConduitMac/Palette/MacPaletteRecents.swift`
- Test: `ConduitMacTests/MacPaletteRecentsTests.swift`

**Interfaces:**
- Consumes: `MacPaletteItem` (Task 1).
- Produces:
  - `struct MacPaletteRecents: Equatable { static let limit = 20; static let shownLimit = 8; private(set) var ids: [String]; init(ids: [String] = []); mutating func record(_ id: String); func resolved(in items: [MacPaletteItem]) -> [MacPaletteItem] }` (`resolved` returns existing items in recency order, unlimited; the provider applies `shownLimit`)
  - `struct MacPaletteRecentsStore { init(defaults: UserDefaults); static func storageKey(dashboardID: UUID?, profile: String) -> String; func load(dashboardID: UUID?, profile: String) -> MacPaletteRecents; func save(_ recents: MacPaletteRecents, dashboardID: UUID?, profile: String) }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacPaletteRecentsTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() { suite = HostedTestSupport.makeSuite() }
    override func tearDown() { HostedTestSupport.dropSuite(suite) }

    func testRecordMovesToFrontAndDedupes() {
        var r = MacPaletteRecents()
        r.record("command:a"); r.record("slash:b"); r.record("command:a")
        XCTAssertEqual(r.ids, ["command:a", "slash:b"])
    }

    func testCapsAtTwenty() {
        var r = MacPaletteRecents()
        for i in 0..<25 { r.record("command:\(i)") }
        XCTAssertEqual(r.ids.count, MacPaletteRecents.limit)
        XCTAssertEqual(r.ids.first, "command:24")
        XCTAssertEqual(r.ids.last, "command:5")
    }

    func testInitClampsAndDedupes() {
        let r = MacPaletteRecents(ids: (0..<30).map { "command:\($0 % 25)" })
        XCTAssertEqual(r.ids.count, MacPaletteRecents.limit)
        XCTAssertEqual(Set(r.ids).count, r.ids.count)
    }

    func testResolvedDropsItemsThatNoLongerExistInRecencyOrder() {
        var r = MacPaletteRecents()
        r.record("session:a"); r.record("slash:b"); r.record("session:gone")   // most recent first: gone, b, a
        let items = [MacPaletteItem.fixture("A", kind: .session, id: "session:a"), .fixture("B", kind: .slash, id: "slash:b")]
        XCTAssertEqual(r.resolved(in: items).map(\.id), ["slash:b", "session:a"])
    }

    func testStorageKeyAndPerScopePersistence() {
        let dashboard = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertEqual(MacPaletteRecentsStore.storageKey(dashboardID: dashboard, profile: "default"),
                       "conduit.mac.palette.recents.00000000-0000-0000-0000-000000000002.default")
        XCTAssertEqual(MacPaletteRecentsStore.storageKey(dashboardID: nil, profile: "work"), "conduit.mac.palette.recents.none.work")

        let store = MacPaletteRecentsStore(defaults: suite.defaults)
        var a = MacPaletteRecents(); a.record("command:x")
        store.save(a, dashboardID: nil, profile: "default")
        XCTAssertEqual(store.load(dashboardID: nil, profile: "default").ids, ["command:x"])
        XCTAssertEqual(store.load(dashboardID: nil, profile: "work").ids, [])
        XCTAssertEqual(MacPaletteRecentsStore(defaults: suite.defaults).load(dashboardID: nil, profile: "default").ids, ["command:x"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPaletteRecentsTests`
Expected: build failure, `cannot find 'MacPaletteRecents' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The palette's recently run items, most recent first (D15). Pure value type.
struct MacPaletteRecents: Equatable {
    static let limit = 20
    static let shownLimit = 8

    private(set) var ids: [String]

    init(ids: [String] = []) {
        var seen = Set<String>()
        self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(Self.limit))
    }

    mutating func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }

    /// The recents whose item still exists, in recency order. This is how
    /// deleted sessions and slash commands of another profile drop out on
    /// read; the stored list is not rewritten (the session catalog is paged,
    /// so "not loaded" is not "gone").
    func resolved(in items: [MacPaletteItem]) -> [MacPaletteItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}

/// Persists recents per dashboard and profile, in an injected suite.
struct MacPaletteRecentsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func storageKey(dashboardID: UUID?, profile: String) -> String {
        "conduit.mac.palette.recents.\(dashboardID?.uuidString ?? "none").\(profile)"
    }

    func load(dashboardID: UUID?, profile: String) -> MacPaletteRecents {
        MacPaletteRecents(ids: defaults.stringArray(forKey: Self.storageKey(dashboardID: dashboardID, profile: profile)) ?? [])
    }

    func save(_ recents: MacPaletteRecents, dashboardID: UUID?, profile: String) {
        defaults.set(recents.ids, forKey: Self.storageKey(dashboardID: dashboardID, profile: profile))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run the Step 2 command. Expected: all `MacPaletteRecentsTests` pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Palette/MacPaletteRecents.swift' 'ConduitMacTests/MacPaletteRecentsTests.swift'
git commit -m "macOS: command palette recents (D15)"
```

---

### Task 3: Provider, scoping and empty-query sections

**Files:**
- Create: `ConduitMac/Palette/MacPaletteProvider.swift`
- Test: `ConduitMacTests/MacPaletteProviderTests.swift`

**Interfaces:**
- Consumes: `MacPaletteItem`, `MacPaletteAction`, `MacPaletteSection`, `MacPaletteKind` (Task 1); `MacPaletteRecents.shownLimit` (Task 2); `SessionSummary.macMatches(_:)`; `SlashCommand`; `SidebarTab`.
- Produces:
  - `struct MacPaletteSnapshot { var sessions: [SessionSummary]; var unreadSessionIDs: Set<String>; var activeSessionID: String?; var slashCommands: [SlashCommand]; var profiles: [String]; var activeProfile: String; var isTurnRunning: Bool; var sidebarVisible: Bool; var canCheckForUpdates: Bool; var dashboardID: UUID?; static let empty }` (memberwise `init` with defaults: `sessions: []`, `unreadSessionIDs: []`, `activeSessionID: nil`, `slashCommands: []`, `profiles: []`, `activeProfile: "default"`, `isTurnRunning: false`, `sidebarVisible: true`, `canCheckForUpdates: true`, `dashboardID: nil`)
  - `enum MacPaletteScope: Equatable { case all, slash, commands, profiles, sessions; static func parse(_ raw: String) -> (scope: MacPaletteScope, text: String); func includes(_ kind: MacPaletteKind) -> Bool }`
  - `enum MacPaletteProvider { static let collapsedSlashCount = 5; static func items(_ snapshot: MacPaletteSnapshot) -> [MacPaletteItem]; static func sections(items: [MacPaletteItem], recents: [MacPaletteItem]) -> [MacPaletteSection] }`
  - Item id formats: `session:<id>`, `slash:<name>`, `profile:<name>`, `model:switch`, `pane:<SidebarTab.rawValue>`, `command:newChat|settings|toggleSidebar|stopResponse|searchSessions|checkForUpdates`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacPaletteProviderTests: XCTestCase {
    private func snapshot(
        sessions: [SessionSummary] = [], active: String? = nil, slash: [SlashCommand] = [],
        profiles: [String] = ["default"], activeProfile: String = "default", running: Bool = false,
        sidebar: Bool = true, unread: Set<String> = []
    ) -> MacPaletteSnapshot {
        MacPaletteSnapshot(
            sessions: sessions, unreadSessionIDs: unread, activeSessionID: active, slashCommands: slash,
            profiles: profiles, activeProfile: activeProfile, isTurnRunning: running, sidebarVisible: sidebar
        )
    }

    private func items(_ s: MacPaletteSnapshot) -> [String: MacPaletteItem] {
        Dictionary(MacPaletteProvider.items(s).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func testSessionsExcludeArchivedAndCarryKeywordsAndFlags() {
        let a = SessionSummary.paletteFixture(id: "a", title: "Laravel", model: "gpt-x", lastActivityAt: 5)
        let b = SessionSummary.paletteFixture(id: "b", title: "Old", archived: true)
        let all = items(snapshot(sessions: [a, b], active: "a", unread: ["a"]))
        XCTAssertNil(all["session:b"])
        let item = try! XCTUnwrap(all["session:a"])
        XCTAssertEqual(item.title, "Laravel")
        XCTAssertEqual(item.action, .openSession("a"))
        XCTAssertTrue(item.keywords.contains("gpt-x") && item.keywords.contains("a"))
        XCTAssertTrue(item.isActiveSession && item.isUnread)
        XCTAssertEqual(item.lastActivityAt, 5)
    }

    func testSessionMatchesActiveIDThroughAlternateIDs() {
        var s = SessionSummary.paletteFixture(id: "real", title: "T")
        s.alternateIds = ["draft"]
        XCTAssertTrue(try! XCTUnwrap(items(snapshot(sessions: [s], active: "draft"))["session:real"]).isActiveSession)
    }

    func testPinnedSessionsComeFirstInCatalogOrder() {
        let list = [SessionSummary.paletteFixture(id: "1", title: "One"), .paletteFixture(id: "2", title: "Two", pinned: true),
                    .paletteFixture(id: "3", title: "Three")]
        XCTAssertEqual(MacPaletteProvider.items(snapshot(sessions: list)).filter { $0.kind == .session }.map(\.id),
                       ["session:2", "session:1", "session:3"])
    }

    func testSlashFollowsCatalogAndMapsArgsHintToInsert() {
        let slash = [SlashCommand(name: "new", description: "Start over"),
                     SlashCommand(name: "title", aliases: ["rename"], description: "Rename", argsHint: "<name>")]
        let all = items(snapshot(active: "a", slash: slash))
        XCTAssertEqual(all["slash:new"]?.action, .runSlash("new"))
        XCTAssertEqual(all["slash:title"]?.action, .insertSlash("title"))
        XCTAssertEqual(all["slash:title"]?.title, "/title")
        XCTAssertTrue(all["slash:title"]!.keywords.contains("rename"))
        XCTAssertEqual(items(snapshot(active: "a", slash: [slash[0]])).keys.filter { $0.hasPrefix("slash:") }.sorted(), ["slash:new"])
    }

    func testNoActiveSessionDisablesSlashWithReason() {
        let all = items(snapshot(active: nil, slash: [SlashCommand(name: "new", description: "")]))
        XCTAssertEqual(all["slash:new"]?.isEnabled, false)
        XCTAssertEqual(all["slash:new"]?.disabledReason, AppLocalization.string("No active chat"))
        XCTAssertEqual(items(snapshot(active: "a", slash: [SlashCommand(name: "new", description: "")]))["slash:new"]?.isEnabled, true)
    }

    func testActiveProfileIsACheckRowAndNotRunnable() {
        let all = items(snapshot(profiles: ["default", "work"], activeProfile: "work"))
        XCTAssertEqual(all["profile:work"]?.isCurrent, true)
        XCTAssertEqual(all["profile:work"]?.isEnabled, false)
        XCTAssertEqual(all["profile:default"]?.action, .switchProfile("default"))
        XCTAssertEqual(all["profile:default"]?.isEnabled, true)
        XCTAssertNotNil(items(snapshot(profiles: [], activeProfile: "solo"))["profile:solo"], "falls back to [activeProfile]")
    }

    func testPanesModelAndStaticCommands() {
        let all = items(snapshot())
        for tab in SidebarTab.allCases { XCTAssertEqual(all["pane:\(tab.rawValue)"]?.action, .selectPane(tab)) }
        XCTAssertEqual(all["model:switch"]?.action, .openModelPicker)
        XCTAssertEqual(all["command:newChat"]?.action, .newChat)
        XCTAssertEqual(all["command:settings"]?.action, .openSettings)
        XCTAssertEqual(all["command:searchSessions"]?.action, .searchSessions)
        XCTAssertEqual(all["command:checkForUpdates"]?.action, .checkForUpdates)
        XCTAssertEqual(all["command:toggleSidebar"]?.action, .toggleSidebar)
    }

    func testToggleSidebarTitleFollowsVisibilityAndStopOnlyWhileRunning() {
        XCTAssertEqual(items(snapshot(sidebar: true))["command:toggleSidebar"]?.title, AppLocalization.string("Hide Sidebar"))
        XCTAssertEqual(items(snapshot(sidebar: false))["command:toggleSidebar"]?.title, AppLocalization.string("Show Sidebar"))
        XCTAssertNil(items(snapshot(running: false))["command:stopResponse"])
        XCTAssertEqual(items(snapshot(running: true))["command:stopResponse"]?.action, .stopResponse)
    }

    func testCheckForUpdatesDisabledWhenUnavailable() {
        var s = snapshot(); s.canCheckForUpdates = false
        XCTAssertEqual(items(s)["command:checkForUpdates"]?.isEnabled, false)
    }

    func testScopeParsing() {
        XCTAssertTrue(MacPaletteScope.parse("/mod") == (.slash, "mod"))
        XCTAssertTrue(MacPaletteScope.parse(">new") == (.commands, "new"))
        XCTAssertTrue(MacPaletteScope.parse("@wo") == (.profiles, "wo"))
        XCTAssertTrue(MacPaletteScope.parse("#lar") == (.sessions, "lar"))
        XCTAssertTrue(MacPaletteScope.parse("  >new") == (.commands, "new"))
        XCTAssertTrue(MacPaletteScope.parse("a/b") == (.all, "a/b"), "a prefix after text is plain text")
        XCTAssertTrue(MacPaletteScope.parse(">") == (.commands, ""), "a bare prefix lists the whole scope")
        XCTAssertTrue(MacPaletteScope.parse("   ") == (.all, ""))
        XCTAssertTrue(MacPaletteScope.parse("") == (.all, ""))
    }

    func testScopeInclusion() {
        XCTAssertTrue(MacPaletteScope.commands.includes(.command) && MacPaletteScope.commands.includes(.pane) && MacPaletteScope.commands.includes(.model))
        XCTAssertFalse(MacPaletteScope.commands.includes(.session))
        XCTAssertTrue(MacPaletteScope.slash.includes(.slash) && !MacPaletteScope.slash.includes(.command))
        XCTAssertTrue(MacPaletteScope.profiles.includes(.profile) && !MacPaletteScope.profiles.includes(.slash))
        XCTAssertTrue(MacPaletteScope.sessions.includes(.session) && !MacPaletteScope.sessions.includes(.profile))
        XCTAssertTrue(MacPaletteKind.allCases.allSatisfy(MacPaletteScope.all.includes))
    }

    func testEmptyQuerySectionsOrderDedupeAndCollapse() {
        let slash = (1...8).map { SlashCommand(name: "c\($0)", description: "") }
        let sessions = (1...3).map { SessionSummary.paletteFixture(id: "s\($0)", title: "S\($0)") }
        let built = MacPaletteProvider.items(snapshot(sessions: sessions, active: "s1", slash: slash))
        let recent = built.filter { $0.id == "session:s2" || $0.id == "command:newChat" }
        let sections = MacPaletteProvider.sections(items: built, recents: recent)
        XCTAssertEqual(sections.map(\.title), [AppLocalization.string("Recent"), AppLocalization.string("Commands"),
                                              AppLocalization.string("Slash Commands"), AppLocalization.string("Chats")])
        XCTAssertEqual(sections[0].items.map(\.id), ["session:s2", "command:newChat"])
        XCTAssertFalse(sections[1].items.contains { $0.id == "command:newChat" }, "a recent row is not repeated")
        XCTAssertEqual(sections[2].items.count, MacPaletteProvider.collapsedSlashCount)
        XCTAssertEqual(sections[3].items.map(\.id), ["session:s1", "session:s3"])
        XCTAssertLessThanOrEqual(sections.flatMap(\.items).count, MacPaletteMatcher.rowLimit)
    }

    func testRecentSectionIsCappedAtEightAndOmittedWhenEmpty() {
        let built = MacPaletteProvider.items(snapshot())
        XCTAssertFalse(MacPaletteProvider.sections(items: built, recents: []).contains { $0.title == AppLocalization.string("Recent") })
        let many = Array(built.prefix(12))
        XCTAssertEqual(MacPaletteProvider.sections(items: built, recents: many)[0].items.count, MacPaletteRecents.shownLimit)
    }

    func testEmptyQueryCapsTotalRowsAtFifty() {
        let sessions = (0..<500).map { SessionSummary.paletteFixture(id: "s\($0)", title: "S\($0)") }
        let built = MacPaletteProvider.items(snapshot(sessions: sessions))
        XCTAssertEqual(MacPaletteProvider.sections(items: built, recents: []).flatMap(\.items).count, MacPaletteMatcher.rowLimit)
    }
}
```

`MacPaletteScope.parse` returns a tuple; the `==` on two labelled tuples works for Equatable members. If the compiler rejects comparing `(scope:text:)` with an unlabelled tuple, compare `.scope` and `.text` separately.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPaletteProviderTests`
Expected: build failure, `cannot find 'MacPaletteSnapshot' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Everything the provider reads, copied out of AppState so the provider is
/// pure and tests build snapshots by hand (D15).
struct MacPaletteSnapshot {
    var sessions: [SessionSummary] = []
    var unreadSessionIDs: Set<String> = []
    var activeSessionID: String?
    var slashCommands: [SlashCommand] = []
    var profiles: [String] = []
    var activeProfile = "default"
    var isTurnRunning = false
    var sidebarVisible = true
    var canCheckForUpdates = true
    var dashboardID: UUID?

    static let empty = MacPaletteSnapshot()
}

/// `/`, `>`, `@`, `#` as the first character limit the palette to one kind of
/// result. The prefix is a filter, never part of the match text.
enum MacPaletteScope: Equatable {
    case all, slash, commands, profiles, sessions

    static func parse(_ raw: String) -> (scope: MacPaletteScope, text: String) {
        let trimmed = raw.drop(while: { $0.isWhitespace })
        guard let first = trimmed.first else { return (.all, "") }
        let scope: MacPaletteScope
        switch first {
        case "/": scope = .slash
        case ">": scope = .commands
        case "@": scope = .profiles
        case "#": scope = .sessions
        default: return (.all, String(trimmed).trimmingCharacters(in: .whitespaces))
        }
        return (scope, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    func includes(_ kind: MacPaletteKind) -> Bool {
        switch self {
        case .all: return true
        case .slash: return kind == .slash
        case .commands: return kind == .command || kind == .pane || kind == .model
        case .profiles: return kind == .profile
        case .sessions: return kind == .session
        }
    }
}

enum MacPaletteProvider {
    static let collapsedSlashCount = 5

    static func items(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        sessionItems(s) + slashItems(s) + profileItems(s) + commandItems(s)
    }

    // MARK: - Sources

    private static func sessionItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        let live = s.sessions.filter { !$0.isArchived }
        // The sidebar's own order is not reachable from here (SidebarView
        // keeps it private); pinned first, then catalog order, approximates it.
        let ordered = live.filter { $0.isPinned == true } + live.filter { $0.isPinned != true }
        return ordered.map { session in
            MacPaletteItem(
                id: "session:\(session.id)", kind: .session,
                title: session.title.isEmpty ? AppLocalization.string("Untitled chat") : session.title,
                subtitle: session.model, keywords: [session.model, session.id],
                isUnread: s.unreadSessionIDs.contains(session.id),
                isActiveSession: s.activeSessionID.map(session.macMatches) ?? false,
                lastActivityAt: session.lastActivityAt,
                action: .openSession(session.id)
            )
        }
    }

    private static func slashItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        let hasChat = s.activeSessionID != nil
        return s.slashCommands.map { command in
            MacPaletteItem(
                id: "slash:\(command.name)", kind: .slash, title: "/" + command.name,
                subtitle: command.description, keywords: command.aliases + [command.description],
                isEnabled: hasChat, disabledReason: hasChat ? nil : AppLocalization.string("No active chat"),
                action: command.argsHint == nil ? .runSlash(command.name) : .insertSlash(command.name)
            )
        }
    }

    private static func profileItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        (s.profiles.isEmpty ? [s.activeProfile] : s.profiles).map { name in
            let current = name == s.activeProfile
            return MacPaletteItem(
                id: "profile:\(name)", kind: .profile, title: name,
                subtitle: current ? AppLocalization.string("Current profile") : AppLocalization.string("Switch profile"),
                isEnabled: !current, isCurrent: current, action: .switchProfile(name)
            )
        }
    }

    private static func commandItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        var list: [MacPaletteItem] = [
            MacPaletteItem(id: "command:newChat", kind: .command, title: AppLocalization.string("New Chat"),
                           keywords: ["create", "start", "conversation"], action: .newChat),
            MacPaletteItem(id: "command:settings", kind: .command, title: AppLocalization.string("Settings"),
                           keywords: ["preferences", "options"], action: .openSettings),
            MacPaletteItem(id: "command:toggleSidebar", kind: .command,
                           title: s.sidebarVisible ? AppLocalization.string("Hide Sidebar") : AppLocalization.string("Show Sidebar"),
                           keywords: ["sidebar", "panel", "toggle"], action: .toggleSidebar),
            MacPaletteItem(id: "command:searchSessions", kind: .command, title: AppLocalization.string("Search Sessions"),
                           keywords: ["find", "chats"], action: .searchSessions),
            MacPaletteItem(id: "command:checkForUpdates", kind: .command, title: AppLocalization.string("Check for Updates"),
                           keywords: ["upgrade", "version"], isEnabled: s.canCheckForUpdates,
                           disabledReason: s.canCheckForUpdates ? nil : AppLocalization.string("Updates are unavailable right now"),
                           action: .checkForUpdates),
            MacPaletteItem(id: "model:switch", kind: .model, title: AppLocalization.string("Switch Model..."),
                           keywords: ["model", "picker", "llm"], action: .openModelPicker),
        ]
        if s.isTurnRunning {
            list.append(MacPaletteItem(id: "command:stopResponse", kind: .command, title: AppLocalization.string("Stop Response"),
                                       keywords: ["cancel", "interrupt", "halt"], action: .stopResponse))
        }
        list += SidebarTab.allCases.map { tab in
            MacPaletteItem(id: "pane:\(tab.rawValue)", kind: .pane, title: tab.displayName,
                           subtitle: AppLocalization.string("Pane"), keywords: ["pane", "tab", "go"], action: .selectPane(tab))
        }
        return list
    }

    // MARK: - Empty-query sections

    /// Recent (max 8, any kind), Commands (commands, model, panes, profiles),
    /// the active chat's slash commands collapsed to 5, then chats. A row
    /// shown in Recent is not repeated. Total rows capped at 50.
    static func sections(items: [MacPaletteItem], recents: [MacPaletteItem]) -> [MacPaletteSection] {
        let recent = Array(recents.prefix(MacPaletteRecents.shownLimit))
        let recentIDs = Set(recent.map(\.id))
        let rest = items.filter { !recentIDs.contains($0.id) }
        let commandKinds: Set<MacPaletteKind> = [.command, .model, .pane, .profile]
        var sections: [MacPaletteSection] = []
        func add(_ title: String, _ list: [MacPaletteItem]) {
            if !list.isEmpty { sections.append(MacPaletteSection(title: title, items: list)) }
        }
        add(AppLocalization.string("Recent"), recent)
        add(AppLocalization.string("Commands"), rest.filter { commandKinds.contains($0.kind) })
        add(AppLocalization.string("Slash Commands"), Array(rest.filter { $0.kind == .slash }.prefix(collapsedSlashCount)))
        add(AppLocalization.string("Chats"), rest.filter { $0.kind == .session })
        return capped(sections)
    }

    static func capped(_ sections: [MacPaletteSection], limit: Int = MacPaletteMatcher.rowLimit) -> [MacPaletteSection] {
        var remaining = limit
        var out: [MacPaletteSection] = []
        for section in sections where remaining > 0 {
            let take = Array(section.items.prefix(remaining))
            remaining -= take.count
            out.append(MacPaletteSection(title: section.title, items: take))
        }
        return out
    }
}
```

Command order inside the Commands section follows the `commandItems` order, then profiles come from `profileItems` order in `items()` (profiles precede commands). If you want commands before profiles, `sections` sorts nothing: the test only requires the section order, not intra-section order. Keep `items()` as written.

- [ ] **Step 4: Run to verify pass**

Run the Step 2 command. Expected: all `MacPaletteProviderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Palette/MacPaletteProvider.swift' 'ConduitMacTests/MacPaletteProviderTests.swift'
git commit -m "macOS: command palette provider, scoping and sections (D15)"
```

---

### Task 4: Calls, dispatcher and store

**Files:**
- Create: `ConduitMac/Palette/MacPaletteStore.swift`
- Test: `ConduitMacTests/MacPaletteStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 3 types; `MacSessionCursor.moved(_:from:in:)`.
- Produces:
  - `struct MacPaletteCalls` with closures (all default to no-ops): `openSession: (String) -> Void`, `runSlash: (String) async -> Void`, `insertSlash: (String) -> Void`, `switchProfile: (String) async -> Void`, `openModelPicker: () -> Void`, `selectPane: (SidebarTab) -> Void`, `newChat: () -> Void`, `openSettings: () -> Void`, `toggleSidebar: () -> Void`, `stopResponse: () -> Void`, `searchSessions: () -> Void`, `checkForUpdates: () -> Void`
  - `enum MacPaletteDispatcher { @MainActor static func perform(_ action: MacPaletteAction, with calls: MacPaletteCalls) }`
  - `@MainActor final class MacPaletteStore: ObservableObject` with `static let shared`, `init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init)`, `@Published private(set) var isPresented: Bool`, `@Published var query: String`, `@Published private(set) var sections: [MacPaletteSection]`, `@Published private(set) var selectionID: String?`, `var rows: [MacPaletteItem]`, `var scope: MacPaletteScope`, `var snapshot: () -> MacPaletteSnapshot`, `var calls: MacPaletteCalls`, `func present(restoreFocus: (() -> Void)? = nil)`, `func dismiss()`, `func toggle(restoreFocus: (() -> Void)? = nil)`, `func refresh()`, `func handleEscape()`, `func move(_ move: MacSessionCursor.Move)`, `func select(_ id: String)`, `func runSelected()`, `func run(_ item: MacPaletteItem)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteStoreTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var store: MacPaletteStore!
    private var log: [String] = []
    private var current = MacPaletteSnapshot.empty

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        store = MacPaletteStore(defaults: suite.defaults, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        log = []
        current = MacPaletteSnapshot(
            sessions: [.paletteFixture(id: "s1", title: "Laravel"), .paletteFixture(id: "s2", title: "Swift")],
            activeSessionID: "s1", slashCommands: [SlashCommand(name: "new", description: "Start over"),
                                                    SlashCommand(name: "title", description: "Rename", argsHint: "<n>")],
            profiles: ["default", "work"], activeProfile: "default"
        )
        store.snapshot = { [unowned self] in self.current }
        var calls = MacPaletteCalls()
        calls.openSession = { [unowned self] in log.append("open:\($0)") }
        calls.runSlash = { [unowned self] in log.append("slash:\($0)") }
        calls.insertSlash = { [unowned self] in log.append("insert:\($0)") }
        calls.switchProfile = { [unowned self] in log.append("profile:\($0)") }
        calls.openModelPicker = { [unowned self] in log.append("model") }
        calls.selectPane = { [unowned self] in log.append("pane:\($0.rawValue)") }
        calls.newChat = { [unowned self] in log.append("newChat") }
        calls.openSettings = { [unowned self] in log.append("settings") }
        calls.toggleSidebar = { [unowned self] in log.append("sidebar") }
        calls.stopResponse = { [unowned self] in log.append("stop") }
        calls.searchSessions = { [unowned self] in log.append("search") }
        calls.checkForUpdates = { [unowned self] in log.append("updates") }
        store.calls = calls
    }

    override func tearDown() async throws {
        store = nil
        HostedTestSupport.dropSuite(suite)
    }

    func testDispatcherCallsEachClosureExactlyOnce() {
        let cases: [(MacPaletteAction, String)] = [
            (.openSession("x"), "open:x"), (.insertSlash("t"), "insert:t"), (.openModelPicker, "model"),
            (.selectPane(.bots), "pane:Bots"), (.newChat, "newChat"), (.openSettings, "settings"),
            (.toggleSidebar, "sidebar"), (.stopResponse, "stop"), (.searchSessions, "search"), (.checkForUpdates, "updates"),
        ]
        for (action, expected) in cases {
            log = []
            MacPaletteDispatcher.perform(action, with: store.calls)
            XCTAssertEqual(log, [expected])
        }
    }

    func testAsyncActionsRunToCompletion() {
        MacPaletteDispatcher.perform(.runSlash("new"), with: store.calls)
        MacPaletteDispatcher.perform(.switchProfile("work"), with: store.calls)
        XCTAssertTrue(HostedTestSupport.waitUntil { log.sorted() == ["profile:work", "slash:new"] })
    }

    func testToggleOpensAndClosesAndResetsQuery() {
        store.toggle()
        XCTAssertTrue(store.isPresented)
        store.query = "lara"
        store.toggle()
        XCTAssertFalse(store.isPresented)
        XCTAssertEqual(store.query, "")
    }

    func testPresentShowsEmptyQuerySectionsAndSelectsFirstEnabledRow() {
        store.present()
        XCTAssertEqual(store.sections.first?.title, AppLocalization.string("Commands"))
        XCTAssertEqual(store.selectionID, store.rows.first(where: \.isEnabled)?.id)
    }

    func testTypingRanksAndScopePrefixFilters() {
        store.present()
        store.query = "lara"
        XCTAssertEqual(store.rows.map(\.id), ["session:s1"])
        store.query = "#"
        XCTAssertEqual(store.rows.map(\.id), ["session:s1", "session:s2"])
        store.query = "/"
        XCTAssertEqual(store.rows.map(\.id), ["slash:new", "slash:title"])
        store.query = "@wor"
        XCTAssertEqual(store.rows.map(\.id), ["profile:work"])
        store.query = "   "
        XCTAssertEqual(store.sections.first?.title, AppLocalization.string("Commands"), "whitespace equals empty")
    }

    func testSelectionClampsSkipsDisabledAndStopsAtEnds() {
        current.activeSessionID = nil           // slash rows become disabled
        store.present()
        store.query = "/"
        XCTAssertTrue(store.rows.allSatisfy { !$0.isEnabled })
        XCTAssertNil(store.selectionID)
        store.move(.down); store.move(.up); store.runSelected()   // must not crash or run
        XCTAssertEqual(log, [])

        store.query = ">"
        let first = store.selectionID
        store.move(.up)
        XCTAssertEqual(store.selectionID, first, "no wrap at the top")
        store.move(.last)
        let last = store.rows.last(where: \.isEnabled)?.id
        XCTAssertEqual(store.selectionID, last)
        store.move(.down)
        XCTAssertEqual(store.selectionID, last, "no wrap at the bottom")
        store.move(.first)
        XCTAssertEqual(store.selectionID, first)
    }

    func testSelectionReclampsWhenTheSelectedRowVanishes() {
        store.present()
        store.query = "#"
        store.select("session:s2")
        current.sessions = [.paletteFixture(id: "s1", title: "Laravel")]
        store.refresh()
        XCTAssertEqual(store.selectionID, "session:s1")
        current.sessions = []
        store.refresh()
        XCTAssertNil(store.selectionID)
        store.runSelected()
        XCTAssertEqual(log, [])
    }

    func testEscapeClearsQueryThenCloses() {
        store.present()
        store.query = "lara"
        store.handleEscape()
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.query, "")
        store.handleEscape()
        XCTAssertFalse(store.isPresented)
    }

    func testRunClosesFirstThenCallsOnceAndRecords() {
        var presentedWhenCalled: Bool?
        store.calls.openSession = { [unowned self] id in presentedWhenCalled = store.isPresented; log.append("open:\(id)") }
        store.present()
        store.query = "lara"
        store.runSelected()
        XCTAssertEqual(log, ["open:s1"])
        XCTAssertEqual(presentedWhenCalled, false, "the palette closes before the action runs")
        XCTAssertFalse(store.isPresented)

        store.present()
        XCTAssertEqual(store.sections.first?.title, AppLocalization.string("Recent"))
        XCTAssertEqual(store.sections.first?.items.first?.id, "session:s1")
    }

    func testRunSkipsDisabledAndCurrentProfile() {
        store.present()
        store.query = "@default"
        XCTAssertEqual(store.rows.first?.isCurrent, true)
        store.run(store.rows[0])
        XCTAssertEqual(log, [])
        XCTAssertTrue(store.isPresented)
    }

    func testRestoreFocusRunsOnCloseBeforeTheAction() {
        var order: [String] = []
        store.calls.newChat = { order.append("action") }
        store.present(restoreFocus: { order.append("focus") })
        store.query = "new chat"
        store.runSelected()
        XCTAssertEqual(order, ["focus", "action"])
        order = []
        store.present(restoreFocus: { order.append("focus") })
        store.dismiss()
        store.dismiss()
        XCTAssertEqual(order, ["focus"], "restored once")
    }

    func testRecentsPersistPerProfileScope() {
        store.present(); store.query = "lara"; store.runSelected()
        let other = MacPaletteStore(defaults: suite.defaults)
        other.snapshot = { [unowned self] in self.current }
        other.present()
        XCTAssertEqual(other.sections.first?.items.first?.id, "session:s1")
        current.activeProfile = "work"
        other.dismiss(); other.present()
        XCTAssertNotEqual(other.sections.first?.title, AppLocalization.string("Recent"), "another profile has its own recents")
    }

    func testTabIsNotTheStoresConcernButQueryChangesRefreshOnlyWhilePresented() {
        store.query = "lara"            // not presented: no work, no crash
        XCTAssertTrue(store.sections.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPaletteStoreTests`
Expected: build failure, `cannot find 'MacPaletteCalls' in scope`.

- [ ] **Step 3: Implement**

```swift
import Combine
import Foundation

/// The app calls the palette can make, injected so tests never touch
/// AppState (pattern: `ModelPickerApplyActions`). Live values: Task 5.
struct MacPaletteCalls {
    var openSession: (String) -> Void = { _ in }
    var runSlash: (String) async -> Void = { _ in }
    var insertSlash: (String) -> Void = { _ in }
    var switchProfile: (String) async -> Void = { _ in }
    var openModelPicker: () -> Void = {}
    var selectPane: (SidebarTab) -> Void = { _ in }
    var newChat: () -> Void = {}
    var openSettings: () -> Void = {}
    var toggleSidebar: () -> Void = {}
    var stopResponse: () -> Void = {}
    var searchSessions: () -> Void = {}
    var checkForUpdates: () -> Void = {}
}

enum MacPaletteDispatcher {
    @MainActor
    static func perform(_ action: MacPaletteAction, with calls: MacPaletteCalls) {
        switch action {
        case .openSession(let id): calls.openSession(id)
        case .runSlash(let name): Task { await calls.runSlash(name) }
        case .insertSlash(let name): calls.insertSlash(name)
        case .switchProfile(let name): Task { await calls.switchProfile(name) }
        case .openModelPicker: calls.openModelPicker()
        case .selectPane(let tab): calls.selectPane(tab)
        case .newChat: calls.newChat()
        case .openSettings: calls.openSettings()
        case .toggleSidebar: calls.toggleSidebar()
        case .stopResponse: calls.stopResponse()
        case .searchSessions: calls.searchSessions()
        case .checkForUpdates: calls.checkForUpdates()
        }
    }
}

/// State of the Cmd-K palette (D15): query, sections, selection, running.
@MainActor
final class MacPaletteStore: ObservableObject {
    static let shared = MacPaletteStore()

    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet { if query != oldValue, isPresented { refresh() } }
    }
    @Published private(set) var sections: [MacPaletteSection] = []
    @Published private(set) var selectionID: String?

    var snapshot: () -> MacPaletteSnapshot = { .empty }
    var calls = MacPaletteCalls()

    private let recentsStore: MacPaletteRecentsStore
    private let now: () -> Date
    private var recents = MacPaletteRecents()
    private var recentsScope: String?
    private var restoreFocus: (() -> Void)?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.recentsStore = MacPaletteRecentsStore(defaults: defaults)
        self.now = now
    }

    var rows: [MacPaletteItem] { sections.flatMap(\.items) }
    var scope: MacPaletteScope { MacPaletteScope.parse(query).scope }

    // MARK: - Presenting

    func present(restoreFocus: (() -> Void)? = nil) {
        guard !isPresented else { return }
        self.restoreFocus = restoreFocus
        query = ""
        isPresented = true
        selectionID = nil
        refresh()
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        query = ""
        sections = []
        selectionID = nil
        let restore = restoreFocus
        restoreFocus = nil
        restore?()
    }

    func toggle(restoreFocus: (() -> Void)? = nil) {
        isPresented ? dismiss() : present(restoreFocus: restoreFocus)
    }

    /// First Esc clears a non-empty query, the second closes.
    func handleEscape() {
        if query.isEmpty { dismiss() } else { query = "" }
    }

    // MARK: - Results

    func refresh() {
        guard isPresented else { return }
        let current = snapshot()
        loadRecentsIfScopeChanged(current)
        let parsed = MacPaletteScope.parse(query)
        let all = MacPaletteProvider.items(current).filter { parsed.scope.includes($0.kind) }
        let resolvedRecents = recents.resolved(in: all)
        if !parsed.text.isEmpty {
            let ranked = MacPaletteMatcher.rank(all, query: parsed.text, recentIDs: resolvedRecents.map(\.id), now: now())
            sections = ranked.isEmpty ? [] : [MacPaletteSection(title: nil, items: ranked)]
        } else if parsed.scope == .all {
            sections = MacPaletteProvider.sections(items: all, recents: resolvedRecents)
        } else {
            sections = MacPaletteProvider.capped([MacPaletteSection(title: nil, items: all)])
        }
        let enabled = rows.filter(\.isEnabled).map(\.id)
        if let selectionID, enabled.contains(selectionID) { return }
        selectionID = enabled.first
    }

    private func loadRecentsIfScopeChanged(_ s: MacPaletteSnapshot) {
        let key = MacPaletteRecentsStore.storageKey(dashboardID: s.dashboardID, profile: s.activeProfile)
        guard key != recentsScope else { return }
        recentsScope = key
        recents = recentsStore.load(dashboardID: s.dashboardID, profile: s.activeProfile)
    }

    // MARK: - Selection

    func move(_ move: MacSessionCursor.Move) {
        let enabled = rows.filter(\.isEnabled).map(\.id)
        guard !enabled.isEmpty else { selectionID = nil; return }
        selectionID = MacSessionCursor.moved(move, from: selectionID, in: enabled) ?? selectionID
    }

    func select(_ id: String) {
        guard rows.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        selectionID = id
    }

    // MARK: - Running

    func runSelected() {
        guard let selectionID, let item = rows.first(where: { $0.id == selectionID }) else { return }
        run(item)
    }

    /// Closes first (restoring focus), then performs the action once.
    func run(_ item: MacPaletteItem) {
        guard item.isEnabled, !item.isCurrent else { return }
        let current = snapshot()
        recents.record(item.id)
        recentsStore.save(recents, dashboardID: current.dashboardID, profile: current.activeProfile)
        dismiss()
        MacPaletteDispatcher.perform(item.action, with: calls)
    }
}
```

Two checks while implementing: (a) in `move`, `MacSessionCursor.moved(.down, from: nil, ...)` picks the first row and `.up` the last; `.up`/`.down` at an end return the same id (they "stay"); (b) `present()` sets `query = ""` before `isPresented = true`, so the `didSet` does not refresh early.

- [ ] **Step 4: Run to verify pass**

Run the Step 2 command. Expected: all `MacPaletteStoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Palette/MacPaletteStore.swift' 'ConduitMacTests/MacPaletteStoreTests.swift'
git commit -m "macOS: command palette store and action dispatcher (D15)"
```

---

### Task 5: Live binding, Cmd-K action, Settings hook, app wiring

**Files:**
- Create: `ConduitMac/Palette/MacPaletteBinding.swift`
- Modify: `ConduitMac/App/MacKeyboardShortcuts.swift` (add `MacPaletteActions` after `MacSessionTabsActions`)
- Modify: the file declaring `Notification.Name.macSessionOpenRequested` (`ConduitMac/App/MacChatRoute.swift`): add `macOpenSettingsRequested`
- Modify: `Conduit/Views/RootView.swift` (gated Settings observer)
- Modify: `ConduitMac/App/ConduitMacApp.swift` (bind the shared store; attach the overlay in Task 6/7)
- Modify: `docs/macos/PORTING_LEDGER.md` (one row)
- Test: `ConduitMacTests/MacPaletteBindingTests.swift`

**Interfaces:**
- Consumes: `MacPaletteStore`, `MacPaletteCalls`, `MacPaletteSnapshot` (Tasks 3, 4); AppState members listed in "Existing facts"; `MacSessionTabsActions.isMainChatWindow`; `MacKeyboardActions`.
- Produces:
  - `extension Notification.Name { static let macOpenSettingsRequested }` (`"conduit.mac.openSettingsRequested"`)
  - `extension MacPaletteCalls { @MainActor static func live(appState: AppState) -> MacPaletteCalls }`
  - `extension MacPaletteStore { func bind(to appState: AppState) }` (idempotent)
  - `extension MacPaletteSnapshot { @MainActor static func make(from appState: AppState, defaults: UserDefaults = .standard) -> MacPaletteSnapshot }`
  - `@MainActor enum MacPaletteActions { static func toggle(store: MacPaletteStore?, window: NSWindow?) }` (optional store parameter: a `.shared` default trips Swift 6 isolation, same as `MacSessionTabsActions`)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteBindingTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws {
        windows.forEach { $0.close() }; windows = []
        HostedTestSupport.dropSuite(suite)
    }

    private func window(identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = identifier.map(NSUserInterfaceItemIdentifier.init)
        windows.append(w)
        return w
    }

    func testSnapshotMirrorsAppState() {
        let appState = AppStateRuntimeRegistry.shared.appState
        let snap = MacPaletteSnapshot.make(from: appState, defaults: suite.defaults)
        XCTAssertEqual(snap.activeProfile, appState.activeProfile)
        XCTAssertEqual(snap.activeSessionID, appState.activeSessionId)
        XCTAssertEqual(snap.isTurnRunning, appState.isBusy)
        XCTAssertEqual(snap.sessions.map(\.id), appState.activeProfileSessions.filter { !$0.isArchived }.map(\.id))
        XCTAssertTrue(snap.sidebarVisible, "defaults to visible when the key is unset")
        suite.defaults.set(false, forKey: MacSidebarState.defaultsKey)
        XCTAssertFalse(MacPaletteSnapshot.make(from: appState, defaults: suite.defaults).sidebarVisible)
    }

    func testBindIsIdempotentAndInstallsLiveCalls() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let appState = AppStateRuntimeRegistry.shared.appState
        store.bind(to: appState)
        store.bind(to: appState)
        XCTAssertEqual(store.snapshot().activeProfile, appState.activeProfile)
    }

    func testOpenSettingsPostsTheNotification() {
        let appState = AppStateRuntimeRegistry.shared.appState
        let calls = MacPaletteCalls.live(appState: appState)
        let posted = expectation(forNotification: .macOpenSettingsRequested, object: nil)
        calls.openSettings()
        wait(for: [posted], timeout: 2)
    }

    func testModelPickerCallSetsTheFlagThenWeResetIt() {
        let appState = AppStateRuntimeRegistry.shared.appState
        let was = appState.showModelPicker
        defer { appState.showModelPicker = was }
        MacPaletteCalls.live(appState: appState).openModelPicker()
        XCTAssertTrue(appState.showModelPicker)
    }

    func testToggleOnlyInTheMainChatWindowAndNotUnderASheet() {
        let store = MacPaletteStore(defaults: suite.defaults)
        MacPaletteActions.toggle(store: store, window: window(identifier: "com_apple_SwiftUI_Settings_window"))
        XCTAssertFalse(store.isPresented, "a non-chat window ignores Cmd-K")
        MacPaletteActions.toggle(store: store, window: nil)
        XCTAssertFalse(store.isPresented)

        let main = window(identifier: "conduit-primary-AppWindow-1")
        MacPaletteActions.toggle(store: store, window: main)
        XCTAssertTrue(store.isPresented)
        MacPaletteActions.toggle(store: store, window: main)
        XCTAssertFalse(store.isPresented)

        let sheet = window(identifier: nil)
        main.beginSheet(sheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { main.attachedSheet != nil })
        MacPaletteActions.toggle(store: store, window: main)
        XCTAssertFalse(store.isPresented, "nothing opens under a sheet")
        main.endSheet(sheet)
    }

    func testToggleRestoresComposerFocusOnlyWhenTheComposerHadIt() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let main = window(identifier: "conduit-primary-AppWindow-1")
        MacPaletteActions.toggle(store: store, window: main)           // first responder is the window: no restore
        store.dismiss()
        // Composer case is covered by MacPaletteCommandsTests with a real ComposerTextView (Task 7).
        XCTAssertFalse(store.isPresented)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPaletteBindingTests`
Expected: build failure, `type 'Notification.Name' has no member 'macOpenSettingsRequested'`.

- [ ] **Step 3: Implement**

Add next to `macSessionOpenRequested` (read the file first and follow its style):

```swift
    /// The command palette asks the root view to open Settings (D15).
    static let macOpenSettingsRequested = Notification.Name("conduit.mac.openSettingsRequested")
```

`ConduitMac/Palette/MacPaletteBinding.swift`:

```swift
import AppKit
import Foundation

extension MacPaletteSnapshot {
    /// What the palette reads from AppState. Sessions come from
    /// `activeProfileSessions`, the sidebar's own source (it filters other
    /// profiles' rows and bot chats); unread comes from `isSessionUnread`
    /// because `SessionSummary.isUnread` is optional and not authoritative.
    @MainActor
    static func make(from appState: AppState, defaults: UserDefaults = .standard) -> MacPaletteSnapshot {
        let sessions = appState.activeProfileSessions.filter { !$0.isArchived }
        return MacPaletteSnapshot(
            sessions: sessions,
            unreadSessionIDs: Set(sessions.filter { appState.isSessionUnread($0) }.map(\.id)),
            activeSessionID: appState.activeSessionId,
            slashCommands: appState.slashCommands,
            profiles: appState.profiles,
            activeProfile: appState.activeProfile,
            isTurnRunning: appState.isBusy,
            sidebarVisible: defaults.object(forKey: MacSidebarState.defaultsKey) as? Bool ?? true,
            canCheckForUpdates: MacUpdater.shared.canCheckForUpdates,
            dashboardID: appState.activeDashboardID
        )
    }
}

extension MacPaletteCalls {
    @MainActor
    static func live(appState: AppState) -> MacPaletteCalls {
        var calls = MacPaletteCalls()
        calls.openSession = { [weak appState] id in
            appState?.dismissSidebarDrawer()
            _ = appState?.requestOpenSession(id)
        }
        calls.runSlash = { [weak appState] name in await appState?.executeSlashCommand("/" + name) }
        // prefillComposer replaces the draft and focuses the composer.
        calls.insertSlash = { [weak appState] name in appState?.prefillComposer("/" + name + " ") }
        calls.switchProfile = { [weak appState] name in await appState?.switchProfile(to: name) }
        calls.openModelPicker = { [weak appState] in appState?.showModelPicker = true }
        calls.selectPane = { tab in MacKeyboardActions.selectTab(tab, window: nil) }
        calls.newChat = { [weak appState] in Task { await appState?.createNewSession() } }
        calls.openSettings = { NotificationCenter.default.post(name: .macOpenSettingsRequested, object: nil) }
        calls.toggleSidebar = { MacSidebarState.toggleVisible() }
        calls.stopResponse = { [weak appState] in Task { _ = await appState?.cancelCurrent() } }
        calls.searchSessions = { MacKeyboardActions.focusSessionSearch() }
        calls.checkForUpdates = { MacUpdater.shared.checkForUpdates() }
        return calls
    }
}

extension MacPaletteStore {
    /// Idempotent; the app calls it once the window appears.
    func bind(to appState: AppState) {
        guard !isBound else { return }
        isBound = true
        snapshot = { [weak appState] in appState.map { MacPaletteSnapshot.make(from: $0) } ?? .empty }
        calls = .live(appState: appState)
    }
}
```

`isBound` must be stored state, which an extension cannot add: add `fileprivate(set) var isBound = false` to `MacPaletteStore` in `MacPaletteStore.swift` (plain `var isBound = false`, since it is used from another file).

Add to `MacKeyboardShortcuts.swift` after `MacSessionTabsActions`:

```swift
/// What Go > Command Palette does (D15). The store is optional because a
/// `.shared` default argument trips Swift 6 isolation (same as the tabs).
@MainActor
enum MacPaletteActions {
    /// Cmd-K: only in the chat window, never under a sheet. When the composer
    /// held focus, closing the palette gives it back.
    static func toggle(store: MacPaletteStore? = nil, window: NSWindow?) {
        let store = store ?? .shared
        guard MacSessionTabsActions.isMainChatWindow(window),
              !MacKeyboardActions.commandsBlocked(by: window) else { return }
        let composerHadFocus = window?.firstResponder is ComposerTextView
        store.toggle(restoreFocus: composerHadFocus ? { MacKeyboardActions.focusComposer(window: window) } : nil)
    }
}
```

Gated upstream edit in `Conduit/Views/RootView.swift`: first run `grep -n "#if os(macOS) // MAC:" Conduit/Views/RootView.swift` and read lines 83 to 100 and 345 to 360 to copy how existing gates sit inside modifier chains. Add, directly after the `.onChange(of: appState.settingsLinkRequest)` block (about line 249):

```swift
        #if os(macOS) // MAC: the command palette opens Settings (D15)
        .onReceive(NotificationCenter.default.publisher(for: .macOpenSettingsRequested)) { _ in
            guard settingsPresentation == nil else { return }
            settingsOpensAt = nil
            if appState.showSidebar, !isPersistentSidebarActive {
                presentSettingsFromDrawer()
            } else {
                presentSettings()
            }
        }
        #endif // MAC:
```

If the compiler rejects `#if` inside the modifier chain at that position, wrap the existing chain tail the way the other gates in the file do (do not restructure unrelated code), keeping every original line byte-identical.

Ledger row in `docs/macos/PORTING_LEDGER.md` (match the table format of existing rows):

`| Conduit/Views/RootView.swift (settingsLinkRequest onChange, about line 249) | R3 gate | `.onReceive(.macOpenSettingsRequested)` opens Settings for the Cmd-K palette (D15); `settingsLinkRequest` only reaches the calls/voice pages | none needed |`

In `ConduitMac/App/ConduitMacApp.swift` `rootContent`, next to the tabs bind:

```swift
            .task { MacPaletteStore.shared.bind(to: appState) }
```

- [ ] **Step 4: Run to verify pass**

Run the Step 2 command. Expected: all `MacPaletteBindingTests` pass. Then build the app (Global Constraints build command) to prove the gated RootView compiles, and run `git diff -- Conduit Shared | grep '^-[^-]'`: expect no output. Note: `git diff` also shows the unrelated pre-existing edits to `AppState.swift`/`ChatView.swift`; restrict the check with `git diff -- Conduit/Views/RootView.swift | grep '^-[^-]'`.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Palette/MacPaletteBinding.swift' 'ConduitMac/Palette/MacPaletteStore.swift' 'ConduitMac/App/MacKeyboardShortcuts.swift' 'ConduitMac/App/MacChatRoute.swift' 'ConduitMac/App/ConduitMacApp.swift' 'Conduit/Views/RootView.swift' 'docs/macos/PORTING_LEDGER.md' 'ConduitMacTests/MacPaletteBindingTests.swift'
git commit -m "macOS: command palette live binding, Cmd-K action, Settings hook (D15)"
```

---

### Task 6: Palette view

**Files:**
- Create: `ConduitMac/Palette/MacPaletteView.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift` (attach the overlay)
- Test: `ConduitMacTests/MacPaletteViewTests.swift`

**Interfaces:**
- Consumes: `MacPaletteStore` (Task 4); `AccessibilityProbe` (`HostedTestSupport.swift`; read `labels(in:)` and `frame(of:in:)` before use and follow their signatures).
- Produces: `struct MacPaletteView: View { init(store: MacPaletteStore? = nil) }`; `enum MacPaletteMetrics { static let width: CGFloat = 560; static let rowHeight: CGFloat = 32; static let maxVisibleRows = 9 }`.

- [ ] **Step 1: Write the failing tests**

```swift
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteViewTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var window: NSWindow?

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws {
        window?.close(); window = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func store(sessions: Int = 3) -> MacPaletteStore {
        let store = MacPaletteStore(defaults: suite.defaults)
        let snapshot = MacPaletteSnapshot(
            sessions: (0..<sessions).map { .paletteFixture(id: "s\($0)", title: "Session number \($0)") },
            activeSessionID: "s0", profiles: ["default"], activeProfile: "default"
        )
        store.snapshot = { snapshot }
        return store
    }

    private func host(_ store: MacPaletteStore, appearance: NSAppearance.Name? = nil) -> NSWindow {
        let view = ZStack { Color.gray.opacity(0.2) }.overlay { MacPaletteView(store: store) }
        let window = HostedTestSupport.host(view.frame(width: 800, height: 600), size: NSSize(width: 800, height: 600))
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        self.window = window
        return window
    }

    func testMetrics() {
        XCTAssertEqual(MacPaletteMetrics.width, 560)
        XCTAssertEqual(MacPaletteMetrics.maxVisibleRows, 9)
    }

    func testNothingRendersWhileClosed() {
        let window = host(store())
        HostedTestSupport.settle()
        XCTAssertFalse(AccessibilityProbe.labels(in: window).contains { $0.contains("Session number") })
    }

    func testRowsAreAccessibleButtonsWithTitleAndSelectedTrait() {
        let store = store()
        let window = host(store)
        store.present()
        store.query = "session"
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: window).contains { $0.contains("Session number 0") } })
        XCTAssertEqual(store.selectionID, "session:s0")
    }

    func testSearchFieldIsLabelledAndFocusedOnOpen() {
        let store = store()
        let window = host(store)
        store.present()
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder is NSTextView || window.firstResponder is NSTextField })
        XCTAssertTrue(AccessibilityProbe.labels(in: window).contains(AppLocalization.string("Command palette search")))
    }

    func testSelectedRowStaysVisibleAfterDownAtOverflow() {
        let store = store(sessions: 40)
        let window = host(store)
        store.present()
        store.query = "#"
        for _ in 0..<30 { store.move(.down) }
        let id = store.selectionID
        XCTAssertEqual(id, "session:s29")
        XCTAssertTrue(HostedTestSupport.waitUntil {
            AccessibilityProbe.frame(of: "Session number 29", in: window).map { window.contentView!.bounds.contains($0) } ?? false
        })
    }

    func testEmptyResultsShowTheEmptyState() {
        let store = store()
        let window = host(store)
        store.present()
        store.query = "zzzzqqq"
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: window).contains(AppLocalization.string("No results")) })
        store.runSelected()    // nothing selected: must not crash
    }

    func testRendersInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let store = store()
            let window = host(store, appearance: appearance)
            store.present()
            HostedTestSupport.settle()
            let view = try XCTUnwrap(window.contentView)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            window.close(); self.window = nil
        }
    }

    func testKeyEventsReachTheStore() throws {
        let store = store()
        let window = host(store)
        store.present()
        store.query = "#"
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder is NSTextView })
        func send(_ keyCode: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
            window.sendEvent(event)
        }
        send(125, chars: "\u{F701}")                  // Down
        XCTAssertTrue(HostedTestSupport.waitUntil { store.selectionID == "session:s1" })
        send(126, chars: "\u{F700}")                  // Up
        XCTAssertTrue(HostedTestSupport.waitUntil { store.selectionID == "session:s0" })
        send(53, chars: "\u{1B}")                     // Esc clears "#"
        XCTAssertTrue(HostedTestSupport.waitUntil { store.query.isEmpty })
        send(53, chars: "\u{1B}")                     // second Esc closes
        XCTAssertTrue(HostedTestSupport.waitUntil { !store.isPresented })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPaletteViewTests`
Expected: build failure, `cannot find 'MacPaletteView' in scope`.

- [ ] **Step 3: Implement**

Before writing, run `grep -rn "SheetEscape" ConduitMac | head` and read the monitor: confirm it only acts when a sheet is up so the palette's Esc is not swallowed. Read `MacSessionTabButton` (`ConduitMac/Tabs/MacSessionTabStrip.swift`) and copy its selected-fill and foreground pair for contrast.

```swift
import AppKit
import SwiftUI

enum MacPaletteMetrics {
    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 32
    static let maxVisibleRows = 9
}

/// The Cmd-K overlay (D15): scrim, search field, result list. Attached around
/// RootView in ConduitMacApp, so a sheet on the window covers it.
struct MacPaletteView: View {
    @ObservedObject var store: MacPaletteStore
    @FocusState private var searchFocused: Bool

    init(store: MacPaletteStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
    }

    var body: some View {
        Group {
            if store.isPresented {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { store.dismiss() }
                        .accessibilityHidden(true)
                    panel.padding(.top, 72)
                }
                .transition(.opacity)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(width: MacPaletteMetrics.width)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
            store.move(press.modifiers.contains(.command) ? .first : .up); return .handled
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
            store.move(press.modifiers.contains(.command) ? .last : .down); return .handled
        }
        .onKeyPress(.home, phases: .down) { _ in store.move(.first); return .handled }
        .onKeyPress(.end, phases: .down) { _ in store.move(.last); return .handled }
        .onKeyPress(.escape, phases: .down) { _ in store.handleEscape(); return .handled }
        .onKeyPress(.tab, phases: [.down, .repeat]) { _ in .handled }
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            // onSubmit, not a raw Return handler: Return that confirms an IME
            // composition must not run the row.
            TextField(AppLocalization.string("Search commands, chats and profiles"), text: $store.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { store.runSelected() }
                .accessibilityLabel(AppLocalization.string("Command palette search"))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var results: some View {
        let rows = store.rows
        return Group {
            if rows.isEmpty {
                Text(AppLocalization.string("No results"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: MacPaletteMetrics.rowHeight * 2)
                    .accessibilityLabel(AppLocalization.string("No results"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(store.sections.enumerated()), id: \.offset) { _, section in
                                if let title = section.title {
                                    Text(title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 14)
                                        .padding(.top, 8)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ForEach(section.items) { item in
                                    MacPaletteRow(item: item, isSelected: item.id == store.selectionID) {
                                        store.run(item)
                                    }
                                    .id(item.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: MacPaletteMetrics.rowHeight * CGFloat(MacPaletteMetrics.maxVisibleRows) + 24)
                    .onChange(of: store.selectionID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }
}

private struct MacPaletteRow: View {
    let item: MacPaletteItem
    let isSelected: Bool
    let onRun: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).accessibilityHidden(true)
            Text(item.title).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).lineLimit(1).foregroundStyle(isSelected ? Color.black.opacity(0.6) : .secondary)
            }
            Spacer(minLength: 0)
            if item.isCurrent { Image(systemName: "checkmark").accessibilityHidden(true) }
            if let reason = item.disabledReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if item.isUnread { Circle().fill(Color.conduitAccent).frame(width: 6, height: 6).accessibilityHidden(true) }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: MacPaletteMetrics.rowHeight)
        .foregroundStyle(isSelected ? Color.black.opacity(0.85) : Color.primary)
        .background(Capsule().fill(isSelected ? Color.conduitAccent : .clear))
        .opacity(item.isEnabled || item.isCurrent ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { onRun() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var label: String {
        [item.title, item.subtitle, item.disabledReason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var symbol: String {
        switch item.kind {
        case .session: return "bubble.left"
        case .slash: return "slash.circle"
        case .profile: return "person.crop.circle"
        case .model: return "cpu"
        case .pane: return "sidebar.left"
        case .command: return "command"
        }
    }
}
```

The test `testRowsAreAccessibleButtonsWithTitleAndSelectedTrait` searches labels with `contains("Session number 0")`; the combined label there is "Session number 0" (subtitle is the empty model), so both `==` and `contains` pass.

If `testKeyEventsReachTheStore` shows arrows or Esc do not reach the `onKeyPress` handlers (a focused single-line `TextField`'s field editor can consume Up/Down, Home/End and Esc before SwiftUI sees them), apply in this order and stop at the first that passes: (1) move the same `.onKeyPress` modifiers onto the `TextField` itself; (2) install a local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` owned by `MacPaletteStore` (installed in `present`, removed in `dismiss`, scoped to events whose `window` is the palette's window, returning nil for the handled keys 126, 125, 115, 119, 53, 48). Record whichever was needed in D15. Do not handle Return in any key handler.

In `ConduitMacApp.swift` `rootContent`, add the overlay on `RootView()` before `.environmentObject(appState)`:

```swift
        RootView()
            .overlay { MacPaletteView() }
            .environmentObject(appState)
```

(The overlay must be inside the `.environmentObject` chain only if the view needs it; `MacPaletteView` takes the store explicitly and needs no `AppState`, so placement is free. Keep it directly on `RootView()` so it covers the toolbar-less content area.)

- [ ] **Step 4: Run to verify pass**

Run the Step 2 command. Expected: all `MacPaletteViewTests` pass. Then run the build command to confirm the app compiles with the overlay attached.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/Palette/MacPaletteView.swift' 'ConduitMac/App/ConduitMacApp.swift' 'ConduitMacTests/MacPaletteViewTests.swift'
git commit -m "macOS: command palette overlay view (D15)"
```

---

### Task 7: Cmd-K menu item and shortcut tests

**Files:**
- Modify: `ConduitMac/App/ConduitCommands.swift`, `ConduitMac/App/ConduitMacApp.swift`
- Modify: `ConduitMacTests/MacKeyboardTests.swift` (menu table)
- Create: `ConduitMacTests/MacPaletteCommandsTests.swift`

**Interfaces:**
- Consumes: `MacPaletteActions.toggle(store:window:)` (Task 5), `MacPaletteStore.shared`.
- Produces: `ConduitCommands.palette: MacPaletteStore` (declared right after `tabs`, so the memberwise init order is `appState, tabs, palette, updater`).

- [ ] **Step 1: Write the failing tests**

Read `ConduitMacTests/MacKeyboardTests.swift` (`MacKeyboardMenuTests`) first, then add the row `("/Go/Command Palette", "k", .command)` to its shortcut table in the style the existing rows use. Create `ConduitMacTests/MacPaletteCommandsTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteCommandsTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws {
        windows.forEach { $0.close() }; windows = []
        HostedTestSupport.dropSuite(suite)
    }

    private func mainWindow() -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("conduit-primary-AppWindow-1")
        windows.append(w)
        return w
    }

    func testComposerFocusIsRestoredAndTheDraftIsUntouched() {
        let window = mainWindow()
        let composer = ComposerTextView(frame: .init(x: 0, y: 0, width: 300, height: 80))
        composer.string = "half-written draft"
        window.contentView?.addSubview(composer)
        window.makeFirstResponder(composer)
        XCTAssertTrue(window.firstResponder === composer)

        let store = MacPaletteStore(defaults: suite.defaults)
        MacPaletteActions.toggle(store: store, window: window)
        XCTAssertTrue(store.isPresented)
        MacPaletteActions.toggle(store: store, window: window)
        XCTAssertFalse(store.isPresented)
        XCTAssertEqual(composer.string, "half-written draft")
    }

    func testCmdKTwiceTogglesFromAnyPaneState() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let window = mainWindow()
        for _ in 0..<3 { MacPaletteActions.toggle(store: store, window: window) }
        XCTAssertTrue(store.isPresented)
    }
}
```

Focus restoration posts `macFocusComposerRequested` (the real composer coordinator observes it); a bare `ComposerTextView` has no coordinator, so the test only asserts the draft is intact and the palette toggles. The live focus return is a manual smoke item (Task 9).

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:ConduitMacTests/MacPaletteCommandsTests -only-testing:ConduitMacTests/MacKeyboardMenuTests`
Expected: `MacKeyboardMenuTests` fails (no `/Go/Command Palette` item). If `MacPaletteCommandsTests` already passes, that is fine (Task 5 supplies `MacPaletteActions`).

- [ ] **Step 3: Implement**

In `ConduitCommands.swift` add `@ObservedObject var palette: MacPaletteStore` right after `tabs`, and at the top of `CommandMenu("Go")` before the `ForEach(1...8 ...)`:

```swift
            // Never `.disabled`: a stale disabled item would swallow Cmd-K (see
            // the comment above). The action checks the window and any sheet.
            Button("Command Palette") { MacPaletteActions.toggle(store: palette, window: NSApp.keyWindow) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
```

In `ConduitMacApp.swift`: `.commands { ConduitCommands(appState: appState, tabs: .shared, palette: .shared, updater: .shared) }`.

Verify Cmd-K is unused: `grep -rn 'keyboardShortcut("k"' ConduitMac Conduit` must show only the new line. If `MacKeyboardMenuTests` has a duplicate-binding check, it covers this once the row is in the table.

- [ ] **Step 4: Run to verify pass**

Run the Step 2 command. Expected: pass. If the menu test needs the AppKit form of the key, print the reported `keyEquivalent`/mask in a failing assertion and pin what AppKit reports ("k", `.command`).

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/App/ConduitCommands.swift' 'ConduitMac/App/ConduitMacApp.swift' 'ConduitMacTests/MacKeyboardTests.swift' 'ConduitMacTests/MacPaletteCommandsTests.swift'
git commit -m "macOS: Go > Command Palette on Cmd-K (D15)"
```

---

### Task 8: Localization keys

**Files:**
- Modify: `Conduit/Localizable.xcstrings` (through `scripts/l10n.py` only, never by hand)
- Possibly modify: `docs/macos/PORTING_LEDGER.md` if the catalog edit needs a row (adding keys removes nothing; add a row only if the ledger already lists `Localizable.xcstrings`)

**Interfaces:**
- Consumes: every `AppLocalization.string("...")` and SwiftUI literal added in Tasks 3 to 7.
- Produces: catalog keys for every shipped language, passing `scripts/check-l10n-coverage.py`.

Keys added by this plan (verify the exact list with the grep in Step 1; keys that already exist, such as `New Chat`, `Settings`, `Hide Sidebar`, `Show Sidebar`, `Search Sessions`, `Sessions`, `Bots`, `Cron`, `Kanban`, need nothing):
`Command Palette`, `Search commands, chats and profiles`, `Command palette search`, `Recent`, `Commands`, `Slash Commands`, `Chats`, `No results`, `No active chat`, `Current profile`, `Switch profile`, `Untitled chat`, `Pane`, `Switch Model...`, `Stop Response`, `Check for Updates`, `Updates are unavailable right now`.

- [ ] **Step 1: Baseline and key discovery**

Run: `python3 scripts/check-l10n-coverage.py --repo-root .` and record the result (it may already fail for unrelated reasons; note the baseline). Then `grep -rhno 'AppLocalization.string("[^"]*")' 'ConduitMac/Palette' 'ConduitMac/App/ConduitCommands.swift' 'ConduitMac/App/MacKeyboardShortcuts.swift' | sort -u` and `python3 scripts/l10n.py --help`. List shipped languages: `python3 - <<'PY'` is not needed; read the `localizations` keys of `Conduit/Localizable.xcstrings` and subtract `ConduitDraftLanguages` in `Conduit/Info.plist`.

- [ ] **Step 2: Add the keys**

Per docs/LOCALIZATION.md ("A new UI string needs every shipped language: write a worksheet per language with the new key and `import --create` them together"): run `python3 scripts/l10n.py export <lang> -o <scratchpad>/<lang>.json` for one language to learn the worksheet format, write one worksheet per shipped language containing the new keys with real translations (one subagent per batch of languages is fine), then `python3 scripts/l10n.py import --create <scratchpad>/<lang>.json` for each. Keep `Switch Model...` with three ASCII dots (ASCII-only rule).

- [ ] **Step 3: Verify**

Run: `python3 scripts/check-l10n-coverage.py --repo-root .`
Expected: no new failures against the Step 1 baseline, and none that mention a palette key. Run `git diff --stat -- Conduit/Localizable.xcstrings` and `git diff -- Conduit/Localizable.xcstrings | grep '^-[^-]'` (expect no removed lines other than the file's own trailing re-serialisation; if the tool re-sorts keys, accept only whitespace-neutral moves and mention it in the commit message).

- [ ] **Step 4: Commit**

```bash
git add 'Conduit/Localizable.xcstrings'
git commit -m "macOS: command palette strings in every shipped language (D15)"
```

---

### Task 9: Docs, smoke checklist, full verification

**Files:**
- Modify: `docs/macos/DECISIONS.md` (new D15; D10 shortcut table row)
- Modify: `docs/macos/SMOKE_CHECKLIST.md`
- Modify: `docs/macos/PORTING_LEDGER.md` (confirm the Task 5 row is present)

- [ ] **Step 1: DECISIONS.md**

Add after D14:

```
## D15: Mac command palette (2026-10-15)
Spec: docs/superpowers/specs/2026-10-15-mac-command-palette-design.md. Cmd-K (Go > Command Palette) toggles an in-window overlay: search field over a ranked list, 560 pt wide, 9 visible rows, scrim, Esc clears then closes. It only dispatches existing app actions and never sends free text as a prompt (Quick Ask owns that). Items: sessions (`activeProfileSessions`, non-archived), slash commands (`slashCommands`, no-arg run `executeSlashCommand`, `argsHint` ones go to the composer via `prefillComposer`, which REPLACES the draft), profiles (active one is a non-runnable check row), "Switch Model..." (opens the model picker; no inline model list), panes, New Chat, Settings, Hide/Show Sidebar, Stop Response (only while a turn runs), Search Sessions, Check for Updates. Prefix scoping `/ > @ #`. Ranking: tiers exact > prefix > word start > substring > fuzzy (3+ chars) > keyword; kind weights, recency boost 60 decaying 6 per rank, session unread +10 and last-24h +5, disabled rows last in their tier, 50-row cap. Recents: 20 ids per dashboard and profile in `conduit.mac.palette.recents.<dashboard>.<profile>`, shown 8; items that no longer exist drop on read (lookup), the stored list is not rewritten because the session catalog is paged. Closing happens before the action runs; focus returns to the composer if it held it. Components: MacPaletteItem, MacPaletteMatcher, MacPaletteRecents, MacPaletteProvider, MacPaletteStore (+ MacPaletteCalls, MacPaletteDispatcher), MacPaletteBinding, MacPaletteView, MacPaletteActions. Upstream edit: one gated `.onReceive(.macOpenSettingsRequested)` in RootView (settingsLinkRequest only reaches the calls and voice pages). The overlay hangs on RootView in ConduitMacApp, so it needs no RootView edit. Out of scope: inline model list, server session search, tab commands, sending prompts.
```

Fill in anything the executor learned: which key-handling route Task 6 needed (modifier on panel, on field, or monitor) and the AppKit form of Cmd-K from Task 7. In D10's shortcut table add a row: `| Cmd-K | Go > Command Palette | toggles the palette (D15); ignored in non-chat windows and under a sheet |`.

- [ ] **Step 2: SMOKE_CHECKLIST.md**

Add to the first checklist (next to the other keyboard items):

```
- [ ] Cmd-K opens the palette from the composer, the sidebar and Bots/Cron/Kanban; Cmd-K again and Esc close it; with text in the composer the draft is untouched and typing resumes there after closing
- [ ] Palette: type a session name, Return opens it; `#`, `/`, `>`, `@` scope the list; Up/Down/Home/End move, Tab does nothing; Esc clears the query, then closes
- [ ] Palette: "/new" with no chat open is disabled with "No active chat"; a slash command with an argument hint (for example /title) lands in the composer as "/title " (replacing the draft)
- [ ] Palette: Switch Model... opens the model picker; Settings opens Settings; New Chat, Hide Sidebar, Check for Updates run; the active profile row shows a check and does nothing; Stop Response appears only while a reply streams
- [ ] Palette with a sheet open (Settings, model picker): Cmd-K does nothing; Japanese IME: Return confirms the composition and does not run the row
```

- [ ] **Step 3: Verify the whole branch**

Run in order, one xcodebuild at a time:
1. `xcodegen generate`
2. Build: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`
3. Full Mac suite twice: `xcodebuild test -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO` (expect all green except the known flaky orb test)
4. `git diff <base-commit> -- Conduit/Views/RootView.swift | grep '^-[^-]'` prints nothing, and `git diff <base-commit> --stat -- Conduit Shared` lists only `RootView.swift` and `Localizable.xcstrings` (plus the two unrelated pre-existing edits, which must stay unstaged and unmodified by you).
5. `python3 scripts/check-l10n-coverage.py --repo-root .` matches Task 8.
6. `grep -rn 'keyboardShortcut("k"' ConduitMac Conduit` shows exactly one hit.

Do not launch or interact with the user's running Conduit; the manual smoke items are for the release gate, not this task.

- [ ] **Step 4: Cleanup**

Per workspace rules: delete regenerable scratch (`build/dd` only if disk is tight, scratch worksheets from Task 8), stop any servers you started, and remove your worktree and branch after merge.

- [ ] **Step 5: Commit**

```bash
git add 'docs/macos/DECISIONS.md' 'docs/macos/SMOKE_CHECKLIST.md' 'docs/macos/PORTING_LEDGER.md'
git commit -m "docs: D15 mac command palette, smoke checklist, ledger"
```

---

## Execution notes

- Order: Tasks 1, 2, 3 are independent of each other in code except that 2 and 3 use Task 1's types; run 1 first, then 2 and 3 may run in parallel worktrees (different files), then 4, 5, 6, 7 in order, then 8 and 9. Merge and run the full suite after each merge.
- After all tasks: whole-branch review against the spec and the Review Focus list above, then merge into `macos`, run the full suite on the merge, remove worktrees.
- Effort check against the spec's estimate (about 5 days): Tasks 1 and 2 about 1.0, 3 and 4 about 1.5, 5 and 6 about 1.5, 7 to 9 about 1.0.
