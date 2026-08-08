#!/usr/bin/env bash
# log-inventory.sh -- zero-dependency inventory of logging callsites in Conduit.
# Usage: bash log-inventory.sh [repo-root]
# Prints (1) Logger subsystem/category declarations, (2) every log emission,
# (3) any print/os_log/NSLog stragglers, (4) per-file counts.
# Read-only: greps sources, never modifies anything, no network, no build.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
APP_DIR="$ROOT/Conduit"

if [ ! -d "$APP_DIR" ]; then
    echo "error: $APP_DIR not found; pass the repo root as the first argument" >&2
    exit 1
fi

echo "== Logger declarations (subsystem/category) =="
grep -rn --include="*.swift" -E "Logger\(subsystem:" "$APP_DIR" || echo "(none)"
echo

echo "== Log emissions (logger.* and named private loggers) =="
grep -rn --include="*.swift" -E "\b(logger|[A-Za-z]+Log)\.(debug|info|notice|warning|error|critical|fault)\(" "$APP_DIR" || echo "(none)"
echo

echo "== Stragglers: print / os_log / NSLog in app target =="
grep -rn --include="*.swift" -E "^[^/]*\b(print|os_log|NSLog)\(" "$APP_DIR" || echo "(none)"
echo

echo "== Emission count per file =="
grep -rl --include="*.swift" -E "\b(logger|[A-Za-z]+Log)\.(debug|info|notice|warning|error|critical|fault)\(" "$APP_DIR" 2>/dev/null | while read -r f; do
    n=$(grep -c -E "\b(logger|[A-Za-z]+Log)\.(debug|info|notice|warning|error|critical|fault)\(" "$f")
    echo "$n	$f"
done | sort -rn
