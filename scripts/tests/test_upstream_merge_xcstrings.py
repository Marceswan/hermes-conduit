"""Tests for scripts/upstream-sync/merge-xcstrings.py (stdlib only)."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR, load_module

m = load_module("merge_xcstrings", "upstream-sync/merge-xcstrings.py")
SCRIPT = os.path.join(SCRIPTS_DIR, "upstream-sync", "merge-xcstrings.py")


def cat(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def loc(v):
    return {"localizations": {"de": {"stringUnit": {"state": "translated", "value": v}}}}


class MergeTests(unittest.TestCase):
    def test_keeps_ours_order_and_appends_new_theirs_keys(self):
        out, c = m.merge(cat({"a": {}, "b": {}}), cat({"b": {}, "a": {}, "mac": {}}),
                         cat({"a": {}, "b": {}, "new": {}}))
        self.assertEqual(list(out["strings"]), ["b", "a", "mac", "new"])
        self.assertEqual(c, [])

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
        self.assertEqual(out["strings"]["k"],
                         {"localizations": {"de": {"v": 2}, "fr": {"v": 3}}})
        self.assertEqual(c, [])

    def test_conflicting_translation_reported(self):
        out, c = m.merge(cat({"k": loc("x")}), cat({"k": loc("ours")}), cat({"k": loc("theirs")}))
        self.assertEqual(c, ["strings/k/localizations/de/stringUnit/value"])
        self.assertEqual(out["strings"]["k"], loc("ours"))

    def test_dumps_format_round_trips_repo_catalog(self):
        raw = subprocess.run(["git", "show", "HEAD:Conduit/AppShortcuts.xcstrings"],
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(m.dumps(json.loads(raw)), raw)

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            def write(name, obj):
                path = os.path.join(tmp, name)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(m.dumps(obj))
                return path

            def run(b, o, t, out):
                return subprocess.run([sys.executable, SCRIPT, b, o, t, "-o", out],
                                      capture_output=True, text=True)

            b = write("base.json", cat({"k": loc("x")}))
            clean_t = write("clean_theirs.json", cat({"k": loc("y")}))
            o = write("ours.json", cat({"k": loc("x")}))
            out = os.path.join(tmp, "out_clean.json")
            result = run(b, o, clean_t, out)
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(out, encoding="utf-8") as handle:
                self.assertEqual(json.load(handle)["strings"]["k"], loc("y"))

            o2 = write("ours2.json", cat({"k": loc("ours")}))
            t2 = write("theirs2.json", cat({"k": loc("theirs")}))
            out2 = os.path.join(tmp, "out_conflict.json")
            result = run(b, o2, t2, out2)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("strings/k/localizations/de/stringUnit/value", result.stdout)
            with open(out2, encoding="utf-8") as handle:
                self.assertEqual(json.load(handle)["strings"]["k"], loc("ours"))

    def test_cli_missing_or_empty_base_is_empty_object(self):
        with tempfile.TemporaryDirectory() as tmp:
            o = os.path.join(tmp, "o.json")
            t = os.path.join(tmp, "t.json")
            for path, obj in ((o, cat({"a": {}})), (t, cat({"b": {}}))):
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(m.dumps(obj))
            empty = os.path.join(tmp, "empty.json")
            open(empty, "w").close()
            for base in (empty, os.path.join(tmp, "missing.json")):
                out = os.path.join(tmp, "out.json")
                result = subprocess.run([sys.executable, SCRIPT, base, o, t, "-o", out],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                with open(out, encoding="utf-8") as handle:
                    self.assertEqual(list(json.load(handle)["strings"]), ["a", "b"])


if __name__ == "__main__":
    unittest.main()
