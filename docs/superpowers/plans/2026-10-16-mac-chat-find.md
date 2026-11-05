# Mac Chat Find (Cmd-F across the whole transcript) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Cmd-F find bar for the main Mac chat window that searches every loaded message, shows "3 of 12", steps with Return / Shift-Return / Cmd-G / Cmd-Shift-G, highlights hits in every mounted message, and scrolls to a hit even when its row is not yet built.

**Architecture:** A pure core (plain-text projection of each message, a case- and diacritic-insensitive matcher, a cursor state) feeds a per-window main-actor `MacChatFindController`. Mounted `NSTextView`s register in a weak registry keyed by message id (id supplied by one environment value set at the row) and are highlighted with TextKit 1 temporary attributes. Scrolling reuses `ChatScrollEngine.explicitMessageRequested` for rows that are not built, then refines inside the transcript `NSScrollView`. The only upstream edit is one gated modifier line on the row in `ChatView.swift`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (TextKit 1) on macOS 14+, Combine, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-16-mac-chat-find-design.md` (draft; its open questions are resolved to the defaults listed under "Resolved Decisions").

## Global Constraints

- Mac only. Never run an iOS build or iOS tests. iOS behaviour is unchanged.
- New code lives under `ConduitMac/ChatFind/`; tests under `ConduitMacTests/`.
- Any edit to a shared `Conduit/` or `Shared/` file is wrapped in `#if os(macOS)` ... `#endif`, carries a `// MAC:` tag and gets one row in `docs/macos/PORTING_LEDGER.md`. Planned: exactly one region, `Conduit/Views/ChatView.swift` (Task 5). No `AppState.swift` edits (D11 precedent). `git diff <base> -- Conduit Shared | grep '^-[^-]'` must print nothing.
- Main chat window only: identifier prefix `conduit-primary`. Cmd-F, Cmd-G and Cmd-Shift-G do nothing in a window whose identifier starts with `conduit-session` (D21 session windows) and nothing while a sheet is attached or a floating panel (Quick Ask) is key (`MacKeyboardActions.commandsBlocked(by:)`). Menu items are never `.disabled` (D10: a stale-disabled item swallows its key).
- Shortcuts: Cmd-F (re-purposed, one contextual item), Cmd-G, Cmd-Shift-G. Do not use Cmd-, or Cmd-Shift-D (D22) or any other new shortcut (D24 unknown).
- D13: message text views are TextKit 1. Every helper that touches `layoutManager` first checks `textView.textLayoutManager == nil` and never converts a view to TextKit 2 or back.
- Temporary attributes only; never write highlight attributes into the text storage. Remove highlights only over ranges this feature applied (tracked per view), never a blanket removal over the whole text.
- Search scope: roles user, assistant, partial; text as drawn (markdown stripped, reply-quote envelope removed, assistant `code` appended). Not searched: system, reasoning, tool, clarify, approval, input-prompt rows, the live streaming tail. Match cap 5,000.
- Localization (docs/LOCALIZATION.md): every user-visible string is `AppLocalization.string("...")` or a SwiftUI literal for `Text`/`Button` titles, with an English source key; use if/else with two explicit `AppLocalization.string` calls, never a `String` ternary of raw literals; no singular built in code. Task 8 adds the keys for every shipped language through `scripts/l10n.py` and runs `scripts/check-l10n-coverage.py`.
- The working tree may have unrelated uncommitted edits. Never run `git add -A` or `git add .`; add explicit file paths only. Never revert or reformat edits you did not make.
- After adding any file run `xcodegen generate` (`ConduitMac/` and `ConduitMacTests/` are picked up by the folder globs in `project.yml`).
- Test one class: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/<Class>' CODE_SIGNING_ALLOWED=NO`. Never run two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- zsh: quote every glob and every path containing `*`, `[`, `?` (for example `git add 'ConduitMac/ChatFind/MacChatFindMatcher.swift'`).
- TDD: failing test, run to see it fail, minimal implementation, run to see it pass, commit.
- Tests: injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`, `settle`), explicit teardown, no fixed sleeps. Never touch the live app's defaults. The user's own Conduit may be running: do not quit, click or type into it.
- Data limits: matches capped at 5,000 (label "N of 5000+"); projection cache filled 40 messages per chunk; debounce 120 ms (query), 150 ms (transcript refresh); reveal retry every 250 ms, at most 6 times; placement passes at 50 ms and 250 ms; scroll band: top 48 pt covered by the bar, 16 pt bottom margin, target 35% down the viewport.
- Colors (fixed, both appearances): match background `sRGB(1.0, 0.93, 0.35)`, current match background `sRGB(1.0, 0.62, 0.10)`, text black; contrast of black on both at least 7:1.

## Resolved Decisions (spec open questions, spec defaults)

1. New query selects the newest (last) match; typing more keeps the nearest match at or below the previous one.
2. System rows and collapsed thinking / tool text are not searched in v1.
3. No "use selection" seeding; the bar reopens with the last query selected.
4. No new shortcut for Search Sessions: Cmd-F with the sidebar focused, Edit > Search Sessions (no key), and the palette.
5. Counts are not reconciled from live views; a parity test guards the common blocks.
6. Loaded transcript only; the bar says "Loaded messages only" when older pages exist.
7. Group-chat rooms and D21 session windows are out of scope.

## Review Focus

1. A query made of markup or regex characters (`[`, `(`, `*`, `\`, `.`) is literal, never crashes, and text that is only in a link destination, a fence marker or a table separator is not a hit. Tests: Task 1 (matcher literals, projection).
2. Return while an IME composition is marked must confirm the composition and not step or close; Shift-Return and Esc likewise. Test: Task 6 (`doCommandBy` mapping with marked text).
3. The transcript changing while the bar is open (a message settles, an older page is prepended, the session switches, the transcript empties): the current hit stays on the same message and ordinal when it survives, else falls to the nearest, the index never goes out of range, and no scroll happens on such a refresh. Tests: Tasks 2 and 4.
4. A hit in a row that was never built: the reveal retries a bounded number of times, places once the row registers, and a late registration after Esc or after another navigation does not scroll. Test: Task 4.
5. Closing the bar leaves no highlight behind, link colors in highlighted text are unchanged, and a view that unmounts is not kept alive by the registry. Tests: Tasks 3 and 5.

## File Map

- Create `ConduitMac/ChatFind/MacChatFindMatcher.swift`: `MacChatFindEntry`, `MacChatFindMatch`, `MacChatFindMatcher` (Task 1).
- Create `ConduitMac/ChatFind/MacChatFindText.swift`: `MacChatFindText`, `MacChatFindTextCache` (Task 1).
- Create `ConduitMac/ChatFind/MacChatFindState.swift`: `MacChatFindState`, `MacChatFindLabel` (Task 2).
- Create `ConduitMac/ChatFind/MacChatFindRegistry.swift`: `MacChatFindColors`, `MacChatFindHighlighter`, `MacChatFindScroll`, `MacChatFindRegistry` (Task 3).
- Create `ConduitMac/ChatFind/MacChatFindController.swift`: `MacChatFindController`, `MacChatFindControllers` (Task 4).
- Create `ConduitMac/ChatFind/MacChatFindEnvironment.swift`: environment keys, `macChatFindRow`, `macChatFind(appState:)`, window reader (Tasks 5 and 6).
- Create `ConduitMac/ChatFind/MacChatFindBar.swift`: bar view, `NSSearchField` wrapper, slot (Task 6).
- Modify `ConduitMac/Chat/SelectableTextView.swift`: register / unregister (Task 5).
- Modify `Conduit/Views/ChatView.swift`: one gated modifier line (Task 5).
- Modify `ConduitMac/App/MacDetailRouter.swift`, `ConduitMac/App/ConduitMacApp.swift` (Task 6).
- Modify `ConduitMac/App/MacKeyboardShortcuts.swift`, `ConduitMac/App/ConduitCommands.swift` (Task 7).
- Tests: `MacChatFindMatcherTests`, `MacChatFindTextTests` (1), `MacChatFindStateTests` (2), `MacChatFindRegistryTests` (3), `MacChatFindControllerTests` (4), `MacChatFindRowTests` (5), `MacChatFindBarTests` (6), `MacChatFindCommandsTests` and edits to `MacKeyboardMenuTests` in `MacKeyboardTests.swift` (7), `MacChatFindParityTests` (8).
- Docs: `docs/macos/DECISIONS.md`, `docs/macos/PORTING_LEDGER.md`, `docs/macos/SMOKE_CHECKLIST.md` (Task 9); `Conduit/Localizable.xcstrings` (Task 8).

---

### Task 1: Matcher and message text projection

**Files:**
- Create: `ConduitMac/ChatFind/MacChatFindMatcher.swift`, `ConduitMac/ChatFind/MacChatFindText.swift`
- Test: `ConduitMacTests/MacChatFindMatcherTests.swift`, `ConduitMacTests/MacChatFindTextTests.swift`

**Interfaces:**
- Consumes: `ChatMessage`, `MessageRole` (`Conduit/Models/Models.swift`), `ReplyQuoteEnvelope.parse` (`Conduit/Views/Components/ChatQuote.swift:88`), `MarkdownParser.parseDocument`, `InlineMarkdownContent.attributed`, `MarkdownLanguage.normalized` (`Conduit/Views/Components/MarkdownText.swift`).
- Produces:
  - `struct MacChatFindEntry: Equatable { let id: String; let text: String }`
  - `struct MacChatFindMatch: Equatable, Hashable { let messageID: String; let ordinal: Int; let range: NSRange }`
  - `enum MacChatFindMatcher { static let defaultLimit = 5_000; static func isSearchable(_ query: String) -> Bool; static func ranges(of query: String, in text: String, limit: Int = .max) -> [NSRange]; static func matches(of query: String, in entries: [MacChatFindEntry], limit: Int = defaultLimit) -> (matches: [MacChatFindMatch], truncated: Bool) }`
  - `enum MacChatFindText { static func isSearchable(_ role: MessageRole) -> Bool; static func searchableText(for message: ChatMessage) -> String?; static func plain(fromMarkdown source: String) -> String }`
  - `@MainActor final class MacChatFindTextCache { init(); func entries(for messages: [ChatMessage]) -> [MacChatFindEntry]; func prime(_ messages: [ChatMessage], chunk: Int = 40) async }`

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacChatFindMatcherTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class MacChatFindMatcherTests: XCTestCase {
    func testCaseAndDiacriticInsensitive() {
        let hits = MacChatFindMatcher.ranges(of: "cafe", in: "Café CAFÉ cafe")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.first, NSRange(location: 0, length: 4))
    }

    func testAccentedQueryFindsPlainLetters() {
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "café", in: "cafe CAFE").count, 2)
    }

    func testHitsDoNotOverlap() {
        XCTAssertEqual(
            MacChatFindMatcher.ranges(of: "aa", in: "aaaa"),
            [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)]
        )
    }

    func testQueryIsLiteral() {
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "[x](", in: "see [x](y) and [x](z)").count, 2)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "a.c", in: "abc a.c").count, 1)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "*", in: "a*b**c").count, 3)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "\\", in: "a\\b").count, 1)
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "(", in: "f(x) g(y)").count, 2)
    }

    func testEmptyAndWhitespaceQueriesMatchNothing() {
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "", in: "abc").isEmpty)
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "   ", in: "a b c").isEmpty)
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "\n", in: "a\nb").isEmpty)
        XCTAssertFalse(MacChatFindMatcher.isSearchable(" \t"))
        XCTAssertTrue(MacChatFindMatcher.isSearchable(" a"))
    }

    func testQueryKeepsInnerAndTrailingSpaces() {
        XCTAssertEqual(MacChatFindMatcher.ranges(of: "a b ", in: "a b c"), [NSRange(location: 0, length: 4)])
        XCTAssertTrue(MacChatFindMatcher.ranges(of: "a b ", in: "a bc").isEmpty)
    }

    func testRangesAreUTF16InNonBMPText() {
        XCTAssertEqual(
            MacChatFindMatcher.ranges(of: "\u{1F600}", in: "x\u{1F600}y\u{1F600}"),
            [NSRange(location: 1, length: 2), NSRange(location: 4, length: 2)]
        )
    }

    func testMatchesAreInEntryOrderWithPerMessageOrdinals() {
        let entries = [
            MacChatFindEntry(id: "m1", text: "foo bar foo"),
            MacChatFindEntry(id: "m2", text: "nothing here"),
            MacChatFindEntry(id: "m3", text: "FOO"),
        ]
        let result = MacChatFindMatcher.matches(of: "foo", in: entries)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.matches.map(\.messageID), ["m1", "m1", "m3"])
        XCTAssertEqual(result.matches.map(\.ordinal), [0, 1, 0])
        XCTAssertEqual(result.matches[1].range, NSRange(location: 8, length: 3))
    }

    func testCapTruncatesAndFlagsOnlyWhenMoreExist() {
        let entries = (1...3).map { MacChatFindEntry(id: "m\($0)", text: "x x x x") }
        let capped = MacChatFindMatcher.matches(of: "x", in: entries, limit: 5)
        XCTAssertEqual(capped.matches.count, 5)
        XCTAssertTrue(capped.truncated)
        let exact = MacChatFindMatcher.matches(of: "x", in: entries, limit: 12)
        XCTAssertEqual(exact.matches.count, 12)
        XCTAssertFalse(exact.truncated, "exactly the limit is not truncation")
        let tail = MacChatFindMatcher.matches(
            of: "x", in: entries + [MacChatFindEntry(id: "m4", text: "none")], limit: 12
        )
        XCTAssertFalse(tail.truncated, "later entries without hits do not flag truncation")
    }

    func testHugeSingleMessageStaysBounded() {
        let entry = MacChatFindEntry(id: "big", text: String(repeating: "needle ", count: 200_000))
        let result = MacChatFindMatcher.matches(of: "needle", in: [entry])
        XCTAssertEqual(result.matches.count, MacChatFindMatcher.defaultLimit)
        XCTAssertTrue(result.truncated)
    }
}
```

`ConduitMacTests/MacChatFindTextTests.swift`:

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindTextTests: XCTestCase {
    private func message(_ id: String, _ role: MessageRole, _ content: String, code: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, content: content, timestamp: "", code: code)
    }

    func testLinkDestinationIsNotSearchable() {
        let text = MacChatFindText.plain(fromMarkdown: "See [the docs](https://example.com/guide) now")
        XCTAssertTrue(text.contains("the docs"))
        XCTAssertFalse(text.contains("example"))
        XCTAssertFalse(text.contains("]("))
    }

    func testEmphasisAndCodeSpansAreStripped() {
        let text = MacChatFindText.plain(fromMarkdown: "**bold** and `code` and *it*")
        XCTAssertTrue(text.contains("bold and code and it"))
        XCTAssertFalse(text.contains("*"))
        XCTAssertFalse(text.contains("`"))
    }

    func testFenceMarkersAreAbsentButCodeIsKept() {
        let text = MacChatFindText.plain(fromMarkdown: "Run:\n\n```swift\nlet x = 1\n```\n")
        XCTAssertTrue(text.contains("let x = 1"))
        XCTAssertFalse(text.contains("```"))
    }

    func testTableSeparatorsAreAbsentButCellsAreKept() {
        let text = MacChatFindText.plain(fromMarkdown: "| h1 | h2 |\n|---|---|\n| c1 | c2 |\n")
        for cell in ["h1", "h2", "c1", "c2"] { XCTAssertTrue(text.contains(cell), cell) }
        XCTAssertFalse(text.contains("---"))
        XCTAssertFalse(text.contains("|"))
    }

    func testListMarkersAndHeadingHashesAreAbsent() {
        let text = MacChatFindText.plain(fromMarkdown: "# Title\n\n- one\n- two\n")
        XCTAssertTrue(text.contains("Title"))
        XCTAssertTrue(text.contains("one"))
        XCTAssertTrue(text.contains("two"))
        XCTAssertFalse(text.contains("# "))
        XCTAssertFalse(text.contains("- one"))
    }

    func testOnlyUserAssistantAndPartialRowsAreSearchable() {
        XCTAssertNotNil(MacChatFindText.searchableText(for: message("u", .user, "hi there")))
        XCTAssertNotNil(MacChatFindText.searchableText(for: message("a", .assistant, "hello")))
        XCTAssertNotNil(MacChatFindText.searchableText(for: message("p", .partial, "partial")))
        for role in [MessageRole.system, .reasoning, .tool, .clarify, .approval, .inputPrompt] {
            XCTAssertNil(MacChatFindText.searchableText(for: message("x", role, "text")), "\(role)")
        }
    }

    func testEmptyOrBlankContentIsNotSearchable() {
        XCTAssertNil(MacChatFindText.searchableText(for: message("a", .assistant, "")))
        XCTAssertNil(MacChatFindText.searchableText(for: message("a", .assistant, " \n ")))
    }

    func testReplyQuoteEnvelopeIsRemovedFromUserRows() {
        let sent = ReplyQuoteEnvelope.outboundText(quoting: "earlier reply words", message: "my own words")
        let text = MacChatFindText.searchableText(for: message("u", .user, sent))
        XCTAssertEqual(text, "my own words")
    }

    func testAssistantCodeBlockIsAppendedAfterTheText() {
        let text = MacChatFindText.searchableText(for: message("a", .assistant, "before", code: "let needle = 1"))
        XCTAssertEqual(text, "before\nlet needle = 1")
        XCTAssertNil(
            MacChatFindText.searchableText(for: message("u", .user, "", code: "ignored")),
            "a user row draws no code block"
        )
    }

    func testCacheReturnsEntriesInOrderAndSkipsUnsearchableRows() {
        let cache = MacChatFindTextCache()
        let entries = cache.entries(for: [
            message("1", .user, "alpha"),
            message("2", .tool, "skipped"),
            message("3", .assistant, "beta"),
        ])
        XCTAssertEqual(entries.map(\.id), ["1", "3"])
        XCTAssertEqual(entries.map(\.text), ["alpha", "beta"])
    }

    func testCacheNoticesAnEditedMessage() {
        let cache = MacChatFindTextCache()
        _ = cache.entries(for: [message("1", .assistant, "old")])
        let entries = cache.entries(for: [message("1", .assistant, "new")])
        XCTAssertEqual(entries.map(\.text), ["new"])
    }

    func testPrimeFillsTheCacheWithoutChangingResults() async {
        let cache = MacChatFindTextCache()
        let messages = (0..<130).map { message("m\($0)", .assistant, "text \($0)") }
        await cache.prime(messages, chunk: 40)
        let entries = cache.entries(for: messages)
        XCTAssertEqual(entries.count, 130)
        XCTAssertEqual(entries[129].text, "text 129")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindMatcherTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile ("cannot find 'MacChatFindMatcher' in scope").

- [ ] **Step 3: Write the matcher**

`ConduitMac/ChatFind/MacChatFindMatcher.swift`:

```swift
import Foundation

/// One searchable message: its id and the plain text the transcript draws for it.
struct MacChatFindEntry: Equatable {
    let id: String
    let text: String
}

/// One hit. `ordinal` counts hits inside the message from 0 in reading order;
/// `range` is UTF-16, in the entry's projected text.
struct MacChatFindMatch: Equatable, Hashable {
    let messageID: String
    let ordinal: Int
    let range: NSRange
}

/// Pure search (D23): literal, case- and diacritic-insensitive, non-overlapping.
enum MacChatFindMatcher {
    static let defaultLimit = 5_000
    static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// An empty or whitespace-only query matches nothing. Anything else is used
    /// exactly as typed (inner and trailing spaces count).
    static func isSearchable(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func ranges(of query: String, in text: String, limit: Int = .max) -> [NSRange] {
        guard isSearchable(query), !text.isEmpty else { return [] }
        let haystack = text as NSString
        var found: [NSRange] = []
        var from = 0
        while from < haystack.length, found.count < limit {
            let hit = haystack.range(
                of: query,
                options: options,
                range: NSRange(location: from, length: haystack.length - from)
            )
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            found.append(hit)
            from = hit.location + hit.length
        }
        return found
    }

    /// Hits over all entries in entry order. `truncated` is true only when at
    /// least one hit beyond `limit` exists.
    static func matches(
        of query: String,
        in entries: [MacChatFindEntry],
        limit: Int = defaultLimit
    ) -> (matches: [MacChatFindMatch], truncated: Bool) {
        guard isSearchable(query) else { return ([], false) }
        var all: [MacChatFindMatch] = []
        for entry in entries {
            let room = limit - all.count
            let found = ranges(of: query, in: entry.text, limit: room + 1)
            for (ordinal, range) in found.prefix(room).enumerated() {
                all.append(MacChatFindMatch(messageID: entry.id, ordinal: ordinal, range: range))
            }
            if found.count > room { return (all, true) }
        }
        return (all, false)
    }
}
```

- [ ] **Step 4: Write the projection and cache**

`ConduitMac/ChatFind/MacChatFindText.swift`:

```swift
import Foundation

/// The plain text a message draws, for searching rows that are not built.
/// Built with the same parser and inline builder the views use, so link
/// destinations, emphasis marks, fences and table separators are absent.
enum MacChatFindText {
    static func isSearchable(_ role: MessageRole) -> Bool {
        switch role {
        case .user, .assistant, .partial: return true
        case .system, .reasoning, .tool, .clarify, .approval, .inputPrompt: return false
        }
    }

    /// nil: the row is not searched, or draws no text.
    static func searchableText(for message: ChatMessage) -> String? {
        guard isSearchable(message.role) else { return nil }
        var parts: [String] = []
        // The user bubble draws the reply-quote envelope as a card, not as text.
        let source = message.role == .user
            ? (ReplyQuoteEnvelope.parse(message.content)?.message ?? message.content)
            : message.content
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(plain(fromMarkdown: source))
        }
        if message.role != .user, let code = message.code, !code.isEmpty {
            parts.append(code)
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    static func plain(fromMarkdown source: String) -> String {
        let document = MarkdownParser.parseDocument(source)
        let references = document.references
        func inline(_ text: String) -> String {
            String(InlineMarkdownContent.attributed(source: text, references: references).characters)
        }
        var lines: [String] = []
        for block in document.blocks {
            switch block {
            case .heading(_, let text), .paragraph(let text):
                lines.append(inline(text))
            case .callout(_, let text):
                lines.append(inline(text))
            case .quote(let quoteLines):
                lines.append(contentsOf: quoteLines.map { inline($0.text) })
            case .unorderedList(let items), .orderedList(let items):
                lines.append(contentsOf: items.map { inline($0) })
            case .table(let headers, _, let rows):
                lines.append(contentsOf: ([headers] + rows).flatMap { row in row.map { inline($0) } })
            case .columns(let columns):
                lines.append(contentsOf: columns.map { inline($0) })
            case .code(let language, let code):
                // Mermaid draws a diagram, not text.
                if MarkdownLanguage.normalized(language) != "mermaid" { lines.append(code) }
            case .image, .math, .divider:
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Projection cache keyed by message id; an entry is reused only while the
/// role, content and code are unchanged. `entries` keeps just the messages it
/// was given, so a session switch drops the old session's text.
@MainActor
final class MacChatFindTextCache {
    private struct Key: Equatable {
        let role: MessageRole
        let content: String
        let code: String?
    }

    private var storage: [String: (key: Key, text: String?)] = [:]

    private static func key(of message: ChatMessage) -> Key {
        Key(role: message.role, content: message.content, code: message.code)
    }

    func entries(for messages: [ChatMessage]) -> [MacChatFindEntry] {
        var next: [String: (key: Key, text: String?)] = [:]
        next.reserveCapacity(messages.count)
        var out: [MacChatFindEntry] = []
        for message in messages {
            let key = Self.key(of: message)
            let text: String?
            if let hit = storage[message.id], hit.key == key {
                text = hit.text
            } else {
                text = MacChatFindText.searchableText(for: message)
            }
            next[message.id] = (key, text)
            if let text { out.append(MacChatFindEntry(id: message.id, text: text)) }
        }
        storage = next
        return out
    }

    /// Fills the cache ahead of the first search without holding the main
    /// actor for long: yields after every `chunk` projections.
    func prime(_ messages: [ChatMessage], chunk: Int = 40) async {
        var computed = 0
        for message in messages {
            if Task.isCancelled { return }
            let key = Self.key(of: message)
            if let hit = storage[message.id], hit.key == key { continue }
            storage[message.id] = (key, MacChatFindText.searchableText(for: message))
            computed += 1
            if computed % chunk == 0 { await Task.yield() }
        }
    }
}
```

If `MarkdownParser.parseDocument`, `InlineMarkdownContent` or `MarkdownLanguage` is not reachable from the Mac module with exactly these names, read the declarations at `Conduit/Views/Components/MarkdownText.swift:922`, `:2322` and `MarkdownLanguage` (grep `enum MarkdownLanguage`) and adjust the calls; do not copy the parser.

- [ ] **Step 5: Run to verify they pass**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindMatcherTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (10 tests).
Run: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindTextTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (12 tests). If a markdown expectation fails because the parser renders a construct differently (for example the table case), print `MacChatFindText.plain(fromMarkdown:)` for the sample, fix the projection (not the test) when the difference is a bug, and relax the assertion only when the drawn text really is what the output shows.

- [ ] **Step 6: Commit**

```bash
git add 'ConduitMac/ChatFind/MacChatFindMatcher.swift' 'ConduitMac/ChatFind/MacChatFindText.swift' 'ConduitMacTests/MacChatFindMatcherTests.swift' 'ConduitMacTests/MacChatFindTextTests.swift'
git commit -m "feat(mac): chat find matcher and message text projection (D23)"
```

---

### Task 2: Cursor state and count label

**Files:**
- Create: `ConduitMac/ChatFind/MacChatFindState.swift`
- Test: `ConduitMacTests/MacChatFindStateTests.swift`

**Interfaces:**
- Consumes: `MacChatFindMatch`, `MacChatFindMatcher.isSearchable` (Task 1); `AppLocalization.string` (`Conduit/Services/AppLanguage.swift:231`).
- Produces:
  - `struct MacChatFindState: Equatable` with `private(set) var matches: [MacChatFindMatch]`, `private(set) var currentIndex: Int?`, `private(set) var isTruncated: Bool`, `var count: Int`, `var current: MacChatFindMatch?`, `var position: Int?` (1-based), `enum Anchor: Equatable { case newest; case keeping(MacChatFindMatch, order: [String: Int]); case near(messageID: String, order: [String: Int]) }`, `mutating func replace(matches: [MacChatFindMatch], truncated: Bool, anchor: Anchor)`, `mutating func next()`, `mutating func previous()`.
  - `enum MacChatFindLabel { static func text(query: String, state: MacChatFindState) -> String }`

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacChatFindStateTests.swift`:

```swift
import XCTest
@testable import ConduitMac

final class MacChatFindStateTests: XCTestCase {
    private func match(_ id: String, _ ordinal: Int = 0) -> MacChatFindMatch {
        MacChatFindMatch(messageID: id, ordinal: ordinal, range: NSRange(location: ordinal * 4, length: 3))
    }

    private let order = ["m1": 0, "m2": 1, "m3": 2, "m4": 3]

    private func state(_ matches: [MacChatFindMatch], anchor: MacChatFindState.Anchor = .newest) -> MacChatFindState {
        var s = MacChatFindState()
        s.replace(matches: matches, truncated: false, anchor: anchor)
        return s
    }

    func testFreshQuerySelectsTheNewestMatch() {
        let s = state([match("m1"), match("m2"), match("m3")])
        XCTAssertEqual(s.current, match("m3"))
        XCTAssertEqual(s.position, 3)
        XCTAssertEqual(s.count, 3)
    }

    func testNextAndPreviousWrap() {
        var s = state([match("m1"), match("m2"), match("m3")])
        s.next()
        XCTAssertEqual(s.position, 1, "wraps from last to first")
        s.previous()
        XCTAssertEqual(s.position, 3, "wraps from first to last")
        s.previous()
        XCTAssertEqual(s.position, 2)
    }

    func testStepsDoNothingWithoutMatches() {
        var s = state([])
        s.next(); s.previous()
        XCTAssertNil(s.current)
        XCTAssertNil(s.position)
        XCTAssertEqual(s.count, 0)
    }

    func testNearAnchorStaysOnTheSameMessageWhenItStillMatches() {
        let s = state([match("m1"), match("m2"), match("m4")], anchor: .near(messageID: "m2", order: order))
        XCTAssertEqual(s.current, match("m2"))
    }

    func testNearAnchorMovesToTheNextMessageDownWhenItsMessageNoLongerMatches() {
        let s = state([match("m1"), match("m4")], anchor: .near(messageID: "m2", order: order))
        XCTAssertEqual(s.current, match("m4"))
    }

    func testNearAnchorFallsBackToTheNewestWhenNothingIsBelow() {
        let s = state([match("m1"), match("m2")], anchor: .near(messageID: "m4", order: order))
        XCTAssertEqual(s.current, match("m2"))
    }

    func testNearAnchorWithAnUnknownMessageFallsBackToTheNewest() {
        let s = state([match("m1"), match("m2")], anchor: .near(messageID: "gone", order: order))
        XCTAssertEqual(s.current, match("m2"))
    }

    func testKeepingFindsTheSameMessageAndOrdinal() {
        let old = match("m2", 1)
        let s = state(
            [match("m1"), match("m2", 0), match("m2", 1), match("m3")],
            anchor: .keeping(old, order: order)
        )
        XCTAssertEqual(s.position, 3)
    }

    func testKeepingFallsBackToNearWhenTheHitVanished() {
        let s = state(
            [match("m1"), match("m3")],
            anchor: .keeping(match("m2", 5), order: order)
        )
        XCTAssertEqual(s.current, match("m3"))
    }

    func testReplaceWithNoMatchesClearsTheCursor() {
        var s = state([match("m1")])
        s.replace(matches: [], truncated: false, anchor: .keeping(match("m1"), order: order))
        XCTAssertNil(s.currentIndex)
        XCTAssertNil(s.current)
    }

    func testIndexNeverLeavesTheRangeAfterAShrinkingRefresh() {
        var s = state([match("m1"), match("m2"), match("m3")])
        s.replace(matches: [match("m1")], truncated: false, anchor: .keeping(match("m3"), order: order))
        XCTAssertEqual(s.currentIndex, 0)
        s.next()
        XCTAssertEqual(s.currentIndex, 0)
    }

    func testLabels() {
        var s = state([match("m1"), match("m2")])
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: s), "2 of 2")
        s.previous()
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: s), "1 of 2")
        XCTAssertEqual(MacChatFindLabel.text(query: "", state: s), "", "no query, no label")
        XCTAssertEqual(MacChatFindLabel.text(query: "  ", state: s), "")
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: state([])), "No matches")
        var capped = MacChatFindState()
        capped.replace(matches: [match("m1")], truncated: true, anchor: .newest)
        XCTAssertEqual(MacChatFindLabel.text(query: "foo", state: capped), "1 of 1+")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindStateTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile ("cannot find 'MacChatFindState' in scope").

- [ ] **Step 3: Write the state**

`ConduitMac/ChatFind/MacChatFindState.swift`:

```swift
import Foundation

/// The matches of the current query and which one is selected (D23). Pure.
struct MacChatFindState: Equatable {
    private(set) var matches: [MacChatFindMatch] = []
    private(set) var currentIndex: Int?
    private(set) var isTruncated = false

    /// Which hit to select after the matches are replaced. `order` maps a
    /// message id to its position in the transcript.
    enum Anchor: Equatable {
        /// A fresh query: the newest hit (the transcript is read from the bottom).
        case newest
        /// A refresh: the same message and ordinal if it still matches, else the nearest.
        case keeping(MacChatFindMatch, order: [String: Int])
        /// The query changed: the first hit at or below this message, else the newest.
        case near(messageID: String, order: [String: Int])
    }

    var count: Int { matches.count }
    var current: MacChatFindMatch? { currentIndex.map { matches[$0] } }
    /// 1-based, for "3 of 12".
    var position: Int? { currentIndex.map { $0 + 1 } }

    mutating func replace(matches: [MacChatFindMatch], truncated: Bool, anchor: Anchor) {
        self.matches = matches
        isTruncated = truncated
        guard !matches.isEmpty else {
            currentIndex = nil
            return
        }
        switch anchor {
        case .newest:
            currentIndex = matches.count - 1
        case .keeping(let old, let order):
            if let same = matches.firstIndex(where: { $0.messageID == old.messageID && $0.ordinal == old.ordinal }) {
                currentIndex = same
            } else {
                currentIndex = Self.nearest(to: old.messageID, in: matches, order: order)
            }
        case .near(let messageID, let order):
            currentIndex = Self.nearest(to: messageID, in: matches, order: order)
        }
    }

    mutating func next() {
        guard let index = currentIndex, !matches.isEmpty else { return }
        currentIndex = (index + 1) % matches.count
    }

    mutating func previous() {
        guard let index = currentIndex, !matches.isEmpty else { return }
        currentIndex = (index - 1 + matches.count) % matches.count
    }

    private static func nearest(to messageID: String, in matches: [MacChatFindMatch], order: [String: Int]) -> Int {
        guard let anchor = order[messageID] else { return matches.count - 1 }
        return matches.firstIndex { (order[$0.messageID] ?? Int.max) >= anchor } ?? matches.count - 1
    }
}

/// The text next to the bar's chevrons.
enum MacChatFindLabel {
    static func text(query: String, state: MacChatFindState) -> String {
        guard MacChatFindMatcher.isSearchable(query) else { return "" }
        guard let position = state.position else { return AppLocalization.string("No matches") }
        if state.isTruncated {
            return String(format: AppLocalization.string("%d of %d+"), position, state.count)
        }
        return String(format: AppLocalization.string("%d of %d"), position, state.count)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindStateTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (12 tests). If `testLabels` fails because `AppLocalization.string` returns something other than the English key for these formats in the test host, read `AppLocalization.string` (`Conduit/Services/AppLanguage.swift:231`) and make the test compare against `String(format: AppLocalization.string(...))` instead of literals.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/ChatFind/MacChatFindState.swift' 'ConduitMacTests/MacChatFindStateTests.swift'
git commit -m "feat(mac): chat find cursor state and count label (D23)"
```

---

### Task 3: Highlighter, registry and scroll helper

**Files:**
- Create: `ConduitMac/ChatFind/MacChatFindRegistry.swift`
- Test: `ConduitMacTests/MacChatFindRegistryTests.swift`

**Interfaces:**
- Consumes: `MacChatFindMatcher.ranges`, `MacChatFindMatch` (Task 1); `SelectableTextView.makeTextView` (existing, tests only).
- Produces:
  - `enum MacChatFindColors { static let match: NSColor; static let current: NSColor; static let text: NSColor; static func contrast(_ a: NSColor, _ b: NSColor) -> Double }`
  - `@MainActor enum MacChatFindHighlighter { @discardableResult static func apply(to textView: NSTextView, ranges: [NSRange], current: Int?, replacing previous: [NSRange]) -> [NSRange]; static func clear(_ textView: NSTextView, ranges: [NSRange]) }`
  - `enum MacChatFindScroll { static let barHeight: CGFloat = 48; static let bottomMargin: CGFloat = 16; static let anchorFraction: CGFloat = 0.35; static func targetOffset(rect: CGRect, offset: CGFloat, viewportHeight: CGFloat, documentHeight: CGFloat) -> CGFloat?; @MainActor static func reveal(_ range: NSRange, in view: NSTextView) }`
  - `@MainActor final class MacChatFindRegistry` with `struct Context: Equatable { var query: String; var current: MacChatFindMatch?; var searchable: Set<String> }`, `private(set) var context: Context?`, `var didRegister: ((String) -> Void)?`, `func register(_ view: NSTextView, messageID: String)`, `func unregister(_ view: NSTextView)`, `func views(for messageID: String) -> [NSTextView]` (reading order), `var mountedViewCount: Int`, `func setContext(_ context: Context?)`, `func contains(_ responder: NSResponder?) -> Bool`, `static func readingOrder(_ a: NSTextView, _ b: NSTextView) -> Bool`, `static func locate(ordinal: Int, counts: [Int]) -> (view: Int, local: Int)?`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacChatFindRegistryTests.swift`:

```swift
import AppKit
import XCTest
@testable import ConduitMac

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class MacChatFindRegistryTests: XCTestCase {
    private var window: NSWindow!
    private var host: FlippedDocument!
    private var nextY: CGFloat = 0

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        window.contentView = host
        nextY = 0
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        host = nil
    }

    /// A message text view. Hosted views are stacked top to bottom in creation
    /// order, so reading order is deterministic; `hosted: false` leaves it free.
    private func textView(_ string: String, width: CGFloat = 300, hosted: Bool = true) -> NSTextView {
        let view = SelectableTextView.makeTextView()
        view.frame = NSRect(x: 0, y: nextY, width: width, height: 40)
        view.string = string
        if hosted {
            host.addSubview(view)
            nextY += 60
        }
        return view
    }

    private func background(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    private func foreground(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    // MARK: colors

    func testBlackTextClearsSevenToOneOnBothHighlightColors() {
        XCTAssertGreaterThanOrEqual(MacChatFindColors.contrast(MacChatFindColors.text, MacChatFindColors.match), 7)
        XCTAssertGreaterThanOrEqual(MacChatFindColors.contrast(MacChatFindColors.text, MacChatFindColors.current), 7)
        XCTAssertGreaterThan(MacChatFindColors.contrast(.white, .black), 20, "the helper reads 21:1 for black on white")
    }

    // MARK: locate

    func testLocateWalksViewsInOrder() {
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 0, counts: [2, 3])?.view, 0)
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 1, counts: [2, 3])?.local, 1)
        let third = MacChatFindRegistry.locate(ordinal: 2, counts: [2, 3])
        XCTAssertEqual(third?.view, 1)
        XCTAssertEqual(third?.local, 0)
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 4, counts: [2, 3])?.local, 2)
        XCTAssertNil(MacChatFindRegistry.locate(ordinal: 5, counts: [2, 3]))
        XCTAssertNil(MacChatFindRegistry.locate(ordinal: -1, counts: [2, 3]))
        XCTAssertNil(MacChatFindRegistry.locate(ordinal: 0, counts: []))
        XCTAssertEqual(MacChatFindRegistry.locate(ordinal: 0, counts: [0, 1])?.view, 1, "an empty view is skipped")
    }

    // MARK: scroll math

    func testTargetOffsetIsNilWhileTheRectIsInTheComfortableBand() {
        let rect = CGRect(x: 0, y: 300, width: 50, height: 20)
        XCTAssertNil(MacChatFindScroll.targetOffset(rect: rect, offset: 200, viewportHeight: 400, documentHeight: 2000))
    }

    func testTargetOffsetCentersAHitBelowTheViewportAtThirtyFivePercent() {
        let rect = CGRect(x: 0, y: 1000, width: 50, height: 20)
        let y = MacChatFindScroll.targetOffset(rect: rect, offset: 0, viewportHeight: 400, documentHeight: 2000)
        XCTAssertEqual(y ?? -1, 1010 - 140, accuracy: 0.5)
    }

    func testTargetOffsetTreatsTheBarAsCoveringTheTop() {
        let underBar = CGRect(x: 0, y: 210, width: 50, height: 20)
        XCTAssertNotNil(MacChatFindScroll.targetOffset(rect: underBar, offset: 200, viewportHeight: 400, documentHeight: 2000))
    }

    func testTargetOffsetClampsToTheDocument() {
        let top = MacChatFindScroll.targetOffset(rect: CGRect(x: 0, y: 5, width: 10, height: 10), offset: 500, viewportHeight: 400, documentHeight: 2000)
        XCTAssertEqual(top, 0)
        let bottom = MacChatFindScroll.targetOffset(rect: CGRect(x: 0, y: 1990, width: 10, height: 10), offset: 0, viewportHeight: 400, documentHeight: 2000)
        XCTAssertEqual(bottom, 1600)
    }

    func testRevealMovesTheTranscriptScrollViewToTheHit() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        let view = textView(String(repeating: "filler line\n", count: 120) + "the needle is here")
        view.frame = NSRect(x: 0, y: 1000, width: 300, height: 1900)
        document.addSubview(view)   // moves it out of the shared host
        scroll.documentView = document
        let scrollWindow = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        scrollWindow.isReleasedWhenClosed = false
        scrollWindow.contentView = scroll
        defer { scrollWindow.close() }
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let range = (view.string as NSString).range(of: "needle")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
        MacChatFindScroll.reveal(range, in: view)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 1000, "scrolled down to the hit")
        let visible = scroll.contentView.bounds
        let rectInDocument = document.convert(
            view.layoutManager!.boundingRect(
                forGlyphRange: view.layoutManager!.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                in: view.textContainer!
            ),
            from: view
        )
        XCTAssertTrue(visible.intersects(rectInDocument), "the hit is inside the visible rect")
    }

    // MARK: reading order

    func testViewsOfAMessageComeBackInReadingOrder() {
        let lower = textView("lower")
        lower.frame = NSRect(x: 0, y: 200, width: 150, height: 40)
        let upperRight = textView("upper right")
        upperRight.frame = NSRect(x: 200, y: 10, width: 150, height: 40)
        let upperLeft = textView("upper left")
        upperLeft.frame = NSRect(x: 0, y: 10, width: 150, height: 40)
        let registry = MacChatFindRegistry()
        registry.register(lower, messageID: "m")
        registry.register(upperRight, messageID: "m")
        registry.register(upperLeft, messageID: "m")
        XCTAssertEqual(registry.views(for: "m").map(\.string), ["upper left", "upper right", "lower"])
    }

    // MARK: highlighting

    func testContextHighlightsEveryHitAndMarksTheCurrentOne() {
        let registry = MacChatFindRegistry()
        let first = textView("beta one")
        let second = textView("two beta beta")
        registry.register(first, messageID: "m")
        registry.register(second, messageID: "m")
        let current = MacChatFindMatch(messageID: "m", ordinal: 2, range: NSRange(location: 9, length: 4))
        registry.setContext(.init(query: "beta", current: current, searchable: ["m"]))
        let wanted = [(first, 0, MacChatFindColors.match), (second, 4, MacChatFindColors.match), (second, 9, MacChatFindColors.current)]
        for (view, index, color) in wanted {
            XCTAssertEqual(background(view, at: index), color, "\(view.string)@\(index)")
            XCTAssertEqual(foreground(view, at: index), MacChatFindColors.text)
        }
        XCTAssertNil(background(first, at: 5), "text outside a hit is untouched")
    }

    func testMessagesOutsideTheSearchableSetAreLeftAlone() {
        let registry = MacChatFindRegistry()
        let view = textView("beta here")
        registry.register(view, messageID: "tool-card")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["other"]))
        XCTAssertNil(background(view, at: 0))
    }

    func testClearingTheContextRemovesEveryHighlight() {
        let registry = MacChatFindRegistry()
        let view = textView("beta beta")
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        XCTAssertNotNil(background(view, at: 0))
        registry.setContext(nil)
        XCTAssertNil(background(view, at: 0))
        XCTAssertNil(background(view, at: 5))
        XCTAssertNil(foreground(view, at: 0))
    }

    func testChangingTheQueryReplacesTheOldHighlights() {
        let registry = MacChatFindRegistry()
        let view = textView("alpha beta")
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "alpha", current: nil, searchable: ["m"]))
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        XCTAssertNil(background(view, at: 0), "alpha is no longer a hit")
        XCTAssertNotNil(background(view, at: 6))
    }

    func testRegisteringAViewWhileSearchingHighlightsItAtOnce() {
        let registry = MacChatFindRegistry()
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        let late = textView("a beta")
        registry.register(late, messageID: "m")
        XCTAssertNotNil(background(late, at: 2))
    }

    func testReRegisteringAfterNewTextReHighlightsWithoutStaleRanges() {
        let registry = MacChatFindRegistry()
        let view = textView("beta beta beta")
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        view.string = "x beta"
        registry.register(view, messageID: "m")
        XCTAssertNotNil(background(view, at: 2))
        XCTAssertNil(background(view, at: 0))
    }

    func testClearingLeavesLinkRangesWithTheirOriginalTemporaryAttributes() {
        let view = textView("see docs now")
        let docs = (view.string as NSString).range(of: "docs")
        view.textStorage?.addAttributes([.link: URL(string: "https://example.com")!, .foregroundColor: NSColor.systemBlue], range: docs)
        let before = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: docs.location, effectiveRange: nil) as? NSColor
        let registry = MacChatFindRegistry()
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "docs", current: nil, searchable: ["m"]))
        XCTAssertEqual(foreground(view, at: docs.location), MacChatFindColors.text)
        registry.setContext(nil)
        let after = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: docs.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(after, before)
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: docs.location, effectiveRange: nil) as? NSColor, .systemBlue)
    }

    func testATextKit2ViewIsNeverTouched() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))   // TextKit 2 by default
        view.string = "beta"
        XCTAssertNotNil(view.textLayoutManager)
        let registry = MacChatFindRegistry()
        registry.register(view, messageID: "m")
        registry.setContext(.init(query: "beta", current: nil, searchable: ["m"]))
        XCTAssertNotNil(view.textLayoutManager, "still TextKit 2: nothing converted it")
    }

    // MARK: lifetime and membership

    func testTheRegistryDoesNotKeepViewsAlive() {
        let registry = MacChatFindRegistry()
        weak var weakView: NSTextView?
        autoreleasepool {
            let view = textView("beta", hosted: false)
            weakView = view
            registry.register(view, messageID: "m")
            XCTAssertEqual(registry.mountedViewCount, 1)
        }
        XCTAssertNil(weakView)
        XCTAssertEqual(registry.mountedViewCount, 0)
        XCTAssertTrue(registry.views(for: "m").isEmpty)
    }

    func testUnregisterRemovesTheView() {
        let registry = MacChatFindRegistry()
        let view = textView("beta")
        registry.register(view, messageID: "m")
        registry.unregister(view)
        XCTAssertEqual(registry.mountedViewCount, 0)
    }

    func testDidRegisterReportsTheMessage() {
        let registry = MacChatFindRegistry()
        var seen: [String] = []
        registry.didRegister = { seen.append($0) }
        registry.register(textView("a"), messageID: "m1")
        XCTAssertEqual(seen, ["m1"])
    }

    func testContainsRecognisesMessageViewsAndTheirScrollView() {
        let registry = MacChatFindRegistry()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let view = textView("beta")
        document.addSubview(view)
        scroll.documentView = document
        registry.register(view, messageID: "m")
        XCTAssertTrue(registry.contains(view))
        XCTAssertTrue(registry.contains(document), "anything inside the transcript scroll view")
        XCTAssertFalse(registry.contains(NSView()))
        XCTAssertFalse(registry.contains(nil))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindRegistryTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile ("cannot find 'MacChatFindColors' in scope").

- [ ] **Step 3: Write the registry file**

`ConduitMac/ChatFind/MacChatFindRegistry.swift`:

```swift
import AppKit

enum MacChatFindColors {
    static let match = NSColor(srgbRed: 1.0, green: 0.93, blue: 0.35, alpha: 1)
    static let current = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1)
    static let text = NSColor.black

    /// WCAG contrast ratio of two colors (sRGB).
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
}

/// Highlights are TextKit 1 temporary attributes: the text storage, measuring
/// (D13), selection and accessibility never see them. Only the ranges this
/// type applied are removed, so link styling the text view keeps as temporary
/// attributes elsewhere is untouched.
@MainActor
enum MacChatFindHighlighter {
    /// Returns the ranges it applied (clamped to the text). `current` indexes `ranges`.
    @discardableResult
    static func apply(
        to textView: NSTextView,
        ranges: [NSRange],
        current: Int?,
        replacing previous: [NSRange]
    ) -> [NSRange] {
        guard textView.textLayoutManager == nil, let layout = textView.layoutManager else { return [] }
        let length = (textView.string as NSString).length
        clear(layout, ranges: previous, length: length)
        var applied: [NSRange] = []
        for (index, raw) in ranges.enumerated() {
            let range = NSIntersectionRange(raw, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            layout.addTemporaryAttributes(
                [
                    .backgroundColor: index == current ? MacChatFindColors.current : MacChatFindColors.match,
                    .foregroundColor: MacChatFindColors.text,
                ],
                forCharacterRange: range
            )
            applied.append(range)
        }
        return applied
    }

    static func clear(_ textView: NSTextView, ranges: [NSRange]) {
        guard textView.textLayoutManager == nil, let layout = textView.layoutManager else { return }
        clear(layout, ranges: ranges, length: (textView.string as NSString).length)
    }

    private static func clear(_ layout: NSLayoutManager, ranges: [NSRange], length: Int) {
        for raw in ranges {
            let range = NSIntersectionRange(raw, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
    }
}

enum MacChatFindScroll {
    /// The find bar covers the top of the transcript.
    static let barHeight: CGFloat = 48
    static let bottomMargin: CGFloat = 16
    static let anchorFraction: CGFloat = 0.35

    /// The clip-view y origin that brings `rect` (document coordinates, flipped:
    /// y grows downward) into the comfortable band, or nil when it already
    /// sits there or the offset would not change.
    static func targetOffset(
        rect: CGRect,
        offset: CGFloat,
        viewportHeight: CGFloat,
        documentHeight: CGFloat
    ) -> CGFloat? {
        let top = offset + barHeight
        let bottom = offset + viewportHeight - bottomMargin
        if rect.minY >= top, rect.maxY <= bottom { return nil }
        let desired = rect.midY - viewportHeight * anchorFraction
        let maxOffset = max(0, documentHeight - viewportHeight)
        let clamped = min(max(0, desired), maxOffset)
        return abs(clamped - offset) < 0.5 ? nil : clamped
    }

    /// Scrolls the transcript's `NSScrollView` so `range` of `view` is visible.
    /// A bounds change the scroll surface did not write is read as the reader
    /// browsing (ChatScrollSurfaceLocator.classifyScroll), so the engine does
    /// not snap back to the latest message.
    @MainActor
    static func reveal(_ range: NSRange, in view: NSTextView) {
        guard view.textLayoutManager == nil, let layout = view.layoutManager,
              let container = view.textContainer,
              let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        let inDocument = document.convert(rect, from: view)
        let clip = scroll.contentView
        guard let y = targetOffset(
            rect: inDocument,
            offset: clip.bounds.origin.y,
            viewportHeight: clip.bounds.height,
            documentHeight: document.frame.height
        ) else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

/// The mounted message text views of one window, keyed by message id (D23).
/// Views register from `SelectableTextView.updateNSView` and unregister from
/// `dismantleNSView`; the registry holds them weakly.
@MainActor
final class MacChatFindRegistry {
    struct Context: Equatable {
        var query: String
        var current: MacChatFindMatch?
        /// Ids of the messages the model searches; other rows are never highlighted.
        var searchable: Set<String>
    }

    private final class Entry {
        weak var view: NSTextView?
        let messageID: String
        var highlighted: [NSRange] = []

        init(view: NSTextView, messageID: String) {
            self.view = view
            self.messageID = messageID
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private(set) var context: Context?
    /// Called after a view registers (also when it registers again with new
    /// text), with its message id.
    var didRegister: ((String) -> Void)?

    func register(_ view: NSTextView, messageID: String) {
        let key = ObjectIdentifier(view)
        if let existing = entries[key], existing.messageID == messageID, existing.view === view {
            // Same view again (text may have changed): keep the ranges to clear.
        } else {
            entries[key] = Entry(view: view, messageID: messageID)
        }
        if context != nil { refresh(messageID: messageID) }
        didRegister?(messageID)
    }

    func unregister(_ view: NSTextView) {
        entries[ObjectIdentifier(view)] = nil
    }

    var mountedViewCount: Int { liveEntries().count }

    /// Reading order: top to bottom, then left to right.
    func views(for messageID: String) -> [NSTextView] {
        liveEntries()
            .filter { $0.messageID == messageID }
            .compactMap(\.view)
            .sorted(by: Self.readingOrder)
    }

    /// The first live view's scroll view: the transcript.
    var transcriptScrollView: NSScrollView? {
        liveEntries().lazy.compactMap { $0.view?.enclosingScrollView }.first
    }

    /// True for a message view and for anything inside the transcript scroll view.
    func contains(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        if liveEntries().contains(where: { $0.view === view }) { return true }
        guard let scroll = transcriptScrollView else { return false }
        return view.isDescendant(of: scroll)
    }

    func setContext(_ context: Context?) {
        self.context = context
        for id in Set(liveEntries().map(\.messageID)) { refresh(messageID: id) }
    }

    private func liveEntries() -> [Entry] {
        for (key, entry) in entries where entry.view == nil { entries[key] = nil }
        return Array(entries.values)
    }

    /// Re-highlights every view of one message: ranges per view, then the
    /// current hit mapped to (view, local index) by reading order.
    private func refresh(messageID: String) {
        let group = liveEntries()
            .filter { $0.messageID == messageID }
            .compactMap { entry in entry.view.map { (entry: entry, view: $0) } }
            .sorted { Self.readingOrder($0.view, $1.view) }
        guard let context, MacChatFindMatcher.isSearchable(context.query),
              context.searchable.contains(messageID) else {
            for item in group {
                MacChatFindHighlighter.clear(item.view, ranges: item.entry.highlighted)
                item.entry.highlighted = []
            }
            return
        }
        let ranges = group.map { MacChatFindMatcher.ranges(of: context.query, in: $0.view.string) }
        var spot: (view: Int, local: Int)?
        if let current = context.current, current.messageID == messageID {
            spot = Self.locate(ordinal: current.ordinal, counts: ranges.map(\.count))
        }
        for (index, item) in group.enumerated() {
            item.entry.highlighted = MacChatFindHighlighter.apply(
                to: item.view,
                ranges: ranges[index],
                current: spot?.view == index ? spot?.local : nil,
                replacing: item.entry.highlighted
            )
        }
    }

    static func readingOrder(_ a: NSTextView, _ b: NSTextView) -> Bool {
        let pa = topLeft(of: a)
        let pb = topLeft(of: b)
        if abs(pa.y - pb.y) > 1 { return pa.y > pb.y }   // window space: larger y is higher
        return pa.x < pb.x
    }

    private static func topLeft(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY), to: nil)
    }

    /// Maps a message-wide ordinal to (view index, hit index inside that view).
    static func locate(ordinal: Int, counts: [Int]) -> (view: Int, local: Int)? {
        guard ordinal >= 0 else { return nil }
        var remaining = ordinal
        for (index, count) in counts.enumerated() {
            if remaining < count { return (index, remaining) }
            remaining -= count
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindRegistryTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (19 tests). Likely adjustments: (a) `testRevealMovesTheTranscriptScrollViewToTheHit` needs the text view laid out at width 300 (`view.textContainer?.widthTracksTextView` is true; if the box is too short for 120 lines, enlarge the frame height); (b) `testClearingLeavesLinkRanges...` compares temporary attributes only for equality before and after, so a `nil == nil` pass is acceptable; (c) if `testTheRegistryDoesNotKeepViewsAlive` still sees the view because `XCTAssert` closures retain it, restructure so the view is created in a helper function.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/ChatFind/MacChatFindRegistry.swift' 'ConduitMacTests/MacChatFindRegistryTests.swift'
git commit -m "feat(mac): chat find highlighter, registry and scroll helper (D23)"
```

---

### Task 4: Controller

**Files:**
- Create: `ConduitMac/ChatFind/MacChatFindController.swift`
- Test: `ConduitMacTests/MacChatFindControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 3 types; `ChatScrollEngine.explicitMessageRequested(id:)` (`Conduit/Services/ChatScrollEngine.swift:614`); `AppState.messages`, `$messages`, `$activeSessionId`, `$activeRoomSurface`, `canLoadEarlierMessagesForActiveConversation`; `ComposerTextView`.
- Produces:
  - `@MainActor final class MacChatFindController: ObservableObject` with:
    - `struct Timing { var debounce: Duration; var refresh: Duration; var placement: [Duration]; var revealRetry: Duration; var maxRevealRetries: Int }` (memberwise, defaults: `.milliseconds(120)`, `.milliseconds(150)`, `[.milliseconds(50), .milliseconds(250)]`, `.milliseconds(250)`, `6`)
    - `struct Environment { var messages: () -> [ChatMessage]; var hasEarlierMessages: () -> Bool; var isTranscriptShown: () -> Bool; static let empty: Environment }`
    - `init(environment: Environment = .empty, timing: Timing = Timing(), scroller: @escaping (NSTextView, NSRange) -> Void = { MacChatFindScroll.reveal($1, in: $0) })`
    - `@Published private(set) var isOpen: Bool`, `@Published var query: String`, `@Published private(set) var state: MacChatFindState`, `@Published private(set) var focusToken: Int`, `@Published private(set) var showsLoadedOnlyNote: Bool`
    - `let registry: MacChatFindRegistry`, `var reveal: (String) -> Void`, `weak var field: NSSearchField?`
    - `var isAvailable: Bool`, `func bind(to appState: AppState)`, `func attach(engine: ChatScrollEngine)`, `func open(restoreFocus: (() -> Void)? = nil)`, `func close()`, `func next()`, `func previous()`, `func transcriptDidChange()`, `func ownsResponder(_ responder: NSResponder?) -> Bool`, `func settled() async`
  - `@MainActor enum MacChatFindControllers { static func register(_ controller: MacChatFindController, in window: NSWindow); static func controller(for window: NSWindow?) -> MacChatFindController? }`

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacChatFindControllerTests.swift`:

```swift
import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindControllerTests: XCTestCase {
    /// Mutable transcript the controller reads through its environment.
    final class Transcript {
        var messages: [ChatMessage]
        var hasEarlier = false
        var shown = true
        init(_ messages: [ChatMessage]) { self.messages = messages }
    }

    private static let quiet = MacChatFindController.Timing(
        debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 3
    )

    private var revealed: [String] = []
    private var scrolled: [(String, NSRange)] = []

    private func message(_ id: String, _ text: String, role: MessageRole = .assistant) -> ChatMessage {
        ChatMessage(id: id, role: role, content: text, timestamp: "")
    }

    private func makeController(
        _ transcript: Transcript,
        timing: MacChatFindController.Timing = MacChatFindControllerTests.quiet
    ) -> MacChatFindController {
        let controller = MacChatFindController(
            environment: .init(
                messages: { transcript.messages },
                hasEarlierMessages: { transcript.hasEarlier },
                isTranscriptShown: { transcript.shown }
            ),
            timing: timing,
            scroller: { [unowned self] view, range in self.scrolled.append((view.string, range)) }
        )
        controller.reveal = { [unowned self] id in self.revealed.append(id) }
        return controller
    }

    private func mounted(_ controller: MacChatFindController, _ id: String, _ text: String) -> NSTextView {
        let view = SelectableTextView.makeTextView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        view.string = text
        controller.registry.register(view, messageID: id)
        return view
    }

    private func background(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    private func search(_ controller: MacChatFindController, _ query: String) async {
        controller.query = query
        await controller.settled()
    }

    // MARK: search

    func testTypingSelectsTheNewestHitAndHighlightsMountedViews() async {
        let transcript = Transcript([message("m1", "alpha beta"), message("m2", "beta gamma"), message("m3", "delta")])
        let controller = makeController(transcript)
        let v1 = mounted(controller, "m1", "alpha beta")
        let v2 = mounted(controller, "m2", "beta gamma")
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.count, 2)
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        XCTAssertEqual(background(v1, at: 6), MacChatFindColors.match)
        XCTAssertEqual(background(v2, at: 0), MacChatFindColors.current)
        XCTAssertEqual(MacChatFindLabel.text(query: controller.query, state: controller.state), "2 of 2")
    }

    func testNonSearchableRowsNeverMatchOrHighlight() async {
        let transcript = Transcript([message("m1", "beta"), message("t1", "beta", role: .tool)])
        let controller = makeController(transcript)
        let tool = mounted(controller, "t1", "beta")
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.count, 1)
        XCTAssertNil(background(tool, at: 0))
    }

    func testNextAndPreviousMoveTheCurrentHitAndScroll() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "beta")])
        let controller = makeController(transcript)
        let views = ["m1", "m2", "m3"].map { mounted(controller, $0, "beta") }
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.position, 3)
        scrolled.removeAll()
        controller.next()
        XCTAssertEqual(controller.state.position, 1, "wraps")
        XCTAssertEqual(background(views[0], at: 0), MacChatFindColors.current)
        XCTAssertEqual(background(views[2], at: 0), MacChatFindColors.match)
        controller.previous()
        XCTAssertEqual(controller.state.position, 3)
        XCTAssertEqual(scrolled.count, 2, "each step scrolls once to a mounted view")
        XCTAssertTrue(revealed.isEmpty, "mounted rows need no engine reveal")
    }

    func testStepsAreIgnoredWhileClosedOrWithoutHits() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.next()
        XCTAssertEqual(controller.state.count, 0)
        controller.open()
        await search(controller, "zzz")
        controller.next()
        controller.previous()
        XCTAssertNil(controller.state.current)
        XCTAssertEqual(MacChatFindLabel.text(query: controller.query, state: controller.state), "No matches")
    }

    func testRefiningTheQueryStaysNearTheCurrentHit() async {
        // Hits for "ab": m1 twice, m2, m3. Newest is m3; one step back is m2.
        let transcript = Transcript([message("m1", "ab abc"), message("m2", "abc"), message("m3", "ab")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "ab")
        XCTAssertEqual(controller.state.count, 4)
        XCTAssertEqual(controller.state.current?.messageID, "m3")
        controller.previous()
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        await search(controller, "abc")   // m3 no longer matches; m2 still does
        XCTAssertEqual(controller.state.count, 2)
        XCTAssertEqual(controller.state.current?.messageID, "m2")
    }

    func testClearingTheQueryClearsEverything() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        let view = mounted(controller, "m1", "beta")
        controller.open()
        await search(controller, "beta")
        XCTAssertNotNil(background(view, at: 0))
        await search(controller, "")
        XCTAssertEqual(controller.state.count, 0)
        XCTAssertNil(background(view, at: 0))
    }

    // MARK: unmounted rows

    func testAnUnmountedRowIsRevealedThenPlacedWhenItsViewRegisters() async {
        let transcript = Transcript([message("m1", "find the needle here"), message("m2", "other")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "needle")
        XCTAssertEqual(revealed, ["m1"])
        XCTAssertTrue(scrolled.isEmpty, "no view yet, nothing to scroll inside")
        _ = mounted(controller, "m1", "find the needle here")
        await controller.settled()
        XCTAssertEqual(scrolled.count, 1)
        XCTAssertEqual(scrolled.first?.1, NSRange(location: 9, length: 6))
    }

    func testRevealRetriesAreBounded() async {
        let transcript = Transcript([message("m1", "needle")])
        let timing = MacChatFindController.Timing(
            debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .milliseconds(15), maxRevealRetries: 3
        )
        let controller = makeController(transcript, timing: timing)
        controller.open()
        await search(controller, "needle")
        XCTAssertTrue(HostedTestSupport.waitUntil { self.revealed.count == 3 })
        HostedTestSupport.settle(0.15)
        XCTAssertEqual(revealed.count, 3, "stops after maxRevealRetries")
    }

    func testClosingCancelsAPendingRevealAndLateRegistrationDoesNotScroll() async {
        let transcript = Transcript([message("m1", "needle")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "needle")
        controller.close()
        let late = mounted(controller, "m1", "needle")
        await controller.settled()
        XCTAssertTrue(scrolled.isEmpty)
        XCTAssertNil(background(late, at: 0), "no highlight after close")
    }

    func testANewNavigationCancelsTheOldPendingReveal() async {
        let transcript = Transcript([message("m1", "needle"), message("m2", "needle")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "needle")          // current m2, pending m2
        controller.previous()                       // current m1, pending m1
        _ = mounted(controller, "m2", "needle")
        await controller.settled()
        XCTAssertTrue(scrolled.isEmpty, "m2 is no longer the target")
        _ = mounted(controller, "m1", "needle")
        await controller.settled()
        XCTAssertEqual(scrolled.count, 1)
    }

    func testAMountedMessageWhoseDrawnTextHasFewerHitsStillScrollsToItsFirstView() async {
        let transcript = Transcript([message("m1", "needle needle")])
        let controller = makeController(transcript)
        let view = mounted(controller, "m1", "needle")   // drawn text shows one hit, projection two
        controller.open()
        await search(controller, "needle")               // current ordinal 1 -> no such hit in the view
        XCTAssertEqual(scrolled.count, 1)
        XCTAssertEqual(scrolled.first?.0, view.string)
    }

    // MARK: transcript changes

    func testARefreshKeepsTheCurrentHitAndDoesNotScroll() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "beta")])
        let controller = makeController(transcript)
        for id in ["m1", "m2", "m3"] { _ = mounted(controller, id, "beta") }
        controller.open()
        await search(controller, "beta")
        controller.previous()                         // m2
        scrolled.removeAll()
        transcript.messages.append(message("m4", "beta"))
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 4)
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        XCTAssertTrue(scrolled.isEmpty)
    }

    func testASessionSwitchFallsBackWithoutLeavingTheRange() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        transcript.messages = [message("x1", "beta"), message("x2", "nope"), message("x3", "beta")]
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 2)
        XCTAssertEqual(controller.state.current?.messageID, "x3")
        transcript.messages = []
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertNil(controller.state.current)
        XCTAssertEqual(MacChatFindLabel.text(query: controller.query, state: controller.state), "No matches")
    }

    func testAnEditedMessageIsSearchedAgain() async {
        let transcript = Transcript([message("m1", "alpha")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.count, 0)
        transcript.messages = [message("m1", "alpha beta")]
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 1)
    }

    func testRefreshWhileClosedDoesNothing() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 0)
    }

    func testTheBarClosesWhenTheTranscriptStopsBeingShown() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.open()
        XCTAssertTrue(controller.isOpen)
        transcript.shown = false
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertFalse(controller.isOpen)
    }

    // MARK: open and close

    func testOpenIsRefusedWhenTheTranscriptIsNotShown() {
        let transcript = Transcript([message("m1", "beta")])
        transcript.shown = false
        let controller = makeController(transcript)
        controller.open()
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.isAvailable)
    }

    func testOpenAgainRefocusesWithoutReplacingTheRestoreTarget() {
        let transcript = Transcript([])
        let controller = makeController(transcript)
        var firstRestores = 0, secondRestores = 0
        controller.open(restoreFocus: { firstRestores += 1 })
        let token = controller.focusToken
        controller.open(restoreFocus: { secondRestores += 1 })
        XCTAssertGreaterThan(controller.focusToken, token)
        controller.close()
        XCTAssertEqual(firstRestores, 1)
        XCTAssertEqual(secondRestores, 0)
        controller.close()
        XCTAssertEqual(firstRestores, 1, "closing twice restores once")
    }

    func testReopeningKeepsTheQueryAndSearchesAgain() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        controller.close()
        XCTAssertEqual(controller.state.count, 0)
        XCTAssertEqual(controller.query, "beta")
        controller.open()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 1)
    }

    func testTheLoadedOnlyNoteFollowsTheTranscript() {
        let transcript = Transcript([message("m1", "beta")])
        transcript.hasEarlier = true
        let controller = makeController(transcript)
        controller.open()
        XCTAssertTrue(controller.showsLoadedOnlyNote)
    }

    // MARK: responders and windows

    func testOwnsTheComposerMessageViewsAndTheTranscript() {
        let controller = makeController(Transcript([]))
        let view = mounted(controller, "m1", "beta")
        XCTAssertTrue(controller.ownsResponder(ComposerTextView()))
        XCTAssertTrue(controller.ownsResponder(view))
        XCTAssertFalse(controller.ownsResponder(NSView()))
        XCTAssertFalse(controller.ownsResponder(nil))
    }

    func testTheFieldEditorOfTheBarsFieldIsOwned() {
        let controller = makeController(Transcript([]))
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        controller.field = field
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(controller.ownsResponder(window.firstResponder))
    }

    func testControllersAreLookedUpPerWindowAndHeldWeakly() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        weak var weakController: MacChatFindController?
        autoreleasepool {
            let controller = makeController(Transcript([]))
            weakController = controller
            MacChatFindControllers.register(controller, in: window)
            XCTAssertTrue(MacChatFindControllers.controller(for: window) === controller)
        }
        XCTAssertNil(weakController)
        XCTAssertNil(MacChatFindControllers.controller(for: window))
        XCTAssertNil(MacChatFindControllers.controller(for: nil))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindControllerTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile ("cannot find 'MacChatFindController' in scope").

- [ ] **Step 3: Write the controller**

`ConduitMac/ChatFind/MacChatFindController.swift`:

```swift
import AppKit
import Combine

/// One window's whole-chat find (D23): query, hits, navigation, highlights.
/// Created per main window in `rootContent`, looked up by `NSWindow` for the
/// menu commands. Nothing here touches `AppState` except through `bind`.
@MainActor
final class MacChatFindController: ObservableObject {
    struct Timing {
        var debounce: Duration = .milliseconds(120)
        var refresh: Duration = .milliseconds(150)
        /// Delays of the placement passes after a pending row registers.
        var placement: [Duration] = [.milliseconds(50), .milliseconds(250)]
        var revealRetry: Duration = .milliseconds(250)
        var maxRevealRetries = 6
    }

    struct Environment {
        var messages: () -> [ChatMessage]
        var hasEarlierMessages: () -> Bool
        /// False while a group-chat room replaces the transcript.
        var isTranscriptShown: () -> Bool

        static let empty = Environment(messages: { [] }, hasEarlierMessages: { false }, isTranscriptShown: { false })
    }

    @Published private(set) var isOpen = false
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var state = MacChatFindState()
    /// Bumped by every `open`; the bar focuses and selects its field on change.
    @Published private(set) var focusToken = 0
    @Published private(set) var showsLoadedOnlyNote = false

    let registry = MacChatFindRegistry()
    /// Asks the scroll engine to bring a row on screen; set by `attach(engine:)`.
    var reveal: (String) -> Void = { _ in }
    /// The bar's search field, so a first responder can be recognised as ours.
    weak var field: NSSearchField?

    private var environment: Environment
    private let timing: Timing
    private let scroller: (NSTextView, NSRange) -> Void
    private let cache = MacChatFindTextCache()
    private var searchable: Set<String> = []
    private var searchTask: Task<Void, Never>?
    private var primeTask: Task<Void, Never>?
    private var placementTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var pending: MacChatFindMatch?
    private var restoreFocus: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var isBound = false
    private weak var attachedEngine: ChatScrollEngine?

    init(
        environment: Environment = .empty,
        timing: Timing = Timing(),
        scroller: @escaping (NSTextView, NSRange) -> Void = { MacChatFindScroll.reveal($1, in: $0) }
    ) {
        self.environment = environment
        self.timing = timing
        self.scroller = scroller
        registry.didRegister = { [weak self] id in self?.viewsChanged(messageID: id) }
    }

    var isAvailable: Bool { environment.isTranscriptShown() }

    // MARK: wiring

    func bind(to appState: AppState) {
        guard !isBound else { return }
        isBound = true
        environment = Environment(
            messages: { [weak appState] in appState?.messages ?? [] },
            hasEarlierMessages: { [weak appState] in appState?.canLoadEarlierMessagesForActiveConversation ?? false },
            isTranscriptShown: { [weak appState] in appState.map { $0.activeRoomSurface == nil } ?? false }
        )
        // @Published fires in willSet: the refresh runs in a Task, after the write.
        let changes = appState.$messages.dropFirst().map { _ in () }
            .merge(with: appState.$activeSessionId.dropFirst().map { _ in () })
            .merge(with: appState.$activeRoomSurface.dropFirst().map { _ in () })
        changes
            .sink { [weak self] in self?.transcriptDidChange() }
            .store(in: &cancellables)
    }

    /// Called by every row on appear (cheap): the engine that scrolls rows.
    func attach(engine: ChatScrollEngine) {
        guard attachedEngine !== engine else { return }
        attachedEngine = engine
        reveal = { [weak engine] id in engine?.explicitMessageRequested(id: id) }
    }

    // MARK: open and close

    func open(restoreFocus: (() -> Void)? = nil) {
        guard isAvailable else { return }
        if !isOpen {
            self.restoreFocus = restoreFocus
            isOpen = true
            showsLoadedOnlyNote = environment.hasEarlierMessages()
            primeCache()
            if MacChatFindMatcher.isSearchable(query) {
                scheduleSearch(after: .zero, keepIdentity: false, scroll: false)
            }
        }
        focusToken &+= 1
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        searchTask?.cancel()
        primeTask?.cancel()
        cancelNavigation()
        state = MacChatFindState()
        registry.setContext(nil)
        let restore = restoreFocus
        restoreFocus = nil
        restore?()
    }

    // MARK: navigation

    func next() { step { $0.next() } }
    func previous() { step { $0.previous() } }

    private func step(_ move: (inout MacChatFindState) -> Void) {
        guard isOpen else { return }
        if searchIsPending {
            // Typed and pressed Return inside the debounce: apply the typed
            // query first and land on its selection instead of stepping.
            searchTask?.cancel()
            runSearch(keepIdentity: false, scroll: true)
            return
        }
        guard state.current != nil else { return }
        move(&state)
        applyHighlights()
        goToCurrent()
    }

    // MARK: search

    private var searchIsPending = false

    private func queryChanged() {
        guard isOpen else { return }
        scheduleSearch(after: timing.debounce, keepIdentity: false, scroll: true)
    }

    /// Transcript changed (a message settled, an older page, a session switch).
    func transcriptDidChange() {
        guard isOpen else { return }
        if !isAvailable { close(); return }
        showsLoadedOnlyNote = environment.hasEarlierMessages()
        scheduleSearch(after: timing.refresh, keepIdentity: true, scroll: false)
    }

    private func scheduleSearch(after delay: Duration, keepIdentity: Bool, scroll: Bool) {
        searchTask?.cancel()
        searchIsPending = true
        searchTask = Task { [weak self] in
            await Task.yield()
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.runSearch(keepIdentity: keepIdentity, scroll: scroll)
        }
    }

    private func runSearch(keepIdentity: Bool, scroll: Bool) {
        searchIsPending = false
        let entries = cache.entries(for: environment.messages())
        let order = Dictionary(
            entries.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        searchable = Set(order.keys)
        let result = MacChatFindMatcher.matches(of: query, in: entries)
        let anchor: MacChatFindState.Anchor
        if let previous = state.current {
            anchor = keepIdentity
                ? .keeping(previous, order: order)
                : .near(messageID: previous.messageID, order: order)
        } else {
            anchor = .newest
        }
        state.replace(matches: result.matches, truncated: result.truncated, anchor: anchor)
        applyHighlights()
        if scroll { goToCurrent() }
        if state.current == nil { cancelNavigation() }
    }

    private func applyHighlights() {
        guard isOpen, MacChatFindMatcher.isSearchable(query) else {
            registry.setContext(nil)
            return
        }
        registry.setContext(.init(query: query, current: state.current, searchable: searchable))
    }

    private func primeCache() {
        primeTask?.cancel()
        let messages = environment.messages()
        primeTask = Task { [weak self] in await self?.cache.prime(messages) }
    }

    // MARK: scrolling

    private func goToCurrent() {
        cancelNavigation()
        guard let match = state.current else { return }
        if place(match) { return }
        pending = match
        requestReveal(for: match, attempt: 0)
    }

    private func cancelNavigation() {
        pending = nil
        placementTask?.cancel()
        revealTask?.cancel()
    }

    private func requestReveal(for match: MacChatFindMatch, attempt: Int) {
        reveal(match.messageID)
        revealTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timing.revealRetry)
            guard !Task.isCancelled, self.pending == match else { return }
            if attempt + 1 >= self.timing.maxRevealRetries {
                self.pending = nil
                return
            }
            self.requestReveal(for: match, attempt: attempt + 1)
        }
    }

    /// A pending row's view mounted: place after layout settles.
    private func viewsChanged(messageID: String) {
        guard let match = pending, match.messageID == messageID else { return }
        revealTask?.cancel()
        placementTask?.cancel()
        placementTask = Task { [weak self] in
            guard let self else { return }
            for delay in self.timing.placement {
                if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
                guard !Task.isCancelled, self.state.current == match else { return }
                self.place(match)
            }
            if self.pending == match { self.pending = nil }
        }
    }

    /// Scrolls inside the mounted views of the match's message. False when the
    /// message has no mounted view yet.
    @discardableResult
    private func place(_ match: MacChatFindMatch) -> Bool {
        let views = registry.views(for: match.messageID)
        guard let first = views.first else { return false }
        let ranges = views.map { MacChatFindMatcher.ranges(of: query, in: $0.string) }
        guard let spot = MacChatFindRegistry.locate(ordinal: match.ordinal, counts: ranges.map(\.count)) else {
            // Mounted, but what is drawn has fewer hits than the projection
            // (or the block holding it is not mounted yet): bring the message in.
            scroller(first, NSRange(location: 0, length: min(1, (first.string as NSString).length)))
            return true
        }
        scroller(views[spot.view], ranges[spot.view][spot.local])
        return true
    }

    // MARK: responders

    /// True for responders that count as "in the chat" for Cmd-F routing.
    func ownsResponder(_ responder: NSResponder?) -> Bool {
        if responder is ComposerTextView { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field,
           (editor.delegate as AnyObject?) === field { return true }
        return registry.contains(responder)
    }

    /// Waits for the queued search, cache fill and placement. For tests.
    func settled() async {
        await searchTask?.value
        await primeTask?.value
        await placementTask?.value
    }
}

/// The find controller of each main chat window.
@MainActor
enum MacChatFindControllers {
    private static let table = NSMapTable<NSWindow, MacChatFindController>(
        keyOptions: .weakMemory,
        valueOptions: .weakMemory
    )

    static func register(_ controller: MacChatFindController, in window: NSWindow) {
        table.setObject(controller, forKey: window)
    }

    static func controller(for window: NSWindow?) -> MacChatFindController? {
        guard let window else { return nil }
        return table.object(forKey: window)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindControllerTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (22 tests). Likely adjustments, in this order: (a) `search(...)` sets `query`; `queryChanged` returns early when the bar is closed, so every test must `open()` first (they do); (b) `Task.sleep(for:)` on `Duration.zero` is skipped by the `delay > .zero` checks, except `requestReveal`, which always sleeps `revealRetry` (60 s in the quiet timing, cancelled by `close()` or the next navigation); (c) if `testClosingCancelsAPendingRevealAndLateRegistrationDoesNotScroll` sees a scroll, confirm `close()` cleared `pending` before the registration; (d) if the Swift 6 compiler rejects the `didSet` on `@Published`, keep the `@Published` property and move the observer into `$query.dropFirst().sink`.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMac/ChatFind/MacChatFindController.swift' 'ConduitMacTests/MacChatFindControllerTests.swift'
git commit -m "feat(mac): chat find controller (D23)"
```

---

### Task 5: Row hook, text view registration and the one upstream line

**Files:**
- Create: `ConduitMac/ChatFind/MacChatFindEnvironment.swift`
- Modify: `ConduitMac/Chat/SelectableTextView.swift` (`updateNSView` at :220, `Coordinator` at :274, new `dismantleNSView`)
- Modify: `Conduit/Views/ChatView.swift:297-299` (one gated line)
- Modify: `docs/macos/PORTING_LEDGER.md` (one row)
- Test: `ConduitMacTests/MacChatFindRowTests.swift`

**Interfaces:**
- Consumes: `MacChatFindController`, `MacChatFindRegistry` (Tasks 3 and 4), `ChatScrollEngine` (`Conduit/Services/ChatScrollEngine.swift:93`).
- Produces:
  - `EnvironmentValues.macChatFindController: MacChatFindController?` and `EnvironmentValues.macChatFindMessageID: String?`
  - `extension View { func macChatFindRow(id: String, engine: ChatScrollEngine) -> some View }`
  - `SelectableTextView.dismantleNSView(_:coordinator:)` and `SelectableTextView.Coordinator.attachFind(_:controller:messageID:)`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacChatFindRowTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindRowTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = HostedTestSupport.host(view.frame(width: 320, height: 120), size: NSSize(width: 320, height: 120))
        windows.append(window)
        return window
    }

    private func background(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    func testARowUnderTheModifierRegistersItsTextViewUnderTheRowId() {
        let controller = MacChatFindController()
        _ = host(
            SelectableTextView(text: "hello world")
                .macChatFindRow(id: "m1", engine: ChatScrollEngine())
                .environment(\.macChatFindController, controller)
        )
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.views(for: "m1").count == 1 })
        XCTAssertEqual(controller.registry.views(for: "m1").first?.string, "hello world")
    }

    func testEveryTextViewInARowRegistersUnderTheSameId() {
        let controller = MacChatFindController()
        _ = host(
            VStack {
                SelectableTextView(text: "first block")
                SelectableTextView(text: "second block")
            }
            .macChatFindRow(id: "m7", engine: ChatScrollEngine())
            .environment(\.macChatFindController, controller)
        )
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.views(for: "m7").count == 2 })
        XCTAssertEqual(controller.registry.views(for: "m7").map(\.string), ["first block", "second block"])
    }

    func testWithoutAControllerNothingRegistersAndNoIdIsSet() {
        struct Probe: View {
            let seen: (String?) -> Void
            @Environment(\.macChatFindMessageID) private var id
            var body: some View { Color.clear.onAppear { seen(id) } }
        }
        var ids: [String?] = []
        _ = host(
            VStack {
                Probe { ids.append($0) }
                SelectableTextView(text: "hello")
            }
            .macChatFindRow(id: "m1", engine: ChatScrollEngine())
        )
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(ids.count, 1)
        XCTAssertNil(ids[0], "no controller in the environment: no id")
    }

    func testATextViewOutsideAnyRowIsNeverRegistered() {
        let controller = MacChatFindController()
        _ = host(SelectableTextView(text: "streaming tail").environment(\.macChatFindController, controller))
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(controller.registry.mountedViewCount, 0)
    }

    func testTheRowReplacesTheRevealClosureWithTheEnginesOwn() {
        let controller = MacChatFindController()
        var custom = 0
        controller.reveal = { _ in custom += 1 }
        _ = host(
            SelectableTextView(text: "x")
                .macChatFindRow(id: "m1", engine: ChatScrollEngine())
                .environment(\.macChatFindController, controller)
        )
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.mountedViewCount == 1 })
        HostedTestSupport.settle(0.05)
        controller.reveal("unknown-row")   // the engine ignores rows it does not know
        XCTAssertEqual(custom, 0, "attach(engine:) installed the engine's closure")
    }

    func testAViewMountedWhileSearchingIsHighlightedAndRemovedWhenItGoesAway() {
        let controller = MacChatFindController()
        controller.registry.setContext(.init(query: "world", current: nil, searchable: ["m1"]))
        let window = host(
            SelectableTextView(text: "hello world")
                .macChatFindRow(id: "m1", engine: ChatScrollEngine())
                .environment(\.macChatFindController, controller)
        )
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.views(for: "m1").count == 1 })
        let view = controller.registry.views(for: "m1")[0]
        XCTAssertEqual(background(view, at: 6), MacChatFindColors.match)
        window.contentView = NSHostingView(rootView: EmptyView())
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.mountedViewCount == 0 },
                      "dismantleNSView unregisters")
    }

    func testTheModifierDoesNotChangeTheMeasuredSize() {
        let plain = SelectableTextView(text: "hello world wrapped text")
        let controller = MacChatFindController()
        let tagged = SelectableTextView(text: "hello world wrapped text")
            .macChatFindRow(id: "m1", engine: ChatScrollEngine())
            .environment(\.macChatFindController, controller)
        let a = NSHostingView(rootView: plain.frame(width: 200)).fittingSize
        let b = NSHostingView(rootView: tagged.frame(width: 200)).fittingSize
        XCTAssertEqual(a.height, b.height, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindRowTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile ("cannot find 'macChatFindRow' in scope", "value of type 'EnvironmentValues' has no member 'macChatFindController'").

- [ ] **Step 3: Write the environment file**

`ConduitMac/ChatFind/MacChatFindEnvironment.swift`:

```swift
import SwiftUI

private struct MacChatFindControllerKey: EnvironmentKey {
    static let defaultValue: MacChatFindController? = nil
}

private struct MacChatFindMessageIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The window's find controller; nil in every window that has no whole-chat find.
    var macChatFindController: MacChatFindController? {
        get { self[MacChatFindControllerKey.self] }
        set { self[MacChatFindControllerKey.self] = newValue }
    }

    /// The transcript message the text views below belong to; nil outside a row.
    var macChatFindMessageID: String? {
        get { self[MacChatFindMessageIDKey.self] }
        set { self[MacChatFindMessageIDKey.self] = newValue }
    }
}

/// The one hook ChatView carries (D23): tags a transcript row with its message
/// id so every `SelectableTextView` below registers for highlighting, and hands
/// the scroll engine to the find controller. With no controller in the
/// environment (every other window) it adds nothing.
struct MacChatFindRowModifier: ViewModifier {
    let id: String
    let engine: ChatScrollEngine
    @Environment(\.macChatFindController) private var controller

    func body(content: Content) -> some View {
        content
            .environment(\.macChatFindMessageID, controller == nil ? nil : id)
            .onAppear { controller?.attach(engine: engine) }
    }
}

extension View {
    func macChatFindRow(id: String, engine: ChatScrollEngine) -> some View {
        modifier(MacChatFindRowModifier(id: id, engine: engine))
    }
}
```

- [ ] **Step 4: Register and unregister in the Mac text view twin**

In `ConduitMac/Chat/SelectableTextView.swift`, at the end of `updateNSView` (after `context.coordinator.openURL = context.environment.openURL`, currently line 225) add:

```swift
        // D23: whole-chat find registers each message text view under its row id.
        context.coordinator.attachFind(
            view,
            controller: context.environment.macChatFindController,
            messageID: context.environment.macChatFindMessageID
        )
```

Directly after `updateNSView` (before `measureNonWrapping`) add:

```swift
    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        coordinator.findController?.registry.unregister(view)
        coordinator.findController = nil
    }
```

In `Coordinator` (currently `var openURL: OpenURLAction?` at the top) add:

```swift
        weak var findController: MacChatFindController?

        /// Registers (or re-registers after a text change) when the view sits
        /// in a transcript row of a window with whole-chat find; otherwise
        /// makes sure it is not registered.
        func attachFind(_ view: NSTextView, controller: MacChatFindController?, messageID: String?) {
            if let controller, let messageID {
                findController = controller
                controller.registry.register(view, messageID: messageID)
            } else if let old = findController {
                old.registry.unregister(view)
                findController = nil
            }
        }
```

- [ ] **Step 5: Add the one gated line to ChatView**

In `Conduit/Views/ChatView.swift`, in `chatScrollView(proxy:)`, change

```swift
                ForEach(chatMessageScrollTargets) { target in
                    MessageBubble(message: target.message, gatewayResolver: appState.gatewayMediaResolver)
                        .id(target.id)
                        .background {
```

to

```swift
                ForEach(chatMessageScrollTargets) { target in
                    MessageBubble(message: target.message, gatewayResolver: appState.gatewayMediaResolver)
                        .id(target.id)
#if os(macOS)
                        .macChatFindRow(id: target.id, engine: scrollEngine) // MAC: whole-chat Find (D23)
#endif
                        .background {
```

Nothing else in the file changes. Verify: `git diff -- Conduit/Views/ChatView.swift` shows three added lines and no removed line (if the file has unrelated uncommitted edits, check only the hunk you made; do not stage those).

- [ ] **Step 6: Ledger row**

In `docs/macos/PORTING_LEDGER.md`, add after the `Conduit/Views/ChatView.swift + ... drag-and-drop attachments` row:

```
| Conduit/Views/ChatView.swift whole-chat Find (D23) | R4 (1 region, `// MAC:`) | each message is its own NSTextView, so find across the transcript needs every row to carry its message id and the scroll engine; one modifier line on the row inside the transcript `ForEach` | ConduitMac/ChatFind/ (`.macChatFindRow(id:engine:)` sets the id into the environment for the row's `SelectableTextView`s and gives the window's `MacChatFindController` the `ChatScrollEngine`; it adds nothing when the environment has no controller). Tests: `MacChatFindRowTests` |
```

- [ ] **Step 7: Run to verify it passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindRowTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (7 tests). `testTheRowReplacesTheRevealClosureWithTheEnginesOwn` asserts that the closure set before the row appears is replaced; if it is flaky because the row's `onAppear` has not run when `reveal` is called, lengthen the `HostedTestSupport.settle` before the call.
Then run the existing Mac twin tests to prove nothing regressed: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/SelectableTextViewTests' -only-testing:'ConduitMacTests/SelectableTextClipTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add 'ConduitMac/ChatFind/MacChatFindEnvironment.swift' 'ConduitMac/Chat/SelectableTextView.swift' 'Conduit/Views/ChatView.swift' 'docs/macos/PORTING_LEDGER.md' 'ConduitMacTests/MacChatFindRowTests.swift'
git commit -m "feat(mac): tag transcript rows for chat find (D23, one gated line in ChatView)"
```

(If `ChatView.swift` or the ledger carries other uncommitted edits, stage only your hunk with `git add -p 'Conduit/Views/ChatView.swift'`.)

---

### Task 6: Find bar, field and window hosting

**Files:**
- Create: `ConduitMac/ChatFind/MacChatFindBar.swift`
- Modify: `ConduitMac/ChatFind/MacChatFindEnvironment.swift` (host modifier and window reader appended)
- Modify: `ConduitMac/App/MacDetailRouter.swift:44-51` (bar overlay on `chat`)
- Modify: `ConduitMac/App/ConduitMacApp.swift` (`rootContent`: `.macChatFind(appState: appState)`)
- Test: `ConduitMacTests/MacChatFindBarTests.swift`

**Interfaces:**
- Consumes: `MacChatFindController` (Task 4), `MacChatFindLabel` (Task 2), `MacChatFindControllers` (Task 4).
- Produces:
  - `struct MacChatFindField: NSViewRepresentable` with `final class Coordinator: NSObject, NSSearchFieldDelegate` exposing `enum Command: Equatable { case next, previous, close }` and `static func command(for selector: Selector, hasMarkedText: Bool, shift: Bool) -> Command?`, `init(controller:)`, `controlTextDidChange(_:)`, `fieldAction(_:)`.
  - `struct MacChatFindBar: View` (`init(controller: MacChatFindController)`), `struct MacChatFindSlot: View` (reads the environment controller).
  - `extension View { func macChatFind(appState: AppState) -> some View }`, `struct MacChatFindHost: ViewModifier`, `struct MacChatFindWindowReader: NSViewRepresentable`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacChatFindBarTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindBarTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
    }

    private func openController(hits: [ChatMessage] = []) -> MacChatFindController {
        MacChatFindController(
            environment: .init(messages: { hits }, hasEarlierMessages: { false }, isTranscriptShown: { true }),
            timing: .init(debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 1)
        )
    }

    // MARK: key mapping (the field decides, AppKit-side)

    func testReturnStepsForwardAndShiftReturnBackward() {
        let ret = #selector(NSResponder.insertNewline(_:))
        XCTAssertEqual(MacChatFindField.Coordinator.command(for: ret, hasMarkedText: false, shift: false), .next)
        XCTAssertEqual(MacChatFindField.Coordinator.command(for: ret, hasMarkedText: false, shift: true), .previous)
    }

    func testEscapeCloses() {
        XCTAssertEqual(
            MacChatFindField.Coordinator.command(for: #selector(NSResponder.cancelOperation(_:)), hasMarkedText: false, shift: false),
            .close
        )
    }

    func testNothingIsHandledWhileAnIMECompositionIsMarked() {
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertNil(MacChatFindField.Coordinator.command(for: selector, hasMarkedText: true, shift: false))
            XCTAssertNil(MacChatFindField.Coordinator.command(for: selector, hasMarkedText: true, shift: true))
        }
    }

    func testOtherCommandsFallThroughToTheFieldEditor() {
        XCTAssertNil(MacChatFindField.Coordinator.command(for: #selector(NSResponder.moveLeft(_:)), hasMarkedText: false, shift: false))
        XCTAssertNil(MacChatFindField.Coordinator.command(for: #selector(NSResponder.deleteBackward(_:)), hasMarkedText: false, shift: false))
    }

    func testOptionAndControlReturnVariantsStepToo() {
        for name in ["insertNewlineIgnoringFieldEditor:", "insertLineBreak:"] {
            XCTAssertEqual(
                MacChatFindField.Coordinator.command(for: NSSelectorFromString(name), hasMarkedText: false, shift: false),
                .next, name
            )
        }
    }

    // MARK: coordinator -> controller

    func testTypingUpdatesTheControllersQuery() {
        let controller = openController()
        controller.open()
        let coordinator = MacChatFindField.Coordinator(controller: controller)
        let field = NSSearchField()
        field.stringValue = "needle"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(controller.query, "needle")
        field.stringValue = ""
        coordinator.fieldAction(field)   // the cancel (x) button
        XCTAssertEqual(controller.query, "")
    }

    func testDoCommandRunsTheMappedAction() async {
        let hits = [
            ChatMessage(id: "m1", role: .assistant, content: "needle", timestamp: ""),
            ChatMessage(id: "m2", role: .assistant, content: "needle", timestamp: ""),
        ]
        let controller = openController(hits: hits)
        controller.open()
        controller.query = "needle"
        await controller.settled()
        let coordinator = MacChatFindField.Coordinator(controller: controller)
        let field = NSSearchField()
        let editor = NSTextView()
        XCTAssertEqual(controller.state.position, 2)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(controller.state.position, 1, "Return went to the next hit (wrapped)")
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }

    // MARK: hosted bar

    func testOpeningShowsTheBarAndFocusesTheField() {
        let controller = openController()
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        XCTAssertNil(controller.field, "closed: no field mounted")
        controller.open()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field?.window != nil })
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.ownsResponder(window.firstResponder) },
                      "the field took focus")
    }

    func testOpeningFocusesTheFieldAndSelectsTheLastQuery() {
        let controller = openController()
        controller.query = "abc"   // typed in an earlier session of the bar
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        controller.open()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field?.stringValue == "abc" })
        XCTAssertTrue(HostedTestSupport.waitUntil {
            controller.ownsResponder(window.firstResponder)
                && (window.firstResponder as? NSTextView)?.selectedRange == NSRange(location: 0, length: 3)
        })
        _ = window.makeFirstResponder(nil)
        controller.open()   // Cmd-F again while the bar is open
        XCTAssertTrue(HostedTestSupport.waitUntil {
            controller.ownsResponder(window.firstResponder)
                && (window.firstResponder as? NSTextView)?.selectedRange == NSRange(location: 0, length: 3)
        })
    }

    func testClosingRemovesTheBar() {
        let controller = openController()
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        controller.open()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field != nil })
        controller.close()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field == nil })
    }

    func testTheBarExposesLabelledControls() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let boostWasOn = AccessibilityTreeBoost.isOn
        defer { AccessibilityTreeBoost.set(boostWasOn) }
        AccessibilityTreeBoost.set(true)
        let controller = openController()
        controller.open()
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        XCTAssertTrue(HostedTestSupport.waitUntil {
            let labels = AccessibilityProbe.labels(in: window)
            return ["Previous match", "Next match", "Done"].allSatisfy(labels.contains)
        }, "labels: \(AccessibilityProbe.labels(in: window))")
    }

    func testTheSlotShowsNothingWithoutAControllerAndTheBarWithOne() {
        let none = HostedTestSupport.host(MacChatFindSlot().frame(width: 400, height: 60), size: NSSize(width: 400, height: 60))
        windows.append(none)
        HostedTestSupport.settle(0.05)
        let controller = openController()
        controller.open()
        let some = HostedTestSupport.host(
            MacChatFindSlot().environment(\.macChatFindController, controller).frame(width: 400, height: 60),
            size: NSSize(width: 400, height: 60)
        )
        windows.append(some)
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field != nil })
    }

    // MARK: window hosting

    func testTheWindowReaderRegistersTheControllerForItsWindow() {
        let controller = openController()
        let window = HostedTestSupport.host(
            Color.clear.background(MacChatFindWindowReader(controller: controller)).frame(width: 100, height: 100),
            size: NSSize(width: 100, height: 100)
        )
        windows.append(window)
        XCTAssertTrue(HostedTestSupport.waitUntil { MacChatFindControllers.controller(for: window) === controller })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindBarTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile ("cannot find 'MacChatFindField' in scope").

- [ ] **Step 3: Write the bar**

`ConduitMac/ChatFind/MacChatFindBar.swift`:

```swift
import AppKit
import SwiftUI

/// The query field. An AppKit `NSSearchField` on purpose: Return vs
/// Shift-Return, Esc and IME composition are decided by `doCommandBy` (which is
/// not called for a marked composition), not by SwiftUI key handlers.
struct MacChatFindField: NSViewRepresentable {
    let controller: MacChatFindController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = AppLocalization.string("Find in chat")
        field.setAccessibilityLabel(AppLocalization.string("Find in chat"))
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        field.sendsSearchStringImmediately = true
        field.stringValue = controller.query
        controller.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.controller = controller
        controller.field = field
        // Do not fight the user's typing: only mirror the model into an idle field.
        if field.currentEditor() == nil, field.stringValue != controller.query {
            field.stringValue = controller.query
        }
        if context.coordinator.lastFocusToken != controller.focusToken {
            context.coordinator.lastFocusToken = controller.focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        if coordinator.controller.field === field { coordinator.controller.field = nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        enum Command: Equatable { case next, previous, close }

        var controller: MacChatFindController
        var lastFocusToken = -1

        init(controller: MacChatFindController) {
            self.controller = controller
        }

        /// Pure mapping, so tests need no real key events. A marked (IME)
        /// composition gets nothing: the field editor confirms it.
        static func command(for selector: Selector, hasMarkedText: Bool, shift: Bool) -> Command? {
            guard !hasMarkedText else { return nil }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 NSSelectorFromString("insertNewlineIgnoringFieldEditor:"),
                 NSSelectorFromString("insertLineBreak:"):
                return shift ? .previous : .next
            case #selector(NSResponder.cancelOperation(_:)):
                return .close
            default:
                return nil
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            controller.query = field.stringValue
        }

        /// The search field's own cancel (x) button.
        @objc func fieldAction(_ sender: NSSearchField) {
            controller.query = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            guard let command = Self.command(for: commandSelector, hasMarkedText: textView.hasMarkedText(), shift: shift) else {
                return false
            }
            switch command {
            case .next: controller.next()
            case .previous: controller.previous()
            case .close: controller.close()
            }
            return true
        }
    }
}

/// The strip at the top of the chat pane (D23). Opaque window background with a
/// bottom divider, no second glass layer (D7).
struct MacChatFindBar: View {
    @ObservedObject var controller: MacChatFindController

    var body: some View {
        if controller.isOpen {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                MacChatFindField(controller: controller)
                    .frame(minWidth: 160, maxWidth: 320)
                    .frame(height: 22)
                Text(MacChatFindLabel.text(query: controller.query, state: controller.state))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 64, alignment: .leading)
                Button { controller.previous() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(controller.state.count == 0)
                    .help(Text("Previous match (Shift-Return)"))
                    .accessibilityLabel(Text("Previous match"))
                Button { controller.next() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(controller.state.count == 0)
                    .help(Text("Next match (Return)"))
                    .accessibilityLabel(Text("Next match"))
                if controller.showsLoadedOnlyNote {
                    Text("Loaded messages only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Text("Older messages are not loaded. Scroll to the top and choose Load earlier messages to include them."))
                }
                Spacer(minLength: 0)
                Button("Done") { controller.close() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Find in chat"))
        }
    }
}

/// Reads the window's controller from the environment: the router overlays
/// this on the chat pane in every window, and only a window with whole-chat
/// find (`macChatFind(appState:)` above it) shows anything.
struct MacChatFindSlot: View {
    @Environment(\.macChatFindController) private var controller

    var body: some View {
        if let controller {
            MacChatFindBar(controller: controller)
        }
    }
}
```

- [ ] **Step 4: Append the host modifier and window reader**

Append to `ConduitMac/ChatFind/MacChatFindEnvironment.swift`:

```swift
import AppKit

/// Gives one main window its find controller: injected through the
/// environment (rows and the bar slot read it), registered for the `NSWindow`
/// (menu commands read it), bound to `AppState` for the transcript. The
/// controller is `@State`, not observed: keystrokes must not rebuild rootContent.
struct MacChatFindHost: ViewModifier {
    let appState: AppState
    @State private var controller = MacChatFindController()

    func body(content: Content) -> some View {
        content
            .environment(\.macChatFindController, controller)
            .background(MacChatFindWindowReader(controller: controller))
            .task { controller.bind(to: appState) }
    }
}

extension View {
    func macChatFind(appState: AppState) -> some View {
        modifier(MacChatFindHost(appState: appState))
    }
}

struct MacChatFindWindowReader: NSViewRepresentable {
    let controller: MacChatFindController

    func makeNSView(context: Context) -> ReaderView { ReaderView(controller: controller) }
    func updateNSView(_ view: ReaderView, context: Context) { view.controller = controller }

    final class ReaderView: NSView {
        var controller: MacChatFindController

        init(controller: MacChatFindController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MacChatFindControllers.register(controller, in: window) }
        }
    }
}
```

If the file-level `import SwiftUI` already sits at the top, add `import AppKit` there instead of mid-file.

- [ ] **Step 5: Overlay the bar on the chat pane and host the controller**

In `ConduitMac/App/MacDetailRouter.swift`, in `body`, change

```swift
            chat
                .opacity(destination == .chat ? 1 : 0)
```

to

```swift
            chat
                .overlay(alignment: .top) { MacChatFindSlot() }   // D23: whole-chat find bar
                .opacity(destination == .chat ? 1 : 0)
```

In `ConduitMac/App/ConduitMacApp.swift`, in `rootContent`, directly after `.environmentObject(appState)` add:

```swift
            // Whole-chat find (D23): this window's controller, in the environment.
            .macChatFind(appState: appState)
```

- [ ] **Step 6: Run to verify it passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindBarTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (13 tests). Then prove the router still mounts: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacDetailRouterMountTests' -only-testing:'ConduitMacTests/MacChatRouteTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS. Likely adjustments: (a) `testOpeningFocusesTheFieldAndSelectsTheLastQuery` depends on the field editor's `selectedRange`; if `selectText(nil)` selects asynchronously, keep the `waitUntil`; (b) on a headless test window `makeFirstResponder` can fail until the window is key; call `window.makeKeyAndOrderFront(nil)` in the test before `controller.open()`; (c) if the SwiftUI `Text` literal in `.help(Text(...))` / `.accessibilityLabel(Text(...))` is not extracted by the l10n checker, switch those to `AppLocalization.string("...")` strings and keep the same keys.

- [ ] **Step 7: Commit**

```bash
git add 'ConduitMac/ChatFind/MacChatFindBar.swift' 'ConduitMac/ChatFind/MacChatFindEnvironment.swift' 'ConduitMac/App/MacDetailRouter.swift' 'ConduitMac/App/ConduitMacApp.swift' 'ConduitMacTests/MacChatFindBarTests.swift'
git commit -m "feat(mac): chat find bar, field and window hosting (D23)"
```

---

### Task 7: Cmd-F routing, Cmd-G and Cmd-Shift-G, menu

**Files:**
- Modify: `ConduitMac/App/MacKeyboardShortcuts.swift` (`FindOutcome` :186, `findOrSearchSessions` :211, new `MacChatFindActions`, new `MacKeyboardActions.searchSessions`)
- Modify: `ConduitMac/App/ConduitCommands.swift:55-58` (Edit group)
- Modify: `ConduitMacTests/MacKeyboardTests.swift` (`MacKeyboardMenuTests`: `shortcuts()`, `testOurShortcutsAreUnique`, `testFindItemStaysInTheMenuWithoutCmdF`)
- Test: `ConduitMacTests/MacChatFindCommandsTests.swift`

**Interfaces:**
- Consumes: `MacChatFindControllers`, `MacChatFindController` (Task 4), `MacKeyboardActions.commandsBlocked`, `MacKeyboardActions.focusSessionSearch`, `MacChatRoute.isChatActive`, `MacPaletteActions.focusRestorer(in:)`, `ComposerTextView`.
- Produces:
  - `MacKeyboardActions.FindOutcome` gains `.chatFind` (cases: `chatFind, messageFind, searchSessions`).
  - `@MainActor enum MacChatFindActions { static let sessionWindowPrefix: String; static func isSessionWindow(_ window: NSWindow?) -> Bool; static func routesToChatFind(responder: NSResponder?, window: NSWindow, controller: MacChatFindController) -> Bool; static func next(window: NSWindow?, defaults: UserDefaults = .standard); static func previous(window: NSWindow?, defaults: UserDefaults = .standard) }`
  - `MacKeyboardActions.searchSessions(window: NSWindow?, defaults: UserDefaults = .standard, requests: MacFocusRequests? = nil)`.

- [ ] **Step 1: Write the failing tests**

`ConduitMacTests/MacChatFindCommandsTests.swift`:

```swift
import AppKit
import XCTest
@testable import ConduitMac

/// A responder that sits outside the transcript, like the sidebar's list.
private final class SidebarStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class MacChatFindCommandsTests: XCTestCase {
    private struct Rig {
        let window: NSWindow
        let message: NSTextView
        let composer: ComposerTextView
        let sidebar: SidebarStandIn
        let controller: MacChatFindController
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []
    private var shown = true

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        shown = true
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        HostedTestSupport.dropSuite(suite)
    }

    private func rig(identifier: String = "conduit-primary-AppWindow-1") -> Rig {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let sidebar = SidebarStandIn(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        let scroll = NSScrollView(frame: NSRect(x: 150, y: 100, width: 450, height: 300))
        let message = SelectableTextView.makeTextView()
        message.frame = NSRect(x: 0, y: 0, width: 450, height: 300)
        message.string = "hello needle"
        scroll.documentView = message
        let composer = ComposerTextView(frame: NSRect(x: 150, y: 0, width: 450, height: 80))
        [sidebar, scroll, composer].forEach(content.addSubview)
        window.orderFront(nil)
        windows.append(window)
        let messages = [ChatMessage(id: "m1", role: .assistant, content: "hello needle", timestamp: "")]
        let controller = MacChatFindController(
            environment: .init(messages: { messages }, hasEarlierMessages: { false }, isTranscriptShown: { [unowned self] in self.shown }),
            timing: .init(debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 1)
        )
        controller.registry.register(message, messageID: "m1")
        MacChatFindControllers.register(controller, in: window)
        return Rig(window: window, message: message, composer: composer, sidebar: sidebar, controller: controller)
    }

    private func find(_ rig: Rig) -> MacKeyboardActions.FindOutcome? {
        MacKeyboardActions.findOrSearchSessions(window: rig.window, defaults: suite.defaults, requests: MacFocusRequests())
    }

    // MARK: Cmd-F routing

    func testCmdFFromTheComposerOpensChatFind() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        let requests = MacFocusRequests()
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: requests), .chatFind)
        XCTAssertTrue(r.controller.isOpen)
        XCTAssertFalse(requests.searchPending, "Search Sessions was not asked")
    }

    func testCmdFFromAMessageViewOpensChatFindNotThePerMessageBar() {
        let r = rig()
        r.message.isSelectable = true
        XCTAssertTrue(r.window.makeFirstResponder(r.message))
        XCTAssertEqual(find(r), .chatFind)
        XCTAssertTrue(r.controller.isOpen)
        let scroll = r.message.enclosingScrollView
        XCTAssertEqual(scroll?.isFindBarVisible, false)
    }

    func testCmdFWithNothingFocusedOpensChatFind() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(nil))
        XCTAssertEqual(find(r), .chatFind)
    }

    func testCmdFFromTheSidebarStillSearchesSessions() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(r.sidebar))
        let requests = MacFocusRequests()
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: requests), .searchSessions)
        XCTAssertTrue(requests.searchPending)
        XCTAssertFalse(r.controller.isOpen)
    }

    func testCmdFWhileChatIsHiddenSearchesSessions() {
        for tab in [SidebarTab.bots, .cron, .kanban] {
            let r = rig()
            suite.defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            XCTAssertTrue(r.window.makeFirstResponder(r.composer))
            XCTAssertEqual(find(r), .searchSessions, "\(tab)")
            XCTAssertFalse(r.controller.isOpen, "\(tab)")
        }
    }

    func testCmdFInAGroupRoomSearchesSessions() {
        let r = rig()
        shown = false
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        XCTAssertEqual(find(r), .searchSessions)
        XCTAssertFalse(r.controller.isOpen)
    }

    func testCmdFWhileOpenRefocusesAndKeepsTheFirstRestoreTarget() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(r.message))
        XCTAssertEqual(find(r), .chatFind)
        let token = r.controller.focusToken
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        XCTAssertEqual(find(r), .chatFind)
        XCTAssertGreaterThan(r.controller.focusToken, token)
        r.controller.close()
        XCTAssertTrue(r.window.firstResponder === r.message, "focus went back to where the first Cmd-F started")
    }

    func testCmdFWithNoControllerKeepsTheD10Behaviour() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let composer = ComposerTextView()
        window.contentView?.addSubview(composer)
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: MacFocusRequests()), .searchSessions)
    }

    // MARK: guards

    func testSessionWindowsAreLeftAlone() {
        let r = rig(identifier: "conduit-session-AppWindow-2")
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        let requests = MacFocusRequests()
        XCTAssertNil(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: requests))
        XCTAssertFalse(requests.searchPending)
        XCTAssertFalse(r.controller.isOpen)
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        MacChatFindActions.previous(window: r.window, defaults: suite.defaults)
        MacKeyboardActions.searchSessions(window: r.window, defaults: suite.defaults, requests: requests)
        XCTAssertFalse(r.controller.isOpen)
        XCTAssertFalse(requests.searchPending)
        XCTAssertTrue(MacChatFindActions.isSessionWindow(r.window))
        XCTAssertFalse(MacChatFindActions.isSessionWindow(rig().window))
        XCTAssertFalse(MacChatFindActions.isSessionWindow(nil))
    }

    func testASheetBlocksEveryFindCommand() {
        let r = rig()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        r.window.beginSheet(sheet)
        defer { r.window.endSheet(sheet) }
        XCTAssertNil(find(r))
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertFalse(r.controller.isOpen)
    }

    func testCommandsWithoutAWindowDoNothing() {
        XCTAssertEqual(
            MacKeyboardActions.findOrSearchSessions(window: nil, defaults: suite.defaults, requests: MacFocusRequests()),
            .searchSessions,
            "no window: D10's Search Sessions, never a chat find"
        )
        MacChatFindActions.next(window: nil, defaults: suite.defaults)
        MacChatFindActions.previous(window: nil, defaults: suite.defaults)
    }

    // MARK: Cmd-G / Cmd-Shift-G

    func testCmdGOpensTheBarWhenClosedAndStepsWhenOpen() async {
        let r = rig()
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertTrue(r.controller.isOpen, "Cmd-G with the bar closed opens it")
        r.controller.query = "needle"
        await r.controller.settled()
        XCTAssertEqual(r.controller.state.position, 1)
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertEqual(r.controller.state.position, 1, "one hit: wraps to itself")
        MacChatFindActions.previous(window: r.window, defaults: suite.defaults)
        XCTAssertEqual(r.controller.state.position, 1)
    }

    func testCmdGStepsFromAnyFocusWhileOpen() async {
        let r = rig()
        r.controller.open()
        r.controller.query = "needle"
        await r.controller.settled()
        XCTAssertTrue(r.window.makeFirstResponder(r.sidebar))
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertTrue(r.controller.isOpen)
    }

    func testCmdGWhileChatIsHiddenOrInARoomDoesNothing() {
        let r = rig()
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertFalse(r.controller.isOpen)
        suite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        shown = false
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertFalse(r.controller.isOpen)
    }

    // MARK: Search Sessions item

    func testSearchSessionsMenuActionFocusesTheSearchWithoutTouchingFind() {
        let r = rig()
        let requests = MacFocusRequests()
        MacKeyboardActions.searchSessions(window: r.window, defaults: suite.defaults, requests: requests)
        XCTAssertTrue(requests.searchPending)
        XCTAssertFalse(r.controller.isOpen)
    }
}
```

Edit `MacKeyboardMenuTests` in `ConduitMacTests/MacKeyboardTests.swift`:

1. In `shortcuts()` replace the row `("/Edit/Search Sessions", "f", .command),` with

```swift
            ("/Edit/Find in Chat", "f", .command),
            ("/Edit/Find Next", "g", .command),
            ("/Edit/Find Previous", "g", [.shift, .command]),
```

2. In `testOurShortcutsAreUnique` change `where expected.key != "f"` to `where expected.key != "f" && expected.key != "g"` (the system Find submenu may keep its own Cmd-G items; `testEveryShortcutIsInTheMenuAndWinsItsKey` already pins that ours come first).

3. In `testFindItemStaysInTheMenuWithoutCmdF` change `XCTAssertEqual(cmdF.first, "/Edit/Search Sessions")` to `XCTAssertEqual(cmdF.first, "/Edit/Find in Chat")`, and after it add

```swift
        let search = try XCTUnwrap(all.first { $0.path == "/Edit/Search Sessions" }, "Search Sessions stays in the menu")
        XCTAssertEqual(search.item.keyEquivalent, "", "and has no key equivalent of its own")
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindCommandsTests' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile ("type 'MacKeyboardActions.FindOutcome' has no member 'chatFind'", "cannot find 'MacChatFindActions' in scope").

- [ ] **Step 3: Routing and actions**

In `ConduitMac/App/MacKeyboardShortcuts.swift` change the enum

```swift
    enum FindOutcome: Equatable {
        case chatFind, messageFind, searchSessions
    }
```

Replace the body of `findOrSearchSessions` (keep its signature and doc comment, extend the comment with "D23: in the main chat window with chat shown and focus in the chat, Cmd-F opens the whole-chat find bar") with

```swift
        guard !commandsBlocked(by: window), !MacChatFindActions.isSessionWindow(window) else { return nil }
        let chatActive = MacChatRoute.isChatActive(tabRaw: defaults.string(forKey: MacSidebarState.tabDefaultsKey))
        // D23: whole-chat find, unless focus is outside the chat (sidebar list,
        // session search) or no find controller exists for the window.
        if chatActive, let window, let controller = MacChatFindControllers.controller(for: window),
           controller.isAvailable,
           MacChatFindActions.routesToChatFind(responder: window.firstResponder, window: window, controller: controller) {
            controller.open(restoreFocus: MacPaletteActions.focusRestorer(in: window))
            return .chatFind
        }
        if let target = findTarget(in: window?.firstResponder, chatActive: chatActive) {
            target.performFindPanelAction(findItem())
            return .messageFind
        }
        focusSessionSearch(defaults: defaults, requests: requests)
        return .searchSessions
```

Add next to `focusSessionSearch`:

```swift
    /// Edit > Search Sessions (no key equivalent): the explicit way in now that
    /// Cmd-F is contextual (D23).
    static func searchSessions(
        window: NSWindow?,
        defaults: UserDefaults = .standard,
        requests: MacFocusRequests? = nil
    ) {
        guard !commandsBlocked(by: window), !MacChatFindActions.isSessionWindow(window) else { return }
        focusSessionSearch(defaults: defaults, requests: requests)
    }
```

Append after `MacPaletteActions`:

```swift
/// What the Find items do (D23). The controller lives per main window; the
/// actions check the same guards as every D10 command.
@MainActor
enum MacChatFindActions {
    /// D21 session windows (scene id `conduit-session`) have their own
    /// transcript and no whole-chat find in v1. When D21 lands, call
    /// `MacSessionWindows.isSessionWindow` here instead.
    static let sessionWindowPrefix = "conduit-session"

    static func isSessionWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix(sessionWindowPrefix) ?? false
    }

    /// Focus in the chat (nothing, the window, the composer, a message view, the
    /// transcript, the find field) opens chat find; focus anywhere else (the
    /// sidebar list, the session search field) keeps D10's Search Sessions.
    static func routesToChatFind(responder: NSResponder?, window: NSWindow, controller: MacChatFindController) -> Bool {
        guard let responder, responder !== window, responder !== window.contentView else { return true }
        return controller.ownsResponder(responder)
    }

    private static func controller(for window: NSWindow?, defaults: UserDefaults) -> MacChatFindController? {
        guard let window, !MacKeyboardActions.commandsBlocked(by: window), !isSessionWindow(window),
              MacChatRoute.isChatActive(tabRaw: defaults.string(forKey: MacSidebarState.tabDefaultsKey)),
              let controller = MacChatFindControllers.controller(for: window), controller.isAvailable else { return nil }
        return controller
    }

    /// Cmd-G. With the bar closed it opens the bar (there is no hidden "repeat
    /// the last search").
    static func next(window: NSWindow?, defaults: UserDefaults = .standard) {
        guard let controller = controller(for: window, defaults: defaults) else { return }
        if controller.isOpen { controller.next() } else { controller.open(restoreFocus: MacPaletteActions.focusRestorer(in: window)) }
    }

    /// Cmd-Shift-G.
    static func previous(window: NSWindow?, defaults: UserDefaults = .standard) {
        guard let controller = controller(for: window, defaults: defaults) else { return }
        if controller.isOpen { controller.previous() } else { controller.open(restoreFocus: MacPaletteActions.focusRestorer(in: window)) }
    }
}
```

- [ ] **Step 4: Menu items**

In `ConduitMac/App/ConduitCommands.swift` replace the comment and `CommandGroup(after: .pasteboard)` block (currently lines 50-58) with

```swift
        // One contextual Cmd-F (D10, D23): the whole-chat find bar when focus is
        // in the chat, Search Sessions when focus is in the sidebar. Cmd-G and
        // Cmd-Shift-G step through the hits. All three sit ahead of Edit > Find
        // on purpose: AppKit stops at the first menu item with a matching key
        // equivalent even when it is disabled, and the system Find items are
        // disabled unless a find-capable text view is focused.
        CommandGroup(after: .pasteboard) {
            Button("Find in Chat") { MacKeyboardActions.findOrSearchSessions(window: NSApp.keyWindow) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { MacChatFindActions.next(window: NSApp.keyWindow) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { MacChatFindActions.previous(window: NSApp.keyWindow) }
                .keyboardShortcut("g", modifiers: [.shift, .command])
            // No key equivalent: the way in when Cmd-F lands on the chat.
            Button("Search Sessions") { MacKeyboardActions.searchSessions(window: NSApp.keyWindow) }
            Divider()
        }
```

- [ ] **Step 5: Run to verify it passes**

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindCommandsTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS (14 tests).
Run: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacKeyboardActionsTests' -only-testing:'ConduitMacTests/MacKeyboardMenuTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS: the existing `testCmdF*` cases still pass because a window with no registered controller keeps D10's behaviour; the menu tests pass with the new paths. If `testEveryShortcutIsInTheMenuAndWinsItsKey` reports the system's `/Edit/Find/Find Next` ahead of `/Edit/Find Next`, move the group so it sits before the Find submenu (the same placement fix D10 used for Cmd-F) and record what you did in the D23 text in Task 9.

- [ ] **Step 6: Commit**

```bash
git add 'ConduitMac/App/MacKeyboardShortcuts.swift' 'ConduitMac/App/ConduitCommands.swift' 'ConduitMacTests/MacKeyboardTests.swift' 'ConduitMacTests/MacChatFindCommandsTests.swift'
git commit -m "feat(mac): Cmd-F routes to chat find, Cmd-G and Cmd-Shift-G step (D23)"
```

---

### Task 8: Hosted parity test and localization keys

**Files:**
- Test: `ConduitMacTests/MacChatFindParityTests.swift`
- Modify: `Conduit/Localizable.xcstrings` (through `scripts/l10n.py` only, never by hand)

**Interfaces:**
- Consumes: `MacChatFindText.searchableText`, `MacChatFindMatcher.ranges`, `MarkdownText`, `.macChatFindRow`, `MacChatFindController` registry.
- Produces: catalog keys for every shipped language, passing `scripts/check-l10n-coverage.py`.

- [ ] **Step 1: Write the parity test**

Mounted `MarkdownText` is the ground truth for what a row draws; the projection must report the same number of hits for each common block type.

`ConduitMacTests/MacChatFindParityTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindParityTests: XCTestCase {
    private let samples: [(name: String, markdown: String, query: String)] = [
        ("plain", "The needle is in the haystack. Another needle.", "needle"),
        ("emphasis", "A **needle** and *needle* and `needle` and ~~needle~~.", "needle"),
        ("link", "See [needle docs](https://example.com/needle/guide) for the needle.", "needle"),
        ("heading", "# needle title\n\nBody with a needle.", "needle"),
        ("list", "- first needle\n- second item\n- third needle", "needle"),
        ("ordered", "1. needle one\n2. two\n3. needle three", "needle"),
        ("quote", "> a quoted needle\n> and another needle", "needle"),
        ("table", "| col | needle |\n|---|---|\n| needle | other |\n", "needle"),
        ("code", "Before needle\n\n```swift\nlet needle = 1\n```\n\nAfter needle", "needle"),
        ("diacritics", "Un café, des CAFÉS et du cafe.", "cafe"),
    ]

    func testProjectedHitCountEqualsTheHitsInTheMountedViews() {
        for sample in samples {
            let controller = MacChatFindController()
            let window = HostedTestSupport.host(
                MarkdownText(source: sample.markdown)
                    .macChatFindRow(id: "m", engine: ChatScrollEngine())
                    .environment(\.macChatFindController, controller)
                    .frame(width: 520),
                size: NSSize(width: 520, height: 600)
            )
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil { controller.registry.mountedViewCount > 0 }, sample.name)
            HostedTestSupport.settle(0.1)
            let mounted = controller.registry.views(for: "m")
                .map { MacChatFindMatcher.ranges(of: sample.query, in: $0.string).count }
                .reduce(0, +)
            let message = ChatMessage(id: "m", role: .assistant, content: sample.markdown, timestamp: "")
            let projected = MacChatFindText.searchableText(for: message)
                .map { MacChatFindMatcher.ranges(of: sample.query, in: $0).count } ?? 0
            XCTAssertEqual(projected, mounted, "\(sample.name): projection and drawn text disagree")
        }
    }
}
```

Run: `xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/MacChatFindParityTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS. A failing sample names the block type whose projection differs from what is drawn. Fix `MacChatFindText.plain(fromMarkdown:)` for that block (Task 1 file), never the sample, unless the sample's block is not drawn as text (then delete the sample and add it to the spec's Risks as an unsearched block). Commit the test with the fix.

- [ ] **Step 2: Baseline and key discovery**

Run: `python3 scripts/check-l10n-coverage.py --repo-root .` and record the result (it may already fail for unrelated reasons; note the baseline). Run `grep -rhno 'AppLocalization.string("[^"]*")' 'ConduitMac/ChatFind' | sort -u`, and list the SwiftUI literals added in `ConduitMac/ChatFind/MacChatFindBar.swift` and `ConduitMac/App/ConduitCommands.swift`. Keys added by this plan (keys that already exist, such as `Done` and `Search Sessions`, need nothing):
`Find in Chat`, `Find Next`, `Find Previous`, `Find in chat`, `Previous match`, `Next match`, `Previous match (Shift-Return)`, `Next match (Return)`, `No matches`, `%d of %d`, `%d of %d+`, `Loaded messages only`, `Older messages are not loaded. Scroll to the top and choose Load earlier messages to include them.`

- [ ] **Step 3: Add the keys**

Per docs/LOCALIZATION.md ("A new UI string needs every shipped language: write a worksheet per language with the new key and `import --create` them together"): run `python3 scripts/l10n.py --help`, then `python3 scripts/l10n.py export <lang> -o <scratchpad>/<lang>.json` for one language to learn the worksheet format, write one worksheet per shipped language containing the new keys with real translations (the two format keys keep their `%d` placeholders and the trailing `+` in order), then `python3 scripts/l10n.py import --create <scratchpad>/<lang>.json` for each. Keep worksheets in the scratchpad directory, not the repo.

- [ ] **Step 4: Verify**

Run: `python3 scripts/check-l10n-coverage.py --repo-root .`
Expected: no new failures against the Step 2 baseline, none mentioning a key above. Run `git diff --stat -- Conduit/Localizable.xcstrings` and `git diff -- Conduit/Localizable.xcstrings | grep '^-[^-]'` (no removed lines other than the tool's own re-serialisation; if it re-sorts keys, accept only whitespace-neutral moves and say so in the commit message).
Run: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test -only-testing:'ConduitMacTests/AccessibilityLabelAuditTests' CODE_SIGNING_ALLOWED=NO`
Expected: PASS. If the audit flags the bar's chevron buttons, they already carry `.accessibilityLabel`; if it still flags them, add an entry to `docs/macos/a11y-audit-allowlist.txt` only after reading the audit's rules in `AccessibilityLabelAuditTests`.

- [ ] **Step 5: Commit**

```bash
git add 'ConduitMacTests/MacChatFindParityTests.swift' 'Conduit/Localizable.xcstrings'
git commit -m "test(mac): chat find projection parity; strings in every shipped language (D23)"
```

(Add `ConduitMac/ChatFind/MacChatFindText.swift` to the same commit if Step 1 fixed the projection.)

---

### Task 9: Docs, smoke checklist, full verification

**Files:**
- Modify: `docs/macos/DECISIONS.md` (new D23; D10 shortcut table row and "Cmd-F and Find" paragraph)
- Modify: `docs/macos/PORTING_LEDGER.md` (the "Menu: Find in Chat (Cmd-F)" row; confirm the Task 5 row)
- Modify: `docs/macos/SMOKE_CHECKLIST.md`

- [ ] **Step 1: DECISIONS.md**

Append after the last decision (D20 at the end of the file; keep the file's order convention, which is not strictly numeric):

```
## D23: Mac chat find (2026-10-16)
Spec: docs/superpowers/specs/2026-10-16-mac-chat-find-design.md. Cmd-F (Edit > Find in Chat) opens a find bar over the top of the chat pane in the main window; the field is an `NSSearchField` (Return next, Shift-Return previous, Esc closes; IME composition is never intercepted), the count reads "3 of 12" (capped "5000+"), Cmd-G / Cmd-Shift-G (Edit > Find Next / Find Previous) step. The model is the loaded transcript only (`AppState.messages`; no server search exists in the client): user, assistant and partial rows as drawn, via `MacChatFindText` (the views' own parser and inline builder, so link destinations, emphasis marks, fences and table separators are not hits). Matching is literal, case- and diacritic-insensitive, non-overlapping (`MacChatFindMatcher`). A new query selects the newest hit.
Highlights are TextKit 1 temporary attributes (D13) applied by a per-window registry of mounted message views keyed by message id; the id reaches the views through one environment value set by `.macChatFindRow(id:engine:)`, the only upstream edit (one gated line in `ChatView.swift`, ledger row). Rejected: attributed-string backgrounds (fight `updateNSView` equality, selection and the measuring contract), a query in the SwiftUI environment (invalidates every gated row per key), matching views to rows by geometry (preference-key timing).
Scrolling: a message with mounted views is scrolled inside the transcript `NSScrollView` to put the hit about 35% down the viewport (skipped when it is already visible below the 48 pt bar); an unmounted row is first revealed through `ChatScrollEngine.explicitMessageRequested` (browsing mode, `proxy.scrollTo`), then placed when its views register (passes at 50 and 250 ms), with the reveal re-issued every 250 ms at most 6 times. A scroll the Mac surface did not write is read as the reader browsing, so the engine does not pull back to the latest message.
Cmd-F routing (supersedes the per-message half of D10): in the main window with chat shown and a find controller present, focus in the chat (nothing, the composer, a message view, the transcript, the find field) opens chat find; focus elsewhere (sidebar list, session search field) keeps Search Sessions; Bots / Cron / Kanban and group-chat rooms keep Search Sessions. Search Sessions also has its own Edit item with no key equivalent. Edit > Find > Find... (the per-message bar) stays without a key. Cmd-F, Cmd-G, Cmd-Shift-G do nothing in D21 session windows (`conduit-session` prefix; swap the local helper for `MacSessionWindows.isSessionWindow` after D21 lands), under a sheet, or in a floating panel.
Known gaps: counts for rows that are not built come from the projection (callout titles, columns, math and mermaid blocks can differ from what is drawn; common blocks are pinned by `MacChatFindParityTests`); system rows, collapsed thinking / tool text and the streaming tail are not searched; no search of unloaded history ("Loaded messages only" shows when older pages exist). Not verifiable headlessly: real hardware Return, Shift-Return and IME in the field, the landing position of `scrollTo` into a far unbuilt row on a very long session.
```

In D10's shortcut table (DECISIONS.md:75) replace the Cmd-F row with:

```
| Cmd-F | Edit > Find in Chat | contextual (D23): focus in the chat opens the whole-chat find bar; focus in the sidebar, or chat hidden, focuses "Search sessions" (also Edit > Search Sessions, no key) |
| Cmd-G / Cmd-Shift-G (D23) | Edit > Find Next / Find Previous | step the chat find hits; Cmd-G with the bar closed opens it |
```

At the start of D10's "Cmd-F and Find." paragraph (DECISIONS.md:86) insert one sentence: "Superseded in part by D23: the contextual item is now 'Find in Chat' and a focused message view opens whole-chat find instead of its own bar; the placement reasoning below still holds."

Fill in anything the executor learned: whether the Cmd-G items needed a placement change (Task 7 Step 5), the `scrollTo` landing behaviour observed in the manual pass, and the AppKit form of Shift-Return in the field.

- [ ] **Step 2: Ledger**

Change `docs/macos/PORTING_LEDGER.md:48` to:

```
| Menu: Find in Chat (Cmd-F) | done (D23) | each message is its own NSTextView; transcript-wide find is the whole-chat find bar (D23). Cmd-F is one contextual command: focus in the chat opens it, focus in the sidebar or chat hidden focuses Search Sessions; Edit > Find > Find... (per-message bar) stays in the menu without a key equivalent | ConduitMac/ChatFind/ (one upstream hook, see the ChatView.swift whole-chat Find row) |
```

Confirm the Task 5 row ("Conduit/Views/ChatView.swift whole-chat Find (D23)") is present.

- [ ] **Step 3: SMOKE_CHECKLIST.md**

Replace the first-list line `- [ ] Select text in a reply across a line; Cmd-C copies; Cmd-F finds (per message; transcript-wide Find in Chat is deferred)` with:

```
- [ ] Select text in a reply across a line; Cmd-C copies
- [ ] Cmd-F in a long chat opens the find bar over the transcript; typing a word shows "N of M", highlights it in every visible message (current hit orange), and jumps to the newest hit
- [ ] Find: Return / Cmd-G next, Shift-Return / Cmd-Shift-G previous, wrapping at both ends; a hit in a message far above scrolls it into view; Esc or Done closes, clears the highlights and returns focus to where it was
- [ ] Find: Japanese IME in the field, Return confirms the composition and does not step; the bar says "Loaded messages only" while older pages exist; a link's destination text is not a hit
- [ ] Cmd-F with the sidebar list focused still focuses Search sessions; under Bots / Cron / Kanban it does too; Cmd-F in a session window does nothing; with a sheet open nothing happens
```

- [ ] **Step 4: Verify the whole branch**

Run in order, one xcodebuild at a time:
1. `xcodegen generate`
2. Build: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO`
3. Full Mac suite twice: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO` (expect all green except the known flaky orb test)
4. `git diff <base-commit> -- Conduit Shared | grep '^-[^-]'` prints nothing, and `git diff <base-commit> --stat -- Conduit Shared` lists only `Conduit/Views/ChatView.swift` (3 added lines, one `#if os(macOS)` region) and `Conduit/Localizable.xcstrings`.
5. `grep -rn 'keyboardShortcut("f"\|keyboardShortcut("g"' ConduitMac Conduit` shows exactly the three Edit items.
6. `python3 scripts/check-l10n-coverage.py --repo-root .` matches Task 8.
7. Manual pass from the smoke list on a long real chat when the app can be launched; note anything unverifiable in the D23 text.

Do not launch or interact with the user's running Conduit; the manual smoke items are for the release gate.

- [ ] **Step 5: Cleanup**

Per workspace rules: delete regenerable scratch (`build/dd` only if disk is tight, the l10n worksheets from Task 8), stop any servers you started, and remove your worktree and branch after merge.

- [ ] **Step 6: Commit**

```bash
git add 'docs/macos/DECISIONS.md' 'docs/macos/PORTING_LEDGER.md' 'docs/macos/SMOKE_CHECKLIST.md'
git commit -m "docs: D23 mac chat find, smoke checklist, ledger"
```

---

## Execution notes

- Order: Tasks 1, 2 and 3 are independent of each other in code (2 uses Task 1's `MacChatFindMatch` and `MacChatFindMatcher.isSearchable`; 3 uses Task 1's `MacChatFindMatch` and `MacChatFindMatcher.ranges`), so after Task 1 they may run in parallel worktrees; 4 needs 1 to 3; 5 and 6 need 4; 7 needs 4 and 6 (for `MacChatFindSlot` only through the app build); 8 and 9 last. Merge and run the full suite after each merge.
- D21 coordination: this plan writes the session-window check as `MacChatFindActions.isSessionWindow` against the literal prefix `conduit-session`. If `MacSessionWindows.isSessionWindow` has landed on `macos` before Task 7, call it instead and delete the local prefix constant (keep `MacChatFindActions.isSessionWindow` as a one-line forwarder so the tests stay). If D21 is not merged yet, leave the literal and add a reminder line to the D21 merge checklist.
- D22 and D24 coordination: this plan adds only Cmd-G and Cmd-Shift-G and re-purposes Cmd-F. Before merging, grep `ConduitCommands.swift` on the merge target for any other `keyboardShortcut("f"`, `("g"` or the two shortcuts of D22 / D24 and resolve there.
- After all tasks: whole-branch review against the spec and the Review Focus list, then merge into `macos`, run the full suite on the merge, remove worktrees.
- Effort check against the spec's estimate (about 5 days): Tasks 1 to 3 about 2.0, 4 about 1.0, 5 and 6 about 1.5, 7 to 9 about 0.5 to 1.0 beyond the shared review fixes.
