# macOS smoke checklist

Run against a real Hermes dashboard before every release build.

- [ ] Log in with password; session list appears in the left column
- [ ] Log in with OAuth: browser opens, approve, app signs in; Cancel returns to login
- [ ] Open a session; history renders; long reply scrolls; scroll up during streaming stays put
- [ ] Send a message; reply streams; code block, math, Mermaid block render
- [ ] Select text in a reply across a line; Cmd-C copies; Cmd-F finds
- [ ] Paste a screenshot (Cmd-Shift-Ctrl-4 then Cmd-V): attaches as image
- [ ] Copy a PNG in Finder, paste: attaches as image; drag a PDF onto composer: attaches
- [ ] Return sends; Shift-Return newline; Japanese IME Return confirms without sending
- [ ] Approve a tool call inline
- [ ] Switch model and reasoning effort
- [ ] Cmd-N new chat; Cmd-. stops a running response; Cmd-Ctrl-S toggles the sidebar column
- [ ] Close window mid-stream, wait 30 s, click Dock icon: reply completed
- [ ] Admin tabs: Capabilities toggle, Jobs list, Connectors, Logs, Kanban board load
- [ ] Bot Mode: bot list loads; open a Bot Chat
- [ ] Switch between two saved dashboards

## Agent pre-checks (2026-10-13)

Debug build launched from DerivedData on the dev Mac. No logged-in item was exercised.

- R9 (a) app-group / "access data from other apps" consent prompt on first launch: PASS. Full-screen capture after launch showed the login screen only, no consent dialog.
- R9 (b) keychain / group-container errors in unified log: PASS (weak). The `log show` filter for process Conduit returned 0 lines in the window, so absence of errors is not strong evidence. E2E key save is UNVERIFIED (needs a logged-in session).
- (c) Logo clipping with no field focused: FAIL. The login form auto-focuses the username field at launch; the logo is clipped under the title bar in that state. Clicking empty window space did not defocus (SwiftUI keeps focus), so a truly unfocused state was not reachable. Focusing the password field scrolls the title and subtitle further under the title bar. Cause is focus-scroll in the login ScrollView; needs a Plan 2 or login-layout fix.
- (d) Dock reopen after Cmd-W: UNVERIFIED. An unintended "Connection Setup / Test connection" sheet was open (see Incident), so Cmd-W did not close the window. Process stayed running; reopen not tested.
- (e) App icon: FAIL (static check). AppIcon.icns is full-bleed square art with no macOS squircle mask or padding. Dock rendering not captured because the Dock is set to auto-hide.
- (f) Cmd-Ctrl-S sidebar toggle: UNVERIFIED (not applicable at the login screen).

### Incident

During check (c) a single AX click on empty window space plus app activation was followed by the login form showing an autofilled password field and a failed login / "Test connection" attempt ("Hermes rejected that username or password"). The agent typed nothing and sent no Return. The trigger is unknown (likely password-manager autofill plus an app-side auto-test). One or two failed auth attempts hit the dashboard. All UI driving was stopped and the app was quit. Worth checking whether LoginView auto-submits or auto-tests after an external autofill.
