# Mac Releases and Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One local command ships a notarized Conduit for macOS build to GitHub Releases with a signed Sparkle feed, and installed copies offer each new build.

**Architecture:** Sparkle 2.10.0 (Swift package, Mac target only) runs a standard updater controller that checks a feed at the GitHub "latest release" URL hourly and prompts. `scripts/mac-ship.sh` computes the next version from `mac-v*` tags, builds through the existing `scripts/mac-release.sh` with version overrides, generates a one-item EdDSA-signed `appcast.xml` with Sparkle's `generate_appcast`, tags, and publishes a GitHub Release carrying the DMG and the feed.

**Tech Stack:** Swift/SwiftUI/AppKit (macOS 14+), Sparkle 2.10.0, xcodegen, bash (macOS `/bin/bash` 3.2 compatible), `gh`, `notarytool`.

**Spec:** `docs/superpowers/specs/2026-10-14-mac-releases-auto-update-design.md`

## Global Constraints

- Sparkle package: `https://github.com/sparkle-project/Sparkle`, `exactVersion: 2.10.0` (released 2026-09-13), `ConduitMac` target only.
- Info.plist: `SUFeedURL` = `https://github.com/Marceswan/hermes-conduit/releases/latest/download/appcast.xml`; `SUPublicEDKey` = the key from Step 0; `SUEnableAutomaticChecks` = true; `SUScheduledCheckInterval` = 3600; `SUAutomaticallyUpdate` = false.
- Menu: **Check for Updates...** after About (`CommandGroup(after: .appInfo)`), disabled while `canCheckForUpdates` is false.
- The updater does not start under XCTest (`MacDefaults.isRunningUnderXCTest`).
- Tags `mac-v<MARKETING_VERSION>`, annotated, annotation includes the line `build=<n>`. First release `0.1.1` build `2`. Patch bump by default; `--minor`, `--major`.
- Versions are build-setting overrides; nothing is committed to bump a version.
- Repo for releases: `Marceswan/hermes-conduit` (always pass `-R`). Notary profile default `conduit-notary`. Signing identity `Developer ID Application: Marc Swan (58XKRG9VMA)`.
- Release notes: first-parent commit subjects since the previous `mac-v*` tag, at most 30.
- No secrets in the repo or in GitHub. The EdDSA private key stays in the login keychain.
- Bash scripts run on macOS `/bin/bash` 3.2: no `mapfile`, no associative arrays, guard empty arrays under `set -u` with `${arr[@]+"${arr[@]}"}`.
- iOS unchanged. Mac code under `ConduitMac/`. No upstream (`Conduit/`, `Shared/`) edits are expected; if one is needed, gate it `#if os(macOS)`, tag `// MAC:`, ledger row.
- Safety: the user's own Conduit is running; do not quit, click or type into it.

## Review Focus

1. A tag or release already exists for the computed version (re-run after a partial failure): the script must stop before building, naming the tag. Test in Task 2 (dry-run fixture).
2. The private key in the keychain does not match `SUPublicEDKey` in Info.plist: every update would fail verification on the other Macs. The script must refuse to ship. Task 2 precondition plus a test of the comparison function.
3. GitHub's `latest/download` redirect lags just after publishing: verification must retry for up to 60 s before declaring failure. Task 2.
4. A commit subject containing `<`, `&` or quotes breaks the HTML notes or the appcast XML. Task 2 escape function test.
5. Building with no version overrides (plain `scripts/mac-release.sh`) must still work as today. Task 2 keeps the default path and tests the argument builder with empty input.

## File Map

- Modify `project.yml`: Sparkle package, `ConduitMac` dependency (Task 1).
- Modify `ConduitMac/Resources/Info.plist`: SU* keys (Task 1).
- Create `ConduitMac/App/MacUpdater.swift`: updater controller wrapper (Task 1).
- Modify `ConduitMac/App/ConduitCommands.swift`, `ConduitMac/App/ConduitMacApp.swift`: menu item and wiring (Task 1).
- Create `ConduitMacTests/MacUpdaterTests.swift` (Task 1).
- Create `scripts/lib/mac-version.sh`, `scripts/tests/test-mac-version.sh` (Task 2).
- Modify `scripts/mac-release.sh`: optional version overrides (Task 2).
- Create `scripts/mac-ship.sh` (Task 2).
- Docs: `docs/macos/DECISIONS.md` (D12), `docs/macos/SMOKE_CHECKLIST.md` (Updates), `docs/macos/RELEASING.md` (Task 2).

---

### Step 0 (user, before Task 1): create the Sparkle signing key

Not a subagent step: it writes to the user's login keychain.

```bash
mkdir -p build/sparkle-2.10.0 && gh release download 2.10.0 -R sparkle-project/Sparkle -p 'Sparkle-2.10.0.tar.xz' -D build/sparkle-2.10.0 && tar -xJf build/sparkle-2.10.0/Sparkle-2.10.0.tar.xz -C build/sparkle-2.10.0
build/sparkle-2.10.0/bin/generate_keys            # creates the key in the login keychain, prints the public key
build/sparkle-2.10.0/bin/generate_keys -x ~/Desktop/conduit-sparkle-private.key   # export for backup
```

The user stores `~/Desktop/conduit-sparkle-private.key` in a password manager, then deletes the file. The printed public key goes into the Task 1 dispatch.

---

### Task 1: Sparkle in the app

**Files:**
- Modify: `project.yml` (top-level `packages:`, `ConduitMac` target `dependencies:`)
- Modify: `ConduitMac/Resources/Info.plist`
- Create: `ConduitMac/App/MacUpdater.swift`
- Modify: `ConduitMac/App/ConduitCommands.swift`, `ConduitMac/App/ConduitMacApp.swift`, `ConduitMac/App/ConduitMacAppDelegate.swift`
- Test: `ConduitMacTests/MacUpdaterTests.swift`

**Interfaces:**
- Consumes: `MacDefaults.isRunningUnderXCTest` (ConduitMac/App/ConduitMacAppDelegate.swift); the public key from Step 0.
- Produces: `@MainActor final class MacUpdater: ObservableObject` with `static let shared`, `let started: Bool`, `@Published private(set) var canCheckForUpdates: Bool`, `func checkForUpdates()`; `ConduitCommands` gains `@ObservedObject var updater: MacUpdater`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacUpdaterTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func testFeedAndPolicyKeys() {
        XCTAssertEqual(info["SUFeedURL"] as? String,
                       "https://github.com/Marceswan/hermes-conduit/releases/latest/download/appcast.xml")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false, "prompt, never install silently")
        XCTAssertEqual((info["SUScheduledCheckInterval"] as? NSNumber)?.intValue, 3600)
    }

    func testPublicKeyIsA32ByteBase64Key() throws {
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        let data = try XCTUnwrap(Data(base64Encoded: key), "SUPublicEDKey must be base64")
        XCTAssertEqual(data.count, 32, "an Ed25519 public key is 32 bytes")
    }

    func testUpdaterDoesNotStartUnderXCTest() {
        XCTAssertTrue(MacDefaults.isRunningUnderXCTest)
        XCTAssertFalse(MacUpdater.shared.started)
    }

    func testCheckForUpdatesIsInTheAppMenu() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(main.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let check = try XCTUnwrap(titles.firstIndex(of: "Check for Updates\u{2026}"), "\(titles)")
        let about = try XCTUnwrap(titles.firstIndex { $0.hasPrefix("About") }, "\(titles)")
        XCTAssertGreaterThan(check, about)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacUpdaterTests`
Expected: build failure, `cannot find 'MacUpdater' in scope`.

- [ ] **Step 3: Add the package and plist keys**

`project.yml`, under `packages:` (after `WebRTC`):

```yaml
  # Mac auto-update (D12): Sparkle 2, pinned.
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.10.0
```

`ConduitMac` target `dependencies:` add `- package: Sparkle`.

`ConduitMac/Resources/Info.plist`, inside the top-level dict, following the file's one-line key/value style:

```xml
    <key>SUFeedURL</key><string>https://github.com/Marceswan/hermes-conduit/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>PUBLIC_KEY_FROM_STEP_0</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>3600</integer>
    <key>SUAutomaticallyUpdate</key><false/>
```

`PUBLIC_KEY_FROM_STEP_0` is replaced with the exact public key the controller passes in the dispatch.

- [ ] **Step 4: Implement the updater**

`ConduitMac/App/MacUpdater.swift`:

```swift
import Combine
import Sparkle

/// Sparkle updates (D12): hourly check against the GitHub Releases feed,
/// prompt before installing. Not started under XCTest (the test host is the app).
@MainActor
final class MacUpdater: ObservableObject {
    static let shared = MacUpdater()

    let started: Bool
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init(startingUpdater: Bool = !MacDefaults.isRunningUnderXCTest) {
        started = startingUpdater
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: nil
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
```

`ConduitCommands.swift`: add `@ObservedObject var updater: MacUpdater` next to the other properties, and as the first entry in `body`:

```swift
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
```

`ConduitMacApp.swift`: pass `updater: .shared` where `ConduitCommands(...)` is constructed (keep every other argument as is), and touch `MacUpdater.shared` at launch so the hourly schedule starts with the app, not with the first menu build: in `ConduitMacAppDelegate.applicationDidFinishLaunching` add `_ = MacUpdater.shared` after `MacDefaults.register()`.

- [ ] **Step 5: Run tests, full suite, iOS build**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacUpdaterTests` (pass), then the full Mac suite once, then `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` (Sparkle must not reach the iOS target).
Also confirm Sparkle's helpers are embedded and signed in a Release archive: `xcodebuild archive -scheme ConduitMac -configuration Release -destination 'generic/platform=macOS' -archivePath build/probe.xcarchive` then `codesign --verify --deep --strict build/probe.xcarchive/Products/Applications/Conduit.app && ls build/probe.xcarchive/Products/Applications/Conduit.app/Contents/Frameworks/Sparkle.framework/Versions/B/`; then `rm -rf build/probe.xcarchive`.

- [ ] **Step 6: Commit**

```bash
git add project.yml ConduitMac/Resources/Info.plist ConduitMac/App/MacUpdater.swift ConduitMac/App/ConduitCommands.swift ConduitMac/App/ConduitMacApp.swift ConduitMac/App/ConduitMacAppDelegate.swift ConduitMacTests/MacUpdaterTests.swift
git commit -m "macOS: Sparkle updater with hourly prompt and Check for Updates (D12)"
```

---

### Task 2: Ship script and docs

**Files:**
- Create: `scripts/lib/mac-version.sh`, `scripts/tests/test-mac-version.sh`, `scripts/mac-ship.sh`
- Modify: `scripts/mac-release.sh`
- Docs: `docs/macos/DECISIONS.md`, `docs/macos/SMOKE_CHECKLIST.md`, create `docs/macos/RELEASING.md`

**Interfaces:**
- Consumes: Task 1's Info.plist keys (`SUPublicEDKey`, `SUFeedURL`); Sparkle tools in `build/sparkle-2.10.0/bin/` (Step 0 layout).
- Produces (bash functions in `scripts/lib/mac-version.sh`): `mac_latest_from_list` (stdin tag list -> highest `mac-v*` tag or empty), `mac_next_version <prev or empty> <patch|minor|major>`, `mac_build_from_annotation <text>` (prints n or empty), `mac_next_build <prev or empty>`, `mac_html_escape <text>`, `mac_version_args <marketing or empty> <build or empty>` (prints `MARKETING_VERSION=...` / `CURRENT_PROJECT_VERSION=...` lines).

- [ ] **Step 1: Write the failing shell tests**

`scripts/tests/test-mac-version.sh`:

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash scripts/tests/test-mac-version.sh`
Expected: `scripts/lib/mac-version.sh: No such file or directory`.

- [ ] **Step 3: Implement the library**

`scripts/lib/mac-version.sh`:

```bash
# Version helpers for scripts/mac-ship.sh (D12). Pure functions; bash 3.2.

# Highest mac-v* tag (by version) from a tag list on stdin; empty if none.
mac_latest_from_list() {
  grep -E '^mac-v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^mac-v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | sed 's/^./mac-v&/' || true
}

# Next marketing version. Empty previous means the first release (from 0.1.0).
mac_next_version() {
  local prev="${1:-0.1.0}" bump="$2" major minor patch
  IFS=. read -r major minor patch <<EOF
$prev
EOF
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
```

Run: `bash scripts/tests/test-mac-version.sh` -> `mac-version: all tests passed`. If `mac_latest_from_list` returns empty for an empty list with a non-zero status under `set -e`, keep the trailing `|| true`.

- [ ] **Step 4: Version overrides in mac-release.sh**

After `cd "$ROOT"` add:

```bash
source "$ROOT/scripts/lib/mac-version.sh"
VERSION_ARGS=()
while IFS= read -r arg; do VERSION_ARGS+=("$arg"); done < <(mac_version_args "${CONDUIT_MARKETING_VERSION:-}" "${CONDUIT_BUILD_NUMBER:-}")
```

and append `${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}` to the `xcodebuild archive` command's arguments (before `2>&1`). Update the usage comment: `# Optional: CONDUIT_MARKETING_VERSION=0.1.1 CONDUIT_BUILD_NUMBER=2 (set by scripts/mac-ship.sh)`. Nothing else in the script changes.

- [ ] **Step 5: The ship script**

`scripts/mac-ship.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Ship Conduit for macOS: build, notarize, GitHub Release, signed Sparkle feed (D12).
# Usage: scripts/mac-ship.sh [--dry-run] [--minor|--major]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/lib/mac-version.sh

REPO="Marceswan/hermes-conduit"
SPARKLE_VERSION="2.10.0"
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
  tar -xJf "$SPARKLE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$SPARKLE_DIR"
fi
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || fail "no Sparkle signing key in the keychain (see docs/macos/RELEASING.md)"
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")"
[ "$KEYCHAIN_KEY" = "$PLIST_KEY" ] || fail "keychain Sparkle key does not match SUPublicEDKey in $PLIST"

step 2 "Computing version and notes"
PREV_TAG="$(git tag -l 'mac-v*' | mac_latest_from_list)"
PREV_VERSION="${PREV_TAG#mac-v}"
PREV_BUILD=""
if [ -n "$PREV_TAG" ]; then
  PREV_BUILD="$(mac_build_from_annotation "$(git tag -l --format='%(contents)' "$PREV_TAG")")"
  [ -n "$PREV_BUILD" ] || fail "$PREV_TAG has no build=<n> line in its annotation"
fi
VERSION="$(mac_next_version "$PREV_VERSION" "$BUMP")"
BUILD="$(mac_next_build "$PREV_BUILD")"
TAG="mac-v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && fail "release $TAG already exists on GitHub"

RANGE="HEAD"
[ -n "$PREV_TAG" ] && RANGE="$PREV_TAG..HEAD"
NOTES_MD=""
NOTES_HTML="<ul>"
while IFS= read -r subject; do
  [ -n "$subject" ] || continue
  NOTES_MD="$NOTES_MD- $subject"$'\n'
  NOTES_HTML="$NOTES_HTML<li>$(mac_html_escape "$subject")</li>"
done < <(git log --first-parent --format=%s -n 30 "$RANGE")
NOTES_HTML="$NOTES_HTML</ul>"
DMG_URL="https://github.com/$REPO/releases/download/$TAG/Conduit-$VERSION.dmg"

cat >&2 <<EOF
Release plan
  version: $VERSION (build $BUILD), previous: ${PREV_TAG:-none}${PREV_BUILD:+ (build $PREV_BUILD)}
  tag:     $TAG at $(git rev-parse --short HEAD)
  dmg:     $DMG_URL
  feed:    $FEED_URL
  notes:
$NOTES_MD
EOF
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

step 5 "Tagging and publishing"
git tag -a "$TAG" -m "Conduit for macOS $VERSION" -m "build=$BUILD"
git push -q origin "$TAG"
if ! gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" -R "$REPO" \
     --title "Conduit for macOS $VERSION" --notes "$NOTES_MD" --latest; then
  fail "release upload failed. Retry: gh release create $TAG '$DMG' '$STAGE/appcast.xml' -R $REPO --title 'Conduit for macOS $VERSION' --latest --notes-file <notes>. To abandon: git push origin :refs/tags/$TAG && git tag -d $TAG"
fi

step 6 "Verifying the live feed"
LIVE=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if curl -fsSL "$FEED_URL" | grep -q "<sparkle:version>$BUILD</sparkle:version>\|sparkle:version=\"$BUILD\""; then LIVE=1; break; fi
  sleep 5
done
[ "$LIVE" = 1 ] || fail "feed at $FEED_URL does not list build $BUILD after 60 s; release left in place for inspection"
curl -fsIL "$DMG_URL" >/dev/null || fail "DMG not downloadable at $DMG_URL"

rm -rf "$ROOT/build/mac/Conduit.xcarchive" "$ROOT/build/mac/Conduit.zip" "$ROOT/build/mac/export" "$ROOT/build/mac/dmg-assets" "$STAGE"
echo "Shipped Conduit for macOS $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/$TAG"
```

Check against Sparkle 2.10.0's actual CLI before running: `build/sparkle-2.10.0/bin/generate_appcast --help` and `build/sparkle-2.10.0/bin/generate_keys --help`. If a flag differs (`-p`, `--embed-release-notes`, `--download-url-prefix`, `-o`), use the 2.10.0 spelling and note it in the report. Confirm the appcast element form for the build number and keep the `grep` matching it.

- [ ] **Step 6: Dry run**

Run (from a clean, pushed `macos` checkout, or a throwaway clone if the implementer works in a worktree on another branch: the branch check will refuse otherwise, which is itself the expected result to report): `scripts/mac-ship.sh --dry-run`
Expected on `macos`: the "Release plan" block with version `0.1.1`, build `2`, tag `mac-v0.1.1`, and `dry run: nothing built or published`. Expected on another branch: `mac-ship: switch to the macos branch`, exit 1. Also run `scripts/mac-ship.sh --bogus` -> usage, exit 2.

- [ ] **Step 7: Docs**

`docs/macos/DECISIONS.md`:

```
## D12: Releases and auto-update (2026-10-14)
Spec: docs/superpowers/specs/2026-10-14-mac-releases-auto-update-design.md. Sparkle 2.10.0 (Mac target only) checks https://github.com/Marceswan/hermes-conduit/releases/latest/download/appcast.xml hourly and prompts (SUAutomaticallyUpdate false); Conduit > Check for Updates... after About. Releases come from one local command, scripts/mac-ship.sh: preconditions (macos branch, clean, pushed, gh, notary profile, keychain key equals SUPublicEDKey), next version from mac-v* tags (patch default, --minor/--major; build from the tag annotation's build=<n>), mac-release.sh with version overrides, generate_appcast one-item signed feed, annotated tag, gh release with DMG + appcast.xml, live feed check. No CI, no secrets in GitHub; the EdDSA private key lives in the login keychain and is backed up by the user. Not started under XCTest.
```

`docs/macos/RELEASING.md`: how to ship (`scripts/mac-ship.sh --dry-run`, then `scripts/mac-ship.sh`), the Step 0 key creation and backup (export, store, delete the file), restoring the key on a new release Mac (`generate_keys -f <file>`), first install on another Mac (download the DMG from the release, drag to Applications), and what to do after a failed publish (the retry and abandon commands the script prints).

`docs/macos/SMOKE_CHECKLIST.md`, new "Updates" section: Conduit > Check for Updates... is present after About; with a newer release published, the prompt shows notes and Install / Skip This Version / Remind Me Later; Install relaunches into the new version (Conduit > About shows it); on a Mac with an older non-Sparkle build, one manual DMG install enables updates.

- [ ] **Step 8: Commit**

```bash
bash scripts/tests/test-mac-version.sh
git add scripts/lib/mac-version.sh scripts/tests/test-mac-version.sh scripts/mac-ship.sh scripts/mac-release.sh docs/macos/DECISIONS.md docs/macos/RELEASING.md docs/macos/SMOKE_CHECKLIST.md
git commit -m "macOS: one-command releases to GitHub with a signed Sparkle feed (D12)"
```

---

### Task 3 (controller with the user): first two releases

Not a subagent task: it publishes to GitHub and needs the user's go-ahead (push and publish).

1. Merge the branch into `macos`, push `macos` (user says "push").
2. `scripts/mac-ship.sh --dry-run`, show the plan to the user, then `scripts/mac-ship.sh` -> `mac-v0.1.1`.
3. User installs 0.1.1 from the DMG on this Mac.
4. Ship `mac-v0.1.2` (any small change merged and pushed, or the docs commit).
5. User chooses Conduit > Check for Updates..., sees the prompt, installs, and the app relaunches as 0.1.2.
