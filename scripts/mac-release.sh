#!/usr/bin/env bash
# Build, sign, notarize, and staple Conduit for macOS as a DMG.
# Usage: CONDUIT_NOTARY_PROFILE=conduit-notary scripts/mac-release.sh
# Optional: CONDUIT_MARKETING_VERSION=0.1.1 CONDUIT_BUILD_NUMBER=2 (set by scripts/mac-ship.sh)
set -euo pipefail

: "${CONDUIT_NOTARY_PROFILE:?set CONDUIT_NOTARY_PROFILE to a notarytool keychain profile}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/mac"
ARCHIVE="$OUT/Conduit.xcarchive"
EXPORT="$OUT/export"

cd "$ROOT"
source "$ROOT/scripts/lib/mac-version.sh"
VERSION_ARGS=()
while IFS= read -r arg; do VERSION_ARGS+=("$arg"); done < <(mac_version_args "${CONDUIT_MARKETING_VERSION:-}" "${CONDUIT_BUILD_NUMBER:-}")
rm -rf "$OUT"
mkdir -p "$OUT"

echo "::progress::1/7 Generating project" >&2
xcodegen generate 2>&1 | tee "$OUT/xcodegen.log" | tail -3

echo "::progress::2/7 Archiving" >&2
xcodebuild archive -scheme ConduitMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} 2>&1 | tee "$OUT/archive.log" | tail -3

echo "::progress::3/7 Exporting (Developer ID)" >&2
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/scripts/mac-export-options.plist" \
  -exportPath "$EXPORT" 2>&1 | tee "$OUT/export.log" | tail -3

APP="$EXPORT/Conduit.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/Conduit-$VERSION.dmg"

# D25: the exported app must embed and sign the widget extension before notarization is spent on it.
scripts/mac-verify-bundle.sh --app "$APP" --require-timestamp

echo "::progress::4/7 Notarizing app" >&2
ditto -c -k --keepParent "$APP" "$OUT/Conduit.zip"
xcrun notarytool submit "$OUT/Conduit.zip" --keychain-profile "$CONDUIT_NOTARY_PROFILE" --wait 2>&1 | tee "$OUT/notarize-app.log"
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

echo "::progress::5/7 Rendering DMG background" >&2
DMG_ASSETS="$OUT/dmg-assets"
swift scripts/make-dmg-background.swift "$DMG_ASSETS" "$VERSION" 2>&1 | tee "$OUT/dmg-background.log" | tail -3

echo "::progress::6/7 Building DMG" >&2
if [ ! -x build/.venv/bin/dmgbuild ]; then
  python3 -m venv build/.venv
  build/.venv/bin/pip install -q dmgbuild==1.6.5
fi
build/.venv/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" \
  -D background="$DMG_ASSETS/background.tiff" \
  -D icon="$APP/Contents/Resources/AppIcon.icns" \
  "Conduit" "$DMG" 2>&1 | tee "$OUT/dmgbuild.log" | tail -3
codesign --sign "Developer ID Application: Marc Swan (58XKRG9VMA)" --timestamp "$DMG"

echo "::progress::7/7 Notarizing DMG" >&2
xcrun notarytool submit "$DMG" --keychain-profile "$CONDUIT_NOTARY_PROFILE" --wait 2>&1 | tee "$OUT/notarize-dmg.log"
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "$DMG"
