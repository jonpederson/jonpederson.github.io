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

# App icon from the Linux SVG (best effort: Quick Look renders the SVG).
ICON_SRC="../data/screenie.svg"
if [ -f "$ICON_SRC" ] && command -v qlmanage >/dev/null && command -v iconutil >/dev/null; then
    tmp="$(mktemp -d)"
    if qlmanage -t -s 1024 -o "$tmp" "$ICON_SRC" >/dev/null 2>&1 && [ -f "$tmp/screenie.svg.png" ]; then
        set_dir="$tmp/Screenie.iconset"
        mkdir -p "$set_dir"
        for s in 16 32 128 256 512; do
            sips -z $s $s "$tmp/screenie.svg.png" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
            sips -z $((s * 2)) $((s * 2)) "$tmp/screenie.svg.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
        done
        if iconutil -c icns "$set_dir" -o "$APP/Contents/Resources/Screenie.icns" 2>/dev/null; then
            /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Screenie" "$APP/Contents/Info.plist"
        fi
    fi
    rm -rf "$tmp"
fi

# Ad-hoc signature unless an identity is given. Login items and Carbon hot keys work with either.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
