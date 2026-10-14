# Version helpers for scripts/mac-ship.sh (D12). Pure functions; bash 3.2.

# Highest mac-v* tag (by version) from a tag list on stdin; empty if none.
mac_latest_from_list() {
  grep -E '^mac-v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^mac-v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | sed 's/^./mac-v&/' || true
}

# Next marketing version. Empty previous means the first release (from 0.1.0).
mac_next_version() {
  local prev="${1:-0.1.0}" bump="$2" major minor patch
  IFS=. read -r major minor patch <<EOT
$prev
EOT
  case "$bump" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    *) echo "$major.$minor.$((patch + 1))" ;;
  esac
}

# The n of a "build=n" line in a tag annotation; empty if absent.
mac_build_from_annotation() {
  printf '%s\n' "$1" | sed -n 's/^build=\([0-9][0-9]*\)$/\1/p' | head -1
}

# Next build number. The first release is build 2 (installed copies are build 1).
mac_next_build() {
  if [ -z "${1:-}" ]; then echo 2; else echo "$(($1 + 1))"; fi
}

mac_html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# xcodebuild build-setting overrides, one per line; nothing when unset.
mac_version_args() {
  if [ -n "${1:-}" ]; then echo "MARKETING_VERSION=$1"; fi
  if [ -n "${2:-}" ]; then echo "CURRENT_PROJECT_VERSION=$2"; fi
}
