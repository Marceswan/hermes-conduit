# Upstream sync skill and the Conduit 2.x merge: design

Date: 2026-10-21. Status: draft for review. Target: the macOS app only (`ConduitMac`). Upstream: `kaishi00/hermes-conduit` (`upstream` remote). Our fork: `Marceswan/hermes-conduit`, branch `macos`.

## Intent

Upstream shipped Conduit 2.0 to 2.2 (iOS) in the eight days after our last merge (merge-base `c13e234f`, 2026-10-13). Most of the new work is rich content between the user and the agent: cards, charts, HTML previews, Mermaid and KaTeX, bounded web images, readable tool rows, large media. The Mac app must render all of it, without a UI rework and without breaking any Mac feature.

This happens again every week or two. So the work has two parts, in this order:

1. **Part 1: an `upstream-sync` skill.** It makes the manual routine in `docs/macos/PORTING_LEDGER.md` ("Sync routine") a repeatable, gated procedure: evaluate, stop for approval, merge, build, test, report.
2. **Part 2: the 2.x merge, as the skill's first run.** 498 upstream commits against 313 Mac commits. This run also tests the skill.

## Goals

- The Mac app renders every rich-content type that upstream 2.x renders, checked in the real app against the user's Hermes host.
- Every upstream commit since `c13e234f` is merged into `macos`.
- The Mac build and the full `ConduitMac` test suite pass after the merge, with no test that passed in the baseline now failing.
- A future upstream drop takes one `/upstream-sync` run: an evaluation report, one approval, a merge.

## Non-goals

- The upstream V2 UI (tab shell, V2 sheets, V2 chrome). The Mac keeps its current UI.
- iOS-only features: CarPlay, Apple Watch, Health, Live Activities, phone and location sync, the iOS Share extension, App Store tooling.
- The Mac Share to Hermes feature (`2026-10-17-mac-share-to-hermes-design.md`). It stays a separate project.
- Pushing to `origin` or cutting a release. Both stay manual (`PORTING_LEDGER.md` steps 6 and 7).
- A scheduled or unattended sync. The user runs the skill.
- The iOS Simulator build (sync routine step 5). Only the Mac app ships.

## Anti-goals

- A merge that leaves out upstream commits (cherry-picks, partial merges). Each later merge then gets harder. "Skip" means "not compiled on Mac" or "gated off on Mac", never "not merged".
- The V2 look appearing on the Mac after the merge, in whole or in part.
- A green test run that hides a broken feature: a rich-content type that compiles but shows raw JSON, raw `::preview{...}` text or an empty box.
- A merge that lands on `macos` before the user saw and approved the evaluation report.
- Re-sorted keys in `Conduit/Localizable.xcstrings` (a 45k-line diff happened on 2026-10-15).

## Constraints

- Porting rules R1 to R4 and decisions D1 to D4 (`docs/macos/DECISIONS.md`) hold. Every upstream edit is tagged `// MAC:` and gets a ledger row.
- The Mac target compiles all of `Conduit/` and `Shared/` except the exclude list in `project.yml` (target `ConduitMac`). So new iOS-only upstream code compiles into the Mac app. It can need R1 to R4 fixes even though Mac never calls it.
- Mac tests are `ConduitMacTests` only. Upstream's `ConduitTests` is iOS and does not run on Mac. Upstream's tests for cards, previews and tool rows therefore do not protect the Mac. This is why the live check exists.
- Parallel-agent rules (memory `parallel-agent-hygiene`): per-worktree scratch in `build/scratch`; agents run only their own test classes; the full suite runs once in the main checkout after each merge; `MacToolbarRealWindowTests` and `PhoneScenePresenceMacTests` flake under load, so rerun the failed class before calling a regression; merge `Localizable.xcstrings` key by key with a JSON script that keeps "ours" key order and writes `indent=2, separators=(",", " : "), ensure_ascii=False`.
- Before debugging a "still broken" report, check the running binary path (`ps -o comm`). The app may run from the DMG (memory `verify-running-binary-path`).
- Workspace cleanup (user CLAUDE.md): remove a merged worktree, its branch and its scratch right away. Check `df -h` before parallel worktree agents; prune if under about 20 GB.
- Text the skill writes follows ASD-STE100: strict mode for the skill's instructions and status messages, STE-flavored for the report.

## Findings that shape the design

- **Size.** `git diff --shortstat c13e234f upstream/main`: 623 files, +274,351 / -52,835. About 187k of those lines are `Conduit/Localizable.xcstrings`. Our side: 424 files, +103,486 / -109 (the Mac port adds; it rarely edits).
- **Release tags are not on upstream `main`.** Each `ios/v*` tag sits on a release-cut commit off `main`. The `main` commit a release was cut from is `git merge-base <tag> upstream/main`:

  | Release | main commit | Commits in step |
  |---|---|---|
  | 0.1.19 (build 212) | `a7939bf3` (2026-10-18) | 205 |
  | 2.0.0 (build 215) | `7124e87c` (2026-10-19) | 190 |
  | 2.1.0 (build 216) | `0f4da80a` (2026-10-19) | 20 |
  | 2.2.0 (build 219) | `be8e27a5` (2026-10-20) | 73 |
  | upstream/main | `b945f9c4` (2026-10-21) | 10 |

- **V2 is behind one preference.** `Conduit/Views/V2/V2Shell.swift`: `V2ShellPreference.key = "conduit.useV2Shell"`, `defaultValue = true`. `RootView` reads it through `@AppStorage` (`useV2Shell`) and takes the drawer shell when it is false. The V2 composer behaviour is an environment value (`\.v2ComposerRests`) that only `V2ConversationScreen` sets to true. Unknown: whether some V2 views (for example "V2 Model/Context sheets", #970) replaced legacy views outside this switch. The evaluation must find these.
- **Rich cards need the host plugin.** Cards come from the Hermes tool `conduit_show` (`Conduit/Cards/RichCard.swift`), provided by the Hermes Conduit Notifier plugin. Upstream recommends plugin `0.48.0` (`Conduit/Services/NotifierPluginStatus.swift`, new upstream file). The live check needs that plugin version, or a newer one, on the user's host.
- **HTML previews go through Mac twins.** `::preview{file="..."}` is parsed in `Conduit/Views/Components/HTMLPreviewBlock.swift` and drawn from `MarkdownText.swift`. `ConduitMac/WebViews/WebViewTwins.swift` holds renamed copies of upstream private types (`MacMarkupMessageProxy` copies `MarkupBlock.swift` `MarkupMessageProxy`; `MacRemoteImageHTML` copies `MarkdownText.swift` `RemoteImageHTML`). Upstream changed preview, Mermaid, KaTeX, CSP and image-loading code (#587, #588, #777, #892, #1010, #1011), so these twins must be re-ported by hand.

## Part 1: the `upstream-sync` skill

### Where it lives

- `.claude/skills/upstream-sync/SKILL.md` in this repo, committed. Invoked as `/upstream-sync`.
- Deterministic work goes in scripts under `scripts/upstream-sync/` (call: scripts, not skill prose, for anything that can be computed). The skill tells the agent when to run each script and what to judge by reading.
- The Sync routine section of `PORTING_LEDGER.md` stays the human-readable reference. The skill links to it and replaces the iOS build step there with a note that it was removed (see Non-goals).

### Phase 1: evaluate (no code changes)

1. **Preflight.** Clean working tree on `macos`. `git fetch upstream --tags`. `df -h` check. Record the merge-base and the commit count on each side.
2. **Baseline.** In the main checkout: `xcodegen generate`, then `xcodebuild test -scheme ConduitMac -destination 'platform=macOS'`. Save the list of failing tests (rerun each failing class once to remove flakes). These failures do not count as regressions later.
3. **Triage.** Put every upstream commit in the range into exactly one group. A script does the path-based part. The agent does the judgment part and may move a commit to another group, with the reason.

   | Group | Meaning | How it is found |
   |---|---|---|
   | Comes along | shared code the Mac compiles as-is | default for `Conduit/`, `Shared/` paths not matched below |
   | iOS-only | compiles into the Mac but Mac never reaches it (CarPlay, Watch, Health, Live Activity, phone and location sync, iOS share extension, App Store scripts, iOS-only targets) | path list in the script; may still need R1 to R4 compile fixes |
   | Needs a Mac port | touches a file a ledger row names, a `keep in sync` marker source, a `// MAC:` region, or an `#if os(iOS)` region | ledger file paths, `grep -rn "keep in sync" ConduitMac`, diff hunks near `// MAC:` |
   | Gate off on Mac | a UI change the Mac must not show (V2 shell, V2 sheets, V2 chrome), or an item on the keep-off list | `Conduit/Views/V2/` paths, `V2`/`v2` identifiers in the hunks, keep-off list, agent judgment |
   | Needs a Mac entry point | a feature upstream reaches only from V2 (no legacy entry point), so V2-off hides it on Mac | for each new V2 route, menu item or sheet, check the legacy shell (`SidebarView`, `ChatView`, `AuxiliaryViews`, `RootView` non-V2 path) for another way in; agent judgment. The report lists each one for the user: Mac entry point, defer, or keep off |
   | Risk | a rename or deletion of a file in the ledger or in `project.yml` excludes; a new framework import (D3 overlay risk); a `project.yml` change; a new target | `git diff --name-status` D and R entries, new `import` lines, `project.yml` hunks |

   Each commit also gets a **rich content** tag when it changes how content from or to the agent is drawn or sent (cards, previews, markdown, images, tool rows, attachments, artifacts, media). The tag drives the live check list.
4. **Report.** Write `docs/macos/upstream-sync/YYYY-MM-DD.md`:
   - Range, counts per group, planned merge steps (the release-cut table above, computed fresh each run).
   - Per group: one line per commit (`sha  PR#  subject`), with the reason for any moved commit.
   - The list of Mac ports to do, each naming the upstream file and the Mac file.
   - The list of new gate-off items, each with the proposed `// MAC:` gate.
   - The live check list (from the rich content tags).
   - The baseline failures.
5. **Stop.** Show the user a summary of at most 5 lines (counts, top risks, the gate-off list) and the report path. Wait for approval. The user can move commits between groups or remove items from the keep-off list in the reply.

### Phase 2: merge (after approval)

6. **Worktree.** Create a worktree on branch `sync/upstream-YYYY-MM-DD` from `macos`.
7. **Step through the merge.** For each planned step (a release-cut `main` commit, then `upstream/main`): `git merge <commit>`. Then:
   - Resolve conflicts. Expected only at `// MAC:` lines, ledger files, `project.yml`, and `Conduit/Localizable.xcstrings` (use the JSON key merge script, see Constraints).
   - Do the Mac ports and the gate-offs for this step, each tagged `// MAC:` with a ledger row.
   - Build. On a Mac compile error apply R1, then R2, R3, R4 in that order.
   - Run the tests for the classes this step touched. Stop the run on a new failure and report the cause.
   - Commit the step.
8. **Full gate.** After the last step, in the main checkout and with no other agent building: the full `ConduitMac` suite (it includes `AccessibilityLabelAuditTests`), then `scripts/mac-verify-bundle.sh --archive` (call: catches widget-extension breakage, D25). Pass = every baseline-passing test still passes and the bundle verifier passes.
9. **Live check.** See "Live check" below.
10. **Land.** Fast-forward `macos` to the sync branch (no push). Remove the worktree, delete the branch and its scratch. Append the result (steps, ports, gates, live check, anything deferred) to the report and commit it. Tell the user the manual smoke items from `docs/macos/SMOKE_CHECKLIST.md` and the push command.

### When upstream changes behavior a Mac test checks

(call) A baseline-passing Mac test that fails because upstream intentionally changed the behavior it checks:

- **The test checks a Mac decision** (contrast ratios, density metrics, accessibility labels, window and toolbar behavior, D-numbered decisions): the test stays as it is. Mac code changes until it passes again.
- **The test checks a copy of upstream behavior** (for example a twin that copies upstream code, or an upstream layout rule the Mac only mirrors): update the test to the new upstream behavior. Add one line to the report: the test, the upstream commit, and the reason.
- **Not clear which kind:** treat it as a Mac decision, and list it in the report for the user.

### The keep-off list

A new section in `PORTING_LEDGER.md`, "Kept off on Mac". One row per upstream feature the Mac deliberately does not show: the feature, the gate (file and `// MAC:` line), the reason, and the date. Triage reads it so the same decision is not asked again. First row: the V2 shell (Part 2).

### When the skill stops early

- The user does not approve the report.
- A merge step has a conflict outside the expected places.
- A Risk item needs a choice only the user can make (for example a new required target).
- A baseline-passing test fails and the cause is not found after one focused attempt.

In each case the skill leaves the worktree in place, writes what it found to the report, and says which one thing the user must decide.

## Part 2: the 2.x merge (first run)

Run the skill. The parts below are specific to this run.

### V2 off on Mac

- Force `V2ShellPreference` to false on Mac with one `// MAC:` gate (R4) on `defaultValue` or on its use in `RootView`. Also hide or remove on Mac any Settings control that turns V2 on. The builder picks the narrowest gate.
- Any V2 view that replaced a legacy view outside the shell switch: keep the legacy view on Mac when upstream still has it; when upstream removed it, report it as a Risk item for the user.
- Add the keep-off ledger row.
- Pass: the merged Mac app looks the same as `macos` today in the sidebar, chat, composer, Settings and sheets.

### Rich content the Mac must support after the merge

From the agent:

1. Rich cards from `conduit_show`: map, place, places, stats, chart, weather, comparison, steps, media, contact, status (#752, #798).
2. HTML `::preview` charts in the reply, including the CSP and no-exfiltration rules (#587, #588, #777, #1011).
3. Mermaid and KaTeX (#777).
4. Web images in replies, Artifacts and pasted links, loaded within bounds (#892, #1010, #899).
5. Tool rows without raw JSON: plans, diffs, output, links (#1063, #1074).
6. Large code blocks that keep up while streaming (#894).
7. Chat tables with plain-text cells and Copy Table / Select Text (#693). iOS uses long press; the Mac equivalent is the builder's call (context menu is the expected answer).
8. Artifacts: all chats and one chat (#656), follows a server switch (#895), closing a file does not freeze (#722), missing files hidden with a toggle (#1068), media over 16 MB streams from `/api/fs/download` (#594). Upstream reaches Artifacts only from V2, so the Mac gets its own entry points (see "Artifacts on Mac").

### Artifacts on Mac

Upstream's only entry points are V2: `V2Route.artifacts` in `V2Shell.swift` (shows `V2ArtifactsPage`) and the V2 conversation "..." menu in `V2ConversationScreen.swift` (shows `ChatArtifactsSheet`). The list is `private struct ArtifactsList` in `Conduit/Views/V2/V2ArtifactsViews.swift`, which imports UIKit and draws `V2Backdrop`. The legacy shell has no entry point. User decision (2026-10-21):

- **All chats:** a new Mac sidebar pane, "Artifacts", routed through `MacDetailRouter` like Bots, Cron, Kanban and Home (D6, D24). It uses the Mac pane chrome (`MacPaneHeader`, `MacPaneTitle`) and density metrics.
- **One chat:** an "Artifacts" item in the chat's menu opens the same list filtered to that chat, as a sheet.
- **The list:** a Mac twin of upstream's `ArtifactsList` in the current Mac style, with no `V2Backdrop` or other V2 chrome. It reuses upstream's non-V2 model and services (`Conduit/Services/Artifacts.swift` and what it calls) unchanged. Twin rules apply: a `keep in sync` marker naming `V2ArtifactsViews.swift`, and a ledger row.
- Behavior matches upstream: a server switch reloads it (#895), closing a file does not freeze the app (#722), the Show Missing Files toggle (#1068), large media streams (#594).
- Accessibility labels, strings in all shipped languages, a sidebar shortcut if the existing tab shortcuts have a free slot (the builder's call), and tests, as for the other Mac panes.
- The "looks the same as today" pass test for V2-off allows this one new pane and menu item.

To the agent (regression check; the Mac already supports these): image paste, file drop and the attachment menu in the composer. New upstream send options (#966, long-press send for per-message delivery options) are triaged like any other commit; the Mac form is the builder's call.

### Live check

- **Prerequisite.** The user's Hermes host runs the Conduit Notifier plugin at the version the merged app recommends (`0.48.0` or newer). The skill reads the version from the app's Settings > Conduit plugin page. It asks the user before it updates the plugin or restarts the gateway.
- **Build under test.** A Debug build from the sync worktree. Confirm the running binary path before checking.
- **Method.** Drive the real app with the computer-use tools. In a new chat, send prompts that make Hermes produce each content type in the list above (for example, ask for a place card, a chart, a Mermaid diagram, an equation, an HTML preview, a large code block, a table). Check each in light and dark appearance.
- **Pass, per type.** It renders as designed. No raw JSON, no raw directive text, no empty box, no crash, no hang. Links open through the existing allowlist (R11). Save one screenshot per type under the worktree's `build/scratch/live-check/` and list the results in the report.
- A type that fails is fixed in the sync branch before landing, or reported as deferred with the reason. The user decides on a deferral.

## Decided by the user

- Both parts, in the order skill first, then the merge as its first run.
- No UI rework. V2 stays off on Mac.
- iOS-only features stay out.
- The skill stops after the evaluation and shows the list before any merge.
- After the merge, check each rich-content type in the real Mac app against the user's Hermes host.
- Artifacts gets a Mac sidebar pane (all chats) and a chat menu item (one chat), with a Mac-styled twin of upstream's list.

## Designer's calls

- Merge in release-cut steps (table above), not one jump.
- "Skip" is always a non-compile or a gate, never a left-out commit.
- No iOS Simulator build in the skill.
- The skill runs on demand only and never pushes.
- Deterministic triage in scripts; the agent judges only what needs reading.
- The report lives in `docs/macos/upstream-sync/` and is committed.
- `scripts/mac-verify-bundle.sh --archive` is part of the full gate.
- Which Mac tests may be updated when upstream changes behavior (see "When upstream changes behavior a Mac test checks").
- A new triage group, "Needs a Mac entry point", for V2-only features, so later runs ask instead of silently hiding them.

## Left to the builder

- The exact gate for V2 (preference default, `RootView` use, or both) and how to hide a V2 Settings control.
- The iOS-only path list and the triage script's language (Python fits `scripts/`).
- The Mac form of table copy and per-message send options.
- The prompts used in the live check.
- How to present Risk items that need a user choice.
