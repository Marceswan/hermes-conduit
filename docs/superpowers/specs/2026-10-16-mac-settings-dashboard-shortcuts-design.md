# Mac Settings (Cmd-,) and Switch Dashboard (Cmd-Shift-D): design

Date: 2026-10-16. Status: draft for review (nothing built; no product code written). Decision: D22. Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

Two small menu commands that the PORTING_LEDGER lists as deferred (rows "SettingsView Cmd-, Settings scene" and "Menu: Switch Dashboard (Cmd-Shift-D)"):

1. App menu "Settings..." on Cmd-, opens Conduit's existing Settings UI (`SettingsView`).
2. A menu item "Switch Dashboard..." on Cmd-Shift-D opens the saved-dashboards switcher.

Zero upstream edits is the target. Both are Mac-only wiring in `ConduitMac/`.

## Facts checked in the tree (branch `macos`, 2026-10-16)

Settings:
- Settings is a sheet owned by `MainView` state: `@State settingsPresentation: SettingsSnapshot?` (`Conduit/Views/RootView.swift:75`), presented by `.sheet(item: $settingsPresentation)` (`RootView.swift:195-197`) with `SettingsView(...)` fed by eleven RootView-owned closures wired to `AppState` (`RootView.swift:199-219`). That is the "RootView-owned closures (RootView.swift:189)" the ledger row means. `presentSettings()` is private (`RootView.swift:499`).
- A Mac entry point already exists. D18 added `Notification.Name.macOpenSettingsRequested` (`ConduitMac/App/MacChatRoute.swift:11`) and one gated observer in `RootView.swift:254-263` (`#if os(macOS) // MAC:`; ledger row at `PORTING_LEDGER.md:104`). It guards `settingsPresentation == nil`, clears `settingsOpensAt`, and picks drawer vs direct presentation. The palette posts it (`ConduitMac/Palette/MacPaletteBinding.swift:53`; test `MacPaletteBindingTests.testOpenSettingsPostsTheNotification`). So Cmd-, needs no upstream edit: post that notification.
- `MainView` exists only when `!appState.showLogin && (connection != nil || offlineChatPresentation != nil)` (`RootView.swift:21-27`). With the login screen showing, nobody observes the notification and Cmd-, does nothing. Same as the sidebar today (Settings is unreachable from login).
- There is no `Settings` scene and no `CommandGroup(replacing: .appSettings)` in the tree (`ConduitMacApp.swift:53-58` has one `WindowGroup`; `grep keyboardShortcut(","` finds nothing). So the app menu has no "Settings..." item today, and Cmd-, is unbound. A `Settings` scene would add the item for free but would open a separate window that cannot host the RootView-owned closures, so it is rejected (below).

Switch Dashboard:
- There is no switcher view and no RootView sheet state for dashboards. The ledger wording ("saved-dashboards UI is RootView state") is inexact. The saved-dashboards UI is `SavedDashboardsSettingsDetail` (`Conduit/Views/SavedDashboardsView.swift:15`), a Settings page: `SettingsDestination.savedDashboards` (`AuxiliaryViews.swift:437-438`, `private enum`), routed at `AuxiliaryViews.swift:750-751`, linked from the Settings home row (`:863`).
- `SavedDashboardsSettingsDetail` is an internal struct. Its only inputs are `@EnvironmentObject AppState` and `close: () -> Void`. All the work goes through `AppState.switchDashboard(to:)` (`AppState.swift:9324`), `signOutDashboard`, `removeDashboard`, and `appState.showLogin = true` for Add (`SavedDashboardsView.swift:186-215`). `close()` is called after Add, after a switch that ends at sign-in, and after sign-out or removal of the active dashboard.
- Opening Settings at that page from outside needs the private `SettingsDestination` and `SettingsSnapshot.opensAt`, which is typed `ConduitAppLink.SettingsLink` (`AuxiliaryViews.swift:119`; enum has only `calls` and `voice`, `Conduit/Services/ConduitAppLink.swift:39-44`). Adding a case would also add a `conduit://settings/<page>` deep link and touch three upstream files.
- `SettingsDetailContainer`, `ConduitSettingsSection` (`AuxiliaryViews.swift:2689, 2703`) and `ConduitSheetHeader` (`Conduit/Views/Components/ConduitSheetHeader.swift:4`) are internal, so a Mac-owned sheet can host `SavedDashboardsSettingsDetail` as is. `ConduitSheetHeader` already carries `.keyboardShortcut(.cancelAction)` (R21), so Esc closes the sheet. `macFormSheetSize` (`ConduitMac/Views/MacFormChrome.swift:55`) sizes Mac sheets.
- Hosting precedent: the palette overlay hangs on `RootView` in `ConduitMacApp.rootContent` (`ConduitMacApp.swift:65`, "attached around RootView ... so a sheet covers it"). A sheet can hang there the same way, and it also works over the login screen (a plus: the user can switch to another saved dashboard when the current one cannot sign in).

Keyboard table and menu rules:
- D10 table (`DECISIONS.md:67-83`) and D11, D17: `,` and Cmd-Shift-D are not used. `grep keyboardShortcut("d"` finds nothing in `Conduit/`, `ConduitMac/`, `Shared/`. Used letters with Cmd-Shift: ], [, T, W (`ConduitCommands.swift`). No Conduit menu item uses Cmd-D; whether a system-supplied item claims Cmd-Shift-D is checked at run time by `testOurShortcutsAreUnique` (the new table row), not assumed.
- Rules: menu items are never `.disabled` for sheets; the action calls `MacKeyboardActions.commandsBlocked(by:)` (`MacKeyboardShortcuts.swift:170`; D10, comment at `ConduitCommands.swift:47-50`). Window-scoped actions use `MacSessionTabsActions.isMainChatWindow` (`MacKeyboardShortcuts.swift:272`, identifier prefix `conduit-primary`).
- `MacKeyboardTests.swift:456-482`: `shortcuts()` pins menu path, key and modifier mask; `testEveryShortcutIsInTheMenuAndWinsItsKey` and `testOurShortcutsAreUnique` iterate it. `MacUpdaterTests.testCheckForUpdatesIsInTheAppMenu` shows how to read the app menu (`NSApp.mainMenu.items.first?.submenu`).
- Existing app-menu group: `CommandGroup(after: .appInfo)` holds "Check for Updates..." (`ConduitCommands.swift:25`).

In-flight D21 (session windows, branch `mac-session-windows`, plan `docs/superpowers/plans/2026-10-16-mac-session-windows.md`):
- Adds File > "Open Session in New Window" (Option-Command-N) and an `@Environment(\.openWindow)` property to `ConduitCommands`, a second `WindowGroup(... id: "conduit-session")` in `body` of `ConduitMacApp`, and edits `MacKeyboardActions.focusComposer`. The session window scene does NOT host `RootView`, `MacPaletteView` or this feature's sheet: its content is `MacSessionWindowScene`, which applies locale, tint and colour scheme only.
- Consequence: `.macOpenSettingsRequested` is observed only by the primary window's `RootView`, and the dashboard sheet attaches only to the primary window. If either command ran while a session window is key, the sheet would appear in a window the user is not looking at.

## Options

Settings:
- S1 (recommended): `CommandGroup(replacing: .appSettings)` with a button posting `.macOpenSettingsRequested`. Zero upstream edits; reuses the D18 observer with its existing guards.
- S2: a SwiftUI `Settings` scene. Rejected: separate window, cannot take RootView's closures (would need `SettingsView` extracted from `MainView` or duplicated closure wiring; upstream edits in RootView), and two ways to open Settings.
- S3: move `presentSettings` behind AppState. Rejected: AppState edit, no gain.

Switch Dashboard:
- D-A (recommended): Mac-owned sheet hosting the existing `SavedDashboardsSettingsDetail` under a `ConduitSheetHeader`, presented from `ConduitMacApp.rootContent` by a small `MacDashboardSwitcherStore`. Zero upstream edits. The same view, so rows, status text, Switch / Sign In, context menu sign-out and remove, and Add Dashboard behave exactly as in Settings; no logic is copied.
- D-B: open Settings at the Saved Dashboards page. Needs a new `ConduitAppLink.SettingsLink` case (also a new deep link), the `SettingsDestination(_:)` mapping, and the RootView observer to carry a page: three upstream edits, three ledger rows, a deep-link surface nobody asked for. Fallback only if D-A's sheet presentation misbehaves.
- D-C: just open Settings (home) and let the user click the row. Zero edits but it is not a switcher; rejected as the feature.
- D-D: a Mac menu listing every saved dashboard (one item each, switch on click). Needs a menu that rebuilds on registry changes and a way to drive sign-in and remove; duplicates logic. Rejected for v1; the sheet already lists them.

## Recommendation

Settings posts the existing `.macOpenSettingsRequested`; Switch Dashboard opens a Mac-owned sheet around the unmodified `SavedDashboardsSettingsDetail`. Both go through one small `MacAppActions` helper next to `MacPaletteActions`. No upstream file is edited; no ledger row is needed for a gate, only the two deferred rows are updated to point at D22.

## Behaviour

Menu:
- App menu, in the `.appSettings` slot between About / Check for Updates and Services: "Settings..." (Cmd-,). SwiftUI literal title with a real ellipsis (U+2026), as "Check for Updates..." is written.
- Go menu, after "Command Palette": "Switch Dashboard..." (Cmd-Shift-D).
- Neither item is ever `.disabled`.

Actions (`MacAppActions`, main actor, window and collaborators injectable):
1. Resolve the chat window: the key window if `isMainChatWindow`; if the key window's identifier starts with `conduit-session` (D21 session window), the app's primary chat window (`NSApp.windows` first with the `conduit-primary` prefix); anything else (the Settings sheet itself, a Sparkle dialog, the Quick Ask panel, no window) gives nil and the command does nothing.
2. If `commandsBlocked(by: chatWindow)` (a sheet is attached to it, so Settings or another picker is up, or the dashboard sheet is up), do nothing.
3. Dismiss the command palette if it is open (an overlay would otherwise stay up under the new sheet).
4. If the chat window is not the key window (came from a session window), deminiaturize if needed and `makeKeyAndOrderFront`.
5. Settings: post `.macOpenSettingsRequested` (object nil, as the palette does). Switch Dashboard: `MacDashboardSwitcherStore.present()`.

Decision on session windows: both commands are app-level, so from a session window they bring the main chat window forward and act there. They do not no-op. This matters because the surfaces live only in the main window (see D21 facts above). The prefix `conduit-session` is read from D21's scene id; when that branch merges, replace the literal with `MacSessionWindows.sceneID` (one-line follow-up, noted in the plan).

Sheet content: `ConduitSheetHeader(title: "Saved Dashboards")` over `SavedDashboardsSettingsDetail(close:)`, `macFormSheetSize(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 520)`, `preferredColorScheme` from `appState.themePreference`, environment: `AppState`, locale. `close` dismisses the store. Behaviours inherited from the page: Add Dashboard sets `showLogin` and closes (login shows behind); a switch that ends in sign-in closes; removing or signing out the active dashboard closes. Esc and the X close it.

Edge behaviour:
- Login screen showing: Cmd-, does nothing (no MainView, nothing observes). Cmd-Shift-D opens the sheet (the sheet hangs above `RootView`).
- Settings already presented: Cmd-, and Cmd-Shift-D do nothing (sheet attached). Cmd-, with the iPad-style drawer is not applicable on Mac (`sidebarPresentation` is `.persistent`).
- Dashboard sheet up and the registry changes (switch finishes): the page rebuilds rows itself (`SavedDashboardsView.swift:56-58`).
- Dashboard switch triggers `reloadDashboardScopedPresentation` and may replace `MainView` with the login surface; the sheet hangs above `RootView`, so it survives that swap and the page closes it when `showLogin` becomes true.

## Testing

All in `ConduitMacTests`; no live key events through the real menu (a fired menu item writes the live app's defaults, see MacKeyboardTests header).
- `MacKeyboardMenuTests` (existing class): append `("/Go/Switch Dashboard\u{2026}", "d", [.shift, .command])` to `shortcuts()` (unique + first-match + composer does not swallow). Add `testSettingsIsInTheAppMenuOnCmdComma`: app menu contains "Settings..." with key `,` and mask `.command`, after the About item, exactly one item with that key. This also answers "is SwiftUI adding its own" (it adds none without a `Settings` scene; the test fails if a duplicate appears).
- New `MacAppActionsTests`: Settings posts `.macOpenSettingsRequested` once from the primary window; nothing from a sheet-attached window, from an unrelated window and from nil; from a `conduit-session` window it posts and brings the primary window forward; with no primary window it posts nothing. Switch Dashboard presents the store under the same matrix; dismisses an open palette; no double presentation.
- `MacDashboardSwitcherStore`: present / dismiss; hosted view test: the sheet content shows the "Saved Dashboards" header and the Add Dashboard control (accessibility tree, tree boost on), and the header's close control calls `close` once.
- Source pin: `git diff -- Conduit Shared` is empty.
- Full Mac suite twice (known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`).
- Not verifiable headless, goes to SMOKE_CHECKLIST: real Cmd-, and Cmd-Shift-D keys; the sheet over `MainView` and over the login screen; switching to a dashboard that needs sign-in; sheet presentation while another RootView sheet is queued.

## Open questions (default chosen)

1. Settings from a session window (D21): forward to the main window (chosen) vs. no-op like Cmd-K. Chosen because Settings is app-level and a silent key is worse.
2. Menu titles: "Settings..." and "Switch Dashboard..." as SwiftUI literals, not added to `Conduit/Localizable.xcstrings` (matches the other Mac menu strings; "Settings" alone is catalogued, "Saved Dashboards" is catalogued and reused for the sheet title). Add catalog entries later if the menus are to be localised.
3. Cmd-, on the login screen does nothing (Settings needs a connected `MainView`). Accepted; matches the sidebar.
4. Shortcut Cmd-Shift-D: free in the tree and the D10 table. Fallback if a future change claims it: Option-Command-D.
5. If SwiftUI does not place a `CommandGroup(replacing: .appSettings)` item in the app menu on some macOS version (verify on the smoke machine; the menu test runs on the dev host, macOS 27), fall back to `CommandGroup(after: .appInfo)` beside Check for Updates.
6. Palette gets a "Switch Dashboard" row? Not in v1 (palette spec lists its commands; the menu is the entry point). One closure plus one row if wanted later.

## Docs

DECISIONS.md D22 (and a Cmd-, / Cmd-Shift-D row in the D10 table); PORTING_LEDGER.md: change the two deferred rows to "done, D22; no upstream edit" and note the ledger wording fix (the dashboards UI is a Settings page, not RootView state); SMOKE_CHECKLIST keyboard section gains both shortcuts.

## Effort

About 1 day: actions, store, sheet and menu wiring 0.4; tests 0.4; docs and smoke list 0.2.
