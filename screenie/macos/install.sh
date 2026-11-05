#!/usr/bin/env bash
# Builds Screenie and installs it to /Applications (or ~/Applications if that isn't writable).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./build.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Quit a running copy first.
osascript -e 'tell application id "local.screenie.Screenie" to quit' >/dev/null 2>&1 || true
pkill -x Screenie 2>/dev/null || true
sleep 1

rm -rf "$DEST/Screenie.app"
cp -R build/Screenie.app "$DEST/"
echo "Installed $DEST/Screenie.app"

# On first launch it adds itself to Login Items and opens its settings.
open "$DEST/Screenie.app"
