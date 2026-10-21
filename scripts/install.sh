#!/bin/sh
# Build BrightBar and install it to /Applications, then (re)launch it from
# there. The login item points at the installed copy, so it survives rebuilds.
set -eu

cd "$(dirname "$0")/.."
./scripts/make-app.sh

DEST=/Applications/BrightBar.app
pkill -x BrightBar 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
cp -R build/BrightBar.app "$DEST"
open "$DEST"
echo "installed $DEST"
