# Mac Share to Hermes (files, images, URLs): design

Date: 2026-10-17. Status: draft for review (not yet approved). Target: the macOS app only (`ConduitMac`). iOS is unchanged. Extends D19 Services (docs/superpowers/specs/2026-10-15-mac-system-integration-design.md Part 1) and reuses the D25 extension packaging (docs/superpowers/specs/2026-10-16-mac-widgets-design.md).

## Intent

Today only selected text reaches Hermes from another app (Services > Send to Hermes). v2 lets the user hand Hermes a file in Finder, a photo, an image, or the web page open in Safari, and land in a new Conduit chat with it attached, ready to ask about. Two parts, each shippable on its own, in this order:

- Part A: the existing "Send to Hermes" Service also takes files, images and URLs. In-process, no new target. Covers Finder (right-click > Quick Actions or Services) and any app that offers Services on a selection.
- Part B: a Share extension, "Conduit" in the system Share menu. Covers Safari's page URL, Photos, Finder's Share button, and every app with a Share menu.

The user skipped the question round, so product choices not already set by D19 are the designer's call and are marked "(call)".

## Goals

- From Finder, Safari or Photos, two clicks put the item into a new Conduit chat with the composer ready.
- The same attachment rules as a drop on the chat pane (size limit preference, 10 per message, JPEG re-encode, folders expand, packages refused).
- Nothing is sent until the user presses Return in Conduit.

## Non-goals

- Sending from the share sheet without opening Conduit (the extension has no gateway connection; D19 rules out unreviewed sends).
- Sending into the Quick Ask panel instead of a new chat (possible later; see "Later").
- Choosing a target chat or profile in the share sheet; the target is always a new chat in the active profile.
- A Services "send and replace selection" round trip; Share returning content to the host app.
- iOS share extension.

## Anti-goals

- Content of the share in a URL (`conduit://...?text=`): any app could trigger it and URL handlers log it (D19 rejected this).
- A shared file landing in the chat that was open, or replacing a draft the user typed.
- A share that silently disappears: if Conduit cannot be opened, the user is told and the item waits.
- A prompt such as "would like to access data from other apps" on macOS 15 (D25).

## Constraints

- D19 rules hold: prefill, never send; always a new chat; parked until `AppState.macCanApplyParkedRequest`; one slot, last write wins; dropped on dashboard or profile change (`MacServiceInbox` scope stamp); the prefill refuses when the chat open after the create already holds a draft.
- Porting rules: Mac code under `ConduitMac/` (and the new extension folder); upstream edits gated `#if os(macOS)` with a ledger row each. Target: zero upstream edits (see "Composer hand-off" for the one possible exception).
- Signing (D25 precedent): Developer ID, hardened runtime, no provisioning profile, team-prefixed app group. A macOS app extension must be sandboxed; the app stays unsandboxed.
- Strings in all 13 shipped languages (`Conduit/Localizable.xcstrings`; the extension compiles that catalog by path, as `ConduitMacWidgets` does). The Services menu title stays in `ConduitMac/Resources/ServicesMenu.xcstrings` (not checked by CI; D19).

## Findings that shape the design

- Services can take files: an `NSServices` entry may set `NSSendFileTypes` (an array of UTIs; pasteboard types are not allowed there) and the provider reads file URLs from the pasteboard. An entry may set both `NSSendTypes` and `NSSendFileTypes`. Source: Apple "Services Properties" (archived Cocoa docs; verify against the current SDK while building).
- A Share extension cannot officially open its containing app. Apple engineers on the Developer Forums say share extensions should call `completeRequest` and that `NSExtensionContext.open(_:)` is for Today widgets; developers report it returns false from a share extension (forums threads 80306, 773342, 758790). Whether `NSWorkspace.shared.open(_:)` with the `conduit` scheme works from a sandboxed share extension on macOS is not documented. This decides the day-1 spike (Part B, "Opening Conduit").
- Mac attachments travel as base64 over the existing RPCs (`image.attach_bytes`, `file.attach`); there is no URL attachment type. A web page is therefore shared as text (its title and URL) for Hermes to fetch, not as an attachment.
- The composer's attachments are view state (`ComposerBar` `@State attachments`), not AppState. The only outside entry today is the main chat pane's drop receiver (`MacAttachmentDropSink.receiver`, `ConduitMac/Chat/ChatAttachmentDrop.swift`), which hands a `MacAttachmentDropPayload` to `ComposerBar.receiveMacDrop` with the composer's own rules.

## Part A: Services for files, images and URLs

### Behaviour

- The one "Send to Hermes" Service now also appears for files in Finder (right-click > Quick Actions or Services) and for selected images and URLs in apps that offer them. Same title everywhere (call: one verb for one action).
- What it does, by pasteboard content, first match wins (the order of `MacAttachmentDropPolicy.payload(from:)`, plus the text and URL cases):
  1. file URLs: a new chat with those files attached (folders add their top-level files, packages are refused by name, more than 10 keeps the first 10 and shows the too-many message);
  2. image data (PNG or TIFF): written to a PNG file in a Conduit temp folder (`ComposerTextView.pastedImages(from:)` for the bytes), then handled as case 1 with one file, so every request carries files only (see "Composer hand-off");
  3. a web URL with no string: a new chat with the URL as composer text;
  4. text: as today (D19, `MacServiceText.normalize`, 20,000 cap).
- Files are not copied at receipt (call): the app is unsandboxed and reads them at apply time through the composer's normal staging (`handleDocumentSelection`, which copies into `AttachmentStaging`). A file moved or deleted before Conduit connects shows the composer's normal failed-import message.
- Empty or unusable pasteboard: `error.pointee = "Nothing to send to Hermes"` (new string; the text-only "No text selected" stays for the text-only case so existing behaviour does not change).

### Architecture

- `Info.plist` `NSServices[0]`: add `NSSendFileTypes = [public.data, public.folder]` (call: regular files and user folders, so a folder adds its top-level files exactly as a drop on the chat pane does; a package such as .app conforms to `com.apple.package`, not `public.folder`, so Finder does not offer the Service on one, and the package refusal stays as a guard for mixed selections) and `NSSendTypes += [public.png, public.tiff, public.url]` (five types in all). Keep `NSMessage = sendToHermes`. Fallback if one entry with both keys does not show in Finder (spike, 0.25 day): a second entry, "Send Files to Hermes", `NSMessage = sendFilesToHermes`, with only `NSSendFileTypes`.
- `MacServicesProvider.sendToHermes`: reads in the order above and submits a `MacShareRequest` (below) instead of a string.
- `MacShareRequest` (new, `ConduitMac/App/MacShareRequest.swift`): `text: String?`, `files: [URL]`, `source: .service | .shareExtension(itemID: UUID)`. Text passes `MacServiceText.normalize`. Files only, never raw images: `MacAttachmentDropPayload` carries one kind per delivery and the composer's cap check (`existingCount: attachments.count`, `ComposerBar.swift:1731`) is stale until staging ends, so a request is delivered to the composer in exactly one `receive` call.
- `MacServiceInbox` holds a `MacShareRequest` instead of a `String` (same one slot, last write wins, scope stamp, `take()` drops a request from another scope). The New Conduit Chat intent's text path is unchanged (it has its own inbox, D19).
- `MacServiceRouting` applies a request: bring Conduit forward, create the new chat (`MacNewChatPrefiller`, which needs an empty-text variant for a files-only request), then hand files and images to the composer (next section).

### Composer hand-off

The composer must receive the files only after it shows the new chat; a payload that arrives while it still shows the old chat would attach to the old draft (anti-goal).

- Route: the main chat pane's drop receiver, the same path a Finder drop on the chat pane takes. `MacChatAttachmentDropModifier` stores its sink in a Mac-owned static weak reference (`MacAttachmentDropSink.chatPane`). No window check is needed: the modifier is applied only to `ChatView`, which only `RootView` (the primary window) shows (`Conduit/Views/RootView.swift:424`); D21 session windows use `MacSessionWindowView`.
- Timing signal: `prefillComposer` keys the prefill to the new session's draft and the composer consumes the token once it shows that chat (`applyPendingPrefill`, `ComposerBar.swift:1688`). The composer also consumes it WITHOUT applying when the prefill's chat is no longer the destination (`handoffComposer`, `ComposerBar.swift:1674`). So the hand-off waits (poll every 50 ms, 3 s cap) until all of: `composerPrefillDraftKey == nil`, `appState.activeSessionId` equals the id the create produced, and `receiver.isEnabled()`. Then it calls `sink.receiver?.receive(.fileURLs(files))` once. For a files-only request the prefill is an empty string (call), which keeps one signal for both cases.
- Focus: an empty prefill leaves the composer unfocused (`isFocused = !text.isEmpty`, `ComposerBar.swift:1696`), so the hand-off then issues the existing composer focus request (`ComposerFocusRequest`) for the new session.
- `receive` returns no completion and staging runs in a task (`handleDocumentSelection`, `ComposerBar.swift:1897`), so nothing waits for staging to finish. Files that must outlive the hand-off (share extension items) are moved out of the group folder at drain (see "Inbox"), never deleted right after `receive`.
- If the signal never comes (3 s), the files are not attached and the composer shows "Couldn't attach the shared files. Drop them on the chat to try again." (new string). Nothing goes to the old chat.
- If a hosted test shows the token is consumed before the composer's `attachments` belong to the new draft key, the fallback is one gated upstream edit: `prefillComposer(_:attachments:)` in `AppState` plus the composer taking `composerPrefillAttachments` in the same gated consumption (two ledger rows). The builder decides from the test; the behaviour above is the contract.

### Testing

- Provider: each pasteboard shape (file URLs, PNG, TIFF, URL only, text, text plus URL, empty) gives the right request or error; uses private `NSPasteboard(name:)`.
- Info.plist test: `NSSendFileTypes == [public.data, public.folder]`; `NSSendTypes` equals the five types; selector still matches. The existing D19 test pins exact equality of `NSSendTypes` (`ConduitMacTests/MacServicesProviderTests.swift:66`), so it is rewritten, not extended.
- Inbox: request replaces request; scope stamp drops a stale request; files-only request survives.
- Routing (fakes): files-only creates and attaches with no text; text plus files prefills then attaches; attach waits for prefill consumption; timeout attaches nothing and shows the message; refused create attaches nothing anywhere.
- Routing: a prefill consumed by `handoffComposer` (the user opened another chat during the create) attaches nothing; a files-only request ends with the composer focused.
- Hosted: a real `ComposerBar` in a window; after the hand-off its draft for the NEW session holds the attachments and the old session's draft is unchanged.
- Manual (SMOKE_CHECKLIST): `pbs -update`, relaunch; Finder right-click a PDF and three images; a folder (top-level files attach); an .app (Service absent); Preview image selection; with Conduit quit, disconnected and mid-turn.

## Part B: Share extension

### Behaviour

- The Share menu (Safari toolbar, Finder, Photos, any app) lists "Conduit" (call: the Share menu names destinations by app; the Service keeps the verb "Send to Hermes").
- Accepts: files, images, 1 web URL, or text (activation rule below). (call) The activation rule accepts up to 100 files or images so that a selection of 11 or more does not silently hide Conduit from the Share menu; the sheet then lists the first 10 and says "Only the first 10 files will be attached." (the drop path's limit, not a new one).
- The share sheet shows:
  - a title, "Send to Hermes";
  - a preview list: file name, type and size (`AttachmentTypePolicy.detailLabel`), a thumbnail for images, page title and URL for a web page, the first three lines of text;
  - files over the size limit marked "Too large" and left out;
  - a note field, "Add a note (optional)";
  - Cancel, and the default button "Open in Conduit".
- Open in Conduit: the extension writes the item to the shared inbox, asks the system to open Conduit, and completes. Conduit comes forward, a new chat opens with the files attached and the composer text set to: the note, then a blank line, then "<page title>\n<URL>" for a web page or the shared text. Nothing is sent.
- If Conduit could not be opened (see spike), the sheet changes to "Saved. Open Conduit to finish." with a Done button; Conduit picks the item up the next time it launches or becomes active.

### Gate before Part B work (day-1 spike, 1 day)

Part B starts with a throwaway extension, built through the real release path (`scripts/mac-release.sh` signing, notarized, stapled, installed from a quarantined DMG download into /Applications), that proves two things before any of the 4 days below is spent:

1. **The group works at run time.** The sandboxed extension writes a file into `58XKRG9VMA.com.meswan.hermes.mac.share` and the unsandboxed app reads it, with no "would like to access data from other apps" prompt, on macOS 14 and 15. D25 signed and exported the same kind of group but never ran it on a notarized, quarantined install (D25 "Not verified until the release gate"; SMOKE_CHECKLIST lines 37 and 38 are unchecked), so this is unproven. If it fails, Part B stops: the fallback is a `group.` id with Developer ID provisioning profiles for the app and both extensions (D25 fallback), which needs the user to create the profiles in the Apple Developer portal. Part A ships either way.
2. **Opening Conduit** (next section).

### Opening Conduit

Try in order, on macOS 14, 15 and 26, from the sandboxed, hardened, Developer ID signed extension, with Conduit quit and running:

1. `NSWorkspace.shared.open(URL(string: "conduit://share/<item id>")!)`.
2. `NSWorkspace.shared.openApplication(at: <containing app URL>, configuration:)`. The app URL is the extension bundle's path three levels up (`Conduit.app/Contents/PlugIns/X.appex`); the app then drains the inbox on launch or activation.
3. Neither works: post the Darwin notification `com.meswan.hermes.mac.share.new` (works for a running Conduit, which drains on receipt) and show "Saved. Open Conduit to finish." when Conduit is not running.

Record the result in D27. Also confirm in the spike that `NSWorkspace` is usable with `APPLICATION_EXTENSION_API_ONLY = YES`.

(call) If only step 3 works, Part B still ships. Conduit is usually running (the Quick Ask hotkey and the notch need it), and then the Darwin notification makes the share land at once. When Conduit is quit the sheet says "Saved. Open Conduit to finish." and the item is applied at the next launch. That is worse than a direct open but still saves the user from re-finding the file. The rest of the design does not change with the answer; only the extension's last step and that sentence do.

### Inbox (app group hand-off)

- New app group `58XKRG9VMA.com.meswan.hermes.mac.share` (call: separate from the widgets group, so the widget extension cannot read shared files). Team-prefixed, no provisioning profile (D25 evidence). `ConduitMac.entitlements` lists both groups; the extension's entitlements list only the share group plus `app-sandbox`.
- Item layout: `<group container>/ShareInbox/<item UUID>/request.json` plus the copied files in the same folder. `request.json`: `version` (1), `createdAt`, `note`, `text`, `url`, `title`, `files: [{ storedName, displayName, typeIdentifier }]`.
- The extension copies files with `NSItemProvider` file representations (`loadFileRepresentation` for files and images), checks each size against the limit before copying, and writes `request.json` last (atomically), so a half-written item has no request file and is ignored.
- Size limit: the app mirrors `conduit.attachmentSizeLimitMB` into the group's `UserDefaults(suiteName:)` on launch and on change; the extension reads it, defaulting to 16 MB when absent. The app's staging checks again (the extension is not trusted for the limit).
- Language: (call) the sheet follows Conduit's in-app language setting, not only the system language. The app mirrors the chosen language into the share group's defaults the way `publishWidgetLanguage` does for widgets (`Conduit/Services/AppState+Widgets.swift:92`); the extension falls back to the system language when the value is absent.
- Untrusted input on the app side (another process wrote it): `request.json` capped at 64 KB and must decode; text and note through `MacServiceText.normalize` (combined cap 20,000); at most 10 files; every stored name must resolve to a regular file directly inside the item folder (no `..`, no symlinks; checked with resolved paths); display names pass `AttachmentTypePolicy.filename` and `MacUntrustedText.sanitize`; unknown versions are ignored.
- Drain: on `conduit://share/<uuid>` (handled in `.onOpenURL` before `ConduitAppLink`, ignored unless the folder exists), on launch, on `applicationDidBecomeActive`, and on the Darwin notification. Oldest first. Draining an item validates it, MOVES its files out of the group folder into a Conduit-owned folder under `AttachmentStaging.directory` (`Shared-<uuid>/`), deletes the group item folder at once, and submits a `MacShareRequest(source: .shareExtension(itemID:))` pointing at the moved files. The D19 inbox rules then apply (one slot, last write wins, scope stamp at arrival).
- Why move at drain: `receive` gives no completion and the composer stages in a task, so there is no moment when "staging finished" is known; and a folder still in the group would be drained again on the next activation. After the move the group holds nothing to re-drain, and the composer copies from the moved files as it would from Finder.
- Cleanup: a replaced or dropped request deletes its `Shared-<uuid>/` folder; everything else under `AttachmentStaging.directory` is cleared by the existing launch sweep (`sweepStaleFiles`, 3 days). Group items older than 24 hours (an extension that crashed before writing `request.json`) are deleted at launch.

### Extension target

- `ConduitMacShare`, `type: app-extension`, macOS 14, bundle id `com.meswan.hermes.mac.share`, embedded at `Conduit.app/Contents/PlugIns/ConduitMacShare.appex` (`project.yml` dependency with `embed: true`, `codeSign: true`, as `ConduitMacWidgets`). Sources: `ConduitMacShare/` (view controller, inbox writer), a small Mac-owned `Shared/ShareInbox/` folder compiled into both the app and the extension (the `request.json` model, the group id constant, the size-label and size-limit rule), and `Conduit/Localizable.xcstrings` as a resource. `AttachmentTypePolicy.detailLabel` cannot be shared by path (it takes an `Attachment` and lives in a SwiftUI view file that needs the UIKit compat module), so the extension's size label is a copy with a parity test against `detailLabel`.
- `Info.plist`: `NSExtensionPointIdentifier = com.apple.share-services`, `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`, `NSExtensionAttributes.NSExtensionActivationRule` dictionary: `NSExtensionActivationSupportsFileWithMaxCount = 100`, `NSExtensionActivationSupportsImageWithMaxCount = 100`, `NSExtensionActivationSupportsWebURLWithMaxCount = 1`, `NSExtensionActivationSupportsText = YES` (verify key names against the current SDK while building).
- `ShareViewController: NSViewController` hosting a SwiftUI view (`NSHostingView`). No network, no Keychain, no gateway code in the extension.
- Settings: `APPLICATION_EXTENSION_API_ONLY = YES`, `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_IDENTITY = Developer ID Application`, team 58XKRG9VMA, versions equal to the app (`scripts/mac-release.sh` overrides every target).
- Release: `scripts/mac-verify-bundle.sh` hard-codes one appex today (lines 15 to 17 and 52); it is changed to loop over both appexes with the same checks (embedded, team, hardened runtime, sandboxed, its own group only, version) and the app check gains the second group. `MacShareEmbeddingTests` pins the group id in the constant and both entitlements files, as `MacWidgetsEmbeddingTests` does.
- Discovery: a new Share extension may need enabling in System Settings > General > Login Items & Extensions > Sharing; the app registers it when it runs from /Applications. Smoke item; no code.

### Testing

- Extension pure parts: preview rows from item providers (fakes); size mark; `request.json` encode.
- App inbox reader: valid item; missing `request.json` ignored; oversized json; unknown version; `..` and symlink names rejected; 12 files keeps 10; text cap; display-name sanitizing.
- Drain triggers: URL with unknown id does nothing; launch drain; replace deletes the older folder; 24-hour sweep.
- End to end (hosted, fake group folder): an item becomes a new chat with the files attached and the composed text, and the folder is deleted.
- Bundle: `mac-verify-bundle.sh --archive` passes with both appexes; `MacShareEmbeddingTests`.
- Manual (SMOKE_CHECKLIST): Safari page, Photos (2 photos), Finder (PDF), Notes text; Conduit quit, running, disconnected; macOS 14 and 15; the notarized build's first launch registers the extension; no "access data from other apps" prompt.

## Error handling summary

| Case | User sees | Item |
|---|---|---|
| File over the limit (extension) | "Too large" in the sheet; others go | left out |
| Conduit cannot be opened | "Saved. Open Conduit to finish." | waits in inbox |
| Not connected | Conduit's connection UI; request parked (D19) | parked |
| Profile or dashboard changed before apply | nothing (D19 drop rule) | deleted |
| Hand-off timed out | "Couldn't attach the shared files. Drop them on the chat to try again." | deleted |
| Composer import fails (moved file, unreadable) | the composer's failed-import message | n/a |
| Chat already has a draft after create | nothing is prefilled or attached (D19) | deleted |

## Docs

New D27 in docs/macos/DECISIONS.md (Services file types, request type, hand-off signal and fallback, share group, inbox format and trust rules, the opening spike result). D19's "no share extension" line is superseded by D27, not edited. SMOKE_CHECKLIST gets a "Share to Hermes" section. PORTING_LEDGER rows only if the hand-off fallback is used.

## Left to the builder

- Share sheet layout within 420 to 520 pt width, light and dark.
- The poll interval and cap for the hand-off signal, within "the composer shows the new chat first".
- Whether the extension reuses upstream pure files by path or a small Mac-owned copy, with a parity test either way.

## Later (not in this spec)

- "Ask in Quick Ask" as a second destination (opens the panel with the files staged; needs Quick Ask v2 Part 1).
- Share into the open chat instead of a new one.
- Profile choice in the share sheet.

## Effort

About 6.5 working days (my earlier "about 3 days" covered the extension alone and left out the Services half, the hand-off timing work and the notarized-install gate):

- Part A Services: 1.5 days (plist and Finder spike 0.25, provider and request type 0.25, inbox and routing 0.25, composer hand-off with the hosted test 0.5, tests and smoke 0.25).
- Part B Share extension: 5 days (gate spike with a notarized install 1, target, signing and the verify-bundle loop 1, sheet UI 1, inbox writer and app reader with trust rules 1, drain, move and cleanup 0.5, tests and smoke 0.5). Stop point after day 1 if the group fails at run time.
