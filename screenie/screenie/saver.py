"""The fullscreen screensaver window (one per monitor)."""

import math
import random
import sys
import time

import cairo
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Graphene", "1.0")
from gi.repository import Gdk, Gio, GLib, Graphene, Gtk, Pango

from . import config

APP_ID = "local.screenie.Saver"
GRACE_SECONDS = 1.0  # ignore input right after showing (e.g. releasing the shortcut keys)
MOTION_THRESHOLD = 12  # pixels of mouse movement before dismissing
FADE_SECONDS = 1.5

AURORA_COLORS = [
    (0.20, 0.45, 1.00),
    (0.55, 0.25, 0.95),
    (0.10, 0.80, 0.75),
    (0.95, 0.35, 0.60),
    (0.25, 0.65, 1.00),
]


def rect(x, y, w, h):
    return Graphene.Rect().init(x, y, w, h)


def rgba(r, g, b, a=1.0):
    c = Gdk.RGBA()
    c.red, c.green, c.blue, c.alpha = r, g, b, a
    return c


def orb_texture(r, g, b, size=256):
    """A soft radial glow, rendered once and scaled on the GPU every frame."""
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    cr = cairo.Context(surf)
    grad = cairo.RadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2)
    grad.add_color_stop_rgba(0.0, r, g, b, 0.38)
    grad.add_color_stop_rgba(0.4, r, g, b, 0.14)
    grad.add_color_stop_rgba(1.0, r, g, b, 0.0)
    cr.set_source(grad)
    cr.paint()
    surf.flush()
    data = GLib.Bytes.new(bytes(surf.get_data()))
    return Gdk.MemoryTexture.new(size, size, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED,
                                 data, surf.get_stride())


class Scene(Gtk.Widget):
    def __init__(self, cfg):
        super().__init__()
        self.style = cfg["style"]
        self.show_clock = cfg["show_clock"]
        iface = Gio.Settings.new("org.gnome.desktop.interface")
        self.time_fmt = "%-I:%M" if iface.get_string("clock-format") == "12h" else "%H:%M"
        self.start = None
        self.t = 0.0
        self.last = 0.0
        rnd = random.Random()

        if self.style == "aurora":
            self.orbs = [
                dict(tex=orb_texture(*AURORA_COLORS[i % len(AURORA_COLORS)]),
                     fx=rnd.uniform(0.03, 0.08), fy=rnd.uniform(0.03, 0.08),
                     px=rnd.uniform(0, 6.28), py=rnd.uniform(0, 6.28),
                     fr=rnd.uniform(0.05, 0.12), size=rnd.uniform(0.7, 1.2))
                for i in range(7)
            ]
        elif self.style == "agents":
            from .agents import Agents
            self.agents = Agents(self, cfg)
        elif self.style == "hud":
            from .hud import Hud
            self.hud = Hud(self, cfg)
        elif self.style == "farm":
            from .farm import Farm
            self.farm = Farm(self, self.show_clock, self.time_fmt)
        elif self.style == "starfield":
            self.stars = [self._new_star(rnd, rnd.uniform(0.05, 1.0)) for _ in range(500)]
            self.rnd = rnd

        # Clock drifts slowly around the screen so nothing burns in.
        self.clock_pos = None
        self.clock_vel = (rnd.choice((-1, 1)) * 18.0, rnd.choice((-1, 1)) * 13.0)
        self.add_tick_callback(self._tick)

    @staticmethod
    def _new_star(rnd, z=1.0):
        return [rnd.uniform(-1, 1), rnd.uniform(-1, 1), z]

    def _tick(self, _widget, clock):
        now = clock.get_frame_time() / 1e6
        if self.start is None:
            self.start = self.last = now
        dt = min(now - self.last, 0.1)
        self.last = now
        self.t = now - self.start
        self._advance(dt)
        self.queue_draw()
        return GLib.SOURCE_CONTINUE

    def _advance(self, dt):
        if self.style == "starfield":
            for s in self.stars:
                s[2] -= dt * 0.12
                if s[2] <= 0.02:
                    s[:] = self._new_star(self.rnd)
        if self.clock_pos is not None:
            x, y = self.clock_pos
            self.clock_pos = (x + self.clock_vel[0] * dt, y + self.clock_vel[1] * dt)

    def do_snapshot(self, snap):
        w, h = self.get_width(), self.get_height()
        if w <= 0 or h <= 0:
            return
        snap.append_color(rgba(0, 0, 0), rect(0, 0, w, h))
        fade = min(1.0, self.t / FADE_SECONDS)
        snap.push_opacity(fade)
        if self.style == "aurora":
            self._draw_aurora(snap, w, h)
        elif self.style == "starfield":
            self._draw_stars(snap, w, h)
        elif self.style == "farm":
            self.farm.draw(snap, w, h, self.t)  # the drone HUD shows the time instead
        elif self.style == "hud":
            self.hud.draw(snap, w, h, self.t)
        elif self.style == "agents":
            self.agents.draw(snap, w, h, self.t)
        if self.show_clock and self.style not in ("farm", "hud", "agents"):
            self._draw_clock(snap, w, h)
        snap.pop()

    def _draw_aurora(self, snap, w, h):
        snap.append_color(rgba(0.01, 0.01, 0.04), rect(0, 0, w, h))
        base = max(w, h) * 0.75
        t = self.t
        for o in self.orbs:
            size = base * o["size"] * (1 + 0.25 * math.sin(t * o["fr"] * 6.28))
            cx = w * (0.5 + 0.45 * math.sin(t * o["fx"] * 6.28 + o["px"]))
            cy = h * (0.5 + 0.45 * math.sin(t * o["fy"] * 6.28 + o["py"]))
            snap.append_texture(o["tex"], rect(cx - size / 2, cy - size / 2, size, size))

    def _draw_stars(self, snap, w, h):
        cx, cy = w / 2, h / 2
        f = max(w, h) * 0.5
        for x, y, z in self.stars:
            sx, sy = cx + x / z * f * 0.5, cy + y / z * f * 0.5
            if not (0 <= sx < w and 0 <= sy < h):
                continue
            near = 1.0 - z
            size = 0.8 + near * 3.2
            b = min(1.0, near * 1.3)
            snap.append_color(rgba(0.8 + 0.2 * b, 0.85 + 0.15 * b, 1.0, b),
                              rect(sx - size / 2, sy - size / 2, size, size))

    def _layout(self, text, px, weight=Pango.Weight.LIGHT):
        layout = self.create_pango_layout(text)
        desc = Pango.FontDescription.from_string("Sans")
        desc.set_weight(weight)
        desc.set_absolute_size(px * Pango.SCALE)
        layout.set_font_description(desc)
        return layout

    def _draw_clock(self, snap, w, h):
        now = time.localtime()
        big = self._layout(time.strftime(self.time_fmt, now), h * 0.13)
        small = self._layout(time.strftime("%A, %B %-d", now), h * 0.03, Pango.Weight.NORMAL)
        bw, bh = big.get_pixel_size()
        sw, sh = small.get_pixel_size()
        cw, ch = max(bw, sw), bh + sh

        if self.clock_pos is None:
            self.clock_pos = ((w - cw) / 2, (h - ch) / 2)
        x, y = self.clock_pos
        vx, vy = self.clock_vel
        if x < 0 or x + cw > w:
            vx = -vx if (x < 0) == (vx < 0) else vx
        if y < 0 or y + ch > h:
            vy = -vy if (y < 0) == (vy < 0) else vy
        self.clock_vel = (vx, vy)
        x, y = min(max(x, 0), max(w - cw, 0)), min(max(y, 0), max(h - ch, 0))
        self.clock_pos = (x, y)

        for layout, lw, oy, alpha in ((big, bw, 0, 0.85), (small, sw, bh, 0.6)):
            snap.save()
            snap.translate(Graphene.Point().init(x + (cw - lw) / 2, y + oy))
            snap.append_layout(layout, rgba(1, 1, 1, alpha))
            snap.restore()


class SaverApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.windows = []
        self.shown_at = 0.0
        self.motion_origin = None
        self.dismissing = False

    def do_activate(self):
        if self.windows:  # already showing; a second launch just lands here
            return
        cfg = config.load()
        self.lock_on_dismiss = cfg["lock_on_dismiss"]
        self.shown_at = time.monotonic()

        css = Gtk.CssProvider()
        css.load_from_string("window.screenie { background: black; }")
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        monitors = Gdk.Display.get_default().get_monitors()
        for i in range(monitors.get_n_items()):
            self._make_window(cfg, monitors.get_item(i))
        if not self.windows:
            self._make_window(cfg, None)

    def _make_window(self, cfg, monitor):
        win = Gtk.ApplicationWindow(application=self, title="Screenie")
        win.add_css_class("screenie")
        win.set_decorated(False)
        win.set_cursor_from_name("none")
        scene = Scene(cfg)
        if hasattr(scene, "hud"):  # the HUD layers live video (NASA ISS stream) above the scene
            overlay = Gtk.Overlay(child=scene)
            scene.hud.overlay = overlay
            win.set_child(overlay)
        else:
            win.set_child(scene)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", lambda *_: self._dismiss() or False)
        win.add_controller(keys)
        click = Gtk.GestureClick(button=0)
        click.connect("pressed", lambda *_: self._dismiss())
        win.add_controller(click)
        scroll = Gtk.EventControllerScroll(flags=Gtk.EventControllerScrollFlags.BOTH_AXES)
        scroll.connect("scroll", lambda *_: self._dismiss() or False)
        win.add_controller(scroll)
        motion = Gtk.EventControllerMotion()
        motion.connect("motion", self._on_motion)
        win.add_controller(motion)

        if monitor is not None:
            win.fullscreen_on_monitor(monitor)
        else:
            win.fullscreen()
        win.present()
        self.windows.append(win)

    def _in_grace(self):
        return time.monotonic() - self.shown_at < GRACE_SECONDS

    def _on_motion(self, _ctrl, x, y):
        if self._in_grace() or self.motion_origin is None:
            self.motion_origin = (x, y)
            return
        ox, oy = self.motion_origin
        if math.hypot(x - ox, y - oy) > MOTION_THRESHOLD:
            self._dismiss()

    def _dismiss(self):
        if self._in_grace() or self.dismissing:
            return
        self.dismissing = True
        if self.lock_on_dismiss:
            try:
                Gio.bus_get_sync(Gio.BusType.SESSION).call_sync(
                    "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver",
                    "Lock", None, None, Gio.DBusCallFlags.NONE, 3000, None)
            except GLib.Error as e:
                print(f"screenie: could not lock screen: {e.message}", file=sys.stderr)
            # Give the lock screen a moment to cover everything before we vanish.
            GLib.timeout_add(600, self.quit)
        else:
            self.quit()


def main():
    return SaverApp().run([sys.argv[0]])
