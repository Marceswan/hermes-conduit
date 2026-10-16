# Mac Home view: design

Date: 2026-10-16. Status: draft for review. Decision: D24. Target: the macOS app only (`ConduitMac`, branch `macos`). iOS is unchanged.

User request, verbatim: "A "Home" view, with a dashboard, metrics, recent sessions, etc."

## Goal

One at-a-glance pane in the main window: which dashboard and profile Conduit is on, whether it is connected, what the agent is doing or waiting on right now (needs-you items first), the most recent chats (one click opens them), a handful of metrics the client already has, and quick actions (New Chat, Quick Ask, open Kanban). Every number comes from a client call or `AppState` property that exists today. Nothing here needs a new server endpoint; anything that would is listed under "Out of scope".

Boundaries with neighbours:
- Notch panel (D16) and notifications (D20) are the interrupt surfaces and own inline Allow/Deny. Home is the place you look when you choose to: it is read-only and opens the session.
- Quick Ask (D15) and the Cmd-K palette (D18) send prompts and run commands. Home only dispatches existing actions (New Chat, Quick Ask, open a pane, open a session).
- Session windows (D21) add a second window type. Home is main-window only: it lives in `MacDetailRouter`, which the session window does not use.
- Desktop widgets (D25) are planned separately and may want the same metrics. All metric computation lives in a pure, Foundation-only type (`MacHomeSnapshot`, built from plain values in `MacHomeInput`) so a widget timeline provider can later fill the same input from its own data and reuse the computation and its tests unchanged. Nothing in that file imports AppKit, SwiftUI, `AppState`, `SessionSummary`, `AgentActivityItem` or `KanbanBoard`.

## Facts checked (file:line, this branch)

Navigation and chrome:
- `SidebarTab` is an upstream `String` enum, cases `sessions, bots, cron, kanban`, with `displayName` and `icon` switches and `migrated(rawValue:)` (`Conduit/Views/SidebarTab.swift:5-37`). It is the persisted value of the key `conduit.sidebarTab` (`MacSidebarState.tabDefaultsKey`, `ConduitMac/App/MacSidebarState.swift:8`).
- The Mac sidebar column always shows `SessionList()`; the tab strip only drives the detail pane (`Conduit/Views/SidebarView.swift:167-168` strip, `:183-199` gated switch; D6, `DECISIONS.md:32-40`). The iOS `switch selectedTab` is in the `#else` branch, so a Mac-only enum case needs no edit there.
- `MacDetailRouter` maps tab to `MacDetailDestination { chat, bots, cron, kanban }` (`ConduitMac/App/MacDetailRouter.swift:4-5`, `:37-44`), keeps chat mounted but hidden under other panes (`:57-62`), builds a non-chat pane on `ConduitBackdrop(drifts: true)` with 20 pt side and 12 pt top padding (`:63-68`), and returns to Sessions on `.macSessionOpenRequested` or an `activeSessionId` change (`:80-87`).
- `MacChatRoute.isChatActive(tabRaw:)` is true only for `.sessions`; every other tab hides the chat toolbar title and sets the window title to `displayName` (`ConduitMac/App/MacChatRoute.swift:19-33`). A new tab gets this for free.
- `MacSidebarTabStrip` renders `SidebarTab.allCases` in equal-width segments inside `ViewThatFits` (names, else icons) (`ConduitMac/Views/MacSidebarTabStrip.swift:17-28`); at the 340 pt column the four names fit (`ConduitMacTests/ButtonGeometryTests.swift:102-111`).
- `MacSidebarShortcut` maps Ctrl-Cmd-1..4 to the four tabs, "numbered in tab-strip order", pinned by `testEveryTabHasExactlyOneDistinctShortcut` (`ConduitMac/App/MacKeyboardShortcuts.swift:9-45`, `ConduitMacTests/MacKeyboardTests.swift:27-34`). The Go menu builds those items from `allCases` (`ConduitMac/App/ConduitCommands.swift:105-108`).
- `SidebarTab.allCases` also feeds the palette's pane rows (`ConduitMac/Palette/MacPaletteProvider.swift:165-168`), so Home appears in Cmd-K with no palette edit.
- Surface styles: D6 pane chrome and 430 pt detail minimum (`DECISIONS.md:35`, `:37`), D7 compact controls and "no second glass layer" (`:43-47`, `ConduitMac/Views/MacControlMetrics.swift:11-40`), `MacPaneHeader` / `MacSearchPill` (`ConduitMac/Views/MacPaneChrome.swift:7-45`), D14 grouped forms (`:124-133`, not needed: Home has no form), D16 surface-style resolution (glass on macOS 26+, solid fallback, Reduce Transparency forces solid; `DECISIONS.md:292-302`). Glass helpers: `conduitGlassSurface(cornerRadius:tint:interactive:)` and `conduitGlassControl(...)` (`Conduit/Theme.swift:275-303`), both behind `#available(iOS 26.0, macOS 26.0, *)` with a pre-26 fallback.

Shortcut table (verified by grepping `keyboardShortcut(` in `ConduitMac`, `Conduit`, `Shared`, and the D10/D11/D17/D18 text):
- Used: Cmd-N, Cmd-W, Cmd-Shift-T, Cmd-F, Cmd-., Cmd-Shift-W, Cmd-K, Cmd-1..9, Cmd-Shift-] / [, Ctrl-Tab, Ctrl-Shift-Tab, Cmd-[ / ], Opt-Cmd-Up / Down, Cmd-L, Ctrl-Cmd-S, Ctrl-Cmd-1..4 (`ConduitCommands.swift:32-133`), Quick Ask panel-local Cmd-Return, Cmd-., Cmd-N (`ConduitMac/QuickAsk/MacQuickAskView.swift:142-153`).
- Taken by parallel specs: Cmd-, and Cmd-Shift-D (D22), Cmd-F / Cmd-G / Cmd-Shift-G (D23 chat find), Option-Cmd-N (D21 session windows, `2026-10-16-mac-settings-dashboard-shortcuts-design.md:36`).
- Free and chosen: **Ctrl-Cmd-5**, "Go > Home". It continues the Ctrl-Cmd-digit pane family (D11), so `MacSidebarShortcut` stays "one shortcut per tab, in strip order". Ctrl-Cmd-5 is not a macOS system shortcut that the app can lose (Cmd-Shift-5 is the screenshot tool; verify on the smoke machine).

Data sources (all existing):
- Connection and scope: `AppState.isConnected` (`AppState.swift:529`), `isConnecting` (`:539`), `activeProfile` (`:562`), `profileDisplayName(_:)` (`:8234`), `savedDashboardRegistry.activeDashboardLabel` (`SavedDashboardRegistry.swift:55`; registry published at `AppState.swift:575`), `activeDashboardID` (`:587`).
- Sessions: `activeProfileSessions` (`AppState.swift:1028`, the sidebar's list minus bot-owned rows) over `sessions` (`:597`); `SessionSummary.title`, `model`, `lastActivityAt` (epoch seconds, optional), `messageCount`, `isArchived` (`Conduit/Models/Models.swift:773-805`, `:787`, `:792`); unread via `isSessionUnread(_:)` (`AppState.swift:5782`; `SessionSummary.isUnread` is optional and not authoritative).
- Live and needs-you: `AgentActivityFeed.shared.items` (`ConduitMac/Activity/AgentActivityFeed.swift:9-13`, set by `MacActivityBootstrap`, `MacActivityBootstrap.swift:12-18`), item fields `kind`, `state` (`.working`, `.needsUser`), `title`, `detail`, `since`, `sessionId`, `sessionKey` (`AgentActivityModels.swift:19-60`), `availability` (`.live`, `.eventsOnly`, `.offline`, `AgentActivityModels.swift:4-11`), `refreshNow()` (`AgentActivityFeed.swift:132`). The notch opens a row with `item.sessionId ?? item.sessionKey` (`ConduitMac/Notch/NotchStatusController.swift:409-410`); Home does the same. Visibility limit from D16 applies: only sessions on this dashboard socket or in the same gateway process's `session.active_list`.
- Open a session, same route as a sidebar row: `appState.dismissSidebarDrawer()` then `appState.requestOpenSession(id)` (as `ConduitCommands.open`, `ConduitCommands.swift:144-149`); `requestOpenSession` posts `.macSessionOpenRequested` and the router returns to Sessions (`AppState.swift:16219-16222`, `MacDetailRouter.swift:80-87`).
- Model and context of the open chat: `AppState.runtime` (`AppState.swift:1345`): `model`, `provider`, `reasoningEffort`, `contextPercent` (0 to 100, normalised at `AppState.swift:12706-12715`), `contextUsed`, `contextMax` (`Models.swift:1105-1114`); the Context sheet shows the same value (`AuxiliaryViews.swift:41-44`). `activeAgents` (sub-agents of the open chat, `AppState.swift:1346`).
- Cron: `AppState.cronJobs` (`:2986`), loaded by `loadCronJobs()` (`:22747`; bridge `/api/cron/jobs` when a dashboard bridge exists, else `HermesClient.listCronJobs` `cron.list`, `HermesClient.swift:2419`); `CronJob.enabled`, `isActive` (enabled and not finished, `Models.swift:873`), `lastError` (`:842`), `nextRunAt` (a **String**, `:845`; shown raw today at `SidebarView.swift:2144`).
- Kanban: `KanbanService.fetchBoard(slug:includeArchived:)` returns `KanbanBoard.columns[].name/tasks` (`Conduit/Services/KanbanService.swift:96`, `Conduit/Models/KanbanModels.swift:306-327`). The board store is private to `KanbanView` (`@StateObject`, `Conduit/Views/KanbanViews.swift:348`), so Home makes its own `KanbanService(requester: appState.dashboardTicketBridge)` (a `DashboardJSONRequester`, `KanbanService.swift:4-14`). The user's board choice is persisted per server at `KanbanStore.scopedBoardKey(serverIdentity:)` (`KanbanStore.swift:127`). Column labels and order: `KanbanStatusPresentation.forStatus(_:)` (`Conduit/Models/KanbanStatus.swift:58`).
- Actions: New Chat `appState.createNewSession()` guarded by `macNewChatDisabled` (`ConduitMac/App/MacNewChatAvailability.swift:29`, `ConduitCommands.swift:32-39`); Quick Ask `MacQuickAskController.shared.show()` (`MacQuickAskController.swift:66`, `ConduitCommands.swift:77`); open a pane = write `SidebarTab.rawValue` to `MacSidebarState.tabDefaultsKey` (`NotchActions.selectPane`, `NotchActions.swift:19-21`).
- Untrusted text: `MacUntrustedText.sanitize(_:maxGraphemes:)` (`ConduitMac/Shared/MacUntrustedText.swift:40`, Foundation only).

## Integration decisions

1. **Home is a fifth `SidebarTab`, `case home = "Home"`, declared last.** It must be a `SidebarTab` value: upstream chat code and `MacChatRoute` read the persisted `conduit.sidebarTab` through `SidebarTab.migrated`, which maps any unknown raw value to `.sessions`; a separate Mac-only route key would leave the chat "active" under Home. The case, its `displayName` entry and its `icon` entry (`house`) are three `#if os(macOS) // MAC:` regions in `Conduit/Views/SidebarTab.swift`, one ledger row (R4), zero removed lines. iOS `allCases` stays four. No edit to `AppState.swift` (D11 precedent), `SidebarView.swift` or `RootView.swift`.
2. **Launch default stays Sessions.** The stored tab keeps whatever the user last chose, as today; a restored session already returns the tab to Sessions at launch (D6 launch note, `DECISIONS.md:36`), so Home does not survive a relaunch that restores a chat. No change to `MacDefaults`.
3. **Shortcut: Ctrl-Cmd-5, Go > Home**, by adding `.home` to `MacSidebarShortcut` (key "5", same `[.control, .command]` modifiers, last in `allCases`, so `testEveryTabHasExactlyOneDistinctShortcut` still holds). The existing test `testOtherKeysMapToNothing` lists "5" and is updated.
4. **Tab strip with five segments.** Five equal segments cannot show names in the 308 pt inside the default 340 pt column (about 62 pt each; the four-name layout needs about 68 to 77 pt for "Sessions"). `MacSidebarTabStrip` gets a three-step ladder inside its existing `ViewThatFits`: (a) five equal segments with names; (b) the four existing tabs equal with names and Home as a fixed icon-only trailing segment (`MacTabStripMetrics.homeSegmentWidth` 38 pt, the 32 pt icon plus the 3 pt inset on each side); (c) all icons, as today's narrow fallback. The default 340 pt column is expected to land on (b), so the four existing names keep showing. Measured in Task 6; if (b) does not fit, the shipped behaviour is (c) and D24 records the measured widths (open question 2).
5. **Home mounts only while it is the route.** `MacDetailRouter` builds `MacHomeView` only when the destination is `.home`; chat stays mounted underneath as for Bots/Cron/Kanban. The snapshot model, its Combine subscriptions and the polls live and die with the view, so the pane costs nothing while hidden.

## Layout

Detail pane, ~900 pt wide (minimum 430 pt; the tile grid is adaptive, minimum 150 pt per tile, so it is 2 columns at 430 and up to 4 wide). One scroll view; cards are the only glass layer (D7), rows inside cards are flat.

```
+----------------------------------------------------------------------------+
| Home                                              (o) Connected            |
| vitalsource-prod  .  Default                                               |
| [ + New Chat ]  [ Quick Ask ]  [ Kanban ]                                  |
|                                                                            |
| +- Needs you ------------------------------------------------------------+ |
| | (!) Approval   rm -rf build/ ...        Refactor billing        4 min  | |
| | (?) Question   Which environment...     Deploy script           1 min  | |
| +- Working --------------------------------------------------------------+ |
| | (>) Running    web_search               Release notes           9 min  | |
| +-------------------------------------------------------------------------+|
|                                                                            |
| +----------+ +----------+ +----------+ +----------+                        |
| | 128      | | 3        | | 2        | | 1        |                        |
| | Sessions | | Unread   | | Needs you| | Working  |                        |
| | Today 5  | |          | | 1 appr.. | | +2 sub.. |                        |
| +----------+ +----------+ +----------+ +----------+                        |
| +--------------------------------+ +-------------------------------------+ |
| | Model                          | | Context                             | |
| | claude-opus-5   anthropic      | | [=================------]   62%      | |
| | reasoning: high                | | 124k of 200k tokens                 | |
| +--------------------------------+ +-------------------------------------+ |
|                                                                            |
| +- Recent chats ---------------------------------------------------------+ |
| | * Refactor billing                          opus-5            4 min    | |
| |   Deploy script                             sonnet            1 hr     | |
| |   ... 8 rows                                                          | |
| +-------------------------------------------------------------------------+|
| +- Activity, 7 days ----+ +- Kanban ------------------+ +- Cron ---------+ |
| |        _              | | To Do      ####     4     | | Active   5     | |
| |    _  | |  _          | | Running    ##       2     | | Paused   1     | |
| | _ | | | | | |  [#]    | | Blocked    #        1     | | Failing  0     | |
| | M T W T F S S         | | Done       ######   9     | | Next  in 2 hr  | |
| +-----------------------+ +---------------------------+ | (job name)     | |
|                                                         +----------------+ |
+----------------------------------------------------------------------------+
```

Dataviz: the skill's procedure was followed. Forms picked by job: stat tiles for single values; a **meter** for one ratio against a limit (context); a **column chart, emphasis form** for magnitude over seven days (today in the accent hue, the other six in a neutral); **horizontal bars, one sequential hue** for Kanban counts. No categorical colour is used, so no palette validation run is needed; no dual axis; status is never colour alone (icon plus label). Marks: columns at most 24 pt thick with a 4 pt rounded top and a square baseline, 2 pt gaps, value label on the top of today's column and on hover (`help`) for the others, recessive baseline only. Each chart has a text fallback: the whole chart is one accessibility element whose label lists every value ("Sessions per day: Mon 3, Tue 0, ..."), which is also the table view. Non-text marks must reach 3:1 and secondary text 4.5:1 against the window background in light and dark; a rendered-colour test pins both (the palette's own finding is that system `.secondary` is below 4.5:1, `MacPaletteContrastTests`, so Home uses explicit `primary` opacities).

## Sections, data source, behaviour

| Section | Shows | Data source | Notes |
|---|---|---|---|
| Header | "Home", dashboard label and profile name, connection pill (icon + label) | `savedDashboardRegistry.activeDashboardLabel`, `profileDisplayName(activeProfile)`, `isConnected` / `isConnecting` | Label and profile text are sanitized (40 graphemes). Pill: Connected, Connecting, Offline. |
| Quick actions | New Chat, Quick Ask, Kanban | `createNewSession()` behind `macNewChatDisabled`; `MacQuickAskController.shared.show()`; pane write | 32 pt `MacControlHeight.compact` glass controls. New Chat disabled exactly when the sidebar's is. |
| Needs you | approvals, clarify questions, input prompts, oldest first | `AgentActivityFeed.items` with `state == .needsUser`, `kind` in approval/clarify/inputPrompt | One row per session; a needs-you item replaces that session's working row. Click opens the session. Command or question text is shown sanitized and cut (120 graphemes); Home never approves inline. |
| Working | running turns, oldest first | `AgentActivityFeed.items` with `state == .working`, `kind == .turn` | Detail is the tool name when the feed has one; poll-only rows have none. |
| Tiles | Sessions (count, "Today n"), Unread, Needs you (approvals / questions), Working (+ sub-agents) | `activeProfileSessions` + `lastActivityAt`; `isSessionUnread`; feed items; `AppState.activeAgents` | Counts are over the loaded catalog; the label says so in the accessibility value. |
| Model | model, provider, reasoning effort of the open chat | `AppState.runtime` | Hidden when `runtime.model` is empty. Labelled "Open chat". Sanitized (40 graphemes). |
| Context | meter and "used of max" | `runtime.contextPercent`, `contextUsed`, `contextMax` | Hidden when both percent and max are 0. From 85% the meter adds a warning icon and label (Home's own threshold; the app has no named one). |
| Recent chats | 8 newest by `lastActivityAt`, unread dot, model, relative time | `activeProfileSessions` | Excludes archived and cron runs (`cronSessions` is a separate list). Same open route as a sidebar row. Title sanitized (80 graphemes); empty title shows "Untitled chat". |
| Activity, 7 days | sessions touched per calendar day, today highlighted | `lastActivityAt` over the loaded catalog | Not messages: no per-day message data exists (`messageCount` is a lifetime total per session). |
| Kanban | task count per column of the board the user last selected, total, blocked count | own `KanbanService.fetchBoard` through `dashboardTicketBridge` | Fetched on appear and every 60 s while the app is active. Fixed order from `KanbanStatusPresentation`; archived column skipped. Unavailable without a dashboard bridge. |
| Cron | Active, Paused, Failing (last run error) counts; next run (job name + relative time) | `cronJobs` via `loadCronJobs()` | `nextRunAt` is parsed as ISO 8601 (with or without fractional seconds); an unparseable value shows no "next" line rather than a guess. |

### Behaviour

- **Open.** Sidebar tab "Home" or Ctrl-Cmd-5 (Go > Home) or the Cmd-K pane row. The window title becomes "Home" and the toolbar title is hidden, as for Bots/Cron/Kanban (D6).
- **Refresh.** On appear and whenever the connection scope changes (dashboard, profile, connected): feed `refreshNow()`, `loadCronJobs()`, Kanban fetch. Every 30 s a tick rebuilds the snapshot (day rollover); every 60 s Kanban and cron refresh while the app is active. AppState changes are coalesced (500 ms throttle) and a rebuild publishes only if the snapshot changed, because `AppState` publishes constantly during a turn.
- **Clicks.** Any session row (live or recent) calls the same two lines as a sidebar row; the router returns to Sessions. A live row with no open id (feed item with neither `sessionId` nor `sessionKey`) is not a button. The Kanban action and the Kanban card header select the Kanban tab.
- **Sheets.** Home sits behind sheets like any pane; nothing special.
- **Disconnected** (`isConnected == false`, not connecting): header pill "Offline"; Needs you / Working hidden (the feed clears its rows 15 s after a drop, D shared base); Kanban "Unavailable offline"; Cron "-"; New Chat disabled per `macNewChatDisabled`; Recent still lists the last catalog and rows stay clickable (they open the saved copy, as in the sidebar). A one-line banner says "Not connected. Showing the last saved list."
- **Connecting:** pill "Connecting", live sections show nothing, data sections keep their last values.
- **Empty:** no chats yet: Recent shows "No chats yet. Start one with New Chat or Quick Ask." Nothing live: the Needs you and Working cards are absent (not an empty card); a quiet line "Nothing running" appears once, in place of both, when connected and the feed is baselined. Feed `.eventsOnly` (gateway lacks `session.active_list`): a footnote "Only chats on this connection show here."
- **Kanban/cron with no data:** Kanban with zero tasks shows "No tasks"; no cron jobs shows "No scheduled jobs".
- **Dashboard or profile switch:** the scope key changes, the view's `.task(id:)` restarts, the Kanban loader resets to "not loaded" so a stale board never shows under the new dashboard.

## Untrusted text

Session titles, models, live-row titles and detail (tool names, approval commands, questions), Kanban column names, cron job names and the dashboard label are gateway or agent controlled. `MacHomeSnapshot.make` sanitizes every string with `MacUntrustedText.sanitize(_:maxGraphemes:)` (title 80, detail 120, model and label 40, cron name 60, Kanban column 24) so any consumer of the snapshot, including a widget, is safe. Views draw them with `Text(verbatim:)`, so no Markdown or link detection applies. Accessibility labels are built from the sanitized values.

## Architecture and files

New, under `ConduitMac/Home/` (xcodegen picks up the folder):
- `MacHomeSnapshot.swift`: input value types, snapshot value types, `MacHomeSnapshot.make(_:calendar:)`, `MacHomeDates.parse(_:)`. Foundation only. Reusable by a widget.
- `MacHomeKanbanLoader.swift`: `@MainActor` loader holding `MacHomeKanbanInput`, injected `fetch`, generation guard, fallback from a stale saved board slug to the server's current board.
- `MacHomeModel.swift`: `@MainActor ObservableObject`, injected `Sources` (input builder, change publisher, refresh, scope), throttled rebuild, `run()` loop.
- `MacHomeBinding.swift`: the live `Sources` from `AppState`, `AgentActivityFeed.shared` and the loader; `MacHomeActions.live`.
- `MacHomeStyle.swift`, `MacHomeComponents.swift`, `MacHomeView.swift`: tokens, tiles, rows, meter, charts, the pane.

Edited, Mac-only (no gate): `ConduitMac/App/MacDetailRouter.swift` (destination `.home`, pane), `ConduitMac/App/MacKeyboardShortcuts.swift` (`MacSidebarShortcut.home`), `ConduitMac/Views/MacSidebarTabStrip.swift` (ladder), `ConduitMac/Views/MacControlMetrics.swift` (`MacTabStripMetrics.homeSegmentWidth`).

Edited, upstream: `Conduit/Views/SidebarTab.swift`, three `#if os(macOS) // MAC:` regions (case, name, icon), one ledger row. That is the only upstream file. No `AppState.swift`, `HermesClient.swift`, `RootView.swift` or `SidebarView.swift` edit.

Localization: new strings are catalogued in `Conduit/Localizable.xcstrings` in all shipped languages through `scripts/l10n.py` (data only, additive, one ledger row as for D16). No string embeds a count and a singular noun: tiles show a number over a label, so no plural keys are needed.

## Risks

1. **Tab strip width.** Five segments change a measured layout (D7). Mitigated by the ladder and by tests that pin both the four visible names and Home's compact segment; the fallback is today's icon-only layout. Product call in open question 2.
2. **Router edit collisions.** D23 (chat find) also edits `MacDetailRouter.swift` (bar overlay). Home touches the destination enum, `destination(for:)` and `pane(for:)` only; if D23 lands first, the two edits are disjoint hunks. Rebase carefully; re-run `MacDetailRouterTests`.
3. **`nextRunAt` format.** It is a raw String and no fixture in the repo pins its format. The parser accepts ISO 8601 with or without fractional seconds and a zone offset; anything else yields no "next run" line. A zone-less value is read as the Mac's local time (assumption). Verify against a live gateway on the smoke pass.
4. **Unprompted network and error banners.** Opening Home calls `loadCronJobs()`, whose failure sets the shared `errorMessage` (`AppState.swift:22759-22766` area), the same banner the Cron pane raises. A gateway without cron would show it each time Home opens. Default: accepted (open question 4); mitigation if it annoys: Home calls `HermesClient.listCronJobs()` directly and swallows errors.
5. **Feed coverage.** Needs-you and Working show only what the feed can see (D16 visibility limit). The footnote and the empty state say so. A session another client runs never appears.
6. **Rebuild cost.** `objectWillChange` of a 27k-line `AppState` fires during streaming. The throttle, the equality gate and the O(n) snapshot (one pass over the loaded catalog; thousands of sessions are still sub-millisecond work) keep this off the hot path. Verified by a model test that counts publishes.
7. **Catalog truncation.** "Sessions" and the seven-day columns count the loaded catalog, not the server's total. Stated in the accessibility value; the tile is not a statistic of record.
8. **Stale Kanban slug.** The saved board may have been deleted; the loader retries once with the server's current board before reporting unavailable.
9. **Liquid Glass fallback.** Cards use `conduitGlassSurface`, which falls back before macOS 26 and under the existing availability checks; Reduce Transparency behaviour is whatever that helper does today (not changed here).
10. **Widget reuse drift.** If D25 changes the snapshot fields it needs, `MacHomeInput` grows additively; it carries no UI types, so that is a compatible change.

## Testing

- `MacHomeSnapshotTests` (pure): live dedupe per session with needs-you winning, ordering, offline suppression; recent ordering, cap, archived exclusion upstream of the snapshot, nil activity last; today and seven-day bucketing with an injected calendar and time zone, midnight boundaries; unread, session and approval/question counts; cron summary and next-run choice including overdue and unparseable dates; Kanban ordering, archived skip, zero total, blocked count; context clamp and high flag; every string passes through the sanitizer (bidi override, newline, zero-width, length cap); a 5000-session input completes and is capped; `MacHomeDates.parse` formats.
- `MacHomeKanbanLoaderTests`: success, fallback from a stale slug, failure leaves `unavailable` or keeps the last board, reset, a late response after reset is dropped, cancellation leaves state alone.
- `MacHomeModelTests`: initial snapshot, throttled rebuild, equal snapshot does not republish, `run()` refreshes then polls, cancellation stops it.
- `MacHomeBindingTests`: input mapping from a real `AppState` with fixture sessions and a stub feed (live item kinds, open id rule, cron conversion, runtime copy); `MacHomeActions.live` open route calls `requestOpenSession` (observe `.macSessionOpenRequested`).
- `MacHomeViewTests` (hosted, accessibility tree): sections present for a full snapshot, absent for an empty one; offline banner; recent row press calls `openSession` with the id; live row without open id is not a button; New Chat disabled; labels contain the sanitized text; chart element carries the full text fallback; light and dark render without clipping at 430 and 900 pt widths.
- `MacHomeContrastTests`: secondary text at least 4.5:1 and chart marks at least 3:1 against `windowBackgroundColor`, light and dark.
- Existing tests updated: `MacKeyboardTests` (Home shortcut, "5" no longer unmapped, menu table), `MacDetailRouterTests` (destination), `ButtonGeometryTests` (strip ladder), `MacPaneTitleTests` (Home hides the toolbar title), `MacChatRouteTests`.
- Full Mac suite twice; `git diff <base> -- Conduit Shared | grep '^-[^-]'` prints nothing. macOS only; no iOS build.

## Out of scope (needs a new endpoint or is not cheap)

- Usage and cost (tokens or dollars over time, per model): no aggregate endpoint exists in `HermesClient` or the dashboard bridge. The only usage surfaces are the per-session `/usage` slash text (`AppState.swift:19162`) and `contextBreakdown(_:)` for one session (`HermesClient.swift:2250`).
- Messages today, messages per day: not available; `messageCount` is a per-session lifetime total.
- Server-wide session or user counts, uptime, gateway health: `gatewayDiagnostics` (`AppState.swift:1360`) is a separate fetch behind a sheet; not pulled into Home.
- Sessions run by other processes or clients: invisible by gateway design (D16).
- Inline approve/deny, reply, or cancel from Home; reordering or hiding sections; per-profile layouts; pinned items; a widget (D25).
- A live Kanban event stream: Home polls; the Kanban pane keeps its own stream.

## Open questions (defaults chosen)

1. **Launch default.** Should Home be the pane a fresh launch shows? Default: no; Sessions stays default, Home is one click or Ctrl-Cmd-5 away.
2. **Strip behaviour when five names do not fit.** Default: the ladder (names + compact Home icon, else all icons). Alternative: widen the ideal sidebar column (D6 metrics, larger change) or show the name only on the selected segment.
3. **Home position and key.** Default: last segment, Ctrl-Cmd-5. Alternative: first segment, which would renumber Sessions to Ctrl-Cmd-2 and break muscle memory.
4. **Cron load errors.** Default: surface through the existing `errorMessage` path like the Cron pane. Alternative: direct `listCronJobs()` with errors swallowed into "Unavailable".
5. **Live data source.** Default: `AgentActivityFeed` (titles, tool names, approval text, same as the notch). Alternative: `AppState.sessionLiveStatus(_:)` over the catalog (`AppState.swift:5788`), which has no detail text.
6. **Recent count.** Default 8. Cron runs excluded; a "Cron runs" shortcut is Cron's job.
7. **Kanban board.** Default: the board the user last selected, else the server's current. Alternative: always the server's current.
8. **Home in the notch menu and palette.** Default: palette gets it automatically (`allCases`); the notch has no pane buttons for it.
9. **Sections the user can hide.** Default: none in v1.

## Effort

About 5 days: snapshot and tests 1.0; Kanban loader, model and binding 1.0; views and components with hosted and contrast tests 1.5; route, shortcut, strip ladder and updated tests 1.0; localization, docs, smoke, review fixes 0.5.

## Docs

New decision D24 in `docs/macos/DECISIONS.md` (append after D20 and the D21 to D23 entries, in number order); D10 shortcut table row for Ctrl-Cmd-5; one `PORTING_LEDGER.md` row for `SidebarTab.swift` and one additive row for the new `Localizable.xcstrings` keys; `SMOKE_CHECKLIST.md` Home items.
