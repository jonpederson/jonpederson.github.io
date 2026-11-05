"""Agents style: mission control for the AI agents working on this computer.

Left: a living constellation. This machine is the core, each project is a hub
around it and each agent orbits its project. Working agents blaze and stream
token particles into their project; every real tool call sends out a
shockwave labelled with the tool, and every new task fires a beam from the
core. Right: a card per agent with live stats. Bottom: the live event feed,
24 hours of activity, and the day's toolkit and token mix.
"""

import math
import os
import random
import socket
import time
import zlib
from datetime import datetime

from gi.repository import Gdk, Graphene, Gsk, Gtk, Pango

from .agents_data import AgentHub

MONO = "Monospace"
SANS = "Sans"

BG = "#05060a"
PANEL = "#0b0e16"
ACCENT = "#e07a52"
TEXT = "#e9e7e2"
DIM = "#7a8291"
FAINT = "#262a36"
WORKING = "#7dffa0"
WARN = "#ff6b6b"
PALETTE = ["#6fe3ff", "#c792ff", "#ffb347", "#7dffa0", "#ff7ab6", "#7aa2ff", "#ffe066", "#5ff0c8"]
CTX_LIMIT = 1_000_000


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


def human(n):
    n = float(n or 0)
    for div, suf in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
        if abs(n) >= div:
            return f"{n / div:.1f}{suf}"
    return f"{n:.0f}"


def dur(s):
    s = max(0, int(s))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m{s % 60:02d}s"
    if s < 86400:
        return f"{s // 3600}h{s % 3600 // 60:02d}m"
    return f"{s // 86400}d{s % 86400 // 3600}h"


def color_for(project):
    return PALETTE[zlib.crc32(project.encode()) % len(PALETTE)]


class Agents:
    def __init__(self, widget, cfg):
        self.widget = widget
        self.hub = AgentHub.get_instance()
        self.details = cfg.get("agents_details", True)
        self.size = None
        self.host = socket.gethostname()
        self.rnd = random.Random()
        self.last_seq = None
        self.particles = []
        self.effects = []
        self.phase = {}
        self.pos = {}
        self.hub_pos = {}
        self.card_nodes = {}
        self.card_rr = 0
        self.card_sig = None
        self.bottom_node = None
        self.bottom_t = 0
        self.feed_seq = None
        self.feed_node = None
        self.feed_t = 0
        self.last_t = None
        self.textures = {}
        self.names = {}

    # --- helpers --------------------------------------------------------------

    def _tex(self, color):
        if color not in self.textures:
            from .saver import orb_texture
            c = rgba(color)
            self.textures[color] = orb_texture(c.red, c.green, c.blue)
        return self.textures[color]

    def _glow(self, snap, x, y, size, color, alpha):
        if alpha <= 0.01:
            return
        snap.push_opacity(min(1.0, alpha))
        snap.append_texture(self._tex(color), rect(x - size / 2, y - size / 2, size, size))
        snap.pop()

    @staticmethod
    def _dot(snap, x, y, r, color):
        snap.push_rounded_clip(rrect(rect(x - r, y - r, 2 * r, 2 * r), r))
        snap.append_color(color, rect(x - r, y - r, 2 * r, 2 * r))
        snap.pop()

    @staticmethod
    def _ring(snap, x, y, r, width, color, dash=None, offset=0.0):
        b = Gsk.PathBuilder.new()
        b.add_circle(pt(x, y), max(r, 0.5))
        stroke = Gsk.Stroke.new(width)
        if dash:
            stroke.set_dash(dash)
            stroke.set_dash_offset(offset)
        snap.append_stroke(b.to_path(), stroke, color)

    @staticmethod
    def _line(snap, x0, y0, x1, y1, width, color):
        b = Gsk.PathBuilder.new()
        b.move_to(x0, y0)
        b.line_to(x1, y1)
        snap.append_stroke(b.to_path(), Gsk.Stroke.new(width), color)

    @staticmethod
    def _font(family, px, weight=Pango.Weight.NORMAL):
        f = Pango.FontDescription.from_string(family)
        f.set_weight(weight)
        f.set_absolute_size(max(px, 4) * Pango.SCALE)
        return f

    def _layout(self, text, font, width=None, align=Pango.Alignment.LEFT):
        layout = self.widget.create_pango_layout(text)
        layout.set_font_description(font)
        if width is not None:
            layout.set_width(int(max(width, 1) * Pango.SCALE))
            layout.set_ellipsize(Pango.EllipsizeMode.END)
            layout.set_alignment(align)
        return layout

    def _text(self, snap, text, x, y, color, font, alpha=1.0, width=None, align=Pango.Alignment.LEFT):
        layout = self._layout(text, font, width, align)
        snap.save()
        snap.translate(pt(x, y))
        snap.append_layout(layout, rgba(color, alpha))
        snap.restore()
        return layout

    def _title(self, a):
        if self.details:
            return a["title"]
        return self.names.setdefault(a["sid"], f"Agent {len(self.names) + 1}")

    def _project(self, name):
        if self.details:
            return name
        return f"project {chr(65 + zlib.crc32(name.encode()) % 26)}"

    def _target(self, target):
        return target if self.details else ""

    # --- layout ---------------------------------------------------------------

    def _setup(self, w, h):
        self.size = (w, h)
        m = self.m = round(h * 0.028)
        self.header = (m, m, w - 2 * m, h * 0.11)
        top = m + h * 0.11 + m * 0.6
        self.bottom_h = h * 0.25
        bottom_y = h - m - self.bottom_h
        main_h = bottom_y - m * 0.6 - top
        cw = (w - 2 * m) * (0.52 if w / h > 2 else 0.5)
        self.const = (m, top, cw, main_h)
        self.cards = (m + cw + m, top, w - 2 * m - cw - m, main_h)
        self.bottom = (m, bottom_y, w - 2 * m, self.bottom_h)
        self.f_huge = self._font(SANS, h * 0.052, Pango.Weight.BOLD)
        self.f_num = self._font(MONO, h * 0.036, Pango.Weight.BOLD)
        self.f_label = self._font(SANS, h * 0.0125, Pango.Weight.BOLD)
        self.f_small = self._font(MONO, h * 0.0135)
        self.f_node = self._font(SANS, h * 0.014)
        self.f_node_b = self._font(SANS, h * 0.0155, Pango.Weight.BOLD)
        self.f_fx = self._font(MONO, h * 0.0145, Pango.Weight.BOLD)
        self.card_nodes.clear()
        self.bottom_node = None
        self.feed_node = None

    # --- frame ----------------------------------------------------------------

    def draw(self, snap, w, h, t):
        if self.size != (w, h):
            self._setup(w, h)
        dt = 0.016 if self.last_t is None else min(max(t - self.last_t, 0), 0.1)
        self.last_t = t
        now = time.time()
        s = self.hub.snapshot
        snap.append_color(rgba(BG), rect(0, 0, w, h))
        jx, jy = 5 * math.sin(t * 0.008), 5 * math.cos(t * 0.011)
        snap.save()
        snap.translate(pt(jx, jy))
        if s is None:
            self._text(snap, "Scanning for agents…", w / 2 - h * 0.15, h / 2, DIM, self.f_node_b)
            snap.restore()
            return
        self._ingest_events(s, now)
        self._header(snap, s, now)
        self._constellation(snap, s, t, dt, now)
        self._cards(snap, s, t, now)
        self._bottom(snap, s, t, now)
        snap.restore()

    def _ingest_events(self, s, now):
        events = s["events"]
        if not events:
            return
        if self.last_seq is None:
            self.last_seq = events[-1][0]  # don't replay history at launch
            return
        for seq, ts, sid, kind, name, target in events:
            if seq <= self.last_seq:
                continue
            self.last_seq = seq
            self.effects.append(dict(kind=kind, sid=sid, name=name, target=self._target(target), t0=now))
        self.effects = self.effects[-40:]

    # --- header ---------------------------------------------------------------

    def _header(self, snap, s, now):
        x, y, w, h = self.header
        agents = s["agents"]
        busy = sum(1 for a in agents if a["busy"])
        self._text(snap, "AGENTS", x, y - h * 0.08, ACCENT, self.f_huge)
        sub = f"MISSION CONTROL · {self.host} · {datetime.now().strftime('%H:%M:%S')}"
        if s["others"]:
            sub += " · also running: " + ", ".join(s["others"])
        self._text(snap, sub, x, y + h * 0.58, DIM, self.f_label)

        today = s["today"]
        total = sum(today.get(k, 0) for k in ("input", "cache_write", "cache_read", "output"))
        rate = sum(a["out_rate"] for a in agents)
        pages = today.get("output", 0) * 0.75 / 500
        tiles = [
            ("AGENTS ONLINE", str(len(agents)), TEXT),
            ("WORKING NOW", str(busy), WORKING if busy else DIM),
            ("OUTPUT TOKENS / MIN", human(rate), ACCENT if rate else DIM),
            ("TOKENS TODAY", human(total), TEXT),
            ("TOOL CALLS TODAY", f"{today.get('tool_calls', 0):,}", TEXT),
            ("FILES EDITED TODAY", str(s["files_today"]), TEXT),
            ("PAGES WRITTEN TODAY", f"≈{pages:,.0f}", TEXT),
        ]
        right = x + w
        gap = h * 0.45
        for label, value, color in reversed(tiles):
            vw = self._layout(value, self.f_num).get_pixel_size()[0]
            lw = self._layout(label, self.f_label).get_pixel_size()[0]
            tw = max(vw, lw)
            self._text(snap, value, right - vw, y - h * 0.02, color, self.f_num)
            self._text(snap, label, right - lw, y + h * 0.58, DIM, self.f_label)
            right -= tw + gap
            if right < x + w * 0.3:
                break
        snap.append_color(rgba(FAINT), rect(x, y + h, w, 1))

    # --- constellation --------------------------------------------------------

    def _constellation(self, snap, s, t, dt, now):
        x0, y0, cw, ch = self.const
        agents = s["agents"]
        cx, cy = x0 + cw / 2, y0 + ch / 2
        mn = min(cw, ch)
        rc = mn * 0.065
        busy_total = sum(1 for a in agents if a["busy"])

        # faint polar grid
        for k in range(1, 4):
            self._ring(snap, cx, cy, mn * 0.16 * k, 1.0, rgba(FAINT, 0.7), dash=[2, 10], offset=t * 3 * k)

        projects = sorted({a["project"] for a in agents})
        n = len(projects)
        rx, ry = cw * 0.34, ch * 0.33
        self.hub_pos = {}
        for i, p in enumerate(projects):
            ang = -math.pi / 2 + 2 * math.pi * i / max(n, 1) + t * 0.012
            self.hub_pos[p] = (cx + rx * math.cos(ang), cy + ry * math.sin(ang)) if n > 1 else (cx, cy - ry)

        # agents orbit their project hub
        self.pos = {}
        by_proj = {}
        for a in agents:
            by_proj.setdefault(a["project"], []).append(a)
        ro = mn * 0.17
        for p, members in by_proj.items():
            hx, hy = self.hub_pos[p]
            for j, a in enumerate(members):
                sp = 0.32 if a["busy"] else 0.045
                ph = self.phase.get(a["sid"], self.rnd.uniform(0, 6.28)) + sp * dt
                self.phase[a["sid"]] = ph
                ang = ph + 2 * math.pi * j / len(members)
                r = ro * (1 + 0.28 * (j % 2))
                self.pos[a["sid"]] = (hx + r * math.cos(ang), hy + r * 0.8 * math.sin(ang))

        # links
        for p, (hx, hy) in self.hub_pos.items():
            col = color_for(p)
            active = any(a["busy"] for a in by_proj.get(p, []))
            self._line(snap, cx, cy, hx, hy, 1.4 if active else 1.0, rgba(col, 0.35 if active else 0.14))
            if active:  # data pulses along the link
                for k in range(3):
                    f = (t * 0.45 + k / 3) % 1
                    self._glow(snap, cx + (hx - cx) * f, cy + (hy - cy) * f, mn * 0.05, col, 0.5)
            for a in by_proj.get(p, []):
                ax, ay = self.pos[a["sid"]]
                self._line(snap, hx, hy, ax, ay, 1.0, rgba(col, 0.28 if a["busy"] else 0.1))

        # token particles from working agents into their project
        for a in agents:
            if not a["busy"]:
                continue
            rate = 5 + min(30, a["out_rate"] / 60)
            if self.rnd.random() < rate * dt:
                ax, ay = self.pos[a["sid"]]
                self.particles.append(dict(sid=a["sid"], p=a["project"], x=ax, y=ay, f=0.0,
                                           v=self.rnd.uniform(0.5, 0.9), bend=self.rnd.uniform(-0.35, 0.35)))
        alive = []
        for q in self.particles[-500:]:
            q["f"] += q["v"] * dt
            if q["f"] >= 1 or q["p"] not in self.hub_pos:
                continue
            hx, hy = self.hub_pos[q["p"]]
            f = q["f"]
            mx, my = (q["x"] + hx) / 2 - (hy - q["y"]) * q["bend"], (q["y"] + hy) / 2 + (hx - q["x"]) * q["bend"]
            px = (1 - f) ** 2 * q["x"] + 2 * (1 - f) * f * mx + f * f * hx
            py = (1 - f) ** 2 * q["y"] + 2 * (1 - f) * f * my + f * f * hy
            self._glow(snap, px, py, mn * 0.028, color_for(q["p"]), 0.9 * math.sin(math.pi * f))
            alive.append(q)
        self.particles = alive

        # core: this machine
        load = os.getloadavg()[0] / (os.cpu_count() or 1)
        pulse = 0.5 + 0.5 * math.sin(t * (1.2 + 3 * min(load, 1)))
        self._glow(snap, cx, cy, rc * (7 + busy_total * 0.6), ACCENT, 0.35 + 0.25 * pulse)
        self._dot(snap, cx, cy, rc, rgba("#120c0a"))
        self._ring(snap, cx, cy, rc, 2.0, rgba(ACCENT, 0.9))
        self._ring(snap, cx, cy, rc * 1.28, 1.5, rgba(ACCENT, 0.55), dash=[rc * 0.5, rc * 0.25], offset=t * 20)
        self._ring(snap, cx, cy, rc * 1.55, 1.0, rgba(ACCENT, 0.3), dash=[rc * 0.12, rc * 0.2], offset=-t * 12)
        hw = rc * 1.8
        self._text(snap, self.host, cx - hw / 2, cy - rc * 0.42, TEXT, self.f_node_b, width=hw,
                   align=Pango.Alignment.CENTER)
        self._text(snap, f"load {os.getloadavg()[0]:.2f}", cx - hw / 2, cy + rc * 0.08, DIM, self.f_node,
                   width=hw, align=Pango.Alignment.CENTER)

        # project hubs
        rh = mn * 0.04
        for p, (hx, hy) in self.hub_pos.items():
            col = color_for(p)
            members = by_proj.get(p, [])
            active = any(a["busy"] for a in members)
            self._glow(snap, hx, hy, rh * 6, col, 0.45 if active else 0.18)
            self._dot(snap, hx, hy, rh, rgba(BG))
            self._ring(snap, hx, hy, rh, 2.0, rgba(col, 0.95 if active else 0.55))
            self._ring(snap, hx, hy, rh * 0.62, 1.0, rgba(col, 0.4), dash=[3, 4], offset=t * (12 if active else 2))
            lw = mn * 0.4
            self._text(snap, self._project(p), hx - lw / 2, hy + rh * 1.25, col, self.f_node_b, width=lw,
                       align=Pango.Alignment.CENTER)
            git = next((a["git"] for a in members if a["git"]), None)
            info = f"{len(members)} agent{'s' if len(members) != 1 else ''}"
            if git:
                info += f" · {git['branch']}"
                if git["add"] or git["del"]:
                    info += f" +{git['add']} −{git['del']}"
            self._text(snap, info, hx - lw / 2, hy + rh * 1.25 + self.size[1] * 0.02, DIM, self.f_node,
                       width=lw, align=Pango.Alignment.CENTER)

        # agents
        ra = mn * 0.02
        for a in agents:
            ax, ay = self.pos[a["sid"]]
            col = color_for(a["project"])
            if a["busy"]:
                beat = 0.5 + 0.5 * math.sin(t * 5 + a["pid"])
                self._glow(snap, ax, ay, ra * (9 + 3 * beat), col, 0.75)
                self._dot(snap, ax, ay, ra * 1.15, rgba("#ffffff", 0.95))
                self._ring(snap, ax, ay, ra * 1.9, 2.0, rgba(col, 0.9), dash=[ra * 1.2, ra * 0.8], offset=t * 30)
            else:
                breathe = 0.5 + 0.5 * math.sin(t * 0.8 + a["pid"])
                self._glow(snap, ax, ay, ra * 5, col, 0.12 + 0.08 * breathe)
                self._dot(snap, ax, ay, ra * 0.75, rgba(col, 0.55))
            if a["busy"]:  # idle agents stay quiet; their cards carry the details
                lw = mn * 0.36
                self._text(snap, self._title(a), ax - lw / 2, ay + ra * 2.2, TEXT, self.f_node, width=lw,
                           align=Pango.Alignment.CENTER)
                self._text(snap, f"WORKING {dur(now - a['since'])}", ax - lw / 2, ay - ra * 2.2 - self.size[1] * 0.02,
                           WORKING, self.f_label, width=lw, align=Pango.Alignment.CENTER)

        # event effects: shockwaves, floating tool labels, task beams
        stack = {}
        keep = []
        for e in self.effects:
            age = now - e["t0"]
            if e["sid"] not in self.pos or age > 4.0:
                continue
            keep.append(e)
            ax, ay = self.pos[e["sid"]]
            col = WORKING if e["kind"] == "prompt" else color_for(next(
                (a["project"] for a in agents if a["sid"] == e["sid"]), "?"))
            if age < 1.6:
                k = age / 1.6
                scale = 9 if e["kind"] == "prompt" else 6 if e["kind"] == "tool" else 4
                self._ring(snap, ax, ay, ra * (1.5 + scale * k), 2.5 * (1 - k) + 0.5, rgba(col, 0.9 * (1 - k)))
            if e["kind"] == "prompt" and age < 2.0:
                k = age / 2.0
                self._line(snap, cx, cy, ax, ay, 3 * (1 - k) + 0.5, rgba(WORKING, 0.8 * (1 - k)))
                f = min(1.0, age / 0.6)
                self._glow(snap, cx + (ax - cx) * f, cy + (ay - cy) * f, mn * 0.08, WORKING, 1 - k)
            idx = stack.get(e["sid"], 0)
            stack[e["sid"]] = idx + 1
            alpha = min(1.0, (4.0 - age) / 1.2)
            label = e["name"] + (f"  {e['target']}" if e["target"] else "")
            ly = ay - ra * 3 - age * self.size[1] * 0.012 - idx * self.size[1] * 0.022
            self._text(snap, label, ax + ra * 2.5, ly, col, self.f_fx, alpha=alpha, width=mn * 0.45)
        self.effects = keep

        # caption
        nproj = len(projects)
        caption = (f"{len(agents)} agent{'s' if len(agents) != 1 else ''} · {nproj} project{'s' if nproj != 1 else ''}"
                   f" · {busy_total} working right now") if agents else "No agents running right now"
        self._text(snap, caption.upper(), x0, y0, DIM, self.f_label)

    # --- cards ----------------------------------------------------------------

    def _cards(self, snap, s, t, now):
        x0, y0, w, h = self.cards
        agents = s["agents"][:10]
        if not agents:
            self._text(snap, "Start a Claude Code session and it will appear here.", x0, y0 + h / 2, DIM, self.f_node_b)
            return
        n = len(agents)
        cols = 1 if n <= 3 else 2
        rows = math.ceil(n / cols)
        gap = self.m * 0.5
        card_w = (w - gap * (cols - 1)) / cols
        card_h = (h - gap * (rows - 1)) / rows
        sig = (n, cols, round(card_w), round(card_h), tuple(a["sid"] for a in agents))
        if sig != self.card_sig:
            self.card_sig = sig
            self.card_nodes = {}
        for i, a in enumerate(agents):  # build missing cards, then refresh one per frame
            if a["sid"] not in self.card_nodes:
                self.card_nodes[a["sid"]] = self._build_card(a, card_w, card_h, now)
        rr = agents[self.card_rr % n]
        self.card_nodes[rr["sid"]] = self._build_card(rr, card_w, card_h, now)
        self.card_rr += 1
        for i, a in enumerate(agents):
            cx = x0 + (i % cols) * (card_w + gap)
            cy = y0 + (i // cols) * (card_h + gap)
            col = color_for(a["project"])
            if a["busy"]:
                beat = 0.5 + 0.5 * math.sin(t * 3)
                self._glow(snap, cx + card_w / 2, cy + card_h / 2, max(card_w, card_h) * 1.1, col, 0.10 + 0.08 * beat)
            snap.save()
            snap.translate(pt(cx, cy))
            snap.append_node(self.card_nodes[a["sid"]])
            snap.restore()
            if a["busy"]:
                edge = rgba(col, 0.5 + 0.4 * beat)
                snap.append_border(rrect(rect(cx, cy, card_w, card_h), 8),
                                   [1.5] * 4, [edge] * 4)

    def _build_card(self, a, w, h, now):
        snap = Gtk.Snapshot()
        col = color_for(a["project"])
        snap.push_rounded_clip(rrect(rect(0, 0, w, h), 8))
        snap.append_color(rgba(PANEL, 0.92), rect(0, 0, w, h))
        snap.append_color(rgba(col, 0.9 if a["busy"] else 0.45), rect(0, 0, 4, h))
        snap.pop()
        lh = min(h / 7.3, self.size[1] * 0.026)
        pad = lh * 0.55
        x, inner = pad + 4, w - 2 * pad - 4
        f_t = self._font(SANS, lh * 0.72, Pango.Weight.BOLD)
        f_v = self._font(MONO, lh * 0.56)
        f_l = self._font(SANS, lh * 0.46, Pango.Weight.BOLD)
        y = pad * 0.6

        status = f"WORKING {dur(now - a['since'])}" if a["busy"] else f"IDLE {dur(now - a['since'])}"
        sw = self._layout(status, f_l).get_pixel_size()[0]
        self._text(snap, self._title(a), x, y, TEXT, f_t, width=inner - sw - lh)
        sc = WORKING if a["busy"] else DIM
        self._dot(snap, x + inner - sw - lh * 0.35, y + lh * 0.42, lh * 0.14, rgba(sc))
        self._text(snap, status, x + inner - sw, y + lh * 0.18, sc, f_l)
        y += lh
        self._text(snap, f"{self._project(a['project'])} · {a['model']} · {a['effort']} effort · up {dur(now - a['started'])}",
                   x, y, col, f_v, width=inner)
        y += lh

        last = a["last"]
        if last:
            name, target, ts = last
            target = self._target(target)
            verb = "NOW" if a["busy"] else "LAST"
            self._text(snap, verb, x, y + lh * 0.08, DIM, f_l)
            lw = lh * 2.2
            self._text(snap, f"{name}{'  ' + target if target else ''}", x + lw, y, TEXT, f_v,
                       width=inner - lw - lh * 3.5)
            self._text(snap, f"{dur(now - ts)} ago", x + inner - lh * 3.4, y, DIM, f_v, width=lh * 3.4,
                       align=Pango.Alignment.RIGHT)
        y += lh

        stats = [("TASKS", f"{a['prompts']}"), ("TOOLS", f"{a['tool_calls']:,}"), ("ERRORS", f"{a['errors']}"),
                 ("SUBAGENTS", f"{a['subagents']}"), ("FILES", f"{a['files']}")]
        cw_ = inner / len(stats)
        for i, (lab, val) in enumerate(stats):
            self._text(snap, lab, x + i * cw_, y + lh * 0.08, DIM, f_l)
            lw = self._layout(lab + " ", f_l).get_pixel_size()[0]
            self._text(snap, val, x + i * cw_ + lw, y, WARN if lab == "ERRORS" and a["errors"] else TEXT, f_v)
        y += lh

        tok = a["tokens"]
        reads = tok.get("cache_read", 0)
        fresh = tok.get("input", 0) + tok.get("cache_write", 0)
        hit = reads / (reads + fresh) * 100 if reads + fresh else 0
        self._text(snap, f"OUT {human(tok.get('output'))}  THINK {human(tok.get('thinking'))}  CACHE {hit:.0f}%",
                   x, y, TEXT, f_v, width=inner * 0.6)
        bx, bw = x + inner * 0.62, inner * 0.38
        fill = min(1.0, a["ctx"] / CTX_LIMIT)
        self._text(snap, f"CTX {human(a['ctx'])}", bx, y, DIM, f_v)
        bar_x = bx + self._layout("CTX 000.0k ", f_v).get_pixel_size()[0]
        bar_w = bx + bw - bar_x
        snap.append_color(rgba(FAINT), rect(bar_x, y + lh * 0.3, bar_w, lh * 0.28))
        snap.append_color(rgba(WARN if fill > 0.8 else col, 0.85), rect(bar_x, y + lh * 0.3, bar_w * fill, lh * 0.28))
        y += lh

        # activity sparkline (tool calls per minute, last hour) + process stats
        sw_ = inner * 0.45
        spark = a["spark"]
        peak = max(max(spark), 1)
        bw_ = sw_ / len(spark)
        for i, v in enumerate(spark):
            if v:
                bh = (lh * 0.85) * v / peak
                snap.append_color(rgba(col, 0.85), rect(x + i * bw_, y + lh * 0.9 - bh, max(bw_ - 1, 1), bh))
        snap.append_color(rgba(FAINT), rect(x, y + lh * 0.9, sw_, 1))
        kids = ", ".join(f"{c}" + (f"×{k}" if k > 1 else "") for c, k in a["kids"]) or "—"
        self._text(snap, f"CPU {a['cpu']:.0f}%  MEM {human(a['rss'])}B  ▸ {kids}", x + sw_ + lh * 0.5, y, DIM, f_v,
                   width=inner - sw_ - lh * 0.5)
        y += lh

        git = a["git"]
        if git:
            g = f"⎇ {git['branch']}  +{git['add']} −{git['del']}  {git['changed']} changed"
            if git["ahead"]:
                g += f"  {git['ahead']} unpushed"
        else:
            g = "not a git repository"
        tools = "  ".join(f"{n} {c}" for n, c in a["tools"][:3])
        self._text(snap, g, x, y, DIM, f_v, width=inner * 0.5)
        self._text(snap, tools, x + inner * 0.5, y, DIM, f_v, width=inner * 0.5, align=Pango.Alignment.RIGHT)
        return snap.to_node()

    # --- bottom strip ---------------------------------------------------------

    def _bottom(self, snap, s, t, now):
        x0, y0, w, h = self.bottom
        snap.append_color(rgba(FAINT), rect(x0, y0 - self.m * 0.3, w, 1))
        feed_w = w * 0.42
        # live feed (rebuilt when new events arrive)
        seq = s["events"][-1][0] if s["events"] else 0
        if seq != self.feed_seq or self.feed_node is None or now - self.feed_t > 1:
            self.feed_seq, self.feed_t = seq, now
            self.feed_node = self._build_feed(s, feed_w, h, now)
        snap.save()
        snap.translate(pt(x0, y0))
        snap.append_node(self.feed_node)
        snap.restore()
        # flash the newest row
        if s["events"]:
            age = now - s["events"][-1][1]
            if age < 2:
                rh = self._feed_row_h
                snap.append_color(rgba(ACCENT, 0.18 * (1 - age / 2)), rect(x0, y0 + self._feed_top, feed_w, rh))
        if self.bottom_node is None or now - self.bottom_t > 2:
            self.bottom_t = now
            self.bottom_node = self._build_stats(s, w - feed_w - self.m, h, now)
        snap.save()
        snap.translate(pt(x0 + feed_w + self.m, y0))
        snap.append_node(self.bottom_node)
        snap.restore()

    def _build_feed(self, s, w, h, now):
        snap = Gtk.Snapshot()
        self._text(snap, "LIVE FEED", 0, 0, ACCENT, self.f_label)
        rh = self._feed_row_h = self.size[1] * 0.024
        top = self._feed_top = self.size[1] * 0.026
        sid_proj = {a["sid"]: a for a in s["agents"]}
        rows = int((h - top) // rh)
        events = list(reversed(s["events"]))[:rows]
        if not events:
            self._text(snap, "Waiting for the next tool call…", 0, top, DIM, self.f_small)
        tw = self._layout("00:00:00  ", self.f_small).get_pixel_size()[0]
        for i, (seq, ts, sid, kind, name, target) in enumerate(events):
            y = top + i * rh
            a = sid_proj.get(sid)
            proj = a["project"] if a else "?"
            col = color_for(proj)
            fade = max(0.35, 1 - i / max(rows, 1) * 0.75)
            self._text(snap, datetime.fromtimestamp(ts).strftime("%H:%M:%S"), 0, y, DIM, self.f_small, alpha=fade)
            self._dot(snap, tw + rh * 0.2, y + rh * 0.42, rh * 0.16, rgba(col, fade))
            px = tw + rh * 0.6
            pw = w * 0.17
            self._text(snap, self._project(proj), px, y, col, self.f_small, alpha=fade, width=pw)
            nx = px + pw
            label = ("◆ " if kind == "prompt" else "↳ " if kind == "subtool" else "") + name
            nc = WORKING if kind == "prompt" else TEXT
            nw = w * 0.2
            self._text(snap, label, nx, y, nc, self.f_small, alpha=fade, width=nw)
            self._text(snap, self._target(target) or (self._title(a) if a and kind == "prompt" else ""),
                       nx + nw, y, DIM, self.f_small, alpha=fade, width=w - nx - nw)
        return snap.to_node()

    def _build_stats(self, s, w, h, now):
        snap = Gtk.Snapshot()
        chart_w = w * 0.56
        # 24h activity, stacked by project
        self._text(snap, "ACTIVITY · LAST 24 HOURS", 0, 0, ACCENT, self.f_label)
        legend_y = self.size[1] * 0.024
        top = self.size[1] * 0.052
        ch = h - top - self.size[1] * 0.03
        hours = s["hours"]
        peak = max([sum(c for _, c in hr) for hr in hours] + [1])
        bw = chart_w / 24
        for i, hr in enumerate(hours):
            y = top + ch
            for p, c in hr:
                if c:
                    bh = ch * c / peak
                    y -= bh
                    snap.append_color(rgba(color_for(p), 0.85), rect(i * bw + 1, y, bw - 2, bh))
        snap.append_color(rgba(FAINT), rect(0, top + ch, chart_w, 1))
        for i, lab in ((0, "−24h"), (6, "−18h"), (12, "−12h"), (18, "−6h")):
            self._text(snap, lab, i * bw, top + ch + 2, DIM, self.f_small)
        self._text(snap, "now", chart_w - self._layout("now", self.f_small).get_pixel_size()[0], top + ch + 2,
                   DIM, self.f_small)
        self._text(snap, f"peak {peak} actions/h", chart_w * 0.5, 0, DIM, self.f_small,
                   width=chart_w * 0.5, align=Pango.Alignment.RIGHT)
        # legend
        lx = 0
        for p in s["projects"][:6]:
            label = self._project(p)
            self._dot(snap, lx + 5, legend_y + self.size[1] * 0.009, 4, rgba(color_for(p)))
            self._text(snap, label, lx + 13, legend_y - 2, DIM, self.f_small)
            lx += self._layout(label, self.f_small).get_pixel_size()[0] + 30

        # toolkit + token mix
        x = chart_w + self.m
        tw = w - x
        self._text(snap, "TOOLKIT TODAY", x, 0, ACCENT, self.f_label)
        tools = s["tools_today"][:6]
        tpeak = max([c for _, c in tools] + [1])
        rh = self.size[1] * 0.021
        y = legend_y
        for name, c in tools:
            self._text(snap, name, x, y, TEXT, self.f_small, width=tw * 0.32)
            bx = x + tw * 0.34
            snap.append_color(rgba(ACCENT, 0.75), rect(bx, y + rh * 0.25, (tw * 0.5) * c / tpeak, rh * 0.5))
            self._text(snap, f"{c}", x + tw * 0.86, y, DIM, self.f_small)
            y += rh
        today = s["today"]
        out = today.get("output", 0)
        typist_h = out * 0.75 / 40 / 60
        reads = today.get("cache_read", 0)
        fresh = today.get("input", 0) + today.get("cache_write", 0)
        hit = reads / (reads + fresh) * 100 if reads + fresh else 0
        y += rh * 0.4
        lines = [
            f"output {human(out)} · thinking {human(today.get('thinking'))}",
            f"context read {human(reads + fresh)} · cache hit {hit:.0f}%",
            f"≈{typist_h:,.1f} h of human typing · {s['sessions_today']} sessions today",
        ]
        for line in lines:
            if y + rh > h:
                break
            self._text(snap, line, x, y, DIM, self.f_small, width=tw)
            y += rh
        return snap.to_node()
