# Upstream sync reports

This folder holds the reports of the `/upstream-sync` skill (`.claude/skills/upstream-sync/SKILL.md`). Each run of the skill writes one report, named `YYYY-MM-DD.md` after the day of the run. The report lists the upstream range, the planned merge steps, and every upstream commit in one group. It also lists the Mac ports and gate-offs, the baseline test failures, the live-check list and the decisions that the user must make. The skill stops after it writes the report and waits for the user to approve it. After the merge, the skill adds the results to the same report: the steps merged, the ports and gates, the gate results, the live-check table and anything deferred.

The skill uses these scripts in `scripts/upstream-sync/`. Each has unit tests in `scripts/tests/test_upstream_*.py`.

- `triage.py` groups the upstream commits, names the merge steps and writes the report.
- `mac-test-failures.py` parses an `xcodebuild` log (`parse`) and compares two parsed runs (`compare`).
- `merge-xcstrings.py` merges the string catalogs key by key. With `--check-order OURS THEIRS` it prints how many common keys have a different order than in THEIRS.
- `affected-tests.py` lists the `ConduitMacTests` classes that name a type declared in a shared file that a merge step changed.
- `check-frozen-copies.py` lists the hunks of the upstream sign-in files (`LoginView.swift`, `ConnectionSetupView.swift`, `ConnectionSetupForm.swift`, `ConnectionSetupComponents.swift`) that the frozen copies in `ConduitMac/Login/` do not contain.
