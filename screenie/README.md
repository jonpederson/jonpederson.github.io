# Screenie

A screensaver for GNOME (Wayland or X11) that comes on even while apps like Claude keep the computer awake.

This is the Linux version. A native macOS version is planned; see [MAC_PORT.md](MAC_PORT.md).

GNOME's own blanking stops working when an app holds an idle inhibitor. Screenie asks Mutter how long it has been since your last real keyboard or mouse input, and inhibitors don't affect that number. Your apps keep running underneath; Screenie only covers the screen.

## Install

```bash
./install.sh
```

Everything goes into your home directory, so no sudo is needed unless GTK4 or libadwaita is missing. The installer:

- puts the app in `~/.local/share/screenie` and the `screenie` command in `~/.local/bin`
- adds **Screenie** to the app grid (right-click it for **Start Screensaver Now**)
- starts the idle watcher, and adds it to autostart so it runs at every login
- registers the keyboard shortcut **Ctrl+Super+S**

## Use

- **Start it now:** press Ctrl+Super+S
- **Dismiss it:** press any key, click, scroll, or move the mouse
- **Settings:** open Screenie from the app grid, or run `screenie`
  - start when idle (on/off) and the idle time in minutes
  - the keyboard shortcut
  - style: Aurora, Starfield, Farm (an endless ASCII farm seen from a drone flying over it), HUD, Agents (both described below) or Black
  - a clock that drifts so it won't burn in (Farm shows the time in its camera overlay instead)
  - require password to dismiss: hands off to the GNOME lock screen when you come back

Settings take effect right away. Nothing needs restarting.

## HUD style

A full-screen dashboard of live and computed data:

| Panel | Source |
|---|---|
| UTC and local time with milliseconds, Unix time, Julian date, sidereal time | computed |
| Location and Plus Code | IP estimate or your coordinates |
| Weather now, 12-hour and 6-day forecast, air quality | Open-Meteo |
| G vs local g, with lunar and solar tidal Δg | WGS84 normal gravity plus computed Moon/Sun positions |
| Your speed relative to Earth's axis, the Sun, the galactic center and the CMB | Galilean velocity addition, computed |
| Sun and Moon position, phase, sunrise/sunset, sunlight travel time | computed, Open-Meteo |
| Nearest near-Earth object, its estimated distance and speed | NASA/JPL close-approach data |
| ISS position, range and elevation from you | wheretheiss.at |
| Kp index, solar wind, IMF, F10.7 flux | NOAA SWPC |
| US power outages by state | ORNL ODIN (participating utilities only) |
| Earthquakes in the last 24 h, plus a full-width seismograph | USGS (the trace is synthesized from the event catalog) |
| Cameras: the 8 nearest traffic cameras, 4 at a time, rotating every 90 s | WisDOT 511 (live video, or snapshots without `gstreamer1.0-plugins-bad`) |
| ISS camera: NASA's live HD Earth view | YouTube's embedded player via `gir1.2-webkit-6.0`; without it, a simulated view of NASA GIBS imagery (MODIS by day, Black Marble at night) under the ISS's live position |
| Wind over the last 3 hours (header graph, with a compass for the prevailing direction) and rain over the last 24 hours (gauge) | Open-Meteo model data |
| Verse of the day in the ESV beside its Hebrew or Greek original | Daily pick from the NET Bible's verse of the day (labs.bible.org); all text from bolls.life (ESV, Westminster Leningrad Codex, SBL Greek New Testament) |
| Sonar-style weather radar scope on the right, 200-mile radius, with state and county lines | NOAA NEXRAD via Iowa Environmental Mesonet; outlines from US Census (us-atlas) |

Set exact coordinates and units under **HUD Style** in settings. Data is cached in `~/.cache/screenie/hud.json`, so the HUD fills in immediately on launch.

## Agents style

Mission control for the AI agents working on this computer. It reads Claude Code's local session files (`~/.claude/sessions` and `~/.claude/projects`) and `/proc`, entirely offline.

- **Constellation:** this machine is the core, each project is a hub, and each agent orbits its project. Working agents glow and stream token particles into their project. Each real tool call sends out a shockwave labelled with the tool, and each new task fires a beam from the core.
- **Agent cards:**
  - title, project, model, effort and how long it's been working or idle
  - its current tool call
  - tasks, tool calls, errors, subagents and files edited
  - output and thinking tokens, cache hit rate, and context fill
  - a 60-minute activity sparkline
  - CPU and memory for the agent's whole process tree, and the child processes it's running
  - git branch and uncommitted changes
- **Bottom strip:**
  - a live feed of tool calls
  - 24 hours of activity, stacked by project
  - today's most-used tools and token totals, with typing-time and page equivalents

Turn off **Show task titles and file names** in settings to show anonymous stats only. Prompts, code and command text are never displayed.

## Uninstall

```bash
./uninstall.sh
```

Add `--purge` to also delete your settings in `~/.config/screenie`.

## Commands

```
screenie                  settings window
screenie show             start the screensaver
screenie daemon           idle watcher (autostarted)
screenie apply-shortcut   re-register the shortcut from the config
screenie remove-shortcut  unregister the shortcut
```
