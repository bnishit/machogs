# Machogs Mac app release

## What membership approval does not prove

Apple Developer Program membership allows the team to create a Developer ID
certificate and use Apple's notary service. It does not create the certificate,
put its private key on this Mac, sign an app, notarize a build, or publish it.

The public Mac app is ready only when the versioned DMG passes every check in
this file. An ad-hoc build is for development and must never be offered as the
download.

## Release contract

| Item | Required value |
|---|---|
| Bundle ID | `com.bnishit.machogs` |
| Minimum macOS | 13.0 Ventura |
| CPU support | Apple silicon and Intel (`arm64`, `x86_64`) |
| Signing | Developer ID Application, secure timestamp |
| Runtime | Hardened runtime, no `get-task-allow` |
| Sandbox | Off by design; process and disk inspection are core features |
| Entitlements | None unless a tested feature later proves one is needed |
| Primary package | Signed, notarized, stapled DMG |
| Install | Open DMG, drag Machogs to Applications, open it |
| Updates | Manual download from GitHub Releases for the first public version |

The DMG is the one public artifact. Do not also offer an unsigned ZIP. A ZIP can
be added later when a signed updater or package manager has a concrete need for
it and its notarization path is tested.

## One-time account setup

1. In the approved Apple team, create a **Developer ID Application**
   certificate. Keep the private key in the release Mac's keychain. A Mac
   Development or Apple Distribution certificate is not a substitute.
2. Install full Xcode and select it with `xcode-select`. Command Line Tools are
   enough to expose `notarytool`, but this app's release build must also be
   proven with a matching compiler and SDK.
3. Store notarization credentials in the keychain using `notarytool store-credentials`.
   Use a profile name such as `machogs-notary`. Never put the password, issuer,
   key, or certificate in this repository.
4. Record the Apple Team ID and certificate expiry in the private release runbook.

No provisioning profile is expected for this Developer ID app. It has no
restricted capability that needs one.

## Build and package without uploading

Start from a clean, reviewed commit. Make the marketing version match the Git
tag and increase the integer build number every time a binary is rebuilt.

```sh
cd app
export MACHOGS_SIGNING_IDENTITY='Developer ID Application: Legal Name (TEAMID)'
./package-release.sh 1.2.0 3
```

This creates `dist/Machogs-1.2.0.dmg` and its SHA-256 file. It refuses to make a
release-looking package without a Developer ID identity. It does not contact
Apple and does not publish anything.

## Notarize after approval

The following command uploads the DMG. Run it only after the user approves that
exact artifact and version.

```sh
./notarize-release.sh --submit dist/Machogs-1.2.0.dmg machogs-notary
```

The script waits for Apple's result, staples the ticket, validates Gatekeeper,
and rewrites the checksum because stapling changes the DMG.

## Human release checks

Test the final DMG from a browser download on two clean Macs: one Apple silicon
and one Intel, both on supported macOS. On each Mac:

1. Open the DMG and drag Machogs onto the Applications shortcut.
2. Launch from Applications. There must be no unidentified-developer warning.
3. Confirm the menu-bar pig appears and the first scan only reports.
4. Allow notifications, toggle Start at Login, log out and back in, then turn it
   off again.
5. Exercise process scan, storage scan, port scan, one approved close, and one
   approved safe-cache clear. Confirm protected processes remain protected.
6. Quit and uninstall: turn off Start at Login, quit Machogs, move it from
   Applications to Trash. Optional local history remains in
   `~/Library/Logs/machogs.log`; preferences remain in
   `~/Library/Preferences/com.bnishit.machogs.plist` until the user deletes them.

Only after those checks should a maintainer create tag `v1.2.0`, upload the DMG
and checksum to a GitHub release, and change the website from preview to
download. Publishing is deliberately outside these scripts.

## Privacy disclosure

Machogs 1.4 adds optional usage analytics through PostHog. The default is off.
The app sends only a random installation identifier, version, installation kind
(new or existing), environment, event UUID/time, first opted-in use, and one event
per UTC ISO week with foreground use. It never sends process names, file paths,
scan results, messages, or cleanup receipts. No autocapture, replay, crash SDK,
or advertising identifiers are used. Scans and background polling do not count
as active use. Turning sharing off cancels pending requests and clears the local
analytics identifier and delivery state; already received events are not erased.

Before enabling a destination, turn on PostHog's **Discard client IP data** setting
and verify ingested test events. Both clients disable GeoIP enrichment and person
profiles. A network provider still sees the source IP while handling a request.
The website has a separate optional choice; app and website IDs are not joined.
See `docs/privacy.html` for the user-facing disclosure and `docs/analytics.md`
for the measurement contract and verification steps.

The app still reads processes, ports, memory, selected disk-usage locations,
and its local receipt log only to explain the Mac's state. It stores settings in
macOS preferences and receipts in `~/Library/Logs/machogs.log`. Closing processes,
freeing ports, and clearing allowed caches require explicit user actions.

`PrivacyInfo.xcprivacy` declares installation identifiers and product interaction
for analytics, linked by the installation identifier, with no cross-app tracking.
UserDefaults retains the `CA92.1` reason. The release verifier checks this contract
and requires a public capture token and an approved HTTPS ingestion host.

## GitHub automation boundary

The repository has no checked-in GitHub Actions release workflow. Before adding
one, first restore GitHub CLI access and inspect branch protection, Actions
permissions, environments, and existing secrets. The first public release
should use the local, witnessed flow above. Automate it only after one complete
release proves the certificate import, notarization, clean-Mac checks, and
rollback steps.

## Product UX branch integration

The product UX work also adds `PrivacyInfo.xcprivacy`, bundles it, and explains
release status during first launch and in Settings. Resolve that overlap by
merging responsibilities, not by choosing one whole file over the other:

- Keep the product UX first-launch and Settings screens, including their final
  user-facing privacy and release-status copy.
- Keep one privacy manifest. Its contract is optional usage analytics, no
  cross-app tracking, no tracking domains, and UserDefaults reason `CA92.1`.
- Keep this branch's build structure: full-Xcode preflight, per-architecture
  builds, `lipo` universal assembly, version and build-number injection,
  privacy-manifest copy, hardened runtime, secure timestamp for Developer ID,
  and strict signature verification.
- Keep `package-release.sh`, `notarize-release.sh`, and `verify-release.sh`.
  The verifier must continue to require both CPU architectures, Developer ID,
  hardened runtime, timestamp, privacy declarations, stapling, and Gatekeeper.
- After resolving the overlap, run a clean universal ad-hoc build. It must pass
  bundle integrity and contain the product UX screens and manifest. It must
  still fail the public-release verifier because ad-hoc signing is not a
  Developer ID release.

Do not resolve either overlapping file with a blanket “ours” or “theirs”. That
would silently remove a user promise or a release safety gate.
