#!/usr/bin/env python3
"""Read xcodebuild test logs and report tests that newly fail against a baseline.

Usage:
  mac-test-failures.py parse LOG -o OUT.json
  mac-test-failures.py compare BASELINE.json CURRENT.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys

OLD_STYLE = re.compile(r"Test Case '-\[\w+\.(\w+) (\w+)\]' (passed|failed)")
NEW_STYLE = re.compile(r"Test case '(\w+)\.(\w+)\(\)' (passed|failed)")
RESULT = re.compile(r"\*\* TEST (?:EXECUTE )?(SUCCEEDED|FAILED) \*\*")


def parse(log: str) -> dict:
    failed = set()
    passed = 0
    result = "UNKNOWN"
    for line in log.splitlines():
        m = OLD_STYLE.search(line) or NEW_STYLE.search(line)
        if m:
            if m.group(3) == "passed":
                passed += 1
            else:
                failed.add("%s/%s" % (m.group(1), m.group(2)))
            continue
        m = RESULT.search(line)
        if m:
            result = m.group(1)
    return {
        "result": result,
        "failed": sorted(failed),
        "passed": passed,
        "failed_classes": sorted({t.split("/")[0] for t in failed}),
    }


def regressions(baseline: dict, current: dict) -> list:
    known = set(baseline.get("failed", []))
    return sorted(t for t in current.get("failed", []) if t not in known)


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("parse")
    p.add_argument("log")
    p.add_argument("-o", "--output", required=True)
    c = sub.add_parser("compare")
    c.add_argument("baseline")
    c.add_argument("current")
    args = ap.parse_args(argv)

    if args.cmd == "parse":
        with open(args.log, encoding="utf-8", errors="replace") as fh:
            data = parse(fh.read())
        with open(args.output, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        print("result=%s passed=%d failed=%d" % (data["result"], data["passed"], len(data["failed"])))
        return 0

    found = regressions(_load(args.baseline), _load(args.current))
    for t in found:
        print(t)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
