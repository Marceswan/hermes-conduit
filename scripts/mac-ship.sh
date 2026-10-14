#!/usr/bin/env bash
# Ship Conduit for macOS: build, notarize, GitHub Release, signed Sparkle feed (D12).
# Usage: scripts/mac-ship.sh [--dry-run] [--minor|--major]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/lib/mac-version.sh

REPO="Marceswan/hermes-conduit"
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"  # Sparkle-2.10.0.tar.xz
SPARKLE_DIR="$ROOT/build/sparkle-$SPARKLE_VERSION"
SPARKLE_BIN="$SPARKLE_DIR/bin"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
PLIST="ConduitMac/Resources/Info.plist"
: "${CONDUIT_NOTARY_PROFILE:=conduit-notary}"
export CONDUIT_NOTARY_PROFILE

DRY_RUN=0
BUMP=patch
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --minor) BUMP=minor ;;
    --major) BUMP=major ;;
    *) echo "usage: scripts/mac-ship.sh [--dry-run] [--minor|--major]" >&2; exit 2 ;;
  esac
done

fail() { echo "mac-ship: $*" >&2; exit 1; }
step() { echo "::progress::$1/6 $2" >&2; }

step 1 "Checking preconditions"
[ "$(git rev-parse --abbrev-ref HEAD)" = "macos" ] || fail "switch to the macos branch"
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
git fetch -q origin macos --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/macos)" ] || fail "push macos first (HEAD differs from origin/macos)"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in (run: gh auth login)"
xcrun notarytool history --keychain-profile "$CONDUIT_NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notary profile '$CONDUIT_NOTARY_PROFILE' not usable"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  mkdir -p "$SPARKLE_DIR"
  gh release download "$SPARKLE_VERSION" -R sparkle-project/Sparkle -p "Sparkle-$SPARKLE_VERSION.tar.xz" -D "$SPARKLE_DIR" --clobber
  TARBALL="$SPARKLE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
  ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
  if [ "$ACTUAL_SHA" != "$SPARKLE_SHA256" ]; then
    rm -f "$TARBALL"
    fail "Sparkle $SPARKLE_VERSION tarball SHA-256 mismatch (got $ACTUAL_SHA); download deleted"
  fi
  tar -xJf "$TARBALL" -C "$SPARKLE_DIR"
fi
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || fail "no Sparkle signing key in the keychain (see docs/macos/RELEASING.md)"
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")" || fail "SUPublicEDKey missing from $PLIST"
[ "$KEYCHAIN_KEY" = "$PLIST_KEY" ] || fail "keychain Sparkle key does not match SUPublicEDKey in $PLIST"

step 2 "Computing version and notes"
SHA="$(git rev-parse HEAD)"
PREV_TAG="$(git tag -l 'mac-v*' | mac_latest_from_list)"
PREV_VERSION="${PREV_TAG#mac-v}"
PREV_BUILD=""
if [ -n "$PREV_TAG" ]; then
  PREV_BUILD="$(mac_build_from_annotation "$(git tag -l --format='%(contents)' "$PREV_TAG")")"
  [ -n "$PREV_BUILD" ] || fail "$PREV_TAG has no build=<n> line in its annotation"
  gh release view "$PREV_TAG" -R "$REPO" >/dev/null 2>&1 \
    || fail "$PREV_TAG has no GitHub Release (a failed publish?). Retry or abandon it first: see 'After a failed publish' in docs/macos/RELEASING.md"
fi
VERSION="$(mac_next_version "$PREV_VERSION" "$BUMP")"
BUILD="$(mac_next_build "$PREV_BUILD")"
TAG="mac-v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && fail "release $TAG already exists on GitHub"

RANGE="HEAD"
if [ -n "$PREV_TAG" ]; then
  RANGE="$PREV_TAG..HEAD"
  [ "$(git rev-list --first-parent --count "$RANGE")" != 0 ] || fail "nothing to ship since $PREV_TAG"
fi
NOTES_MD=""
NOTES_HTML="<ul>"
while IFS= read -r subject; do
  [ -n "$subject" ] || continue
  NOTES_MD="$NOTES_MD- $subject"$'\n'
  NOTES_HTML="$NOTES_HTML<li>$(mac_html_escape "$subject")</li>"
done < <(git log --first-parent --format=%s -n 30 "$RANGE")
NOTES_HTML="$NOTES_HTML</ul>"
DMG_URL="https://github.com/$REPO/releases/download/$TAG/Conduit-$VERSION.dmg"

cat >&2 <<PLAN
Release plan
  version: $VERSION (build $BUILD), previous: ${PREV_TAG:-none}${PREV_BUILD:+ (build $PREV_BUILD)}
  tag:     $TAG at $(git rev-parse --short "$SHA")
  dmg:     $DMG_URL
  feed:    $FEED_URL
  notes:
$NOTES_MD
PLAN
if [ "$DRY_RUN" = 1 ]; then echo "dry run: nothing built or published" >&2; exit 0; fi

step 3 "Building, signing, notarizing"
CONDUIT_MARKETING_VERSION="$VERSION" CONDUIT_BUILD_NUMBER="$BUILD" scripts/mac-release.sh
DMG="$ROOT/build/mac/Conduit-$VERSION.dmg"
[ -f "$DMG" ] || fail "expected $DMG"

step 4 "Signing the update feed"
STAGE="$ROOT/build/mac/appcast-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"
printf '%s\n' "$NOTES_HTML" > "$STAGE/Conduit-$VERSION.html"
"$SPARKLE_BIN/generate_appcast" --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$STAGE/appcast.xml" "$STAGE"
grep -q "<sparkle:version>$BUILD</sparkle:version>\|sparkle:version=\"$BUILD\"" "$STAGE/appcast.xml" \
  || fail "appcast does not name build $BUILD (check the archive's CFBundleVersion)"

NOTES_FILE="$ROOT/build/mac/release-notes-$VERSION.md"
printf '%s' "$NOTES_MD" > "$NOTES_FILE"

step 5 "Tagging and publishing"
[ "$(git rev-parse HEAD)" = "$SHA" ] || fail "HEAD moved during the build (was $SHA); nothing tagged or published"
git tag -a "$TAG" -m "Conduit for macOS $VERSION" -m "build=$BUILD" "$SHA"
if ! git push -q origin "$TAG"; then
  git tag -d "$TAG" >/dev/null
  fail "tag push failed; local tag removed; nothing published"
fi
if ! gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" -R "$REPO" \
     --title "Conduit for macOS $VERSION" --notes-file "$NOTES_FILE" --latest; then
  fail "release upload failed. Retry: gh release create $TAG '$DMG' '$STAGE/appcast.xml' -R $REPO --title 'Conduit for macOS $VERSION' --latest --notes-file '$NOTES_FILE' ; then check the feed: curl -fsSL '$FEED_URL' | grep 'sparkle:version'. To abandon: git push origin :refs/tags/$TAG && git tag -d $TAG"
fi

step 6 "Verifying the live feed"
LIVE=0
FEED_BODY=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  FEED_BODY="$(curl -fsSL "$FEED_URL" || true)"
  if grep -q "<sparkle:version>$BUILD</sparkle:version>\|sparkle:version=\"$BUILD\"" <<<"$FEED_BODY" \
     && curl -fsSL -r 0-0 -o /dev/null "$DMG_URL"; then LIVE=1; break; fi
  sleep 5
done
if [ "$LIVE" != 1 ]; then
  echo "mac-ship: live feed currently lists: $(grep -o 'sparkle:version[^<]*<[^<]*\|sparkle:version="[^"]*"' <<<"$FEED_BODY" | tr '\n' ' ')" >&2
  fail "feed at $FEED_URL or DMG at $DMG_URL not live for build $BUILD after 60 s; release left in place for inspection"
fi

rm -rf "$ROOT/build/mac/Conduit.xcarchive" "$ROOT/build/mac/Conduit.zip" "$ROOT/build/mac/export" "$ROOT/build/mac/dmg-assets" "$STAGE" "$NOTES_FILE"
echo "Shipped Conduit for macOS $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/$TAG"
