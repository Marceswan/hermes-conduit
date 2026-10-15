# macOS smoke checklist

Run against a real Hermes dashboard before every release build.

- [ ] Log in with password; session list appears in the left column
- [ ] Log in with OAuth: browser opens, approve, app signs in; Cancel returns to login
- [ ] Open a session; history renders; long reply scrolls; scroll up during streaming stays put
- [ ] Send a message; reply streams; code block, math, Mermaid block render
- [ ] Select text in a reply across a line; Cmd-C copies; Cmd-F finds (per message; transcript-wide Find in Chat is deferred)
- [ ] Paste a screenshot (Cmd-Shift-Ctrl-4 then Cmd-V): attaches as image
- [ ] Copy a PNG in Finder, paste: attaches as image; drag an image file onto composer: attaches as image (non-image drops are not supported, same as upstream)
- [ ] Composer reasoning picker ("Medium") and the tool-call card (name, time, chevron) read in light mode: the picker label is near-black, not pale gold, and the card's tool name, time and chevron are clearly legible in light and dark (automated in `ComposerToolCardContrastTests`; check by eye in a light-mode window).
- [ ] Return sends; Shift-Return newline; Japanese IME Return confirms without sending
- [ ] Approve a tool call inline
- [ ] Switch model and reasoning effort
- [ ] Cmd-N new chat; Cmd-. stops a running response; Cmd-Ctrl-S toggles the sidebar column
- [ ] Close window mid-stream, wait 30 s, click Dock icon: reply completed
- [ ] Admin tabs: Capabilities toggle, Jobs list, Connectors, Logs, Kanban board load
- [ ] Bot Mode: bot list loads; open a Bot Chat
- [ ] Switch between two saved dashboards
- [ ] Fresh install from DMG on a second Mac: no Gatekeeper prompt

## Release gate (run before distributing a DMG)

- [ ] Log in, quit, relaunch: still signed in and no keychain prompt
- [ ] After login, no "would like to access data from other apps" prompt
- [ ] Live hover pass and Esc pass on a long chat, with Activity Monitor CPU under about 10% while hovering
- [ ] Close the window mid-stream, wait 30 s, click the Dock icon: reply completed
- [ ] The `.windowToolbar`-hidden sheets (e.g. SidebarView drawer root) don't break the main window toolbar
- [ ] Notarized DMG installed on a second Mac with no Gatekeeper prompt

## Agent pre-checks (2026-10-13)

Debug build launched from DerivedData on the dev Mac. No logged-in item was exercised.

- R9 (a) app-group / "access data from other apps" consent prompt on first launch: PASS. Full-screen capture after launch showed the login screen only, no consent dialog.
- R9 (b) keychain / group-container errors in unified log: UNVERIFIED. Predicate used: `log show` filtered to process Conduit, which returned 0 lines in the window, so absence of errors is not evidence. E2E key save is UNVERIFIED (needs a logged-in session).
- (c) Logo clipping: FAIL on the first run (focus-scroll under the title bar). Fix applied in 11e; recheck UNVERIFIED, see Open findings.
- (d) Dock reopen after Cmd-W: UNVERIFIED. An unintended "Connection Setup / Test connection" sheet was open (see Incident), so Cmd-W did not close the window. Process stayed running; reopen not tested.
- (e) App icon: was FAIL (full-bleed square). Regenerated in 11e; static check PASS (alpha, transparent corners). See Open findings.
- (f) Cmd-Ctrl-S sidebar toggle: UNVERIFIED (not applicable at the login screen).

### Incident

During check (c) an agent AX click on empty window space plus app activation was followed by a failed login and a "Test connection" attempt ("Hermes rejected that username or password"). No auto-submit or auto-test path exists in the app: agent clicks reached Connect and Test Connection (the login form holds autofilled credentials). At least 2 auth attempts reached the production dashboard.

Rule R18: agents never send clicks or key events to the running app. Launch smoke checks are launch plus screenshot only; if a system prompt covers the window, do not dismiss it, report the item UNVERIFIED, and quit the app.

## Updates

- [ ] Conduit > Check for Updates... is present after About.
- [ ] With a newer release published, the prompt shows the release notes and Install / Skip This Version / Remind Me Later.
- [ ] Install relaunches into the new version (Conduit > About shows it).
- [ ] On a Mac with an older non-Sparkle build, one manual DMG install enables updates (see docs/macos/RELEASING.md).

## System integration: Spotlight

Human pass at release time (agents never click or type into the running app, R18).

- [ ] Settings > On this device shows "Show chats in Spotlight", off by default, with "Remove from Spotlight" below it.
- [ ] With the toggle off, Cmd-Space on a known chat title lists no Conduit result. (`mdfind "<chat title>"` is not a reliable check for Core Spotlight items, which live in Spotlight's own index and may not appear there even when indexed; treat an empty `mdfind` as inconclusive, verify on your macOS build.)
- [ ] Turn the toggle on, wait about 5 seconds (2 s debounce), Cmd-Space a chat title: the chat is listed with the model and "N messages", no message text.
- [ ] Open the result with Conduit closed: Conduit opens on that chat once connected. If it only activates the app and nothing opens on a cold launch, add the AppKit route `application(_:continue:restorationHandler:)` to `ConduitMacAppDelegate` (see D19) and record it.
- [ ] Open the result with Conduit running on another profile: Conduit switches to the chat's profile and opens it.
- [ ] Rename a chat: Spotlight shows the new title. Archive a chat: its result disappears. Delete a chat: its result disappears. Restore an archived chat: it reappears.
- [ ] Switch profile: the new profile's chats are listed and the first profile's are gone.
- [ ] Switch to another dashboard: the old dashboard's chats are gone.
- [ ] Scroll the chat list so older pages load: older chats are added; chats that scroll out of the loaded page stay listed.
- [ ] Turn the toggle off: searching a chat title finds nothing. Turn it on, tap "Remove from Spotlight": the index empties, the toggle stays on, and a chat you open or rename is added again.
- [ ] A stale result (chat deleted on another device) opens Conduit and shows "That chat is no longer available."

## Open findings

- (c) Login logo clipping: fix applied in `Conduit/Views/LoginView.swift` (focus `scrollTo` gated to iOS, ledger R4). Owner: 11e. Launch screenshot on 2026-10-13 was covered by a keychain prompt (see below), so the visual result is UNVERIFIED; user confirms on the next launch.
- (e) App icon: regenerated by `scripts/make-mac-icon.swift`; built `AppIcon.icns` has alpha and transparent corners (verified by `sips -g hasAlpha` and a pixel read of a rendered PNG). Static check PASS; Dock look is for the user.
- Keychain prompt: launching showed a system prompt "Conduit is trying to Unlock Conduit". Likely a keychain item ACL tied to a differently-signed earlier build; should go away with consistent Developer ID signing. Owner: user, recheck after installing the notarized build.
- Live hover checks (R23), user:
  - [ ] Hover an icon button: tooltip after about 0.6 s, hand cursor, accent highlight.
  - [ ] Moving away reverts the cursor and removes the highlight.
  - [ ] View > Highlight Controls on Hover toggles the highlight.
  - [ ] No double bubble on any control.
- Esc checks, user:
  - [ ] Esc closes Settings, Bot editor and Profile sheets.
  - [ ] Esc does nothing in the Model picker while editing; it must never press Done.
  - [ ] Esc in a file Open panel still cancels the panel natively.
- (d) Dock reopen after closing the window with its red close button (Cmd-W now closes a tab, not the window) and close-window-mid-stream: user.
- Logged-in items (key save end to end, sidebar toggle): user.
- Keyboard checks (D10), user (hosted tests send synthetic events only; none of these has run against real hardware keys):
  - [ ] Ctrl-Cmd-1 to Ctrl-Cmd-4 switch Sessions / Bots / Cron / Kanban from the composer and from the sidebar search field.
  - [ ] Cmd-[ and Cmd-] (and Opt-Cmd-Up / Down) open the previous / next session in the order shown, including with a search filter; greyed at the ends; Cmd-[ in the composer does not type or indent.
  - [ ] Cmd-F focuses "Search sessions" (also with the sidebar hidden and from the composer); with text selected in a message it opens that message's find bar instead; Edit > Find > Find... shows no Cmd-F.
  - [ ] Cmd-F then Cmd-L (or a click in the composer) quickly: the keyboard ends in the composer, not pulled back to the search field. Ctrl-Cmd-1..4, Cmd-1..9, Cmd-]/[, Cmd-W and Cmd-F do nothing while a sheet (model picker, Settings) is open.
  - [ ] Composer: the macOS inline-prediction Tab accept (if enabled) versus Tab leaving the composer.
  - [ ] Cmd-L from Kanban returns to chat and focuses the composer.
  - [ ] Tab from the composer goes to the sidebar list, then the search field, then back to the composer (Shift-Tab reverses); the list shows an accent ring in light and dark; Up / Down / Home / End move it, Return opens it.
  - [ ] System Settings > Keyboard > Keyboard navigation off and on: Tab still reaches list, search field and composer; buttons join the loop only when it is on.
  - [ ] Session tabs (D11): open 3 sessions and see 3 tabs; Cmd-1, Cmd-9 and Ctrl-Tab move between them.
  - [ ] Cmd-W twice closes two tabs, then Cmd-Shift-T brings the last one back; Cmd-W while Settings (a sheet) is open does nothing; Esc closes it.
  - [ ] Delete a session from the sidebar and its tab goes; rename a session and its tab stays with the new title; relaunch restores the tabs.
  - [ ] Delete the chat that is open (its tab is active): the tab goes and the replacement chat gets a tab; no stale tab remains.
  - [ ] Ctrl-Cmd-1..4 switch Sessions / Bots / Cron / Kanban (plain Cmd-1..4 now select tabs).
  - [ ] Cmd-Shift-] and Cmd-Shift-[ wrap: from the last tab Cmd-Shift-] goes to tab 1, from tab 1 Cmd-Shift-[ goes to the last tab.
  - [ ] Bot chat tab: open a bot chat, switch to another tab, then click the bot chat's tab. It reopens and is not marked unavailable (dimmed).
  - [ ] Group room: open a group room (the strip is hidden there), then press Cmd-1. The chat returns with tab 1 selected and the room closes. Cmd-W while the room is open does nothing.
  - [ ] Cmd-W under Kanban (and Bots, Cron) does nothing; Cmd-1 under Kanban returns to chat with tab 1.
  - [ ] Tab strip layout, live: drag the window edge wider and narrower, press the green zoom button, enter and leave full screen, and drag the sidebar to its 390 pt maximum with the window at its 820 pt minimum. Refresh and the connection status dot stay visible in the toolbar (never in the overflow menu), the strip regrows after each change, and the active tab stays scrolled into view. Full screen is the known weak point: if the strip stays at about 120 pt until a resize, record it.
  - [ ] Status dot, Refresh and search stay put and do not flicker at any window width. Watch the toolbar for ten seconds at 820 pt, at the default width and at full width, with the sidebar shown and hidden. Clicking the search item expands its field and may push the strip and the other items to overflow until it collapses (known gap, D11): record what you see, do not fail the line for it. With the 390 pt sidebar at 820 pt one item may be in overflow (D11).
  - [ ] The status dot check must be done on a real window at 1291 pt with the sidebar shown (and again with it hidden), in the build under test and not a hosted harness: before judging, open Conduit > About and confirm the version is the build you mean to test, and quit and relaunch if the app was started before the build was installed or from a mounted disk image (a process started from the 0.1.1 image kept the 0.1.1 flicker after 0.1.2 was installed; its live toolbar matched `MacToolbarRealWindowTests` run against the 0.1.1 code exactly, D11). The Refresh button, the status dot and the search item all stay on the toolbar and none moves for ten seconds.
  - [ ] Window tabbing is off: the Window menu has no window-tab items ("Show Next Tab", "Show Previous Tab", "Show Tab Bar", "Merge All Windows"), and Ctrl-Tab switches session tabs.
  - [ ] Long assistant messages show their last line in full at any window width. Open a reply with several paragraphs (bold runs, links, a short final line) and drag the window from its minimum to full screen: the last line is never cut off above the message action row, in Smallest and Largest chat text sizes too (D13).
  - [ ] Kanban > New task: the sheet is System Settings style (grouped cards, each section header above its card, each footer under its card and clear of the next header), Model / Skills / Depends on are plain rows (label left, value and chevron right, the whole row clickable, no gold button slab), the description field is a visible bordered box with a "Description" prompt, nothing is clipped at the right edge, and the Model and Skills pickers (sheets from the sheet) are grouped too. Board settings, filters and New Bot look the same way.
  - [ ] Kanban > New task with Full Keyboard Access on: Tab reaches Model, Skills and Depends on, each shows a visible focus ring, and Space or Return opens its picker. (Known: VoiceOver reads the empty description's "Description" prompt as well as the editor's label; the prompt stays in the accessibility tree so MacFormStyleTests can observe it.)
  - [ ] Pane title (macOS 26 and later; check in the installed build and confirm About shows the version under test): on Bots, Cron and Kanban the toolbar shows no pane name above the pane's own header, the search item sits at the trailing edge (same place as on Sessions), nothing is in the overflow menu, and the Window menu lists the pane name. Switch back to Sessions: the tab strip, Refresh, status dot and search are unchanged. On macOS 14 to 25 the pane title still shows in the toolbar (the 0.1.3 layout).
  - [ ] Bulleted and numbered lists in an assistant reply: each marker sits on its item's first line, items are evenly spaced, and wrapped lines hang under the item text. Check a reply that has a list plus a divider, table or code block (that path renders lists as marker + text rows), light and dark.
  - [ ] Density: the sidebar uses desktop sizes. Workspace, Settings, New Chat, voice, more and folder are 32 pt tall with 6 pt gaps; the tab strip is a 32 pt container; filter chips are 24 pt; session cards are about 44 pt apart with a 24 pt icon; the Kanban header buttons are 32 pt. Check light and dark, and that Tab focus rings and hover outlines still follow each control's rounded shape. Toolbar items (Refresh, status dot, search) and the composer are unchanged.
