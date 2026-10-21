---
name: upstream-sync
description: Use when merging new kaishi00/hermes-conduit (upstream) commits into the macos branch, or when asked to evaluate, sync or adopt upstream Conduit updates.
---

# Upstream sync

This skill merges `kaishi00/hermes-conduit` (remote `upstream`) into the `macos` branch. It covers the Mac app (`ConduitMac`) only. Run it from the main checkout. The reference for the manual routine is "Sync routine" in `docs/macos/PORTING_LEDGER.md`.

**Rules.**

- Phase 1 changes no code. Phase 2 starts only after the user approves the report.
- Merge every upstream commit in the range. Do not cherry-pick. Do not merge part of a range.
- "Skip" means "not compiled on Mac" or "gated off on Mac". "Skip" never means "not merged".
- Never push to `origin`. Never cut a release.
- Do not build for the iOS Simulator. Only the Mac app ships.
- Tag every upstream edit `// MAC:`. Add a row for it in `docs/macos/PORTING_LEDGER.md`.
- Never re-sort keys in `Conduit/Localizable.xcstrings` or `Conduit/AppShortcuts.xcstrings`.
- Write status lines in ASD-STE100 strict mode. Write the report in STE-flavored mode. Use ASCII only.

**Terms.**

- `<date>` is today's date, `YYYY-MM-DD`.
- The scratch folder is `build/scratch/upstream-sync/`. Each worktree has its own.
- The full suite command is:
  `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO`
- The class command is the full suite command with `-only-testing:'ConduitMacTests/<Class>'` added at the end.
- The build command is the full suite command with `build` in place of `test`.
- Save a log with `2>&1 | tee <log>`. Do not use the exit code of that pipe. Read the log with the parse command.
- Run `xcodegen generate` before any of these commands when `project.yml` or the set of files changed. Run it also in a new worktree.
- The parse command is `python3 scripts/upstream-sync/mac-test-failures.py parse <log> -o <out>.json`. It prints `result=<R> passed=<N> failed=<N>`.
- The compare command is `python3 scripts/upstream-sync/mac-test-failures.py compare <baseline>.json <current>.json`. Exit 0 means no new failure. Exit 1 means it prints each new failing test.
- **Gate rule.** A parsed test run with `result` UNKNOWN, or with `passed` 0, is a gate FAILURE. This holds even when `compare` exits 0. A run that crashed or never started parses to no failures.
- `MacToolbarRealWindowTests` and `PhoneScenePresenceMacTests` fail at random under load. Rerun a failed class once before you call a failure a regression.

## Preflight

1. Run `git status --porcelain`. Pass = no output.
2. Run `git branch --show-current`. Pass = it prints `macos`.
3. Run `git fetch upstream --tags`. Pass = exit 0.
4. Run `git rev-parse upstream/main`. Pass = it prints one SHA. Keep the SHA. It is the pinned head.
5. Run `df -h .`. Read the free space in the `Avail` column. Stop if it is under 20 GB. Tell the user.
6. Run `git merge-base macos upstream/main`. Pass = it prints one SHA. Keep the SHA.
7. Run `mkdir -p build/scratch/upstream-sync`.

## Phase 1: Evaluate

1. **Baseline.**
   1. Run `xcodegen generate`. Pass = exit 0.
   2. Run the full suite command with `2>&1 | tee build/scratch/upstream-sync/baseline.log`.
   3. Run the parse command on that log with `-o build/scratch/upstream-sync/baseline.json`. Pass = the Gate rule holds. If it does not hold, the baseline is not valid. Stop and tell the user the log path.
   4. Run the class command for each class in `failed_classes`. Save each log as `build/scratch/upstream-sync/baseline-rerun-<Class>.log`. Parse each log. A rerun that breaks the Gate rule is not a pass.
   5. A test that passes on the rerun is a flake. Delete it from the baseline file. To do this, delete the test from `failed`. Delete its class from `failed_classes` when no failed test of that class remains.
2. **Triage.** Run:
   `python3 scripts/upstream-sync/triage.py --repo . --mac-ref macos --head upstream/main --baseline build/scratch/upstream-sync/baseline.json --json build/scratch/upstream-sync/triage.json --report docs/macos/upstream-sync/<date>.md`
   1. Pass = exit 0, and the report file exists.
   2. Read `steps` in `build/scratch/upstream-sync/triage.json`. Each step has `label`, `sha` and `count`. The `sha` is a full SHA. Pass = `steps[-1].sha` equals the pinned head. If it does not, stop and tell the user.
   3. Pin the head in the report. In the "Merge steps" table, the last row can show `-` in the Commit column. Replace the `-` with the first 8 characters of the pinned head. Add the line `Pinned head: upstream/main = <full pinned head>` under the table.
3. **Judge by reading.** Run `git show <sha>` for each commit in Gate off, Risk, and Needs a Mac entry point. Move a commit only with a written reason. Write the reason on the commit's line in the report.
   - For each Needs a Mac port commit, add the Mac file to its line. Take it from the "Mac side" column of the matching ledger row, or from the `keep in sync` marker's file.
   - For each new V2 route, menu item or sheet, look for a legacy entry point. Look in `SidebarView`, `ChatView`, `AuxiliaryViews` and the non-V2 path of `RootView`. With none, the commit goes under "Needs a Mac entry point" for the user.
   - Find the UI changes that upstream made in legacy views without the V2 switch. Examples are `V2RowDivider`, `.v2TabBarClearance()`, `.v2EdgeBar`, and new `Conduit/Views/Login/` screens. List them under "Decisions for the user", each with a proposed gate.
4. **Stop.** Show a summary of at most 5 lines and the report path. Do not merge until the user approves.
   - Approval counts only after the user sees the report. A message that comes before the report exists is not approval, even when it says "go".
   - If the user says "go" early, finish items 1 to 3, write the report, show the summary, and then stop.
   - Write the user's answers into the report. This includes each move of a commit between groups.

## Phase 2: Merge

Start only after the user approves the report. Run the commands in the main checkout until item 2.

1. Commit the report on `macos`, so that the worktree has it:
   1. Run `git add docs/macos/upstream-sync/<date>.md`.
   2. Run `git commit -m "docs(mac): upstream sync evaluation <date>"`. End the message with `Co-Authored-By: Claude <noreply@anthropic.com>`.
2. Create the worktree. Run `git worktree add .worktrees/sync-upstream-<date> -b sync/upstream-<date> macos`. The worktree is `.worktrees/sync-upstream-<date>`, on branch `sync/upstream-<date>`.
   1. Go into the worktree. Run all later commands there.
   2. Run `mkdir -p build/scratch/upstream-sync`.
   3. Copy `baseline.json` and `triage.json` from the main checkout's `build/scratch/upstream-sync/` to the same folder in the worktree.
   4. Run `xcodegen generate`.
3. Merge each step in `steps` of `build/scratch/upstream-sync/triage.json`. Go from the first step to the last step. For each merge step, do these items in order.
   - Take the full SHA of each step from `steps[].sha`. Do not take it from the "Merge steps" table. The last row of that table can show `-`.
   - The last step is the pinned head. Its `sha` is the pinned `upstream/main`. Merge that SHA. Never merge the name `upstream/main`.
   - The number `<n>` of a merge step is its place in `steps`, counted from 1.
   1. Run `git merge --no-ff <step sha> -m "merge: upstream <label>"`. If it exits 0, go to item 6. If it reports conflicts, do items 2 to 5.
   2. Run `git diff --name-only --diff-filter=U`. The expected places for a conflict are only these:
      - lines tagged `// MAC:` in upstream files (under `Conduit/`, `Shared/` or `ConduitWidgets/`)
      - `docs/macos/PORTING_LEDGER.md`
      - `project.yml`
      - `Conduit/Localizable.xcstrings` and `Conduit/AppShortcuts.xcstrings`

      A conflict in any other file, or in any other part of a file, is outside the expected places. Stop early.

      Upstream has no `ConduitMac/` or `ConduitMacTests/` folder. A conflict in a file under those folders is always outside the expected places. Do not try to resolve it.
   3. For a conflict in a `// MAC:` line, keep the Mac lines and take the upstream lines around them.
   4. For a catalog conflict, with `<p>` as the catalog path:
      1. Run `git show :1:<p> > build/scratch/upstream-sync/base.json`. If it fails, leave `base.json` empty.
      2. Run `git show :2:<p> > build/scratch/upstream-sync/ours.json`.
      3. Run `git show :3:<p> > build/scratch/upstream-sync/theirs.json`.
      4. Run `python3 scripts/upstream-sync/merge-xcstrings.py build/scratch/upstream-sync/base.json build/scratch/upstream-sync/ours.json build/scratch/upstream-sync/theirs.json -o <p>`.
      5. Exit 0 means the catalog merged clean. Exit 1 means it printed one conflict path per line. The file `<p>` holds "ours" at each of those paths.
      6. On exit 1, resolve each printed path by hand, preferring upstream for translations of upstream-owned keys. Edit only the lines at that path. Do not re-sort keys.
      7. Run `python3 -c "import json,sys; json.load(open(sys.argv[1]))" <p>`. Pass = exit 0.
   5. Run `git add` for each resolved file. Run `git grep -n '^<<<<<<< '`. Pass = no output. Then run `git commit --no-edit`.
   6. Run the build command. Pass = the output has `** BUILD SUCCEEDED **`. On a Mac compile error, apply rules R1 to R4 in order. See `docs/macos/DECISIONS.md` D1 to D4.
      - R1: add the missing member to a shim. Shims expose only members that upstream uses.
      - R2: exclude the file and twin it under `ConduitMac`.
      - R3: gate one type with `#if os(iOS)` and add a Mac twin.
      - R4: gate one statement.
   7. Do the Mac ports and gate-offs that the report lists for this merge step. Each upstream edit gets a `// MAC:` tag and a ledger row. Each gate-off also gets a row in `## Kept off on Mac`. Put the upstream path in column 1 of that row.
   8. Test only the classes this merge step touched. These are the `ConduitMacTests` classes for the Mac files you changed or ported in this merge step and the files you resolved in conflicts. Add each test class you wrote. Find a class with `grep -rl '<Type>' ConduitMacTests`.
      1. For each class, run the class command. Save the log as `build/scratch/upstream-sync/step-<n>-<Class>.log`. Here `<n>` is the number of the merge step.
      2. Run the parse command on each log. Run the compare command with `baseline.json` and each parsed file. Pass = exit 0 and the Gate rule holds.
      3. On a new failure, rerun the class once. If it still fails, follow "Test-change rule". If you find no cause after one focused attempt, stop early. One focused attempt is one read of the failure, one fix and one rerun.
   9. Commit the fixes of this merge step. Use the prefix `fix(mac):`, `feat(mac):` or `test(mac):`. End the message with `Co-Authored-By: Claude <noreply@anthropic.com>`. If you changed nothing after the merge commit, there is nothing to commit.

## Test-change rule

A baseline-passing Mac test that fails because upstream intentionally changed the behavior it checks:

- **The test checks a Mac decision** (contrast ratios, density metrics, accessibility labels, window and toolbar behavior, D-numbered decisions): the test stays as it is. Mac code changes until it passes again.
- **The test checks a copy of upstream behavior** (for example a twin that copies upstream code, or an upstream layout rule the Mac only mirrors): update the test to the new upstream behavior. Add one line to the report: the test, the upstream commit, and the reason.
- **Not clear which kind:** treat it as a Mac decision, and list it in the report for the user.

A baseline-passing Mac test can also fail because of a Mac change that you made on purpose and that the user approved. An example is a new Mac sidebar tab with a new key. That change changes a Mac decision. Update the test only together with that Mac change, in the same commit. Add one line to the report: the test, the Mac change, and the reason.

## Full gate

Run these in the sync worktree. No other agent can build at the same time.

1. Run `xcodegen generate`. Run the full suite command with `2>&1 | tee build/scratch/upstream-sync/final.log`.
2. Run the parse command with `-o build/scratch/upstream-sync/final.json`. Run the compare command with `baseline.json` and `final.json`. Pass = exit 0 and the Gate rule holds.
3. For each class that `compare` lists, rerun the class once. If it still fails, follow "Test-change rule". If `AccessibilityLabelAuditTests` fails, follow step 5 of "Sync routine" in `docs/macos/PORTING_LEDGER.md`.
4. Run `scripts/mac-verify-bundle.sh --archive`. Pass = exit 0, with every check line printing `ok:`.

## Live check

- **Prerequisite.** The user's Hermes host runs the Conduit Notifier plugin at the version the merged app recommends (`0.48.0` or newer). The skill reads the version from the app's Settings > Conduit plugin page. It asks the user before it updates the plugin or restarts the gateway.
- **Build under test.** A Debug build from the sync worktree. Confirm the running binary path before checking.
- **Method.** Drive the real app with the computer-use tools. In a new chat, send prompts that make Hermes produce each content type in the prompt list below (for example, ask for a place card, a chart, a Mermaid diagram, an equation, an HTML preview, a large code block, a table). Check each in light and dark appearance.
- **Pass, per type.** It renders as designed. No raw JSON, no raw directive text, no empty box, no crash, no hang. Links open through the existing allowlist (R11). Save one screenshot per type under the worktree's `build/scratch/live-check/` and list the results in the report.
- A type that fails is fixed in the sync branch before landing, or reported as deferred with the reason. The user decides on a deferral.

Do these items:

1. Load the `agent-desktop` skill. Use it to drive the app.
2. Start the Debug app from the worktree: `build/dd/Build/Products/Debug/Conduit.app`.
3. Run `ps -o pid,lstart,comm -p $(pgrep -x Conduit)`. Pass = the `comm` path is under the worktree's `build/dd/`. If the app runs from another path (for example `/Volumes/Conduit`), quit it and start the right build.
4. Open Settings > Conduit plugin. Read the installed and recommended plugin versions. If the installed version is lower, stop and ask the user.
5. In a new chat, send these prompts. Send one prompt for each type. Name the screenshot `build/scratch/live-check/<type>-<light|dark>.png`.
   - `place-card`: "Show me a place card for the Ferry Building in San Francisco."
   - `chart-card`: "Make a bar chart card of these numbers: 3, 7, 5."
   - `mermaid`: "Draw a mermaid flowchart with three steps."
   - `katex`: "Write the quadratic formula in LaTeX."
   - `html-preview`: "Write an HTML file with an SVG chart and show it with ::preview."
   - `table`: "Reply with a markdown table of 3 rows and 3 columns."
   - `code-block`: "Print a 300-line Swift file in one code block."
   - `web-image`: "Read a web page and include one of its images."
   - `tool-row`: "Run a shell command that lists a directory."
6. Check each reply in light and then in dark appearance. Change the appearance in System Settings. Restore the original setting when you finish.
7. Fix each failed type in the sync branch. Write a test first when a test can show the cause. Then rerun the check for that type. Record a type you cannot fix as deferred, with the reason, under "Decisions for the user". Ask the user.

## Land

Run these items after the Full gate and the Live check pass.

1. In the worktree, append the results to the report. Add the merge steps and the ports and gates (each with its ledger row). Add each test you changed and why. Add the gate results, the live-check table (type, light, dark, result) and anything deferred.
2. Run `git add docs/macos/upstream-sync/<date>.md`. Run `git commit -m "docs(mac): upstream sync report <date>"`. End the message with `Co-Authored-By: Claude <noreply@anthropic.com>`.
3. Find the main checkout. It is the first path that `git worktree list` prints.
4. Run `git -C <main checkout> merge --ff-only sync/upstream-<date>`. Pass = exit 0. If it fails, another commit may be on `macos`. Stop early.
5. In the main checkout, delete the worktree and its scratch:
   1. Run `git worktree remove .worktrees/sync-upstream-<date>`. Do not use `--force`.
   2. Run `git branch -d sync/upstream-<date>`.
   3. Delete `build/scratch/upstream-sync`.
   4. Pass = `git worktree list` does not show the worktree, and `git branch --list 'sync/upstream-<date>'` prints nothing.
6. Run `grep -n '^## ' docs/macos/SMOKE_CHECKLIST.md`. Print the names of the sections to run. Choose the sections for the areas this merge changed. Always add "Release gate".
7. Print the push command `git push origin macos`. Do not run the push.

## Stop early when

- The user does not approve the report.
- A merge step has a conflict outside the expected places.
- A Risk item needs a choice only the user can make (for example a new required target).
- A baseline-passing test fails and the cause is not found after one focused attempt.

In each case, do these items:

1. Leave the worktree in place. Do not delete it. If no worktree exists yet, skip this item.
2. Write what you found to the report. Use the report in the worktree if there is one. Otherwise use the report in the main checkout.
3. Name the one decision that the user must make.
4. Do not continue the merge.
