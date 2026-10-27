#!/bin/sh
# Build BrightBar and install it to /Applications (~/Applications without admin
# rights), then (re)launch it from there. The login item points at the
# installed copy, so it survives rebuilds.
set -eu

cd "$(dirname "$0")/.."
./scripts/make-app.sh

# Decide before quitting the running copy, so a failed copy can't leave the
# Mac without BrightBar.
if [ -w /Applications ]; then
    DIR=/Applications
else
    DIR="$HOME/Applications"
    mkdir -p "$DIR"
    echo "note: /Applications is not writable, installing to $DIR"
fi
DEST="$DIR/BrightBar.app"
pkill -x BrightBar 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
cp -R build/BrightBar.app "$DEST"
# Make Finder and the Applications view pick up a changed icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
open "$DEST"
echo "installed $DEST"
