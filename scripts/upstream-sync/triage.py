#!/usr/bin/env python3
"""Classify upstream commits for the /upstream-sync skill (pure logic, stdlib only)."""
# No "from __future__ import annotations": load_module() does not register the module in
# sys.modules, and dataclasses fails on string annotations then. typing types suffice on 3.9.
import argparse
import fnmatch
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from typing import Callable, Dict, List, Optional, Set, Tuple

GROUPS = ("risk", "mac-port", "gate-off", "ios-only", "comes-along")

GROUP_TITLES = {
    "risk": "Risk",
    "mac-port": "Needs a Mac port",
    "gate-off": "Gate off on Mac",
    "ios-only": "iOS-only or no Mac effect",
    "comes-along": "Comes along",
}

IOS_ONLY_PREFIXES = (
    "ConduitTests/", "ConduitUITests/", "ConduitWatch/", "ConduitShareExtension/",
    "ConduitLocationPush/", "ConduitScreenshots/", "ConduitNotificationService/",
    "scripts/app-store/", ".github/", "project-tests.yml",
    "docs/", "README.md", "opencode.json",
    "Conduit/CarPlay/", "Conduit/Watch/", "Shared/WatchVoice/", "Conduit/Health/",
    "Conduit/Phone/", "Conduit/Location/", "Shared/Location/", "Shared/ShareDraft/",
    "Conduit/Views/CarPlaySettingsSection.swift",
    "Conduit/Views/HealthSettingsViews.swift",
    "Conduit/Views/PhoneSettingsViews.swift",
    "Conduit/Views/LocationSettingsViews.swift",
    "Conduit/Services/AppState+HealthSync.swift",
    "Conduit/Services/AppState+PhoneSync.swift",
    "Conduit/Services/AppState+Location.swift",
    "Conduit/Services/AppState+ShareDraft.swift",
    "ConduitWidgets/HermesTurnLiveActivity.swift",
    "Conduit/Services/LiveTurnActivities.swift",
    "Conduit/Services/LiveActivityUpdateThrottle.swift",
    "Conduit/Services/ScreenshotCallFixture.swift",
)

RISK_FRAMEWORKS = frozenset({
    "ActivityKit", "HealthKit", "CarPlay", "BackgroundTasks", "AlarmKit", "ContactsUI",
    "VisionKit", "MetricKit", "PushKit", "CallKit", "WatchConnectivity", "CoreTelephony",
    "MessageUI", "FamilyControls", "DeviceActivity", "ManagedSettings",
})

RICH_PATH_PREFIXES = (
    "Conduit/Cards/", "Conduit/Views/Components/MarkdownText",
    "Conduit/Views/Components/MarkupBlock", "Conduit/Views/Components/HTMLPreview",
    "Conduit/Views/Components/BoundedRemoteImage", "Conduit/Views/Components/MediaPreview",
    "Conduit/Views/Components/ComposerBar", "Conduit/Services/Artifacts",
    "Conduit/Services/AppState+Artifacts", "Conduit/Services/GatewayMedia",
    "Conduit/Services/DashboardFileDownload",
)

RICH_SUBJECT = re.compile(
    r"(?i)\b(cards?|preview|markdown|mermaid|katex|images?|pictures?|photos?|attach\w*|"
    r"artifacts?|media|tool rows?|tables?|code blocks?|files?|charts?)\b")

UPSTREAM_ROOTS = ("Conduit/", "Shared/", "ConduitWidgets/")
KEEP_OFF_HEADING = "## Kept off on Mac"
V2_PREFIX = "Conduit/Views/V2/"


@dataclass
class Commit:
    sha: str
    subject: str
    pr: Optional[int]
    files: List[Tuple[str, str]]
    added_imports: List[Tuple[str, str]]
    group: str = ""
    reasons: List[str] = field(default_factory=list)
    rich: bool = False
    new_v2_surface: bool = False


@dataclass
class Context:
    ledger_patterns: List[str]
    mac_excludes: List[str]
    sync_basenames: Set[str]
    mac_marker_files: Set[str]
    keep_off_patterns: List[str]


def parse_pr(subject: str) -> Optional[int]:
    found = re.findall(r"\(#(\d+)\)", subject)
    return int(found[-1]) if found else None


def _column1_paths(line: str) -> List[str]:
    """Upstream path tokens from column 1 of one table row."""
    if not line.lstrip().startswith("|"):
        return []
    cells = line.strip().strip("|").split("|")
    if not cells:
        return []
    cell = re.sub(r"`[^`]*`", " ", cells[0])
    if re.fullmatch(r"[\s:\-]*", cell):
        return []
    paths = []
    for piece in re.split(r",| \+ ", cell):
        tokens = piece.split()
        if tokens and tokens[0].startswith(UPSTREAM_ROOTS):
            paths.append(tokens[0])
    return paths


def parse_ledger_paths(text: str) -> List[str]:
    paths: List[str] = []
    for line in text.splitlines():
        if line.strip().startswith(KEEP_OFF_HEADING):
            break
        paths.extend(_column1_paths(line))
    return paths


def parse_keep_off_patterns(text: str) -> List[str]:
    paths: List[str] = []
    in_section = False
    for line in text.splitlines():
        if line.strip().startswith("#"):
            in_section = line.strip().startswith(KEEP_OFF_HEADING)
            continue
        if in_section:
            paths.extend(_column1_paths(line))
    return paths


def parse_mac_excludes(project_yml: str) -> List[str]:
    lines = project_yml.splitlines()
    in_target = False
    found = False
    out: List[str] = []
    for line in lines:
        if not found:
            if line.rstrip() == "  ConduitMac:":
                in_target = True
            elif in_target and re.match(r"^  \S.*:\s*$", line):
                break
            elif in_target and line.strip() == "- path: Conduit":
                found = True
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped == "excludes:":
            continue
        m = re.match(r"""^-\s+["'](.+)["']\s*(#.*)?$""", stripped)
        if not m:
            break
        out.append("Conduit/" + m.group(1))
    return out


def parse_sync_basenames(marker_lines: List[str]) -> Set[str]:
    names: Set[str] = set()
    for line in marker_lines:
        body = re.sub(r"^[^:]+:\d+:", "", line, count=1)
        names.update(re.findall(r"([A-Za-z0-9_+]+\.swift)", body))
    return names


def matches(path: str, patterns: List[str]) -> bool:
    for pattern in patterns:
        if "*" in pattern:
            if fnmatch.fnmatch(path, pattern):
                return True
        elif path == pattern or path.startswith(pattern.rstrip("/") + "/"):
            return True
    return False


def _compiled_on_mac(path: str, ctx: Context) -> bool:
    if path.startswith("ConduitWidgets/") or path.startswith("Shared/Widgets/"):
        return True
    if path.startswith(("Conduit/", "Shared/")):
        return not matches(path, ctx.mac_excludes)
    return False


def _is_ios_only(path: str) -> bool:
    return any(path == p or path.startswith(p) for p in IOS_ONLY_PREFIXES)


def classify(commit: Commit, ctx: Context) -> Commit:
    risk: List[str] = []
    port: List[str] = []
    gate: List[str] = []

    for status, path in commit.files:
        letter = status[:1]
        if path == "project.yml":
            risk.append("project.yml changed")
        if letter in ("D", "R") and (matches(path, ctx.ledger_patterns)
                                     or matches(path, ctx.mac_excludes)
                                     or path in ctx.mac_marker_files):
            word = "deleted" if letter == "D" else "renamed"
            risk.append("%s a file the Mac port depends on: %s" % (word, path))
        if matches(path, ctx.ledger_patterns):
            port.append("ledger file: %s" % path)
        if matches(path, ctx.mac_excludes):
            port.append("Mac-excluded file: %s" % path)
        if path in ctx.mac_marker_files:
            port.append("Mac-marked file: %s" % path)
        if path.rsplit("/", 1)[-1] in ctx.sync_basenames:
            port.append("keep-in-sync file: %s" % path)
        if path.startswith(V2_PREFIX) or matches(path, ctx.keep_off_patterns):
            gate.append("kept off on Mac: %s" % path)
        if letter == "A" and path.startswith(V2_PREFIX):
            commit.new_v2_surface = True

    for path, framework in commit.added_imports:
        if framework in RISK_FRAMEWORKS and _compiled_on_mac(path, ctx):
            risk.append("new import of %s in Mac-compiled file: %s" % (framework, path))

    ios_only: List[str] = []
    if commit.files and all(_is_ios_only(p) for _, p in commit.files):
        ios_only.append("every file is iOS-only or has no Mac effect")

    ordered = [("risk", risk), ("mac-port", port), ("gate-off", gate), ("ios-only", ios_only)]
    group = "comes-along"
    reasons: List[str] = []
    for name, found in ordered:
        if found:
            if not reasons:
                group = name
            reasons.extend(found)
    if not reasons:
        reasons = ["shared code; the Mac compiles it"]

    commit.group = group
    commit.reasons = reasons
    commit.rich = (any(p.startswith(RICH_PATH_PREFIXES) for _, p in commit.files)
                   or bool(RICH_SUBJECT.search(commit.subject)))
    return commit



# ---- git collection, merge steps, report, CLI ----

Git = Callable[[List[str]], str]

LEDGER_PATH = "docs/macos/PORTING_LEDGER.md"
PROJECT_PATH = "project.yml"
IMPORT_LINE = re.compile(
    r"^\+\s*(?:@\w+\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z0-9_]+)")


@dataclass
class Step:
    label: str
    sha: str
    count: int


def run_git(repo: str) -> Git:
    def git(args: List[str]) -> str:
        proc = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        out = proc.stdout.decode("utf-8", errors="replace")
        if proc.returncode == 0:
            return out
        if proc.returncode == 1 and args and args[0] == "grep":
            return ""
        raise RuntimeError("git %s failed (%d): %s" % (
            " ".join(args), proc.returncode, proc.stderr.decode("utf-8", errors="replace").strip()))
    return git


def _parse_name_status(text: str) -> List[Tuple[str, str]]:
    files: List[Tuple[str, str]] = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status = parts[0]
        if status[:1] == "R" and len(parts) >= 3:
            files.append((status, parts[1]))      # the old path is gone
            files.append(("A", parts[2]))         # the new path appears
        elif status[:1] == "C" and len(parts) >= 3:
            files.append(("A", parts[2]))
        else:
            files.append((status, parts[-1]))
    return files


def _parse_added_imports(diff: str) -> List[Tuple[str, str]]:
    found: List[Tuple[str, str]] = []
    current = ""
    for line in diff.splitlines():
        if line.startswith("+++ "):
            target = line[4:].strip()
            current = target[2:] if target.startswith("b/") else ""
        elif line.startswith("+") and current:
            m = IMPORT_LINE.match(line)
            if m:
                found.append((current, m.group(1)))
    return found


def collect_commits(git: Git, base: str, head: str) -> List[Commit]:
    log = git(["log", "--no-merges", "--reverse", "--format=%H%x1f%s", "%s..%s" % (base, head)])
    commits: List[Commit] = []
    for line in log.splitlines():
        if "\x1f" not in line:
            continue
        sha, subject = line.split("\x1f", 1)
        files = _parse_name_status(git(["show", "--name-status", "--format=", sha]))
        imports = _parse_added_imports(git(["show", "--format=", "-U0", sha]))
        commits.append(Commit(sha=sha, subject=subject, pr=parse_pr(subject),
                              files=files, added_imports=imports))
    return commits


def build_context(git: Git, mac_ref: str) -> Context:
    ledger = git(["show", "%s:%s" % (mac_ref, LEDGER_PATH)])
    project = git(["show", "%s:%s" % (mac_ref, PROJECT_PATH)])
    prefix = mac_ref + ":"
    marker_files = set()
    for line in git(["grep", "-l", "// MAC:", mac_ref, "--", "Conduit", "Shared", "ConduitWidgets"]).splitlines():
        line = line.strip()
        if line.startswith(prefix):
            line = line[len(prefix):]
        if line:
            marker_files.add(line)
    sync_lines = []
    for line in git(["grep", "-n", "keep in sync", mac_ref, "--", "ConduitMac"]).splitlines():
        sync_lines.append(line[len(prefix):] if line.startswith(prefix) else line)
    return Context(
        ledger_patterns=parse_ledger_paths(ledger),
        mac_excludes=parse_mac_excludes(project),
        sync_basenames=parse_sync_basenames(sync_lines),
        mac_marker_files=marker_files,
        keep_off_patterns=parse_keep_off_patterns(ledger),
    )


def _count(git: Git, base: str, tip: str) -> int:
    return int(git(["rev-list", "--count", "%s..%s" % (base, tip)]).strip() or "0")


def release_steps(git: Git, base: str, head: str, tag_glob: str = "ios/v*") -> List[Step]:
    base_sha = git(["rev-parse", base]).strip()
    head_sha = git(["rev-parse", head]).strip()
    tags = git(["tag", "-l", "--sort=creatordate", tag_glob]).split()
    cut_label: Dict[str, str] = {}
    for tag in tags:           # creatordate order: the last tag of a cut names it
        try:
            cut = git(["merge-base", tag, head_sha]).strip()
        except RuntimeError:
            continue
        if cut == base_sha:
            continue
        try:
            git(["merge-base", "--is-ancestor", base_sha, cut])
        except RuntimeError:
            continue
        cut_label[cut] = tag
    ordered = sorted(cut_label, key=lambda c: _count(git, base_sha, c))
    stops = [(cut_label[c], c) for c in ordered]
    if not stops or stops[-1][1] != head_sha:
        stops.append((head, head_sha))
    steps: List[Step] = []
    prev = base_sha
    for label, sha in stops:
        steps.append(Step(label=label, sha=sha, count=_count(git, prev, sha)))
        prev = sha
    return steps


def _commit_line(c: Commit) -> str:
    pr = " #%d" % c.pr if c.pr is not None else ""
    return "- `%s`%s %s -- %s" % (c.sha[:8], pr, c.subject, "; ".join(c.reasons))


def _section(title: str, commits: List[Commit]) -> List[str]:
    lines = ["## " + title, ""]
    lines.extend(_commit_line(c) for c in commits) if commits else lines.append("None.")
    lines.append("")
    return lines


def render_report(commits: List[Commit], steps: List[Step], base: str, head: str,
                  baseline_failures: List[str]) -> str:
    total = sum(s.count for s in steps)
    out = ["# Upstream triage", "", "## Range", "",
           "- Base: `%s`" % base[:8],
           "- Head: `%s`" % head,
           "- Commits in range (including merges): %d" % total,
           "- Non-merge commits listed below: %d" % len(commits), "",
           "## Merge steps", "", "| Step | Commit | Commits |", "|---|---|---|"]
    # The head row shows no sha: the head commit is also a commit line in its group section.
    out.extend("| %s | %s | %d |" % (s.label, "-" if s.label == head else "`%s`" % s.sha[:8], s.count)
               for s in steps)
    out.append("")
    for group in GROUPS:
        out.extend(_section(GROUP_TITLES[group], [c for c in commits if c.group == group]))
        if group == "gate-off":
            out.extend(_section("Needs a Mac entry point (candidates)",
                                [c for c in commits if c.new_v2_surface]))
    out.extend(_section("Live check list", [c for c in commits if c.rich]))
    out.extend(["## Baseline failures", ""])
    out.extend("- %s" % f for f in baseline_failures) if baseline_failures else out.append("None.")
    out.extend(["", "## Decisions for the user", ""])
    return "\n".join(out)


def _load_baseline(path: Optional[str]) -> List[str]:
    if not path:
        return []
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict):
        data = data.get("failures", [])
    return [str(x) for x in data]


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Triage upstream commits for the Mac port.")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--mac-ref", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--json", required=True, dest="json_out")
    ap.add_argument("--report", required=True)
    ap.add_argument("--baseline")
    args = ap.parse_args(argv)

    git = run_git(args.repo)
    base = git(["merge-base", args.mac_ref, args.head]).strip()
    ctx = build_context(git, args.mac_ref)
    commits = [classify(c, ctx) for c in collect_commits(git, base, args.head)]
    steps = release_steps(git, base, args.head)
    failures = _load_baseline(args.baseline)

    with open(args.json_out, "w", encoding="utf-8") as fh:
        json.dump({"base": base, "head": args.head, "steps": [asdict(s) for s in steps],
                   "commits": [asdict(c) for c in commits], "baseline_failures": failures},
                  fh, indent=2)
        fh.write("\n")
    with open(args.report, "w", encoding="utf-8") as fh:
        fh.write(render_report(commits, steps, base, args.head, failures))
    return 0


if __name__ == "__main__":
    sys.exit(main())
