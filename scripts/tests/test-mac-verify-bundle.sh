#!/usr/bin/env bash
# Tests for scripts/lib/mac-bundle.sh. Run: bash scripts/tests/test-mac-verify-bundle.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/mac-bundle.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
eq() { if [ "$1" != "$2" ]; then echo "FAIL: $3: expected '$2', got '$1'"; FAILS=$((FAILS + 1)); fi; }
expect_ok() { local msg="$1"; shift; if ! "$@" >/dev/null 2>&1; then echo "FAIL: $msg"; FAILS=$((FAILS + 1)); fi; }
expect_fail() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $msg"; FAILS=$((FAILS + 1)); fi; }

GROUP="58XKRG9VMA.com.meswan.hermes.mac.widgets"

cat > "$TMP/ext.ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array><string>58XKRG9VMA.com.meswan.hermes.mac.widgets</string></array>
</dict></plist>
EOF
cat > "$TMP/app.ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.camera</key><true/>
<key>com.apple.security.application-groups</key><array><string>group.com.milim.relay.widgets</string></array>
</dict></plist>
EOF
cat > "$TMP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.1.4</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>conduit</string></array></dict></array>
<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict></plist>
EOF
cat > "$TMP/debug.ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
EOF
printf 'not a plist' > "$TMP/broken.ent"

eq "$(mac_plist_value "$TMP/ext.ent" com.apple.security.app-sandbox)" "true" "sandbox true"
eq "$(mac_plist_value "$TMP/app.ent" com.apple.security.app-sandbox)" "" "app has no sandbox key"
eq "$(mac_plist_value "$TMP/broken.ent" com.apple.security.app-sandbox)" "" "broken plist reads as empty, no traceback"
eq "$(mac_plist_value "$TMP/Info.plist" CFBundleShortVersionString)" "0.1.4" "string value"
expect_ok   "extension has the team group" mac_plist_has_line "$TMP/ext.ent" com.apple.security.application-groups "$GROUP"
expect_fail "app fixture has the iOS group, not the team group" mac_plist_has_line "$TMP/app.ent" com.apple.security.application-groups "$GROUP"
expect_fail "missing file is not a match" mac_plist_has_line "$TMP/nope.ent" com.apple.security.application-groups "$GROUP"
eq "$(mac_url_schemes "$TMP/Info.plist")" "conduit" "url schemes"
eq "$(mac_extension_point "$TMP/Info.plist")" "com.apple.widgetkit-extension" "extension point"
eq "$(mac_extension_point "$TMP/ext.ent")" "" "no NSExtension"

SAMPLE=$'Executable=/x/ConduitMacWidgets\nIdentifier=com.meswan.hermes.mac.widgets\nCodeDirectory v=20500 size=640 flags=0x10000(runtime) hashes=10+7 location=embedded\nAuthority=Developer ID Application: Marc Swan (58XKRG9VMA)\nAuthority=Developer ID Certification Authority\nTimestamp=Oct 16, 2026 at 10:00:00\nTeamIdentifier=58XKRG9VMA'
eq "$(mac_cs_field "$SAMPLE" TeamIdentifier)" "58XKRG9VMA" "team field"
eq "$(mac_cs_field "$SAMPLE" Authority)" "Developer ID Application: Marc Swan (58XKRG9VMA)" "first authority is the leaf"
eq "$(mac_cs_field "$SAMPLE" Timestamp)" "Oct 16, 2026 at 10:00:00" "timestamp field"
expect_ok   "runtime flag" mac_cs_has_runtime "$SAMPLE"
expect_fail "no runtime flag" mac_cs_has_runtime $'CodeDirectory v=20400 size=640 flags=0x0(none) hashes=10+7'
expect_fail "unsigned sample has no team" test -n "$(mac_cs_field $'Signature=adhoc\nTeamIdentifier=not set' TeamIdentifier | grep -E '^[A-Z0-9]{10}$' || true)"
expect_ok   "starts_with" mac_starts_with "Developer ID Application: X" "Developer ID Application:"
expect_fail "starts_with no" mac_starts_with "Apple Development: X" "Developer ID Application:"

expect_ok   "release entitlements have no get-task-allow" mac_no_get_task_allow "$TMP/app.ent"
expect_ok   "no entitlements at all is fine" mac_no_get_task_allow "$TMP/nope.ent"
expect_fail "debug entitlements carry get-task-allow" mac_no_get_task_allow "$TMP/debug.ent"
expect_fail "apple development authority is not Developer ID" mac_starts_with "$(mac_cs_field $'Authority=Apple Development: X (ABC)\nAuthority=Apple Worldwide Developer Relations Certification Authority' Authority)" "Developer ID Application:"

# verifier-local helpers: non-empty equality and check's failure output
eval "$(sed -n '/^nonempty_equal()/p' scripts/mac-verify-bundle.sh)"
expect_ok   "equal non-empty values" nonempty_equal "0.1.4" "0.1.4"
expect_fail "both empty must not pass" nonempty_equal "" ""
expect_fail "differing values" nonempty_equal "0.1.4" "0.1.5"
CHECK_SRC="$(sed -n '/^check() {/,/^}/p' scripts/mac-verify-bundle.sh)"
OUT="$(bash -c "FAILS=0; $CHECK_SRC; check demo bash -c 'echo detail-line; exit 1'" 2>&1 || true)"
case "$OUT" in
  *"FAIL: demo"*"        detail-line"*) ;;
  *) echo "FAIL: check prints the failing command output indented: $OUT"; FAILS=$((FAILS + 1)) ;;
esac

if [ "$FAILS" -ne 0 ]; then echo "$FAILS failure(s)"; exit 1; fi
echo "mac-bundle: all passed"
