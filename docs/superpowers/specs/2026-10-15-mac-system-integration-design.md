# Mac system integration: design

Date: 2026-10-15. Status: draft for review. Target: the macOS app only (`ConduitMac`). iOS is unchanged. Three parts, each independently shippable, in this order: Services, Shortcuts, Spotlight.

## Goal

Make Conduit reachable from the rest of macOS: send selected text to a new chat from any app (Services), run Conduit actions from Shortcuts/Siri/Spotlight actions (App Intents), and find past chats in Spotlight (Core Spotlight).

## Constraints

- Porting rules apply (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`, upstream edits gated `#if os(macOS)`, tagged `// MAC:`, one ledger row each. Prefer zero edits to `AppState.swift`; every hook below uses existing public API.
- One shared `AppState`, one gateway connection. Nothing here runs a second connection or a background daemon.
- Developer ID build, hardened runtime, not sandboxed (confirm in `ConduitMac.entitlements`). Services and Core Spotlight need no entitlement.
- Platform facts are from Apple documentation as known at writing and must be re-verified against the current docs while implementing (marked "verify"): the live docs were not reachable during this draft.

## Existing code this builds on

- `ConduitMac/Resources/Info.plist`: no `NSServices` key today.
- `ConduitMacAppDelegate` (`applicationDidFinishLaunching`) is the place to set `NSApp.servicesProvider`.
- `ConduitMacApp.swift` `.onOpenURL`: `routeWidgetLaunchURL`, then `ConduitAppLink(externalURL:)` into `pendingExternalLink`, drained by a `.task` once `appState.isConnected`, then `appState.openAppLink(link)`. `ConduitAppLink` (Conduit/Services/ConduitAppLink.swift) has `.session(id:profile:)`, `.bot`, `.settings`.
- `AppState.prefillComposer(_:)` sets `composerPrefillText` plus a token keyed to the active session's draft. `AppState.createNewSession(cwd:widgetLease:)` guards on `isConnected`, not switching, not connecting. `AppState.requestOpenSession(_:onFailure:)`, `deleteSession(_:)`, `loadSessions(forceRefresh:)`, `@Published sessions`, `activeProfileSessions`, `activeProfile`, `switchProfile(to:)`.
- `SessionSummary` (Conduit/Models/Models.swift): `id`, `alternateIds`, `title`, `lastActivityAt`, `messageCount`, `profile`, `source`, `isArchived`. It carries no last-message text (see Part 2).
- Intents (Conduit/Intents/): `StartVoiceConversationIntent` (+ `ConduitVoiceShortcuts: AppShortcutsProvider`, `SiriProfileShortcuts`, `ConduitProfileEntity`), `AskHermesAboutScreenIntent`. Both already carry `@available(iOS 26.0, macOS 26.0, *) // MAC:` on `supportedModes` (ledger R4). Both hand off through `PendingVoiceIntentStore.shared.enqueue(...)`, drained by the voice-intent task in `ConduitMacApp`.

## Part 1: Send to Hermes (Services menu)

### Behaviour

- Selecting text in any app and choosing Conduit > Send to Hermes (app menu > Services, or the context menu) opens Conduit and starts a new chat with the text in the composer.
- Prefill, not send. Reasons: selections are often partial, may hold secrets, and a Service fires from other apps with no confirmation; sending would put unreviewed text on a remote agent and start a billed turn. The user presses Return. (No "send immediately" variant in v1; see open question 1.)
- Always a new chat (not the active one), so a draft or running turn in the active chat is never touched. The text is plain text only; rich text is flattened. Cap at 20,000 characters; longer input is truncated with a trailing note "[truncated]".
- Not connected yet (cold launch via Service): the request is parked and applied once `appState.isConnected`, same pattern as `pendingExternalLink`. If connection never comes, the app is foreground and the existing connection UI shows; the parked text is dropped on a profile or dashboard switch.
- Multiple Services calls before the first applies: last one wins.
- Menu title "Send to Hermes". No key equivalent in v1 (collides with host apps).

### Architecture

- `ConduitMac/Resources/Info.plist` additions (verify keys in Apple's "Services Implementation Guide" / Cocoa Info.plist keys reference):
  `NSServices` array with one dict: `NSMenuItem` = dict `default` = "Send to Hermes"; `NSMessage` = `sendToHermes` (the selector name without the trailing colon and arguments); `NSPortName` = the app's bundle name (`Conduit`); `NSSendTypes` = array `NSStringPboardType` (and `public.utf8-plain-text`, verify which the OS still honours; keep both); no `NSReturnTypes` (nothing is returned). Optional `NSRequiredContext` is not used.
- `ConduitMac/App/MacServicesProvider.swift` (new): `final class MacServicesProvider: NSObject` with `@objc func sendToHermes(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>)`. Reads `pboard.string(forType: .string)`, trims, rejects empty with `error.pointee = "No text selected"`, then posts to a main-actor sink.
- `ConduitMacAppDelegate.applicationDidFinishLaunching`: `NSApp.servicesProvider = servicesProvider` (strong reference held by the delegate). Also `NSUpdateDynamicServices()` is not called in production; it is a dev aid.
- Hand-off: a small `MacServiceInbox` (ObservableObject, main actor, Mac-only) holds `pendingText: String?`. `ConduitMacApp` adds a `.task(id: serviceRouteKey)` next to the `pendingExternalLink` task: when `appState.isConnected` and `pendingText != nil`, `await appState.createNewSession()` then `appState.prefillComposer(text)`, and activates the app (`NSApp.activate`), un-minimises the main window. `prefillComposer` keys the draft on `activeSessionId`, so it must run after the new session is active; the task checks `appState.activeSessionId` changed before prefilling (verify against `composerPrefillDraftKey` behaviour).
- No upstream edits expected. If `createNewSession` cannot be awaited to completion from outside (it returns Void), poll `activeSessionId` change with a 3 s timeout, else fall back to prefilling the current chat; this is the only place a gate in AppState might be needed (ledger row if so).
- Rejected: URL scheme `conduit://compose?text=` (logs the text in URL handlers, length limits, any app could trigger it), and a Share extension (needs a separate extension target; Services is enough for text on Mac).

### Testing

- Unit: provider extracts string, trims, truncates at cap, rejects empty and non-string pasteboards (use a private `NSPasteboard(name:)`).
- Unit: inbox last-write-wins; dropped on profile switch; not applied while disconnected, applied once on connect, applied exactly once.
- Info.plist test: plist decodes with `NSServices[0].NSMessage == "sendToHermes"` and the provider responds to that selector (guards rename drift).
- Manual (SMOKE_CHECKLIST): `/System/Library/CoreServices/pbs -flush`, select text in TextEdit and Safari, run the Service with Conduit closed, connected, and mid-turn; check System Settings > Keyboard > Keyboard Shortcuts > Services lists the item and its toggle works.

## Part 2: Spotlight indexing of sessions

### Behaviour

- Each chat of the active profile appears in Spotlight with: title, a snippet, and the last-activity date. Selecting a result opens Conduit on that session (through the same route as a `conduit://session/<id>` link, switching profile if needed).
- Snippet: `SessionSummary` has no last-message text and the catalog loads in pages, so v1 indexes title + model + "N messages" + date as `contentDescription`, not message bodies. Indexing real last-message text needs a per-session fetch and is deferred (open question 2); privacy-wise it is also the riskier half.
- Privacy: Settings > Privacy toggle "Show chats in Spotlight", default OFF (decision for review, open question 3). Turning it off calls `deleteAllSearchableItems` for Conduit's index and stops indexing. Titles can contain sensitive text, hence opt-in.
- Deindex: on `deleteSession` success, on archive, on profile switch (the outgoing profile's items go; the incoming profile's are indexed from its catalog), on dashboard switch or sign-out, and on toggle off. Bot chats and cron sessions are not indexed.
- Only sessions already in the loaded catalog are indexed; it is a best-effort mirror, not a full history. Older pages are indexed as they load.
- Results survive relaunch (Core Spotlight persists them); a stale result for a deleted session opens the app and shows the existing "That chat is no longer available." message via `openAppLink`.

### Architecture

- `ConduitMac/Spotlight/MacSpotlightIndexer.swift` (new, `import CoreSpotlight`, `UniformTypeIdentifiers`):
  - Pure mapper `MacSpotlightItemFactory.item(for: SessionSummary, dashboardID:, profile:)` returning a value struct (`uniqueIdentifier`, `domainIdentifier`, title, description, date), converted to `CSSearchableItem` at the edge so tests need no index.
  - `uniqueIdentifier` = `conduit.<dashboardID>.<profile>.<SessionSummary.id>`; `domainIdentifier` = `conduit.<dashboardID>.<profile>` so a profile deindex is one `deleteSearchableItems(withDomainIdentifiers:)`. The id is parsed back by splitting on the first three dots only after URL-safe encoding of each part (ids are opaque tokens; verify none contain dots, else use a delimiter such as `|`).
  - `CSSearchableItemAttributeSet(contentType: .text)` with `title`, `contentDescription`, `contentModificationDate` (from `lastActivityAt`), `displayName`. `expirationDate` left at the default.
  - Indexing via `CSSearchableIndex.default().indexSearchableItems(_:)`; removal via `deleteSearchableItems(withIdentifiers:)`, `withDomainIdentifiers:`, `deleteAllSearchableItems()`. All inside a protocol `SearchableIndexing` so tests inject a fake.
  - Diff-based: keeps a persisted `[id: (title, lastActivityAt)]` hash in `UserDefaults` (key `conduit.mac.spotlight.<dashboardID>.<profile>`); only changed rows are re-indexed, vanished-and-deleted rows are removed. A row merely absent from the loaded page is NOT removed (same rule as session tabs: absence is not deletion). Removal is driven by deletion detection, which matches the tabs spec: `sessionMutationID` ends and the session is gone from the catalog.
  - Debounced (2 s) off `appState.$sessions`; capped at 1,000 items per profile, newest first.
- Open path: `ConduitMacApp` adds `.onContinueUserActivity(CSSearchableItemActionType)`; reads `CSSearchableItemActivityIdentifier` from `userInfo`, parses to (dashboardID, profile, sessionID), and sets `pendingExternalLink = .session(id:, profile:)` so the existing connected-then-open task and `openAppLink` do the rest. A mismatched dashboardID is ignored with a message. (verify the SwiftUI modifier and the key names in Core Spotlight docs.)
- Settings: toggle in the Mac Settings Privacy pane (`ConduitMac/Views/`), persisted as `conduit.mac.spotlight.enabled` in `UserDefaults`; a "Remove from Spotlight" button calls `deleteAllSearchableItems`.
- Upstream edits: none planned. The deindex-on-delete observer lives in the indexer. Only if deletion cannot be observed without a hook (see tabs spec) does it need a gate and a ledger row.
- Rejected: `NSUserActivity.isEligibleForSearch` per opened chat (only covers visited chats, no deindex control); a Spotlight importer plugin (heavy, needs file store).

### Testing

- Mapper: title, description, date, identifier round trip, domain per profile, profile with odd characters.
- Indexer with fake index: initial index, rename re-indexes one item, delete removes one, page absence removes nothing, profile switch deletes old domain and indexes new, toggle off calls delete-all and later catalog changes index nothing, cap at 1,000, debounce coalesces.
- Continuation: userInfo identifier becomes the right `ConduitAppLink`; foreign dashboard ignored; malformed ignored.
- Manual: toggle on, search the title in Spotlight (Cmd-Space), open result with app closed, delete the chat and confirm the result disappears, toggle off and confirm empty.

## Part 3: Shortcuts / App Intents on Mac

### What already compiles on Mac

Both files are in the `Conduit` source tree that ConduitMac compiles; no excludes name `Conduit/Intents/`.
- `StartVoiceConversationIntent` + `ConduitProfileEntity` + `ConduitVoiceShortcuts`: compiles; `supportedModes` is macOS 26 gated (ledger R4); on macOS 14 and 15 the `openAppWhenRun = true` literal applies. Works in-process (no extension), so `PendingVoiceIntentStore` reaches the running app. Shows in Shortcuts on macOS 14+ (verify AppShortcutsProvider phrase support on Mac: Siri phrases and Spotlight actions need macOS 14/15 respectively).
- `AskHermesAboutScreenIntent`: compiles; takes an image file. On Mac it works with a screenshot from "Take Screenshot" in Shortcuts. Its parameter names are a stability contract (file header): do not rename, add optional parameters only.
- Voice intents need the microphone path on Mac; their usefulness there is limited but harmless.

### New intents (Mac-useful), all in new files under `Conduit/Intents/` only if iOS also benefits, else `ConduitMac/Intents/` (default: `ConduitMac/Intents/`, no ledger row, no iOS exposure)

1. `NewChatIntent` ("New Conduit Chat"): optional `profile: ConduitProfileEntity`, optional `message: String` (prefilled, never sent). Foreground. Hand-off via a Mac `MacIntentInbox` (same shape as `MacServiceInbox`, shares the drain task): create new session, prefill.
2. `OpenSessionIntent` ("Open Conduit Chat"): parameter `session: ConduitSessionEntity` (new `AppEntity`, `EntityStringQuery` suggesting `appState.activeProfileSessions` titles, identifier `SessionSummary.id`). Foreground. Routes as `.session(id:profile:)` through `openAppLink`. The query needs access to the live catalog: through a main-actor `MacIntentDataSource.shared` weak-referencing `AppState` (set at launch); returns an empty list when the app is not running (the intent launches it first with `suggestedEntities` empty; `entities(for:)` can resolve an id without a catalog).
3. `AskHermesIntent` ("Ask Hermes"): `prompt: String`, optional `profile`, returns `ReturnsValue<String>` with the final assistant reply. Background-capable (`openAppWhenRun = false` / `supportedModes` `.background` on macOS 26, verify). This is the one that needs real design: it must run a turn in a fresh session and wait for the reply, with a 120 s timeout and a clear error when disconnected. It requires an AppState entry point for "run a headless turn and return the final text" that does not exist today (not verified in this draft); see open question 4. Ship 1 and 2 first; 3 only after a spike.
- `AppShortcutsProvider`: Swift allows one provider per app. Add the new shortcuts to `ConduitVoiceShortcuts.appShortcuts` via a Mac-gated addition (`#if os(macOS) // MAC:` with a ledger row) or, preferably, rename nothing and add the entries there; limit is 10 `AppShortcut`s. Phrases must include `\(.applicationName)`. `updateAppShortcutParameters()` already runs on profile changes; add a call when the session catalog changes only if a session parameter is used in a phrase (it is not in v1; sessions are chosen in Shortcuts UI).
- Security: intents run for any shortcut on the Mac, including ones a user imports. Prefill-only (1) and open (2) are safe. (3) sends text to the agent and returns output; mark it as requiring the app's unlocked, connected state and never auto-approve tool prompts: a turn that needs approval fails the intent with "Needs approval in Conduit" rather than waiting.

### Testing

- Build gate: ConduitMac builds on macOS 14 deployment target with each new intent (no macOS 26 only API without `@available` + `// MAC:`).
- Unit: entity query suggestions from a fixed catalog, `entities(for:)` resolves by id, empty when no data source; inbox ordering and one-shot drain; `NewChatIntent` with and without profile; unknown profile throws a user-visible error.
- Metadata: App Intents metadata extraction produces no warnings in the Mac build log.
- Manual: Shortcuts app on macOS 14 and 26 lists the actions, run each with Conduit closed and open; Spotlight shows the app shortcuts; the existing Ask About Screen shortcut still runs.

## Docs and ledger

New D12 in docs/macos/DECISIONS.md (prefill over send; Spotlight opt-in and metadata-only; no daemon). Ledger rows only for any gated upstream edit (the AppShortcutsProvider addition if made in `Conduit/Intents/`). SMOKE_CHECKLIST gets a "System integration" section. `project.yml`: no new targets; new files fall under the existing `ConduitMac` source path; run xcodegen.

## Out of scope (v1)

Services for files/images/URLs, a Services "send and replace selection" round trip, a share extension, indexing message bodies, indexing bot/cron sessions, Spotlight "Quick Actions" beyond App Shortcuts, widgets/Control Center controls, iOS changes.

## Open questions

1. Prefill only for Services (proposed), or a second Service "Ask Hermes" that sends and replaces nothing? Sending from other apps is hard to undo.
2. Is title + metadata enough for Spotlight, or do you want last-message text indexed (needs a per-session fetch and exposes message content to Spotlight)?
3. Spotlight default off (proposed) or on?
4. For `AskHermesIntent`: is a headless turn (no visible window, reply returned to Shortcuts) acceptable given approvals and the single shared connection, and should it use a new session each time or a dedicated "Shortcuts" session?
5. Intent files location: `ConduitMac/Intents/` (proposed, Mac only) or shared `Conduit/Intents/` so iOS gets them too?

## Effort

- Part 1 Services: 1.5 days (plist, provider, inbox, drain task, tests, manual pass).
- Part 2 Spotlight: 3 days (mapper, diff indexer, deindex rules, continuation, settings toggle, tests).
- Part 3 Shortcuts: 2 days for New Chat + Open Session (entity, data source, provider edit, tests); +2 to 3 days for Ask Hermes after a 1-day spike.
- Total: 6.5 days without Ask Hermes, about 10 with it.
