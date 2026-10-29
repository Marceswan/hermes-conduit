"""Regression coverage for scripts/upstream-sync/triage.py (git collection, steps, report)."""
import os
import subprocess
import tempfile
import unittest
from _util import load_module
t = load_module("upstream_triage_git", "upstream-sync/triage.py")
from test_upstream_triage import PROJECT  # noqa: E402

LEDGER_ONE_ROW = """| File | Rule | Reason | Mac side |
|---|---|---|---|
| Conduit/Views/RootView.swift `MainView` chat chrome | R4 | x | y |
"""


class GitFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._saved = {k: os.environ.get(k) for k in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM")}
        os.environ["GIT_CONFIG_GLOBAL"] = "/dev/null"
        os.environ["GIT_CONFIG_SYSTEM"] = "/dev/null"
        cls._tmp = tempfile.TemporaryDirectory()
        cls.repo = os.path.join(cls._tmp.name, "repo")
        os.makedirs(cls.repo)
        cls.git = staticmethod(t.run_git(cls.repo))
        cls._build()

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()
        for key, value in cls._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @classmethod
    def _g(cls, *args):
        return cls.git(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + list(args)).strip()

    @classmethod
    def _write(cls, rel, text):
        path = os.path.join(cls.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    @classmethod
    def _commit(cls, msg, files):
        for rel, text in files.items():
            cls._write(rel, text)
        cls._g("add", "-A")
        cls._g("commit", "-q", "-m", msg)
        return cls._g("rev-parse", "HEAD")

    @classmethod
    def _build(cls):
        cls._g("init", "-q", "-b", "main")
        cls.c1 = cls._commit("c1", {"README.md": "r\n", "Conduit/Models/X.swift": "a\n",
                                    "Conduit/Views/RootView.swift": "v\n"})
        cls._g("tag", "ios/v0.9-build-0")
        cls._g("branch", "mac")
        cls.c2 = cls._commit("c2 (#2)", {"Conduit/Models/X.swift": "a\nb\n"})
        cls._g("branch", "rel")
        cls.c3 = cls._commit("c3", {"Conduit/Views/V2/V2Shell.swift": "s\n"})
        cls.c4 = cls._commit("c4", {"Conduit/Views/RootView.swift": "v\nw\n",
                                    "Shared/Widgets/A.swift": "import ActivityKit\n"})
        cls._g("checkout", "-q", "rel")
        cls._commit("r1", {"rel.txt": "r\n"})
        cls._g("tag", "ios/v1.0.0-build-1")
        cls._g("tag", "odd/a")
        cls._g("checkout", "-q", "-b", "rel2", cls.c3)
        cls._commit("r2", {"rel2.txt": "r\n"})
        cls._g("tag", "ios/v1.0.1-build-2")
        cls._g("tag", "odd/b")
        cls._g("checkout", "-q", "mac")
        cls._commit("mac files", {"docs/macos/PORTING_LEDGER.md": LEDGER_ONE_ROW, "project.yml": PROJECT,
                                  "Conduit/Views/Mac.swift": "// MAC: x\n",
                                  "ConduitMac/Sync.swift": "// keep in sync with Conduit/Models/Other.swift\n"})
        cls._g("checkout", "-q", "main")


class ReleaseStepTests(GitFixture):
    def test_steps_use_cut_commit_and_end_at_head(self):
        steps = t.release_steps(self.git, self.c1, "main")
        self.assertEqual([s.label for s in steps], ["ios/v1.0.1-build-2", "main"])
        self.assertEqual(steps[0].sha, self.c3)
        self.assertEqual([s.count for s in steps], [2, 1])

    def test_tags_group_by_major_minor_into_one_step(self):
        steps = t.release_steps(self.git, self.c1, "main", tag_glob="ios/v1.0*")
        self.assertEqual(len(steps), 2)
        self.assertEqual(steps[0].sha, self.c3)

    def test_tags_without_version_group_by_cut(self):
        steps = t.release_steps(self.git, self.c1, "main", tag_glob="odd/*")
        self.assertEqual([s.label for s in steps], ["odd/a", "odd/b", "main"])
        self.assertEqual([s.sha for s in steps[:2]], [self.c2, self.c3])
        self.assertEqual([s.count for s in steps], [1, 1, 1])

    def test_no_tags_gives_single_step(self):
        self.assertEqual([s.label for s in t.release_steps(self.git, self.c1, "main", tag_glob="none/*")], ["main"])


class RunGitTests(GitFixture):
    def test_nonzero_raises(self):
        with self.assertRaises(RuntimeError):
            self.git(["rev-parse", "no-such-ref"])

    def test_grep_no_match_is_empty(self):
        self.assertEqual(self.git(["grep", "-l", "zzzNoMatchzzz", "main"]), "")


class CollectTests(GitFixture):
    def test_collect_and_classify_end_to_end(self):
        ctx = t.build_context(self.git, "mac")
        cs = [t.classify(c, ctx) for c in t.collect_commits(self.git, self.c1, "main")]
        self.assertEqual([c.group for c in cs], ["comes-along", "gate-off", "risk"])
        self.assertIn(("Shared/Widgets/A.swift", "ActivityKit"), cs[2].added_imports)

    def test_context_reads_mac_ref(self):
        ctx = t.build_context(self.git, "mac")
        self.assertIn("Conduit/Views/RootView.swift", ctx.ledger_patterns)
        self.assertIn("Conduit/ConduitApp.swift", ctx.mac_excludes)
        self.assertEqual(ctx.mac_marker_files, {"Conduit/Views/Mac.swift"})
        self.assertIn("Other.swift", ctx.sync_basenames)


class ReportTests(GitFixture):
    def test_report_sections_and_one_line_per_commit(self):
        ctx = t.build_context(self.git, "mac")
        cs = [t.classify(c, ctx) for c in t.collect_commits(self.git, self.c1, "main")]
        md = t.render_report(cs, t.release_steps(self.git, self.c1, "main"), self.c1, "main", ["A/testB"])
        for heading in ("## Range", "## Merge steps", "## Risk", "## Needs a Mac port", "## Gate off on Mac",
                        "## Needs a Mac entry point (candidates)", "## iOS-only or no Mac effect", "## Comes along",
                        "## Live check list", "## Baseline failures"):
            self.assertIn(heading, md)
        self.assertEqual(md.count(cs[2].sha[:8]), 1)
        self.assertIn("A/testB", md)
        self.assertTrue(md.rstrip().endswith("## Decisions for the user"))


class CliTests(GitFixture):
    def test_baseline_in_mac_test_failures_format_is_listed(self):
        import json
        mtf = load_module("mac_test_failures_for_triage", "upstream-sync/mac-test-failures.py")
        log = ("Test case 'ComposerToolCardContrastTests."
               "testReasoningPickerHasAtLeast4_5ToOneContrastInLightAndDark()' failed on 'My Mac' (0.1 seconds)\n"
               "** TEST FAILED **\n")
        out = os.path.join(self._tmp.name, "out_baseline")
        os.makedirs(out)
        with open(os.path.join(out, "b.json"), "w") as fh:
            json.dump(mtf.parse(log), fh)
        rc = t.main(["--repo", self.repo, "--mac-ref", "mac", "--head", "main",
                     "--json", os.path.join(out, "t.json"), "--report", os.path.join(out, "t.md"),
                     "--baseline", os.path.join(out, "b.json")])
        self.assertEqual(rc, 0)
        with open(os.path.join(out, "t.md")) as fh:
            report = fh.read()
        section = report.split("## Baseline failures")[1].split("## Decisions")[0]
        self.assertIn("ComposerToolCardContrastTests/testReasoningPickerHasAtLeast4_5ToOneContrastInLightAndDark",
                      section)

    def test_main_writes_json_and_report(self):
        import json
        out = os.path.join(self._tmp.name, "out")
        os.makedirs(out)
        rc = t.main(["--repo", self.repo, "--mac-ref", "mac", "--head", "main",
                     "--json", os.path.join(out, "t.json"), "--report", os.path.join(out, "t.md")])
        self.assertEqual(rc, 0)
        with open(os.path.join(out, "t.json")) as fh:
            data = json.load(fh)
        self.assertEqual(data["base"], self.c1)
        self.assertEqual([c["group"] for c in data["commits"]], ["comes-along", "gate-off", "risk"])
        with open(os.path.join(out, "t.md")) as fh:
            self.assertIn("## Range", fh.read())


if __name__ == "__main__":
    unittest.main()
