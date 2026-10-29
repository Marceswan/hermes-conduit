#!/usr/bin/env python3
"""List the ConduitMacTests classes that name a type declared in a changed shared file.

Usage: affected-tests.py --base REV --head REV [--repo DIR]

The script takes the Swift files that changed between BASE and HEAD under
Conduit/, Shared/ and ConduitWidgets/. It takes each type name that those
files declare (names of 4 or more characters). It prints, one per line, each
XCTestCase class in ConduitMacTests whose file names one of those types as a
whole word. The exit code is 0.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

SHARED_DIRS = ("Conduit/", "Shared/", "ConduitWidgets/")
MIN_NAME = 4
DECLARATION = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:public|private|fileprivate|internal|open|final|indirect)\s+)*"
    r"(?:struct|class|enum|protocol|actor|typealias|extension)\s+(\w+)", re.M)
TEST_CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*[\w.,\s]*XCTestCase", re.M)


def declared_types(text: str) -> set:
    return {name for name in DECLARATION.findall(text) if len(name) >= MIN_NAME}


def classes_naming(types, tests: dict) -> list:
    """tests maps a file name to its text. Return sorted class names."""
    if not types:
        return []
    pattern = re.compile(r"\b(?:%s)\b" % "|".join(re.escape(t) for t in sorted(types)))
    found = set()
    for text in tests.values():
        if pattern.search(text):
            found.update(TEST_CLASS.findall(text))
    return sorted(found)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="List the test classes that a merge step affects.")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--repo", default=".")
    args = parser.parse_args(argv)

    diff = subprocess.run(["git", "-C", args.repo, "diff", "--name-only", args.base, args.head],
                          capture_output=True, text=True)
    if diff.returncode != 0:
        print(diff.stderr.strip(), file=sys.stderr)
        return 2
    types = set()
    for path in diff.stdout.splitlines():
        full = os.path.join(args.repo, path)
        if path.endswith(".swift") and path.startswith(SHARED_DIRS) and os.path.exists(full):
            with open(full, encoding="utf-8", errors="replace") as handle:
                types |= declared_types(handle.read())
    tests = {}
    tests_dir = os.path.join(args.repo, "ConduitMacTests")
    for root, _, files in os.walk(tests_dir):
        for name in files:
            if name.endswith(".swift"):
                path = os.path.join(root, name)
                with open(path, encoding="utf-8", errors="replace") as handle:
                    tests[path] = handle.read()
    for name in classes_naming(types, tests):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
