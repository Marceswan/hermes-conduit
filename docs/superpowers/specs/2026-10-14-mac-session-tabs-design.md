# Mac session tabs: design

Date: 2026-10-14. Status: approved in chat (approach, behaviour, look/state/testing). Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

Switch quickly between the conversations in use, without going back to the sidebar. A horizontally scrollable strip of session tabs replaces the single title pill in the chat window's toolbar (the area between the sidebar toggle and Refresh).

Single user, several Macs. No sync of tabs between Macs.

## Constraints

- One chat is active at a time (`AppState.activeSessionId`). A tab switch opens that session; it does not run chats side by side. A turn running in another session keeps running on the gateway and shows on return.
- Porting rules apply (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`, upstream edits gated `#if os(macOS)`, tagged `// MAC:`, one ledger row each. No edits to `AppState.swift`.

## Approach

Mac-only tab model tied to the active session (chosen). Rejected:
- Shared tab model in upstream (iPad too): many upstream edits, expensive upstream syncs, iPad not in use.
- Native macOS window tabs (NSWindow tabbing): each tab would need its own AppState and gateway connection; the app is built around one shared state.

## Behaviour

- **Open adds a tab.** Every path that makes a session active adds it as a tab at the end of the strip: sidebar click, Cmd-[ / Cmd-], session-list keyboard, search, New Chat, bot chat, missing-session recovery's fresh chat. If the session already has a tab, that tab becomes selected and nothing is added.
- **Select.** Clicking a tab opens its session through `AppState.requestOpenSession` (the same path as a sidebar row click), which also returns the main pane to chat.
- **Close.** The x button (shown on hover and always on the active tab) or Cmd-W closes a tab. Closing the active tab activates the right neighbour, else the left neighbour. Closing the last tab leaves the empty new-chat state (no session open). Closing an inactive tab does not change the active session.
- **Reopen.** Cmd-Shift-T reopens the most recently closed tab, at its old index (clamped), and opens it. The closed stack keeps the last 10, most recent first.
- **Overflow.** The strip scrolls horizontally. The active tab is always scrolled into view. No cap on the number of tabs.
- **Rename / Delete.** The title pill's menu (Rename, Delete) moves to each tab's context menu. The scroll-to-top primary action stays on a click of the already-active tab.
- **Deleted sessions.** A tab is removed only when (a) the user deletes that session (`AppState.deleteSession` succeeds), or (b) opening it fails because the gateway reports the session not found. A session absent from the loaded catalog is NOT pruned: the catalog loads in pages of 200, so older sessions can be absent without being deleted. A tab whose session is not in the loaded catalog shows its last known title.
- **Identity.** Tabs match sessions by `SessionSummary.id` and `alternateIds` (session identity rules, spec 2026-09-06), so a session whose id is re-keyed keeps its tab.
- **Persistence.** Tabs (order, ids, last known titles) and the active tab survive relaunch, stored per dashboard and profile (`activeDashboardID` + `activeProfile`). A profile or dashboard switch swaps to that scope's tabs. The closed stack is not persisted.
- **Not tabs in v1.** Group-chat rooms (`activeRoomSurface`). While a room is open the strip stays visible, with no tab selected.

## Shortcuts

| Keys | Action |
|---|---|
| Cmd-1 .. Cmd-8 | select tab 1..8 |
| Cmd-9 | select the last tab |
| Ctrl-Tab, Cmd-Shift-] | next tab (wraps) |
| Ctrl-Shift-Tab, Cmd-Shift-[ | previous tab (wraps) |
| Cmd-W | close tab |
| Cmd-Shift-T | reopen closed tab |
| Ctrl-Cmd-1 .. Ctrl-Cmd-4 | Sessions, Bots, Cron, Kanban (moved from Cmd-1..4, D10) |
| Cmd-[ / Cmd-] | previous / next session in sidebar order (unchanged) |

Cmd-W with no tabs does nothing (the window must not close from Cmd-W while the strip is empty; the window's close button still closes it). The same sheet guard as D10 applies: tab commands do nothing while a sheet is attached. Ctrl-Tab must not be swallowed by the composer or the session list (the D10 Tab loop handles plain Tab and Shift-Tab only).

## Look

- One toolbar item in the principal slot, flexible width, on the system toolbar glass platter (D7: no second glass layer).
- Tabs are flat pills, 28 pt tall, 120 to 220 pt wide, title truncated at the end.
- Active tab: accent fill (`conduitAccent`, as the user message bubble), dark text. Inactive: secondary text, subtle fill on hover. Close x 16 pt.
- Overflowing edges fade (same treatment as the sidebar filter-chip fade).
- Busy dot: a small pulsing dot when the session is `working` or `needsInput` in the gateway's `session.active_list` (the data behind the sidebar Status filter), and for the active session when its turn is running. Unread uses the sidebar's existing unread indicator style.
- Hover outline and tooltips (D5, D7) keep working: each tab declares its shape with `.contentShape(.accessibility, Capsule())` and carries the full title as its accessibility label.

## Components

- `MacSessionTabsModel` (pure value type): ordered tab ids, active id, closed stack; operations `open`, `select`, `close`, `reopen`, `selectIndex`, `next`, `previous`, `remove(sessionId)`, `rekey`. No AppKit, no AppState. All behaviour above is tested here.
- `MacSessionTabsStore` (ObservableObject, main actor): owns the model for the current dashboard/profile scope, persists to injected `UserDefaults` (key `conduit.mac.sessionTabs.<dashboardID>.<profile>`), observes `activeSessionId`, scope changes, deletion and not-found results, and issues opens through `requestOpenSession`.
- `MacSessionTabStrip` (SwiftUI view): renders the store, scrolls the active tab into view, context menu, close buttons, busy and unread indicators.
- `ConduitCommands`: Go menu entries for the table above; pane items move to Ctrl-Cmd-1..4.
- Upstream edit: `RootView.chatToolbarContent`, `#if os(macOS)` gate swapping `ChatTitleControl` for `MacSessionTabStrip` (one ledger row). Any further hook needed for deletion or not-found observation must use existing notifications or published state first; a new upstream gate needs its own ledger row.

## Testing

- Model: open appends, open existing selects, close active picks right then left, close last leaves none, close inactive keeps active, reopen restores index and caps at 10, next/previous wrap, Cmd-9 last, remove on delete, not-found removal, no prune on catalog absence, re-keyed id keeps tab.
- Store: persistence round trip on an injected defaults suite; scope switch swaps tabs; `activeSessionId` change adds a tab; tab select calls the open path once.
- Commands: shortcut mapping table, panes on Ctrl-Cmd-1..4, Cmd-W no-op with no tabs, sheet guard, Ctrl-Tab not consumed by the composer or list.
- View: hosted strip renders in light and dark, active tab scrolled into view at overflow, accessibility labels present.
- Full Mac suite twice; iOS simulator build; `git diff -- Conduit Shared` removes zero lines outside gates.

## Out of scope (v1)

Drag to reorder, rooms as tabs, tab sync between Macs, pinning tabs, middle-click close.

## Docs

New D11 in docs/macos/DECISIONS.md; D10's shortcut table updated for the pane move; ledger row for the RootView gate; SMOKE_CHECKLIST keyboard section updated.
