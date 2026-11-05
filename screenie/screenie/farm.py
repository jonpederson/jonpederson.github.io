"""Farm style: an endless ASCII-art farm seen from a drone flying overhead.

The world is generated procedurally in vertical bands of fields. Each run of
CHUNK columns is rendered once into a cached GSK render node, so a frame only
translates those nodes and draws the few moving things (animals, tractors,
traffic, birds, clouds and the camera HUD) on top.
"""

import bisect
import math
import random
import time

from gi.repository import Gdk, GLib, Graphene, Gsk, Gtk, Pango

CHUNK = 48  # columns per cached render node
ROWS_ON_SCREEN = 64  # sets the font size
SPEED = 3.0  # drone ground speed, columns per second
SWAY_ROWS = 6  # the drone drifts up and down by this much
FONT = "Monospace"

# key: (foreground, background)
PALETTE = {
    "grass": ("#4f9a3a", "#10200d"),
    "flower": ("#e8d84a", "#10200d"),
    "wheat": ("#d9b54a", "#2b230e"),
    "wheat2": ("#b08a36", "#2b230e"),
    "corn": ("#6fc04a", "#18160c"),
    "corn2": ("#4f9a34", "#18160c"),
    "soil": ("#6a4e30", "#1d150c"),
    "plowed": ("#8c6a40", "#1d150c"),
    "cabbage": ("#9ad46c", "#17140b"),
    "sunflower": ("#f2c41e", "#1a1c0c"),
    "sunleaf": ("#5c9a34", "#1a1c0c"),
    "hay": ("#b89a50", "#262010"),
    "bale": ("#f0d27a", "#262010"),
    "tree": ("#3f8f3a", "#0b1a09"),
    "tree2": ("#6cbf4e", "#0b1a09"),
    "water": ("#5a9ae0", "#0c1c33"),
    "water2": ("#9ccaf4", "#0c1c33"),
    "reed": ("#7aa83e", "#10200d"),
    "hedge": ("#2f7a2e", "#0a160a"),
    "hedge2": ("#459a3c", "#0a160a"),
    "fence": ("#a89272", "#10200d"),
    "road": ("#8a7456", "#2c2216"),
    "verge": ("#6a8a3a", "#18200f"),
    "yard": ("#8a8478", "#1e1c18"),
    "barn": ("#d0503e", "#3a1210"),
    "barnedge": ("#ece4d4", "#3a1210"),
    "roof": ("#a8a8b4", "#26262e"),
    "roofedge": ("#e8e8f0", "#26262e"),
    "silo": ("#c8ccd4", "#2a2c30"),
}

FIELD_KINDS = [
    ("pasture", 4), ("wheat", 3), ("corn", 3), ("plowed", 2), ("hay", 2),
    ("orchard", 2), ("cabbage", 1), ("sunflower", 1), ("pond", 1), ("farmstead", 1),
]

TREE = [" ,@@@, ", "@@@%@@@", " '@@@' ", "       "]
BARN = [".------------.", "|\\\\\\\\\\\\\\\\\\\\\\\\|", "|============|",
        "|////////////|", "'------------'"]
HOUSE = [".--------.", "|##n#####|", "|########|", "'--------'"]
SILO = [" .--. ", "( () )", " '--' "]

# Sprites: list of (text, color) runs, facing right; mirrored for left.
SPRITES = {
    "cow": [("~(", "#f0ece0"), ("##", "#8a5a34"), (")>", "#f0ece0")],
    "sheep": [("{@@}", "#f6f6f2"), (">", "#b0b0b0")],
    "chicken": [("o", "#ffffff"), (">", "#f0a030")],
    "tractor": [("=", "#9a9a9a"), ("[##]", "#3fae4a"), (">", "#ffe066")],
    "truck": [("[==]", "#e0483a"), (">", "#ffe066")],
}
MIRROR = str.maketrans("<>()[]{}/\\", "><)(][}{\\/")


def h2(x, y, s):
    n = (x * 374761393 + y * 668265263 + s * 2246822519) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return n ^ (n >> 16)


def rgba(hexstr, alpha=1.0):
    c = Gdk.RGBA()
    c.parse(hexstr)
    c.alpha = alpha
    return c


def rrect(bounds, radius):
    # Build in place: chaining Gsk.RoundedRect().init_from_rect() returns a dangling struct in PyGObject.
    rr = Gsk.RoundedRect()
    rr.init_from_rect(bounds, radius)
    return rr

def rect(x, y, w, h):
    return Graphene.Rect().init(x, y, w, h)


class Field:
    def __init__(self, x0, y0, w, h, kind, rnd):
        self.x0, self.y0, self.w, self.h = x0, y0, w, h  # interior, world cells
        self.seed = rnd.getrandbits(30)
        self.vert = rnd.random() < 0.5
        self.objs = []
        if kind == "farmstead" and not self._layout_farm(rnd):
            kind = "pasture"
        if kind == "pond":
            self.cx, self.cy = w / 2 - 0.5, h / 2 - 0.5
            self.rx, self.ry = max(w * 0.38, 2), max(h * 0.36, 1.5)
        self.kind = kind
        self.bg = PALETTE[self.base_key()][1]

    def base_key(self):
        return {"pasture": "grass", "orchard": "tree", "pond": "grass", "farmstead": "grass",
                "corn": "corn", "cabbage": "cabbage", "sunflower": "sunflower"}.get(self.kind, self.kind)

    def _layout_farm(self, rnd):
        if self.w < 20 or self.h < 7:
            return False
        placed = []

        def fits(x, y, sprite):
            sw, sh = len(sprite[0]), len(sprite)
            if x < 1 or y < 1 or x + sw > self.w - 1 or y + sh > self.h - 1:
                return False
            return all(x + sw + 1 <= px or px + pw + 1 <= x or y + sh + 1 <= py or py + ph + 1 <= y
                       for px, py, pw, ph in placed)

        def place(sprite, edge, inner, spots):
            for x, y in spots:
                if fits(x, y, sprite):
                    self.objs.append((x, y, sprite, edge, inner))
                    placed.append((x, y, len(sprite[0]), len(sprite)))
                    return True
            return False

        bx, by = 2, 1 + rnd.randint(0, max(0, self.h - 8))
        if not place(BARN, "barnedge", "barn", [(bx, by)]):
            return False
        place(HOUSE, "roofedge", "roof", [(bx + 17, by), (bx + 17, by + 1), (bx, by + 7)])
        place(SILO, "silo", "silo", [(bx + 15, by + 3), (bx + 2, by + 6), (bx + 29, by)])
        x0 = min(o[0] for o in placed) - 1
        y0 = min(o[1] for o in placed) - 1
        x1 = max(o[0] + o[2] for o in placed) + 1
        y1 = max(o[1] + o[3] for o in placed) + 1
        self.yard = (max(x0, 0), max(y0, 0), min(x1, self.w), min(y1, self.h))
        return True

    def cell(self, lx, ly):
        k, hs = self.kind, h2(lx + self.x0, ly + self.y0, self.seed)
        a, b = (lx, ly) if self.vert else (ly, lx)  # a = row index, b = position along row
        if k == "wheat":
            return (";" if a % 2 == 0 else ":"), ("wheat" if hs % 5 else "wheat2")
        if k == "corn":
            if a % 2 == 0:
                return ("Y" if hs % 3 else "y"), ("corn" if hs % 4 else "corn2")
            return ("." if hs % 6 == 0 else " "), "soil"
        if k == "plowed":
            if self.vert:
                return ("|" if a % 2 == 0 else ":"), ("plowed" if a % 2 == 0 else "soil")
            return ("=" if a % 2 == 0 else "-"), ("plowed" if a % 2 == 0 else "soil")
        if k == "cabbage":
            if a % 2 == 0 and b % 2 == 0:
                return ("o" if hs % 5 else "@"), "cabbage"
            return ("." if hs % 5 == 0 else " "), "soil"
        if k == "sunflower":
            if a % 2 == 0:
                return ("*" if hs % 4 else "o"), "sunflower"
            return ("," if hs % 3 == 0 else "."), "sunleaf"
        if k == "hay":
            if 1 <= lx < self.w - 2 and 1 <= ly < self.h - 1 and hs % 47 == 0:
                return "O", "bale"
            return ",'`."[hs % 4] if hs % 3 else " ", "hay"
        if k == "orchard":
            shift = 3 if (ly // 4) % 2 else 0
            ch = TREE[ly % 4][(lx + shift) % 7]
            if ch != " ":
                return ch, ("tree2" if ch == "%" else "tree")
            return self._grass(hs)
        if k == "pond":
            d = ((lx - self.cx) / self.rx) ** 2 + ((ly - self.cy) / self.ry) ** 2
            if d < 0.8:
                return ("~" if (lx + ly * 3) % 5 else "-"), ("water" if hs % 6 else "water2")
            if d < 1.0:
                return ("~" if hs % 3 else " "), "water"
            if d < 1.35:
                return ("\"" if hs % 2 else "'"), "reed"
            return self._grass(hs)
        if k == "farmstead":
            for ox, oy, sprite, edge, inner in self.objs:
                if ox <= lx < ox + len(sprite[0]) and oy <= ly < oy + len(sprite):
                    ch = sprite[ly - oy][lx - ox]
                    if ch != " ":
                        return ch, (edge if ch in ".-|'()" else inner)
            x0, y0, x1, y1 = self.yard
            if x0 <= lx < x1 and y0 <= ly < y1:
                return ("." if hs % 4 == 0 else " "), "yard"
        return self._grass(hs)

    @staticmethod
    def _grass(hs):
        if hs % 97 == 0:
            return "*", "flower"
        return (".,'\""[hs % 4] if hs % 6 == 0 else " "), "grass"


class Band:
    def __init__(self, x0, w, sep):
        self.x0, self.w, self.sep = x0, w, sep
        self.sepw = {"hedge": 2, "fence": 1, "lane": 2}[sep]
        self.fields = []  # (field, border_row or None)


class World:
    def __init__(self, rows, rnd):
        self.rows = rows
        self.rnd = rnd
        self.road = int(rows * 0.58)  # 4 rows: verge, lane, lane, verge
        self.bands, self.band_x = [], []
        self.next_x = 0
        self.actors = []

    def _new_band(self):
        r = self.rnd
        band = Band(self.next_x, r.randint(24, 56), r.choice(["hedge", "hedge", "fence", "fence", "lane"]))
        kinds, weights = zip(*FIELD_KINDS)
        has_farm = False
        for top, bottom in ((0, self.road), (self.road + 4, self.rows)):
            y = top
            while y < bottom:
                h = r.randint(8, 18)
                if bottom - (y + h) < 6:
                    h = bottom - y
                last = y + h >= bottom
                kind = r.choices(kinds, weights)[0]
                if kind == "farmstead" and has_farm:
                    kind = "pasture"
                f = Field(band.x0, y, band.w - band.sepw, h - (0 if last else 1), kind, r)
                has_farm |= f.kind == "farmstead"
                band.fields.append((f, None if last else y + h - 1))
                self._spawn(f)
                y += h
        self.bands.append(band)
        self.band_x.append(band.x0)
        self.next_x += band.w

    def _spawn(self, f):
        r = self.rnd
        if f.kind == "pasture":
            kind = r.choice(["cow", "cow", "sheep"])
            for _ in range(max(1, f.w * f.h // 150)):
                self.actors.append(Animal(kind, f, r))
        elif f.kind == "farmstead":
            x0, _, x1, y1 = f.yard  # the yard's bottom strip is clear of buildings
            for _ in range(r.randint(2, 4)):
                self.actors.append(Animal("chicken", f, r, area=(x0, y1 - 1, x1, y1)))
        elif f.kind in ("wheat", "hay", "plowed") and r.random() < 0.3 and f.w > 12 and f.h > 2:
            self.actors.append(Tractor(f, r))

    def band_at(self, x):
        while self.next_x <= x:
            self._new_band()
        return self.bands[bisect.bisect_right(self.band_x, x) - 1]

    def cell(self, x, y):
        if self.road <= y < self.road + 4:
            hs = h2(x, y, 7)
            if y in (self.road, self.road + 3):
                return (",'\"."[hs % 4] if hs % 3 == 0 else " "), "verge"
            return (":" if hs % 9 == 0 else "." if hs % 4 == 0 else " "), "road"
        band = self.band_at(x)
        lx = x - band.x0
        hs = h2(x, y, 3)
        if lx >= band.w - band.sepw:
            return self._sep(band.sep, hs, vertical=True, along=y)
        for f, border in band.fields:
            if border == y:
                return self._sep(band.sep, hs, vertical=False, along=x)
            if f.y0 <= y < f.y0 + f.h:
                return f.cell(lx, y - f.y0)
        return " ", "grass"

    @staticmethod
    def _sep(kind, hs, vertical, along):
        if kind == "hedge":
            return "%&%@"[hs % 4], ("hedge" if hs % 3 else "hedge2")
        if kind == "fence":
            if vertical:
                return ("+" if along % 4 == 0 else "|"), "fence"
            return ("+" if along % 6 == 0 else "-"), "fence"
        return (":" if hs % 5 == 0 else "." if hs % 2 else " "), "road"

    def bg_for(self, x, y):
        return PALETTE[self.cell(x, y)[1]][1]


class Animal:
    def __init__(self, kind, field, rnd, area=None):
        self.kind = kind
        self.width = len("".join(t for t, _ in SPRITES[kind]))
        x0, y0, x1, y1 = area or (0, 0, field.w, field.h)
        self.bounds = (field.x0 + x0, field.y0 + y0, field.x0 + x1 - self.width, field.y0 + y1 - 1)
        bx0, by0, bx1, by1 = self.bounds
        self.x = rnd.randint(bx0, max(bx0, bx1))
        self.y = rnd.randint(by0, max(by0, by1))
        self.dir = rnd.choice((-1, 1))
        self.next_t = rnd.uniform(0, 3)
        self.bg = field.bg if area is None else PALETTE["yard"][1]
        self.rnd = rnd

    def update(self, t, dt):
        if t < self.next_t:
            return
        r = self.rnd
        quick = self.kind == "chicken"
        self.next_t = t + (r.uniform(0.2, 1.2) if quick else r.uniform(1.0, 4.0))
        if r.random() < 0.25:
            self.dir = -self.dir
            return
        bx0, by0, bx1, by1 = self.bounds
        self.x = min(max(self.x + self.dir, bx0), max(bx0, bx1))
        if r.random() < 0.3:
            self.y = min(max(self.y + r.choice((-1, 1)), by0), max(by0, by1))


class Tractor:
    kind = "tractor"

    def __init__(self, field, rnd):
        self.width = 6
        self.x0, self.x1 = field.x0 + 1, field.x0 + field.w - self.width - 1
        self.y = field.y0 + rnd.randint(0, field.h - 1)
        self.fx = rnd.uniform(self.x0, self.x1)
        self.dir = rnd.choice((-1, 1))
        self.speed = rnd.uniform(1.0, 1.8)
        self.bg = field.bg

    @property
    def x(self):
        return int(self.fx)

    def update(self, t, dt):
        self.fx += self.dir * self.speed * dt
        if self.fx > self.x1 or self.fx < self.x0:
            self.dir = -self.dir
            self.fx = min(max(self.fx, self.x0), self.x1)


class Truck:
    kind = "truck"

    def __init__(self, x, y, d, speed):
        self.width = 5
        self.fx, self.y, self.dir, self.speed = x, y, d, speed
        self.bg = PALETTE["road"][1]

    @property
    def x(self):
        return int(self.fx)

    def update(self, t, dt):
        self.fx += self.dir * self.speed * dt


class Farm:
    def __init__(self, widget, show_clock, time_fmt):
        self.widget = widget
        self.show_clock = show_clock
        self.time_fmt = time_fmt.replace("%M", "%M:%S")
        self.rnd = random.Random()
        self.size = None
        self.last_t = 0.0
        self.sprite_cache = {}

    def _setup(self, w, h):
        self.size = (w, h)
        px = h / ROWS_ON_SCREEN
        self.font = Pango.FontDescription.from_string(FONT)
        self.font.set_absolute_size(px * Pango.SCALE)
        probe = self._plain("M" * CHUNK + "\nM\nM\nM")
        lw, lh = probe.get_size()
        self.cell_w = lw / Pango.SCALE / CHUNK
        self.cell_h = lh / Pango.SCALE / 4
        self.chunk_w = lw / Pango.SCALE
        self.screen_cols = int(w / self.cell_w) + 2
        self.world = World(int(h / self.cell_h) + SWAY_ROWS + 2, self.rnd)
        self.chunks = {}
        self.trucks = []
        self.next_truck = self.rnd.uniform(2, 10)
        self.birds = None
        self.next_birds = self.rnd.uniform(8, 25)
        self.shadows = [[self.rnd.uniform(0, w * 2), self.rnd.uniform(0, h), self.rnd.uniform(0.5, 0.9) * h]
                        for _ in range(3)]
        self.clouds = [[w + self.rnd.uniform(0, w * 3), self.rnd.uniform(0, h), self.rnd.uniform(0.6, 1.1) * h]
                       for _ in range(2)]
        from .saver import orb_texture  # shared soft-blob texture
        self.shadow_tex = orb_texture(0, 0, 0)
        self.cloud_tex = orb_texture(1, 1, 1)

    def _plain(self, text):
        layout = self.widget.create_pango_layout(text)
        layout.set_font_description(self.font)
        return layout

    def _markup(self, markup):
        layout = self.widget.create_pango_layout(None)
        layout.set_font_description(self.font)
        layout.set_markup(markup, -1)
        return layout

    # --- cached ground

    def _chunk(self, ci):
        node = self.chunks.get(ci)
        if node is not None:
            return node
        world, cw, ch = self.world, self.cell_w, self.cell_h
        snap = Gtk.Snapshot()
        lines = []
        for y in range(world.rows):
            parts, run_fg, run = [], None, []
            bg_start, bg_cur = 0, None
            for i in range(CHUNK):
                c, key = world.cell(ci * CHUNK + i, y)
                fg, bg = PALETTE[key]
                if bg != bg_cur:
                    if bg_cur is not None:
                        snap.append_color(rgba(bg_cur), rect(bg_start * cw, y * ch, (i - bg_start) * cw + 0.6, ch + 0.6))
                    bg_cur, bg_start = bg, i
                if c != " " and fg != run_fg:
                    if run:
                        parts.append(self._span(run_fg, run))
                    run_fg, run = fg, []
                run.append(c)
            snap.append_color(rgba(bg_cur), rect(bg_start * cw, y * ch, (CHUNK - bg_start) * cw + 0.6, ch + 0.6))
            parts.append(self._span(run_fg, run))
            lines.append("".join(parts))
        snap.append_layout(self._markup("\n".join(lines)), rgba("#ffffff"))
        node = snap.to_node()
        self.chunks[ci] = node
        return node

    @staticmethod
    def _span(fg, chars):
        text = GLib.markup_escape_text("".join(chars))
        return f'<span foreground="{fg}">{text}</span>' if fg else text

    def _sprite(self, kind, d):
        key = (kind, d)
        if key not in self.sprite_cache:
            runs = SPRITES[kind]
            if d < 0:
                runs = [(t[::-1].translate(MIRROR), c) for t, c in reversed(runs)]
            self.sprite_cache[key] = self._markup("".join(self._span(c, t) for t, c in runs))
        return self.sprite_cache[key]

    # --- frame

    def draw(self, snap, w, h, t):
        if self.size != (w, h):
            self._setup(w, h)
        dt = min(max(t - self.last_t, 0.0), 0.1)
        self.last_t = t
        cw, ch = self.cell_w, self.cell_h
        scroll = t * SPEED * cw
        sway = (SWAY_ROWS * ch) * 0.5 * (1 - math.cos(t * 0.045))
        col0 = scroll / cw

        first, last = int(scroll // self.chunk_w), int((scroll + w) // self.chunk_w)
        for ci in range(first, last + 1):
            node = self._chunk(ci)
            snap.save()
            snap.translate(Graphene.Point().init(ci * self.chunk_w - scroll, -sway))
            snap.append_node(node)
            snap.restore()
        self._chunk(last + 1)  # build ahead (cached)
        for ci in [c for c in self.chunks if c < first - 1]:
            del self.chunks[ci]

        # moving things on the ground
        self._traffic(t, col0)
        world = self.world
        world.actors = [a for a in world.actors if a.x + a.width >= col0 - 20]
        for a in world.actors + self.trucks:
            a.update(t, dt)
            if a.x + a.width < col0 - 1 or a.x > col0 + self.screen_cols:
                continue
            x, y = a.x * cw - scroll, a.y * ch - sway
            snap.append_color(rgba(a.bg), rect(x, y, a.width * cw, ch))
            if isinstance(a, Tractor):
                tx = x - 3 * cw if a.dir > 0 else x + a.width * cw
                trail = ". :" if a.dir > 0 else ": ."
                self._text(snap, trail, PALETTE["plowed"][0], tx, y, 0.7)
            snap.save()
            snap.translate(Graphene.Point().init(x, y))
            snap.append_layout(self._sprite(a.kind, a.dir), rgba("#ffffff"))
            snap.restore()

        self._sky(snap, w, h, t, dt, scroll)
        self._hud(snap, w, h, t, sway)

    def _traffic(self, t, col0):
        if t >= self.next_truck:
            self.next_truck = t + self.rnd.uniform(12, 40)
            road = self.world.road
            if self.rnd.random() < 0.5:  # oncoming
                self.trucks.append(Truck(col0 + self.screen_cols + 2, road + 1, -1, self.rnd.uniform(3, 6)))
            else:  # overtaking the drone
                self.trucks.append(Truck(col0 - 6, road + 2, 1, SPEED + self.rnd.uniform(3, 6)))
        self.trucks = [k for k in self.trucks if col0 - 10 < k.fx < col0 + self.screen_cols + 10]

    def _text(self, snap, text, color, x, y, alpha=1.0):
        snap.save()
        snap.translate(Graphene.Point().init(x, y))
        snap.append_layout(self._plain(text), rgba(color, alpha))
        snap.restore()

    def _sky(self, snap, w, h, t, dt, scroll):
        r = self.rnd
        # Cloud shadows sit on the ground and drift slowly with the wind.
        for s in self.shadows:
            s[0] += 14 * dt
            x = s[0] - scroll
            if x + s[2] < 0:
                s[0], s[1], s[2] = scroll + w + r.uniform(0, w), r.uniform(-0.2, 1.0) * h, r.uniform(0.5, 0.9) * h
            snap.push_opacity(0.55)
            snap.append_texture(self.shadow_tex, rect(x, s[1], s[2] * 1.6, s[2]))
            snap.pop()

        # Birds below the drone cross faster than the ground.
        if self.birds is None and t >= self.next_birds:
            d = r.choice((-1, 1))
            self.birds = dict(x=-200 if d > 0 else w + 200, y=r.uniform(0.1, 0.8) * h, d=d,
                              v=r.uniform(90, 160), vy=r.uniform(-15, 15),
                              flock=[(r.uniform(-120, 120), r.uniform(-60, 60), r.uniform(0, 6)) for _ in range(r.randint(3, 9))])
        if self.birds:
            b = self.birds
            b["x"] += b["d"] * b["v"] * dt - SPEED * self.cell_w * dt * 0.4
            b["y"] += b["vy"] * dt
            for ox, oy, ph in b["flock"]:
                self._text(snap, "v" if math.sin(t * 7 + ph) > 0 else "^", "#f0f0f0", b["x"] + ox, b["y"] + oy, 0.9)
            if b["x"] < -400 or b["x"] > w + 400:
                self.birds = None
                self.next_birds = t + r.uniform(20, 60)

        # Wisps of cloud between the drone and the ground race past.
        for c in self.clouds:
            c[0] -= SPEED * self.cell_w * 2.4 * dt
            if c[0] + c[2] * 2 < 0:
                c[0], c[1], c[2] = w + r.uniform(w, w * 4), r.uniform(-0.2, 1.0) * h, r.uniform(0.6, 1.1) * h
            snap.push_opacity(0.22)
            snap.append_texture(self.cloud_tex, rect(c[0], c[1], c[2] * 2, c[2]))
            snap.pop()

    def _hud(self, snap, w, h, t, sway):
        # Everything drifts a few pixels over time so the HUD never burns in.
        jx, jy = 8 * math.sin(t * 0.011), 8 * math.cos(t * 0.017)
        m = h * 0.045
        white = rgba("#ffffff", 0.55)
        arm, th = h * 0.05, max(2.0, h / 600)
        for cx, cy, sx, sy in ((m, m, 1, 1), (w - m, m, -1, 1), (m, h - m, 1, -1), (w - m, h - m, -1, -1)):
            x, y = cx + jx, cy + jy
            snap.append_color(white, rect(min(x, x + sx * arm), y - (th if sy < 0 else 0), arm, th))
            snap.append_color(white, rect(x - (th if sx < 0 else 0), min(y, y + sy * arm), th, arm))
        cx, cy, c = w / 2 + jx, h / 2 + jy, h * 0.018
        faint = rgba("#ffffff", 0.3)
        snap.append_color(faint, rect(cx - c, cy - th / 2, c * 0.6, th))
        snap.append_color(faint, rect(cx + c * 0.4, cy - th / 2, c * 0.6, th))
        snap.append_color(faint, rect(cx - th / 2, cy - c, th, c * 0.6))
        snap.append_color(faint, rect(cx - th / 2, cy + c * 0.4, th, c * 0.6))

        tx, ty = m + arm * 0.4 + jx, m + arm * 0.3 + jy
        if int(t * 1.2) % 2 == 0:  # blinking record light
            d = self.cell_h * 0.5
            snap.push_rounded_clip(rrect(rect(tx, ty + d / 2, d, d), d / 2))
            snap.append_color(rgba("#ff4040", 0.9), rect(tx, ty + d / 2, d, d))
            snap.pop()
        el = int(t)
        self._text(snap, f"  REC  {el // 3600:02d}:{el // 60 % 60:02d}:{el % 60:02d}", "#ffffff", tx, ty, 0.7)
        if self.show_clock:
            stamp = time.strftime(self.time_fmt)
            sw = self._plain(stamp).get_pixel_size()[0]
            self._text(snap, stamp, "#ffffff", w - m - arm * 0.4 - sw + jx, ty, 0.7)
        alt = 120 + sway / self.cell_h * 1.5
        by = h - m - arm * 0.3 - self.cell_h + jy
        self._text(snap, f"ALT {alt:5.1f}m   SPD 8.4m/s   HDG 090°", "#ffffff", tx, by, 0.7)
        lon = 71.0589 - t * 0.00008
        gps = f"N 42.3601°  W {lon:08.4f}°"
        gw = self._plain(gps).get_pixel_size()[0]
        self._text(snap, gps, "#ffffff", w - m - arm * 0.4 - gw + jx, by, 0.7)
