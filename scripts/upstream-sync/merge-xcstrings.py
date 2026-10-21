#!/usr/bin/env python3
"""Three-way, key-by-key merge of .xcstrings catalogs.

Usage: merge-xcstrings.py BASE OURS THEIRS -o OUT

A missing or empty BASE file means {}. OUT is always written. At a conflict
the merged file keeps "ours", the script prints one line per conflict path,
and the exit code is 1. A clean merge exits 0. Key order follows "ours";
keys only in "theirs" are appended in their order.
"""
from __future__ import annotations

import argparse
import json
import os
import sys


def dumps(obj: dict) -> str:
    """Serialize a catalog the way Xcode and scripts/l10n.py do."""
    return json.dumps(obj, indent=2, separators=(",", " : "), ensure_ascii=False) + "\n"


def _join(path: str, key: str) -> str:
    return key if not path else path + "/" + key


def _merge_value(b, o, t, path, conflicts):
    if o == t:
        return o
    if o == b:
        return t
    if t == b:
        return o
    if isinstance(o, dict) and isinstance(t, dict) and (b is None or isinstance(b, dict)):
        return _merge_dict(b or {}, o, t, path, conflicts)
    conflicts.append(path)
    return o


def _merge_dict(b, o, t, path, conflicts):
    merged = {}
    keys = list(o) + [k for k in t if k not in o]
    for key in keys:
        value = _merge_value(b.get(key), o.get(key), t.get(key), _join(path, key), conflicts)
        if value is not None:
            merged[key] = value
    return merged


def merge(base: dict, ours: dict, theirs: dict):
    """Return (merged, conflict_paths). Conflicts keep the "ours" value."""
    conflicts = []
    merged = _merge_value(base, ours, theirs, "", conflicts)
    return merged, conflicts


def _load(path: str, allow_missing: bool = False) -> dict:
    if allow_missing and not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if allow_missing and not text.strip():
        return {}
    return json.loads(text)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Three-way merge of .xcstrings catalogs.")
    parser.add_argument("base")
    parser.add_argument("ours")
    parser.add_argument("theirs")
    parser.add_argument("-o", "--output", required=True)
    args = parser.parse_args(argv)

    merged, conflicts = merge(_load(args.base, True), _load(args.ours), _load(args.theirs))
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(dumps(merged))
    for path in conflicts:
        print(path)
    return 1 if conflicts else 0


if __name__ == "__main__":
    sys.exit(main())
