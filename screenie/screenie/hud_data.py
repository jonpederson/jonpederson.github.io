"""Background fetching of live data for the HUD style.

One worker thread per process polls each source on its own interval and keeps
results in memory plus a small disk cache, so a fresh screensaver launch shows
data immediately. Drawing code only ever reads `Hub.get()`; it never blocks.
"""

import json
import math
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import astro

CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "screenie" / "hud.json"
UA = "screenie-screensaver/1.0"
RETRY_SECONDS = 90

STATE_FIPS = {
    "01": "AL", "02": "AK", "04": "AZ", "05": "AR", "06": "CA", "08": "CO", "09": "CT", "10": "DE",
    "11": "DC", "12": "FL", "13": "GA", "15": "HI", "16": "ID", "17": "IL", "18": "IN", "19": "IA",
    "20": "KS", "21": "KY", "22": "LA", "23": "ME", "24": "MD", "25": "MA", "26": "MI", "27": "MN",
    "28": "MS", "29": "MO", "30": "MT", "31": "NE", "32": "NV", "33": "NH", "34": "NJ", "35": "NM",
    "36": "NY", "37": "NC", "38": "ND", "39": "OH", "40": "OK", "41": "OR", "42": "PA", "44": "RI",
    "45": "SC", "46": "SD", "47": "TN", "48": "TX", "49": "UT", "50": "VT", "51": "VA", "53": "WA",
    "54": "WV", "55": "WI", "56": "WY", "72": "PR",
}


def fetch_json(url, params=None, timeout=15, headers=None):
    if params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def parse_coords(text):
    try:
        lat, lon = (float(p) for p in text.replace(";", ",").split(","))
    except ValueError:
        return None
    if -90 <= lat <= 90 and -180 <= lon <= 180:
        return lat, lon
    return None


# --- sources ---------------------------------------------------------------

def src_location(hub):
    manual = parse_coords(hub.cfg.get("hud_location", "") or "")
    if manual:
        return dict(lat=manual[0], lon=manual[1], source="manual", city="", region="", country="")
    d = fetch_json("https://ipwho.is/")
    if not d.get("success"):
        raise RuntimeError(d.get("message", "IP lookup failed"))
    return dict(lat=d["latitude"], lon=d["longitude"], source="IP estimate", city=d.get("city", ""),
                region=d.get("region", ""), country=d.get("country_code", ""))


def src_weather(hub):
    loc = hub.get("location")
    imperial = hub.imperial()
    return fetch_json("https://api.open-meteo.com/v1/forecast", {
        "latitude": loc["lat"], "longitude": loc["lon"], "timezone": "auto",
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,weather_code,"
                   "cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,"
                   "precipitation,uv_index,visibility,is_day",
        "hourly": "temperature_2m,precipitation_probability,weather_code",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
                 "sunrise,sunset,uv_index_max,wind_speed_10m_max",
        "forecast_hours": 13, "forecast_days": 6,
        "temperature_unit": "fahrenheit" if imperial else "celsius",
        "wind_speed_unit": "mph" if imperial else "kmh",
        "precipitation_unit": "inch" if imperial else "mm",
    })


def src_air(hub):
    loc = hub.get("location")
    return fetch_json("https://air-quality-api.open-meteo.com/v1/air-quality", {
        "latitude": loc["lat"], "longitude": loc["lon"],
        "current": "us_aqi,pm2_5,pm10,ozone,european_aqi",
    })["current"]


def src_quakes(hub):
    d = fetch_json("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson", timeout=25)
    out = []
    for f in d["features"]:
        p, (lon, lat, depth) = f["properties"], f["geometry"]["coordinates"]
        if p.get("mag") is None:
            continue
        out.append(dict(t=p["time"] / 1000, mag=p["mag"], place=p.get("place") or "", lat=lat, lon=lon,
                        depth=depth, tsunami=p.get("tsunami", 0)))
    out.sort(key=lambda q: q["t"])
    return out


def src_neo(hub):
    now = datetime.now(timezone.utc)
    params = {
        "date-min": (now - timedelta(days=7)).strftime("%Y-%m-%d"),
        "date-max": (now + timedelta(days=30)).strftime("%Y-%m-%d"),
        "dist-max": "0.2", "fullname": "true",
    }
    try:
        d = fetch_json("https://ssd-api.jpl.nasa.gov/cad.api", params)
    except urllib.error.HTTPError:  # the API sometimes 502s on full names; designations still work
        del params["fullname"]
        d = fetch_json("https://ssd-api.jpl.nasa.gov/cad.api", params)
    fields = d.get("fields", [])
    rows = [dict(zip(fields, r)) for r in d.get("data", [])]
    for r in rows:
        r["jd"], r["dist"], r["v_rel"] = float(r["jd"]), float(r["dist"]), float(r["v_rel"])
        r["h"] = float(r["h"]) if r.get("h") else None
        r["name"] = (r.get("fullname") or r["des"]).strip()
    return rows


def src_iss(hub):
    d = fetch_json("https://api.wheretheiss.at/v1/satellites/25544", timeout=8)
    prev = hub.get("iss")
    if prev and prev.get("timestamp") != d.get("timestamp"):
        d["prev"] = (prev["latitude"], prev["longitude"], prev["timestamp"])
    elif prev:
        d["prev"] = prev.get("prev")
    return d


def iss_motion(iss):
    """Ground-track velocity (deg/s lat, deg/s lon) from the last two fixes, or None."""
    if not iss or not iss.get("prev"):
        return None
    plat, plon, pts = iss["prev"]
    dt = iss["timestamp"] - pts
    if dt <= 0 or dt > 120:
        return None
    dlon = (iss["longitude"] - plon + 540) % 360 - 180
    return (iss["latitude"] - plat) / dt, dlon / dt


def iss_position(iss, now):
    """Dead-reckoned ISS sub-point (lat, lon) at `now`."""
    v = iss_motion(iss)
    lat, lon = iss["latitude"], iss["longitude"]
    if v:
        dt = now - iss["timestamp"]
        lat += v[0] * dt
        lon = (lon + v[1] * dt + 540) % 360 - 180
    return lat, lon


ISS_VIEW_DEG = 3.2  # half-height of each imagery tile, degrees of latitude
GIBS = "https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi"


def src_isscam(hub):
    """NASA GIBS imagery under where the ISS is about to be (fallback for the live camera)."""
    iss = hub.get("iss")
    if not iss or not iss_motion(iss):
        return None  # still waiting for two position fixes
    lat, lon = iss_position(iss, time.time() + 8)
    lat = max(-80.0, min(80.0, lat))
    dlat = ISS_VIEW_DEG
    dlon = ISS_VIEW_DEG / max(0.2, math.cos(math.radians(lat)))
    bbox = (lon - dlon, lat - dlat, lon + dlon, lat + dlat)
    s = astro.sun(time.time())
    sun_alt, _ = astro.alt_az(s["ra"], s["dec"], lat, lon, time.time())
    night = sun_alt < -4
    params = {"SERVICE": "WMS", "REQUEST": "GetMap", "VERSION": "1.3.0", "STYLES": "", "CRS": "EPSG:4326",
              "BBOX": f"{bbox[1]:.4f},{bbox[0]:.4f},{bbox[3]:.4f},{bbox[2]:.4f}",  # 1.3.0: lat,lon order
              "WIDTH": 1024, "HEIGHT": 1024, "FORMAT": "image/jpeg"}
    if night:
        layer, data = "VIIRS Black Marble (city lights)", fetch_bytes(GIBS, dict(params, LAYERS="VIIRS_Black_Marble"))
    else:
        data, layer = b"", ""
        for days in (1, 2, 3):  # the newest daily mosaic may still be processing
            day = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
            data = fetch_bytes(GIBS, dict(params, LAYERS="MODIS_Terra_CorrectedReflectance_TrueColor", TIME=day))
            layer = f"MODIS Terra true color {day}"
            if len(data) > 20000:
                break
    return dict(jpg=data, bbox=bbox, layer=layer, night=night, t=time.time())


def src_iss_stream(hub):
    """Current YouTube ID of NASA's official 'Live High-Definition Views from the ISS' stream."""
    req = urllib.request.Request("https://www.youtube.com/@NASA/streams",
                                 headers={"User-Agent": "Mozilla/5.0", "Accept-Language": "en-US"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        html = resp.read().decode("utf-8", "replace")
    ids = list(dict.fromkeys(re.findall(r'"videoId":"([A-Za-z0-9_-]{11})"', html)))[:12]
    for vid in ids:
        try:
            title = fetch_json("https://www.youtube.com/oembed",
                               {"url": f"https://www.youtube.com/watch?v={vid}", "format": "json"})["title"]
        except Exception:  # noqa: BLE001 - unembeddable or private
            continue
        if "International Space Station" in title and "Live" in title:
            return dict(id=vid, title=title)
    raise RuntimeError("NASA ISS stream not found")


def src_history(hub):
    """Last 3 hours of wind (15-minute) and last 24 hours of precipitation (hourly), Open-Meteo."""
    loc = hub.get("location")
    imperial = hub.imperial()
    d = fetch_json("https://api.open-meteo.com/v1/forecast", {
        "latitude": loc["lat"], "longitude": loc["lon"], "timezone": "auto",
        "minutely_15": "wind_speed_10m,wind_gusts_10m,wind_direction_10m",
        "past_minutely_15": 12, "forecast_minutely_15": 1,
        "hourly": "precipitation", "past_hours": 24, "forecast_hours": 1,
        "wind_speed_unit": "mph" if imperial else "kmh",
        "precipitation_unit": "inch" if imperial else "mm",
    })
    m, hr = d["minutely_15"], d["hourly"]
    return dict(wind_t=m["time"], wind=m["wind_speed_10m"], gust=m["wind_gusts_10m"], wdir=m["wind_direction_10m"],
                rain_t=hr["time"][:-1], rain=hr["precipitation"][:-1])


def src_space(hub):
    base = "https://services.swpc.noaa.gov/products/"
    kp = fetch_json(base + "noaa-planetary-k-index.json")
    out = {"kp": float(kp[-1]["Kp"]), "kp_time": kp[-1]["time_tag"]}
    for name, key, path in (("wind", "proton_speed", "summary/solar-wind-speed.json"),
                            ("bz", "bz_gsm", "summary/solar-wind-mag-field.json"),
                            ("bt", "bt", "summary/solar-wind-mag-field.json"),
                            ("flux", "flux", "summary/10cm-flux.json")):
        try:
            v = fetch_json(base + path)
            out[name] = float((v[0] if isinstance(v, list) else v)[key])
        except Exception:  # noqa: BLE001 - partial space weather is still useful
            out[name] = None
    return out


def src_outages(hub):
    base = "https://ornl.opendatasoft.com/api/explore/v2.1/catalog/datasets/odin-real-time-outages-county"
    rows = fetch_json(base + "/exports/json", {"select": "communitydescriptor,metersaffected"}, timeout=25)
    states = Counter()
    for r in rows:
        states[STATE_FIPS.get((r.get("communitydescriptor") or "")[:2], "??")] += r.get("metersaffected") or 0
    return dict(total=sum(states.values()), incidents=len(rows), states=states.most_common(5))


RADAR_MILES = 200


def radar_bbox(lat, lon, miles=RADAR_MILES):
    """A box `miles` from the center each way (lon_min, lat_min, lon_max, lat_max), equirectangular."""
    dlat = miles / 69.0
    dlon = miles / (69.17 * math.cos(math.radians(lat)))
    return lon - dlon, lat - dlat, lon + dlon, lat + dlat


def fetch_bytes(url, params=None, timeout=20, headers=None):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def src_cameras(hub):
    """WisDOT 511 traffic cameras nearest to you (stills plus live HLS video)."""
    loc = hub.get("location")
    rows = []
    for start in range(0, 2000, 100):
        query = json.dumps({"columns": [{"data": None, "name": ""}, {"name": "sortOrder", "s": True}],
                            "order": [{"column": 1, "dir": "asc"}], "start": start, "length": 100,
                            "search": {"value": ""}})
        d = fetch_json("https://511wi.gov/List/GetData/Cameras", {"query": query, "lang": "en-US"})
        rows += d.get("data", [])
        if start + 100 >= d.get("recordsTotal", 0):
            break
    cams = []
    for r in rows:
        m = re.match(r"POINT \(([-\d.]+) ([-\d.]+)\)", ((r.get("latLng") or {}).get("geography") or {})
                     .get("wellKnownText", ""))
        imgs = [i for i in r.get("images") or [] if not i.get("disabled") and not i.get("blocked")]
        if not m or not imgs:
            continue
        lon, lat = float(m[1]), float(m[2])
        km = astro.haversine_km(loc["lat"], loc["lon"], lat, lon)
        if km > RADAR_MILES * 1.609:
            continue
        img = imgs[0]
        video = img.get("videoUrl") if not img.get("videoDisabled") and not img.get("isVideoAuthRequired") else None
        cams.append(dict(name=r.get("location") or r.get("roadway") or "Camera", lat=lat, lon=lon, km=km,
                         image="https://511wi.gov" + img["imageUrl"], video=video))
    cams.sort(key=lambda c: c["km"])
    return cams[:16]


def src_radar(hub):
    """NEXRAD base reflectivity composite (NOAA via Iowa Environmental Mesonet) for the scope."""
    loc = hub.get("location")
    bbox = radar_bbox(loc["lat"], loc["lon"])
    png = fetch_bytes("https://mesonet.agron.iastate.edu/cgi-bin/wms/nexrad/n0q.cgi", {
        "SERVICE": "WMS", "REQUEST": "GetMap", "VERSION": "1.1.1", "LAYERS": "nexrad-n0q-900913",
        "STYLES": "", "SRS": "EPSG:4326", "BBOX": ",".join(f"{v:.4f}" for v in bbox),
        "WIDTH": 1024, "HEIGHT": 1024, "FORMAT": "image/png", "TRANSPARENT": "true",
    })
    return dict(png=png, bbox=bbox, t=time.time())


def _topo_arcs(topo, bbox):
    sx, sy = topo["transform"]["scale"]
    tx, ty = topo["transform"]["translate"]
    x0, y0, x1, y1 = bbox
    out = []
    for arc in topo["arcs"]:
        x = y = 0
        pts = []
        for dx, dy in arc:
            x += dx
            y += dy
            pts.append((round(x * sx + tx, 4), round(y * sy + ty, 4)))
        if any(x0 <= px <= x1 and y0 <= py <= y1 for px, py in pts):
            out.append(pts)
    return out


def src_borders(hub):
    """State and county outlines (US Census via the us-atlas package) around you."""
    loc = hub.get("location")
    x0, y0, x1, y1 = radar_bbox(loc["lat"], loc["lon"], RADAR_MILES * 1.5)
    base = "https://cdn.jsdelivr.net/npm/us-atlas@3/"
    return dict(states=_topo_arcs(fetch_json(base + "states-10m.json", timeout=30), (x0, y0, x1, y1)),
                counties=_topo_arcs(fetch_json(base + "counties-10m.json", timeout=40), (x0, y0, x1, y1)))


def src_stills(hub):
    """Camera snapshots, only for cameras whose live stream isn't playing."""
    out = dict(hub.get("stills") or {})
    for url in list(hub.still_wanted)[:8]:
        if url in out and time.time() - out[url][1] < 60:
            continue
        try:
            out[url] = (fetch_bytes(url, timeout=15), time.time())
        except Exception:  # noqa: BLE001 - keep the previous frame
            pass
    return out


USFM_BOOKS = ("GEN EXO LEV NUM DEU JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST JOB PSA PRO ECC SNG ISA JER "
              "LAM EZK DAN HOS JOL AMO OBA JON MIC NAM HAB ZEP HAG ZEC MAL MAT MRK LUK JHN ACT ROM 1CO 2CO GAL "
              "EPH PHP COL 1TH 2TH 1TI 2TI TIT PHM HEB JAS 1PE 2PE 1JN 2JN 3JN JUD REV").split()
BOOK_NAMES = ["Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth", "1 Samuel",
              "2 Samuel", "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra", "Nehemiah", "Esther", "Job",
              "Psalms", "Proverbs", "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah", "Lamentations",
              "Ezekiel", "Daniel", "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk",
              "Zephaniah", "Haggai", "Zechariah", "Malachi", "Matthew", "Mark", "Luke", "John", "Acts", "Romans",
              "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians", "Philippians", "Colossians",
              "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus", "Philemon", "Hebrews",
              "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John", "Jude", "Revelation"]


def parse_passage(passage):
    """'2TI.2.15' or 'JHN.3.16-17' -> (book number 1-66, chapter, first verse, last verse)."""
    m = re.match(r"([1-3A-Z]{3})\.(\d+)\.(\d+)(?:-(?:[1-3A-Z]{3}\.\d+\.)?(\d+))?", passage)
    if not m or m[1] not in USFM_BOOKS:
        raise ValueError(f"unrecognized passage {passage}")
    v1 = int(m[3])
    return USFM_BOOKS.index(m[1]) + 1, int(m[2]), v1, int(m[4] or v1)


def bolls_text(translation, book, chap, v1, v2):
    """Plain text of verses v1..v2 of one chapter from bolls.life (book numbered 1-66)."""
    verses = fetch_json(f"https://bolls.life/get-text/{translation}/{book}/{chap}/")
    parts = [v["text"] for v in verses if v1 <= v.get("verse", 0) <= v2]
    text = " ".join(re.sub(r"<S>.*?</S>|<m>.*?</m>|<[^>]+>", "", t) for t in parts)
    return re.sub(r"\s+", " ", text).strip()


def original_text(passage):
    """Hebrew (WLC) for the Old Testament, Greek (SBLGNT) for the New, via bolls.life."""
    book, chap, v1, v2 = parse_passage(passage)
    hebrew = book <= 39
    return dict(orig=bolls_text("WLC" if hebrew else "SBLGNT", book, chap, v1, v2),
                orig_lang="Hebrew" if hebrew else "Greek",
                orig_src="Westminster Leningrad Codex" if hebrew else "SBL Greek New Testament", rtl=hebrew)


def src_votd(hub):
    """Verse of the day: the NET Bible's daily pick, with the ESV and original text from bolls.life."""
    verses = fetch_json("https://labs.bible.org/api/", {"passage": "votd", "type": "json", "formatting": "plain"})
    first, last = verses[0], verses[-1]
    name = first["bookname"].replace("Psalm ", "Psalms ").strip()
    if name not in BOOK_NAMES:
        raise RuntimeError(f"unknown book {name}")
    book = BOOK_NAMES.index(name) + 1
    chap, v1 = int(first["chapter"]), int(first["verse"])
    v2 = int(last["verse"]) if int(last["chapter"]) == chap else v1
    passage = f"{USFM_BOOKS[book - 1]}.{chap}.{v1}" + (f"-{v2}" if v2 != v1 else "")
    ref = f"{'Psalm' if name == 'Psalms' else name} {chap}:{v1}" + (f"–{v2}" if v2 != v1 else "")
    out = dict(date=datetime.now().strftime("%Y-%m-%d"), passage=passage, ref=ref)
    try:
        out.update(text=bolls_text("ESV", book, chap, v1, v2), version="ESV")
    except Exception:  # noqa: BLE001 - the NET text came with the pick
        out.update(text=re.sub(r"\s+", " ", " ".join(v["text"] for v in verses)).strip(), version="NET")
    if not out["text"]:
        out.update(text=re.sub(r"\s+", " ", " ".join(v["text"] for v in verses)).strip(), version="NET")
    try:
        out.update(original_text(passage))
    except Exception as e:  # noqa: BLE001 - English still shows
        out["orig_error"] = str(e)[:60]
    return out


# name: (function, refresh seconds, needs location, cached on disk)
SOURCES = {
    "location": (src_location, 6 * 3600, False, True),
    "weather": (src_weather, 600, True, True),
    "air": (src_air, 1800, True, True),
    "cameras": (src_cameras, 24 * 3600, True, True),
    "radar": (src_radar, 300, True, False),
    "borders": (src_borders, 30 * 86400, True, True),
    "stills": (src_stills, 5, False, False),
    "quakes": (src_quakes, 120, False, True),
    "neo": (src_neo, 6 * 3600, False, True),
    "iss": (src_iss, 5, False, False),
    "isscam": (src_isscam, 12, False, False),
    "iss_stream": (src_iss_stream, 6 * 3600, False, True),
    "history": (src_history, 600, True, True),
    "votd": (src_votd, 3600, False, True),  # refetched hourly so it rolls over with the day
    "space": (src_space, 300, False, True),
    "outages": (src_outages, 600, False, True),
}


class Hub:
    _instance = None

    @classmethod
    def get_instance(cls, cfg):
        if cls._instance is None:
            cls._instance = Hub(cfg)
        return cls._instance

    def __init__(self, cfg):
        self.cfg = cfg
        self.entries = {}  # name -> {"t", "data", "loc"}
        self.errors = {}
        self.retry = {}
        self.still_wanted = set()  # camera snapshot URLs the renderer needs (stream failed)
        try:
            self.entries = json.loads(CACHE.read_text())
        except (OSError, ValueError):
            pass
        # Settings that change what location-based sources return invalidate them.
        sig = [self.cfg.get("hud_location", ""), self.cfg.get("hud_units", "auto"), 3]
        if self.entries.get("_sig") != sig:
            self.entries = {}
        self.entries["_sig"] = sig
        threading.Thread(target=self._run, daemon=True, name="screenie-hud").start()

    def get(self, name):
        e = self.entries.get(name)
        return e["data"] if e else None

    def age(self, name):
        e = self.entries.get(name)
        return time.time() - e["t"] if e else None

    def error(self, name):
        return self.errors.get(name)

    def imperial(self):
        units = self.cfg.get("hud_units", "auto")
        if units != "auto":
            return units == "imperial"
        loc = self.get("location") or {}
        return loc.get("country", "US") in ("US", "LR", "MM", "")

    def _loc_key(self):
        loc = self.get("location")
        return f"{loc['lat']:.3f},{loc['lon']:.3f}" if loc else None

    def _run(self):
        while True:
            changed = False
            for name, (fn, interval, needs_loc, _) in SOURCES.items():
                now = time.time()
                loc = self._loc_key()
                if needs_loc and loc is None:
                    continue
                e = self.entries.get(name)
                due = (e is None or now - e["t"] > interval or (needs_loc and e.get("loc") != loc))
                if not due or now < self.retry.get(name, 0):
                    continue
                try:
                    data = fn(self)
                    self.entries[name] = {"t": time.time(), "data": data, "loc": loc}
                    self.errors.pop(name, None)
                    changed |= SOURCES[name][3]
                except Exception as ex:  # noqa: BLE001 - any failure just means "try later"
                    self.errors[name] = str(ex)[:80]
                    self.retry[name] = now + RETRY_SECONDS
            if changed:
                self._save()
            time.sleep(1)

    def _save(self):
        try:
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            keep = {k: v for k, v in self.entries.items() if k == "_sig" or SOURCES.get(k, (0, 0, 0, False))[3]}
            tmp = CACHE.with_suffix(".tmp")
            tmp.write_text(json.dumps(keep))
            tmp.replace(CACHE)
        except OSError:
            pass
