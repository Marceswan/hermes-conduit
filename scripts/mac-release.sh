#!/usr/bin/env bash
# Build, sign, notarize, and staple Conduit for macOS as a DMG.
# Usage: CONDUIT_NOTARY_PROFILE=conduit-notary scripts/mac-release.sh
set -euo pipefail

: "${CONDUIT_NOTARY_PROFILE:?set CONDUIT_NOTARY_PROFILE to a notarytool keychain profile}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/mac"
ARCHIVE="$OUT/Conduit.xcarchive"
EXPORT="$OUT/export"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "::progress::1/6 Generating project" >&2
xcodegen generate

echo "::progress::2/6 Archiving" >&2
xcodebuild archive -scheme ConduitMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" | tail -3

echo "::progress::3/6 Exporting (Developer ID)" >&2
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/scripts/mac-export-options.plist" \
  -exportPath "$EXPORT" | tail -3

APP="$EXPORT/Conduit.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/Conduit-$VERSION.dmg"

echo "::progress::4/6 Notarizing app" >&2
ditto -c -k --keepParent "$APP" "$OUT/Conduit.zip"
xcrun notarytool submit "$OUT/Conduit.zip" --keychain-profile "$CONDUIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "::progress::5/6 Building DMG" >&2
hdiutil create -volname "Conduit" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "::progress::6/6 Notarizing DMG" >&2
xcrun notarytool submit "$DMG" --keychain-profile "$CONDUIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "$DMG"
