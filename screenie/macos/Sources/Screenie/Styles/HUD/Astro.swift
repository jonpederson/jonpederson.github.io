import Foundation

/// Small, dependency-free astronomy and geodesy for the HUD (port of `astro.py`).
///
/// Sun and Moon positions use Paul Schlyter's low-precision method (about 1-2
/// arcminutes), which is plenty for tides, phases and rise/set style readouts.
enum Astro {
    static let G = 6.67430e-11  // CODATA 2018/2022, m^3 kg^-1 s^-2
    static let gmMoon = 4.9048695e12
    static let gmSun = 1.32712440018e20
    static let AU = 1.495978707e11
    static let earthA = 6378137.0  // WGS84 equatorial radius, m
    static let earthB = 6356752.3142
    static let omegaEarth = 7.2921159e-5  // rad/s
    static let cKms = 299792.458
    static let kmsToMph = 2236.9363

    // Sun's velocity relative to the cosmic microwave background (Planck dipole, J2000).
    static let cmbRA = 167.942, cmbDec = -6.944, cmbSpeed = 369.82
    // Sun's orbit around the galactic center: ~230 km/s toward galactic l=90, b=0 (Cygnus).
    static let galRA = 318.004, galDec = 48.330, galSpeed = 230.0

    static func rad(_ x: Double) -> Double { x * .pi / 180 }
    static func deg(_ x: Double) -> Double { x * 180 / .pi }
    static func sind(_ x: Double) -> Double { sin(rad(x)) }
    static func cosd(_ x: Double) -> Double { cos(rad(x)) }

    /// Python's `%` for floats (result has the sign of the divisor).
    static func mod(_ a: Double, _ b: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: b)
        return r < 0 ? r + b : r
    }

    static func julianDay(_ ts: Double) -> Double { ts / 86400.0 + 2440587.5 }

    static func gmstDeg(_ ts: Double) -> Double {
        mod(280.46061837 + 360.98564736629 * (julianDay(ts) - 2451545.0), 360)
    }

    private static func day(_ ts: Double) -> Double { julianDay(ts) - 2451543.5 }  // Schlyter's day number

    private static func obliquity(_ d: Double) -> Double { 23.4393 - 3.563e-7 * d }

    /// Ecliptic (deg) to equatorial RA/Dec (deg).
    private static func eclToEq(_ lon: Double, _ lat: Double, _ d: Double) -> (ra: Double, dec: Double) {
        let ecl = obliquity(d)
        let x = cosd(lon) * cosd(lat)
        let y = sind(lon) * cosd(lat)
        let z = sind(lat)
        let ye = y * cosd(ecl) - z * sind(ecl)
        let ze = y * sind(ecl) + z * cosd(ecl)
        return (mod(deg(atan2(ye, x)), 360), deg(atan2(ze, hypot(x, ye))))
    }

    struct Sun {
        let lon, r, ra, dec, M, L: Double  // r in AU
    }

    static func sun(_ ts: Double) -> Sun {
        let d = day(ts)
        let w = 282.9404 + 4.70935e-5 * d
        let e = 0.016709 - 1.151e-9 * d
        let M = mod(356.0470 + 0.9856002585 * d, 360)
        let E = M + deg(e) * sind(M) * (1 + e * cosd(M))
        let xv = cosd(E) - e, yv = (1 - e * e).squareRoot() * sind(E)
        let v = deg(atan2(yv, xv)), r = hypot(xv, yv)
        let lon = mod(v + w, 360)
        let eq = eclToEq(lon, 0, d)
        return Sun(lon: lon, r: r, ra: eq.ra, dec: eq.dec, M: M, L: mod(M + w, 360))
    }

    struct Moon {
        let lon, lat, dist, ra, dec: Double  // dist in m
    }

    static func moon(_ ts: Double) -> Moon {
        let d = day(ts)
        let N = 125.1228 - 0.0529538083 * d
        let i = 5.1454
        let w = 318.0634 + 0.1643573223 * d
        let a = 60.2666, e = 0.054900
        let M = mod(115.3654 + 13.0649929509 * d, 360)
        var E = M + deg(e) * sind(M) * (1 + e * cosd(M))
        for _ in 0..<5 {
            E -= (E - deg(e) * sind(E) - M) / (1 - e * cosd(E))
        }
        let xv = a * (cosd(E) - e), yv = a * (1 - e * e).squareRoot() * sind(E)
        let v = deg(atan2(yv, xv))
        var r = hypot(xv, yv)
        let xh = r * (cosd(N) * cosd(v + w) - sind(N) * sind(v + w) * cosd(i))
        let yh = r * (sind(N) * cosd(v + w) + cosd(N) * sind(v + w) * cosd(i))
        let zh = r * sind(v + w) * sind(i)
        var lon = deg(atan2(yh, xh))
        var lat = deg(atan2(zh, hypot(xh, yh)))

        let s = sun(ts)
        let Ms = s.M, Mm = M
        let Lm = M + w + N
        let D = Lm - s.L
        let F = Lm - N
        lon += -1.274 * sind(Mm - 2 * D) + 0.658 * sind(2 * D) - 0.186 * sind(Ms)
        lon += -0.059 * sind(2 * Mm - 2 * D) - 0.057 * sind(Mm - 2 * D + Ms)
        lon += 0.053 * sind(Mm + 2 * D) + 0.046 * sind(2 * D - Ms) + 0.041 * sind(Mm - Ms)
        lon += -0.035 * sind(D) - 0.031 * sind(Mm + Ms) - 0.015 * sind(2 * F - 2 * D)
        lon += 0.011 * sind(Mm - 4 * D)
        lat += -0.173 * sind(F - 2 * D) - 0.055 * sind(Mm - F - 2 * D)
        lat += -0.046 * sind(Mm + F - 2 * D) + 0.033 * sind(F + 2 * D) + 0.017 * sind(2 * Mm + F)
        r += -0.58 * cosd(Mm - 2 * D) - 0.46 * cosd(2 * D)
        lon = mod(lon, 360)
        let eq = eclToEq(lon, lat, d)
        return Moon(lon: lon, lat: lat, dist: r * 6378140.0, ra: eq.ra, dec: eq.dec)
    }

    /// Geocentric altitude and azimuth (deg, azimuth from north).
    static func altAz(ra: Double, dec: Double, lat: Double, lon: Double, ts: Double) -> (alt: Double, az: Double) {
        let ha = mod(gmstDeg(ts) + lon - ra, 360)
        let alt = deg(asin(sind(lat) * sind(dec) + cosd(lat) * cosd(dec) * cosd(ha)))
        let az = deg(atan2(sind(ha), cosd(ha) * sind(lat) - tan(rad(dec)) * cosd(lat))) + 180
        return (alt, mod(az, 360))
    }

    static func moonPhase(_ ts: Double) -> (name: String, illum: Double, age: Double) {
        let s = sun(ts), m = moon(ts)
        let age = mod(m.lon - s.lon, 360)  // 0 new, 180 full
        let illum = (1 - cosd(age)) / 2
        let names = ["New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
                     "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"]
        return (names[Int(((age + 22.5) / 45).rounded(.down)) % 8], illum, age)
    }

    static func geocentricRadius(_ lat: Double) -> Double {
        let a = earthA, b = earthB
        let c = cosd(lat), s = sind(lat)
        let num = pow(a * a * c, 2) + pow(b * b * s, 2)
        let den = pow(a * c, 2) + pow(b * s, 2)
        return (num / den).squareRoot()
    }

    /// WGS84 Somigliana normal gravity with free-air correction, m/s^2.
    static func normalGravity(_ lat: Double, elev: Double = 0) -> Double {
        let s2 = pow(sind(lat), 2)
        let g0 = 9.7803253359 * (1 + 0.00193185265241 * s2) / (1 - 0.00669437999013 * s2).squareRoot()
        return g0 - 3.086e-6 * elev
    }

    /// Vertical tidal acceleration (m/s^2, positive = upward, i.e. reduces g) on a rigid Earth.
    static func tidalDg(gm: Double, dist: Double, altDeg: Double, radius: Double) -> Double {
        let cz = sind(altDeg)  // cos(zenith angle)
        return gm * radius / pow(dist, 3) * (3 * cz * cz - 1)
    }

    private typealias V3 = (Double, Double, Double)

    private static func vec(_ ra: Double, _ dec: Double, _ speed: Double) -> V3 {
        (speed * cosd(dec) * cosd(ra), speed * cosd(dec) * sind(ra), speed * sind(dec))
    }

    private static func add(_ vs: V3...) -> V3 {
        vs.reduce((0, 0, 0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
    }

    private static func norm(_ v: V3) -> Double { (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot() }

    struct FrameSpeeds {
        let axis, sun, galaxy, cmb, orbit: Double  // km/s
    }

    /// Your speed (km/s) relative to successively larger frames, by Galilean velocity addition.
    static func frameSpeeds(lat: Double, lon: Double, ts: Double) -> FrameSpeeds {
        let d = day(ts)
        let ecl = obliquity(d)
        // Rotation: eastward, in equatorial coordinates.
        let theta = rad(gmstDeg(ts) + lon)
        let vr = omegaEarth * geocentricRadius(lat) * cosd(lat) / 1000.0
        let vRot: V3 = (-vr * sin(theta), vr * cos(theta), 0)
        // Orbit: Earth moves toward ecliptic longitude (sun longitude - 90), vis-viva speed.
        let s = sun(ts)
        let r = s.r * AU
        let vo = (gmSun * (2 / r - 1 / (1.000001018 * AU))).squareRoot() / 1000.0
        let psi = rad(s.lon - 90)
        let vOrb: V3 = (vo * cos(psi), vo * sin(psi) * cosd(ecl), vo * sin(psi) * sind(ecl))
        let vGal = vec(galRA, galDec, galSpeed)
        let vCmb = vec(cmbRA, cmbDec, cmbSpeed)
        return FrameSpeeds(axis: norm(vRot), sun: norm(add(vRot, vOrb)), galaxy: norm(add(vRot, vOrb, vGal)),
                           cmb: norm(add(vRot, vOrb, vCmb)), orbit: vo)
    }

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = rad(lat1), p2 = rad(lat2)
        let a = pow(sin((p2 - p1) / 2), 2) + cos(p1) * cos(p2) * pow(sin(rad(lon2 - lon1) / 2), 2)
        return 2 * 6371.0088 * asin(a.squareRoot())
    }

    /// Straight-line distance and elevation angle from a ground point to something at altitude.
    static func slantRangeKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double,
                             altKm: Double) -> (dist: Double, elev: Double) {
        let R = 6371.0088
        let c = haversineKm(lat1, lon1, lat2, lon2) / R
        let r2 = R + altKm
        let dist = (R * R + r2 * r2 - 2 * R * r2 * cos(c)).squareRoot()
        let elev = c > 1e-9 ? deg(atan2(cos(c) - R / r2, sin(c))) : 90.0
        return (dist, elev)
    }

    private static let plusAlphabet = Array("23456789CFGHJMPQRVWX")

    /// Open Location Code (10 digits, ~14 m).
    static func plusCode(_ latIn: Double, _ lonIn: Double) -> String {
        var lat = min(max(latIn, -90.0), 90.0 - 1e-9) + 90
        var lon = mod(lonIn + 180, 360)
        var code = ""
        var res = 20.0
        for i in 0..<5 {
            let dl = Int((lat / res).rounded(.down)), dg = Int((lon / res).rounded(.down))
            lat -= Double(dl) * res
            lon -= Double(dg) * res
            code.append(plusAlphabet[min(max(dl, 0), 19)])
            code.append(plusAlphabet[min(max(dg, 0), 19)])
            res /= 20
            if i == 3 { code += "+" }
        }
        return code
    }

    static func dms(_ value: Double, _ pos: String, _ neg: String) -> String {
        let hemi = value >= 0 ? pos : neg
        let v = abs(value)
        let d = Int(v)
        let m = Int((v - Double(d)) * 60)
        let s = (v - Double(d) - Double(m) / 60) * 3600
        return String(format: "%d°%02d'%04.1f\"%@", d, m, s, hemi)
    }
}
