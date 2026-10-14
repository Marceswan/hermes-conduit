# Releasing Conduit for macOS

Decision record: D12 in docs/macos/DECISIONS.md. Spec: docs/superpowers/specs/2026-10-14-mac-releases-auto-update-design.md.

## Ship a release

From a clean `macos` checkout that is pushed to `origin/macos`:

```
scripts/mac-ship.sh --dry-run    # runs every precondition, prints version, build, tag, notes, URLs; publishes nothing
scripts/mac-ship.sh              # patch bump (0.1.1 -> 0.1.2)
scripts/mac-ship.sh --minor      # or --major
```

The script computes the next version from the newest `mac-v*` tag (the first release is 0.1.1, build 2). The build number comes from the `build=<n>` line in the previous tag's annotation. It builds, signs and notarizes the DMG, signs a one-item Sparkle feed, creates the annotated tag, creates the GitHub Release on `Marceswan/hermes-conduit` with the DMG and `appcast.xml`, and checks the live feed. Installed copies see it within the hour (or via Conduit > Check for Updates...).

Requirements: `gh` logged in, notary profile `conduit-notary` (override with `CONDUIT_NOTARY_PROFILE`), and the Sparkle EdDSA private key in the login keychain matching `SUPublicEDKey` in `ConduitMac/Resources/Info.plist`. Sparkle's tools are downloaded to `build/sparkle-2.10.0/bin` on first run.

## Back up the signing key

Losing the private key means installed copies cannot verify new updates; recovery is a manual reinstall of a build with a new key.

```
build/sparkle-2.10.0/bin/generate_keys -x ~/sparkle-private-key   # export from the login keychain
# store the file's contents in a password manager, then:
rm ~/sparkle-private-key
```

## Restore the key on a new release Mac

```
build/sparkle-2.10.0/bin/generate_keys -f <exported-key-file>     # import into the login keychain
build/sparkle-2.10.0/bin/generate_keys -p                         # must print the SUPublicEDKey value
rm <exported-key-file>
```

Also set up `gh auth login` and the `conduit-notary` notarytool profile on that Mac.

## First install on another Mac

Builds installed before Sparkle have no updater. On each other Mac, download `Conduit-<version>.dmg` from the GitHub Release (https://github.com/Marceswan/hermes-conduit/releases) and drag Conduit to Applications. Every later release arrives through the update prompt.

## After a failed publish

If `git push` of the tag fails, the script removes the local tag and publishes nothing; fix the cause and rerun.

If `gh release create` fails after the tag push, the script prints both commands (the notes are saved in `build/mac/release-notes-<version>.md`, and the DMG and `appcast.xml` stay in `build/mac`):

- Retry: `gh release create mac-v<version> <dmg> <appcast.xml> -R Marceswan/hermes-conduit --title 'Conduit for macOS <version>' --latest --notes-file build/mac/release-notes-<version>.md`, then check the feed: `curl -fsSL 'https://github.com/Marceswan/hermes-conduit/releases/latest/download/appcast.xml' | grep 'sparkle:version'` (it must show the new build).
- Abandon: `git push origin :refs/tags/mac-v<version> && git tag -d mac-v<version>`

The next ship refuses while the previous `mac-v*` tag has no GitHub Release, so retry or abandon first. It also refuses when there are no commits since the previous tag, and when HEAD moved during the build.

If the feed check fails after the release exists, the release is left in place for inspection; nothing is deleted automatically. A bad release already live is fixed by shipping a higher version (Sparkle never downgrades).
