"""Tests for scripts/upstream-sync/mac-test-failures.py."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR, load_module

f = load_module("mac_test_failures", "upstream-sync/mac-test-failures.py")
SCRIPT = os.path.join(SCRIPTS_DIR, "upstream-sync", "mac-test-failures.py")

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


class CliTests(unittest.TestCase):
    def run_compare(self, baseline, current):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for name, data in (("base.json", baseline), ("cur.json", current)):
                p = os.path.join(d, name)
                with open(p, "w", encoding="utf-8") as fh:
                    json.dump(data, fh)
                paths.append(p)
            return subprocess.run(
                [sys.executable, SCRIPT, "compare"] + paths,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

    def test_compare_exits_1_on_regression(self):
        r = self.run_compare({"failed": ["A/x"]}, {"failed": ["A/x", "B/y"]})
        self.assertEqual(r.returncode, 1)
        self.assertIn("B/y", r.stdout)
        self.assertNotIn("A/x", r.stdout)

    def test_compare_exits_0_without_regression(self):
        r = self.run_compare({"failed": ["A/x"]}, {"failed": ["A/x"]})
        self.assertEqual(r.returncode, 0)

    def test_parse_writes_json(self):
        with tempfile.TemporaryDirectory() as d:
            log, out = os.path.join(d, "l.log"), os.path.join(d, "o.json")
            with open(log, "w", encoding="utf-8") as fh:
                fh.write(LOG)
            r = subprocess.run([sys.executable, SCRIPT, "parse", log, "-o", out],
                               stdout=subprocess.PIPE, universal_newlines=True)
            self.assertEqual(r.returncode, 0)
            with open(out, encoding="utf-8") as fh:
                self.assertEqual(json.load(fh)["passed"], 2)


if __name__ == "__main__":
    unittest.main()
