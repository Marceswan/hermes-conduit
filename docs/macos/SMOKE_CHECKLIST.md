# macOS smoke checklist

Run against a real Hermes dashboard before every release build.

- [ ] Log in with password; session list appears in the left column
- [ ] Log in with OAuth: browser opens, approve, app signs in; Cancel returns to login
- [ ] Open a session; history renders; long reply scrolls; scroll up during streaming stays put
- [ ] Send a message; reply streams; code block, math, Mermaid block render
- [ ] Select text in a reply across a line; Cmd-C copies
- [ ] Cmd-F in a long chat opens the find bar over the transcript; typing a word shows "N of M", highlights it in every visible message (current hit orange), and jumps to the newest hit
- [ ] Find: Return / Cmd-G next, Shift-Return / Cmd-Shift-G previous, wrapping at both ends; a hit in a message far above scrolls it into view; Esc or Done closes, clears the highlights and returns focus to where it was
- [ ] Find: Japanese IME in the field, Return confirms the composition and does not step; the bar says "Loaded messages only" while older pages exist; a link's destination text is not a hit
- [ ] Cmd-G / Cmd-Shift-G with the bar closed or focus outside the bar (composer, a message) open or step the chat find hits
- [ ] Session window (needs D21 merged): Cmd-F / Cmd-G / Cmd-Shift-G drive the focused message's own find bar; nothing happens with no message focused
- [ ] Cmd-F with the sidebar list focused still focuses Search sessions; under Bots / Cron / Kanban it does too; with a sheet open nothing happens; in a session window Cmd-F opens the focused message's own find bar
- [ ] Paste a screenshot (Cmd-Shift-Ctrl-4 then Cmd-V): attaches as image
- [ ] Send a message with Return, then with the Send button: the message field keeps the keyboard each time and the next message can be typed at once. Click a message, then click Send: the field takes the keyboard back. Same after Stop.
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
- [ ] Close the window mid-stream, also hide Conduit (Cmd-H) and leave it hidden for 2 minutes, click the Dock icon: reply completed (D29; use a reply that runs longer than 2 minutes). While it runs, `pmset -g assertions` lists a Conduit assertion and Activity Monitor shows App Nap "No" for Conduit
- [ ] The `.windowToolbar`-hidden sheets (e.g. SidebarView drawer root) don't break the main window toolbar
- [ ] Notarized DMG installed on a second Mac with no Gatekeeper prompt
- [ ] Widgets: the notarized app from the DMG, installed in /Applications and launched once, lists `ConduitMacWidgets` in `pluginkit -mAvvv -p com.apple.widgetkit-extension`, and adding a Conduit widget shows no consent prompt
- [ ] Launch the exported/notarized build once; `pluginkit -mAvvv -p com.apple.widgetkit-extension` lists ConduitMacWidgets (the export step itself was verified by signature only, never launched)

## Background activity (D29)
A stream holds an App Nap token (the Mac may still sleep when idle). A live call holds a stronger token (the Mac does not sleep when idle). Check with Activity Monitor (View > Columns > App Nap) and `pmset -g assertions | grep -i conduit`. The call token shows as a `PreventUserIdleSystemSleep` assertion named "Conduit: a reply is streaming or a voice call is live". The stream token shows no `pmset` line; Activity Monitor shows App Nap "No" for Conduit while it holds.
- [ ] Idle: with Conduit hidden and no reply, no call: no Conduit line in `pmset -g assertions`; the App Nap column reads "Yes" after a short while.
- [ ] Stream, window closed: start a reply that runs longer than 2 minutes, close the window, hide Conduit (Cmd-H). App Nap reads "No" for Conduit the whole time. After 2 minutes, click the Dock icon: the reply is complete, not stopped part way.
- [ ] The reply ends with Conduit still hidden: App Nap reads "Yes" again within about 10 seconds (the 5 s grace, then App Nap's own delay). Two replies sent a few seconds apart do not drop and retake the token in between.
- [ ] A chat the user left: start a long reply in a tab, switch to another tab, close the window. The reply still completes (the main window's turn state follows the open chat only; the activity feed covers the other one).
- [ ] A session window (D21) and Quick Ask (D15): start a long reply in each, close or hide the main window. The same result as the stream check.
- [ ] Call: start a Gemini Live, GPT-Live, Grok Live or Local Live call, then minimise it or close the window. `pmset -g assertions` lists the Conduit `PreventUserIdleSystemSleep` assertion. After hang-up it is gone within about 10 seconds (2 s poll plus the 5 s grace).
- [ ] A call that fails with its screen open (turn the network off at connect): the assertion goes away while the failed screen stays up. It does not stay for as long as the screen is open.
- [ ] Quit Conduit while a reply streams or a call runs: `pmset -g assertions | grep -i conduit` prints nothing at once.

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
## Launch at login (D28)

Human pass at release time (agents never click or type into the running app, R18). Use the installed copy in /Applications.

- [ ] Settings > On this device shows "Open Conduit at login" below the Spotlight row, off by default. System Settings > General > Login Items does not list Conduit before the first click.
- [ ] Turn the toggle on: Conduit is in the Open at Login list, or the footnote "Allow Conduit in System Settings > General > Login Items to finish." and the button "Open Login Items" show under the toggle. The toggle stays on.
- [ ] With the footnote showing, click "Open Login Items": System Settings opens on Login Items. Allow Conduit there and return to Conduit: the footnote and the button are gone and the toggle stays on, with Settings still open.
- [ ] Turn Conduit off in System Settings > General > Login Items and return to Conduit: the toggle is off.
- [ ] Turn the toggle off in Conduit: Conduit is no longer in the Login Items list.
- [ ] With the toggle on, log out and log in: Conduit opens with its normal window (D28: no hidden start).
- [ ] A copy that runs from a build folder or a disk image: turn the toggle on. Either it works, or the error footnote shows and the toggle goes back to off. No crash.
- [ ] Turn the toggle off at the end of the pass, so a test copy does not open at your next login.

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

## Notifications (D20)

- [ ] Fresh defaults: no permission prompt at launch. Background the app, run a 40 s turn: the prompt appears once, then a Done banner with Reply and Open
- [ ] Type a reply inline in the banner (banner and alert styles): it is sent to that session; open the session and the message is there. On a locked Mac Reply, Approve and Deny ask for unlock first
- [ ] Trigger an approval while another app is frontmost: banner after about 3 s titled "Approval needed" with the command in the body and the session name as the subtitle; Approve, Deny, Open; Approve resumes the turn; there is no Always or Session button
- [ ] Approval whose command is over 300 characters (or has a newline): the banner has Deny and Open only
- [ ] Answer the same approval in the app inside 3 s: no banner. Answer on a second Mac after delivery: the first Mac's banner disappears
- [ ] Ask a single-question clarify: Reply answers it; a multi-question clarify has Open only
- [ ] Look at an approving session (app frontmost, that session active): no banner; switch to another tab or app while it is still pending: the banner arrives
- [ ] Focus on holds banners; they appear when Focus ends and disappear if the session was opened meanwhile
- [ ] Quit, then click a delivered notification from a cold launch: the app opens the session once connected
- [ ] Click a notification from a different dashboard or profile: the app activates only
- [ ] Disconnect Wi-Fi, then press Approve on an older banner: "Couldn't send" with Open, and the card is still pending in the app
- [ ] Interrupt a long turn with Stop: no notification. Five quick long turns across sessions: three banners and one "5 conversations finished"
- [ ] Settings > Notifications > On this Mac: toggles and threshold apply immediately; with notifications blocked in System Settings the status says so and the button opens the pane (record which URL worked)
- [ ] Limit check: a session started from a terminal Hermes (not attached to this socket) does not notify
- [ ] Turn off Wi-Fi mid-turn, let the turn finish on the gateway, turn Wi-Fi on: no Done banner for that turn (the feed marks it observedGap)
- [ ] Quit Conduit while an approval is pending, relaunch with another app frontmost: one Approve/Deny banner arrives (read from the feed snapshot)
- [ ] Session title containing a right-to-left override or many line breaks shows cleaned up in the banner

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
  - [ ] Ctrl-Cmd-5 shows Home from the composer, the sidebar search field and Bots/Cron/Kanban; Ctrl-Cmd-1 returns to Sessions with the draft intact (D24).
  - [ ] Ctrl-Cmd-6 shows Artifacts from the composer and the sidebar search field; Ctrl-Cmd-1 returns to Sessions with the draft intact (D26).
  - [ ] Cmd-[ and Cmd-] (and Opt-Cmd-Up / Down) open the previous / next session in the order shown, including with a search filter; greyed at the ends; Cmd-[ in the composer does not type or indent.
  - [ ] Cmd-F focuses "Search sessions" from the sidebar list or search field (also with the sidebar hidden / chat not shown); from the composer or a message it opens the whole-chat find bar (D23); Edit > Find > Find... shows no Cmd-F.
  - [ ] Cmd-F then Cmd-L (or a click in the composer) quickly: the keyboard ends in the composer, not pulled back to the search field. Ctrl-Cmd-1..4, Cmd-1..9, Cmd-]/[, Cmd-W and Cmd-F do nothing while a sheet (model picker, Settings) is open.
  - [ ] Composer: the macOS inline-prediction Tab accept (if enabled) versus Tab leaving the composer.
  - [ ] Cmd-L from Kanban returns to chat and focuses the composer.
  - [ ] Command palette (D18): Cmd-K opens it from the composer, the sidebar and Bots / Cron / Kanban; Cmd-K again and Esc close it; with text in the composer the draft is untouched and typing resumes there after closing.
  - [ ] Palette: type a session name, Return opens it; `#`, `/`, `>`, `@` scope the list; Up / Down / Home / End move the highlight, Tab does nothing; Esc clears the query, then closes. (The hosted test sends synthetic arrow and Esc events to the focused field; confirm with the real keyboard.)
  - [ ] Palette: `/new` with no chat open is disabled with "No active chat"; a slash command that needs an argument (`/background`, `/queue`, `/steer`, or any with an argument hint) lands in the composer as `/name ` when the draft is empty; with typed text it asks "Replace your draft?" first (Esc keeps the draft). From Kanban, Bots or Cron an inserted or run slash command brings the chat pane back.
  - [ ] Palette: Switch Model... opens the model picker; Settings opens Settings; New Chat, Hide Sidebar, Check for Updates run; the active profile row shows a check and does nothing; Stop Response appears only while a reply streams.
  - [ ] Palette confirmations: Stop Response (while a reply streams), `/undo`, `/compress`, `/yolo` and any skill command replace the list with a question; Return confirms, Esc or typing goes back and nothing runs; switching profile while a reply streams asks too, and switching while idle does not. VoiceOver reads the question when it appears and reads each row as the arrows move.
  - [ ] Palette focus: open it from the session list or the search field, press Esc: the list or field has focus again (not only the composer). Light and dark: subtitles and the selected row's subtitle are legible; an unread row shows its dot on the selected row too.
  - [ ] Settings (D22): Cmd-, and Conduit > Settings... open Settings from the composer, the sidebar and Bots / Cron / Kanban; with Settings or the model picker already open, Cmd-, does nothing; on the login screen it does nothing. With a session window key (D21) it brings the main window forward and opens Settings there.
  - [ ] Switch Dashboard (D22): Cmd-Shift-D (Go > Switch Dashboard...) opens the Saved Dashboards sheet over the chat and over the login screen; Switch to another saved dashboard works and closes the sheet when it ends at sign-in; Add Dashboard closes the sheet and shows login; Esc and the X close it; with another sheet up it does nothing; with the palette open the palette closes first.
  - [ ] With the Switch Dashboard sheet open, open a `conduit://settings/...` link: note whether Settings stacks over the sheet.
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

## Notch status (D16)

- [ ] Idle: nothing at the top of the screen; Settings > On this device > Notch status shows the three modes and the visibility footnote.
- [ ] Start a long turn: compact wings appear around the notch (a pill on an external or non-notch display); the mark pulses; the right wing names the tool or the count.
- [ ] Hover the compact surface: it expands after about 200 ms and collapses about 400 ms after the pointer leaves. Reduce Motion on: fade only.
- [ ] Trigger an approval in a background session: the panel expands and stays; the row says "Approval needed" with the description and command, the chat title in small text below; Allow once and Deny are disabled for about 600 ms and then work; Always allow exists only in the "..." menu; a smart-denied request has no menu.
- [ ] Approval with a very long command (over 160 characters) or one containing invisible characters: the row shows "Review in Conduit" instead of Allow once, no "..." menu, Deny still works; Review opens the session.
- [ ] Answer from the notch; answer from the main window; answer from Hermes Desktop: the row disappears each time with no error.
- [ ] Approval with a multi-line command (for example `ls` then a second line): the row shows "Review in Conduit", not Allow once; Deny still works.
- [ ] Approval with a 150-character command: the whole command is on screen (no "..." cut by the layout) before Allow once is offered.
- [ ] Two displays: drop the surface on the second display, then focus a window on the first; the surface stays on the second until Reset Agent Status Position.
- [ ] Mode Off: no surface, and Activity Monitor shows no wakeups from the notch while an agent works (Show Agent Status pins it for a look).
- [ ] A clarify or sudo/secret prompt: the row says "Answer in Conduit" and clicking opens that session.
- [ ] Click a working row: Conduit comes forward on that session. (Kanban rows and the cron footer are follow-up; nothing to test in v1.)
- [ ] Drag the compact surface to the bottom edge, the left edge, the right edge, then onto a second display: it follows the pointer, snaps to the nearest edge on release, shows a vertical capsule on left and right, and its expanded panel opens inward (up from the bottom, right from the left edge, left from the right edge) with rows stacked. The wings only appear in the default placement.
- [ ] Docked at the bottom, left and right edges, with the Dock visible at that edge: the surface draws above the Dock (window level `.statusBar`).
- [ ] Quit and relaunch: it returns to the saved spot on each display. Unplug the display it was docked on: it falls back to the notch (or the top-center pill) and returns to the saved spot when the display is plugged in again.
- [ ] Press and release Allow once without moving: it fires. Press it and drag past a few points: the panel moves, nothing is approved, and no control stays highlighted afterwards.
- [ ] While dragging, let an approval arrive: nothing resizes or announces until you release, then the panel expands and the buttons are disabled for about 600 ms.
- [ ] Go > Reset Agent Status Position, then (docked again) double-click the capsule or grip: both return it to the notch.
- [ ] Turn finishes: checkmark row for 4 s expanded, stays as a row for 30 s (max 3), then disappears. A failed turn is red with the error text.
- [ ] A session started in the CLI or Slack never shows (known limit, D16).
- [ ] Go > Show Agent Status pins the panel (also with the mode Off) and shows "No agents running" with the limit note; again hides it. Esc collapses it with Conduit frontmost; click outside collapses it always.
- [ ] Disconnect Hermes: rows clear after about 15 s and the panel hides; pinned shows "Not connected to Hermes".
- [ ] Capture on a notch Mac: `NSScreen.main` `safeAreaInsets.top`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea` and record them next to the fixture in NotchGeometryTests.
- [ ] Hardware matrix: external display only (lid closed), mirrored display, a full-screen app, two Spaces, unplug the external display while expanded.
- [ ] VoiceOver: the panel reads "Agent status: ..." and every row and button is reachable; an approval announces.
- [ ] Click the empty corners of the compact capsule: clicks pass through to the menu bar.
- [ ] Notch style (Settings > On this device): the picker lists Liquid Glass, Dark glass, Solid black and Dock, each with a one-line explanation; the default on a fresh install is Liquid Glass; the choice survives a relaunch.
- [ ] Each style on the notch display: the resting wings stay black beside the hardware notch in every style; the expanded panel keeps a black band across the top and draws the chosen style below it. Dock on the notch display draws as Dark glass.
- [ ] Each style on an external display (pill at the top centre): the pill and the expanded panel draw the chosen style; Dock draws as Dark glass at the top.
- [ ] Side edges: drag to the bottom, left and right edges with each style. Dock shows the clear tinted slab there; the other styles keep their look; rows are readable over a bright and over a dark window.
- [ ] Light mode and dark mode with Liquid Glass: switch System Settings > Appearance while the panel is open; the text turns dark on light glass and white on dark glass, with no black ink on a dark surface and no white ink on light glass. Try Clear and Tinted glass.
- [ ] Dark glass, Solid black and Dock stay dark with white text when the Mac is in light mode.
- [ ] Approval row in every style over a white window and over a dark one: the command, the secondary lines and the "Couldn't send" line read clearly, and the Allow (amber) and Deny (pink) buttons show as filled shapes with legible labels, in light and dark Mac appearance.
- [ ] Reduce Transparency on (System Settings > Accessibility > Display), toggled while the panel is open: every style draws solid black with white text; off restores the chosen style.
- [ ] On macOS 14 or 15 (if available): the picker shows the note that glass needs macOS 26 and the notch is drawn Solid black.

## Home (D24)
- [ ] Home: the sidebar tab strip shows the six tabs with Home leftmost and Artifacts rightmost (Home, Sessions, Bots, Cron, Kanban, Artifacts). Since D26 the strip shows icons at every column width (names in tooltips and VoiceOver): drag the sidebar from its narrowest to its widest and check that it never clips or flickers. Ctrl-Cmd-1 is still Sessions, Ctrl-Cmd-5 is still Home and Ctrl-Cmd-6 is Artifacts (Artifacts is last in Go).
- [ ] Home layout: at a wide window the four tiles fill the row to the same right edge as Recent chats; Activity, Kanban and Cron are three equal-width, equal-height cards that start level and span the same width; at a medium window (about 640 pt) tiles go 2 x 2 and Cron spans the full width under Activity and Kanban; at the minimum the cards are one column; nothing clips (light and dark).
- [ ] Home, connected: header shows the dashboard label, the profile and "Connected"; New Chat, Quick Ask and Kanban work; New Chat is disabled exactly when the sidebar's is (Home is stricter: also disabled while disconnected).
- [ ] Home: start a turn that needs approval in another session: it appears under Needs you with the command text; clicking it opens that session in Sessions; a running turn appears under Working with its tool name.
- [ ] Home: recent chats list the eight newest; unread ones are bold with a dot; clicking opens the chat and returns the pane to Sessions; open with Return after Tab in the VoiceOver rotor.
- [ ] Home: Sessions, Unread, Waiting on you, Working tiles match the sidebar (Unread chip count, Needs input and Working chips); the Model and Context cards follow the open chat.
- [ ] Home: Kanban counts (total, blocked, per column) match the board the Kanban pane shows; switch dashboard and the old counts disappear at once; cron shows Active/Paused/Failing and a sensible Next run (record the real `next_run_at` format seen).
- [ ] Home, disconnected (turn off the network): "Offline", the banner, no Needs you/Working, the saved recent list still opens chats; reconnect and the sections return without reopening Home.
- [ ] Home in light and dark, Reduce Transparency on, and a 470 pt-wide window: no clipping, text readable, charts legible; VoiceOver reads each tile and chart as one element with its values.
- [ ] Home does not run while another pane is shown (Activity Monitor: no periodic Kanban requests after switching to Sessions).
- [ ] With a D21 session window key, Ctrl-Cmd-5 leaves the main window on its pane; a session window shows no Home tab.
- [ ] The Home strings in the 13 shipped languages are model-generated: have native speakers review them before a localized release.

## Artifacts (D26)
- [ ] Artifacts pane against a host whose notifier plugin offers `artifacts` (0.40+): the pane lists the profile's artifacts under day headings, pictures and videos as a 3-column grid with thumbnails, the rest as rows; the chips (All, Images, Pages, Files, Links) filter; scrolling to the end reads the next page; typing in the search pill filters after a short pause.
- [ ] Open: a picture or file downloads and Finder shows it selected (it carries the quarantine flag); a page opens in a sheet with a Done button that closes it; a page that is not UTF-8 text or is over the size limit is revealed in Finder instead; a link opens in the browser; a file the host no longer has shows the alert with its path; a very large file shows "Too large to open on this Mac".
- [ ] Right-click an item: Open, Show in Chat (the pane returns to Sessions, opens that chat and scrolls to the message), Copy Link (links) or Copy Path (files).
- [ ] More menu: Show Missing Files is off at first (missing files hidden; the request carries `missing=hide`); turn it on and the list reads again and missing files appear dimmed with a "Missing" badge on pictures; Refresh reads the list again.
- [ ] A host whose plugin is older: the pane shows "Update the Conduit plugin" and no spinner; update the plugin, return to the pane, and the list loads.
- [ ] Switch dashboard with the pane open: the old server's artifacts disappear at once. Light and dark, Reduce Transparency on, VoiceOver reads each tile as name, kind and chat.
- [ ] Chat > Artifacts... (no key): disabled with no chat open and in a new empty chat; with a chat open it shows a sheet titled Artifacts with that chat's items, padded 20 pt each side, same filters and More menu as the pane. Show in Chat closes the sheet and scrolls to the message. Esc and the close button dismiss it. Light and dark.

## Session windows (D21)
- [ ] Right-click a tab > Open in New Window: a window opens with that chat; the main window shows the neighbour tab.
- [ ] Option-Command-N with a chat active does the same; with a sheet open it does nothing.
- [ ] Send in the window while main streams another chat: both stream at once; neither shows the other's text.
- [ ] Stop in the window stops only that turn. Cmd-. with the window key stops only the window's turn.
- [ ] An approval in the window: Allow works; the main window is unaffected.
- [ ] Turn Wi-Fi off and on: the window says "Not connected", then catches up; no Stop button left over.
- [ ] Switch profile in main: the window says "Belongs to <profile>" and its composer is disabled; switch back: it resumes.
- [ ] Delete the chat from the sidebar: the window says "This conversation was deleted." and Close works.
- [ ] Open 4 windows; a fifth: beep, nothing opens; the tab menu item is disabled.
- [ ] Cmd-W in the window closes the window, not a main tab. Cmd-L focuses the window's composer and leaves main on its pane.
- [ ] Quit with a window open and relaunch: no session window comes back.
- [ ] Cmd-, and Cmd-Shift-D with a session window key: the main window comes forward and opens Settings / the Saved Dashboards sheet there (D22); the session window never shows the sheet.
- [ ] Close the main window with a session window open, then click the Dock icon: the main window comes back (and a second click does not open another). With the main window closed, Cmd-N, Cmd-, and Cmd-Shift-D from the session window bring it back.
- [ ] Bot Chat tab: right-click shows "Open in New Window" disabled, and Option-Command-N does nothing for it.
- [ ] The same session open in main and in a window: sending in one does not break the other; both show the reply after the turn.
- [ ] Assistant rows in the window show only the Copy button: no Quote, Branch, react or read-aloud controls. Copy puts the reply on the clipboard.
- [ ] Scroll a window up while its chat streams: the transcript stays where you scrolled; scroll to the end and it follows again; sending always jumps to the end.
- [ ] With a session window key: Ctrl-Cmd-1..4, Hide Sidebar and Cmd-F leave the main window as it was; Cmd-N brings main forward with a new chat.
- [ ] With a session window open, open a `conduit://` link from another app (Terminal: `open conduit://session/<id>`): the main window handles it; no extra empty session window appears.
- [ ] Disconnect mid-turn so the settle read fails: the window shows the error with Retry, Stop is gone, and Retry re-reads. Leave a chat idle for a long while (the gateway reaps its runtime), then send from the window: it sends after one transparent resume.
- [ ] Open a `conduit://session/...` or other in-app link from a chat inside the window: it follows the same link policy as main (an app link opens in main, other schemes go to the system or are dropped).

## Zoom (D27)
- [ ] View menu shows Actual Size (Cmd-0), Zoom In (Cmd-+) and Zoom Out (Cmd--). Cmd-= (no Shift), Cmd-Shift-= and the keypad + all zoom in.
- [ ] Zoom in to 150% with a chat open: the sidebar and the chat grow, text stays sharp, the toolbar and tabs keep their size, and the first message starts just under the toolbar (no gap, nothing under it). Zoom out to 75%: the same, smaller.
- [ ] While zoomed: scroll a long chat, select text in a reply, type in the composer, drag the sidebar edge, hover controls with Highlight Controls on Hover on: each works and lands where the pointer is.
- [ ] A zoom change keeps the typed draft and the focused field. A chat at its latest message stays at it (no jump-to-latest button); a chat scrolled up to older messages stays among them. The same in a session window.
- [ ] Home, Bots, Cron, Kanban and Artifacts panes zoom too. A session window follows the same level.
- [ ] At 200%, Zoom In beeps; at 75%, Zoom Out beeps. On a laptop screen Zoom In stops (beep) at the level where the window no longer fits. Cmd-0 returns to 100%. Quit and relaunch: the level is kept.

## Widgets (D25)

Install the exported app in /Applications (quit the running Conduit first), launch it, connect to a dashboard.

Before the widget pass, quit and remove every other Conduit.app copy (Debug builds, Xcode DerivedData, build/ archives or exports). Each one registers the `conduit://` scheme too and can steal a widget tap from the installed app.

- [ ] Edit Widgets lists Conduit with Native and Conduit-chan, medium only; add one of each to the desktop and one to Notification Center
- [ ] Before connecting (or signed out) the widget reads "Open Conduit"; after the app connects and loads sessions, the dashboard and profile labels and the last chat title appear within a few seconds
- [ ] Edit Widget: the Workspace and Conversation pickers list your dashboards and chats; picking a chat changes the title; Hide conversation title shows "Resume chat"
- [ ] Tap the title: the chat opens. Tap New Chat: a new chat opens. Tap Talk: a voice call starts (microphone prompt only the first time). Each from: Conduit frontmost, Conduit in the background, all windows closed (Cmd-W), and Conduit quit
- [ ] A tap while signed out or with the dashboard unreachable ends with a visible failure message, not a hang (30 s limit)
- [ ] Switch App Language in Settings: the widget copy follows
- [ ] Sign out / remove the dashboard: the widget falls back to "Open Conduit" or "Open Conduit to refresh"
- [ ] Update through Sparkle from the previous build: the widgets keep working without re-adding
- [ ] macOS 15 desktop with a tinted widget style: the mark and character render accented; on macOS 14 they render full colour
- [ ] With D21 session windows, a widget tap opens one chat once (not once per window)
- [ ] D21 interplay: with all primary windows closed and one session window open, a widget tap still routes once and opens the chat (a primary window is restored or the chat opens in the session window; no dead tap)
- [ ] D21 interplay: with the main window behind a session window, a widget tap brings the target chat to the front once
