#!/usr/bin/env bash
# Verify that a built Conduit.app embeds and correctly signs the widget extension (D25).
# Usage: scripts/mac-verify-bundle.sh --app <Conduit.app> [--require-timestamp]
#        scripts/mac-verify-bundle.sh --archive [--keep]
# --archive builds a signed Release archive under build/mac-verify and verifies the app
# inside it (deleted afterwards unless --keep). It never exports, notarizes, tags or
# publishes anything. Exit 0 only when every check prints "ok:".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/mac-bundle.sh"

TEAM="58XKRG9VMA"
GROUP="$TEAM.com.meswan.hermes.mac.widgets"
APPEX_NAME="ConduitMacWidgets.appex"
APPEX_ID="com.meswan.hermes.mac.widgets"
EXTENSION_POINT="com.apple.widgetkit-extension"

MODE=""
APP=""
REQUIRE_TS=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) MODE=app; APP="${2:?--app needs a path}"; shift ;;
    --archive) MODE=archive ;;
    --require-timestamp) REQUIRE_TS=1 ;;
    --keep) KEEP=1 ;;
    *) echo "usage: scripts/mac-verify-bundle.sh --app <Conduit.app> [--require-timestamp] | --archive [--keep]" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "usage: scripts/mac-verify-bundle.sh --app <Conduit.app> | --archive" >&2; exit 2; }

FAILS=0
check() { # check "description" command args...
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    echo "ok:   $desc" >&2
  else
    echo "FAIL: $desc" >&2
    if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/        /' >&2; fi
    FAILS=$((FAILS + 1))
  fi
}
# nonempty_equal A B: both values are non-empty and identical.
nonempty_equal() { [ -n "$1" ] && [ "$1" = "$2" ]; }

verify_app() {
  local app="$1" appex="$1/Contents/PlugIns/$APPEX_NAME" work
  work="$(mktemp -d)"
  check "app bundle exists" test -d "$app"
  check "codesign --verify --deep --strict (app)" codesign --verify --deep --strict --verbose=2 "$app"
  check "Sparkle.framework is embedded and signed" codesign --verify --strict "$app/Contents/Frameworks/Sparkle.framework"
  check "extension embedded at Contents/PlugIns/$APPEX_NAME" test -d "$appex"
  local app_info
  app_info="$(codesign -dvv "$app" 2>&1 || true)"
  check "app signed by a Developer ID Application certificate" mac_starts_with "$(mac_cs_field "$app_info" Authority)" "Developer ID Application:"
  check "app has the hardened runtime flag" mac_cs_has_runtime "$app_info"
  codesign -d --entitlements :- "$app" >"$work/app.ent" 2>/dev/null || true
  check "app has no get-task-allow entitlement" mac_no_get_task_allow "$work/app.ent"
  if [ -d "$appex" ]; then
    check "codesign --verify --strict (extension)" codesign --verify --strict --verbose=2 "$appex"
    local ext_info
    ext_info="$(codesign -dvv "$appex" 2>&1 || true)"
    check "extension TeamIdentifier is $TEAM" test "$(mac_cs_field "$ext_info" TeamIdentifier)" = "$TEAM"
    check "extension signed by a Developer ID Application certificate" mac_starts_with "$(mac_cs_field "$ext_info" Authority)" "Developer ID Application:"
    check "extension has the hardened runtime flag" mac_cs_has_runtime "$ext_info"
    check "app TeamIdentifier is $TEAM" test "$(mac_cs_field "$app_info" TeamIdentifier)" = "$TEAM"
    if [ "$REQUIRE_TS" = 1 ]; then
      check "extension has a secure timestamp" test -n "$(mac_cs_field "$ext_info" Timestamp)"
      check "app has a secure timestamp" test -n "$(mac_cs_field "$app_info" Timestamp)"
    fi

    codesign -d --entitlements :- "$appex" >"$work/ext.ent" 2>/dev/null || true
    check "extension is sandboxed" test "$(mac_plist_value "$work/ext.ent" com.apple.security.app-sandbox)" = "true"
    check "extension has no get-task-allow entitlement" mac_no_get_task_allow "$work/ext.ent"
    check "extension has the team app group $GROUP" mac_plist_has_line "$work/ext.ent" com.apple.security.application-groups "$GROUP"
    check "app has the team app group $GROUP" mac_plist_has_line "$work/app.ent" com.apple.security.application-groups "$GROUP"
    check "app is not sandboxed" test -z "$(mac_plist_value "$work/app.ent" com.apple.security.app-sandbox)"

    check "extension bundle id is $APPEX_ID" test "$(mac_plist_value "$appex/Contents/Info.plist" CFBundleIdentifier)" = "$APPEX_ID"
    check "extension point is $EXTENSION_POINT" test "$(mac_extension_point "$appex/Contents/Info.plist")" = "$EXTENSION_POINT"
    check "extension CFBundleShortVersionString equals the app's (non-empty)" nonempty_equal "$(mac_plist_value "$app/Contents/Info.plist" CFBundleShortVersionString)" "$(mac_plist_value "$appex/Contents/Info.plist" CFBundleShortVersionString)"
    check "extension CFBundleVersion equals the app's (non-empty)" nonempty_equal "$(mac_plist_value "$app/Contents/Info.plist" CFBundleVersion)" "$(mac_plist_value "$appex/Contents/Info.plist" CFBundleVersion)"
  fi
  check "app registers the conduit URL scheme" test "$(mac_url_schemes "$app/Contents/Info.plist")" = "conduit"
  rm -rf "$work"
}

if [ "$MODE" = archive ]; then
  OUT="$ROOT/build/mac-verify"
  rm -rf "$OUT"; mkdir -p "$OUT"
  if [ "$KEEP" != 1 ]; then trap 'rm -rf "$OUT"' EXIT; fi
  echo "::progress::1/3 Generating project" >&2
  xcodegen generate 2>&1 | tail -3
  echo "::progress::2/3 Archiving (Release, signed; nothing is exported or published)" >&2
  xcodebuild archive -scheme ConduitMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/Conduit.xcarchive" 2>&1 | tee "$OUT/archive.log" | tail -3
  APP="$OUT/Conduit.xcarchive/Products/Applications/Conduit.app"
  echo "::progress::3/3 Verifying $APP" >&2
fi

verify_app "$APP"
if [ "$FAILS" -ne 0 ]; then echo "mac-verify-bundle: $FAILS check(s) failed for $APP" >&2; exit 1; fi
echo "mac-verify-bundle: all checks passed for $APP" >&2
