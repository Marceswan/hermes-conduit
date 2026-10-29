"""Tests for scripts/upstream-sync/affected-tests.py (stdlib only)."""

import os
import subprocess
import sys
import tempfile
import unittest

from _util import load_module

a = load_module("affected_tests", "upstream-sync/affected-tests.py")

SWIFT = """import SwiftUI
public struct DashboardSwitcher: View {}
final class SwitcherModel {}
private enum Tab {}
extension AppState {}
@MainActor final class RouteStore {}
"""


class UnitTests(unittest.TestCase):
    def test_declared_types(self):
        self.assertEqual(a.declared_types(SWIFT), {"DashboardSwitcher", "SwitcherModel", "AppState", "RouteStore"})

    def test_classes_naming_matches_whole_words(self):
        tests = {
            "1": "final class MacSwitchTests: XCTestCase { func t() { _ = DashboardSwitcher() } }",
            "2": "final class OtherTests: XCTestCase { func t() { _ = DashboardSwitcherX() } }",
            "3": "class RouteTests: MacTestCase, XCTestCase { var s: RouteStore }",
        }
        self.assertEqual(a.classes_naming({"DashboardSwitcher", "RouteStore"}, tests),
                         ["MacSwitchTests", "RouteTests"])

    def test_no_types_gives_no_classes(self):
        self.assertEqual(a.classes_naming(set(), {"1": "class X: XCTestCase {}"}), [])


class CliTests(unittest.TestCase):
    def test_cli_lists_class_for_changed_shared_file(self):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        with tempfile.TemporaryDirectory() as tmp:
            def git(*args):
                subprocess.run(("git", "-C", tmp) + args, check=True, capture_output=True, env=env)
            def put(path, text):
                full = os.path.join(tmp, path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "w") as handle:
                    handle.write(text)
            git("init", "-q")
            put("Conduit/Views/Switcher.swift", "struct DashboardSwitcher {}\n")
            put("ConduitMacTests/SwitchTests.swift",
                "final class SwitchTests: XCTestCase { let s = DashboardSwitcher() }\n")
            put("ConduitMacTests/OtherTests.swift", "final class OtherTests: XCTestCase {}\n")
            git("add", "-A")
            git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "a")
            put("Conduit/Views/Switcher.swift", "struct DashboardSwitcher { var x = 1 }\n")
            git("add", "-A")
            git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "b")
            result = subprocess.run(
                [sys.executable, a.__file__,
                 "--repo", tmp, "--base", "HEAD~1", "--head", "HEAD"],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split(), ["SwitchTests"])


if __name__ == "__main__":
    unittest.main()
