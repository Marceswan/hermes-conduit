# Upstream Sync Skill and Conduit 2.x Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repo skill, `/upstream-sync`, that evaluates and merges `kaishi00/hermes-conduit` into the `macos` branch behind an approval stop and regression gates. Then use it to merge upstream 2.0 to 2.2, so the Mac app renders all of upstream's rich content, with V2 off and a new Mac Artifacts pane.

**Architecture:**
- **Part 1 (Tasks 1-5)** adds three stdlib-only Python scripts under `scripts/upstream-sync/` and one skill file:
  - `triage.py` sorts upstream commits into groups and plans the merge steps.
  - `merge-xcstrings.py` does a three-way, key-by-key catalog merge.
  - `mac-test-failures.py` reads xcodebuild logs and finds regressions.
  - `.claude/skills/upstream-sync/SKILL.md` puts them in order with the porting rules.
- **Part 2 (Tasks 6-15)** is the skill's first run, done in a worktree:
  - Evaluate and stop for approval.
  - Merge in five release steps.
  - Re-port the twins, adapt rich content for the Mac, and add the Artifacts pane and the chat-menu sheet.
  - Run the full gate and the live check, then land.

**Tech Stack:** Python 3.9+ stdlib with `unittest`. Swift 5.9, SwiftUI and AppKit, macOS 14 deployment target. XCTest. xcodegen. git.

**Spec:** `docs/superpowers/specs/2026-10-21-upstream-sync-and-2x-merge-design.md`

## Global Constraints

- **Mac scope:**
  - Target: the macOS app only (`ConduitMac`). iOS is unchanged. No iOS Simulator build anywhere.
  - Porting rules R1 to R4 and decisions D1 to D4 hold (`docs/macos/DECISIONS.md`). Every upstream edit is tagged `// MAC:` and gets a row in `docs/macos/PORTING_LEDGER.md`.
- **Merging:**
  - "Skip" means "not compiled on Mac" or "gated off on Mac", never "not merged". No cherry-picks and no partial merges.
  - Never push to `origin`. Never cut a release.
  - `Conduit/Localizable.xcstrings` and `Conduit/AppShortcuts.xcstrings` are merged key by key with "ours" key order, written as `json.dumps(obj, indent=2, separators=(",", " : "), ensure_ascii=False) + "\n"`. Never re-sort keys.
- **Python:** scripts are stdlib only and Python 3.9 safe: `from __future__ import annotations`, no `match`, `#!/usr/bin/env python3`, `main(argv=None)` plus `sys.exit(main())`. Tests are `unittest`, loaded with `scripts/tests/_util.py` `load_module(name, "upstream-sync/<file>.py")`.
- **Commands:**
  - Python tests: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_*.py'`
  - Mac test, one class: `xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO -only-testing:'ConduitMacTests/<Class>'`. Run `xcodegen generate` first whenever `project.yml` or the file set changed.
  - Full Mac suite: the same command without `-only-testing`, run in the main checkout or the sync worktree with no other agent building.
- **Worktrees and parallel agents:**
  - Worktrees go under `.worktrees/`, which is git-ignored. `.claude/worktrees/` is not ignored.
  - Each agent keeps scratch in its own worktree's `build/scratch/`.
  - `MacToolbarRealWindowTests` and `PhoneScenePresenceMacTests` flake under load. Rerun the failed class once before calling it a regression.
  - Check `df -h` before parallel worktree agents. If free space is under about 20 GB, prune first.
- **Text:**
  - Strings shown to the user exist in all 13 shipped languages in `Conduit/Localizable.xcstrings`.
  - Skill instructions and status lines use ASD-STE100 strict mode. Reports use STE-flavored mode. ASCII only.
- **Commits:** prefixes are `feat(mac):`, `fix(mac):`, `docs(mac):`, `chore(mac):`, `test(mac):` and `merge:`. The trailer is `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Review Focus

1. **An agent HTML preview tries to reach the network** (a `fetch`, or a script-driven navigation to an http(s) URL). On the Mac twin, the request is blocked by upstream's CSP and upstream's `HTMLPreviewPage.navigationDecision`, exactly as on iOS (#777). A user link click opens externally only through the R11 allowlist. Test: Task 10 `MacHTMLPreviewPolicyTests`.
2. **The host plugin is too old or lacks the `artifacts` capability.** The Artifacts pane shows upstream's "update the plugin" state. It does not show an error, an empty list or an endless spinner. Test: Task 12 `MacArtifactsPaneTests.testUnsupportedPluginShowsUpdateState`.
3. **A dashboard or server switch while the Artifacts pane is open.** No row from the previous server stays visible (#895, `ArtifactsListKey.showsRows(of:)`). Test: Task 12 `MacArtifactsPaneTests.testDashboardSwitchDropsOtherServerRows`.
4. **Both sides changed one string's translation in different ways.** `merge-xcstrings.py` reports the conflict and exits 1. It does not drop either side without a report. Test: Task 3 `test_conflicting_translation_reported`.
5. **"Show in Chat" from the Artifacts pane while that chat is not open.** The chat opens, the router returns to chat, and the transcript scrolls to the message (`AppState.showArtifactInChat(_:chatIsOpen:)`, `pendingArtifactReveal`). Test: Task 12 `MacArtifactsPaneTests.testShowInChatFromPaneOpensSessionAndReturnsToChat`.

---

## Part 1: the `upstream-sync` skill

Do Tasks 1 to 5 in the worktree `.worktrees/upstream-sync-skill` on branch `feat/upstream-sync-skill`, created from `macos`. After the Task 5 review, fast-forward `macos` to it, then remove the worktree and the branch.

### Task 1: Triage classification core

**Files:**
- Create: `scripts/upstream-sync/triage.py`
- Test: `scripts/tests/test_upstream_triage.py`

**Interfaces:**
- Produces (all in `triage.py`):
  - `GROUPS = ("risk", "mac-port", "gate-off", "ios-only", "comes-along")`: the precedence order. A commit's group is the first group any rule matches.
  - `GROUP_TITLES: dict[str, str]`: `{"risk": "Risk", "mac-port": "Needs a Mac port", "gate-off": "Gate off on Mac", "ios-only": "iOS-only or no Mac effect", "comes-along": "Comes along"}`.
  - `@dataclass Commit`: `sha: str`, `subject: str`, `pr: int | None`, `files: list[tuple[str, str]]` (git status letter and path; for a rename the path is the old path), `added_imports: list[tuple[str, str]]` (path and framework), `group: str = ""`, `reasons: list[str] = field(default_factory=list)`, `rich: bool = False`, `new_v2_surface: bool = False`.
  - `@dataclass Context`: `ledger_patterns: list[str]`, `mac_excludes: list[str]`, `sync_basenames: set[str]`, `mac_marker_files: set[str]`, `keep_off_patterns: list[str]`.
  - `parse_pr(subject: str) -> int | None`: the last `(#N)` in the subject.
  - `parse_ledger_paths(text: str) -> list[str]`: upstream path patterns from column 1 of every table row.
  - `parse_keep_off_patterns(text: str) -> list[str]`: column 1 paths of the table under `## Kept off on Mac`. Returns `[]` when the section is missing.
  - `parse_mac_excludes(project_yml: str) -> list[str]`: the `excludes` of the `path: Conduit` source of target `ConduitMac`, each prefixed `Conduit/`.
  - `parse_sync_basenames(marker_lines: list[str]) -> set[str]`: the `<Name>.swift` file names that the `keep in sync` marker lines name.
  - `matches(path: str, patterns: list[str]) -> bool`: `fnmatch` for patterns with `*`; otherwise an exact match or a directory prefix.
  - `classify(commit: Commit, ctx: Context) -> Commit`: sets `group`, `reasons`, `rich` and `new_v2_surface`, and returns the same object.
  - `IOS_ONLY_PREFIXES: tuple[str, ...]` and `RISK_FRAMEWORKS: frozenset[str]`: values in Step 3.

- [ ] **Step 1: Write the failing tests**

```python
"""Regression coverage for scripts/upstream-sync/triage.py (classification)."""
import unittest
from _util import load_module
t = load_module("upstream_triage", "upstream-sync/triage.py")

LEDGER = """| File | Rule | Reason | Mac side |
|---|---|---|---|
| Conduit/Views/RootView.swift `MainView` chat chrome | R4 | x | y |
| Conduit/Services/AppState.swift `requestOpenSession`, `openBotChat` | R4 | x | y |
| ConduitWidgets/*, Shared/Widgets/*, Conduit/Localizable.xcstrings | shared source | x | y |
| Menu: Find in Chat (Cmd-F) | done | x | y |
| ConduitMac/Compat/App/FormShim.swift (new; no upstream file edited) | R1-style | x | y |

## Kept off on Mac

| Feature | Gate | Reason | Date |
|---|---|---|---|
| Conduit/Views/V2/ | V2Shell.swift `defaultValue` | no UI rework | 2026-10-21 |
"""
PROJECT = """targets:
  ConduitMac:
    type: application
    sources:
      - path: ConduitMac
        excludes:
          - "Compat/Module/**"
      - path: Shared
      - path: Conduit
        excludes:
          - "ConduitApp.swift"
          # comment
          - "Views/Components/SelectableTextView.swift"
    settings:
      base:
        PRODUCT_NAME: Conduit
  ConduitMacTests:
    sources:
      - path: Conduit
        excludes:
          - "Nope.swift"
"""

def ctx(**kw):
    base = dict(ledger_patterns=t.parse_ledger_paths(LEDGER), mac_excludes=t.parse_mac_excludes(PROJECT),
                sync_basenames={"MarkupBlock.swift"}, mac_marker_files={"Conduit/Views/SidebarView.swift"},
                keep_off_patterns=t.parse_keep_off_patterns(LEDGER))
    base.update(kw)
    return t.Context(**base)

def commit(files, subject="x (#1)", imports=()):
    return t.Commit(sha="a" * 40, subject=subject, pr=t.parse_pr(subject), files=list(files), added_imports=list(imports))

class ParseTests(unittest.TestCase):
    def test_parse_pr_takes_last(self):
        self.assertEqual(t.parse_pr("Carry #843 (#924)"), 924)
        self.assertIsNone(t.parse_pr("no number"))
    def test_ledger_paths_only_upstream(self):
        p = t.parse_ledger_paths(LEDGER)
        self.assertIn("Conduit/Views/RootView.swift", p)
        self.assertIn("Conduit/Services/AppState.swift", p)
        self.assertIn("ConduitWidgets/*", p)
        self.assertIn("Shared/Widgets/*", p)
        self.assertNotIn("ConduitMac/Compat/App/FormShim.swift", p)
        self.assertFalse(any(x.startswith("Menu") for x in p))
    def test_keep_off(self):
        self.assertEqual(t.parse_keep_off_patterns(LEDGER), ["Conduit/Views/V2/"])
        self.assertEqual(t.parse_keep_off_patterns("| a | b |"), [])
    def test_mac_excludes_only_conduitmac_conduit_source(self):
        self.assertEqual(t.parse_mac_excludes(PROJECT),
                         ["Conduit/ConduitApp.swift", "Conduit/Views/Components/SelectableTextView.swift"])
    def test_sync_basenames(self):
        lines = ["ConduitMac/WebViews/WebViewTwins.swift:17:// keep in sync with MarkupBlock.swift `MarkupMessageProxy`",
                 "ConduitMac/App/ConduitMacApp.swift:92:// Ported from ConduitApp.swift; keep in sync"]
        self.assertEqual(t.parse_sync_basenames(lines), {"MarkupBlock.swift", "ConduitApp.swift"})

class ClassifyTests(unittest.TestCase):
    def test_precedence_risk_over_port(self):
        c = t.classify(commit([("M", "project.yml"), ("M", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "risk")
    def test_rename_of_ledger_file_is_risk(self):
        c = t.classify(commit([("R", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "risk")
    def test_risky_import_in_mac_compiled_file(self):
        c = t.classify(commit([("A", "Shared/Widgets/HermesTurnActivity.swift")],
                              imports=[("Shared/Widgets/HermesTurnActivity.swift", "ActivityKit")]), ctx())
        self.assertEqual(c.group, "risk")
    def test_risky_import_in_ios_only_target_is_not_risk(self):
        c = t.classify(commit([("A", "ConduitWatch/Foo.swift")], imports=[("ConduitWatch/Foo.swift", "HealthKit")]), ctx())
        self.assertEqual(c.group, "ios-only")
    def test_ledger_marker_and_sync_files_are_ports(self):
        for path in ("Conduit/Views/RootView.swift", "Conduit/Views/SidebarView.swift",
                     "Conduit/Views/Components/MarkupBlock.swift", "Conduit/Views/Components/SelectableTextView.swift"):
            self.assertEqual(t.classify(commit([("M", path)]), ctx()).group, "mac-port", path)
    def test_v2_is_gate_off_and_new_file_flags_surface(self):
        c = t.classify(commit([("A", "Conduit/Views/V2/V2ArtifactsViews.swift")]), ctx())
        self.assertEqual(c.group, "gate-off")
        self.assertTrue(c.new_v2_surface)
    def test_port_beats_gate_off(self):
        c = t.classify(commit([("M", "Conduit/Views/V2/V2Shell.swift"), ("M", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "mac-port")
    def test_ios_only_needs_every_file(self):
        self.assertEqual(t.classify(commit([("M", "ConduitTests/A.swift"), ("M", "docs/x.md")]), ctx()).group, "ios-only")
        self.assertEqual(t.classify(commit([("M", "ConduitTests/A.swift"), ("M", "Conduit/Models/X.swift")]), ctx()).group, "comes-along")
    def test_rich_by_path_or_subject(self):
        self.assertTrue(t.classify(commit([("M", "Conduit/Cards/RichCard.swift")]), ctx()).rich)
        self.assertTrue(t.classify(commit([("M", "Conduit/Models/X.swift")], subject="Chat tables: Copy Table (#693)"), ctx()).rich)
        self.assertFalse(t.classify(commit([("M", "Conduit/Voice/X.swift")], subject="Voice timers (#1)"), ctx()).rich)
    def test_every_commit_gets_a_reason(self):
        c = t.classify(commit([("M", "Conduit/Models/X.swift")]), ctx())
        self.assertEqual(c.group, "comes-along")
        self.assertTrue(c.reasons)
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_triage.py' -v`
Expected: an error, because `scripts/upstream-sync/triage.py` does not exist.

- [ ] **Step 3: Implement the parsers, `matches` and `classify` in `scripts/upstream-sync/triage.py`**

- **`parse_ledger_paths`:** for each line that starts with `|` and is not the header or separator row, take column 1. Remove backticked spans. Split on `,` and ` + `. Keep the first whitespace-separated token of each piece. Keep a token only if it starts with `Conduit/`, `Shared/` or `ConduitWidgets/` (`ConduitMac/` tokens are Mac-side). Stop at the `## Kept off on Mac` heading.
- **`parse_keep_off_patterns`:** the same column-1 rule, applied only to table rows after `## Kept off on Mac`.
- **`parse_mac_excludes`:** line-based, with no YAML library. Find the line `  ConduitMac:` (two-space indent). Inside that block, which ends at the next line with exactly two-space indent and a trailing `:`, find `- path: Conduit`. Collect the quoted strings of the `- "..."` lines under its `excludes:` until the next `- path:` or a dedent. Skip `#` comment lines.
- **`parse_sync_basenames`:** the regex `([A-Za-z0-9_+]+\.swift)`. Drop the file part of the leading `path:line:` prefix.
- **`IOS_ONLY_PREFIXES`:**
  - Test, extension, Watch and tooling targets: `ConduitTests/`, `ConduitUITests/`, `ConduitWatch/`, `ConduitShareExtension/`, `ConduitLocationPush/`, `ConduitScreenshots/`, `ConduitNotificationService/`, `scripts/app-store/`, `.github/`, `project-tests.yml`.
  - Docs and repo files: `docs/`, `README.md`, `opencode.json`.
  - iOS feature directories: `Conduit/CarPlay/`, `Conduit/Watch/`, `Shared/WatchVoice/`, `Conduit/Health/`, `Conduit/Phone/`, `Conduit/Location/`, `Shared/Location/`, `Shared/ShareDraft/`.
  - Single files: `Conduit/Views/CarPlaySettingsSection.swift`, `Conduit/Views/HealthSettingsViews.swift`, `Conduit/Views/PhoneSettingsViews.swift`, `Conduit/Views/LocationSettingsViews.swift`, `Conduit/Services/AppState+HealthSync.swift`, `Conduit/Services/AppState+PhoneSync.swift`, `Conduit/Services/AppState+Location.swift`, `Conduit/Services/AppState+ShareDraft.swift`, `ConduitWidgets/HermesTurnLiveActivity.swift`, `Conduit/Services/LiveTurnActivities.swift`, `Conduit/Services/LiveActivityUpdateThrottle.swift`, `Conduit/Services/ScreenshotCallFixture.swift`.
- **`RISK_FRAMEWORKS`:** `ActivityKit, HealthKit, CarPlay, BackgroundTasks, AlarmKit, ContactsUI, VisionKit, MetricKit, PushKit, CallKit, WatchConnectivity, CoreTelephony, MessageUI, FamilyControls, DeviceActivity, ManagedSettings`.
- **"Compiled on Mac":** a path is compiled on Mac when it is under `Conduit/` or `Shared/` and does not match `mac_excludes`, or when it is under `ConduitWidgets/` or `Shared/Widgets/` (`ConduitMacWidgets`).
- **`classify` rules, in precedence order.** The first match wins. Every rule that matches also appends its reason, so the report shows them all.
  1. **risk:** `project.yml` was touched; or the status is D or R and the path matches `ledger_patterns`, `mac_excludes` or `mac_marker_files`; or an added import is in `RISK_FRAMEWORKS` and its path is compiled on Mac.
  2. **mac-port:** a path matches `ledger_patterns` or `mac_excludes`, or is in `mac_marker_files`, or its basename is in `sync_basenames`.
  3. **gate-off:** a path is under `Conduit/Views/V2/` or matches `keep_off_patterns`. Set `new_v2_surface` when the status is `A` under `Conduit/Views/V2/`.
  4. **ios-only:** every path matches `IOS_ONLY_PREFIXES`.
  5. **comes-along:** everything else. The reason is "shared code; the Mac compiles it".
- **`rich`:** set when any path starts with `Conduit/Cards/`, `Conduit/Views/Components/MarkdownText`, `Conduit/Views/Components/MarkupBlock`, `Conduit/Views/Components/HTMLPreview`, `Conduit/Views/Components/BoundedRemoteImage`, `Conduit/Views/Components/MediaPreview`, `Conduit/Views/Components/ComposerBar`, `Conduit/Services/Artifacts`, `Conduit/Services/AppState+Artifacts`, `Conduit/Services/GatewayMedia` or `Conduit/Services/DashboardFileDownload`. Also set it when the subject matches `(?i)\b(cards?|preview|markdown|mermaid|katex|images?|pictures?|photos?|attach\w*|artifacts?|media|tool rows?|tables?|code blocks?|files?|charts?)\b`.

- [ ] **Step 4: Run the tests and see them pass**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_triage.py' -v`
Expected: all tests in `ParseTests` and `ClassifyTests` pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/upstream-sync/triage.py scripts/tests/test_upstream_triage.py \
  docs/superpowers/specs/2026-10-21-upstream-sync-and-2x-merge-design.md \
  docs/superpowers/plans/2026-10-21-upstream-sync-and-2x-merge.md
git commit -m "feat(mac): upstream triage classifier for the sync skill"
```

### Task 2: Triage git collection, release steps and report

**Files:**
- Modify: `scripts/upstream-sync/triage.py`
- Test: `scripts/tests/test_upstream_triage_git.py`

**Interfaces:**
- Consumes: Task 1 `Commit`, `Context`, `classify`, the parsers and `GROUPS`.
- Produces:
  - `Git = Callable[[list[str]], str]`, and `run_git(repo: str) -> Git`. The returned callable runs `git -C repo <args>` and returns stdout. It raises `RuntimeError` on a non-zero exit, with one exception: `git grep` exiting 1 means "no match", so it returns `""`.
  - `@dataclass Step`: `label: str`, `sha: str`, `count: int`.
  - `collect_commits(git: Git, base: str, head: str) -> list[Commit]`: oldest first, with `--no-merges`. `files` come from `git show --name-status --format= <sha>`. `added_imports` come from the `+import X` lines in `git show --format= -U0 <sha>`, mapped to their file.
  - `build_context(git: Git, mac_ref: str) -> Context`: reads `docs/macos/PORTING_LEDGER.md` and `project.yml` at `mac_ref` (`git show mac_ref:path`). Gets `mac_marker_files` from `git grep -l "// MAC:" mac_ref -- Conduit Shared ConduitWidgets`, with the `ref:` prefix removed. Gets the `keep in sync` lines from `git grep -n "keep in sync" mac_ref -- ConduitMac`.
  - `release_steps(git: Git, base: str, head: str, tag_glob: str = "ios/v*") -> list[Step]`.
  - `render_report(commits: list[Commit], steps: list[Step], base: str, head: str, baseline_failures: list[str]) -> str`.
  - CLI: `triage.py --repo PATH --mac-ref REF --head REF --json OUT --report OUT [--baseline FAILURES.json]`. `base` is `git merge-base mac_ref head`. Exit 0.

- [ ] **Step 1: Write the failing tests.** The fixture builds a throwaway repo with `subprocess`, using `git -c user.name=t -c user.email=t@t`:
  - On `main`: commits `c1` (adds `README.md`), `c2` (modifies `Conduit/Models/X.swift`), `c3` and `c4`.
  - Branch `rel` from `c2`, with one commit `r1` tagged `ios/v1.0.0-build-1`. The tag is not on `main`, as upstream does it.
  - Tag `ios/v0.9-build-0` on `c1`, which is the base, so it is excluded.
  - `mac` branched at `c1`. It holds `docs/macos/PORTING_LEDGER.md` (one row: `Conduit/Views/RootView.swift`) and `project.yml` (the Task 1 `PROJECT` text).
  - `c3` adds `Conduit/Views/V2/V2Shell.swift`. `c4` modifies `Conduit/Views/RootView.swift` and adds a line `import ActivityKit` to `Shared/Widgets/A.swift`.

```python
class ReleaseStepTests(unittest.TestCase):
    def test_steps_use_cut_commit_and_end_at_head(self):
        steps = t.release_steps(self.git, self.c1, "main")
        self.assertEqual([s.label for s in steps], ["ios/v1.0.0-build-1", "main"])
        self.assertEqual(steps[0].sha, self.c2)
        self.assertEqual([s.count for s in steps], [1, 2])
    def test_no_tags_gives_single_step(self):
        self.assertEqual([s.label for s in t.release_steps(self.git, self.c1, "main", tag_glob="none/*")], ["main"])

class CollectTests(unittest.TestCase):
    def test_collect_and_classify_end_to_end(self):
        ctx = t.build_context(self.git, "mac")
        cs = [t.classify(c, ctx) for c in t.collect_commits(self.git, self.c1, "main")]
        self.assertEqual([c.group for c in cs], ["comes-along", "gate-off", "risk"])
        self.assertIn(("Shared/Widgets/A.swift", "ActivityKit"), cs[2].added_imports)

class ReportTests(unittest.TestCase):
    def test_report_sections_and_one_line_per_commit(self):
        ctx = t.build_context(self.git, "mac")
        cs = [t.classify(c, ctx) for c in t.collect_commits(self.git, self.c1, "main")]
        md = t.render_report(cs, t.release_steps(self.git, self.c1, "main"), self.c1, "main", ["A/testB"])
        for heading in ("## Range", "## Merge steps", "## Risk", "## Needs a Mac port", "## Gate off on Mac",
                        "## Needs a Mac entry point (candidates)", "## iOS-only or no Mac effect", "## Comes along",
                        "## Live check list", "## Baseline failures"):
            self.assertIn(heading, md)
        self.assertEqual(md.count(cs[2].sha[:8]), 1)
        self.assertIn("A/testB", md)
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_triage_git.py' -v`
Expected: FAIL with `AttributeError: module 'upstream_triage' has no attribute 'release_steps'`.

- [ ] **Step 3: Implement `run_git`, `build_context`, `collect_commits`, `release_steps`, `render_report` and `main`**

- **`release_steps`:**
  1. For each tag from `git tag -l <glob>`, compute `cut = git merge-base <tag> <head>`. Keep it when `cut != base` and `git merge-base --is-ancestor base cut` succeeds.
  2. Group by `cut`, and label each group with its last tag in `git tag -l --sort=creatordate` order.
  3. Order the groups by `git rev-list --count base..cut`.
  4. Append `head` as the last step, unless it resolves to the last cut.
  5. `count` is the number of commits from the previous step (or `base`) to this step.
- **`render_report`:** sections in the order the test lists. Each commit line is ``- `<sha8>` #<pr> <subject> -- <reasons joined by "; ">``.
  - "Needs a Mac entry point (candidates)" lists the commits with `new_v2_surface`.
  - "Live check list" lists the commits with `rich`.
  - "Merge steps" is a table: label, sha8, count.
  - The report ends with an empty `## Decisions for the user` section.

- [ ] **Step 4: Run all triage tests and see them pass**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_triage*.py' -v`
Expected: all tests pass.

- [ ] **Step 5: Smoke-run on the real repo and check the counts**

Run: `python3 scripts/upstream-sync/triage.py --repo . --mac-ref macos --head upstream/main --json build/scratch/triage.json --report build/scratch/triage.md && head -40 build/scratch/triage.md`
Expected: the Range section shows 498 commits. Merge steps show 5 rows with the cuts `a7939bf3`, `7124e87c`, `0f4da80a`, `be8e27a5` and then `upstream/main`, with counts 205, 190, 20, 73 and 10. If upstream has moved on since 2026-10-21, the last count may be higher.

- [ ] **Step 6: Commit**

```bash
git add scripts/upstream-sync/triage.py scripts/tests/test_upstream_triage_git.py
git commit -m "feat(mac): triage collects commits, plans release-cut merge steps, writes the report"
```

### Task 3: Three-way string catalog merge

**Files:**
- Create: `scripts/upstream-sync/merge-xcstrings.py`
- Test: `scripts/tests/test_upstream_merge_xcstrings.py`

**Interfaces:**
- Produces:
  - `merge(base: dict, ours: dict, theirs: dict) -> tuple[dict, list[str]]`: the merged object, plus the conflict paths, such as `strings/Artifacts/localizations/de/stringUnit/value`.
  - `dumps(obj: dict) -> str`: the Global Constraints format, with a trailing newline.
  - CLI: `merge-xcstrings.py BASE OURS THEIRS -o OUT`. A missing or empty BASE file means `{}`. The merged file is always written; at a conflict it keeps "ours". Exit 0 when clean. Exit 1 when there are conflicts, after printing one line per conflict path.

- [ ] **Step 1: Write the failing tests**

```python
m = load_module("merge_xcstrings", "upstream-sync/merge-xcstrings.py")
def cat(strings): return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
def loc(v): return {"localizations": {"de": {"stringUnit": {"state": "translated", "value": v}}}}

class MergeTests(unittest.TestCase):
    def test_keeps_ours_order_and_appends_new_theirs_keys(self):
        out, c = m.merge(cat({"a": {}, "b": {}}), cat({"b": {}, "a": {}, "mac": {}}), cat({"a": {}, "b": {}, "new": {}}))
        self.assertEqual(list(out["strings"]), ["b", "a", "mac", "new"]); self.assertEqual(c, [])
    def test_one_side_change_wins(self):
        out, _ = m.merge(cat({"k": loc("x")}), cat({"k": loc("x")}), cat({"k": loc("y")}))
        self.assertEqual(out["strings"]["k"], loc("y"))
    def test_theirs_delete_of_unchanged_key(self):
        out, _ = m.merge(cat({"k": {}}), cat({"k": {}}), cat({}))
        self.assertNotIn("k", out["strings"])
    def test_disjoint_language_changes_merge(self):
        b = {"localizations": {"de": {"v": 1}, "fr": {"v": 1}}}
        o = {"localizations": {"de": {"v": 2}, "fr": {"v": 1}}}
        th = {"localizations": {"de": {"v": 1}, "fr": {"v": 3}}}
        out, c = m.merge(cat({"k": b}), cat({"k": o}), cat({"k": th}))
        self.assertEqual(out["strings"]["k"], {"localizations": {"de": {"v": 2}, "fr": {"v": 3}}}); self.assertEqual(c, [])
    def test_conflicting_translation_reported(self):
        out, c = m.merge(cat({"k": loc("x")}), cat({"k": loc("ours")}), cat({"k": loc("theirs")}))
        self.assertEqual(c, ["strings/k/localizations/de/stringUnit/value"])
        self.assertEqual(out["strings"]["k"], loc("ours"))
    def test_dumps_format_round_trips_repo_catalog(self):
        import json, subprocess
        raw = subprocess.run(["git", "show", "HEAD:Conduit/AppShortcuts.xcstrings"], capture_output=True, text=True, check=True).stdout
        self.assertEqual(m.dumps(json.loads(raw)), raw)
    def test_cli_exit_codes(self): ...  # writes three temp files; exit 0 clean, exit 1 and a printed path on conflict
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_merge_xcstrings.py' -v`
Expected: an error, because the file does not exist.

- [ ] **Step 3: Implement `merge`, `dumps` and `main`**

The merge is a recursive three-way merge over dicts. Missing values count as `None`.

```text
merge_value(b, o, t, path):
  if o == t: return o
  if o == b: return t            # includes theirs-delete (t is None)
  if t == b: return o            # includes ours-delete
  if all of b, o, t are dicts (b may be None -> {}): return merge_dict(b or {}, o, t, path)
  record conflict path; return o
merge_dict(b, o, t, path): keys in o order, then keys only in t in t order;
  drop a key whose merged value is None
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_merge_xcstrings.py' -v`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/upstream-sync/merge-xcstrings.py scripts/tests/test_upstream_merge_xcstrings.py
git commit -m "feat(mac): key-by-key three-way merge for string catalogs"
```

### Task 4: Mac test log reader and regression compare

**Files:**
- Create: `scripts/upstream-sync/mac-test-failures.py`
- Test: `scripts/tests/test_upstream_mac_test_failures.py`

**Interfaces:**
- Produces:
  - `parse(log: str) -> dict`: `{"result": "SUCCEEDED" | "FAILED" | "UNKNOWN", "failed": [sorted "Class/test"], "passed": int, "failed_classes": [sorted "Class"]}`.
  - `regressions(baseline: dict, current: dict) -> list[str]`: the tests in `current["failed"]` that are not in `baseline["failed"]`, sorted.
  - CLI: `mac-test-failures.py parse LOG -o OUT.json`, which prints a one-line summary and exits 0. `mac-test-failures.py compare BASELINE.json CURRENT.json`, which prints each regression and exits 1 if there is any, else exits 0.

- [ ] **Step 1: Write the failing tests**

```python
f = load_module("mac_test_failures", "upstream-sync/mac-test-failures.py")
LOG = """Test Case '-[ConduitMacTests.MacDetailRouterTests testTabToDestinationMappings]' passed (0.010 seconds).
Test Case '-[ConduitMacTests.MacChatRouteTests testHomeIsAPaneNotChat]' failed (0.020 seconds).
Test case 'MacKeyboardTests.testOtherKeysMapToNothing()' failed on 'My Mac - Conduit (123)' (0.004 seconds)
Test case 'MacKeyboardTests.testA()' passed on 'My Mac - Conduit (123)' (0.004 seconds)
** TEST FAILED **
"""
class ParseTests(unittest.TestCase):
    def test_both_xctest_line_styles(self):
        r = f.parse(LOG)
        self.assertEqual(r["result"], "FAILED")
        self.assertEqual(r["failed"], ["MacChatRouteTests/testHomeIsAPaneNotChat", "MacKeyboardTests/testOtherKeysMapToNothing"])
        self.assertEqual(r["passed"], 2)
        self.assertEqual(r["failed_classes"], ["MacChatRouteTests", "MacKeyboardTests"])
    def test_succeeded_and_unknown(self):
        self.assertEqual(f.parse("** TEST SUCCEEDED **\n")["result"], "SUCCEEDED")
        self.assertEqual(f.parse("build log only")["result"], "UNKNOWN")
    def test_regressions_ignore_baseline_failures(self):
        self.assertEqual(f.regressions({"failed": ["A/x"]}, {"failed": ["A/x", "B/y"]}), ["B/y"])
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_mac_test_failures.py' -v`
Expected: an error, because the file does not exist.

- [ ] **Step 3: Implement `parse`, `regressions` and `main`.** Use two regexes:
  - `Test Case '-\[\w+\.(\w+) (\w+)\]' (passed|failed)`
  - `Test case '(\w+)\.(\w+)\(\)' (passed|failed)`

  `result` comes from the last `** TEST (EXECUTE )?(SUCCEEDED|FAILED) **` line.

- [ ] **Step 4: Run the tests and see them pass**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_mac_test_failures.py' -v`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/upstream-sync/mac-test-failures.py scripts/tests/test_upstream_mac_test_failures.py
git commit -m "feat(mac): parse Mac xcodebuild test logs and compare against a baseline"
```

### Task 5: The skill file and the ledger changes

**Files:**
- Create: `.claude/skills/upstream-sync/SKILL.md`
- Create: `docs/macos/upstream-sync/README.md` (one paragraph: what the reports are; one report per run, named `YYYY-MM-DD.md`)
- Modify: `docs/macos/PORTING_LEDGER.md`:
  - Add `## Kept off on Mac` before `## Sync routine`. It holds only the table header `| Feature | Gate | Reason | Date |` and the separator.
  - In `## Sync routine`, add one line at the top: "Run `/upstream-sync` (`.claude/skills/upstream-sync/SKILL.md`); the steps below are the reference it follows."
  - In step 5, replace the iOS Simulator bullet with: "No iOS Simulator build: only the Mac app ships (2026-10-21)."

**Interfaces:**
- Consumes: the CLIs from Tasks 2, 3 and 4, exactly as their Interfaces blocks give them.

- [ ] **Step 1: Write `SKILL.md`.** Use frontmatter `name: upstream-sync`. The description: "Use when merging new kaishi00/hermes-conduit (upstream) commits into the macos branch, or when asked to evaluate, sync or adopt upstream Conduit updates." The body has these sections in this order. Each section is short numbered steps in STE strict mode. Each step names the exact command and the output that means it passed.
  - **Preflight:**
    - The working tree is clean and on `macos`.
    - Run `git fetch upstream --tags`.
    - `df -h`: stop if free space is under 20 GB.
    - Record `git merge-base macos upstream/main`.
  - **Phase 1, Evaluate:**
    1. **Baseline.** Run `xcodegen generate`, then the full Mac suite, saving the log with `| tee build/scratch/upstream-sync/baseline.log`. Then run `mac-test-failures.py parse ... -o build/scratch/upstream-sync/baseline.json`. Rerun each failed class once with `-only-testing`. A test that passes on the rerun is a flake; remove it from the baseline file.
    2. **Triage.** Run `triage.py --repo . --mac-ref macos --head upstream/main --baseline build/scratch/upstream-sync/baseline.json --json build/scratch/upstream-sync/triage.json --report docs/macos/upstream-sync/<date>.md`.
    3. **Judge by reading.** Read each commit in Gate off, Risk, and Needs a Mac entry point. Move a commit only with a written reason.
       - For each Needs a Mac port commit, add the Mac file to its line. Take it from the "Mac side" column of the matching ledger row, or from the `keep in sync` marker's file.
       - For each new V2 route, menu item or sheet, look for a legacy entry point in `SidebarView`, `ChatView`, `AuxiliaryViews` and the non-V2 path of `RootView`. With none, the commit goes under "Needs a Mac entry point" for the user.
       - List the UI changes that upstream made in legacy views without the V2 switch (for example `V2RowDivider`, `.v2TabBarClearance()`, `.v2EdgeBar`, and new `Conduit/Views/Login/` screens) under "Decisions for the user", each with a proposed gate.
    4. **Stop.** Show a summary of at most 5 lines and the report path. Do not merge until the user approves.
  - **Phase 2, Merge.** These steps come from spec Part 1, steps 6 to 10:
    - The worktree is `.worktrees/sync-upstream-<date>`, on branch `sync/upstream-<date>`.
    - For each step: `git merge --no-ff <step sha> -m "merge: upstream <label>"`.
    - For a catalog conflict: `git show :1:<p> > b`, `:2:` to `o`, `:3:` to `t`, then `merge-xcstrings.py b o t -o <p>`. On exit 1, resolve each printed path by hand, preferring upstream for translations of upstream-owned keys.
    - Apply rules R1 to R4 in order. Each upstream edit gets a `// MAC:` tag and a ledger row.
    - Test only the classes this step touched, then run `compare` against the baseline.
    - Commit after each step.
  - **Test-change rule.** Copy the spec section "When upstream changes behavior a Mac test checks" verbatim.
  - **Full gate:**
    - Run the full suite, then `compare`. Pass = exit 0.
    - Run `scripts/mac-verify-bundle.sh --archive`. Pass = exit 0, with every check line printing `ok:`.
  - **Live check.** Copy the spec "Live check" bullets. Load the `agent-desktop` skill to drive the app. Use these check prompts:
    - "Show me a place card for the Ferry Building in San Francisco."
    - "Make a bar chart card of these numbers: 3, 7, 5."
    - "Draw a mermaid flowchart with three steps."
    - "Write the quadratic formula in LaTeX."
    - "Write an HTML file with an SVG chart and show it with ::preview."
    - "Reply with a markdown table of 3 rows and 3 columns."
    - "Print a 300-line Swift file in one code block."
    - "Read a web page and include one of its images."
    - "Run a shell command that lists a directory."
  - **Land:**
    - `git -C <main checkout> merge --ff-only sync/upstream-<date>`.
    - `git worktree remove`, `git branch -d`, delete `build/scratch/upstream-sync`.
    - Append the results to the report and commit it.
    - Print the `SMOKE_CHECKLIST.md` sections to run, and the push command `git push origin macos`. Do not run the push.
  - **Stop early when:** copy the four bullets from the spec, and add the rule "leave the worktree; write what you found to the report; name the one decision".
- [ ] **Step 2: Pressure-test the skill text.** Send a fresh subagent `SKILL.md` and these 4 scenarios. Ask it to answer each from the skill alone:
  1. "Step 2's merge conflicts in `ConduitMac/App/MacDetailRouter.swift`."
  2. "`MacSidebarShortcutTests.testOtherKeysMapToNothing` fails after you add a Mac sidebar tab on Ctrl-Cmd-6."
  3. "The user says 'go' before the report exists."
  4. "`merge-xcstrings.py` exits 1 with 3 paths."

  Expected answers:
  1. Stop early: a conflict outside the expected places.
  2. A Mac-decision test: update it only together with the Mac change that changed the decision, and give the reason in the report.
  3. Write the report first, then stop.
  4. Resolve each path by hand.

  Fix the skill text until all 4 answers match.
- [ ] **Step 3: Run the Python suite once more**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_upstream_*.py'`
Expected: `OK`.

- [ ] **Step 4: Commit, review and land Part 1**

```bash
git add .claude/skills/upstream-sync/SKILL.md docs/macos/upstream-sync/README.md docs/macos/PORTING_LEDGER.md
git commit -m "feat(mac): /upstream-sync skill; Kept off on Mac ledger section; drop the iOS build from the sync routine"
```

After the review passes, run `git -C <main checkout> merge --ff-only feat/upstream-sync-skill`. Then remove the worktree and delete the branch.

---

## Part 2: the 2.x merge (the skill's first run)

Run `/upstream-sync` from the main checkout on `macos`. Tasks 6 to 15 are that run. They also name what is already known about this range. Task 6 happens in the main checkout. Tasks 7 to 14 happen in `.worktrees/sync-upstream-<date>`.

### Task 6: Evaluate and stop

- [ ] **Step 1:** Run the skill's Preflight and Phase 1 steps 1 to 3.
- [ ] **Step 2: Check that the report has these, and add any that are missing:**
  - V2 shell under Gate off, with the proposed gate from Task 7.
  - `V2ArtifactsViews.swift` under "Needs a Mac entry point", with the decision already taken: Tasks 12 and 13.
  - The Capabilities screens (`Conduit/Views/Capabilities/`, 5 new files): look for a legacy entry point. If there is none, list them for the user.
  - The new `Conduit/Views/Login/` screens and the `V2RowDivider` uses in `AuxiliaryViews.swift`, `BotRosterView.swift`, `ConnectionSetup*.swift` and `Login/*.swift`, under "Decisions for the user".
  - `Shared/Widgets/HermesTurnActivity.swift` (ActivityKit) under Risk.
  - The `project.yml` changes under Risk: new targets `ConduitWatchWidgets`, `ConduitLocationPush`, `ConduitShareExtension` and `ConduitScreenshots`, plus `PROVISIONING_PROFILE_SPECIFIER: "Hermes Conduit App Store"`. Mac targets keep their own signing.
- [ ] **Step 3: Stop.** Show the summary and the report path. Wait for the user's approval and their answers under "Decisions for the user". Write the answers into the report.

### Task 7: Merge step 1 (cut `a7939bf3`, 205 commits) and V2 off

**Files:**
- Modify: `Conduit/Views/V2/V2Shell.swift`, the `V2ShellPreference.defaultValue` line (R4)
- Modify: `docs/macos/PORTING_LEDGER.md` (ledger rows, plus the first `Kept off on Mac` row)
- Modify: `project.yml` (conflict resolution; Mac excludes as needed)
- Test: `ConduitMacTests/MacV2ShellOffTests.swift`

**Interfaces:**
- Produces: on Mac, `V2ShellPreference.defaultValue == false` and `V2ShellPreference.isOn == false`. Every `@AppStorage(V2ShellPreference.key)` site then reads false, and `RootView.sidebarLayoutContent` takes the non-V2 path.

- [ ] **Step 1: Create the worktree and merge step 1**

```bash
git worktree add .worktrees/sync-upstream-<date> -b sync/upstream-<date> macos
cd .worktrees/sync-upstream-<date> && git merge --no-ff a7939bf3 -m "merge: upstream main@a7939bf3 (0.1.19 cut)"
```

- [ ] **Step 2: Resolve the conflicts.**
  - **`RootView.swift`:** keep every `// MAC:` region, and take upstream's `useV2Shell` property and `if useV2Shell { V2Shell() }` branch as they are. The Mac never takes that branch after Step 4. The conflict points are the `sidebarLayoutContent` region (macos `:305-335`), the `isPersistentSidebarActive` line (macos `:94`) and the `settingsLinkRequest` handler (macos `:249`). The resolved `isPersistentSidebarActive` is upstream's `!useV2Shell && sidebarPresentation == .persistent`, so the Mac `return .persistent` region still makes it true.
  - **`project.yml`:** keep the Mac targets unchanged and take upstream's iOS targets.
  - **Catalogs:** use `merge-xcstrings.py` for both catalogs.
- [ ] **Step 3: Write the failing test** `ConduitMacTests/MacV2ShellOffTests.swift`:

```swift
@testable import ConduitMac
import XCTest

final class MacV2ShellOffTests: XCTestCase {
    func testV2ShellDefaultsOffOnMac() {
        XCTAssertFalse(V2ShellPreference.defaultValue)
    }
    func testV2ShellReadsOffWhenUnset() {
        UserDefaults.standard.removeObject(forKey: V2ShellPreference.key)
        XCTAssertFalse(V2ShellPreference.isOn)
    }
}
```

Run: the one-class Mac test command with `MacV2ShellOffTests`.
Expected: FAIL on both tests (`defaultValue` is `true`).

- [ ] **Step 4: Gate the default.** In `V2Shell.swift`, replace the one line `static let defaultValue = true` with:

```swift
    #if os(macOS) // MAC: V2 shell kept off; the Mac keeps its own UI (Kept off on Mac)
    static let defaultValue = false
    #else
    static let defaultValue = true
    #endif // MAC:
```

  Add the ledger row (R4, 1 region). Add the `Kept off on Mac` row: `| Conduit/Views/V2/ | V2Shell.swift V2ShellPreference.defaultValue (// MAC:) | no UI rework (user, 2026-10-21) | 2026-10-21 |`.
- [ ] **Step 5: Build and fix compile errors with R1 to R4, in that order.** Expected candidates:
  - **`HTMLPreviewBlock.swift` `HTMLPreviewWebView: UIViewRepresentable`:** R3. Gate the type `#if os(iOS) // MAC:` and add a minimal Mac twin with the same name in `ConduitMac/WebViews/HTMLPreviewWebViewTwin.swift`, an `NSViewRepresentable` around `WKWebView`. Task 10 completes it.
  - **`Shared/Widgets/HermesTurnActivity.swift` (ActivityKit):** if it fails to compile, use R2. Exclude it in `project.yml` from `ConduitMac` (as `path: Shared` excludes) and from `ConduitMacWidgets` (as `path: Shared/Widgets` excludes). Add a stub only for the symbols Mac code references.
  - **New iOS-only frameworks in `Conduit/Location/`, `Shared/Location/`, `Conduit/Health/`:** R2 by directory exclude when a whole directory is iOS-only and nothing compiled on Mac references it. Otherwise use R3 and R4.
- [ ] **Step 6: Run the touched classes and the step compare.** Run `MacV2ShellOffTests`, plus every test class whose subject file the step changed (from `git diff --name-only HEAD~1`). Then run `mac-test-failures.py compare build/scratch/upstream-sync/baseline.json <step.json>`.
  Expected: `MacV2ShellOffTests` passes and the compare exits 0. For a test-change case, follow the skill's test-change rule.
- [ ] **Step 7: Check the look.** Launch the Debug build, after confirming the binary path with `ps -o comm`. The sidebar, chat, composer and Settings match `macos` today. There is no tab bar and no V2 top bar. Save screenshots to `build/scratch/live-check/v2-off-*.png`.
- [ ] **Step 8: Commit.** Use `git commit -m "fix(mac): upstream step 1 compiles on Mac; V2 shell kept off"`. Any compile fixes go in the same commit, or in their own `fix(mac):` commits before it.

### Task 8: Merge step 2 (cut `7124e87c`, 190 commits)

This step brings rich cards (`Conduit/Cards/`, which uses Charts, available on macOS 13 and later), `Shared/ShareDraft/` and `Shared/LocalLive/`.

- [ ] **Step 1:** Run `git merge --no-ff 7124e87c -m "merge: upstream main@7124e87c (2.0.0 build 215 cut)"`. Resolve conflicts as in Task 7 Step 2.
- [ ] **Step 2: Build and fix compile errors with R1 to R4.** `Shared/ShareDraft/` is iOS-only (the share extension). If it needs a fix, prefer R2 by directory exclude from `ConduitMac`'s `path: Shared`, as long as nothing compiled on Mac references it.
- [ ] **Step 3:** Run the touched classes, then `compare`. Expected: exit 0.
- [ ] **Step 4:** Commit with `fix(mac): upstream step 2 compiles on Mac`. If the merge commit alone is clean, there is nothing to commit.

### Task 9: Merge steps 3 to 5 (`0f4da80a`, `be8e27a5`, `upstream/main`; 103 commits)

- [ ] **Step 1:** For each step in order, run `git merge --no-ff <sha>`, resolve conflicts, build, run the touched classes and `compare`, then commit. Run `compare` after each step, not only after the last one.
- [ ] **Step 2: Fold in commits newer than the plan.** If `upstream/main` moved after 2026-10-21, the last step covers the newer commits too. Re-run `triage.py` for that range, and add any new Gate off or Risk items to the report before you merge them.

### Task 10: Re-port the twins at the final upstream state

**Files:**
- Modify: `ConduitMac/WebViews/WebViewTwins.swift` (`MacMarkupMessageProxy`, `MarkupWebView`, `SafeMarkupWebView`, `MacRemoteImageHTML`, `RemoteImageWebView`, `AuthWebView`)
- Modify: `ConduitMac/WebViews/HTMLPreviewWebViewTwin.swift` (complete the Task 7 twin)
- Modify: `ConduitMac/Chat/SelectableTextView.swift` (`bridge`, `withTraits`)
- Modify: `ConduitMac/App/ConduitMacApp.swift` (`rootContent` port)
- Test: `ConduitMacTests/MacHTMLPreviewPolicyTests.swift`

**Interfaces:**
- Consumes (shared upstream code in `Conduit/Views/Components/HTMLPreviewBlock.swift`, compiled on Mac):
  - `HTMLPreviewPage.navigationDecision(url: URL?, isMainFrame: Bool, userTapped: Bool) -> (allow: Bool, openExternally: URL?)`
  - `HTMLPreviewPage.contentSecurityPolicy`
  - `HTMLPreviewPage.framed(_:theme:presentation:)`
  - `HTMLPreviewPage.messageHandlerNames(reportsHeight:)`
- Produces:
  - `final class MacHTMLPreviewNavigationDelegate: NSObject, WKNavigationDelegate` in `HTMLPreviewWebViewTwin.swift`, with `init(open: @escaping (URL) -> Void = { UIApplication.shared.open($0) })`. The test helper `decide(_:type:delegate:) async -> WKNavigationActionPolicy` calls `webView(_:decidePolicyFor:decisionHandler:)` on a plain `WKWebView()` and returns the policy that the handler receives. Its `decidePolicyFor navigationAction` calls the shared `navigationDecision` with `userTapped: navigationAction.navigationType == .linkActivated`. It cancels when `allow` is false. It sends any `openExternally` URL through the existing R11 path (`UIApplication.shared.open`, which opens only when `UIApplication.allowsExternalOpen`).
  - It defines no Mac-only policy. The decision stays upstream's.

- [ ] **Step 1: Diff each source against the twin.** Run `git diff c13e234f upstream/main -- <source>` for `Conduit/Views/Components/MarkupBlock.swift`, `Conduit/Views/Components/MarkdownText.swift`, `Conduit/Views/Components/HTMLPreviewBlock.swift`, `Conduit/Views/Components/SelectableTextView.swift` and `Conduit/ConduitApp.swift`, and for the file that now holds `AuthWebView` (find it with `git grep -n "AuthWebView" upstream/main -- Conduit`). Write down each behavior change to port: CSP text (#777, #1011), Mermaid and KaTeX hash pins (#777), the bounded image loader (#892, #1010), message proxy changes and `rootContent` modifiers.
- [ ] **Step 2: Write the failing tests.** The tests drive `MacHTMLPreviewNavigationDelegate` with a stub `WKNavigationAction` subclass (override `request` and `navigationType`), so they check what the Mac twin actually does.

```swift
final class MacHTMLPreviewPolicyTests: XCTestCase {
    func testScriptedRemoteLoadIsCancelled() async {
        let policy = await decide("https://evil.example/x", type: .other, delegate: MacHTMLPreviewNavigationDelegate())
        XCTAssertEqual(policy, .cancel)
    }
    func testBlankDocumentLoads() async {
        XCTAssertEqual(await decide("about:blank", type: .other, delegate: MacHTMLPreviewNavigationDelegate()), .allow)
    }
    func testUserClickOnWebLinkIsCancelledInPlaceAndOpensExternally() async {
        let opened = OpenRecorder()   // seam: the delegate takes `open: (URL) -> Void`, defaulting to the R11 path
        let policy = await decide("https://example.com", type: .linkActivated, delegate: MacHTMLPreviewNavigationDelegate(open: opened.record))
        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(opened.urls, [URL(string: "https://example.com")!])
    }
    func testFramedDocumentCarriesUpstreamCSP() {
        XCTAssertTrue(HTMLPreviewPage.contentSecurityPolicy.contains("connect-src data: blob:"))
        let html = HTMLPreviewPage.framed("<p>x</p>", theme: /* the Mac theme value the twin passes */, presentation: .inline)
        XCTAssertTrue(html.contains(#"<meta http-equiv="Content-Security-Policy" content="\#(HTMLPreviewPage.contentSecurityPolicy)">"#))
    }
}
```

The `Presentation` case name and the theme constructor come from the merged `HTMLPreviewBlock.swift`. Use what the twin passes.

Run: the one-class command with `MacHTMLPreviewPolicyTests`.
Expected: FAIL to compile (`MacHTMLPreviewNavigationDelegate` is missing).

- [ ] **Step 3: Implement the delegate and the full twin.** The twin builds its document with `HTMLPreviewPage.framed`. It registers `HTMLPreviewPage.messageHandlerNames(reportsHeight:)`, and its delegate is `MacHTMLPreviewNavigationDelegate`. The message proxy matches upstream's `MarkupMessageProxy` changes. Port every behavior change from Step 1 into the matching twin. Keep the `keep in sync` markers and update the ledger rows.
- [ ] **Step 4: Run the tests.** Run `MacHTMLPreviewPolicyTests` plus the existing twin classes: `SelectableTextViewTests` and the `WebViewTwins` tests found by `grep -ln "MarkupWebView\|RemoteImageWebView\|AuthWebView" ConduitMacTests`.
  Expected: all pass.
- [ ] **Step 5: Commit.** Use `git commit -m "fix(mac): twins follow upstream 2.x (previews, Mermaid/KaTeX pins, bounded images, auth)"`.

### Task 11: Mac forms of new rich-content interactions

**Files:**
- Modify only where Step 1 finds a gap. Each upstream edit gets a `// MAC:` tag and a ledger row.
- Test: `ConduitMacTests/MacRichContentInteractionTests.swift`

- [ ] **Step 1: Check each interaction's trigger in the merged code.** SwiftUI `.contextMenu` already works as right-click on Mac. A `LongPressGesture` or `onLongPressGesture` does not.
  - Chat tables Copy Table and Select Text (#693): `git grep -n "Copy Table" -- Conduit`.
  - Per-message send options (#966): search the composer send button in `ComposerBar.swift` for `onLongPressGesture` or `LongPressGesture`.
  - Tool rows (#1063, #1074): check whether `SettledToolCardContent` still exists and still holds the 6 `// MAC:` contrast regions.
- [ ] **Step 2: Fix each gap.**
  - For each trigger that is a long press, add a Mac `.contextMenu` with the same items in a `#if os(macOS) // MAC:` region (R4).
  - If the tool card's `// MAC:` contrast regions moved, re-apply them to the new view. `ComposerToolCardContrastTests` is a Mac-decision test, so it stays as it is and must pass.
- [ ] **Step 3: Write and run the tests.**
  - For each gap fixed in Step 2, add one source-pin test in `MacRichContentInteractionTests`. Use the repo's existing style; see `MacPaneTitleTests.testRootViewAppliesTheRemovalToTheChatStack`. The test asserts that the upstream file holds the `#if os(macOS) // MAC:` `.contextMenu` region, with the same item titles as upstream's long-press menu.
  - Run the existing `ComposerToolCardContrastTests` unchanged.
  - If Step 1 found no gaps, this class is not created. The live check in Task 14 covers right-click on Mac.

  Expected: all pass.
- [ ] **Step 4: Commit.** Use `git commit -m "fix(mac): right-click forms of table copy and send options; tool card contrast kept"`.

### Task 12: Mac Artifacts pane

**Files:**
- Modify: `Conduit/Views/SidebarTab.swift` (extend the three `// MAC:` regions: `case artifacts = "Artifacts"`, displayName `AppLocalization.string("Artifacts")`, icon `"square.grid.2x2"`)
- Modify: `ConduitMac/App/MacDetailRouter.swift` (`MacDetailDestination.artifacts`, the `destination(for:)` mapping, `pane(for:)` showing `MacArtifactsPane()`)
- Modify: `ConduitMac/App/MacKeyboardShortcuts.swift` (`MacSidebarShortcut.artifacts`, key `"6"`, Ctrl-Cmd-6; the Go menu gets it from `allCases`)
- Modify: `ConduitMac/Views/MacControlMetrics.swift` (`MacSidebarTabOrder.strip = [.home, .sessions, .bots, .cron, .kanban, .artifacts]`; adjust the `MacTabStripMetrics` ladder for 6 segments)
- Create: `ConduitMac/Artifacts/MacArtifactsPane.swift`
- Create: `ConduitMac/Artifacts/MacArtifactsList.swift`
- Modify: `ConduitMac/Views/MediaPreviewPresenterMac.swift` (add `present(downloaded:)`, matching the upstream signature, with the twin's current behavior: reveal in Finder)
- Modify: `Conduit/Localizable.xcstrings` (any new Mac string, in all 13 languages; upstream already has "Artifacts")
- Modify: `docs/macos/PORTING_LEDGER.md` (SidebarTab row extended; `MacArtifactsList` twin row), `docs/macos/DECISIONS.md` (new decision D26: Artifacts pane, why it is a `SidebarTab` case, as in D24)
- Test: `ConduitMacTests/MacArtifactsPaneTests.swift`. Update `MacDetailRouterTests`, `MacChatRouteTests.testHomeIsAPaneNotChat`, `MacKeyboardTests` (`testEveryTabHasExactlyOneDistinctShortcut`, `testOtherKeysMapToNothing`), `MacControlMetricsTests` and `ButtonGeometryTests` for the new tab. These are Mac-decision tests that this Mac change deliberately changes; give the reason in the report.

**Interfaces:**
- Consumes these upstream types (compiled on Mac from `Conduit/Services/Artifacts.swift`, `AppState+Artifacts.swift` and `Conduit/Views/V2/V2ArtifactsViews.swift`): `ArtifactItem`, `ArtifactFilter`, `ArtifactDay`, `ArtifactPage`, `ArtifactsClient` (`page(profile:sessionIDs:filter:query:showMissing:before:)`, `requestPath(...)`, `showMissingKey`), `ArtifactScope`, `ArtifactsListKey` (`showsRows(of:)`), `HTMLPreviewSheet(name:html:)`, `HTMLPreviewPage.decodedDocument(fromDataURL:)`, and `AppState.supportsArtifacts`, `activeChatArtifactSessionIDs` and `showArtifactInChat(_:chatIsOpen:)`.
- Produces:
  - `struct MacArtifactsPane: View`, with `init()` and `@EnvironmentObject appState`. It shows `MacPaneHeader(title: "Artifacts")`, then `MacSearchPill` in `.safeAreaInset(edge: .top)` (never `.searchable`, D6), then `MacArtifactsList(scope: .profile, chatIsOpen: false, showInChat: { appState.showArtifactInChat($0, chatIsOpen: false) })`.
  - `struct MacArtifactsList: View`, with `init(scope: ArtifactScope, chatIsOpen: Bool, query: String = "", showInChat: @escaping (ArtifactItem) -> Void)`. Mac twin of upstream `private struct ArtifactsList`. Marker: `// Mac twin of V2ArtifactsViews.swift ArtifactsList; keep in sync`.
  - What the list does:
    - Filter chips over `ArtifactFilter.allCases`. Day sections from `ArtifactsClient.days`. A 3-column tile grid for `isVisual` items, and rows for the rest.
    - Paging by `nextBefore`.
    - A context menu with Open, Show in Chat, Copy Link (`NSPasteboard`) and Copy Path.
    - A More menu with the "Show Missing Files" toggle, bound to `@AppStorage(ArtifactsClient.showMissingKey) var showMissing = false`.
    - Empty, failure and update-plugin states with upstream's strings.
    - No `V2Backdrop`, no `.refreshable`; a Refresh button in the More menu instead.
  - Open: a `.page` goes to `HTMLPreviewSheet` in a sheet. Any other item goes to `MediaPreviewPresenter.shared.present(downloaded:)`, with `present(dataURL:filename:)` as fallback. `.tooLarge` shows an alert.
  - #722 (closing a file froze the app) changed only the iOS presenter, which is gated off on Mac. The Mac twin reveals the file in Finder, so the fix does not apply. Say so in the report; do not port it.

- [ ] **Step 1: Write the failing tests** in `MacArtifactsPaneTests`:
  - `testArtifactsTabRoutesToArtifactsPane`: `MacDetailRouter.destination(for: .artifacts) == .artifacts`.
  - `testArtifactsIsAPaneNotChat`: `MacChatRoute.isChatActive(tabRaw: "Artifacts") == false`.
  - `testCtrlCmd6SelectsArtifacts`: `MacSidebarShortcut.tab(forKey: "6") == .artifacts`.
  - `testStripOrderEndsWithArtifacts`: `MacSidebarTabOrder.strip.last == .artifacts`.
  - `testShowMissingDefaultsOffAndHidesMissing`: with the defaults suite unset, the list's request path from `ArtifactsClient.requestPath(... showMissing: false ...)` contains `missing=hide`.
  - `testUnsupportedPluginShowsUpdateState`: host `MacArtifactsPane` with an `AppState` whose plugin does not report `artifacts`. `AccessibilityProbe.texts` contains upstream's update-plugin title, so no row and no spinner are shown.
  - `testDashboardSwitchDropsOtherServerRows`: `ArtifactsListKey(dashboard: A, ...)` rows are not shown under key `dashboard: B` (`showsRows(of:)` is false), and the hosted list shows no rows after the key changes.
  - `testShowInChatFromPaneOpensSessionAndReturnsToChat`: host `MacDetailRouter` on tab `.artifacts`, then call the pane's `showInChat` with an item for session `s1`. Expect `appState.pendingArtifactReveal?.messageID == item.messageID`, `.macSessionOpenRequested` to be posted for `s1`, and the stored tab to read `.sessions`.

Run: the one-class command with `MacArtifactsPaneTests`.
Expected: FAIL to compile (`SidebarTab.artifacts` is missing).

- [ ] **Step 2: Implement the tab, router, shortcut and strip order.** Run `MacArtifactsPaneTests` and the updated router, route, keyboard and metrics classes. Expected: the routing tests pass, and the view tests still fail.
- [ ] **Step 3: Implement `MacArtifactsPane`, `MacArtifactsList` and `present(downloaded:)`.** Run all the classes from Step 2 plus `AccessibilityLabelAuditTests`. Expected: all pass.
- [ ] **Step 4: Check the strings.** Run `python3 scripts/check-l10n-coverage.py`. Expected: exit 0.
- [ ] **Step 5: Commit.** Use `git commit -m "feat(mac): Artifacts sidebar pane (D26) with a Mac twin of upstream's list"`.

### Task 13: "Artifacts..." for one chat, from the Chat menu

**Files:**
- Create: `ConduitMac/Artifacts/MacChatArtifactsSheet.swift`. It holds the store `final class MacChatArtifactsStore: ObservableObject { static let shared; @Published var sessionIDs: [String]?; func present(sessionIDs: [String]) }` and the modifier `View.macChatArtifactsSheet(appState:store:)`. The sheet is `ConduitSheetHeader(title: "Artifacts", close:)` over `MacArtifactsList(scope: .chat(ids), chatIsOpen: true, showInChat: ...)`, sized with `.macFormSheetSize(...)`.
- Modify: `ConduitMac/App/MacKeyboardShortcuts.swift`: `MacAppActions.showChatArtifacts(window: NSWindow?)`. It runs `prepare(...)` and then presents with `activeChatArtifactSessionIDs`, following `switchDashboard`.
- Modify: `ConduitMac/App/ConduitCommands.swift`: in the "Chat" menu after "Ask About Window...", add `Button("Artifacts\u{2026}") { MacAppActions.showChatArtifacts(window: NSApp.keyWindow) }`. Disable it when there is no active chat or when `activeChatArtifactSessionIDs` is empty. Use the same `appState` access the Chat menu's other items use. No key equivalent.
- Modify: `ConduitMac/App/ConduitMacApp.swift`: attach `.macChatArtifactsSheet(appState:)` next to `.macDashboardSwitcher`.
- Test: `ConduitMacTests/MacChatArtifactsSheetTests.swift`. Update the menu table in `MacKeyboardMenuTests` and the `MacQuickAskCommandsTests` source pin.

- [ ] **Step 1: Write the failing tests:**
  - `testPresentStoresSessionIDs`
  - `testMenuItemDisabledWithoutActiveChat`
  - `testMenuTableHasChatArtifacts`: the menu path `/Chat/Artifacts…`
  - `testSheetScopesToChat`: the hosted sheet's list uses `ArtifactScope.chat(["s1","s2"])`

  Run the class. Expected: FAIL to compile.
- [ ] **Step 2: Implement.** Run `MacChatArtifactsSheetTests`, `MacKeyboardMenuTests` and `MacQuickAskCommandsTests`. Expected: all pass.
- [ ] **Step 3: Commit.** Use `git commit -m "feat(mac): Chat > Artifacts… shows one chat's artifacts in a sheet"`.

### Task 14: Full gate and live check

- [ ] **Step 1: Run the full suite in the sync worktree, with no other agent building.**

```bash
xcodegen generate && xcodebuild -project Conduit.xcodeproj -scheme ConduitMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO \
  | tee build/scratch/upstream-sync/final.log
python3 scripts/upstream-sync/mac-test-failures.py parse build/scratch/upstream-sync/final.log -o build/scratch/upstream-sync/final.json
python3 scripts/upstream-sync/mac-test-failures.py compare build/scratch/upstream-sync/baseline.json build/scratch/upstream-sync/final.json
```

Expected: `compare` exits 0. For a flake class, rerun it once.

- [ ] **Step 2: Run the bundle check.** Run `scripts/mac-verify-bundle.sh --archive`. Expected: exit 0, and every check line starts with `ok:`.
- [ ] **Step 3: Check the plugin prerequisite.** In the Debug app, open Settings > Conduit plugin and read the installed and recommended versions. If the installed version is lower, stop and ask the user before you update the plugin or restart the gateway.
- [ ] **Step 4: Live check.** Confirm the binary path with `ps -o comm`. Load the `agent-desktop` skill. In a new chat, send each prompt from the skill's list, and check the result in light and dark appearance.
  - Pass for each type: it renders as designed, with no raw JSON, no raw `::preview{...}` text, no empty box, no crash and no hang.
  - Also check:
    - The Artifacts pane, and "Show in Chat" from it.
    - Chat > Artifacts....
    - Show Missing Files.
    - Right-click Copy Table.
    - Image paste, file drop and the attachment menu in the composer.
  - Save one screenshot per type as `build/scratch/live-check/<type>-<light|dark>.png`.
- [ ] **Step 5: Handle failures.** Fix a failing type in the sync branch: write a test first when the cause can be tested, then rerun its check. Record a type you cannot fix as deferred, with the reason, under "Decisions for the user", and ask the user.

### Task 15: Land and report

- [ ] **Step 1: Finish the report.** Append these to `docs/macos/upstream-sync/<date>.md`: the steps merged, the ports and gates added (each with its ledger row), each test changed and why, the gate results, the live-check table (type, light, dark, result) and anything deferred.
- [ ] **Step 2: Commit the report in the sync worktree.** Use `git commit -m "docs(mac): upstream sync report <date>"`.
- [ ] **Step 3: Land.** In the main checkout, run `git merge --ff-only sync/upstream-<date>`. Then run `git worktree remove .worktrees/sync-upstream-<date>` and `git branch -d sync/upstream-<date>`, and delete `build/scratch/upstream-sync` and `build/scratch/live-check`.
- [ ] **Step 4: Report to the user.** Give the counts, what now works, the `SMOKE_CHECKLIST.md` sections to run (Release gate, Shared base, Home, Session windows, Widgets), and the command `git push origin macos`. Do not push.
