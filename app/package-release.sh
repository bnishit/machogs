#!/bin/bash
# Build a signed universal app and package it as a drag-to-Applications DMG.
# This script never submits to Apple and never publishes a release.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
IDENTITY="${MACHOGS_SIGNING_IDENTITY:-}"

if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
    echo "Usage: MACHOGS_SIGNING_IDENTITY='Developer ID Application: …' $0 <version> <build-number>" >&2
    exit 2
fi
if [ -z "$IDENTITY" ]; then
    echo "MACHOGS_SIGNING_IDENTITY is required; refusing to make a public-looking ad-hoc release." >&2
    exit 2
fi

MACHOGS_ARCHS="arm64 x86_64" \
MACHOGS_VERSION="$VERSION" \
MACHOGS_BUILD_NUMBER="$BUILD_NUMBER" \
    "$ROOT/build.sh" "$IDENTITY"

"$ROOT/verify-release.sh" "$ROOT/dist/Machogs.app" --before-notarization

STAGE="$ROOT/dist/dmg-root"
DMG="$ROOT/dist/Machogs-$VERSION.dmg"
rm -rf "$STAGE"
rm -f "$DMG"
mkdir -p "$STAGE"
ditto "$ROOT/dist/Machogs.app" "$STAGE/Machogs.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "Machogs" -srcfolder "$STAGE" "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
rm -rf "$STAGE"

(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")") > "$DMG.sha256"
echo "Packaged $DMG"
echo "Not uploaded. After explicit approval, notarize it with:"
echo "  ./notarize-release.sh --submit '$DMG' <keychain-profile>"
