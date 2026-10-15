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

## Shared base (floating panel, stream hub, activity feed)

- [ ] Panel (needs a consumer panel): click a control without moving the mouse and it still clicks; drag past about 4 pt and the panel follows; releasing near each of the four edges snaps to that edge; releasing on an external display docks there; unplug that display and the panel returns to its default notch-anchored spot; after a drag a control under the pointer is not left highlighted and does not fire.
- [ ] Panel never takes focus from the front app: show it from Safari and keep typing there; it appears over a full-screen app and on the current Space.
- [ ] Reconnect while behind other windows: close the Conduit window (Cmd-W), switch to another app, restart the gateway (or turn Wi-Fi off for 20 s and on again). Conduit reconnects within about 30 s without being brought forward (before this change it stayed disconnected until foregrounded).
- [ ] Feed while not frontmost: start a turn in session A, open session B in the main window, switch to another app. A consumer (notch, notifications) still sees A working and then finished.
- [ ] Poll-only session: a session running in the same gateway process but opened by another client shows as working or waiting with no tool name; a CLI or Slack session from another process never appears (expected).
- [ ] Disconnect: turn Wi-Fi off; the consumer shows reconnecting at once and clears its rows after about 15 s with no "done" notification; turn it back on and a turn that finished during the outage is dropped without a notification.

## System integration: Spotlight

Human pass at release time (agents never click or type into the running app, R18).

- [ ] Settings > On this device shows "Show chats in Spotlight", off by default, with "Remove from Spotlight" below it.
- [ ] With the toggle off, Cmd-Space on a known chat title lists no Conduit result. (`mdfind "<chat title>"` is not a reliable check for Core Spotlight items, which live in Spotlight's own index and may not appear there even when indexed; treat an empty `mdfind` as inconclusive, verify on your macOS build.)
- [ ] Turn the toggle on, wait about 5 seconds (2 s debounce), Cmd-Space a chat title: the chat is listed with the model and "N messages", no message text.
- [ ] Open the result with Conduit closed: Conduit opens on that chat once connected, and opens it once (the SwiftUI and AppKit routes both feed one inbox; see D19). Repeat with Conduit running.
- [ ] Open the result with Conduit running on another profile: Conduit switches to the chat's profile and opens it.
- [ ] Rename a chat: Spotlight shows the new title. Archive a chat: its result disappears. Delete a chat: its result disappears. Restore an archived chat: it reappears.
- [ ] Switch profile: the new profile's chats are listed and the first profile's are gone.
- [ ] Switch to another dashboard: the old dashboard's chats are gone.
- [ ] Scroll the chat list so older pages load: older chats are added; chats that scroll out of the loaded page stay listed.
- [ ] Turn the toggle off: searching a chat title finds nothing. Turn it on, tap "Remove from Spotlight": the index empties, the toggle stays on, and a chat you open or rename is added again.
- [ ] A stale result (chat deleted on another device) opens Conduit and shows "That chat is no longer available."
## System integration: Services

- [ ] Run `/System/Library/CoreServices/pbs -update`, relaunch Conduit once; System Settings > Keyboard > Keyboard Shortcuts > Services > Text lists "Send to Hermes"; its toggle works
- [ ] Select text in TextEdit and Safari, run the Service with Conduit closed: Conduit opens, new chat, text in the composer, not sent
- [ ] Same with Conduit connected and mid-turn: the running chat is untouched, the text is in a new chat
- [ ] Select text in a Mail message and an image-only selection: Service is absent or reports "No text selected"; nothing breaks
- [ ] Run the Service with Conduit running in the background, disconnected (Hermes unreachable), and with its window closed (red close button): Conduit comes forward at once; the text lands in a new chat when Hermes connects
- [ ] Select a very large block of text (several MB) and run the Service: Conduit stays responsive and the composer holds the first 20,000 characters plus "[truncated]"
- [ ] Switch profile before the cold launch connects: the parked text is not applied to the other profile
- [ ] With a non-English system language, the Services menu item shows the translated title

## System integration: Shortcuts

- [ ] Shortcuts app lists "New Conduit Chat" and "Open Conduit Chat" under Conduit on macOS 14 and on macOS 26
- [ ] Run "New Conduit Chat" with Conduit closed and with a Message: Conduit opens a new chat with the text in the composer, not sent
- [ ] Same with a Profile that is not active: the profile switches first; with a Profile that no longer exists the action fails with "Conduit has no profile named ..."
- [ ] Run "Open Conduit Chat" with a chat picked from the list; with Conduit closed; with a deleted chat (shows "That chat is no longer available.")
- [ ] Spotlight (Cmd-Space) shows the app shortcut "New Conduit Chat"; saying or running "Open a chat in Conduit" asks which chat
- [ ] The existing "Ask Hermes About Screen" shortcut and "Talk to Conduit" still run

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
  - [ ] Command palette (D18): Cmd-K opens it from the composer, the sidebar and Bots / Cron / Kanban; Cmd-K again and Esc close it; with text in the composer the draft is untouched and typing resumes there after closing.
  - [ ] Palette: type a session name, Return opens it; `#`, `/`, `>`, `@` scope the list; Up / Down / Home / End move the highlight, Tab does nothing; Esc clears the query, then closes. (The hosted test sends synthetic arrow and Esc events to the focused field; confirm with the real keyboard.)
  - [ ] Palette: `/new` with no chat open is disabled with "No active chat"; a slash command that needs an argument (`/background`, `/queue`, `/steer`, or any with an argument hint) lands in the composer as `/name ` when the draft is empty; with typed text it asks "Replace your draft?" first (Esc keeps the draft). From Kanban, Bots or Cron an inserted or run slash command brings the chat pane back.
  - [ ] Palette: Switch Model... opens the model picker; Settings opens Settings; New Chat, Hide Sidebar, Check for Updates run; the active profile row shows a check and does nothing; Stop Response appears only while a reply streams.
  - [ ] Palette confirmations: Stop Response (while a reply streams), `/undo`, `/compress`, `/yolo` and any skill command replace the list with a question; Return confirms, Esc or typing goes back and nothing runs; switching profile while a reply streams asks too, and switching while idle does not. VoiceOver reads the question when it appears and reads each row as the arrows move.
  - [ ] Palette focus: open it from the session list or the search field, press Esc: the list or field has focus again (not only the composer). Light and dark: subtitles and the selected row's subtitle are legible; an unread row shows its dot on the selected row too.
  - [ ] Palette with a sheet open (Settings, model picker): Cmd-K does nothing. Japanese IME in the search field: Return confirms the composition and does not run the row.
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
  - [ ] Ask About Window (macOS 14 and 15, clean Screen Recording state: remove Conduit under System Settings > Privacy & Security > Screen & System Audio Recording first): Chat > Ask About Window... (Cmd-Shift-W) opens the system window picker with no Screen Recording permission prompt. Pick a Safari window: a screenshot chip appears in the open chat's composer. Esc in the picker: nothing happens and no error shows, and the item works again. With no chat open it creates one and attaches. Conduit's own windows are not offered (or, if the picker still lists them, record it). Set the attachment limit to 8 MB and pick a large busy window: it attaches as JPEG or shows the too-large message, never a crash. The composer + menu has the same item.
  - [ ] Quick Ask (D15), macOS 14 and 15.2 or later: press Option-Shift-Space from Safari, from a full-screen app and from a window on a second display. The panel appears under the mouse near the top center, the field is focused (type at once, without clicking), the front app keeps its menu bar, and typing does not leak into the front app. Press the hotkey again and Esc: the panel hides each time and the field is focused again on the next open.
  - [ ] Quick Ask: ask "what is 2+2", watch the reply stream with markdown; press Esc while it streams, wait ten seconds, press the hotkey again within 120 s: the finished reply is shown and the sidebar lists one new session. After 120 s the panel opens empty. Cmd-N in the panel clears a restored exchange.
  - [ ] Quick Ask: Cmd-Return mid-stream. Conduit comes forward, the Quick Ask session opens as a tab and the reply keeps streaming in the main chat. The chat that was open before is not changed by the panel at any point. Record whether the session opens when the stored id is not yet known (Cmd-Return within a second of Return).
  - [ ] Quick Ask: Cmd-. in the panel stops the Quick Ask turn and does not stop a turn running in the main chat (Chat > Stop Response also owns Cmd-.; with the panel key, the panel's button must win).
  - [ ] Quick Ask: ask something that triggers an approval or clarify prompt. The panel says "Hermes needs your input" with Open in Conduit as the default action and never shows an answer control.
  - [ ] Quick Ask: disconnect from the network (or stop the gateway). The panel shows "Not connected" or "Reconnecting" with Open Conduit and a disabled field; reconnect and it recovers without reopening. With Conduit in the background (not the active app), the reconnect still happens (shared base exemption).
  - [ ] Quick Ask: start two Quick Ask turns in separate invocations (wait 120 s between) while the main chat also streams. All three replies are correct and none appears in the wrong place. When the gateway refuses with its session limit (4090), the panel says so, keeps the typed prompt, and Retry works after a session is freed.
  - [ ] Quick Ask, macOS 15.0 or 15.1 only: the Chat menu shows "Quick Ask shortcut unavailable on this macOS version. Use Chat > Quick Ask." and Chat > Quick Ask still opens the panel. Any macOS: switch Chat > Quick Ask Shortcut off and the hotkey stops (Space types normally), on again and it works. Register Option-Shift-Space in another app first (or run a second Conduit) to see the "taken by another app" line.
  - [ ] Quick Ask: with Conduit running and no window open (red close button), the hotkey opens the panel and an ask works (the stream subscription starts at launch). Quit and relaunch with the shortcut toggle off: the hotkey does nothing.
  - [ ] Quick Ask in VoiceOver: the panel is announced as "Quick Ask", the field is "Ask Hermes", every button is announced, and the panel is reachable while key.
