#!/usr/bin/env bash
# Removes Screenie. Your settings in ~/.config/screenie are kept unless you pass --purge.
set -uo pipefail

SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"

[ -x "$HOME/.local/bin/screenie" ] && "$HOME/.local/bin/screenie" remove-shortcut
pkill -f "python3 -m screenie" 2>/dev/null

rm -rf "$SHARE/screenie"
rm -f "$HOME/.local/bin/screenie" \
      "$SHARE/applications/local.screenie.Settings.desktop" \
      "$SHARE/icons/hicolor/scalable/apps/screenie.svg" \
      "$CONFIG/autostart/screenie-daemon.desktop"
[ "${1:-}" = "--purge" ] && rm -rf "$CONFIG/screenie"
update-desktop-database "$SHARE/applications" 2>/dev/null || true

echo "Screenie uninstalled."
