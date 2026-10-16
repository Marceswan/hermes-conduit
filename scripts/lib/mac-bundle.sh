# Helpers for scripts/mac-verify-bundle.sh (D25). bash 3.2; python3 for plists.

# mac_plist_value FILE KEY: the value, one line per array item, true/false for
# booleans; nothing when the key, the file or the plist is missing or invalid.
mac_plist_value() {
  python3 -I - "$1" "$2" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        data = plistlib.load(handle)
    value = data.get(sys.argv[2])
except Exception:
    sys.exit(0)
if value is None:
    sys.exit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    for item in value:
        print(item)
else:
    print(value)
PY
}

# mac_plist_has_line FILE KEY LINE: success when LINE is one of the printed lines.
mac_plist_has_line() {
  mac_plist_value "$1" "$2" | grep -Fxq -- "$3"
}

# mac_url_schemes FILE: every scheme in CFBundleURLTypes, one per line.
mac_url_schemes() {
  python3 -I - "$1" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        data = plistlib.load(handle)
    for entry in data.get("CFBundleURLTypes", []):
        for scheme in entry.get("CFBundleURLSchemes", []):
            print(scheme)
except Exception:
    sys.exit(0)
PY
}

# mac_extension_point FILE: NSExtension.NSExtensionPointIdentifier, or nothing.
mac_extension_point() {
  python3 -I - "$1" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        data = plistlib.load(handle)
    print(data.get("NSExtension", {}).get("NSExtensionPointIdentifier", ""))
except Exception:
    sys.exit(0)
PY
}

# mac_cs_field TEXT FIELD: first "FIELD=value" line of `codesign -dvv` output.
mac_cs_field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# mac_cs_has_runtime TEXT: the hardened-runtime flag is set.
mac_cs_has_runtime() {
  printf '%s\n' "$1" | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime'
}

# mac_starts_with STRING PREFIX
mac_starts_with() {
  [[ "$1" == "$2"* ]]
}

# mac_no_get_task_allow ENT_FILE: com.apple.security.get-task-allow is absent (or false).
mac_no_get_task_allow() {
  [ "$(mac_plist_value "$1" com.apple.security.get-task-allow)" != "true" ]
}
