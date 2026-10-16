# Mac chat find (Cmd-F across the whole transcript): design

Date: 2026-10-16. Status: implemented (D23). Decision number: D23. Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

A transcript-wide find in the main chat window, Safari/Xcode style: a find bar with a query field, a match count ("3 of 12"), next / previous (Return / Shift-Return, Cmd-G / Cmd-Shift-G), Esc closes. Every match in a mounted message is highlighted; next / previous scrolls to the message holding the match even when its row is not yet built by the `LazyVStack`. Searches the loaded transcript only (`AppState.messages`). Closes the ledger row "Menu: Find in Chat (Cmd-F) | deferred" (`docs/macos/PORTING_LEDGER.md:48`).

Scope, stated plainly: the main chat window only (identifier prefix `conduit-primary`). The session windows of D21 (scene id `conduit-session`, own transcript, not `ChatView`) get no whole-chat Find in v1, and Cmd-F / Cmd-G / Cmd-Shift-G do nothing in them. Group-chat rooms (`GroupChatView`) are out of scope too.

## Constraints

- Porting rules (`docs/macos/PORTING_LEDGER.md`): Mac code under `ConduitMac/`; any upstream edit gated `#if os(macOS)`, tagged `// MAC:`, one ledger row each. D11 precedent: no edits to `AppState.swift`. Keep `ChatView.swift` to one gated line.
- D10: one Cmd-F menu item, placed ahead of the Edit > Find submenu, because AppKit stops at the first item with a matching key equivalent even when it is disabled (`DECISIONS.md` D10, "Cmd-F and Find"). The same holds for Cmd-G and Cmd-Shift-G.
- D10: no menu item is `.disabled` for a sheet; the action checks `MacKeyboardActions.commandsBlocked(by:)` when it runs.
- D13: message text views are TextKit 1 (`NSTextView(usingTextLayoutManager: false)`). Touching `.layoutManager` on a TextKit 2 view converts it mid-life, so every Mac find helper first checks `textLayoutManager == nil`.
- Shortcuts taken by parallel work, not used here: Cmd-, and Cmd-Shift-D (D22), and whatever D24 (Home view) picks. This spec adds Cmd-G and Cmd-Shift-G and re-purposes Cmd-F; nothing else.
- Localization (`docs/LOCALIZATION.md`): every user-visible string through `AppLocalization.string` or a SwiftUI literal, keys added for every shipped language with `scripts/l10n.py`.

## Facts checked in the tree

Per-message find today
- `ConduitMac/Chat/SelectableTextView.swift:116` creates each message text view with `NSTextView(usingTextLayoutManager: false)` and `:122` sets `usesFindBar = true`. Each markdown block of a message is its own text view: `MarkdownText` renders one view for plain flow text (`Conduit/Views/Components/MarkdownText.swift:84`) or one `MarkdownBlockView` per block (list item, table cell, quote line, code block) otherwise (`:120`). Every text in a bubble goes through `SelectableTextView`, so one Mac-side hook point sees all of it.
- Cmd-F is the single contextual item `Search Sessions` in `CommandGroup(after: .pasteboard)` (`ConduitMac/App/ConduitCommands.swift:55-58`) calling `MacKeyboardActions.findOrSearchSessions` (`ConduitMac/App/MacKeyboardShortcuts.swift:211`). `FindOutcome` is `.messageFind | .searchSessions` (`:186`). `findTarget` (`:196`) accepts only a first-responder `NSTextView` with `usesFindBar`, on screen, with chat the shown pane (`MacChatRoute.isChatActive`, `ConduitMac/App/MacChatRoute.swift:19`). The composer and the sidebar fall through to Search Sessions.
- `MacSessionTabsActions.isMainChatWindow` (`MacKeyboardShortcuts.swift:272`) is the "main window" test (identifier prefix `conduit-primary`). `MacPaletteActions.focusRestorer(in:)` (`:319`) already builds a "give focus back to what had it" closure.
- Existing tests pin today's Cmd-F: `MacKeyboardActionsTests` (`ConduitMacTests/MacKeyboardTests.swift:125`, the `testCmdF*` cases from `:264`) and `MacKeyboardMenuTests` (`:434`, table row `/Edit/Search Sessions` at `shortcuts()`, `testFindItemStaysInTheMenuWithoutCmdF`).

Transcript, scrolling, rows
- `ChatView.body` wraps the list in `ScrollViewReader` (`Conduit/Views/ChatView.swift:204`); `chatScrollView(proxy:)` (`:275`) is a `ScrollView { LazyVStack { ForEach(chatMessageScrollTargets) { target in MessageBubble(...).id(target.id) ... } } }` (`:276-299`). Row id is `ChatMessage.id` (`Conduit/Services/ChatScrollState.swift:20`). The rows come from `ChatScrollEngine.targets` (a cache over `appState.messages`, `ChatScrollState.swift:43`).
- The live tail (`ChatLiveTurnRows`, `ChatView.swift:3080`) is outside `messages` and outside the `ForEach`; a streaming reply joins `messages` when it settles.
- `ChatScrollEngine.explicitMessageRequested(id:)` (`Conduit/Services/ChatScrollEngine.swift:614`) leaves follow-latest, sets browsing mode, cancels restoration and emits `.revealRow(id:)`. `ChatScrollEventRouter.handle` (`ChatView.swift:~636`) answers with `proxy.scrollTo(id, anchor: .top)` without animation. That is the existing, tested path for "jump to an arbitrary row, mounted or not", and `scrollEngine` is a `@StateObject` in `ChatView`, in scope at the row (`:34`, used at `:297`).
- The Mac scroll surface is the transcript `NSScrollView` (`ConduitMac/Chat/ChatScrollSurfaceLocator.swift`). An offset change that is not one the surface wrote is classified `.userDiscrete` and the engine treats it as the reader browsing (`:150-170`). So a Mac-side scroll refinement inside an already mounted row cannot make the engine snap back to the bottom.
- `MessageBubble` (`ChatView.swift:745`) routes by role. Text that is on screen without a tap: user (`:970`, `MarkdownText` with the reply-quote envelope stripped, `ReplyQuoteEnvelope.parse`, `Conduit/Views/Components/ChatQuote.swift:88`), assistant (`:1406`, plus `ChatCodeBlock(source: message.code)` at `:1416`), system (`:1636`). Reasoning and tool cards render their text only when expanded.
- Markdown to text: `MarkdownParser.parseDocument` (`MarkdownText.swift:2322`) gives blocks plus the reference context; `InlineMarkdownContent.attributed` (`:922`) is the single inline builder the views use, so `String(attributed.characters)` is exactly the displayed inline text (link destinations and `**` are absent).
- `AppState.messages` is `@Published` (`Conduit/Services/AppState.swift:728`); `canLoadEarlierMessagesForActiveConversation` (`:21535`) says older pages exist. No server-side transcript search exists in the client (grep for search endpoints finds only voice chat lookup, `searchChatsForVoice`, `AppState.swift:5208`, which finds sessions). So there is nothing to reuse: v1 searches the loaded transcript.

Hosting
- The main window is `WindowGroup("Conduit", id: "conduit-primary")` (`ConduitMac/App/ConduitMacApp.swift:53`) around `rootContent`. The detail pane is `MacDetailRouter(chat:)` (`ConduitMac/App/MacSidebarState.swift:64`, `ConduitMac/App/MacDetailRouter.swift:44-71`), Mac code, which keeps the chat mounted under other panes with `opacity(0)`.
- `RootView` shows `GroupChatView` when `appState.activeRoomSurface != nil`, else `ChatView` (`Conduit/Views/RootView.swift:419-425`).
- In-flight D21 (`docs/superpowers/plans/2026-10-16-mac-session-windows.md`): "AppState, ChatView and ComposerBar are not edited"; adds `MacSessionWindows.isSessionWindow` (plan line ~1705, `hasPrefix(sceneID)`) and already guards some commands against session windows.

## Options

### A. Match model and where the text comes from

1. Match on `ChatMessage.content` (raw markdown). Trivial, but counts hits in link destinations, `**`, fence markers and table separators that are never drawn. Rejected.
2. Match on a plain-text projection of each message, built with the same parser and inline builder the views use (chosen). Pure, testable, no views needed, works for rows that are not built. Differences from what is drawn remain possible for exotic blocks (callouts, columns, math, mermaid); see Risks.
3. Match only in mounted views. Exact, but cannot give "3 of 12" over the whole transcript or navigate to a row that is not built. Rejected as the model; it is kept as the highlight layer (each view finds its own hits).

### B. How highlights reach each `NSTextView`

1. Mutate the attributed string (background color). Changes `attributedText` equality in `updateNSView` (`SelectableTextView.swift:220`), would fight the SwiftUI diff and the cross-block selection code. Rejected.
2. SwiftUI environment value with the query, re-render every row on each keystroke. Invalidates every mounted gated row (`SettledAssistantMessageContent` equality gates) per key. Rejected.
3. TextKit 1 temporary attributes on the view's `NSLayoutManager`, applied by a per-window registry of mounted views keyed by message id (chosen). Temporary attributes never touch the text storage, so measuring (`measuredHeight`, D13), selection and accessibility are unaffected. A keystroke touches only mounted views, with no SwiftUI invalidation. The registry learns each view's message id from one environment value set at the row.

### C. Getting the message id to the views, and the scroll handle to the controller

1. Two upstream hooks (a row tag, and a `ScrollViewReader` wrapper for the proxy). Rejected: two regions in `ChatView.swift`.
2. Match each view to a row by geometry (row frames from the scroll engine). Zero extra hooks but depends on preference-key timing. Rejected as fragile.
3. One gated modifier on the row: `.macChatFindRow(id: target.id, engine: scrollEngine)` (chosen). It sets the message id into the environment for everything under the row and hands the `ChatScrollEngine` to the window's find controller on appear. The engine already owns the `ScrollViewProxy` path (`explicitMessageRequested`), so no proxy is needed. The find controller itself reaches `ChatView` through the environment from `ConduitMacApp.rootContent`, which is Mac code.

### D. Scrolling to a match in a lazy list

1. `proxy.scrollTo(messageID)` for every navigation. Lands on the row top; a long message can have the match far below; an unbuilt row far away can land short because `LazyVStack` estimates heights.
2. Two steps (chosen): if the message has mounted views, scroll the transcript `NSScrollView` so the match rect sits about 35% down the visible band; else ask the engine to reveal the row (`explicitMessageRequested`), wait for the row's views to register, then run step 1 (twice, after 50 ms and 250 ms, to absorb layout settling), and re-issue the reveal every 250 ms up to 6 times if the row still has not mounted. Closing the bar or starting another navigation cancels the pending reveal.

### E. Cmd-F routing

1. Cmd-F always opens chat find in the main window. Loses "Search Sessions from the sidebar".
2. Cmd-F by focus region (chosen): chat find when chat is the shown pane and the first responder is nothing, the composer, a message view, the transcript, or the find field itself; Search Sessions when the first responder is anywhere else (sidebar list, session search field, other panes). Unchanged from D10 for Bots / Cron / Kanban (chat hidden) and when no find controller exists for the window. Search Sessions stays reachable from the menu (new item without key equivalent), from Cmd-F while the sidebar has focus, and from the palette.

## Recommendation

B3 + C3 + D2 + E2 with the A2 model:

- A pure core: `MacChatFindText` (message to plain text), `MacChatFindMatcher` (case- and diacritic-insensitive, literal, non-overlapping), `MacChatFindState` (matches, current index, wrap, retarget).
- A per-window `MacChatFindController` (main actor) owns query, state, the registry of mounted views, highlighting and navigation. Created in `rootContent`, injected through the environment, registered per `NSWindow`.
- The find bar is a Mac SwiftUI view overlaid on the chat pane inside `MacDetailRouter` (so it is only on the chat pane, hides with it, and never covers the sidebar). The query field is an `NSSearchField` wrapper so Return vs Shift-Return, Esc and IME composition are decided by AppKit's `doCommandBy` instead of SwiftUI key handlers.
- Upstream edit: exactly one gated line in `Conduit/Views/ChatView.swift` (the `.macChatFindRow` modifier on the row inside the `ForEach`), one ledger row. No `AppState.swift` edit.

## Behaviour

- **Open.** Cmd-F (Edit > Find in Chat) in the main window, chat pane shown, focus not in the sidebar: the bar slides in at the top of the chat pane and its field takes focus with its text selected. The previous first responder is remembered (`MacPaletteActions.focusRestorer`). Cmd-F while the bar is open refocuses the field and selects its text. The bar keeps the last query when reopened.
- **Look.** Full-width strip at the top of the chat pane, 40 pt: magnifier, search field, count label, previous / next chevrons, a trailing "Loaded messages only" caption when older pages exist (`canLoadEarlierMessagesForActiveConversation`), and Done. Opaque window background with a bottom divider (no second glass layer, D7). The strip overlays the first rows; scrolling to a match treats the top 48 pt as covered.
- **Match rules.** Query as typed (no trimming; empty or whitespace-only query matches nothing). Case-insensitive, diacritic-insensitive (`cafe` finds `Café`), literal (no regex or wildcard), non-overlapping. Searched: user, assistant and partial rows, as drawn (markdown stripped, reply-quote envelope removed from user rows, the assistant's `code` block appended). Not searched in v1: system rows, reasoning, tool, clarify, approval and input-prompt rows, the live streaming tail, attachment names, timestamps, reactions.
- **Count.** "3 of 12" (position of the current match, total). "No matches" for a non-empty query without hits. Total is capped at 5,000; beyond that the label reads "3 of 5000+". Nothing is shown for an empty query.
- **Current match.** A new query selects the last (newest) match, because the transcript is read from the bottom; as the user keeps typing the selection stays at the match nearest the previous one (same message or the next one down). Return / Cmd-G go to the next match (down the transcript, wrapping from last to first); Shift-Return / Cmd-Shift-G go to the previous (wrapping). With the bar closed, Cmd-G opens the bar (no hidden "repeat last search").
- **Highlights.** Every hit in every mounted searched message gets a yellow background with black text; the current hit is orange. Black text on both clears 7:1 in light and dark (the yellow is fixed, not appearance-adaptive, as in Safari). Highlights follow the view when the row scrolls out and back, and are re-applied after `updateNSView` replaces the text. Closing the bar removes them.
- **Scrolling.** See D2. A visible match is not scrolled if it already sits in the band between the bar and 16 pt above the bottom. Scrolling moves the engine to browsing mode (it does not snap back to the latest message); the existing jump-to-latest affordance returns the user.
- **Transcript changes while open.** A settled message arriving, a prepended older page or a session switch re-runs the search (150 ms debounce) and keeps the current hit if it still exists (same message id and ordinal), otherwise the nearest one. No scroll happens on such a refresh.
- **Close.** Esc in the field or the Done button (Cmd-F does not toggle: with the bar open it refocuses the field). Highlights cleared, pending reveal cancelled, focus returned to the previous responder if it is still on screen.
- **Keyboard.** In the field: Return next, Shift-Return previous, Esc close. Return during IME composition confirms the composition and does not navigate. Menu: Edit > Find in Chat (Cmd-F), Find Next (Cmd-G), Find Previous (Cmd-Shift-G), Search Sessions (no key). The items are never disabled; the actions do nothing under a sheet, in a floating panel, or in a session window (`conduit-session` prefix).
- **Pane and room guards.** With chat hidden under Bots / Cron / Kanban, Cmd-F is Search Sessions (D10, unchanged) and an open bar is hidden with the chat. In a group-chat room the bar does not open (controller `isAvailable` false) and Cmd-F is Search Sessions.
- **Edit > Find > Find...** (per-message find bar) stays in the menu without a key equivalent, as D10 left it.

## Risks

- **Projection vs drawn text.** Counts for unbuilt rows come from the projection; a block type whose drawn text differs (callout titles, columns, math, mermaid) can make "N" differ slightly from what highlights show, and the orange hit may be missing for such a message. Mitigation: the projection reuses `MarkdownParser` and `InlineMarkdownContent`; a hosted parity test renders sample messages and compares projected hit counts with the mounted views' own counts for headings, lists, tables, quotes, code, links. Counts are not reconciled from live views in v1 (open question 5).
- **Estimated row heights.** `scrollTo` into a far unbuilt `LazyVStack` region can land short. Mitigated by the retry-until-mounted loop and the two-pass refinement; the visible check makes the second pass a no-op when the first was right.
- **Temporary attributes and links.** NSTextView may use temporary attributes for link styling. Highlights are removed only over the ranges this feature set (tracked per view), never a blanket `removeTemporaryAttribute` over the whole text; a test pins link-range attributes before and after.
- **Registry lifetime.** Views register in `updateNSView` and unregister in `dismantleNSView`; the registry holds them weakly, so a missed dismantle cannot keep a view alive. Entries with a dead view are dropped on read.
- **Cost on large transcripts.** Projection is cached per message (key: role, content, code) and filled in chunks of 40 with a `Task.yield` when the bar opens; a query pass over the cache is a linear `NSString.range(of:)` scan. Hits are capped at 5,000. The projection of a 500 KB message is the slowest single step and runs once.
- **Real key events.** Hosted tests send synthetic events to the field and call `doCommandBy` directly; real hardware Return, Shift-Return and IME are only verifiable by hand (smoke checklist), as D10 already notes for its keys.
- **Native Find items.** `TextEditingCommands` also adds Find Next / Find Previous with Cmd-G / Cmd-Shift-G. Ours sit earlier in Edit and are never disabled, so they win; a test pins "first item with this key is ours" for all three keys.
- **Unsearched blocks.** Image alt text, math blocks, collapsed thinking and collapsed tool text are not searched (they are not drawn as selectable message text); system rows and the live streaming tail are also out of scope.
- **No-resolver MEDIA: tag.** With no gateway media resolver the views draw a raw `MEDIA:` tag as text but the projection does not emit it, so the count can miss such a tag (rare).
- **D21 overlap.** The session-window check is written as a local helper against the literal prefix `conduit-session`. When D21 lands, swap it for `MacSessionWindows.isSessionWindow` (one call site, noted in the plan).

## Architecture and file paths

New, under `ConduitMac/ChatFind/` (xcodegen picks up the folder):
- `MacChatFindMatcher.swift`: `MacChatFindEntry`, `MacChatFindMatch`, `MacChatFindMatcher` (pure).
- `MacChatFindText.swift`: `MacChatFindText` (projection, pure) and `MacChatFindTextCache`.
- `MacChatFindState.swift`: `MacChatFindState`, `MacChatFindLabel` (pure).
- `MacChatFindRegistry.swift`: mounted-view registry, ordering, `locate`, `MacChatFindHighlighter`, `MacChatFindColors`, `MacChatFindScroll`.
- `MacChatFindController.swift`: controller, `MacChatFindControllers` (per window map).
- `MacChatFindEnvironment.swift`: environment keys, `macChatFindRow` modifier, `macChatFind(appState:)` host modifier, window reader.
- `MacChatFindBar.swift`: the bar view and the `NSSearchField` wrapper.

Edited, Mac-only (no gate): `ConduitMac/Chat/SelectableTextView.swift` (register / unregister in `updateNSView` / new `dismantleNSView`), `ConduitMac/App/MacDetailRouter.swift` (bar overlay on `chat`), `ConduitMac/App/ConduitMacApp.swift` (`.macChatFind(appState:)` in `rootContent`), `ConduitMac/App/MacKeyboardShortcuts.swift` (routing, `MacChatFindActions`), `ConduitMac/App/ConduitCommands.swift` (menu items), tests `ConduitMacTests/MacKeyboardTests.swift`.

Upstream edit (one gate, one ledger row): `Conduit/Views/ChatView.swift`, `.macChatFindRow(id:engine:)` after `.id(target.id)` on the `MessageBubble` in the transcript `ForEach` (`:299`).

## Testing

- Matcher (pure): case, diacritics, non-overlap, literal specials (`[`, `(`, `*`, `\`), emoji and combining marks, empty and whitespace queries, cap and truncation flag, UTF-16 ranges in non-BMP text.
- Projection (pure): link destination absent, emphasis and code spans stripped, fence markers absent, table separators absent, list markers absent, reply-quote envelope removed from user rows, assistant `code` appended, non-searchable roles return nil.
- State (pure): newest on fresh query, near-anchor retarget, keep-current across refresh, wrap both ways, empty state, label text including "No matches" and "5000+".
- Registry and highlighter (hosted `NSTextView`): reading-order sort, `locate` across several views, highlight and current colors, clear restores link attributes, contrast of black text on both colors in light and dark, no strong reference to views.
- Controller (hosted, injected `Timing` and recorders): query to state to highlights, next / previous scrolls via the recorder, unmounted row triggers reveal then places on registration, retry bound, close cancels pending, transcript refresh keeps the current hit, session switch, `isAvailable` false.
- Row hook: a `SelectableTextView` under `.macChatFindRow` with a controller in the environment registers under the row id; without a controller nothing registers.
- Parity: `MarkdownText` samples hosted; per-message hit counts from projection equal the sum over mounted views.
- Bar: hosted bar renders in light and dark; `doCommandBy` mapping (Return, Shift-Return, Esc, IME marked text); focus token focuses and selects; accessibility labels.
- Commands: menu table (`/Edit/Find in Chat`, `/Edit/Find Next`, `/Edit/Find Previous` win their keys), routing (composer, message view, sidebar-like responder, nothing focused, hidden chat, room, sheet, session window, Quick Ask panel), existing `testCmdF*` cases unchanged and green because a window without a controller keeps D10's behavior.
- Full Mac suite twice; `git diff -- Conduit Shared` removes zero lines and adds exactly one gated region in `ChatView.swift`.

## Open questions (default chosen)

1. Initial match for a new query: newest (last) hit, versus the first hit below the top visible row. Default: newest.
2. System rows (voice-call markers, review and model-change cards, notices) and collapsed thinking / tool text: searched? Default: no in v1; revisit when a row shows text without a tap.
3. Seed the query from the current text selection (Safari's Cmd-E "Use Selection for Find")? Default: no; the bar reopens with the last query selected.
4. A separate shortcut for Search Sessions now that Cmd-F is contextual (Cmd-Shift-F would be the natural one)? Default: none, to avoid colliding with D22 and D24; it stays reachable from Cmd-F with the sidebar focused, the Edit menu, and the palette.
5. Reconcile the total from live views (replace a mounted message's projected count with the sum of its views' own counts)? Default: no; projection reuses the parser and a parity test guards the common blocks.
6. Include older, not-yet-loaded history (a "Load earlier" prompt inside the bar, or server search)? Default: no; the bar says "Loaded messages only" when older pages exist.
7. Group-chat rooms and D21 session windows get the same find later? Default: out of scope for v1; the controller takes a `messages` closure, so a second host can reuse it.

## Effort

About 5 days: pure core (matcher, projection, state) 1.0; registry, highlighter, scroll helper 1.0; controller and navigation 1.0; bar, hooks, hosting 1.0; commands, routing, tests, l10n, docs, review fixes 1.0.

## Docs

New decision D23 in `docs/macos/DECISIONS.md`; D10 shortcut table row for Cmd-F and the "Cmd-F and Find" paragraph updated to point at D23; one `PORTING_LEDGER.md` row for the `ChatView.swift` hook, and the "Menu: Find in Chat" row changed from deferred to done; `SMOKE_CHECKLIST.md` first-list Cmd-F line replaced and new find items added.
