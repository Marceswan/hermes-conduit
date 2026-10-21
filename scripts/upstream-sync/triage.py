#!/usr/bin/env python3
"""Classify upstream commits for the /upstream-sync skill (pure logic, stdlib only)."""
# No "from __future__ import annotations": load_module() does not register the module in
# sys.modules, and dataclasses fails on string annotations then. typing types suffice on 3.9.
import fnmatch
import re
import sys
from dataclasses import dataclass, field
from typing import List, Optional, Set, Tuple

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
        elif matches(path, ctx.mac_excludes):
            port.append("Mac-excluded file: %s" % path)
        elif path in ctx.mac_marker_files:
            port.append("Mac-marked file: %s" % path)
        elif path.rsplit("/", 1)[-1] in ctx.sync_basenames:
            port.append("keep-in-sync file: %s" % path)
        if path.startswith(V2_PREFIX) or matches(path, ctx.keep_off_patterns):
            gate.append("kept off on Mac: %s" % path)
        if letter == "A" and path.startswith(V2_PREFIX):
            commit.new_v2_surface = True

    for path, framework in commit.added_imports:
        if framework in RISK_FRAMEWORKS and _compiled_on_mac(path, ctx):
            risk.append("new import of %s in Mac-compiled file: %s" % (framework, path))

    if risk:
        group, reasons = "risk", risk
    elif port:
        group, reasons = "mac-port", port
    elif gate:
        group, reasons = "gate-off", gate
    elif commit.files and all(_is_ios_only(p) for _, p in commit.files):
        group, reasons = "ios-only", ["every file is iOS-only or has no Mac effect"]
    else:
        group, reasons = "comes-along", ["shared code; the Mac compiles it"]

    commit.group = group
    commit.reasons = reasons
    commit.rich = (any(p.startswith(RICH_PATH_PREFIXES) for _, p in commit.files)
                   or bool(RICH_SUBJECT.search(commit.subject)))
    return commit


def main(argv=None) -> int:
    sys.stderr.write("triage.py is a library; use the collect script.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
