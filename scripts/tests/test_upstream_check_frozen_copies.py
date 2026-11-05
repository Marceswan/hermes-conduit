"""Tests for scripts/upstream-sync/check-frozen-copies.py (stdlib only)."""

import os
import subprocess
import tempfile
import unittest

from _util import load_module

c = load_module("check_frozen_copies", "upstream-sync/check-frozen-copies.py")

UPSTREAM = """struct LoginView: View {
    var body: some View {
        Text("a")
        Text("new line")
        Text("new line 2")
    }
}
"""
COPY = """struct LoginView: View {
    var body: some View {
        Text("a") // MAC: keep
        // MAC: extra line
        Text("mac only")
    }
}
"""


class HunkTests(unittest.TestCase):
    def test_lists_upstream_lines_the_copy_lacks(self):
        hunks = c.find_hunks(UPSTREAM, COPY)
        self.assertEqual(len(hunks), 1)
        self.assertEqual([line for _, line in hunks[0]], ['Text("new line")', 'Text("new line 2")'])
        self.assertEqual(hunks[0][0][0], 4)

    def test_mac_comments_and_spacing_are_ignored(self):
        self.assertEqual(c.find_hunks('Text( "a" )\n', 'Text(  "a" ) // MAC: x\n'), [])

    def test_identical_text_has_no_hunks(self):
        self.assertEqual(c.find_hunks(UPSTREAM, UPSTREAM), [])

    def test_separate_runs_are_separate_hunks(self):
        up = "a1\nsame\nb1\nsame2\nc1\n"
        hunks = c.find_hunks(up, "same\nsame2\n")
        self.assertEqual([[l for _, l in h] for h in hunks], [["a1"], ["b1"], ["c1"]])

    def test_bracket_only_lines_do_not_split_a_hunk(self):
        hunks = c.find_hunks("x1\n}\nx2\n", "other\n")
        self.assertEqual([[l for _, l in h] for h in hunks], [["x1", "x2"]])

    def test_rename_maps_type_names(self):
        self.assertEqual(c.find_hunks("let v = OldName()\n", "let v = NewName()\n", {"OldName": "NewName"}), [])
        self.assertEqual(len(c.find_hunks("let v = OldName()\n", "let v = NewName()\n")), 1)


class CliTests(unittest.TestCase):
    def test_cli_reads_ref_and_copies(self):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        with tempfile.TemporaryDirectory() as tmp:
            def git(*a):
                subprocess.run(("git", "-C", tmp) + a, check=True, capture_output=True, env=env)
            git("init", "-q")
            os.makedirs(os.path.join(tmp, "up"))
            os.makedirs(os.path.join(tmp, "copies"))
            with open(os.path.join(tmp, "up", "A.swift"), "w") as f:
                f.write(UPSTREAM)
            with open(os.path.join(tmp, "copies", "A.swift"), "w") as f:
                f.write(COPY)
            git("add", "-A")
            git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "x")
            import sys
            script = c.__file__
            result = subprocess.run(
                [sys.executable, script, "--ref", "HEAD", "--copies", "copies", "up/A.swift"],
                cwd=tmp, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("up/A.swift: 1 hunk(s)", result.stdout)
            self.assertIn('+ Text("new line")', result.stdout)
            missing = subprocess.run(
                [sys.executable, script, "--ref", "HEAD", "--copies", "copies", "up/B.swift"],
                cwd=tmp, capture_output=True, text=True)
            self.assertEqual(missing.returncode, 2)


if __name__ == "__main__":
    unittest.main()
