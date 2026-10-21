#!/usr/bin/env python3
"""List the hunks of upstream sign-in files that the frozen Mac copies lack.

Usage: check-frozen-copies.py [--ref REF] [--copies DIR] [--rename OLD=NEW ...] [PATH ...]

Each PATH is an upstream file. The default is the table UPSTREAM_PATHS below.
The script reads each file at REF (default upstream/main) with git show. It
compares the file with the union of the Swift files in DIR (default
ConduitMac/Login). A hunk is a run of consecutive upstream lines that the
copies do not contain. Before the compare, the script removes `// MAC:`
comments and blank lines, collapses spaces, and applies the --rename pairs.
Lines that hold only brackets are neutral. The exit code is 0, also when
hunks exist. The exit code is 2 when a file cannot be read.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys

UPSTREAM_PATHS = [
    "Conduit/Views/LoginView.swift",
    "Conduit/Views/ConnectionSetupView.swift",
    "Conduit/Views/ConnectionSetupForm.swift",
    "Conduit/Views/ConnectionSetupComponents.swift",
]
COPY_DIR = "ConduitMac/Login"

MAC_COMMENT = re.compile(r"\s*//\s*MAC:.*$")
NEUTRAL = re.compile(r"^[\s{}()\[\],;]*$")


def normalize(text: str, renames=None) -> list:
    """Return (line number, normalized line) pairs. Blank and MAC-only lines are dropped."""
    out = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = MAC_COMMENT.sub("", raw)
        for old, new in (renames or {}).items():
            line = re.sub(r"\b%s\b" % re.escape(old), new, line)
        line = " ".join(line.split())
        if line:
            out.append((number, line))
    return out


def find_hunks(upstream_text: str, copy_text: str, renames=None) -> list:
    """Return hunks as lists of (line number, line). Line numbers are upstream's."""
    have = {line for _, line in normalize(copy_text, renames)}
    hunks = []
    current = []
    for number, line in normalize(upstream_text, renames):
        if NEUTRAL.match(line):
            continue
        if line in have:
            if current:
                hunks.append(current)
                current = []
        else:
            current.append((number, line))
    if current:
        hunks.append(current)
    return hunks


def _git_show(ref: str, path: str) -> str:
    result = subprocess.run(["git", "show", "%s:%s" % (ref, path)], capture_output=True, text=True)
    if result.returncode != 0:
        raise OSError("git show %s:%s failed: %s" % (ref, path, result.stderr.strip()))
    return result.stdout


def _read_copies(directory: str) -> str:
    texts = []
    for path in sorted(glob.glob(os.path.join(directory, "*.swift"))):
        with open(path, encoding="utf-8") as handle:
            texts.append(handle.read())
    if not texts:
        raise OSError("no Swift files in " + directory)
    return "\n".join(texts)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="List upstream hunks that the frozen Mac copies lack.")
    parser.add_argument("paths", nargs="*", default=UPSTREAM_PATHS)
    parser.add_argument("--ref", default="upstream/main")
    parser.add_argument("--copies", default=COPY_DIR)
    parser.add_argument("--rename", action="append", default=[], metavar="OLD=NEW")
    args = parser.parse_args(argv)

    renames = {}
    for pair in args.rename:
        old, _, new = pair.partition("=")
        renames[old] = new
    try:
        copy_text = _read_copies(args.copies)
        for path in args.paths:
            hunks = find_hunks(_git_show(args.ref, path), copy_text, renames)
            print("%s: %d hunk(s)" % (path, len(hunks)))
            for hunk in hunks:
                print("  @@ line %d, %d line(s)" % (hunk[0][0], len(hunk)))
                for _, line in hunk:
                    print("  + " + line)
    except OSError as error:
        print(str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
