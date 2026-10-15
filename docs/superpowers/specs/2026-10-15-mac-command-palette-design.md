# Mac command palette (Cmd-K): design

Date: 2026-10-15. Status: draft for review. Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

One keyboard-first, in-window palette to reach anything command-like without the mouse or the sidebar: jump to a session, run a slash command in the current chat, switch profile, open the model picker, change pane, New Chat, Settings.

Boundary with Quick Ask (Option-Shift-Space, global floating panel, separate spec): Quick Ask sends a prompt from anywhere in the OS. The palette lives inside the Conduit window, never sends free text as a prompt, and only dispatches existing app actions.

## Constraints

- Porting rules (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`, upstream edits gated `#if os(macOS)`, tagged `// MAC:`, one ledger row each. Prefer zero upstream edits.
- Cmd-K is free: no `keyboardShortcut("k"` in `Conduit/` or `ConduitMac/`, and docs mention none. The Go/Chat menus use Cmd-1..9, Cmd-[ ], Cmd-F, Cmd-L, Cmd-N, Cmd-W, Cmd-. (`ConduitCommands`).
- Sheet guard: like every command in `MacKeyboardActions`, the palette does nothing while a sheet is attached (`MacKeyboardActions.commandsBlocked(by:)`). Items that open a sheet close the palette first.
- One chat is active at a time (`AppState.activeSessionId`); opening a session goes through `AppState.requestOpenSession`, which also returns the main pane to chat (`macSessionOpenRequested`, `MacDetailRouter`).

## Approach

Own pure-Swift ranking and provider layer plus a SwiftUI overlay (chosen). Rejected:
- Reuse `MacSessionKeyboard` matching: that file has no matcher. It holds cursor movement (`MacSessionCursor`), focus plumbing (`MacFocusRequests`) and the toolbar search-field locator (`MacToolbarSearch`). The sidebar match is `SidebarView.sessionMatches` (private; `localizedCaseInsensitiveContains` over title, model, id, category). Substring only, no ranking, not reachable from ConduitMac. Reuse the cursor type for up/down/first/last; write a new matcher.
- Native `NSPanel`/popover: needs its own window and focus handling; an in-window overlay keeps first-responder handling in SwiftUI and respects sheets.

## Behaviour

- **Open.** Cmd-K (Go menu item "Command Palette") toggles the palette. Works from any pane and from the composer. The composer draft is untouched; focus returns to the previous responder on close (composer if it held focus, via `MacKeyboardActions.focusComposer`).
- **Look.** Centered overlay near the top of the window, 560 pt wide, max 9 visible rows, scrollable. A search field (auto-focused) over a result list, with section headers only when the query is empty. Dim scrim; click outside or Esc closes. Uses the app's flat-pill row style and `conduitAccent` selection (D11 contrast rules); no second glass layer (D7).
- **Keys.** Up/Down move the selection (wraps off; Home/End or Cmd-Up/Down jump first/last, same moves as `MacSessionCursor.Move`). Return runs the selected item. Esc closes (empty query: close; non-empty: first Esc clears, second closes). Tab is swallowed (no focus escape). Cmd-K again closes.
- **Prefix scoping.** `/` limits to slash commands, `>` to app commands and panes, `@` to profiles, `#` to sessions. No prefix searches everything. The prefix is a filter, never part of the match text.
- **Empty query.** Shows Recent first (last 8 items run, any kind), then Commands, then the active chat's slash commands collapsed to the first 5, then sessions in sidebar order.
- **Running items.**
  - Session: `appState.dismissSidebarDrawer()` then `appState.requestOpenSession(id)`, as `ConduitCommands.open(_:)` does.
  - Slash command with no `argsHint`: `await appState.executeSlashCommand("/" + name)` (AppState.swift). Requires an active session; otherwise the row is disabled with reason "No active chat". `/model` with no argument already opens the picker there.
  - Slash command with `argsHint`: closes the palette and inserts `/name ` into the composer draft, focused (needs a draft-insert path, see open question 2); not executed.
  - Switch profile: `await appState.switchProfile(to:)` (as `ProfilePickerSheet` does). The row for `activeProfile` shows a check and is not runnable.
  - Switch model: v1 is one command, "Switch Model...", that sets `appState.showModelPicker = true` (what `/model` does, AppState.swift ~19405; sheet in RootView).
  - Panes: write `tab.rawValue` to `MacSidebarState.tabDefaultsKey` through `MacKeyboardActions.selectTab(_:window:)`, the same call the Ctrl-Cmd-1..4 items use. Items: Sessions (chat), Bots, Cron, Kanban (`SidebarTab`, `MacDetailRouter.destination(for:)`).
  - App commands: New Chat (`appState.createNewSession()`), Settings (see open question 4), Hide/Show Sidebar (`MacSidebarState.toggleVisible()`), Stop Response (`appState.cancelCurrent()`, only while a turn runs), Search Sessions (`MacKeyboardActions.focusSessionSearch`), Check for Updates (`MacUpdater`).
- **Closing on run.** The palette closes before the action runs, except profile switch, which closes immediately and lets the switch complete in the background; failures surface through the existing `appState.errorMessage` path.
- **Slash catalog freshness.** `appState.slashCommands` starts as `builtInSlashCommands` and is replaced by the gateway catalog when loaded (AppState.swift ~19258); the palette reads it live, so a profile switch changes the list.

## Result sources and ranking

Item = `id`, `kind` (session, slash, profile, model, pane, command), `title`, `subtitle`, `keywords`, `isEnabled`, `disabledReason`, `action`.

| Source | Provider reads | Title / match fields |
|---|---|---|
| Sessions | `appState.sessions` (non-archived; `SessionSummary.title`, `model`, `id`, `alternateIds`, `lastActivityAt`, `isUnread`) | title; keywords model, id, category |
| Slash | `appState.slashCommands` (`SlashCommand.name`, `aliases`, `description`, `category`, `argsHint`) | "/name"; keywords aliases, description |
| Profiles | `appState.profiles` (falls back to `[activeProfile]`, as `ProfilePickerSheet`) | profile name |
| Model | one static command | "Switch Model" |
| Panes | `SidebarTab.allCases` | `displayName` |
| App commands | static list in the provider | title + synonyms |

Matcher (pure, `MacPaletteMatcher`): case- and diacritic-insensitive. Score tiers, highest first: exact title; title prefix; word-start match of every query token (so "nc" matches "New Chat" only via tokens, "new ch" yes); contiguous substring; in-order subsequence fuzzy over the title (gap-penalized, min 3 chars of query); keyword substring. No match, no row. Query tokens split on whitespace; all must match.

Final score = tier score + kind weight (commands +30, slash +20, panes +20, profiles +10, sessions 0) + recency boost (items in the recent list: +60 decaying by 6 per rank) + for sessions a small activity boost (`isUnread` +10; last activity within 24 h +5; active session +0 so it does not crowd the top). Ties break by recency rank, then title ascending, then id. Disabled items rank last in their tier and are skipped by Return.

Recents: a `MacPaletteRecents` value type, max 20 ids ("kind:id"), persisted per dashboard and profile in `UserDefaults` (`conduit.mac.palette.recents.<dashboardID>.<profile>`, same scope keys as the tab store); sessions that no longer exist are dropped on read. Written only when an item runs.

Limits: the session catalog loads in pages of 200 (see tabs spec); the palette searches the loaded set only. The matcher runs on the main actor over at most a few thousand items per keystroke; debounce is not needed, but ranking is `O(n)` with early exit, and the list is capped to 50 rows.

## Architecture and file paths

New, all under `ConduitMac/Palette/` (xcodegen picks up the folder; regenerate the project):
- `MacPaletteItem.swift`: item and kind types.
- `MacPaletteMatcher.swift`: pure scoring and ranking; no AppKit, no AppState.
- `MacPaletteRecents.swift`: pure recency list plus a thin `UserDefaults` store (injected suite).
- `MacPaletteProvider.swift`: builds `[MacPaletteItem]` from an `AppState` snapshot (sessions, slash commands, profiles, active ids, turn-running flag) and an actions struct; the actions struct wraps the calls listed under Behaviour so tests inject fakes (pattern: `ModelPickerApplyActions`).
- `MacPaletteStore.swift`: `@MainActor ObservableObject`: `isPresented`, `query`, `selection`, `results`, `toggle()`, `run(_:)`.
- `MacPaletteView.swift`: SwiftUI overlay, search field, list, key handling via `onKeyPress` (same API family as `MacSessionListKeyboard`), `MacPaletteChrome` for look.

Edited, Mac-only files (no gate needed):
- `ConduitMac/App/ConduitCommands.swift`: Go menu button "Command Palette" with `.keyboardShortcut("k", modifiers: .command)`, calling `MacPaletteActions.toggle(window:)`. The menu item is never disabled (stale-disabled items swallow keys; same rule as the existing comment), the action checks `commandsBlocked`.
- `ConduitMac/App/MacKeyboardShortcuts.swift`: `MacPaletteActions` enum beside `MacSessionTabsActions`.
- `ConduitMac/App/ConduitMacApp.swift`: create the `MacPaletteStore` next to the tabs store and pass it to `ConduitCommands`.

Upstream edit (one `#if os(macOS) // MAC:` gate, one ledger row): `Conduit/Views/RootView.swift` adds `.overlay { MacPaletteView(store:) }` on the root content, outside the room gate. Alternative with no upstream edit: host the overlay in a `ConduitMacApp` wrapper view around `RootView`; prefer this if the scene already wraps it. No `AppState.swift` edits; the composer draft insert (open question 2) is the only candidate for a second gate.

Cmd-K vs text views: the menu key equivalent is consumed before the composer's NSTextView sees it; Cmd-K has no standard text-editing meaning in `TextEditingCommands`, so nothing conflicts.

## Testing

- Matcher: tier order (exact > prefix > word-start > substring > fuzzy > keyword), diacritics and case, multi-token AND, fuzzy needs >= 3 chars, kind weights, recency boost decay, tie-breaks, disabled last, 50-row cap.
- Recents: add moves to front, dedupe, cap 20, per-scope persistence on an injected suite, stale session ids dropped.
- Provider: sessions exclude archived; slash list follows `slashCommands`; `argsHint` commands map to insert, others to execute; no active session disables slash items; active profile is a non-runnable check row; Stop Response only while a turn runs. Prefix scoping (`/ > @ #`).
- Store: toggle open/close, selection clamps and skips disabled, Esc clears then closes, run closes then calls the injected action exactly once, run records recents.
- Commands: Cmd-K mapped in the Go menu; no duplicate binding in the existing shortcut table (extend `MacKeyboardTests`/`MacSessionTabsCommandsTests` mapping check); blocked while a sheet is attached.
- View: hosted palette renders in light and dark, selected row visible after Down at overflow, accessibility labels and `.isSelected` trait on the row, search field focused on open.
- Full Mac suite twice; `git diff -- Conduit Shared` removes zero lines outside gates. macOS only; no iOS build (project scope).

## Open questions

1. Model rows: v1 opens the picker. Should it list models inline? That needs `client.modelOptions(sessionId:)` (as `ModelPickerView.loadModels`) plus `runModelPickerApply`/`ModelSwitchOutcome` confirmation handling for mid-chat switches; roughly +1.5 days.
2. Slash with `argsHint` (and any command needing text): insert `/name ` into the composer. No public draft-insert API was found on AppState; this may need one gated upstream edit. Acceptable, or limit v1 to no-arg commands only?
3. Session scope: loaded catalog only (200 per page), or also call the server search the sidebar uses for older sessions?
4. Settings entry: Settings is presented by `RootView.presentSettings()` (private) via `isSettingsSheetPresented`; there is no public request flag besides `settingsLinkRequest` (deep link, `ConduitAppLink.SettingsLink`). Is routing through `settingsLinkRequest` acceptable, or add a gated hook?
5. Should the palette also surface tab commands (Close Tab, Reopen Closed Tab via `MacSessionTabsActions`) and open session tabs first?

## Effort

About 5 days: matcher + recents + tests 1.0; provider + actions + tests 1.0; store + view + keys 1.5; commands wiring, RootView/App hook, ledger 0.5; view/UI tests, light/dark, smoke checklist, review fixes 1.0.

## Docs

New decision D15 in docs/macos/DECISIONS.md; ledger row for the overlay hook (and the draft-insert gate if added); SMOKE_CHECKLIST keyboard section gains Cmd-K.
