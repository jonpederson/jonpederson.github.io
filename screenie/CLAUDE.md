# Screenie

Screensaver that starts on real input idle time, even while other apps keep the computer awake. This folder is the working Linux version (Python, GTK4, GNOME on Wayland); see README.md.

The current task is a native Swift macOS version (Apple Silicon, macOS 14+). Read MAC_PORT.md before starting: it has the decisions, the proposed architecture, the build order, and what was learned about every data source. The Mac app lives in `macos/` (Swift package, built into an app bundle by `macos/build.sh`); all four phases (core, Aurora, Starfield, Black, Farm, HUD, Agents) are in place, and CI builds it on macOS (`.github/workflows/screenie-macos.yml`).

Keep the Linux version working; port behaviour from it rather than redesigning features.
