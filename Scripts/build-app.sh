#!/bin/bash
# Build Brygga.app bundle around the SPM-built binary.
#
# Usage:   ./Scripts/build-app.sh [debug|release] [--sandboxed]
# Env:     VERSION      — CFBundleShortVersionString, defaults to "0.1"
#          BUILD_NUMBER — CFBundleVersion,            defaults to "1"
#
# Without `--sandboxed` the bundle is unsigned (release.yml signs it
# ad-hoc later); existing DMG / Homebrew workflows are unchanged.
#
# With `--sandboxed` the bundle is codesigned ad-hoc with entitlements
# from `Brygga.entitlements` so it runs under the macOS App Sandbox —
# the configuration the future Mac App Store build will use. Existing
# users' data under `~/Library/Application Support/Brygga/` is *not*
# visible to a sandboxed build (the sandbox redirects file paths to
# `~/Library/Containers/<bundle-id>/Data/Library/...`). Treat the
# sandboxed build as a separate install for now.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="debug"
SANDBOXED="false"
for arg in "$@"; do
    case "$arg" in
        debug|release)
            CONFIG="$arg"
            ;;
        --sandboxed)
            SANDBOXED="true"
            ;;
        *)
            echo "unknown argument: $arg" >&2
            echo "usage: $0 [debug|release] [--sandboxed]" >&2
            exit 64
            ;;
    esac
done

VERSION="${VERSION:-0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [ "$CONFIG" = "release" ]; then
    swift build -c release
    BIN=".build/release/Brygga"
else
    swift build
    BIN=".build/debug/Brygga"
fi

APP="build/Brygga.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Brygga"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Brygga</string>
    <key>CFBundleIdentifier</key>
    <string>org.buggerman.Brygga</string>
    <key>CFBundleName</key>
    <string>Brygga</string>
    <key>CFBundleDisplayName</key>
    <string>Brygga</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- Brygga uses only standard TLS / SCRAM-SHA-256 (CryptoKit /
         CommonCrypto). That qualifies as exempt under US export rules,
         so we declare it here once and never have to fill out the
         "Encryption export compliance" form on App Store Connect. -->
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
</dict>
</plist>
PLIST

if [ "$SANDBOXED" = "true" ]; then
    if [ ! -f Brygga.entitlements ]; then
        echo "Brygga.entitlements is missing; cannot produce a sandboxed bundle." >&2
        exit 1
    fi
    codesign \
        --force \
        --sign - \
        --entitlements Brygga.entitlements \
        --options runtime \
        "$APP"
    codesign --verify --strict --verbose "$APP"
    echo "built $APP (version $VERSION, build $BUILD_NUMBER, sandboxed)"
else
    echo "built $APP (version $VERSION, build $BUILD_NUMBER)"
fi
