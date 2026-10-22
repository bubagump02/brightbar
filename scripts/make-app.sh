#!/bin/sh
# Build BrightBar and wrap it in a minimal, ad-hoc signed .app bundle.
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product BrightBar

APP=build/BrightBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BrightBar "$APP/Contents/MacOS/BrightBar"
# Icon Composer icon, compiled to Assets.car (macOS 26) plus AppIcon.icns
# (older macOS). Needs Xcode's actool. Regenerate the source with:
#   swift scripts/make-icon.swift Resources/AppIcon.icon
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
        --output-partial-info-plist build/icon-info.plist >/dev/null
else
    echo "note: no actool (Xcode not selected), building without an app icon"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BrightBar</string>
    <key>CFBundleIdentifier</key><string>local.brightbar</string>
    <key>CFBundleExecutable</key><string>BrightBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
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
