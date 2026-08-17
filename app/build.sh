#!/bin/bash
# Build Machogs.app from the Swift package + the bash engine.
#
#   ./build.sh            ad-hoc signed — runs on this Mac, fine for dev
#   ./build.sh "Developer ID Application: Name (TEAMID)"
#                         Developer ID signed — for distribution; follow with
#                         notarytool submit + stapler for a no-warning download
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${1:--}"   # "-" = ad-hoc

swift build -c release

APP=dist/Machogs.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MachogsApp "$APP/Contents/MacOS/Machogs"
cp Info.plist "$APP/Contents/"
cp ../machogs "$APP/Contents/Resources/machogs"
chmod +x "$APP/Contents/Resources/machogs"

# App icon: drawn in code (make-icon.swift) so there are no binary assets to
# maintain — regenerate only when missing.
if [ ! -f AppIcon.icns ]; then
  swift make-icon.swift
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/"

codesign --force --options runtime -s "$IDENTITY" "$APP"
echo "Built $APP  (signed: $IDENTITY)"
