#!/usr/bin/env bash
# Installs Screenie for the current user (no sudo needed unless packages are missing).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="$SHARE/screenie"
BIN="$HOME/.local/bin/screenie"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

# Dependencies (all preinstalled on Ubuntu Desktop, but check anyway).
if ! python3 -c 'import cairo, gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1"); from gi.repository import Gtk, Adw' 2>/dev/null; then
    echo "Installing required packages (needs sudo)..."
    sudo apt-get install -y python3-gi python3-gi-cairo python3-cairo gir1.2-gtk-4.0 gir1.2-adw-1
fi

# Optional extras for the HUD's live video:
#   gstreamer1.0-plugins-bad  live WisDOT traffic-camera video (otherwise snapshots)
#   gir1.2-webkit-6.0         NASA's live ISS camera (otherwise a simulated view from NASA imagery)
extras=()
gst-inspect-1.0 tsdemux >/dev/null 2>&1 || extras+=(gstreamer1.0-plugins-bad)
python3 -c 'import gi; gi.require_version("WebKit", "6.0")' 2>/dev/null || extras+=(gir1.2-webkit-6.0)
if [ ${#extras[@]} -gt 0 ]; then
    echo "Optional packages for live video in the HUD: ${extras[*]}"
    if [ -t 0 ]; then
        read -r -p "Install them now with sudo? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] && sudo apt-get install -y "${extras[@]}"
    fi
fi

echo "Installing to $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR" "$(dirname "$BIN")" "$SHARE/applications" "$SHARE/icons/hicolor/scalable/apps" "$AUTOSTART"
cp -r "$SRC/screenie" "$APP_DIR/"
find "$APP_DIR" -name __pycache__ -prune -exec rm -rf {} +

cat > "$BIN" <<EOF
#!/bin/sh
cd "$APP_DIR" && exec python3 -m screenie "\$@"
EOF
chmod +x "$BIN"

cp "$SRC/data/screenie.svg" "$SHARE/icons/hicolor/scalable/apps/screenie.svg"

cat > "$SHARE/applications/local.screenie.Settings.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Screenie
GenericName=Screensaver
Comment=Screensaver settings
Exec=$BIN settings
Icon=screenie
Categories=Settings;DesktopSettings;
Keywords=screensaver;screen saver;idle;privacy;
Actions=start;

[Desktop Action start]
Name=Start Screensaver Now
Exec=$BIN show
EOF

cat > "$AUTOSTART/screenie-daemon.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Screenie idle watcher
Exec=$BIN daemon
Icon=screenie
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

update-desktop-database "$SHARE/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$SHARE/icons/hicolor" 2>/dev/null || true

# Register the keyboard shortcut and (re)start the idle watcher.
"$BIN" apply-shortcut
pkill -f "python3 -m screenie daemon" 2>/dev/null || true
sleep 0.3
setsid -f "$BIN" daemon >/dev/null 2>&1 < /dev/null

SHORTCUT="$(python3 -c "import sys; sys.path.insert(0, '$APP_DIR'); from screenie import config; print(config.load()['shortcut'] or 'none')")"
cat <<EOF

Screenie is installed and running.
  • Starts after 5 minutes without keyboard/mouse input (change in settings)
  • Shortcut: $SHORTCUT
  • Settings: open "Screenie" from the app grid, or run: screenie
  • Uninstall: $SRC/uninstall.sh
EOF
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  (Note: ~/.local/bin isn't on your PATH yet; log out and back in to use the 'screenie' command.)";; esac
