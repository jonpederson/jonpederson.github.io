# Screenie for macOS: port plan and handoff

This folder holds the working **Linux** version of Screenie (Python, GTK4, GNOME). This document is the brief for building the **macOS** version. It was written on the Linux machine, where nothing for macOS could be built or tested, so treat every macOS API detail here as a starting point to verify, not as tested fact.

## Decisions already made

- **Native Swift app**, not a port of the Python/GTK code.
- **Apple Silicon, macOS 14 Sonoma or newer.** No Intel or older-macOS support needed.
- **Same feature set as Linux**: six styles (Aurora, Starfield, Farm, HUD, Agents, Black), start after N idle minutes even while apps keep the Mac awake, a global shortcut to start it now, simple install and settings.
- **Suggested build order** (the base must be confirmed working before the big styles):
  1. Core: menu bar app, idle watcher, global shortcut, settings, one window per display, dismiss on input, launch at login. Styles: Aurora, Starfield, Black.
  2. Farm.
  3. HUD.
  4. Agents.

## Why the app exists (the problem to preserve)

Apps like Claude hold power assertions to keep the computer awake. On macOS, `PreventUserIdleDisplaySleep` / `NoDisplaySleep` assertions also stop the system screen saver from starting. Screenie must measure **real keyboard and mouse idle time**, which those assertions don't affect, and cover the screen itself. It covers the screen; it doesn't stop or pause anything running underneath.

## Proposed macOS architecture

| Concern | Linux implementation (this folder) | macOS approach to try |
|---|---|---|
| Idle time | Mutter `org.gnome.Mutter.IdleMonitor.GetIdletime` over D-Bus (`daemon.py`) | `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)` (any input). Confirm it keeps counting while a `NoDisplaySleep` assertion is held, e.g. with `caffeinate -d` running. |
| Background watcher | Python daemon started from `~/.config/autostart` | The app itself: `LSUIElement` menu bar app, registered with `SMAppService.mainApp.register()` for login. Poll idle every 2 s, fire once per idle stretch (see `daemon.py` for the "fired" logic). |
| Covering the screen | GTK fullscreen window per monitor | One borderless `NSWindow` per `NSScreen`, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `NSCursor.hide()`. Avoid native fullscreen, because it animates into a new Space. |
| Dismiss | Any key, click, scroll, or >12 px mouse move, after a 1 s grace period (`saver.py`) | Same rules, via `NSEvent.addLocalMonitorForEvents`. Keep the grace period so releasing the shortcut keys doesn't dismiss instantly. |
| Global shortcut | GNOME custom keybinding via gsettings (`shortcut.py`), default Ctrl+Super+S | Carbon `RegisterEventHotKey` (no Accessibility permission needed). Default suggestion: Ctrl+Cmd+S. Check for conflicts. |
| "Require password to dismiss" | `org.gnome.ScreenSaver.Lock` | Options to evaluate: `pmset displaysleepnow` (locks if "require password after sleep" is immediate), or the Lock Screen menu item behaviour. Pick whatever reliably shows the login window. |
| Settings | libadwaita window (`settings.py`), JSON at `~/.config/screenie/config.json` | SwiftUI `Settings` scene; JSON or `UserDefaults`. Same keys as `config.py` so behaviour matches. |
| Rendering | GtkSnapshot / GSK nodes, about 60 fps | SwiftUI `Canvas` + `TimelineView(.animation)`, or Core Animation / Metal where heavier. Cache static layers (Farm chunks, HUD panels, radar scope base) the way the Python code does. |
| Live video | GStreamer via `Gtk.MediaFile` (WisDOT HLS needs `tsdemux`) | `AVPlayer` plays HLS with MPEG-TS natively, so the WisDOT cameras should just work. |
| ISS live camera | WebKitGTK embedding YouTube (optional) | `WKWebView` with the YouTube embed. Set it to ignore mouse events so input still dismisses the saver. |

## Style notes (read the Python for the details)

- **Aurora** (`saver.py`): 7 soft radial-gradient orbs on Lissajous paths over near-black. Optional clock that drifts and bounces to avoid burn-in.
- **Starfield** (`saver.py`): 500 stars flying toward the viewer.
- **Black**: black, optional drifting clock.
- **Farm** (`farm.py`): endless procedurally generated top-down ASCII farm scrolling past like a drone fly-by. Bands of fields (crops, pasture, orchard, pond, farmstead), hedges and fences, a road, plus moving cows, sheep, chickens, tractors and trucks, cloud shadows, birds, and a drone camera HUD. The ground is rendered in 48-column chunks and cached.
- **HUD** (`hud.py`, `hud_data.py`, `astro.py`): dashboard of live data. Layout on a 3440×1440 ultrawide: header (UTC/local clock with ms, a 3-hour wind graph with a prevailing-wind compass, location and Plus Code), four columns of panels on the left, a rain gauge, a 200-mile sonar-style weather radar scope on the right, and a seismograph tape across the bottom. The verse of the day fills the largest open space under the shorter columns.
- **Agents** (`agents.py`, `agents_data.py`): mission control for the Claude Code agents on the machine. A constellation (machine core, project hubs, orbiting agents, token particles, tool-call shockwaves, task beams), a card per agent, a live tool-call feed, 24 h activity, and the day's toolkit and token mix.

## Data sources and what was learned about each

All keyless unless noted. Refresh intervals are in `hud_data.py` (`SOURCES`).

- **Location**: `https://ipwho.is/`, or a manual "lat, lon" setting. On a Mac, CoreLocation is an option (needs a permission prompt).
- **Weather, forecast, history**: Open-Meteo `api.open-meteo.com/v1/forecast` (`current`, `hourly`, `daily`). For history: `minutely_15=wind_speed_10m,wind_gusts_10m,wind_direction_10m&past_minutely_15=12` and `hourly=precipitation&past_hours=24`. Units follow the location (US = imperial). This is model data; label the rain gauge "model est."
- **Air quality**: `air-quality-api.open-meteo.com/v1/air-quality?current=us_aqi,pm2_5,...`
- **Earthquakes**: USGS `earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson`. The seismograph trace is **synthesized** from the event catalog (magnitude-scaled wave packets); say so on screen.
- **Near-Earth objects**: JPL `ssd-api.jpl.nasa.gov/cad.api`. `fullname=true` with a wide date range returns **502**, so retry without it. "Nearest now" is estimated per object as `hypot(dist_at_closest_approach, v_rel * time_since_closest_approach)`.
- **ISS**: `api.wheretheiss.at/v1/satellites/25544`. Keep the previous fix to compute ground-track velocity and heading, and dead-reckon between fixes.
- **ISS live video**: NASA's official stream is a YouTube live stream whose ID changes when NASA restarts it. Resolve it by fetching `https://www.youtube.com/@NASA/streams`, collecting `"videoId"` values, and checking each one's title via `https://www.youtube.com/oembed?url=...&format=json` for "International Space Station" and "Live". The title is "Live High-Definition Views from the International Space Station (Official NASA Stream)".
- **ISS simulated fallback**: NASA GIBS WMS `gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi`. WMS 1.3.0 with EPSG:4326 uses **lat,lon** BBOX order. By day use `MODIS_Terra_CorrectedReflectance_TrueColor` with `TIME` = yesterday, falling back to 2 or 3 days ago; a tiny response (<20 KB) means it isn't processed yet. (`VIIRS_SNPP_...TrueColor` came back black.) At night, when the sun is more than 4° below the horizon at the ISS sub-point, use `VIIRS_Black_Marble`. Rotate the image so the direction of travel is up, and label it **SIMULATED**.
- **Space weather**: NOAA SWPC `services.swpc.noaa.gov/products/noaa-planetary-k-index.json`, `summary/solar-wind-speed.json`, `summary/solar-wind-mag-field.json`, `summary/10cm-flux.json`. (`plasma-2-hour.json` is 404; the `rtsw` files are about 2.5 MB.)
- **US power outages**: ORNL ODIN `ornl.opendatasoft.com/api/explore/v2.1/catalog/datasets/odin-real-time-outages-county/exports/json?select=communitydescriptor,metersaffected`. The first two digits of `communitydescriptor` are the state FIPS code. Only participating utilities report, so say "partial coverage".
- **Traffic cameras**: WisDOT 511 `https://511wi.gov/List/GetData/Cameras?query=<DataTables JSON>`. Pages are capped at **100**, so page with `start`. Each record has `latLng.geography.wellKnownText` ("POINT (lon lat)"), `images[0].imageUrl` (relative path to a 352×240 still), and `images[0].videoUrl` (HLS `.m3u8`, H.264 352×240 in MPEG-TS). Windy's webcam API has the same cameras but needs a key.
- **Weather radar**: NEXRAD via Iowa Environmental Mesonet WMS `mesonet.agron.iastate.edu/cgi-bin/wms/nexrad/n0q.cgi`, `LAYERS=nexrad-n0q-900913`, `SRS=EPSG:4326`, `TRANSPARENT=true`, 1024×1024. The BBOX is ±200 mi: `dlat = 200/69`, `dlon = 200/(69.17·cos lat)`.
- **Map outlines**: US Census via `cdn.jsdelivr.net/npm/us-atlas@3/states-10m.json` and `counties-10m.json` (TopoJSON). Decode the delta-encoded quantized arcs with `transform.scale/translate`, and keep only arcs inside the scope.
- **Verse of the day**: the pick comes from `labs.bible.org/api/?passage=votd&type=json&formatting=plain`. All text comes from bolls.life, `https://bolls.life/get-text/{ESV|WLC|SBLGNT}/{book 1-66}/{chapter}/`: ESV for English, WLC (Hebrew) for OT books 1–39, SBLGNT (Greek) for the NT. Strip `<S>…</S>`, `<m>…</m>` and other tags from SBLGNT. Hebrew is right-to-left. Some Hebrew verse numbering differs (Psalm headings). Licensing: whether bolls.life has Crossway's permission for the ESV is unverified; fine for personal use, but revisit before sharing the app.
- **Astronomy and physics** (`astro.py`, pure maths, port directly): Schlyter low-precision Sun and Moon, GMST, alt/az, moon phase, WGS84 Somigliana normal gravity with free-air correction, lunar and solar tidal Δg (rigid Earth), Galilean frame speeds (Earth rotation, orbit by vis-viva, galactic ~230 km/s toward RA 318.004/Dec 48.330, CMB 369.82 km/s toward RA 167.942/Dec −6.944), Plus Code encoder, haversine and slant range. These were checked against reference values: Plus Code `8FVC9G8F+6X`, the 2026-11-09 new moon and 2026-11-24 full moon, solstice declination 23.44°, and a lunar tide of about 110 µGal at zenith.

## Agents style: data model

- `~/.claude/sessions/<pid>.json`: one per running Claude Code process. Fields used: `pid`, `sessionId`, `cwd`, `name` (session title), `status` (`busy`/`idle`), `statusUpdatedAt`, `startedAt` (ms), `entrypoint`. Check the pid is alive; stale files exist.
- `~/.claude/projects/<slug>/<sessionId>.jsonl`: transcript, tailed incrementally (keep a byte offset and the partial last line). Subagents may appear as `<sessionId>/subagents/*.jsonl`.
  - `assistant` entries: `message.usage` (`input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `output_tokens_details.thinking_tokens`). **Dedupe by `message.id`**, because one API message spans several entries.
  - `tool_use` blocks: `name` and `input` (`file_path` for file tools, `description` for Bash).
  - `user` entries: string content or text blocks from `userType: external` count as a new task; `tool_result.is_error` counts as an error. `custom-title` entries carry titles.
- Process stats: on Linux these come from `/proc`; on macOS use `proc_pidinfo` / `sysctl` (`KERN_PROC`) or `ps -axo pid,ppid,rss,time,comm`. Sum CPU and memory across the agent's whole process tree.
- Git per project every 20 s: branch, `diff --numstat HEAD`, `status --porcelain`, commits ahead of upstream.
- **Privacy rule:** never display prompts, code or command text. Titles, project names, file basenames and Bash `description`s are shown, behind a "Show task titles and file names" setting.
- Context bar assumes a 1M-token window (sessions were observed above 800k).

## Gotchas hit on Linux (some may have Mac equivalents)

- Burn-in: everything static drifts a few pixels over time, and clocks bounce around. Keep that.
- Only one screensaver instance should run (the Linux version uses `Gtk.Application` uniqueness). A second trigger, from the shortcut or the watcher, should just be ignored.
- The Linux version caches HUD data to `~/.cache/screenie/hud.json` so it fills in instantly at launch. Never cache test or sample data there; one test leaked a fake verse into the cache once.
- Performance targets on Linux were 3–9 ms per frame at 3440×1440. Rebuild cached layers round-robin (one panel or card per frame) rather than everything at once.

## Testing checklist for the Mac build

- [ ] Starts after the idle time **while `caffeinate -d` is running** (the whole point).
- [ ] Shortcut starts it immediately; releasing the keys doesn't dismiss it.
- [ ] Covers every display, including the menu bar and Dock, with no Space-switch animation.
- [ ] Key, click, scroll or mouse movement dismisses it; with "require password" on, the login window appears.
- [ ] Launch at login works after a reboot.
- [ ] Each style renders smoothly on a Retina display.
- [ ] HUD: cameras play live via AVPlayer, the ISS stream plays and doesn't swallow input, and every panel fills in.
- [ ] Agents: finds the Claude Code sessions on the Mac.
