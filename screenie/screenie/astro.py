"""Small, dependency-free astronomy and geodesy for the HUD.

Sun and Moon positions use Paul Schlyter's low-precision method (about 1-2
arcminutes), which is plenty for tides, phases and rise/set style readouts.
"""

import math

G = 6.67430e-11  # CODATA 2018/2022, m^3 kg^-1 s^-2
GM_MOON = 4.9048695e12
GM_SUN = 1.32712440018e20
AU = 1.495978707e11
EARTH_A = 6378137.0  # WGS84 equatorial radius, m
EARTH_B = 6356752.3142
OMEGA_EARTH = 7.2921159e-5  # rad/s
C_KMS = 299792.458
KMS_TO_MPH = 2236.9363

# Sun's velocity relative to the cosmic microwave background (Planck dipole, J2000).
CMB_RA, CMB_DEC, CMB_SPEED = 167.942, -6.944, 369.82
# Sun's orbit around the galactic center: ~230 km/s toward galactic l=90, b=0 (Cygnus).
GAL_RA, GAL_DEC, GAL_SPEED = 318.004, 48.330, 230.0

rad, deg = math.radians, math.degrees


def sind(x):
    return math.sin(rad(x))


def cosd(x):
    return math.cos(rad(x))


def julian_day(ts):
    return ts / 86400.0 + 2440587.5


def gmst_deg(ts):
    return (280.46061837 + 360.98564736629 * (julian_day(ts) - 2451545.0)) % 360


def _day(ts):
    return julian_day(ts) - 2451543.5  # Schlyter's day number


def _obliquity(d):
    return 23.4393 - 3.563e-7 * d


def _ecl_to_eq(lon, lat, d):
    """Ecliptic (deg) to equatorial RA/Dec (deg)."""
    ecl = _obliquity(d)
    x = cosd(lon) * cosd(lat)
    y = sind(lon) * cosd(lat)
    z = sind(lat)
    ye = y * cosd(ecl) - z * sind(ecl)
    ze = y * sind(ecl) + z * cosd(ecl)
    return deg(math.atan2(ye, x)) % 360, deg(math.atan2(ze, math.hypot(x, ye)))


def sun(ts):
    """Geocentric Sun: ecliptic longitude (deg), distance (AU), RA, Dec, mean anomaly, mean longitude."""
    d = _day(ts)
    w = 282.9404 + 4.70935e-5 * d
    e = 0.016709 - 1.151e-9 * d
    M = (356.0470 + 0.9856002585 * d) % 360
    E = M + deg(e) * sind(M) * (1 + e * cosd(M))
    xv, yv = cosd(E) - e, math.sqrt(1 - e * e) * sind(E)
    v, r = deg(math.atan2(yv, xv)), math.hypot(xv, yv)
    lon = (v + w) % 360
    ra, dec = _ecl_to_eq(lon, 0.0, d)
    return dict(lon=lon, r=r, ra=ra, dec=dec, M=M, L=(M + w) % 360)


def moon(ts):
    """Geocentric Moon: ecliptic lon/lat (deg), distance (m), RA, Dec."""
    d = _day(ts)
    N = 125.1228 - 0.0529538083 * d
    i = 5.1454
    w = 318.0634 + 0.1643573223 * d
    a, e = 60.2666, 0.054900
    M = (115.3654 + 13.0649929509 * d) % 360
    E = M + deg(e) * sind(M) * (1 + e * cosd(M))
    for _ in range(5):
        E -= (E - deg(e) * sind(E) - M) / (1 - e * cosd(E))
    xv, yv = a * (cosd(E) - e), a * math.sqrt(1 - e * e) * sind(E)
    v, r = deg(math.atan2(yv, xv)), math.hypot(xv, yv)
    xh = r * (cosd(N) * cosd(v + w) - sind(N) * sind(v + w) * cosd(i))
    yh = r * (sind(N) * cosd(v + w) + cosd(N) * sind(v + w) * cosd(i))
    zh = r * sind(v + w) * sind(i)
    lon = deg(math.atan2(yh, xh))
    lat = deg(math.atan2(zh, math.hypot(xh, yh)))

    s = sun(ts)
    Ms, Mm = s["M"], M
    Lm = M + w + N
    D = Lm - s["L"]
    F = Lm - N
    lon += (-1.274 * sind(Mm - 2 * D) + 0.658 * sind(2 * D) - 0.186 * sind(Ms)
            - 0.059 * sind(2 * Mm - 2 * D) - 0.057 * sind(Mm - 2 * D + Ms)
            + 0.053 * sind(Mm + 2 * D) + 0.046 * sind(2 * D - Ms) + 0.041 * sind(Mm - Ms)
            - 0.035 * sind(D) - 0.031 * sind(Mm + Ms) - 0.015 * sind(2 * F - 2 * D)
            + 0.011 * sind(Mm - 4 * D))
    lat += (-0.173 * sind(F - 2 * D) - 0.055 * sind(Mm - F - 2 * D)
            - 0.046 * sind(Mm + F - 2 * D) + 0.033 * sind(F + 2 * D) + 0.017 * sind(2 * Mm + F))
    r += -0.58 * cosd(Mm - 2 * D) - 0.46 * cosd(2 * D)
    lon %= 360
    ra, dec = _ecl_to_eq(lon, lat, d)
    return dict(lon=lon, lat=lat, dist=r * 6378140.0, ra=ra, dec=dec)


def alt_az(ra, dec, lat, lon, ts):
    """Geocentric altitude and azimuth (deg, azimuth from north)."""
    ha = (gmst_deg(ts) + lon - ra) % 360
    alt = deg(math.asin(sind(lat) * sind(dec) + cosd(lat) * cosd(dec) * cosd(ha)))
    az = deg(math.atan2(sind(ha), cosd(ha) * sind(lat) - math.tan(rad(dec)) * cosd(lat))) + 180
    return alt, az % 360


def moon_phase(ts):
    s, m = sun(ts), moon(ts)
    age = (m["lon"] - s["lon"]) % 360  # 0 new, 180 full
    illum = (1 - cosd(age)) / 2
    names = ["New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
             "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"]
    return names[int((age + 22.5) // 45) % 8], illum, age


def geocentric_radius(lat):
    a, b = EARTH_A, EARTH_B
    c, s = cosd(lat), sind(lat)
    return math.sqrt(((a * a * c) ** 2 + (b * b * s) ** 2) / ((a * c) ** 2 + (b * s) ** 2))


def normal_gravity(lat, elev_m=0.0):
    """WGS84 Somigliana normal gravity with free-air correction, m/s^2."""
    s2 = sind(lat) ** 2
    g0 = 9.7803253359 * (1 + 0.00193185265241 * s2) / math.sqrt(1 - 0.00669437999013 * s2)
    return g0 - 3.086e-6 * elev_m


def tidal_dg(gm, dist, alt_deg, radius):
    """Vertical tidal acceleration (m/s^2, positive = upward, i.e. reduces g) on a rigid Earth."""
    cz = sind(alt_deg)  # cos(zenith angle)
    return gm * radius / dist ** 3 * (3 * cz * cz - 1)


def _vec(ra, dec, speed):
    return (speed * cosd(dec) * cosd(ra), speed * cosd(dec) * sind(ra), speed * sind(dec))


def _add(*vs):
    return tuple(sum(c) for c in zip(*vs))


def _norm(v):
    return math.sqrt(sum(c * c for c in v))


def frame_speeds(lat, lon, ts):
    """Your speed (km/s) relative to successively larger frames, by Galilean velocity addition."""
    d = _day(ts)
    ecl = _obliquity(d)
    # Rotation: eastward, in equatorial coordinates.
    theta = rad(gmst_deg(ts) + lon)
    vr = OMEGA_EARTH * geocentric_radius(lat) * cosd(lat) / 1000.0
    v_rot = (-vr * math.sin(theta), vr * math.cos(theta), 0.0)
    # Orbit: Earth moves toward ecliptic longitude (sun longitude - 90), vis-viva speed.
    s = sun(ts)
    r = s["r"] * AU
    vo = math.sqrt(GM_SUN * (2 / r - 1 / (1.000001018 * AU))) / 1000.0
    psi = rad(s["lon"] - 90)
    v_orb = (vo * math.cos(psi), vo * math.sin(psi) * cosd(ecl), vo * math.sin(psi) * sind(ecl))
    v_gal = _vec(GAL_RA, GAL_DEC, GAL_SPEED)
    v_cmb = _vec(CMB_RA, CMB_DEC, CMB_SPEED)
    return {
        "axis": _norm(v_rot),
        "sun": _norm(_add(v_rot, v_orb)),
        "galaxy": _norm(_add(v_rot, v_orb, v_gal)),
        "cmb": _norm(_add(v_rot, v_orb, v_cmb)),
        "orbit": vo,
    }


def haversine_km(lat1, lon1, lat2, lon2):
    p1, p2 = rad(lat1), rad(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(rad(lon2 - lon1) / 2) ** 2
    return 2 * 6371.0088 * math.asin(math.sqrt(a))


def slant_range_km(lat1, lon1, lat2, lon2, alt_km):
    """Straight-line distance and elevation angle from a ground point to something at altitude."""
    R = 6371.0088
    c = haversine_km(lat1, lon1, lat2, lon2) / R
    r2 = R + alt_km
    dist = math.sqrt(R * R + r2 * r2 - 2 * R * r2 * math.cos(c))
    elev = deg(math.atan2(math.cos(c) - R / r2, math.sin(c))) if c > 1e-9 else 90.0
    return dist, elev


PLUS_ALPHABET = "23456789CFGHJMPQRVWX"


def plus_code(lat, lon):
    """Open Location Code (10 digits, ~14 m)."""
    lat = min(max(lat, -90.0), 90.0 - 1e-9) + 90
    lon = (lon + 180) % 360
    code, res = "", 20.0
    for i in range(5):
        dl, dg = int(lat // res), int(lon // res)
        lat -= dl * res
        lon -= dg * res
        code += PLUS_ALPHABET[dl] + PLUS_ALPHABET[dg]
        res /= 20
        if i == 3:
            code += "+"
    return code


def dms(value, pos, neg):
    hemi = pos if value >= 0 else neg
    v = abs(value)
    d = int(v)
    m = int((v - d) * 60)
    s = (v - d - m / 60) * 3600
    return f"{d:3d}°{m:02d}'{s:04.1f}\"{hemi}"
