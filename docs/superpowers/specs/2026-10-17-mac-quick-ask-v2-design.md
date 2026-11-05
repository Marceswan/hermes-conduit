# Mac Quick Ask v2: design

Date: 2026-10-17. Status: draft for review (not yet approved). Target: the macOS app only (`ConduitMac`). iOS is unchanged. Builds on D15 (docs/superpowers/specs/2026-10-15-mac-quick-ask-design.md, docs/macos/DECISIONS.md D15).

## Intent

Quick Ask v1 answers a typed question from any app. v2 makes it useful for the questions people actually ask from another app: "what is this file / screenshot", "ask this with a faster or stronger model", and "what did it tell me ten minutes ago". Three parts, each shippable on its own, in this order:

1. Attachments: drop a file or screenshot on the panel, paste an image, or pick a file.
2. Model picker: choose the model Quick Ask uses.
3. Panel history: recent Quick Ask exchanges in the panel, readable and continuable.

The user skipped the question round, so every product choice below that is not in D15 is the designer's call and is marked "(call)". Change any of them at review.

## Goals

- A screenshot or file reaches Hermes from the panel with no trip to the main window.
- The same attachment rules as the main composer: size limit preference, count cap, JPEG re-encode, folder expansion, package refusal. One set of rules, not a second copy that drifts.
- The model choice is visible before sending and survives relaunch.
- A past Quick Ask answer can be found again in the panel in two keystrokes.

## Non-goals

- Window capture from inside the panel (D17 Ask About Window stays a main-window feature). Cmd-Shift-4, then a drag of the floating thumbnail onto the panel, covers it (see "Panel hold").
- Reasoning effort, fast mode and yolo controls in the panel.
- Slash commands, dictation, approvals inside the panel (unchanged from D15).
- Server-side search of Quick Ask sessions; history is local.

## Anti-goals (a failure even if it works)

- The panel vanishes while the user drags a file to it.
- A dropped file is sent before the user presses Return.
- The panel changes the main window's chat, draft, model or attachments.
- History shows another profile's or dashboard's exchanges.

## Constraints

- D15 holds: the panel is a non-activating `MacFloatingPanel`; Quick Ask drives its own session through `appState.client` and `MacStreamEventHub`; AppState and the open chat are untouched.
- Porting rules (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`; upstream edits gated `#if os(macOS)`, tagged `// MAC:`, one ledger row each. Target for this spec: zero upstream edits (see "Reuse").
- Strings through `AppLocalization.string`, catalogued in `Conduit/Localizable.xcstrings` in all 13 shipped languages (`scripts/check-l10n-coverage.py`); model translations flagged for native-speaker review, as in D21 to D24.
- Gateway-controlled text in panel chrome (model labels, error text, file references echoed back) passes through `MacUntrustedText.sanitize`. The reply body renders as Markdown, as in v1.

## Reuse (existing code this builds on)

- Attachment model: `Attachment` (`Conduit/Models/Models.swift:85`; `id`, `name`, `uri` file URL string, `mimeType`, `kind` image / video / document).
- Staging rules: `AttachmentStaging.finishStaging(fileAt:name:type:limitMegabytes:)`, `stageScreenshot(data:filename:limitMegabytes:)`, `destination(for:)`, `sweepStaleFiles` (`Conduit/Views/Components/ComposerAttachments.swift`). Size limit: `AttachmentSizeLimit` (preference `conduit.attachmentSizeLimitMB`, default 16 MB). Type rules: `AttachmentTypePolicy`. Count cap: `ComposerBar.photoPickerSelectionLimit` (10).
- Drop rules: `MacAttachmentDropPolicy.payload(from:)`, `expand(_:existingCount:cap:)` and `MacAttachmentDropRouter.route` (`ConduitMac/Chat/ChatAttachmentDrop.swift`): file URLs win over bitmaps, folders expand to top-level regular files, packages are refused, overflow is reported once.
- Paste rules: `ComposerTextView.pasteDecision(for:)` and `pastedImages(from:)` (`ConduitMac/Chat/ComposerPasteTextView.swift`); `PastedImage { data, typeIdentifier }`.
- Upload RPCs (`Conduit/Services/HermesClient.swift`): `attachImage(_:base64:filename:)` (`image.attach_bytes`), `attachFile(_:dataUrl:name:path:)` (`file.attach`, 120 s timeout, returns an `@file:` reference). Helpers: `AttachmentHelper.toBase64`, `toDataUrl`, `dataUrl(base64:for:)`; `AppState.isImageAttachRefusal(_:)` (4016 / 4018) and `AppState.promptText(_:fileReferences:)`, both `nonisolated static`.
- Model RPCs: `modelOptions(sessionId:)` (`model.options`, returns providers with `ModelInfo { id, label, reasoningCapable }`), `setModel(_:model:provider:confirmed:)` (`config.set ... --session`, returns `ModelSwitchOutcome { model, confirmRequired, confirmMessage, deferred }`), `createSession(model:provider:reasoningEffort:fast:cwd:inProfile:)`. Hidden providers and models: `appState.modelVisibility` (per dashboard, see Part 2).
- Resume: `client.openSession(_:profile:) -> SessionResumeResult` (`session.resume`).
- On-disk precedent for transcript text: `OfflineChatCacheStore` (`Conduit/Services/OfflineChatCache.swift`) already keeps chat transcripts on this Mac.

The main composer's upload loop lives inside `AppState.sendMessage` and acts on the active session only, so Quick Ask cannot call it. Quick Ask gets a Mac-owned `MacAttachmentUploader` that applies the same rules through the same client calls and helpers (see Part 1). A parity test pins the rules to the main path's; no upstream refactor.

## Part 1: Attachments

### Behaviour

- **Ways in.**
  - Drop files, folders or images on the panel. Same rules as a drop on the main chat pane (`MacAttachmentDropPolicy`): file URLs win over bitmaps, a folder adds its top-level files, a package (.app, .rtfd) is refused by name, over 10 shows "Too many files to attach at once. Only the first ones were added." While a drag that would be accepted is over the panel, the panel shows the same dashed "Drop to attach" overlay as the chat pane.
  - Paste with Cmd-V while the field is focused: an image (or an image file URL) on the clipboard is attached; text pastes as text. The decision is `ComposerTextView.pasteDecision(for:)`, so the panel and the main composer agree. A non-image file copied in Finder pastes as its name, as in the main composer today (parity; changing that is a separate fix for both).
  - (call) No file-picker button in v2. A file dialog needs Conduit to be the active app; activating Conduit raises its main window and, with the default "switch to a Space with open windows" setting, can move the user to another Space, away from the app they are asking about. Drop and paste are what was asked for. The empty panel shows a one-line hint under the field when nothing is staged: "Drop files or paste an image to attach." A picker that works without activation (for example an open panel as a sheet on the Quick Ask panel) is "Later".
- **Strip.** Staged attachments show as chips in one row above the field: thumbnail (image) or file symbol (`AttachmentTypePolicy.symbolName`), name, detail label (`AttachmentTypePolicy.detailLabel`, e.g. "PDF . 2 MB"), and a remove button. The row scrolls horizontally past 4 chips. Removing a chip deletes its staged file. Each chip has an accessibility label "<name>, <detail>" and the remove button "Remove <name>".
- **Limits.** Size: the `AttachmentSizeLimit` preference, checked before decode and after any re-encode (`finishStaging`); a refused file shows `AttachmentSizeLimit.tooLargeMessage` inline. Count: 10 per message, shared across drop, paste and the button. Images other than JPEG, PNG, GIF and WebP are re-encoded to JPEG (`finishStaging`).
- **Sending.** Return sends when the field holds text. (call) An attachment-only send is refused: the placeholder changes from "Ask Hermes" to "Ask about the attached files" when chips are present, and Return with an empty field does nothing. The prompt text is required because image uploads add no reference to the prompt, so an image-only send would be an empty `prompt.submit`.
- **Upload.** After `session.create` (first turn) or straight away (follow-up), each attachment is uploaded in strip order, then the prompt is sent:
  - image: `attachImage` with base64; a 4016 / 4018 refusal re-sends it as a file through `attachFile` (data URL);
  - video and document: `attachFile` with a data URL;
  - every returned `@file:` reference goes ahead of the typed text through `AppState.promptText(_:fileReferences:)`.
  The status line reads "Uploading 2 of 3" while this runs. Encoding runs off the main actor (a 16 MB file is about 21 MB of base64).
- **Stop during upload.** Cmd-. cancels the upload task; nothing was submitted, so no `session.interrupt` is sent. Files already uploaded stay on the gateway (harmless; the main composer has the same property).
- **Failure.** Any upload error moves to `.failed` with "Attachment failed: <reason>" (the main composer's wording), keeps the typed text and the chips for Retry. Retry uploads every attachment again (call: simple and matches the main composer's restore-the-draft behaviour; a duplicate queued image on the gateway is possible and accepted).
- **After send.** The chips leave the strip and appear, as names only, in a single caption line above that turn's reply ("Sent with photo.png, report.pdf"). The staged files stay until the launch sweep (`sweepStaleFiles`, 3 days), as the main composer's do.
- **Promotion.** Cmd-Return with unsent chips: the chips stay in the panel (they belong to the panel's draft, like the typed text). Promotion moves only the session.
- **Reset.** Cmd-N and the 120 s restore expiry clear the chips and delete their staged files.

### Panel hold (the drag problem)

Dragging a file from Finder starts with a click in Finder. That click makes Finder's window key, the panel resigns key, and D15's `dismissOnResignKey` hides it before the drag arrives. v2 rule:

- `MacFloatingPanelConfig` gains `holdWhileMouseDownElsewhere: Bool` (Quick Ask true, notch status false).
- On resign key, if the left mouse button is down (`NSEvent.pressedMouseButtons & 1 != 0`), the hide is deferred. The controller polls the button state every 100 ms (a timer; no global event monitor, so no permission). When the button is released it waits a further 300 ms grace (`pressedMouseButtons` reads hardware state, so the release can be seen before `performDragOperation` reaches the panel), then:
  - if a drop landed on the panel during the hold or the grace, the panel stays, becomes key again (`makeKey`, which does not activate Conduit on a non-activating panel) and refocuses the field;
  - otherwise it hides, as in D15.
- A hold ends after 120 s at most (a stuck button state must not keep the panel up forever).
- Cmd-Tab or any resign key with no button down hides at once, as in D15.
- A plain click in another app now hides the panel about 400 ms after mouse up instead of at mouse down. Accepted.
- The global hotkey also works mid-drag: start the drag, press Option-Shift-Space, drop. No extra code; listed for the smoke pass.

### Components

- `ConduitMac/QuickAsk/MacQuickAskAttachments.swift`: `MacQuickAskAttachmentStrip` value (ordered `[Attachment]`, cap, add results, remove deletes the staged file), pure apart from file deletion through an injected closure.
- `ConduitMac/Chat/MacAttachmentStager.swift` (call: zero upstream edits wins over sharing the glue). The composer's staging glue (`stageDocument`, `addAttachment`, `handleDocumentSelection`, `reportImportProblems` in `ComposerBar.swift` lines 1853 to 1977) is `private` view code that writes the composer's own `@State`, so Mac code cannot call it. The RULES are already shared and stay shared: size, sniffing, JPEG re-encode and naming are all in `AttachmentStaging.finishStaging` and `AttachmentTypePolicy`. Only the thin glue is copied: copy a file to `AttachmentStaging.destination(for:)` then `finishStaging`; write pasted bytes then `finishStaging`; build the error text from `AttachmentSizeLimit.tooLargeMessage` and the composer's failed-import string (same catalog key, so no new translation). A parity test stages the same inputs through the stager and checks the results match what `finishStaging` gives the composer. Copying, decoding and re-encoding run off the main actor.
- `ConduitMac/QuickAsk/MacAttachmentUploader.swift`: `struct MacAttachmentUploader` with injected `attachImage` / `attachFile` closures; `func upload(_ attachments: [Attachment], to sessionID: String, progress: (Int, Int) -> Void) async throws -> [String]` (file references). Rule order identical to `AppState.sendMessage`. Lives in `ConduitMac/` so the share work (separate spec) can reuse it later if needed.
- `MacQuickAskModel`: new state `.uploading(done: Int, total: Int)` between `.creating` and `.sending`; `canSubmit` unchanged (idle, done, failed); events are still accepted only in sending, streaming and done. `submit` takes the attachment names for the caption.
- `MacQuickAskController`: `attachments` published; `add(_ payload: MacAttachmentDropPayload)`, `remove(_ id:)`; `run(prompt:)` uploads between create and `sendPrompt`. New environment closures `attachImage` and `attachFile` bound to `appState.client` in `bind(to:)`.
- `MacQuickAskView`: strip, hint line, drop target and overlay. `MacAttachmentDropDelegate` and `MacAttachmentDropOverlay` are `private` in `ChatAttachmentDrop.swift` (lines 184 and 225); that file is Mac-owned, so they become `internal` and are reused with a `MacAttachmentDropSink` the panel owns (no ledger row).
- Field editor (drops and paste on the field): the field is a SwiftUI `TextField`; while it is focused (always, in the panel) its field editor is an `NSTextView` that takes file drags itself and inserts the path as text, as the main composer had to prevent (`sinkOwnsDrag`, `ComposerPasteTextView.swift:357`). `MacFloatingPanel` overrides `fieldEditor(_:for:)` to return one `MacQuickAskFieldEditor: NSTextView` that (a) forwards file and image drags to the panel's sink, like `sinkOwnsDrag`, and (b) overrides `paste(_:)`: when `pasteDecision(for: .general)` is `.images` it hands them to the sink's image path and inserts nothing, else `super`. IME composition and the v1 focus workaround are unaffected because the field stays a `TextField`. If the override does not take for SwiftUI's field, the fallback is an `NSTextView`-backed field (larger change: re-verify IME and the D15 focus workaround).
- `MacFloatingPanelController`: the hold rule.
- Panel height: `MacQuickAskPanelConfig.maxHeight` goes from 480 to 600 and the reply area cap from 340 to 320 pt. The v1 worst case is already about 470 pt; the chip row (about 50 pt) and the always-visible footer would clip at 480. Rule: field, chips, status and footer never clip; the reply area takes what remains under the cap. The placement still clamps the panel to the screen's visible frame.

### Testing

- Strip: cap 10 across sources, overflow message once, remove deletes the staged file, reset deletes all.
- Uploader parity (fakes): image -> `attachImage`; 4016 and 4018 -> `attachFile` with a data URL; other errors propagate; document and video -> `attachFile`; references kept in strip order; a nil reference is skipped; order of calls matches `AppState.sendMessage` on the same input (test fixture shared with the main path's existing tests where they exist).
- Model: `.creating -> .uploading -> .sending -> .streaming`; Stop during upload ends in `.done` or `.idle` with nothing submitted (pick one and pin it); upload failure keeps prompt and chips.
- Controller: attachment-only Return does nothing; follow-up with attachments uploads to the existing session without a second create; Retry re-uploads.
- Hold rule (hosted panel, injected button-state and clock): resign key with button up hides at once; with button down defers; release without drop hides after the grace; a drop that arrives inside the grace keeps the panel and makes it key; 120 s cap hides.
- Paste (through the field editor): image clipboard attaches and inserts no text; text clipboard pastes text; image-file-URL clipboard attaches.
- Drop: hosted drop on the panel and on the focused field with a file URL, a folder, a package and 12 files; the field never receives a path as text.
- Stager parity: same inputs through `MacAttachmentStager` and through `finishStaging` give the same names, types, kinds and refusals.
- Height: with 10 chips, a 5,000-line reply and the footer, the field and footer are fully inside the panel.
- Accessibility labels on chips and buttons (`AccessibilityLabelAuditTests` pattern).
- Manual (SMOKE_CHECKLIST): drag a PDF from Finder to the panel and to the field; Cmd-Shift-4 then drag the thumbnail; Cmd-Ctrl-Shift-4 then Cmd-V; Japanese IME in the field still composes; 16 MB limit message; hotkey mid-drag.

## Part 2: Model picker

### Behaviour

- A compact menu in the panel footer, always visible (v1 shows the footer only once a session exists). Label: the chosen model's label, or "Default model" when none is chosen. (call) "Default model" means the profile default, as in v1: `session.create` with no model.
- Items: "Default model" (checked when nothing is chosen), a divider, then the models from `modelOptions(sessionId: nil)` grouped by provider (section headers), minus what the main model picker hides: hidden providers and hidden models in the live `appState.modelVisibility` (per dashboard; stored under `conduit.modelVisibilityByDashboard.v1`, not the legacy `conduit.modelVisibility.v1`). The hidden-model key (`provider` + U+001F + `model`) is built by a `private` helper in `ModelPickerView.swift`, so the Mac filter mirrors that format and a parity test builds a `ModelVisibility` through its public mutators and checks the Mac filter hides exactly what the picker hides. Labels pass through `MacUntrustedText.sanitize` (cap 60 graphemes).
- Loading: fetched the first time the panel opens in a scope (dashboard + profile), cached in the controller, refreshed on scope change and on `show()` when the cache is older than 5 minutes (a SwiftUI `Menu` has no open callback). While loading or after a failure the menu shows "Default model" and a disabled "Couldn't load models" row.
- Persistence: one choice per scope, `conduit.mac.quickAsk.model.<dashboardKey>.<percent-encoded profile>` holding provider and model id (dashboardKey is the dashboard UUID or `none`, as D19). A saved model missing from a freshly loaded list falls back to "Default model" and the key is cleared.
- Effect on a new exchange: `createSession(model:provider:inProfile: nil)` with the chosen pair (provider sent only with a model, as `createSession` already does).
- Effect during an exchange (a session exists): (call) picking a model applies to this session and becomes the saved choice. The controller calls `setModel(id, model:, provider:)`:
  - "Default model" picked mid-exchange: `config.set` has no "unset", so (call) the controller resolves the profile default from the top-level `model` and `provider` that `modelOptions` returns and calls `setModel` with them; if that pair is missing, only the saved choice is cleared and the row says "Applies to your next Quick Ask." (the session keeps its model).
  - `confirmRequired`: an inline row shows `confirmMessage` (sanitized) with "Use This Model" and "Cancel"; confirm calls `setModel(..., confirmed: true)`; cancel keeps the old model and the old saved choice.
  - `deferred`: the row says "Applies from your next message."
  - error: inline message; the choice is not saved.
- Disabled while a turn runs or uploads.
- Not touched: the main window's `runtime`, its model picker, `voiceJob*` settings.

### Open point for the builder (spike, 0.5 day)

Whether `session.create` with an expensive model needs the same confirmation `config.set` asks for is unknown (`createSession` has no confirm parameter). Test against a live gateway. If the create refuses, create with the default model and then run the `setModel` confirm flow before the first prompt.

### Components

- `ConduitMac/QuickAsk/MacQuickAskModelChoice.swift`: `struct MacQuickAskModelChoice: Codable, Equatable { provider, model, label }`, a per-scope store over `UserDefaults` (injected), and a pure menu builder from `[ProviderInfo]` plus the visibility filter.
- Controller: `modelChoice` and `modelMenu` published; environment closures `modelOptions`, `setModel`, `scopeKey`, `isModelHidden`.
- View: `Menu` in the footer with `.menuStyle(.button)` and `.buttonStyle(.plain)` (the composer chip style, so the label is not flattened).

### Testing

- Menu builder: grouping, hidden models removed, sanitized labels, default row checked.
- Store: per-scope keys, round trip, stale model cleared after a list load.
- Controller: create passes the choice; default passes nil; mid-exchange pick calls `setModel` once; confirm path, cancel path, deferred note, error leaves the saved choice unchanged; picker disabled while running.
- Manual: switch profile and see that profile's choice; an expensive model's confirm text.

## Part 3: Panel history

### Behaviour

- **What is kept.** (call) The last 30 Quick Ask exchanges per scope (dashboard + profile). An exchange is one Quick Ask session: its runtime and stored ids, created and updated dates, the model label used, and up to its last 10 turns. A turn is the prompt (capped at 2,000 characters), the attachment names, and the final reply text (capped at 20,000 characters, with "[truncated]" past the cap). Partial replies of failed or interrupted turns are kept, marked.
- **Where.** A JSON file per scope under the app's Application Support folder, next to the offline chat cache (`QuickAskHistory/<scope hash>.json`, written atomically, debounced 1 s, written when a turn ends). Not UserDefaults (size).
- **Privacy.** The Chat menu gets "Keep Quick Ask History" (Toggle, `conduit.mac.quickAsk.history.enabled`, default on (call): the app already keeps transcripts on disk in the offline chat cache) and "Clear Quick Ask History" (deletes every scope's file). Turning keeping off deletes all files and stops writing. Removing a saved dashboard deletes its scope files when the dashboard registry change is observable from Mac code; otherwise they stay until "Clear" (builder checks; note it in D26).
- **Open the list.** Cmd-Y or a clock button in the footer toggles the history list in place of the reply area. Rows: title (the first prompt, one line), relative date, first line of the last reply (secondary). (call) Opening the list moves keyboard focus from the field to the list; whatever is typed in the field stays there untouched. In the list, Up and Down move the selection, Return opens the selected row, Delete (Backspace) removes it, Esc closes the list and returns focus to the field (a second Esc hides the panel). Return never sends while the list has focus, and Delete never edits the field. The field does not filter the list (call: one job per control; 30 rows need no search).
- **Open an exchange.** The panel shows its turns read-only, oldest first, in the scrolling reply area: prompt in bold, caption of attachment names, reply as Markdown. The placeholder reads "Ask a follow-up". A draft typed before opening stays in the field and becomes the follow-up.
- **One session at a time.** (call) The model stays single-session (one `runtimeID` / `storedID`, `MacQuickAskModel.swift:36`). While the live exchange has a turn running (creating, uploading, sending or streaming, shown or hidden), another entry opens read-only and its Continue is disabled with "Wait for the current answer to finish."; the live session stays the one the hub follows, so its reply still finishes and is recorded. Once that turn ends (and is recorded), opening another entry adopts it and the previous exchange is only in history. This keeps the 120 s restore rule intact and avoids a per-session tracker.
- **Continue.** Return with text sends a follow-up into that session:
  - if Quick Ask already holds the session's runtime id (the live exchange), send as today;
  - otherwise resume it first with `client.openSession(storedID ?? runtimeID, profile: nil)` and adopt the returned ids into the model (as `sessionCreated`), then upload and send. The hub subscription starts at adoption.
  - Resume failure (deleted, other workspace, not owned): "That chat is no longer available." (the existing string) and the exchange stays read-only, with "Remove from History" offered.
- **Open in Conduit** (Cmd-Return) on a history exchange promotes it like a live one: `requestOpenSession` with the stored id.
- **The live exchange is history too.** The current exchange is the first row; the 120 s restore rule from D15 is unchanged and still decides what a fresh open shows.
- **The panel shows every turn of the current exchange** (v1 showed only the latest turn), oldest first, auto-scrolled to the newest, inside the 320 pt reply cap (see "Panel height").

### Open point for the builder

Resuming through `client.openSession` from outside `AppState` must not disturb the main window. AppState drops events for non-active sessions (D15), and the Voice background supervisor drives sessions the same way, but check two things with a hosted test or a live gateway: the resume response is not applied to AppState's active chat, and resuming a session that the main window has open is safe (a later promote must still work). If either fails, v2 ships history as read-only plus Open in Conduit, and Continue waits.

### Components

- `ConduitMac/QuickAsk/MacQuickAskHistory.swift`: `MacQuickAskHistoryEntry` and `Turn` (Codable values, caps applied at the boundary), `MacQuickAskHistoryStore` (file IO behind a protocol, scope keyed, 30-entry and 10-turn caps, newest first, upsert by session id, delete, clear all).
- `MacQuickAskModel`: `priorTurns: [Turn]` for display; `adopt(runtimeID:storedID:priorTurns:)` for a resumed exchange.
- Controller: records turns on turn end; `showHistory`, `openHistoryEntry(_:)`, `removeHistoryEntry(_:)`; environment closure `resumeSession`.
- View: list mode, read-only turns, keyboard handling (`onKeyPress` on the panel, as the palette does, D18).
- `ConduitCommands.swift`: the Toggle and the Clear item.

### Testing

- Store: caps (30, 10, character caps with "[truncated]"), upsert by either id, scope isolation, clear all, keep-off deletes, corrupt file reads as empty and is replaced.
- Controller: turn end records once; follow-up on a live exchange does not resume; on a stored exchange resumes once then sends; resume failure shows the message and sends nothing; promote from history.
- View: Cmd-Y toggles and moves focus to the list; arrows move, Return opens, Delete removes, Esc closes the list then hides; a typed draft survives open and close of the list; Return in the list never sends.
- Controller: opening another entry while the live turn runs is read-only and the live turn's reply is still recorded; after the turn ends, opening adopts the other session.
- Manual: ask, Esc, wait 3 minutes, Cmd-Y, continue the old exchange; switch profile and see only that profile's history; relaunch keeps history; "Clear Quick Ask History" empties it.

## Error handling summary

| Case | Panel shows | Kept |
|---|---|---|
| File over the size limit | `tooLargeMessage` inline | other chips |
| More than 10 | the too-many message once | first 10 |
| Package dropped | the main composer's failed-import wording (`ComposerBar.reportImportProblems(oversized:failed:...)` with the package names; reuse its strings, add none) | other chips |
| Upload fails | "Attachment failed: <reason>", Retry | prompt and chips |
| Model list fails | "Couldn't load models" (disabled row) | default model works |
| Model switch needs confirm | confirm row | old model until confirmed |
| Resume fails | "That chat is no longer available." | entry, read-only |
| Not connected | v1 strip; chips can still be added; Return disabled | everything |

## Docs

New D26 in docs/macos/DECISIONS.md (hold rule with its grace, field editor for drops and paste, no picker button, stager and uploader parity rules, panel height 600, attachment-only send refused, model choice per scope and mid-exchange behaviour, history store and privacy defaults, the two spike results). D15's "out of scope" list is updated by D26, not edited in place. SMOKE_CHECKLIST "Quick Ask" section gains the manual lines above. No PORTING_LEDGER row expected (zero upstream edits); if the builder needs one, it gets a row.

## Later (not in this spec)

- A file-picker button that does not activate Conduit (for example an open panel as a sheet on the Quick Ask panel).
- Window capture from the panel.
- Sharing from other apps straight into the panel (see the Share to Hermes spec, "Later").

## Left to the builder

- Exact chip and list visuals within the existing glass rules (one glass layer, D7) and the 640 pt panel width.
- The paste interception point, as long as the paste contract holds.
- Timer versus run-loop observer for the hold poll.
- Whether the uploader encodes on a detached task or an actor.

## Effort

About 7 working days (my earlier "2 to 3 days" was too low once history that resumes sessions was included):

- Part 1 attachments: 3 days (hold rule 0.5, field editor drops and paste 0.75, stager and strip 0.75, uploader and state 0.5, tests 0.5).
- Part 2 model picker: 1.5 days (including the 0.5-day create-confirm spike).
- Part 3 history: 2 days (store 0.5, list and read-only view 0.75, resume and continue 0.5, tests 0.25).
- Docs, smoke, review fixes: 0.5 day.

Cheaper cut if wanted: history as read-only plus Open in Conduit (no Continue) saves about 0.75 day and removes the resume open point.
