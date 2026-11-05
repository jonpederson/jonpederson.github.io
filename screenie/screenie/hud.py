"""HUD style: a full-screen dashboard of live and computed data.

Panels are laid out masonry-style in columns sized to the screen, re-rendered
one panel per frame into cached render nodes. The header clock (with
milliseconds) and the seismograph strip are drawn every frame.
"""

import bisect
import json
import math
import os
import socket
import time
from datetime import datetime, timezone

from gi.repository import Gdk, Gio, GLib, Graphene, Gsk, Gtk, Pango

from . import astro
from .hud_data import RADAR_MILES, Hub, iss_motion, iss_position, radar_bbox

try:  # optional: plays NASA's live ISS stream through YouTube's embedded player
    import gi

    gi.require_version("WebKit", "6.0")
    from gi.repository import WebKit

    HAVE_WEBKIT = True
except (ImportError, ValueError):
    HAVE_WEBKIT = False

FONT = "Monospace"
SEIS_WINDOW = 3600  # seconds of seismograph visible across the screen

BG = "#03070c"
TITLE = "#ffb347"
LABEL = "#5f8798"
VALUE = "#c4f1ff"
BRIGHT = "#6fe3ff"
WARN = "#ff6b6b"
GOOD = "#7dffa0"
DIM = "#2b4a58"
PHOSPHOR = "#4dff9a"
SCOPE_BG = "#03100a"

WMO = {
    0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast", 45: "Fog", 48: "Rime fog",
    51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle", 56: "Freezing drizzle", 57: "Freezing drizzle",
    61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain",
    71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains", 80: "Showers", 81: "Showers",
    82: "Violent showers", 85: "Snow showers", 86: "Snow showers", 95: "Thunderstorm",
    96: "T-storm, hail", 99: "T-storm, hail",
}
COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
NA = "—"


def json_key(d):
    return json.dumps(d, sort_keys=True, default=str) if d else None


def rgba(hexstr, alpha=1.0):
    c = Gdk.RGBA()
    c.parse(hexstr)
    c.alpha = alpha
    return c


def rect(x, y, w, h):
    return Graphene.Rect().init(x, y, w, h)


def rrect(bounds, radius):
    # Build in place: chaining Gsk.RoundedRect().init_from_rect() returns a dangling struct in PyGObject.
    rr = Gsk.RoundedRect()
    rr.init_from_rect(bounds, radius)
    return rr

def pt(x, y):
    return Graphene.Point().init(x, y)


def ago(seconds):
    if seconds is None:
        return "loading…"
    if seconds < 60:
        return "live"
    if seconds < 3600:
        return f"{int(seconds // 60)}m ago"
    return f"{int(seconds // 3600)}h ago"


def aqi_label(aqi):
    for limit, name in ((50, "Good"), (100, "Moderate"), (150, "Sensitive"), (200, "Unhealthy"),
                        (300, "Very unhealthy")):
        if aqi <= limit:
            return name
    return "Hazardous"


class Hud:
    def __init__(self, widget, cfg):
        self.widget = widget
        self.hub = Hub.get_instance(cfg)
        self.size = None
        self.started = time.time()
        self.panels = [
            ("LOCATION", "location", 7, self.p_location),
            ("WEATHER", "weather", 8, self.p_weather),
            ("FORECAST", "weather", 8, self.p_forecast),
            ("GRAVITY  G vs g", None, 8, self.p_gravity),
            ("MOTION  GALILEAN FRAMES", None, 7, self.p_motion),
            ("SUN & MOON", None, 8, self.p_sun_moon),
            ("NEAREST NEO", "neo", 7, self.p_neo),
            ("ISS", "iss", 6, self.p_iss),
            ("SPACE WEATHER", "space", 5, self.p_space),
            ("US POWER OUTAGES", "outages", 7, self.p_outages),
            ("SEISMIC  24H", "quakes", 6, self.p_seismic),
            ("CHRONO", None, 7, self.p_chrono),
            ("THIS MACHINE", None, 5, self.p_machine),
            ("CAMERAS  WisDOT 511", "cameras", 12, self.p_cameras),
            ("ISS CAMERA", "isscam", 10, self.p_iss_cam),
        ]
        self.cam_index = len(self.panels) - 2
        self.iss_index = len(self.panels) - 1
        self.overlay = None  # set by the saver window; hosts the live ISS video
        self.webview = None
        self.webview_id = None
        self.isscam_tex = []  # [(fetched t, texture, data)] newest last
        self.verse_node = None
        self.verse_key = None
        self.media = {}  # video URL -> (Gtk.MediaFile, started)
        self.still_tex = {}  # image URL -> (fetched at, Gdk.Texture)
        self.radar_tex = None
        self.radar_t = None
        self.scope_node = None
        self.scope_key = None
        self.nodes = {}
        self.next_panel = 0
        self.seis_cache = {}
        self.seis_feed_t = None
        self.seis_node = None
        self.seis_built_for = None

    # --- layout ---------------------------------------------------------------

    def _setup(self, w, h):
        self.size = (w, h)
        self.nodes.clear()
        self.seis_node = None
        m = round(h * 0.03)
        self.m = m
        self.header_h = h * 0.115
        self.seis_h = h * 0.12
        top = m + self.header_h + m * 0.5
        bottom = h - m - self.seis_h - m * 0.6
        main_h = bottom - top

        # Right: the radar scope at full height, nothing on top of it. Rain gauge just left of it.
        label_room = h * 0.03  # bearing labels around the ring
        r = min(main_h / 2 - label_room, w * 0.22)
        self.scope_c = (w - m - label_room - r, top + main_h / 2)
        self.scope_r = r
        self.scope_node = None
        gauge_w = h * 0.07
        gauge_x = self.scope_c[0] - r - label_room - m - gauge_w
        self.gauge = (gauge_x, top, gauge_w, main_h)

        # Left: masonry columns of panels.
        panels_w = gauge_x - m - m
        ncols = max(2, min(6, round(panels_w / (h * 0.36))))
        gap = m * 0.8
        col_w = (panels_w - gap * (ncols - 1)) / ncols

        lh_guess = h * 0.022
        cell_w = (col_w - lh_guess * 1.2) / 2
        cam_h = 2 * (cell_w * 240 / 352 + lh_guess * 1.1) + lh_guess * 0.4
        iss_h = (col_w - lh_guess * 0.8) * 9 / 16 + lh_guess * 1.3
        for idx, height in ((self.cam_index, cam_h), (self.iss_index, iss_h)):
            title, src, _, fn = self.panels[idx]
            self.panels[idx] = (title, src, math.ceil(height / lh_guess), fn)

        heights, cols = [0.0] * ncols, [[] for _ in range(ncols)]
        for i, (_, _, n, _) in enumerate(self.panels):
            c = heights.index(min(heights))
            cols[c].append(i)
            heights[c] += n + 2.2  # title + padding, in line units
        units = max(heights)
        self.line_h = min(h * 0.028, main_h / units)
        self.font = self._font(self.line_h * 0.74)
        self.small = self._font(self.line_h * 0.6)
        self.geom = {}
        col_bottom = []
        for c, idxs in enumerate(cols):
            y = top
            for i in idxs:
                ph = (self.panels[i][2] + 1.6) * self.line_h
                self.geom[i] = (m + c * (col_w + gap), y, col_w, ph)
                y += ph + 0.6 * self.line_h
            col_bottom.append(y)

        # Verse of the day: the biggest open rectangle under the shorter columns.
        self.verse_box = None
        best = 0.0
        for a in range(ncols):
            for b in range(a, ncols):
                free_top = max(col_bottom[a:b + 1]) + self.line_h * 0.2
                fh = bottom - free_top
                fw = (b - a + 1) * col_w + (b - a) * gap
                if fh >= self.line_h * 4.5 and fw * fh > best:
                    best = fw * fh
                    self.verse_box = (m + a * (col_w + gap), free_top, fw, fh)
        self.verse_node = None
        self.big = self._font(self.header_h * 0.46)
        self.mid = self._font(self.header_h * 0.2)

        # Header middle: wind graph between the clock and the location block.
        left_end = m + self._layout("UTC 0000-00-00 00:00:00.000", self.big).get_pixel_size()[0] + m * 1.5
        right_w = max(self._layout("XXXXXXXX+XX", self.big).get_pixel_size()[0],
                      self._layout("X" * 38, self.mid).get_pixel_size()[0])
        right_start = w - m - right_w - m * 1.5
        self.wind_box = (left_end, m * 0.6, max(right_start - left_end, 0), self.header_h * 0.95)
        self._place_webview()

    @staticmethod
    def _font(px):
        f = Pango.FontDescription.from_string(FONT)
        f.set_absolute_size(px * Pango.SCALE)
        return f

    def _layout(self, text, font=None, width=None, align=Pango.Alignment.LEFT):
        layout = self.widget.create_pango_layout(text)
        layout.set_font_description(font or self.font)
        if width is not None:
            layout.set_width(int(max(width, 1) * Pango.SCALE))
            layout.set_ellipsize(Pango.EllipsizeMode.END)
            layout.set_alignment(align)
        return layout

    def _text(self, snap, text, x, y, color, font=None, alpha=1.0, width=None, align=Pango.Alignment.LEFT):
        layout = self._layout(text, font, width, align)
        snap.save()
        snap.translate(pt(x, y))
        snap.append_layout(layout, rgba(color, alpha))
        snap.restore()
        return layout

    # --- frame ----------------------------------------------------------------

    def draw(self, snap, w, h, t):
        if self.size != (w, h):
            self._setup(w, h)
        now = time.time()
        snap.append_color(rgba(BG), rect(0, 0, w, h))
        jx, jy = 6 * math.sin(t * 0.009), 6 * math.cos(t * 0.013)  # slow drift against burn-in
        snap.save()
        snap.translate(pt(jx, jy))
        self._scope(snap, w, h, t, now)

        # Refresh one panel per frame (all of them on the first frame).
        todo = range(len(self.panels)) if not self.nodes else [self.next_panel]
        for i in todo:
            self.nodes[i] = self._build_panel(i, now)
        self.next_panel = (self.next_panel + 1) % len(self.panels)
        for i, node in self.nodes.items():
            x, y, _, _ = self.geom[i]
            snap.save()
            snap.translate(pt(x, y))
            snap.append_node(node)
            snap.restore()

        self._cameras(snap, now)
        self._iss_view(snap, t, now)
        self._rain_gauge(snap, t)
        self._verse(snap)
        self._header(snap, w, now)
        self._wind_graph(snap)
        self._seismograph(snap, w, h, now)
        snap.restore()

    def _header(self, snap, w, now):
        m = self.m
        utc = datetime.fromtimestamp(now, timezone.utc)
        local = datetime.fromtimestamp(now).astimezone()
        ms = f"{now % 1:.3f}"[1:]
        self._text(snap, "UTC", m, m + self.header_h * 0.04, TITLE, self.mid)
        lw = self._layout("UTC ", self.mid).get_pixel_size()[0]
        self._text(snap, utc.strftime("%Y-%m-%d %H:%M:%S") + ms, m + lw, m - self.header_h * 0.04, BRIGHT, self.big)
        off = local.strftime("%z")
        self._text(snap, f"LOCAL {local.strftime('%Y-%m-%d %H:%M:%S')}{ms}  {local.strftime('%Z')}  "
                         f"UTC{off[:3]}:{off[3:]}", m, m + self.header_h * 0.62, VALUE, self.mid)

        loc = self.hub.get("location") or {}
        wx = (self.hub.get("weather") or {}).get("current")
        right = w - m
        place = ", ".join(p for p in (loc.get("city"), loc.get("region")) if p).upper() or "LOCATING…"
        if wx:
            u = "°F" if self.hub.imperial() else "°C"
            place += f"   {wx['temperature_2m']:.0f}{u} {WMO.get(wx['weather_code'], '').upper()}"
        self._text(snap, place, right - w * 0.5, m + self.header_h * 0.04, VALUE, self.mid,
                   width=w * 0.5, align=Pango.Alignment.RIGHT)
        tag = astro.plus_code(loc["lat"], loc["lon"]) if loc else ""
        self._text(snap, tag, right - w * 0.5, m + self.header_h * 0.3, BRIGHT, self.big,
                   width=w * 0.5, align=Pango.Alignment.RIGHT)

    def _build_panel(self, i, now):
        title, source, nlines, fn = self.panels[i]
        _, _, pw, ph = self.geom[i]
        lh = self.line_h
        snap = Gtk.Snapshot()
        snap.append_color(rgba(BG, 0.66), rect(0, 0, pw, ph))
        # Corner ticks and a hairline under the title.
        th, arm = max(1.0, lh / 14), lh * 0.6
        c = rgba(DIM)
        for x, y, sx, sy in ((0, 0, 1, 1), (pw, 0, -1, 1), (0, ph, 1, -1), (pw, ph, -1, -1)):
            snap.append_color(c, rect(min(x, x + sx * arm), y - (th if sy < 0 else 0), arm, th))
            snap.append_color(c, rect(x - (th if sx < 0 else 0), min(y, y + sy * arm), th, arm))
        pad = lh * 0.4
        self._text(snap, title, pad, pad * 0.6, TITLE, self.small)
        if source:
            err = self.hub.error(source)
            status = ago(self.hub.age(source))
            if err and self.hub.get(source) is None:
                status = "offline"
            self._text(snap, status, pw - pad - pw * 0.4, pad * 0.6, WARN if status == "offline" else LABEL,
                       self.small, width=pw * 0.4, align=Pango.Alignment.RIGHT)
        snap.append_color(rgba(DIM, 0.6), rect(pad, lh * 1.25, pw - 2 * pad, th))

        try:
            lines = fn(now)
        except Exception as e:  # noqa: BLE001 - a bad datum shouldn't take the whole HUD down
            lines = [("error", str(e)[:60], WARN)]
        y = lh * 1.45
        inner = pw - 2 * pad
        for line in lines[:nlines]:
            label, value = line[0], line[1]
            color = line[2] if len(line) > 2 else VALUE
            if label is None:
                self._text(snap, value, pad, y, color, width=inner)
            else:
                lab = self._text(snap, label, pad, y, LABEL, self.small, width=inner * 0.45)
                lw = lab.get_pixel_size()[0] + lh * 0.5
                self._text(snap, value, pad + lw, y + (self.line_h * 0.02), color,
                           width=inner - lw, align=Pango.Alignment.RIGHT)
            y += lh
        return snap.to_node()

    # --- seismograph ----------------------------------------------------------

    def _seis_value(self, s, quakes, times):
        v = self.seis_cache.get(s)
        if v is not None:
            return v
        n = (((s * 2654435761) ^ (s >> 3) * 40503) & 0xFFFF) / 32768.0 - 1.0
        v = n * 0.03 + 0.025 * math.sin(s * 2 * math.pi / 6.3) + 0.012 * math.sin(s * 2 * math.pi / 17.0)
        lo = bisect.bisect_left(times, s - 600)
        hi = bisect.bisect_right(times, s)
        for q in quakes[lo:hi]:
            mag = max(q["mag"], 0.0)
            dur = 30 + 25 * mag ** 1.5
            k = s - q["t"]
            if k < 0 or k > dur:
                continue
            amp = min(1.3, 0.015 * 2.1 ** mag)
            p = 0.35 * amp * math.exp(-k / (0.12 * dur))
            ks = 0.22 * dur
            sw = amp * math.exp(-(k - ks) / (0.3 * dur)) * min(1.0, (k - ks) / 4) if k >= ks else 0.0
            v += (p + sw) * math.sin(k * 2.6 + q["t"]) * (0.7 + 0.3 * n)
        v = max(-1.0, min(1.0, v))
        self.seis_cache[s] = v
        return v

    def _seismograph(self, snap, w, h, now):
        m = self.m
        x0, x1 = m, w - m
        y0 = h - m - self.seis_h
        sh = self.seis_h
        mid = y0 + sh * 0.6
        amp = sh * 0.36
        pps = (x1 - x0) / SEIS_WINDOW
        quakes = self.hub.get("quakes") or []
        feed_t = self.hub.age("quakes")
        feed_key = (len(quakes), quakes[-1]["t"] if quakes else 0)
        if feed_key != self.seis_feed_t:
            self.seis_feed_t = feed_key
            self.seis_cache.clear()
            self.seis_built_for = None

        s0 = int(now)
        if self.seis_built_for != s0:
            self.seis_built_for = s0
            self.seis_node = self._build_seis(s0, quakes, x0, x1, y0, sh, mid, amp, pps)
            for k in [k for k in self.seis_cache if k < s0 - SEIS_WINDOW - 5]:
                del self.seis_cache[k]

        # Frame + static labels
        snap.append_color(rgba(BG, 0.8), rect(x0, y0, x1 - x0, sh))
        snap.append_color(rgba(DIM, 0.8), rect(x0, y0, x1 - x0, 1))
        snap.append_color(rgba(DIM, 0.8), rect(x0, y0 + sh, x1 - x0, 1))
        self._text(snap, "GLOBAL SEISMIC ACTIVITY", x0, y0 + sh * 0.03, TITLE, self.small)
        n = sum(1 for q in quakes if q["t"] > now - SEIS_WINDOW)
        status = "offline" if (feed_t is None and self.hub.error("quakes")) else ago(feed_t)
        self._text(snap, f"USGS · {n} events in last 60 min · trace synthesized from event catalog · {status}",
                   x1 - w * 0.6, y0 + sh * 0.03, LABEL, self.small, width=w * 0.6, align=Pango.Alignment.RIGHT)

        # The trace scrolls continuously between one-second rebuilds.
        snap.push_clip(rect(x0, y0, x1 - x0, sh))
        snap.save()
        snap.translate(pt(x1 - (now - s0) * pps, 0))
        if self.seis_node:
            snap.append_node(self.seis_node)
        snap.restore()
        snap.pop()
        # Pen
        pen_y = mid - self._seis_value(s0, quakes, [q["t"] for q in quakes]) * amp
        r = self.line_h * 0.2
        snap.push_rounded_clip(rrect(rect(x1 - r, pen_y - r, 2 * r, 2 * r), r))
        snap.append_color(rgba(BRIGHT), rect(x1 - r, pen_y - r, 2 * r, 2 * r))
        snap.pop()

    def _build_seis(self, s0, quakes, x0, x1, y0, sh, mid, amp, pps):
        """Trace, ticks and event labels, in coordinates relative to the right edge at second s0."""
        snap = Gtk.Snapshot()
        times = [q["t"] for q in quakes]
        span = SEIS_WINDOW + 60
        # baseline and 10-minute ticks
        snap.append_color(rgba(DIM, 0.5), rect(-span * pps, mid, span * pps, 1))
        first_tick = (s0 - SEIS_WINDOW) // 600 * 600
        for ts in range(first_tick, s0 + 1, 600):
            x = (ts - s0) * pps
            snap.append_color(rgba(DIM, 0.45), rect(x, y0 + sh * 0.2, 1, sh * 0.8))
            label = datetime.fromtimestamp(ts, timezone.utc).strftime("%H:%MZ")
            self._text(snap, label, x + 4, y0 + sh - self.line_h * 0.85, LABEL, self.small)

        b = Gsk.PathBuilder.new()
        step = max(1, int(1 / pps)) if pps < 1 else 1
        for i, s in enumerate(range(s0 - span, s0 + 1, step)):
            x, y = (s - s0) * pps, mid - self._seis_value(s, quakes, times) * amp
            if i == 0:
                b.move_to(x, y)
            else:
                b.line_to(x, y)
        snap.append_stroke(b.to_path(), Gsk.Stroke.new(max(1.2, self.line_h / 16)), rgba(BRIGHT, 0.9))

        # Label the biggest events in view without overlapping.
        visible = [q for q in quakes if q["t"] > s0 - SEIS_WINDOW]
        placed = []
        for q in sorted(visible, key=lambda q: -q["mag"])[:12]:
            if q["mag"] < 1.5 and placed:
                break
            x = (q["t"] - s0) * pps
            place = q["place"].split(" of ")[-1] if " of " in q["place"] else q["place"]
            text = f"M{q['mag']:.1f} {place}"
            tw = self._layout(text, self.small).get_pixel_size()[0]
            for row in range(2):
                if all(not (r == row and x < px + pw_ + 12 and px < x + tw + 12) for px, pw_, r in placed):
                    placed.append((x, tw, row))
                    ly = y0 + sh * (0.15 + row * 0.1)
                    color = WARN if q["mag"] >= 5 else TITLE if q["mag"] >= 3.5 else VALUE
                    snap.append_color(rgba(color, 0.5), rect(x, ly + self.line_h * 0.7, 1, mid - ly - self.line_h * 0.7))
                    self._text(snap, text, x + 4, ly, color, self.small)
                    break
        return snap.to_node()

    # --- cameras ----------------------------------------------------------------

    CAM_PAGE_SECONDS = 90

    def _cam_page(self, now):
        cams = self.hub.get("cameras") or []
        if not cams:
            return []
        pages = max(1, min(2, math.ceil(len(cams) / 4)))  # rotate through the nearest 8
        page = int(now // self.CAM_PAGE_SECONDS) % pages
        return cams[page * 4:page * 4 + 4]

    def _cam_cells(self):
        x, y, pw, ph = self.geom[self.cam_index]
        lh = self.line_h
        pad = lh * 0.4
        top = y + lh * 1.45
        cw = (pw - pad * 3) / 2
        ch = (y + ph - pad - top - pad) / 2
        return [(x + pad + (i % 2) * (cw + pad), top + (i // 2) * (ch + pad), cw, ch) for i in range(4)]

    def _still(self, url):
        stills = self.hub.get("stills") or {}
        got = stills.get(url)
        if not got:
            return None
        data, fetched = got
        cached = self.still_tex.get(url)
        if cached and cached[0] == fetched:
            return cached[1]
        try:
            tex = Gdk.Texture.new_from_bytes(GLib.Bytes.new(data))
        except GLib.Error:
            return None
        self.still_tex[url] = (fetched, tex)
        return tex

    def _cameras(self, snap, now):
        page = self._cam_page(now)
        wanted = {c["video"] for c in page if c["video"]}
        for url in [u for u in self.media if u not in wanted]:  # stop streams that rotated away
            self.media.pop(url)[0].clear()
        lh = self.line_h
        for cam, (x, y, cw, ch) in zip(page, self._cam_cells()):
            vh = ch - lh * 1.05
            snap.append_color(rgba("#000000", 0.85), rect(x, y, cw, vh))
            live = False
            paintable = None
            if cam["video"]:
                if cam["video"] not in self.media:
                    m = Gtk.MediaFile.new_for_file(Gio.File.new_for_uri(cam["video"]))
                    m.set_muted(True)
                    m.play()
                    self.media[cam["video"]] = (m, now)
                    self.hub.still_wanted.add(cam["image"])  # something to show while connecting
                m, started = self.media[cam["video"]]
                if m.get_error() is None and m.is_prepared() and m.get_intrinsic_width() > 0:
                    paintable, live = m, True
                    self.hub.still_wanted.discard(cam["image"])
                elif m.get_error() is not None or now - started > 20:
                    self.hub.still_wanted.add(cam["image"])
            else:
                self.hub.still_wanted.add(cam["image"])
            if paintable is None:
                paintable = self._still(cam["image"])
            if paintable is not None:
                iw = paintable.get_intrinsic_width() or 352
                ih = paintable.get_intrinsic_height() or 240
                scale = min(cw / iw, vh / ih)
                dw, dh = iw * scale, ih * scale
                snap.save()
                snap.translate(pt(x + (cw - dw) / 2, y + (vh - dh) / 2))
                paintable.snapshot(snap, dw, dh)
                snap.restore()
            else:
                self._text(snap, "CONNECTING…", x, y + vh / 2 - lh / 2, LABEL, self.small, width=cw,
                           align=Pango.Alignment.CENTER)
            # status tag
            tag, col = ("● LIVE", WARN) if live else ("STILL", LABEL)
            self._text(snap, tag, x + lh * 0.3, y + lh * 0.2, col, self.small, alpha=0.9)
            dist = self._dist(cam["km"])
            self._text(snap, cam["name"], x, y + vh + lh * 0.1, VALUE, self.small, width=cw * 0.72)
            self._text(snap, dist, x + cw * 0.72, y + vh + lh * 0.1, LABEL, self.small, width=cw * 0.28,
                       align=Pango.Alignment.RIGHT)

    def p_cameras(self, now):
        cams = self.hub.get("cameras")
        if cams is None:
            return [(None, "Finding nearby cameras…", LABEL)]
        if not cams:
            return [(None, f"No WisDOT cameras within {RADAR_MILES} miles", LABEL)]
        return []  # the grid itself is drawn live in _cameras()

    # --- ISS camera ---------------------------------------------------------------

    def p_iss_cam(self, now):
        return []  # drawn live in _iss_view()

    def _iss_rect(self):
        x, y, pw, ph = self.geom[self.iss_index]
        lh = self.line_h
        pad = lh * 0.4
        top = y + lh * 1.45
        vw = pw - 2 * pad
        vh = min(vw * 9 / 16, y + ph - pad - lh * 1.0 - top)
        return x + pad, top, vw, vh

    def _place_webview(self):
        """NASA's live ISS stream via YouTube's embedded player, when WebKitGTK is installed."""
        if not HAVE_WEBKIT or self.overlay is None or self.size is None:
            return
        stream = self.hub.get("iss_stream")
        if not stream:
            return
        x, y, vw, vh = self._iss_rect()
        if self.webview is None:
            policies = WebKit.WebsitePolicies(autoplay=WebKit.AutoplayPolicy.ALLOW)
            self.webview = WebKit.WebView(website_policies=policies)
            self.webview.set_background_color(rgba("#000000"))
            # Events must reach the saver window underneath so any input still dismisses it.
            self.webview.set_can_target(False)
            self.webview.set_can_focus(False)
            self.webview.set_halign(Gtk.Align.START)
            self.webview.set_valign(Gtk.Align.START)
            self.overlay.add_overlay(self.webview)
        if self.webview_id != stream["id"]:
            self.webview_id = stream["id"]
            src = (f"https://www.youtube.com/embed/{stream['id']}?autoplay=1&mute=1&controls=0"
                   f"&playsinline=1&rel=0&modestbranding=1")
            html = ('<html><body style="margin:0;background:#000;overflow:hidden">'
                    f'<iframe src="{src}" style="position:absolute;inset:0;width:100%;height:100%;border:0" '
                    'allow="autoplay; encrypted-media" referrerpolicy="strict-origin-when-cross-origin">'
                    '</iframe></body></html>')
            self.webview.load_html(html, "https://localhost/")
        self.webview.set_margin_start(int(x))
        self.webview.set_margin_top(int(y))
        self.webview.set_size_request(int(vw), int(vh))

    def _iss_view(self, snap, t, now):
        x, y, vw, vh = self._iss_rect()
        lh = self.line_h
        if HAVE_WEBKIT and self.overlay is not None and self.hub.get("iss_stream"):
            if self.webview is None or self.webview_id != self.hub.get("iss_stream")["id"]:
                self._place_webview()
            self._text(snap, "NASA LIVE · Official ISS HD Earth view (YouTube)", x, y + vh + lh * 0.1, LABEL,
                       self.small, width=vw)
            return

        # Fallback: real NASA imagery panned under the ISS's live position, travel direction up.
        snap.append_color(rgba("#000000"), rect(x, y, vw, vh))
        cam = self.hub.get("isscam")
        if cam and cam.get("jpg") and (not self.isscam_tex or self.isscam_tex[-1][0] != cam["t"]):
            try:
                tex = Gdk.Texture.new_from_bytes(GLib.Bytes.new(cam["jpg"]))
                self.isscam_tex = (self.isscam_tex + [(cam["t"], tex, cam)])[-2:]
            except GLib.Error:
                pass
        iss = self.hub.get("iss")
        motion = iss_motion(iss)
        if not self.isscam_tex or not motion:
            self._text(snap, "ACQUIRING ISS…", x, y + vh / 2 - lh / 2, LABEL, self.small, width=vw,
                       align=Pango.Alignment.CENTER)
        else:
            plat, plon = iss_position(iss, now)
            coslat = max(0.2, math.cos(math.radians(plat)))
            heading = math.degrees(math.atan2(motion[1] * coslat, motion[0]))
            ppd = vh / 2.4  # pixels per degree of latitude: ~270 km tall view
            snap.push_clip(rect(x, y, vw, vh))
            snap.save()
            snap.translate(pt(x + vw / 2, y + vh / 2))
            snap.rotate(-heading)
            for k, (ft, tex, data) in enumerate(self.isscam_tex):
                lon0, lat0, lon1, lat1 = data["bbox"]
                dlon = (lon0 - plon + 540) % 360 - 180
                r = rect(dlon * coslat * ppd, -(lat1 - plat) * ppd, (lon1 - lon0) * coslat * ppd, (lat1 - lat0) * ppd)
                fade = 1.0 if k == 0 else min(1.0, (now - ft) / 2.0)
                snap.push_opacity(fade)
                snap.append_texture(tex, r)
                snap.pop()
            snap.restore()
            # porthole vignette and reticle
            for edge in range(6):
                a = 0.12 * (6 - edge) / 6
                snap.append_color(rgba("#000000", a), rect(x, y + edge * lh * 0.15, vw, lh * 0.15))
                snap.append_color(rgba("#000000", a), rect(x, y + vh - (edge + 1) * lh * 0.15, vw, lh * 0.15))
            cx, cy, c = x + vw / 2, y + vh / 2, lh * 0.8
            for dx, dy, ww, hh in ((-c, 0, c * 0.6, 1.2), (c * 0.4, 0, c * 0.6, 1.2), (0, -c, 1.2, c * 0.6),
                                   (0, c * 0.4, 1.2, c * 0.6)):
                snap.append_color(rgba(BRIGHT, 0.6), rect(cx + dx, cy + dy, ww, hh))
            snap.pop()
            data = self.isscam_tex[-1][2]
            mode = "NIGHT" if data["night"] else "DAY"
            speed = iss["velocity"] * (0.621371 if self._imp() else 1)
            snap.append_color(rgba("#000000", 0.55), rect(x, y, vw, lh * 1.0))
            self._text(snap, f"{mode} · {abs(plat):.2f}°{'N' if plat >= 0 else 'S'} "
                             f"{abs(plon):.2f}°{'E' if plon >= 0 else 'W'} · HDG {heading % 360:03.0f}° · "
                             f"{speed:,.0f} {'mph' if self._imp() else 'km/h'}",
                       x + lh * 0.3, y + lh * 0.2, BRIGHT, self.small, width=vw - lh * 0.6)
            if int(t * 1.2) % 2 == 0:
                self._text(snap, "● TRACKING", x + vw - lh * 4.6, y + vh - lh * 0.9, WARN, self.small)
        layer = self.isscam_tex[-1][2]["layer"] if self.isscam_tex else "NASA GIBS"
        note = "SIMULATED view from " + layer + " · live camera needs gir1.2-webkit-6.0"
        self._text(snap, note, x, y + vh + lh * 0.1, LABEL, self.small, width=vw)

    # --- rain gauge -----------------------------------------------------------------

    def _rain_gauge(self, snap, t):
        gx, gy, gw, gh = self.gauge
        lh = self.line_h
        hist = self.hub.get("history")
        imp = self._imp()
        unit = "in" if imp else "mm"
        total = sum(v or 0 for v in hist["rain"]) if hist else 0.0
        self._text(snap, "RAIN", gx, gy, TITLE, self.small, width=gw, align=Pango.Alignment.CENTER)
        self._text(snap, "24H", gx, gy + lh * 0.75, LABEL, self.small, width=gw, align=Pango.Alignment.CENTER)
        tx, tw = gx + gw * 0.42, gw * 0.4
        ty, th = gy + lh * 2.0, gh - lh * 4.6
        # scale: a round number comfortably above the total
        steps = [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12] if imp else [5, 10, 20, 30, 50, 75, 100, 150, 250]
        full = next((v for v in steps if total <= v * 0.85), steps[-1])
        glass = rrect(rect(tx, ty, tw, th), tw / 2)
        snap.push_rounded_clip(glass)
        snap.append_color(rgba(BRIGHT, 0.06), rect(tx, ty, tw, th))
        level = min(1.0, total / full)
        wh = th * level
        if wh > 0:
            wave = math.sin(t * 2.2) * min(lh * 0.08, wh / 2)
            snap.append_color(rgba("#3d8bff", 0.85), rect(tx, ty + th - wh + wave, tw, wh - wave))
            snap.append_color(rgba("#9cc8ff", 0.9), rect(tx, ty + th - wh + wave, tw, max(1.5, lh * 0.06)))
        snap.pop()
        snap.append_border(glass, [1.5] * 4, [rgba(BRIGHT, 0.55)] * 4)
        # graduations
        for k in range(11):
            yk = ty + th - th * k / 10
            major = k % 5 == 0
            snap.append_color(rgba(BRIGHT, 0.6 if major else 0.3),
                              rect(tx - (lh * 0.5 if major else lh * 0.28), yk, lh * 0.5 if major else lh * 0.28, 1.2))
            if major:
                val = full * k / 10
                label = f"{val:g}"
                lw = self._layout(label, self.small).get_pixel_size()[0]
                self._text(snap, label, tx - lh * 0.6 - lw, yk - lh * 0.35, LABEL, self.small)
        fmt = f"{total:.2f}" if imp else f"{total:.1f}"
        self._text(snap, f"{fmt} {unit}", gx - lh, ty + th + lh * 0.5, BRIGHT if total else VALUE, self.font,
                   width=gw + 2 * lh, align=Pango.Alignment.CENTER)
        self._text(snap, "model est.", gx - lh, ty + th + lh * 1.4, LABEL, self.small, width=gw + 2 * lh,
                   align=Pango.Alignment.CENTER)

    # --- verse of the day --------------------------------------------------------------

    def _verse(self, snap):
        if self.verse_box is None:
            return
        votd = self.hub.get("votd")
        key = (json_key(votd), self.verse_box, self.hub.error("votd"))
        if key != self.verse_key or self.verse_node is None:
            self.verse_key = key
            self.verse_node = self._build_verse(votd)
        x, y, _, _ = self.verse_box
        snap.save()
        snap.translate(pt(x, y))
        snap.append_node(self.verse_node)
        snap.restore()

    def _wrapped(self, text, family, px, width, align=Pango.Alignment.LEFT, italic=False):
        layout = self.widget.create_pango_layout(text)
        f = Pango.FontDescription.from_string(family)
        f.set_absolute_size(px * Pango.SCALE)
        if italic:
            f.set_style(Pango.Style.ITALIC)
        layout.set_font_description(f)
        layout.set_width(int(width * Pango.SCALE))
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        layout.set_alignment(align)
        return layout

    def _build_verse(self, votd):
        _, _, bw, bh = self.verse_box
        lh = self.line_h
        snap = Gtk.Snapshot()
        snap.append_color(rgba(BG, 0.66), rect(0, 0, bw, bh))
        th, arm = max(1.0, lh / 14), lh * 0.6
        for x, y, sx, sy in ((0, 0, 1, 1), (bw, 0, -1, 1), (0, bh, 1, -1), (bw, bh, -1, -1)):
            snap.append_color(rgba(DIM), rect(min(x, x + sx * arm), y - (th if sy < 0 else 0), arm, th))
            snap.append_color(rgba(DIM), rect(x - (th if sx < 0 else 0), min(y, y + sy * arm), th, arm))
        pad = lh * 0.4
        self._text(snap, "VERSE OF THE DAY", pad, pad * 0.6, TITLE, self.small)
        snap.append_color(rgba(DIM, 0.6), rect(pad, lh * 1.25, bw - 2 * pad, th))
        body_y = lh * 1.55
        avail_h = bh - body_y - lh * 1.2
        if not votd:
            err = self.hub.error("votd")
            self._text(snap, f"Offline: {err}" if err else "Loading…", pad, body_y, LABEL, self.small,
                       width=bw - 2 * pad)
            return snap.to_node()

        col_gap = lh * 1.2
        left_w = (bw - 2 * pad - col_gap) * 0.55
        right_w = bw - 2 * pad - col_gap - left_w
        eng, orig = votd.get("text", ""), votd.get("orig", "")
        # Largest serif size at which both texts fit.
        px = lh * 1.15
        while px > lh * 0.5:
            le = self._wrapped(eng, "Serif", px, left_w)
            lo = self._wrapped(orig, "Serif", px * 1.05, right_w,
                               Pango.Alignment.RIGHT if votd.get("rtl") else Pango.Alignment.LEFT)
            if max(le.get_pixel_size()[1], lo.get_pixel_size()[1]) <= avail_h:
                break
            px *= 0.93
        for layout, xx, color in ((le, pad, "#f1efe8"), (lo, pad + left_w + col_gap, "#e9d9b4")):
            snap.save()
            snap.translate(pt(xx, body_y))
            snap.append_layout(layout, rgba(color))
            snap.restore()
        snap.append_color(rgba(DIM, 0.6), rect(pad + left_w + col_gap / 2, body_y, th, avail_h))
        foot_y = bh - lh * 1.0
        self._text(snap, f"— {votd.get('ref', '')} ({votd.get('version', 'ESV')})", pad, foot_y, BRIGHT,
                   self.small, width=left_w)
        src = (f"{votd['orig_lang']} · {votd['orig_src']}" if orig else
               f"original text unavailable ({votd.get('orig_error', '')})")
        self._text(snap, src, pad + left_w + col_gap, foot_y, LABEL, self.small, width=right_w,
                   align=Pango.Alignment.RIGHT if votd.get("rtl") else Pango.Alignment.LEFT)
        return snap.to_node()

    # --- wind graph -----------------------------------------------------------------

    def _compass(self, snap, cx, cy, r, prevailing, current, steadiness):
        ring = Gsk.PathBuilder.new()
        ring.add_circle(pt(cx, cy), r)
        snap.append_stroke(ring.to_path(), Gsk.Stroke.new(1.4), rgba(BRIGHT, 0.55))
        lh = self.line_h
        for deg in range(0, 360, 45):
            a = math.radians(deg)
            inner = r * (0.78 if deg % 90 == 0 else 0.88)
            b = Gsk.PathBuilder.new()
            b.move_to(cx + inner * math.sin(a), cy - inner * math.cos(a))
            b.line_to(cx + r * math.sin(a), cy - r * math.cos(a))
            snap.append_stroke(b.to_path(), Gsk.Stroke.new(1.2), rgba(BRIGHT, 0.6 if deg % 90 == 0 else 0.3))
        for deg, letter in ((0, "N"), (90, "E"), (180, "S"), (270, "W")):
            a = math.radians(deg)
            lw, lh_ = self._layout(letter, self.small).get_pixel_size()
            lr = r + lh * 0.45
            self._text(snap, letter, cx + lr * math.sin(a) - lw / 2, cy - lr * math.cos(a) - lh_ / 2,
                       TITLE if letter == "N" else LABEL, self.small)
        # Arrow flies downwind: tail on the side the wind comes from, head where it's going.
        a = math.radians(prevailing)
        sx, sy = math.sin(a), -math.cos(a)  # unit vector toward the source
        tail = (cx + sx * r * 0.8, cy + sy * r * 0.8)
        head = (cx - sx * r * 0.8, cy - sy * r * 0.8)
        shaft = Gsk.PathBuilder.new()
        shaft.move_to(*tail)
        shaft.line_to(*head)
        snap.append_stroke(shaft.to_path(), Gsk.Stroke.new(max(2.0, lh / 9)), rgba(BRIGHT, 0.4 + 0.6 * steadiness))
        hl, hw = r * 0.32, r * 0.18
        px, py = -sy, sx  # perpendicular
        tip = Gsk.PathBuilder.new()
        tip.move_to(*head)
        tip.line_to(head[0] + sx * hl + px * hw, head[1] + sy * hl + py * hw)
        tip.line_to(head[0] + sx * hl - px * hw, head[1] + sy * hl - py * hw)
        tip.close()
        snap.append_fill(tip.to_path(), Gsk.FillRule.WINDING, rgba(BRIGHT, 0.95))
        # current direction: a dot on the ring
        ca = math.radians(current)
        d = max(2.5, lh * 0.16)
        dx, dy = cx + math.sin(ca) * r, cy - math.cos(ca) * r
        snap.push_rounded_clip(rrect(rect(dx - d, dy - d, 2 * d, 2 * d), d))
        snap.append_color(rgba(TITLE), rect(dx - d, dy - d, 2 * d, 2 * d))
        snap.pop()

    def _wind_graph(self, snap):
        bx, by, bw, bh = self.wind_box
        if bw < self.line_h * 8:
            return
        hist = self.hub.get("history")
        lh = self.line_h
        unit = "mph" if self._imp() else "km/h"
        self._text(snap, "WIND · LAST 3 HOURS", bx, by, TITLE, self.small)
        if not hist or not hist["wind"]:
            self._text(snap, "loading…", bx, by + lh, LABEL, self.small)
            return
        speeds = [v or 0 for v in hist["wind"]]
        gusts = [v or 0 for v in hist["gust"]]
        now_v, now_dir = speeds[-1], (hist["wdir"][-1] or 0)
        # readout on the right of the graph
        read = f"{now_v:.0f}"
        rw = self._layout(read, self.big).get_pixel_size()[0]
        rx = bx + bw - rw - lh * 3.2
        self._text(snap, read, rx, by + bh * 0.08, BRIGHT, self.big)
        self._text(snap, unit, rx + rw + lh * 0.2, by + bh * 0.2, LABEL, self.small)
        self._text(snap, f"from {COMPASS[round(now_dir / 22.5) % 16]}", rx + rw + lh * 0.2, by + bh * 0.42, VALUE,
                   self.small)
        self._text(snap, f"gust {gusts[-1]:.0f}", rx + rw + lh * 0.2, by + bh * 0.64, LABEL, self.small)

        # Prevailing direction: speed-weighted vector mean of the last 3 hours.
        dirs = [d or 0 for d in hist["wdir"]]
        ex = sum(v * math.sin(math.radians(d)) for v, d in zip(speeds, dirs))
        ny = sum(v * math.cos(math.radians(d)) for v, d in zip(speeds, dirs))
        prevailing = math.degrees(math.atan2(ex, ny)) % 360
        steadiness = math.hypot(ex, ny) / max(sum(speeds), 1e-6)
        cr = bh * 0.3
        ccx, ccy = rx - lh * 1.4 - cr, by + bh * 0.58
        self._compass(snap, ccx, ccy, cr, prevailing, now_dir, steadiness)
        plabel = f"PREVAILING {COMPASS[round(prevailing / 22.5) % 16]}"
        pw_ = self._layout(plabel, self.small).get_pixel_size()[0]
        self._text(snap, plabel, ccx - pw_ / 2, by - lh * 0.15, TITLE, self.small)

        gx, gy = bx, by + lh * 0.9
        gw, gh = ccx - cr - lh * 2.6 - bx, bh - lh * 1.9
        peak = max(max(gusts), max(speeds), 1)
        top_v = math.ceil(peak / 5) * 5
        snap.append_color(rgba(DIM, 0.8), rect(gx, gy + gh, gw, 1))
        for k in (0.5, 1.0):
            yk = gy + gh - gh * k
            snap.append_color(rgba(DIM, 0.4), rect(gx, yk, gw, 1))
            self._text(snap, f"{top_v * k:g}", gx + gw + lh * 0.15, yk - lh * 0.35, LABEL, self.small)
        n = len(speeds)

        def path(vals):
            b = Gsk.PathBuilder.new()
            for i, v in enumerate(vals):
                px, py = gx + gw * i / max(n - 1, 1), gy + gh - gh * min(v / top_v, 1)
                (b.move_to if i == 0 else b.line_to)(px, py)
            return b.to_path()

        stroke = Gsk.Stroke.new(max(1.0, lh / 18))
        stroke.set_dash([lh * 0.25, lh * 0.2])
        snap.append_stroke(path(gusts), stroke, rgba(LABEL, 0.8))
        snap.append_stroke(path(speeds), Gsk.Stroke.new(max(1.6, lh / 10)), rgba(BRIGHT, 0.95))
        for i, lab in ((0, "−3h"), (n // 3, "−2h"), (2 * n // 3, "−1h"), (n - 1, "now")):
            px = gx + gw * i / max(n - 1, 1)
            self._text(snap, lab, px - (lh * 0.9 if lab == "now" else 0), gy + gh + lh * 0.1, LABEL, self.small)

    # --- radar scope ------------------------------------------------------------

    def _scope_xy(self, lat, lon, bbox):
        cx, cy = self.scope_c
        r = self.scope_r
        x0, y0, x1, y1 = bbox
        return (cx + ((lon - x0) / (x1 - x0) * 2 - 1) * r, cy - ((lat - y0) / (y1 - y0) * 2 - 1) * r)

    def _scope_bbox(self):
        radar = self.hub.get("radar")
        if radar:
            return radar["bbox"]
        loc = self._loc()
        return radar_bbox(loc["lat"], loc["lon"]) if loc else None

    def _scope(self, snap, w, h, t, now):
        bbox = self._scope_bbox()
        if bbox is None:
            return
        cx, cy = self.scope_c
        r = self.scope_r
        radar = self.hub.get("radar")
        if radar and radar["t"] != self.radar_t:
            try:
                self.radar_tex = Gdk.Texture.new_from_bytes(GLib.Bytes.new(radar["png"]))
                self.radar_t = radar["t"]
            except GLib.Error:
                pass
        key = (self.radar_t, self.hub.age("borders") is not None, tuple(round(v, 3) for v in bbox), self.size)
        if key != self.scope_key or self.scope_node is None:
            self.scope_key = key
            self.scope_node = self._build_scope(bbox)
        snap.append_node(self.scope_node)

        # Sweep: a bright wedge trail lights up the radar echoes as the beam passes.
        period = 6.0
        ang = (t % period) / period * 2 * math.pi
        trail, steps = math.radians(100), 20
        circle = rrect(rect(cx - r, cy - r, 2 * r, 2 * r), r)
        snap.push_rounded_clip(circle)
        for k in range(steps):
            a1 = ang - trail * k / steps
            a0 = ang - trail * (k + 1) / steps
            fade = (1 - k / steps) ** 2
            b = Gsk.PathBuilder.new()
            b.move_to(cx, cy)
            for j in range(5):
                a = a0 + (a1 - a0) * j / 4
                b.line_to(cx + r * 1.02 * math.sin(a), cy - r * 1.02 * math.cos(a))
            b.close()
            snap.push_fill(b.to_path(), Gsk.FillRule.WINDING)
            snap.append_color(rgba(PHOSPHOR, 0.10 * fade), rect(cx - r, cy - r, 2 * r, 2 * r))
            if self.radar_tex is not None:
                snap.push_opacity(0.85 * fade)
                snap.append_texture(self.radar_tex, rect(cx - r, cy - r, 2 * r, 2 * r))
                snap.pop()
            snap.pop()
        snap.pop()
        b = Gsk.PathBuilder.new()
        b.move_to(cx, cy)
        b.line_to(cx + r * math.sin(ang), cy - r * math.cos(ang))
        snap.append_stroke(b.to_path(), Gsk.Stroke.new(2.0), rgba(PHOSPHOR, 0.85))

        # Contacts: cameras and nearby earthquakes flare as the beam crosses them.
        def flare(x, y):
            bearing = math.atan2(x - cx, cy - y)
            behind = (ang - bearing) % (2 * math.pi)
            return max(0.0, 1 - behind / math.radians(120))

        dot = max(2.0, self.line_h * 0.14)
        for cam in self.hub.get("cameras") or []:
            x, y = self._scope_xy(cam["lat"], cam["lon"], bbox)
            a = 0.25 + 0.75 * flare(x, y)
            snap.append_color(rgba(BRIGHT, a), rect(x - dot, y - dot, 2 * dot, 2 * dot))
        for q in self.hub.get("quakes") or []:
            x, y = self._scope_xy(q["lat"], q["lon"], bbox)
            if math.hypot(x - cx, y - cy) > r:
                continue
            rr_ = dot * (1 + max(q["mag"], 0))
            snap.push_rounded_clip(rrect(rect(x - rr_, y - rr_, 2 * rr_, 2 * rr_), rr_))
            snap.append_color(rgba(TITLE, 0.3 + 0.7 * flare(x, y)), rect(x - rr_, y - rr_, 2 * rr_, 2 * rr_))
            snap.pop()
        beat = 0.5 + 0.5 * math.sin(t * 3)
        c = dot * (1.4 + beat)
        snap.push_rounded_clip(rrect(rect(cx - c, cy - c, 2 * c, 2 * c), c))
        snap.append_color(rgba(PHOSPHOR, 0.9), rect(cx - c, cy - c, 2 * c, 2 * c))
        snap.pop()

    def _build_scope(self, bbox):
        cx, cy = self.scope_c
        r = self.scope_r
        snap = Gtk.Snapshot()
        circle = rrect(rect(cx - r, cy - r, 2 * r, 2 * r), r)
        snap.push_rounded_clip(circle)
        snap.append_color(rgba(SCOPE_BG), rect(cx - r, cy - r, 2 * r, 2 * r))
        borders = self.hub.get("borders")
        if borders:
            for arcs, alpha, width in ((borders["counties"], 0.09, 1.0), (borders["states"], 0.3, 1.6)):
                b = Gsk.PathBuilder.new()
                for arc in arcs:
                    for i, (lon, lat) in enumerate(arc):
                        x, y = self._scope_xy(lat, lon, bbox)
                        (b.move_to if i == 0 else b.line_to)(x, y)
                snap.append_stroke(b.to_path(), Gsk.Stroke.new(width), rgba(PHOSPHOR, alpha))
        if self.radar_tex is not None:  # resting echo, dim between sweeps
            snap.push_opacity(0.28)
            snap.append_texture(self.radar_tex, rect(cx - r, cy - r, 2 * r, 2 * r))
            snap.pop()
        snap.pop()

        ring = rgba(PHOSPHOR, 0.22)
        imp = self._imp()
        for k in range(1, 5):
            rk = r * k / 4
            b = Gsk.PathBuilder.new()
            b.add_circle(pt(cx, cy), rk)
            snap.append_stroke(b.to_path(), Gsk.Stroke.new(1.0 if k < 4 else 1.8), ring)
            miles = RADAR_MILES * k / 4
            label = f"{miles:.0f} mi" if imp else f"{miles * 1.609:.0f} km"
            self._text(snap, label, cx + rk * 0.707 + 4, cy - rk * 0.707 - self.line_h * 0.5, PHOSPHOR,
                       self.small, alpha=0.45)
        for x0, y0, x1, y1 in ((cx - r, cy, cx + r, cy), (cx, cy - r, cx, cy + r)):
            b = Gsk.PathBuilder.new()
            b.move_to(x0, y0)
            b.line_to(x1, y1)
            snap.append_stroke(b.to_path(), Gsk.Stroke.new(1.0), rgba(PHOSPHOR, 0.12))
        for deg in range(0, 360, 5):
            a = math.radians(deg)
            inner = r * (0.955 if deg % 30 == 0 else 0.975)
            b = Gsk.PathBuilder.new()
            b.move_to(cx + inner * math.sin(a), cy - inner * math.cos(a))
            b.line_to(cx + r * math.sin(a), cy - r * math.cos(a))
            snap.append_stroke(b.to_path(), Gsk.Stroke.new(1.2), rgba(PHOSPHOR, 0.5 if deg % 30 == 0 else 0.25))
            if deg % 30 == 0:
                label = {0: "N", 90: "E", 180: "S", 270: "W"}.get(deg, f"{deg:03d}")
                lw, lh_ = self._layout(label, self.small).get_pixel_size()
                lr = r + self.line_h * 0.7
                self._text(snap, label, cx + lr * math.sin(a) - lw / 2, cy - lr * math.cos(a) - lh_ / 2,
                           PHOSPHOR, self.small, alpha=0.75 if deg % 90 == 0 else 0.45)
        self._text(snap, "NEXRAD REFLECTIVITY · NOAA/IEM", cx - r, cy + r - self.line_h * 0.6, PHOSPHOR,
                   self.small, alpha=0.4)
        return snap.to_node()

    # --- panel contents -------------------------------------------------------

    def _loc(self):
        return self.hub.get("location")

    def _imp(self):
        return self.hub.imperial()

    def _dist(self, km, digits=0):
        if self._imp():
            return f"{km * 0.621371:,.{digits}f} mi"
        return f"{km:,.{digits}f} km"

    def _elev(self):
        wx = self.hub.get("weather")
        return wx.get("elevation", 0.0) if wx else 0.0

    def p_location(self, now):
        loc = self._loc()
        if not loc:
            return [(None, "Locating…", LABEL)]
        lat, lon = loc["lat"], loc["lon"]
        elev = self._elev()
        place = ", ".join(p for p in (loc.get("city"), loc.get("region"), loc.get("country")) if p) or NA
        return [
            ("GPS", f"{lat:.5f}, {lon:.5f}", BRIGHT),
            ("LAT", astro.dms(lat, "N", "S").strip()),
            ("LON", astro.dms(lon, "E", "W").strip()),
            ("ELEVATION", f"{elev * 3.28084:,.0f} ft" if self._imp() else f"{elev:,.0f} m"),
            ("PLACE", place),
            ("PLUS CODE", astro.plus_code(lat, lon)),
            ("FIX", "manual coordinates" if loc["source"] == "manual" else "IP estimate · set exact in settings",
             LABEL),
        ]

    def p_weather(self, now):
        wx = self.hub.get("weather")
        if not wx:
            return [(None, "Waiting for Open-Meteo…", LABEL)]
        c = wx["current"]
        imp = self._imp()
        u, wu = ("°F", "mph") if imp else ("°C", "km/h")
        air = self.hub.get("air")
        aq = f"AQI {air['us_aqi']} {aqi_label(air['us_aqi'])} · PM2.5 {air['pm2_5']}" if air else NA
        pressure = f"{c['pressure_msl'] * 0.02953:.2f} inHg" if imp else f"{c['pressure_msl']:.0f} hPa"
        vis = c.get("visibility")
        vis_s = (f"{vis / 1609.34:.1f} mi" if imp else f"{vis / 1000:.1f} km") if vis is not None else NA
        return [
            ("NOW", f"{c['temperature_2m']:.0f}{u}  {WMO.get(c['weather_code'], '?')}", BRIGHT),
            ("FEELS LIKE", f"{c['apparent_temperature']:.0f}{u}"),
            ("HUMIDITY", f"{c['relative_humidity_2m']}%  dew {c['dew_point_2m']:.0f}{u}"),
            ("WIND", f"{COMPASS[round(c['wind_direction_10m'] / 22.5) % 16]} {c['wind_speed_10m']:.0f} {wu}"
                     f"  gust {c['wind_gusts_10m']:.0f}"),
            ("PRESSURE", pressure),
            ("CLOUD / VIS", f"{c['cloud_cover']}% · {vis_s}"),
            ("UV · PRECIP", f"{c.get('uv_index', 0):.1f} · {c['precipitation']} {'in' if imp else 'mm'}"),
            ("AIR", aq, GOOD if air and air["us_aqi"] <= 50 else VALUE),
        ]

    def p_forecast(self, now):
        wx = self.hub.get("weather")
        if not wx:
            return [(None, "Waiting for Open-Meteo…", LABEL)]
        hr, dy = wx["hourly"], wx["daily"]
        hours = []
        for i in range(0, min(13, len(hr["time"])), 4):
            hh = datetime.fromisoformat(hr["time"][i]).strftime("%-I%p").lower()
            hours.append(f"{hh} {hr['temperature_2m'][i]:.0f}°")
        rain = max((p or 0) for p in hr["precipitation_probability"][:13])
        lines = [("NEXT 12H", "  ".join(hours), BRIGHT), ("PRECIP 12H", f"up to {rain}%")]
        for i in range(min(6, len(dy["time"]))):
            day = "TODAY" if i == 0 else datetime.fromisoformat(dy["time"][i]).strftime("%a").upper()
            p = dy["precipitation_probability_max"][i] or 0
            lines.append((day, f"{WMO.get(dy['weather_code'][i], '?')}  {p:>3}%  "
                               f"{dy['temperature_2m_max'][i]:>3.0f}°/{dy['temperature_2m_min'][i]:.0f}°".ljust(8)))
        return lines

    def p_gravity(self, now):
        loc = self._loc()
        if not loc:
            return [("G", f"{astro.G:.5e} m³/kg·s²")]
        lat, lon = loc["lat"], loc["lon"]
        g0 = astro.normal_gravity(lat, self._elev())
        r = astro.geocentric_radius(lat)
        mo, su = astro.moon(now), astro.sun(now)
        malt, _ = astro.alt_az(mo["ra"], mo["dec"], lat, lon, now)
        salt, _ = astro.alt_az(su["ra"], su["dec"], lat, lon, now)
        dm = -astro.tidal_dg(astro.GM_MOON, mo["dist"], malt, r)
        ds = -astro.tidal_dg(astro.GM_SUN, su["r"] * astro.AU, salt, r)
        pull = astro.GM_MOON / mo["dist"] ** 2
        return [
            ("G  UNIVERSAL", f"{astro.G:.5e} m³/kg·s²", BRIGHT),
            ("g  NORMAL", f"{g0:.7f} m/s²"),
            ("MOON TIDE Δg", f"{dm / 1e-8:+7.1f} µGal"),
            ("SUN TIDE Δg", f"{ds / 1e-8:+7.1f} µGal"),
            ("g  NOW", f"{g0 + dm + ds:.9f} m/s²", BRIGHT),
            ("TIDE Δg/g", f"{(dm + ds) / g0 * 1e9:+.1f} ppb"),
            ("MOON PULL", f"{pull:.3e} m/s² · 1/{g0 / pull:,.0f} g"),
            ("MOON ALT", f"{malt:+.1f}° · {self._dist(mo['dist'] / 1000)}"),
        ]

    def p_motion(self, now):
        loc = self._loc()
        if not loc:
            return [(None, "Locating…", LABEL)]
        f = astro.frame_speeds(loc["lat"], loc["lon"], now)
        mph = astro.KMS_TO_MPH
        traveled = f["cmb"] * (now - self.started)
        return [
            ("vs EARTH'S AXIS", f"{f['axis'] * mph:,.0f} mph"),
            ("vs SUN", f"{f['sun'] * mph:,.0f} mph"),
            ("vs GALACTIC CTR", f"≈{f['galaxy'] * mph:,.0f} mph"),
            ("vs CMB REST", f"{f['cmb'] * mph:,.0f} mph", BRIGHT),
            ("v/c (CMB)", f"{f['cmb'] / astro.C_KMS * 100:.4f}%"),
            ("ORBIT (vis-viva)", f"{f['orbit'] * mph:,.0f} mph"),
            ("SINCE SAVER ON", f"{self._dist(traveled, 0)} through the CMB"),
        ]

    def p_sun_moon(self, now):
        loc = self._loc()
        if not loc:
            return [(None, "Locating…", LABEL)]
        lat, lon = loc["lat"], loc["lon"]
        su, mo = astro.sun(now), astro.moon(now)
        salt, saz = astro.alt_az(su["ra"], su["dec"], lat, lon, now)
        malt, maz = astro.alt_az(mo["ra"], mo["dec"], lat, lon, now)
        malt -= math.degrees(6378140.0 / mo["dist"]) * math.cos(math.radians(malt))  # parallax
        name, illum, age = astro.moon_phase(now)
        light = su["r"] * astro.AU / 299792458.0
        days_full = ((180 - age) % 360) / 12.190749
        rise = sset = NA
        length = NA
        wx = self.hub.get("weather")
        if wx:
            d = wx["daily"]
            r_, s_ = datetime.fromisoformat(d["sunrise"][0]), datetime.fromisoformat(d["sunset"][0])
            rise, sset = r_.strftime("%-I:%M %p"), s_.strftime("%-I:%M %p")
            secs = (s_ - r_).total_seconds()
            length = f"{int(secs // 3600)}h {int(secs % 3600 // 60):02d}m"
        return [
            ("SUN", f"alt {salt:+.1f}°  az {saz:.0f}°", BRIGHT if salt > 0 else VALUE),
            ("RISE / SET", f"{rise} / {sset}"),
            ("DAY LENGTH", length),
            ("SUNLIGHT AGE", f"{int(light // 60)}m {light % 60:04.1f}s · {su['r']:.4f} AU"),
            ("MOON", f"{name} {illum * 100:.0f}%", BRIGHT),
            ("MOON POS", f"alt {malt:+.1f}°  az {maz:.0f}°"),
            ("MOON DIST", self._dist(mo["dist"] / 1000)),
            ("NEXT FULL", f"≈{days_full:.1f} days"),
        ]

    def p_neo(self, now):
        rows = self.hub.get("neo")
        if not rows:
            return [(None, "Waiting for NASA/JPL…", LABEL)]
        jd = astro.julian_day(now)
        AU_KM = astro.AU / 1000
        LD_KM = 384400.0

        def current_km(r):
            # Straight-line flyby estimate around the close approach.
            dt = (jd - r["jd"]) * 86400
            return math.hypot(r["dist"] * AU_KM, r["v_rel"] * dt)

        near = min(rows, key=current_km)
        km = current_km(near)
        ca = datetime.fromtimestamp((near["jd"] - 2440587.5) * 86400, timezone.utc)
        when = "ago" if ca.timestamp() < now else "from now"
        delta = abs(ca.timestamp() - now)
        size = NA
        if near["h"] is not None:
            lo = 1329 / math.sqrt(0.25) * 10 ** (-near["h"] / 5) * 1000
            hi = 1329 / math.sqrt(0.05) * 10 ** (-near["h"] / 5) * 1000
            size = (f"{lo * 3.28084:,.0f}–{hi * 3.28084:,.0f} ft" if self._imp() else f"{lo:,.0f}–{hi:,.0f} m")
        upcoming = sorted((r for r in rows if r["jd"] > jd and r["dist"] < 0.05), key=lambda r: r["jd"])
        nxt = upcoming[0] if upcoming else None
        return [
            ("NAME", near["name"].strip("() ") if near["name"].startswith("(") else near["name"], BRIGHT),
            ("EST. DISTANCE", f"{km / LD_KM:.2f} LD · {self._dist(km)}"),
            ("SPEED (rel.)", f"{near['v_rel'] * astro.KMS_TO_MPH:,.0f} mph"),
            ("CLOSEST PASS", f"{near['dist'] * AU_KM / LD_KM:.2f} LD · {delta / 86400:.1f} d {when}"),
            ("EST. SIZE", f"{size}  (H {near['h']})" if near["h"] else NA),
            ("NEXT < 0.05 AU", f"{nxt['des']} · {nxt['cd'][5:11]} · {nxt['dist'] * AU_KM / LD_KM:.1f} LD"
             if nxt else NA),
            (None, "JPL close-approach data · linear flyby est.", LABEL),
        ]

    def p_iss(self, now):
        iss, loc = self.hub.get("iss"), self._loc()
        if not iss:
            return [(None, "Waiting for wheretheiss.at…", LABEL)]
        lines = [
            ("POSITION", f"{abs(iss['latitude']):.2f}°{'N' if iss['latitude'] >= 0 else 'S'} "
                         f"{abs(iss['longitude']):.2f}°{'E' if iss['longitude'] >= 0 else 'W'}", BRIGHT),
            ("ALTITUDE", self._dist(iss["altitude"])),
            ("SPEED", f"{iss['velocity'] * 0.621371:,.0f} mph" if self._imp() else f"{iss['velocity']:,.0f} km/h"),
        ]
        if loc:
            d, elev = astro.slant_range_km(loc["lat"], loc["lon"], iss["latitude"], iss["longitude"], iss["altitude"])
            lines.append(("RANGE FROM YOU", self._dist(d)))
            lines.append(("ELEVATION", f"{elev:+.1f}° " + ("ABOVE HORIZON" if elev > 0 else "below horizon"),
                          GOOD if elev > 0 else VALUE))
        lines.append(("LIGHTING", iss.get("visibility", NA)))
        return lines

    def p_space(self, now):
        sp = self.hub.get("space")
        if not sp:
            return [(None, "Waiting for NOAA SWPC…", LABEL)]
        kp = sp["kp"]
        storm = "G0 quiet" if kp < 5 else f"G{min(5, int(kp) - 4)} storm"
        wind = sp.get("wind")
        f = lambda v, fmt: fmt.format(v) if v is not None else NA  # noqa: E731
        return [
            ("KP INDEX", f"{kp:.2f}  {storm}", WARN if kp >= 5 else BRIGHT),
            ("SOLAR WIND", f"{wind:.0f} km/s · {wind * astro.KMS_TO_MPH:,.0f} mph" if wind else NA),
            ("IMF Bz / Bt", f"{f(sp.get('bz'), '{:+.0f}')} / {f(sp.get('bt'), '{:.0f}')} nT"),
            ("F10.7 FLUX", f(sp.get("flux"), "{:.0f} sfu")),
            ("SOURCE", "NOAA SWPC", LABEL),
        ]

    def p_outages(self, now):
        o = self.hub.get("outages")
        if not o:
            return [(None, "Waiting for ORNL ODIN…", LABEL)]
        lines = [("CUSTOMERS OUT", f"{o['total']:,}", BRIGHT), ("INCIDENTS", f"{o['incidents']:,}")]
        for st, n in o["states"][:4]:
            lines.append((f"  {st}", f"{n:,}"))
        lines.append((None, "ODIN-reporting utilities only", LABEL))
        return lines

    def p_seismic(self, now):
        qs = self.hub.get("quakes")
        if not qs:
            return [(None, "Waiting for USGS…", LABEL)]
        big = max(qs, key=lambda q: q["mag"])
        energy = sum(10 ** (1.5 * q["mag"] + 4.8) for q in qs)
        lines = [
            ("EVENTS", f"{len(qs)} · {sum(1 for q in qs if q['mag'] >= 4.5)} ≥ M4.5"),
            ("LARGEST", f"M{big['mag']:.1f} {big['place']}", WARN if big["mag"] >= 6 else BRIGHT),
        ]
        loc = self._loc()
        if loc:
            near = min(qs, key=lambda q: astro.haversine_km(loc["lat"], loc["lon"], q["lat"], q["lon"]))
            dkm = astro.haversine_km(loc["lat"], loc["lon"], near["lat"], near["lon"])
            lines.append(("NEAREST YOU", f"M{near['mag']:.1f} · {self._dist(dkm)} · {near['place'].split(', ')[-1]}"))
        last = qs[-1]
        lines.append(("LATEST", f"M{last['mag']:.1f} · {int((now - last['t']) // 60)} min ago"))
        lines.append(("ENERGY", f"{energy:.2e} J · {energy / 4.184e12:,.2f} kt TNT"))
        lines.append(("DEEPEST", f"{max(q['depth'] for q in qs):,.0f} km"))
        return lines

    def p_chrono(self, now):
        loc = self._loc()
        utc = datetime.fromtimestamp(now, timezone.utc)
        local = datetime.fromtimestamp(now).astimezone()
        g = astro.gmst_deg(now) / 15
        hms = lambda hrs: f"{int(hrs):02d}:{int(hrs * 60 % 60):02d}:{int(hrs * 3600 % 60):02d}"  # noqa: E731
        lmst = hms(((astro.gmst_deg(now) + loc["lon"]) % 360) / 15) if loc else NA
        y0 = datetime(utc.year, 1, 1, tzinfo=timezone.utc).timestamp()
        y1 = datetime(utc.year + 1, 1, 1, tzinfo=timezone.utc).timestamp()
        wx = self.hub.get("weather")
        tz = wx["timezone"] if wx else (local.tzname() or NA)
        return [
            ("UNIX", f"{now:.3f}", BRIGHT),
            ("JULIAN DATE", f"{astro.julian_day(now):.5f}"),
            ("GMST", hms(g)),
            ("LOCAL SIDEREAL", lmst),
            ("DAY / WEEK", f"day {utc.timetuple().tm_yday} · ISO week {utc.isocalendar()[1]}"),
            ("TIME ZONE", tz),
            ("YEAR", f"{(now - y0) / (y1 - y0) * 100:.5f}% complete"),
        ]

    def p_machine(self, now):
        try:
            up = float(open("/proc/uptime").read().split()[0])
            mem = dict(line.split(":", 1) for line in open("/proc/meminfo"))
            total = int(mem["MemTotal"].split()[0]) / 1048576
            avail = int(mem["MemAvailable"].split()[0]) / 1048576
        except (OSError, KeyError, ValueError):
            up, total, avail = 0, 0, 0
        l1, l5, l15 = os.getloadavg()
        return [
            ("HOST", socket.gethostname()),
            ("UPTIME", f"{int(up // 86400)}d {int(up % 86400 // 3600)}h {int(up % 3600 // 60)}m"),
            ("LOAD", f"{l1:.2f}  {l5:.2f}  {l15:.2f}  ({os.cpu_count()} CPUs)"),
            ("MEMORY", f"{total - avail:.1f} / {total:.1f} GiB used"),
            ("SAVER ON FOR", f"{int((now - self.started) // 60)} min"),
        ]
