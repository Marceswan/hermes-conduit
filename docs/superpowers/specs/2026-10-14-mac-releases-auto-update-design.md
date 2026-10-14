# Mac releases and auto-update: design

Date: 2026-10-14. Status: approved in chat (trigger, install behaviour, Sparkle, section 1). Target: the macOS app (`ConduitMac`) and release tooling. iOS is unchanged.

## Goal

The user is the only user, on several Macs. A release made on this Mac reaches the other Macs without a manual reinstall: each Mac learns of the new build within the hour and offers it.

## Decisions

- **Trigger:** one local command, `scripts/mac-ship.sh`. No CI. Signing (Developer ID certificate, notary profile `conduit-notary`, Sparkle EdDSA private key) stays in this Mac's keychain; no secrets in GitHub.
- **Install behaviour:** prompt each time. Sparkle's standard dialog with release notes and Install / Skip This Version / Remind Me Later.
- **Updater:** Sparkle 2 (open source, MIT-style licence, free). Rejected: a homemade updater (re-implements signature checks and app replacement), a Homebrew cask (no in-app prompt).
- **Hosting:** GitHub Releases on the public fork `Marceswan/hermes-conduit` (free; assets download without authentication).

## In the app

- Sparkle added as a Swift package to the `ConduitMac` target only (project.yml), pinned with `exactVersion` to the newest Sparkle 2.x release that is at least two weeks old at implementation time.
- Info.plist keys (ConduitMac/Resources/Info.plist):
  - `SUFeedURL` = `https://github.com/Marceswan/hermes-conduit/releases/latest/download/appcast.xml`
  - `SUPublicEDKey` = the public EdDSA key generated below
  - `SUEnableAutomaticChecks` = true
  - `SUScheduledCheckInterval` = 3600
  - `SUAutomaticallyUpdate` = false (prompt, do not install silently)
- An `SPUStandardUpdaterController` owned by the Mac app (started at launch, not under XCTest), and a menu item **Conduit > Check for Updates...** placed after About (`CommandGroup(after: .appInfo)`), disabled while a check is in progress (`canCheckForUpdates`).
- No sandbox (the app is not sandboxed), so Sparkle's XPC services are not needed.
- External URL policy (R6/R7) is unaffected: Sparkle downloads through its own URL session; release-note links open through Sparkle's UI.

## Signing key

- Generated once with Sparkle's `generate_keys` tool; the private key is stored in this Mac's login keychain (Sparkle's default), the public key goes into Info.plist.
- **The user backs up the private key** (`generate_keys -x <file>` to export, store in a password manager, delete the file). Losing it means installed copies cannot verify new updates; recovery is a manual reinstall of a build with a new key.

## Versioning

- Tags: `mac-v<MARKETING_VERSION>` (for example `mac-v0.1.1`). The `mac-` prefix keeps them apart from upstream tags.
- Each ship computes the next version from the newest `mac-v*` tag: patch + 1 for `MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` = previous build number + 1, read from the previous tag's annotation line `build=<n>`. The first release is `0.1.1`, build `2`.
- Versions are passed to `xcodebuild archive` as build-setting overrides. Nothing is committed to bump a version; the tag records it.
- `--minor` and `--major` flags on the ship script bump those parts instead of patch.

## `scripts/mac-ship.sh`

1. Preconditions, each refusing with a clear message: current branch is `macos`; working tree clean; `HEAD` equals `origin/macos`; `gh auth status` succeeds; `CONDUIT_NOTARY_PROFILE` set (default `conduit-notary`); Sparkle's `sign_update`/`generate_appcast` tools found (from the resolved package's artifacts); the EdDSA key is present in the keychain.
2. Compute the next version and build number.
3. Build, sign, notarize and staple the DMG by calling `scripts/mac-release.sh` with the version overrides (mac-release.sh gains optional `CONDUIT_MARKETING_VERSION` / `CONDUIT_BUILD_NUMBER` environment inputs; unset keeps today's behaviour).
4. Release notes: the subjects of first-parent commits since the previous `mac-v*` tag (all of history for the first release, capped at the last 30), as a short HTML list for Sparkle and Markdown for the GitHub Release.
5. Appcast: run `generate_appcast` over a staging folder holding only the new DMG and the notes, with download URL prefix `https://github.com/Marceswan/hermes-conduit/releases/download/mac-v<version>/`. The result is a one-item, EdDSA-signed `appcast.xml`.
6. Create an annotated tag `mac-v<version>` whose annotation includes the line `build=<n>`, push it, then `gh release create mac-v<version>` with the DMG and `appcast.xml` as assets, the Markdown notes as the body, marked as latest.
7. Verify: fetch `SUFeedURL` (following redirects) and check it names the new version and build; fetch the DMG URL headers (HTTP 200). On failure, print what is live and leave the release in place for inspection (no automatic deletion).
8. Clean up `build/mac` intermediates and the staging folder; keep the DMG and logs.

Progress lines go to stderr in the `::progress::<n>/<total> <label>` format, as mac-release.sh does today.

## First install on other Macs

Builds installed before this change have no updater. Each other Mac needs one manual install of the first Sparkle-enabled DMG (download from the GitHub Release, drag to Applications). Every later release arrives through the prompt. `docs/macos/SMOKE_CHECKLIST.md` gets an "Updates" section covering this and a test of the update prompt.

## Failure handling

- Notarization failure, missing tools or keys, dirty tree: the script stops before tagging; nothing is published.
- `gh release create` failure after the tag push: the script prints the exact command to retry and the tag to delete if abandoning.
- A bad release already live: ship a fixed one (higher version); Sparkle never downgrades.

## Testing

- App: a unit test that Info.plist carries `SUFeedURL`, `SUPublicEDKey` (non-empty, base64), `SUEnableAutomaticChecks` true, `SUAutomaticallyUpdate` false, `SUScheduledCheckInterval` 3600; a test that the updater controller is not started under XCTest; a menu test that **Check for Updates...** exists under the app menu.
- Script: a `--dry-run` flag that runs every precondition and the version and notes computation, prints the plan (version, build, tag, notes, URLs) and publishes nothing. Version computation lives in a small function tested against fixture tag lists (none, `mac-v0.1.1`, out-of-order tags, `--minor`).
- End to end, once, with the user: ship `0.1.1`, install it on this Mac, ship `0.1.2`, confirm the prompt appears (Check for Updates...) and the update installs and relaunches.

## Out of scope

Delta updates, beta channels, CI builds, auto-install without prompt, iOS.

## Docs

New D12 in docs/macos/DECISIONS.md; SMOKE_CHECKLIST "Updates" section; a short "Releasing" section in docs/macos (how to ship, back up the key, first install on another Mac).
