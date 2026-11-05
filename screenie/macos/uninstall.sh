#!/usr/bin/env bash
# Removes Screenie. Add --purge to also delete its settings.
set -euo pipefail

for dir in /Applications "$HOME/Applications"; do
    app="$dir/Screenie.app"
    [ -d "$app" ] || continue
    "$app/Contents/MacOS/Screenie" --unregister-login-item || true
    osascript -e 'tell application id "local.screenie.Screenie" to quit' >/dev/null 2>&1 || true
    pkill -x Screenie 2>/dev/null || true
    rm -rf "$app"
    echo "Removed $app"
done

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/Library/Application Support/Screenie"
    defaults delete local.screenie.Screenie >/dev/null 2>&1 || true
    echo "Removed settings"
fi
