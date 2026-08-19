#!/bin/bash
# The only release script that contacts Apple's notary service.
# Requiring the literal --submit keeps packaging and upload separate.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" != "--submit" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
    echo "Usage: $0 --submit <dmg> <notarytool-keychain-profile>" >&2
    exit 2
fi

DMG=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
PROFILE="$3"
case "$DMG" in
    "$ROOT"/dist/Machogs-*.dmg) ;;
    *) echo "Refusing to upload a file outside app/dist or without the Machogs versioned name." >&2; exit 2 ;;
esac
if [ ! -f "$DMG" ]; then
    echo "DMG not found: $DMG" >&2
    exit 2
fi

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
"$ROOT/verify-release.sh" "$DMG"
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")") > "$DMG.sha256"
echo "Notarized and stapled: $DMG"
