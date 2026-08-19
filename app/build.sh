#!/bin/bash
# Build Machogs.app from the Swift package and bundled bash engine.
#
#   ./build.sh
#       Native-architecture, ad-hoc signed development build.
#
#   MACHOGS_ARCHS="arm64 x86_64" \
#   MACHOGS_VERSION=1.2.0 MACHOGS_BUILD_NUMBER=3 \
#   ./build.sh "Developer ID Application: Name (TEAMID)"
#       Universal Developer ID build with hardened runtime and timestamp.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

# Full Xcode is required for a reproducible app build. Prefer the selected
# toolchain, but use the standard Xcode install without changing global state.
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "Full Xcode is required. Install it and select its developer directory." >&2
        exit 1
    fi
fi

IDENTITY="${1:--}"
ARCHS="${MACHOGS_ARCHS:-$(uname -m)}"
VERSION="${MACHOGS_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
BUILD_NUMBER="${MACHOGS_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)}"
APP="$ROOT/dist/Machogs.app"

case "$VERSION" in
    ''|*[!0-9.]*) echo "Version must contain only numbers and dots: $VERSION" >&2; exit 2 ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) echo "Build number must be an integer: $BUILD_NUMBER" >&2; exit 2 ;;
esac

BINARIES=()
for arch in $ARCHS; do
    swift build -c release --arch "$arch"
    bin_dir=$(swift build -c release --arch "$arch" --show-bin-path)
    BINARIES+=("$bin_dir/MachogsApp")
done

rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#BINARIES[@]}" -eq 1 ]; then
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/Machogs"
else
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Machogs"
fi

cp Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp ../machogs "$APP/Contents/Resources/machogs"
cp PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/machogs"

if [ ! -f AppIcon.icns ]; then
    swift make-icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/"

SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
echo "  Version: $VERSION ($BUILD_NUMBER)"
echo "  Architectures: $(lipo -archs "$APP/Contents/MacOS/Machogs")"
echo "  Signed: $IDENTITY"
