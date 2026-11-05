# Mac changes viewer: design

Date: 2026-10-15. Status: draft for review. Target: the macOS app only (`ConduitMac`). iOS is unchanged.

## Goal

Show, for one turn (and optionally the whole session), the files the agent created or edited: a file list on the left, a diff on the right (unified or side by side), and per-file actions Quick Look, Reveal in Finder, Open in default editor. Entry point: a "Changes" chip on the turn's tool cards and a Go-menu / toolbar item for the session view.

## What data exists today (evidence)

The honest answer: Conduit receives tool name, a tool-argument string and a tool-result string. It never receives a typed "file edit" event, an old/new pair, or a unified patch as a structured field.

- Live stream. `StreamEventParser.swift:102-120` maps `tool.start`/`tool_call` to `.toolStart(sessionId, toolName, toolInput, toolID)` and `tool.complete`/`tool_result` to `.toolComplete(..., toolOutput, toolID)`. Input is the first present of `args_text`, `context`, `input`, `arguments`, `args`, flattened with `descriptiveStringValue`; output is `output` or `result`. No other field is read, so any `path`, `diff` or `files` sibling the server sends is dropped.
- Model. `Models.swift:99` `ToolActivity { id, name, input: String?, output: String?, status }`. Everything is a string; structure is lost at the parser.
- History reload. `HermesClient.swift:4129` `extractToolCalls` reads `tool_calls`/`tools`, taking `function.arguments` (a JSON string) as `input`; the tool-result row becomes `output` (`HermesClient.swift:3240-3290`). `session.resume` rows carry only a `context` preview and "deliberately omit raw output" (comment at `HermesClient.swift:3274`), so after a reload some cards have a preview only.
- Samples. `StreamEventParserTests.swift:215-285` only covers `web_search`/`terminal` (`args_text`, `input`, `arguments`). `MessageNormalizerTests.swift:1092` is the only file-tool fixture: `write_file` with `arguments` `{"path":"note.txt"}` and result `"saved"`. That proves a path key for `write_file` in that fixture and nothing about content, patches or other edit tools. The repo contains no captured payload for `patch`/`edit`.
- Rendering. `ChatView.swift:2082-2226` (`SettledToolCardContent`, `ToolCard`) shows `input` and `output` as plain monospaced text, truncated to 500 lines (`ToolCard.truncateForDisplay`). No diff or path awareness.
- No file-change event exists. `grep` for diff, patch, `file.changed` and similar finds nothing outside unrelated PATCH HTTP calls and `MEDIA:` tags (`GatewayMediaTags.swift`).

Can the client read the files? Conduit is a network client; the agent's files live on the Hermes host (often remote), so `NSWorkspace`/Quick Look cannot open them by path. What exists: dashboard filesystem endpoints used by the Workspace browser, via `dashboardTicketBridge`: `/api/fs/list`, `/api/fs/read-text` (returns `text`, `binary`, `byteSize`, `language`, `truncated`; `AppState.swift:24823-24848`), `/api/fs/read-data-url` (any type, size-bounded by `DataURLLimits`; `AppState.swift:24884`), and `/api/fs/write-text` (`AppState.swift:22568`). `workspaceDownloadURL` stages bytes to a temp file. So the client can fetch the file's CURRENT contents by absolute path, subject to dashboard auth, size limits and whatever root the dashboard permits (unverified for paths outside the workspace).

What it cannot get: the BEFORE contents. Nothing snapshots a file prior to the edit.

### Verdict

| Need | Available? | Source |
|---|---|---|
| Which file was touched | Probably, for tools whose args contain a path (verified only for `write_file` in a test fixture) | `ToolActivity.input` |
| New content (create) | Only if the tool's args carry it; unverified | `ToolActivity.input` |
| Edit as old/new strings or a patch | Only if the tool's args carry it; unverified | `ToolActivity.input` |
| Unified diff as a result | Unknown; result is free text | `ToolActivity.output` |
| Current file bytes | Yes via dashboard `/api/fs/*` | `AppState` workspace helpers |
| Pre-edit file bytes | No | n/a |
| Local path on this Mac | No (remote agent) unless the agent is local | n/a |

Server asks for a full-fidelity viewer (do not assume they exist): (1) forward a structured `files: [{path, op: create|modify|delete, before_sha, after_sha}]` on `tool.complete` for file-mutating tools; (2) a unified `diff` string per file in that payload (or a `/api/fs/diff?session&tool_call_id` endpoint); (3) keep the same fields in the persisted transcript and `session.resume`. Until then, ship the degraded version below.

## Constraints

- Porting rules (docs/macos/PORTING_LEDGER.md): Mac code under `ConduitMac/`; upstream edits gated `#if os(macOS)` with `// MAC:` and one ledger row each. No edits to `AppState.swift`.
- Pure parsing and diffing code goes in shared-neutral files under `ConduitMac/Changes/` (no AppKit) so it is unit-testable; nothing in `Conduit/` changes except one gate for the entry chip.
- Never invent tool names: the extractor is data-driven and tolerant (below), and unknown tools show no Changes chip.

## Approach

Degraded v1 (chosen): derive change entries from tool-call args and results already in the transcript. Rendering order of fidelity per file:
1. Patch text found in args or result (a unified diff or `*** Begin Patch` style block): render it as the diff.
2. Old/new string pair in args (str-replace style): synthesize a hunk from the two strings.
3. Full new content in args (write style): show as an all-added file, no "before".
4. Path only: list the file, show "No diff available" with Current content (fetched on demand) and the three actions.

Rejected: (a) fetch the file and `git diff` through a shell tool call to the agent (invents a model action, cost, and mutates the transcript); (b) client-side snapshot before each turn (needs a pre-edit read for every file the agent might touch, unknowable in advance); (c) wait for the server fields (blocks all value; the degraded view is also the fallback once they exist).

## Behavior

- **Turn scope.** A turn is the tool cards between a user message and the next user message. A "Changes (N)" chip appears on the last tool card of a turn that has at least one extracted entry. Click opens the viewer scoped to that turn.
- **Session scope.** Toolbar/Go menu item "Show Changes for Session" (Cmd-Opt-D) aggregates all turns; a segmented control (Turn / Session) switches. Same path edited several times: entries are kept in order and shown as one file row with "N edits"; the detail view stacks hunks per edit (we cannot compute a net diff without the baseline).
- **Window.** A sheet is wrong for a work surface: use a `Window("Changes", id: "changes")` scene opened with `openWindow(value:)` carrying `(sessionId, turnAnchorMessageId?)`. Split view: file list (sidebar style, status glyph A/M/D, +/- counts) and detail.
- **Detail.** Header: path, remote-or-local badge, view picker Unified / Side by side (remembered in `UserDefaults`, `conduit.mac.changes.diffMode`). Body: diff or the degraded states (full-file, path-only). Large diffs: virtualized lines, collapse unchanged context beyond 3 lines (expandable).
- **Actions.** Per file, toolbar and context menu:
  - Quick Look: fetch current bytes via `/api/fs/read-data-url`, stage with `MediaPreviewPresenter.stage`, preview. Until the QLPreviewPanel backlog (ledger row for `MediaPreviewPresenterMac.swift`) is done, this falls back to the existing placeholder (reveal staged copy in Finder). Implementing a real `QLPreviewPanel` data source is in this feature's scope (see Effort) because Space-to-preview is the expected behavior.
  - Reveal in Finder: only when the path exists on this Mac (local agent, or the staged copy). Otherwise reveals the staged download and says so in the tooltip.
  - Open in default editor: stage current bytes, `NSWorkspace.open`, file quarantined first (`FileQuarantine.markQuarantined`, as the existing presenter does). The staged copy is read-only intent: label it "Copy from gateway"; edits there do not sync back (no write-back in v1).
  - Copy path, Copy diff.
- **States.** Loading, "file not available" (deleted, outside dashboard root, auth failure), "binary file" (no diff, actions only), "truncated" (server `truncated` flag: banner), and tool still running (row shows spinner; diff appears on completion).
- **Reload.** Entries are recomputed from `messages`; no separate persistence. Cards that came back from `session.resume` with only a preview yield path-only entries at best.

## Architecture and file paths

All new, Mac-only:

- `ConduitMac/Changes/FileChangeExtractor.swift`: pure. `static func changes(from: [ChatMessage]) -> [FileChange]`. `FileChange { path, op (.create/.modify/.delete/.unknown), edits: [Edit], toolCallID, messageID, turnIndex }`; `Edit` is `.patch(String)`, `.replace(old,new)`, `.fullContent(String)`, `.pathOnly`. Parses `ToolActivity.input`: JSON object when it decodes, else a tolerant `key=value` / patch-text scan. Key aliases live in one table (`path`, `file_path`, `filepath`, ...) that is data, tuned against captured payloads (open question 1).
- `ConduitMac/Changes/UnifiedDiffParser.swift`: pure. Parses unified diffs and the `*** Begin Patch / *** Update File:` format into `[DiffHunk]`.
- `ConduitMac/Changes/LineDiff.swift`: pure. Myers line diff for the replace/full-content cases; word-level highlight inside changed lines via a second pass on paired lines.
- `ConduitMac/Changes/ChangesStore.swift`: `@MainActor ObservableObject`. Holds scope, selection, diff mode, cached current-content fetches; calls `AppState.previewWorkspaceFile`-equivalent public APIs (`gatewayMediaDataURL(for:profile:)` for bytes). No new gateway calls.
- `ConduitMac/Changes/ChangesWindow.swift`, `ChangesFileList.swift`, `DiffView.swift` (unified), `SideBySideDiffView.swift`: SwiftUI.
- `ConduitMac/Changes/ChangesFileActions.swift`: stage, quarantine, Quick Look, reveal, open. Reuses `MediaPreviewPresenter.stage` and `FileQuarantine`.
- `ConduitMac/Views/MediaPreviewPresenterMac.swift`: replace the Finder placeholder with a `QLPreviewPanel` controller (retires the ledger backlog; update that row).
- `ConduitMac/App/ConduitCommands.swift`: Go-menu item and shortcut.
- Upstream edit (one gate): `ChatView.swift` tool-card footer, `#if os(macOS) // MAC:` adds the Changes chip view (`MacChangesChip`) after `ToolCard`; one ledger row. The chip reads `FileChangeExtractor` output via an environment value so the gate stays 2-3 lines.
- Docs: new D15 in docs/macos/DECISIONS.md, ledger row, SMOKE_CHECKLIST entry.

## Diff rendering approach

No new dependency. Rendering is SwiftUI `LazyVStack` of line rows in a monospaced font with:
- Unified: gutter with old/new line numbers, +/- marker, tinted row backgrounds (added/removed colors from the existing semantic palette; contrast >= 4.5:1 in light and dark, per D11 rule).
- Side by side: two columns aligned by hunk, paired removed/added lines, shared vertical scroll. Falls back to unified when width < 700 pt.
- Syntax highlighting: none in v1 (the dashboard returns a `language` hint for later). Word-level intra-line highlight only.
- Selection/copy: rows are plain `Text` with `.textSelection(.enabled)`; for very long diffs (> 5000 lines) switch to a single NSTextView-backed view (the existing `SelectableTextView` twin) to avoid SwiftUI selection cost.
Justification for no library: diff parsing is ~200 lines; a Swift diff package or a WKWebView with a JS diff viewer adds a dependency and a second rendering path for little gain.

## Testing

- Extractor: fixtures for each fidelity level (JSON args string as in `MessageNormalizerTests.swift:1092`; object `arguments`; `args_text`; patch in result); unknown tool yields nothing; same path edited twice; cards with preview-only input; replayed events with duplicate `toolID`.
- UnifiedDiffParser: hunks, no-newline marker, renames, `*** Begin Patch` blocks, malformed input degrades to raw text.
- LineDiff: replace pair, add-only, delete-only, CRLF, 20k-line performance bound (< 100 ms).
- Store: scope switch, selection persistence, fetch cancellation on selection change, cache invalidation on profile change.
- Actions: stage then quarantine order; failure to quarantine opens nothing; local-path detection.
- View: hosted diff views render in light and dark; accessibility labels on rows and actions.
- Full Mac suite twice; `git diff -- Conduit Shared` removes zero lines outside gates.

## Open questions

1. What do the real Hermes file-edit tools put in their args and result (names, keys, patch format)? Needed: one captured payload each for create, str-replace and patch tools (live `tool.start`/`tool.complete` and reloaded transcript). The extractor key table depends on it.
2. Will the server team add structured file-change fields (see Verdict asks)? If yes, the extractor becomes a fallback and v1 effort drops by ~1 day.
3. Are absolute paths outside the dashboard workspace root readable via `/api/fs/*`? If not, current-content actions work only for in-workspace files.
4. Is a remote agent the norm for this user? If the agent is usually on the same Mac, Reveal and Open can use the real path and Quick Look needs no download.
5. Is write-back (editing the staged copy and saving to the gateway through `/api/fs/write-text`) wanted later? Out of scope here, but it changes the "copy" labeling.

## Effort

About 7 days. Extractor, diff parser, line diff and tests 2.5; window, list, unified and side-by-side views 2; actions plus real QLPreviewPanel 1.5; chip gate, commands, docs, smoke and two full-suite runs 1. Add 1 day if payload capture (question 1) shows nonstandard formats; subtract 1 if the server ships structured fields first.
