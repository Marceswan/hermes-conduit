"""Regression coverage for scripts/upstream-sync/triage.py (classification)."""
import unittest
from _util import load_module
t = load_module("upstream_triage", "upstream-sync/triage.py")

LEDGER = """| File | Rule | Reason | Mac side |
|---|---|---|---|
| Conduit/Views/RootView.swift `MainView` chat chrome | R4 | x | y |
| Conduit/Services/AppState.swift `requestOpenSession`, `openBotChat` | R4 | x | y |
| ConduitWidgets/*, Shared/Widgets/*, Conduit/Localizable.xcstrings | shared source | x | y |
| Menu: Find in Chat (Cmd-F) | done | x | y |
| ConduitMac/Compat/App/FormShim.swift (new; no upstream file edited) | R1-style | x | y |

## Kept off on Mac

| Feature | Gate | Reason | Date |
|---|---|---|---|
| Conduit/Views/V2/ | V2Shell.swift `defaultValue` | no UI rework | 2026-10-21 |
"""
PROJECT = """targets:
  ConduitMac:
    type: application
    sources:
      - path: ConduitMac
        excludes:
          - "Compat/Module/**"
      - path: Shared
      - path: Conduit
        excludes:
          - "ConduitApp.swift"
          # comment
          - "Views/Components/SelectableTextView.swift"
    settings:
      base:
        PRODUCT_NAME: Conduit
  ConduitMacTests:
    sources:
      - path: Conduit
        excludes:
          - "Nope.swift"
"""

def ctx(**kw):
    base = dict(ledger_patterns=t.parse_ledger_paths(LEDGER), mac_excludes=t.parse_mac_excludes(PROJECT),
                sync_basenames={"MarkupBlock.swift"}, mac_marker_files={"Conduit/Views/SidebarView.swift"},
                keep_off_patterns=t.parse_keep_off_patterns(LEDGER))
    base.update(kw)
    return t.Context(**base)

def commit(files, subject="x (#1)", imports=()):
    return t.Commit(sha="a" * 40, subject=subject, pr=t.parse_pr(subject), files=list(files), added_imports=list(imports))

class ParseTests(unittest.TestCase):
    def test_parse_pr_takes_last(self):
        self.assertEqual(t.parse_pr("Carry #843 (#924)"), 924)
        self.assertIsNone(t.parse_pr("no number"))
    def test_ledger_paths_only_upstream(self):
        p = t.parse_ledger_paths(LEDGER)
        self.assertIn("Conduit/Views/RootView.swift", p)
        self.assertIn("Conduit/Services/AppState.swift", p)
        self.assertIn("ConduitWidgets/*", p)
        self.assertIn("Shared/Widgets/*", p)
        self.assertNotIn("ConduitMac/Compat/App/FormShim.swift", p)
        self.assertFalse(any(x.startswith("Menu") for x in p))
    def test_keep_off(self):
        self.assertEqual(t.parse_keep_off_patterns(LEDGER), ["Conduit/Views/V2/"])
        self.assertEqual(t.parse_keep_off_patterns("| a | b |"), [])
    def test_mac_excludes_only_conduitmac_conduit_source(self):
        self.assertEqual(t.parse_mac_excludes(PROJECT),
                         ["Conduit/ConduitApp.swift", "Conduit/Views/Components/SelectableTextView.swift"])
    def test_sync_basenames(self):
        lines = ["ConduitMac/WebViews/WebViewTwins.swift:17:// keep in sync with MarkupBlock.swift `MarkupMessageProxy`",
                 "ConduitMac/App/ConduitMacApp.swift:92:// Ported from ConduitApp.swift; keep in sync"]
        self.assertEqual(t.parse_sync_basenames(lines), {"MarkupBlock.swift", "ConduitApp.swift"})

class ClassifyTests(unittest.TestCase):
    def test_precedence_risk_over_port(self):
        c = t.classify(commit([("M", "project.yml"), ("M", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "risk")
    def test_rename_of_ledger_file_is_risk(self):
        c = t.classify(commit([("R", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "risk")
    def test_risky_import_in_mac_compiled_file(self):
        c = t.classify(commit([("A", "Shared/Widgets/HermesTurnActivity.swift")],
                              imports=[("Shared/Widgets/HermesTurnActivity.swift", "ActivityKit")]), ctx())
        self.assertEqual(c.group, "risk")
    def test_risky_import_in_ios_only_target_is_not_risk(self):
        c = t.classify(commit([("A", "ConduitWatch/Foo.swift")], imports=[("ConduitWatch/Foo.swift", "HealthKit")]), ctx())
        self.assertEqual(c.group, "ios-only")
    def test_ledger_marker_and_sync_files_are_ports(self):
        for path in ("Conduit/Views/RootView.swift", "Conduit/Views/SidebarView.swift",
                     "Conduit/Views/Components/MarkupBlock.swift", "Conduit/Views/Components/SelectableTextView.swift"):
            self.assertEqual(t.classify(commit([("M", path)]), ctx()).group, "mac-port", path)
    def test_v2_is_gate_off_and_new_file_flags_surface(self):
        c = t.classify(commit([("A", "Conduit/Views/V2/V2ArtifactsViews.swift")]), ctx())
        self.assertEqual(c.group, "gate-off")
        self.assertTrue(c.new_v2_surface)
    def test_port_beats_gate_off(self):
        c = t.classify(commit([("M", "Conduit/Views/V2/V2Shell.swift"), ("M", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "mac-port")
    def test_ios_only_needs_every_file(self):
        self.assertEqual(t.classify(commit([("M", "ConduitTests/A.swift"), ("M", "docs/x.md")]), ctx()).group, "ios-only")
        self.assertEqual(t.classify(commit([("M", "ConduitTests/A.swift"), ("M", "Conduit/Models/X.swift")]), ctx()).group, "comes-along")
    def test_rich_by_path_or_subject(self):
        self.assertTrue(t.classify(commit([("M", "Conduit/Cards/RichCard.swift")]), ctx()).rich)
        self.assertTrue(t.classify(commit([("M", "Conduit/Models/X.swift")], subject="Chat tables: Copy Table (#693)"), ctx()).rich)
        self.assertFalse(t.classify(commit([("M", "Conduit/Voice/X.swift")], subject="Voice timers (#1)"), ctx()).rich)
    def test_every_commit_gets_a_reason(self):
        c = t.classify(commit([("M", "Conduit/Models/X.swift")]), ctx())
        self.assertEqual(c.group, "comes-along")
        self.assertTrue(c.reasons)

    def test_reasons_keep_every_matching_rule(self):
        c = t.classify(commit([("M", "project.yml"), ("M", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "risk")
        self.assertEqual(c.reasons[0], "project.yml changed")
        self.assertIn("ledger file: Conduit/Views/RootView.swift", c.reasons)
    def test_gate_off_reason_follows_port_reason(self):
        c = t.classify(commit([("M", "Conduit/Views/V2/V2Shell.swift"), ("M", "Conduit/Views/RootView.swift")]), ctx())
        self.assertEqual(c.group, "mac-port")
        self.assertEqual(c.reasons, ["ledger file: Conduit/Views/RootView.swift",
                                     "kept off on Mac: Conduit/Views/V2/V2Shell.swift"])
    def test_one_path_records_ledger_and_sync_reasons(self):
        c = t.classify(commit([("M", "Conduit/Views/RootView.swift")]), ctx(sync_basenames={"RootView.swift"}))
        self.assertEqual(c.reasons, ["ledger file: Conduit/Views/RootView.swift",
                                     "keep-in-sync file: Conduit/Views/RootView.swift"])


if __name__ == "__main__":
    unittest.main()
