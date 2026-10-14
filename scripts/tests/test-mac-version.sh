#!/usr/bin/env bash
# Tests for scripts/lib/mac-version.sh. Run: bash scripts/tests/test-mac-version.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/mac-version.sh

FAILS=0
eq() { if [ "$1" != "$2" ]; then echo "FAIL: $3: expected '$2', got '$1'"; FAILS=$((FAILS + 1)); fi; }

eq "$(printf '' | mac_latest_from_list)" "" "no tags"
eq "$(printf 'mac-v0.1.1\n' | mac_latest_from_list)" "mac-v0.1.1" "one tag"
eq "$(printf 'mac-v0.1.9\nmac-v0.1.10\nmac-v0.1.2\n' | mac_latest_from_list)" "mac-v0.1.10" "version order, not text order"
eq "$(printf 'v2.0.0\nmac-v0.1.3\nrelease-1\n' | mac_latest_from_list)" "mac-v0.1.3" "ignores other tags"

eq "$(mac_next_version "" patch)" "0.1.1" "first release"
eq "$(mac_next_version 0.1.9 patch)" "0.1.10" "patch"
eq "$(mac_next_version 0.1.9 minor)" "0.2.0" "minor"
eq "$(mac_next_version 0.1.9 major)" "1.0.0" "major"

eq "$(mac_build_from_annotation $'Conduit for macOS 0.1.1\n\nbuild=2')" "2" "annotation"
eq "$(mac_build_from_annotation 'no build line')" "" "missing build line"
eq "$(mac_next_build "")" "2" "first build"
eq "$(mac_next_build 41)" "42" "next build"

eq "$(mac_html_escape 'Fix <tab> & "quotes"')" "Fix &lt;tab&gt; &amp; &quot;quotes&quot;" "escape"

eq "$(mac_version_args "" "")" "" "no overrides keeps today's build"
eq "$(mac_version_args 0.1.1 2 | tr '\n' ' ')" "MARKETING_VERSION=0.1.1 CURRENT_PROJECT_VERSION=2 " "overrides"

if [ "$FAILS" -gt 0 ]; then echo "$FAILS failure(s)"; exit 1; fi
echo "mac-version: all tests passed"
