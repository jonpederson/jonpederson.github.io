#!/usr/bin/env bash
# Builds build/Screenie.app (Apple Silicon, macOS 14+). Needs Xcode or the Command Line Tools.
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh   to sign with a real identity
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="build/Screenie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Screenie" "$APP/Contents/MacOS/Screenie"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon (Resources/AppIcon.png is drawn by tools/make_icon.py).
ICONSET="$(mktemp -d)/Screenie.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Screenie.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signature unless an identity is given. Login items and Carbon hot keys work with either.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
