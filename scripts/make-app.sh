#!/bin/sh
# Build BrightBar and wrap it in a minimal, ad-hoc signed .app bundle.
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product BrightBar

APP=build/BrightBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/BrightBar "$APP/Contents/MacOS/BrightBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BrightBar</string>
    <key>CFBundleIdentifier</key><string>local.brightbar</string>
    <key>CFBundleExecutable</key><string>BrightBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# A stable identity keeps the Accessibility permission across rebuilds: with
# ad-hoc signing macOS keys it on the cdhash, which changes every build.
IDENTITY="BrightBar Local"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "note: no \"$IDENTITY\" identity, signing ad hoc (Accessibility must be re-granted after each build)"
    codesign --force --sign - "$APP"
fi
echo "built $APP"
