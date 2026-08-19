#!/bin/bash
# Fail closed when a bundle or DMG is not fit for public download.
set -euo pipefail

TARGET="${1:-}"
PHASE="${2:-}"
if [ -z "$TARGET" ]; then
    echo "Usage: $0 <Machogs.app|Machogs-version.dmg> [--before-notarization]" >&2
    exit 2
fi

if [[ "$TARGET" == *.app ]]; then
    INFO="$TARGET/Contents/Info.plist"
    EXECUTABLE="$TARGET/Contents/MacOS/Machogs"
    plutil -lint "$INFO"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = "com.bnishit.machogs"
    test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")" = "13.0"
    test -x "$TARGET/Contents/Resources/machogs"
    PRIVACY="$TARGET/Contents/Resources/PrivacyInfo.xcprivacy"
    plutil -lint "$PRIVACY"
    test "$(plutil -extract NSPrivacyTracking raw -o - "$PRIVACY")" = "false"
    test "$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$PRIVACY")" = "[]"
    test "$(plutil -extract NSPrivacyTrackingDomains json -o - "$PRIVACY")" = "[]"
    test "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw -o - "$PRIVACY")" = "NSPrivacyAccessedAPICategoryUserDefaults"
    test "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw -o - "$PRIVACY")" = "CA92.1"
    test "$(lipo -archs "$EXECUTABLE")" = "x86_64 arm64" || test "$(lipo -archs "$EXECUTABLE")" = "arm64 x86_64"
    codesign --verify --deep --strict --verbose=2 "$TARGET"
    signature=$(codesign -dv --verbose=4 "$TARGET" 2>&1)
    grep -q 'Authority=Developer ID Application:' <<<"$signature"
    grep -q 'flags=.*runtime' <<<"$signature"
    grep -q '^Timestamp=' <<<"$signature"
    if codesign -d --entitlements :- "$TARGET" 2>/dev/null | grep -q '<key>com.apple.security.get-task-allow</key>'; then
        echo "Release must not contain get-task-allow." >&2
        exit 1
    fi
    if [ "$PHASE" != "--before-notarization" ]; then
        spctl --assess --type execute --verbose=2 "$TARGET"
    fi
elif [[ "$TARGET" == *.dmg ]]; then
    codesign --verify --verbose=2 "$TARGET"
    xcrun stapler validate "$TARGET"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
else
    echo "Expected a .app or .dmg: $TARGET" >&2
    exit 2
fi

echo "Release checks passed: $TARGET"
