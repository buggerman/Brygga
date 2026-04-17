#!/bin/bash
# Build Brygga.app bundle around the SPM-built binary.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
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

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "built $APP"
