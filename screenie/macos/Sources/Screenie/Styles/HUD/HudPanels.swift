import Darwin
import Foundation

/// Number formatting the way the Python f-strings do it.
enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.usesGroupingSeparator = true
        return f
    }()

    /// `f"{v:,.{digits}f}"`
    static func commas(_ v: Double, _ digits: Int) -> String {
        grouped.minimumFractionDigits = digits
        grouped.maximumFractionDigits = digits
        return grouped.string(from: NSNumber(value: v)) ?? String(format: "%.\(digits)f", v)
    }

    static func commas(_ v: Int) -> String { commas(Double(v), 0) }

    /// A JSON number printed as Python would print it (ints without decimals).
    static func num(_ j: J) -> String {
        guard let v = j.double else { return HudStyle.NA }
        if let n = j.raw as? NSNumber, !CFNumberIsFloatType(n as CFNumber) { return "\(n.intValue)" }
        return v == v.rounded() && abs(v) < 1e15 ? String(format: "%.1f", v) : "\(v)"
    }
}

/// Open-Meteo returns local wall-clock times without a zone ("2026-11-05T14:00").
/// Parsing and printing them in UTC keeps the wall-clock values unchanged.
enum WallClock {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    private static let isoMinute = formatter("yyyy-MM-dd'T'HH:mm")
    private static let isoDay = formatter("yyyy-MM-dd")

    static func parse(_ s: String) -> Date? { isoMinute.date(from: s) ?? isoDay.date(from: s) }

    static func format(_ d: Date, _ format: String) -> String { formatter(format).string(from: d) }
}

extension HudStyle {
    static let wmo: [Int: String] = [
        0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast", 45: "Fog", 48: "Rime fog",
        51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle", 56: "Freezing drizzle", 57: "Freezing drizzle",
        61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain",
        71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains", 80: "Showers", 81: "Showers",
        82: "Violent showers", 85: "Snow showers", 86: "Snow showers", 95: "Thunderstorm",
        96: "T-storm, hail", 99: "T-storm, hail",
    ]

    static func L(_ label: String?, _ value: String, _ color: String = HudStyle.VALUE) -> Line { (label, value, color) }

    static func aqiLabel(_ aqi: Double) -> String {
        for (limit, name) in [(50.0, "Good"), (100, "Moderate"), (150, "Sensitive"), (200, "Unhealthy"), (300, "Very unhealthy")]
        where aqi <= limit {
            return name
        }
        return "Hazardous"
    }

    func dist(_ km: Double, _ digits: Int = 0) -> String {
        imperial ? Fmt.commas(km * 0.621371, digits) + " mi" : Fmt.commas(km, digits) + " km"
    }

    var location: (lat: Double, lon: Double, data: J)? {
        let loc = hub.get("location")
        guard let lat = loc["lat"].double, let lon = loc["lon"].double else { return nil }
        return (lat, lon, loc)
    }

    var elevation: Double { hub.get("weather")["elevation"].d() }

    func pLocation(_ now: Double) -> [Line] {
        guard let loc = location else { return [Self.L(nil, "Locating…", Self.LABEL)] }
        let elev = elevation
        var place = [loc.data["city"].s(), loc.data["region"].s(), loc.data["country"].s()].filter { !$0.isEmpty }
            .joined(separator: ", ")
        if place.isEmpty { place = Self.NA }
        let manual = loc.data["source"].s() == "manual"
        return [
            Self.L("GPS", String(format: "%.5f, %.5f", loc.lat, loc.lon), Self.BRIGHT),
            Self.L("LAT", Astro.dms(loc.lat, "N", "S")),
            Self.L("LON", Astro.dms(loc.lon, "E", "W")),
            Self.L("ELEVATION", imperial ? Fmt.commas(elev * 3.28084, 0) + " ft" : Fmt.commas(elev, 0) + " m"),
            Self.L("PLACE", place),
            Self.L("PLUS CODE", Astro.plusCode(loc.lat, loc.lon)),
            Self.L("FIX", manual ? "manual coordinates" : "IP estimate · set exact in settings", Self.LABEL),
        ]
    }

    func pWeather(_ now: Double) -> [Line] {
        let wx = hub.get("weather")
        guard wx.exists else { return [Self.L(nil, "Waiting for Open-Meteo…", Self.LABEL)] }
        let c = wx["current"]
        let imp = imperial
        let u = imp ? "°F" : "°C", wu = imp ? "mph" : "km/h"
        let air = hub.get("air")
        var aq = Self.NA
        if let aqi = air["us_aqi"].double {
            aq = "AQI \(Fmt.num(air["us_aqi"])) \(Self.aqiLabel(aqi)) · PM2.5 \(Fmt.num(air["pm2_5"]))"
        }
        let pmsl = c["pressure_msl"].d()
        let pressure = imp ? String(format: "%.2f inHg", pmsl * 0.02953) : String(format: "%.0f hPa", pmsl)
        var vis = Self.NA
        if let v = c["visibility"].double {
            vis = imp ? String(format: "%.1f mi", v / 1609.34) : String(format: "%.1f km", v / 1000)
        }
        let wcode = c["weather_code"].int ?? -1
        return [
            Self.L("NOW", String(format: "%.0f%@  ", c["temperature_2m"].d(), u) + (Self.wmo[wcode] ?? "?"), Self.BRIGHT),
            Self.L("FEELS LIKE", String(format: "%.0f%@", c["apparent_temperature"].d(), u)),
            Self.L("HUMIDITY", "\(Fmt.num(c["relative_humidity_2m"]))%  dew " + String(format: "%.0f%@", c["dew_point_2m"].d(), u)),
            Self.L("WIND", "\(Self.compassName(c["wind_direction_10m"].d())) "
                + String(format: "%.0f %@  gust %.0f", c["wind_speed_10m"].d(), wu, c["wind_gusts_10m"].d())),
            Self.L("PRESSURE", pressure),
            Self.L("CLOUD / VIS", "\(Fmt.num(c["cloud_cover"]))% · \(vis)"),
            Self.L("UV · PRECIP", String(format: "%.1f · ", c["uv_index"].d()) + "\(Fmt.num(c["precipitation"])) \(imp ? "in" : "mm")"),
            Self.L("AIR", aq, (air["us_aqi"].double ?? 999) <= 50 ? Self.GOOD : Self.VALUE),
        ]
    }

    func pForecast(_ now: Double) -> [Line] {
        let wx = hub.get("weather")
        guard wx.exists else { return [Self.L(nil, "Waiting for Open-Meteo…", Self.LABEL)] }
        let hr = wx["hourly"], dy = wx["daily"]
        var hours: [String] = []
        for i in stride(from: 0, to: min(13, hr["time"].count), by: 4) {
            guard let d = WallClock.parse(hr["time"][i].s()) else { continue }
            let hh = WallClock.format(d, "ha").lowercased()
            hours.append(String(format: "%@ %.0f°", hh, hr["temperature_2m"][i].d()))
        }
        let rain = hr["precipitation_probability"].array.prefix(13).map { $0.d() }.max() ?? 0
        var lines = [Self.L("NEXT 12H", hours.joined(separator: "  "), Self.BRIGHT),
                     Self.L("PRECIP 12H", String(format: "up to %.0f%%", rain))]
        for i in 0..<min(6, dy["time"].count) {
            let day = i == 0 ? "TODAY" : (WallClock.parse(dy["time"][i].s()).map { WallClock.format($0, "EEE").uppercased() } ?? "")
            let p = dy["precipitation_probability_max"][i].d()
            let name = Self.wmo[dy["weather_code"][i].int ?? -1] ?? "?"
            lines.append(Self.L(day, String(format: "%@  %3.0f%%  %3.0f°/%.0f°", name, p,
                                            dy["temperature_2m_max"][i].d(), dy["temperature_2m_min"][i].d())))
        }
        return lines
    }

    func pGravity(_ now: Double) -> [Line] {
        guard let loc = location else { return [Self.L("G", String(format: "%.5e m³/kg·s²", Astro.G))] }
        let g0 = Astro.normalGravity(loc.lat, elev: elevation)
        let r = Astro.geocentricRadius(loc.lat)
        let mo = Astro.moon(now), su = Astro.sun(now)
        let malt = Astro.altAz(ra: mo.ra, dec: mo.dec, lat: loc.lat, lon: loc.lon, ts: now).alt
        let salt = Astro.altAz(ra: su.ra, dec: su.dec, lat: loc.lat, lon: loc.lon, ts: now).alt
        let dm = -Astro.tidalDg(gm: Astro.gmMoon, dist: mo.dist, altDeg: malt, radius: r)
        let ds = -Astro.tidalDg(gm: Astro.gmSun, dist: su.r * Astro.AU, altDeg: salt, radius: r)
        let pull = Astro.gmMoon / pow(mo.dist, 2)
        return [
            Self.L("G  UNIVERSAL", String(format: "%.5e m³/kg·s²", Astro.G), Self.BRIGHT),
            Self.L("g  NORMAL", String(format: "%.7f m/s²", g0)),
            Self.L("MOON TIDE Δg", String(format: "%+7.1f µGal", dm / 1e-8)),
            Self.L("SUN TIDE Δg", String(format: "%+7.1f µGal", ds / 1e-8)),
            Self.L("g  NOW", String(format: "%.9f m/s²", g0 + dm + ds), Self.BRIGHT),
            Self.L("TIDE Δg/g", String(format: "%+.1f ppb", (dm + ds) / g0 * 1e9)),
            Self.L("MOON PULL", String(format: "%.3e m/s² · 1/", pull) + Fmt.commas(g0 / pull, 0) + " g"),
            Self.L("MOON ALT", String(format: "%+.1f° · ", malt) + dist(mo.dist / 1000)),
        ]
    }

    func pMotion(_ now: Double) -> [Line] {
        guard let loc = location else { return [Self.L(nil, "Locating…", Self.LABEL)] }
        let f = Astro.frameSpeeds(lat: loc.lat, lon: loc.lon, ts: now)
        let mph = Astro.kmsToMph
        let traveled = f.cmb * (now - started)
        return [
            Self.L("vs EARTH'S AXIS", Fmt.commas(f.axis * mph, 0) + " mph"),
            Self.L("vs SUN", Fmt.commas(f.sun * mph, 0) + " mph"),
            Self.L("vs GALACTIC CTR", "≈" + Fmt.commas(f.galaxy * mph, 0) + " mph"),
            Self.L("vs CMB REST", Fmt.commas(f.cmb * mph, 0) + " mph", Self.BRIGHT),
            Self.L("v/c (CMB)", String(format: "%.4f%%", f.cmb / Astro.cKms * 100)),
            Self.L("ORBIT (vis-viva)", Fmt.commas(f.orbit * mph, 0) + " mph"),
            Self.L("SINCE SAVER ON", "\(dist(traveled)) through the CMB"),
        ]
    }

    func pSunMoon(_ now: Double) -> [Line] {
        guard let loc = location else { return [Self.L(nil, "Locating…", Self.LABEL)] }
        let su = Astro.sun(now), mo = Astro.moon(now)
        let sp = Astro.altAz(ra: su.ra, dec: su.dec, lat: loc.lat, lon: loc.lon, ts: now)
        var mp = Astro.altAz(ra: mo.ra, dec: mo.dec, lat: loc.lat, lon: loc.lon, ts: now)
        mp.alt -= Astro.deg(6378140.0 / mo.dist) * cos(Astro.rad(mp.alt))  // parallax
        let phase = Astro.moonPhase(now)
        let light = su.r * Astro.AU / 299792458.0
        let daysFull = Astro.mod(180 - phase.age, 360) / 12.190749
        var rise = Self.NA, set = Self.NA, length = Self.NA
        let daily = hub.get("weather")["daily"]
        if let r = WallClock.parse(daily["sunrise"][0].s()), let s = WallClock.parse(daily["sunset"][0].s()) {
            rise = WallClock.format(r, "h:mm a")
            set = WallClock.format(s, "h:mm a")
            let secs = s.timeIntervalSince(r)
            length = String(format: "%dh %02dm", Int(secs / 3600), Int(secs.truncatingRemainder(dividingBy: 3600) / 60))
        }
        return [
            Self.L("SUN", String(format: "alt %+.1f°  az %.0f°", sp.alt, sp.az), sp.alt > 0 ? Self.BRIGHT : Self.VALUE),
            Self.L("RISE / SET", "\(rise) / \(set)"),
            Self.L("DAY LENGTH", length),
            Self.L("SUNLIGHT AGE", String(format: "%dm %04.1fs · %.4f AU", Int(light / 60), light.truncatingRemainder(dividingBy: 60), su.r)),
            Self.L("MOON", String(format: "%@ %.0f%%", phase.name, phase.illum * 100), Self.BRIGHT),
            Self.L("MOON POS", String(format: "alt %+.1f°  az %.0f°", mp.alt, mp.az)),
            Self.L("MOON DIST", dist(mo.dist / 1000)),
            Self.L("NEXT FULL", String(format: "≈%.1f days", daysFull)),
        ]
    }

    func pNeo(_ now: Double) -> [Line] {
        let rows = hub.get("neo").array
        guard !rows.isEmpty else { return [Self.L(nil, "Waiting for NASA/JPL…", Self.LABEL)] }
        let jd = Astro.julianDay(now)
        let auKm = Astro.AU / 1000, ldKm = 384400.0
        // Straight-line flyby estimate around the close approach.
        func currentKm(_ r: J) -> Double {
            let dt = (jd - r["jd"].d()) * 86400
            return hypot(r["dist"].d() * auKm, r["v_rel"].d() * dt)
        }
        guard let near = rows.min(by: { currentKm($0) < currentKm($1) }) else { return [] }
        let km = currentKm(near)
        let caTs = (near["jd"].d() - 2440587.5) * 86400
        let when = caTs < now ? "ago" : "from now"
        let delta = abs(caTs - now)
        var size = Self.NA
        if let h = near["h"].double {
            let lo = 1329 / 0.25.squareRoot() * pow(10, -h / 5) * 1000
            let hi = 1329 / 0.05.squareRoot() * pow(10, -h / 5) * 1000
            size = imperial ? Fmt.commas(lo * 3.28084, 0) + "–" + Fmt.commas(hi * 3.28084, 0) + " ft"
                : Fmt.commas(lo, 0) + "–" + Fmt.commas(hi, 0) + " m"
            size += "  (H \(Fmt.num(near["h"])))"
        }
        let upcoming = rows.filter { $0["jd"].d() > jd && $0["dist"].d() < 0.05 }.sorted { $0["jd"].d() < $1["jd"].d() }
        var nextText = Self.NA
        if let nxt = upcoming.first {
            let cd = Array(nxt["cd"].s())
            let short = cd.count >= 11 ? String(cd[5..<11]) : nxt["cd"].s()
            nextText = "\(nxt["des"].s()) · \(short) · " + String(format: "%.1f LD", nxt["dist"].d() * auKm / ldKm)
        }
        var name = near["name"].s()
        if name.hasPrefix("(") { name = name.trimmingCharacters(in: CharacterSet(charactersIn: "() ")) }
        return [
            Self.L("NAME", name, Self.BRIGHT),
            Self.L("EST. DISTANCE", String(format: "%.2f LD · ", km / ldKm) + dist(km)),
            Self.L("SPEED (rel.)", Fmt.commas(near["v_rel"].d() * Astro.kmsToMph, 0) + " mph"),
            Self.L("CLOSEST PASS", String(format: "%.2f LD · %.1f d %@", near["dist"].d() * auKm / ldKm, delta / 86400, when)),
            Self.L("EST. SIZE", size),
            Self.L("NEXT < 0.05 AU", nextText),
            Self.L(nil, "JPL close-approach data · linear flyby est.", Self.LABEL),
        ]
    }

    func pISS(_ now: Double) -> [Line] {
        let iss = hub.get("iss")
        guard iss.exists else { return [Self.L(nil, "Waiting for wheretheiss.at…", Self.LABEL)] }
        let lat = iss["latitude"].d(), lon = iss["longitude"].d()
        var lines = [
            Self.L("POSITION", String(format: "%.2f°%@ %.2f°%@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W"), Self.BRIGHT),
            Self.L("ALTITUDE", dist(iss["altitude"].d())),
            Self.L("SPEED", imperial ? Fmt.commas(iss["velocity"].d() * 0.621371, 0) + " mph" : Fmt.commas(iss["velocity"].d(), 0) + " km/h"),
        ]
        if let loc = location {
            let sr = Astro.slantRangeKm(loc.lat, loc.lon, lat, lon, altKm: iss["altitude"].d())
            lines.append(Self.L("RANGE FROM YOU", dist(sr.dist)))
            lines.append(Self.L("ELEVATION", String(format: "%+.1f° ", sr.elev) + (sr.elev > 0 ? "ABOVE HORIZON" : "below horizon"),
                                sr.elev > 0 ? Self.GOOD : Self.VALUE))
        }
        lines.append(Self.L("LIGHTING", iss["visibility"].s(Self.NA)))
        return lines
    }

    func pSpace(_ now: Double) -> [Line] {
        let sp = hub.get("space")
        guard let kp = sp["kp"].double else { return [Self.L(nil, "Waiting for NOAA SWPC…", Self.LABEL)] }
        let storm = kp < 5 ? "G0 quiet" : "G\(min(5, Int(kp) - 4)) storm"
        func f(_ j: J, _ format: String) -> String { j.double.map { String(format: format, $0) } ?? Self.NA }
        var windText = Self.NA
        if let wind = sp["wind"].double, wind != 0 {
            windText = String(format: "%.0f km/s · ", wind) + Fmt.commas(wind * Astro.kmsToMph, 0) + " mph"
        }
        return [
            Self.L("KP INDEX", String(format: "%.2f  %@", kp, storm), kp >= 5 ? Self.WARN : Self.BRIGHT),
            Self.L("SOLAR WIND", windText),
            Self.L("IMF Bz / Bt", "\(f(sp["bz"], "%+.0f")) / \(f(sp["bt"], "%.0f")) nT"),
            Self.L("F10.7 FLUX", f(sp["flux"], "%.0f sfu")),
            Self.L("SOURCE", "NOAA SWPC", Self.LABEL),
        ]
    }

    func pOutages(_ now: Double) -> [Line] {
        let o = hub.get("outages")
        guard o.exists else { return [Self.L(nil, "Waiting for ORNL ODIN…", Self.LABEL)] }
        var lines = [Self.L("CUSTOMERS OUT", Fmt.commas(o["total"].int ?? 0), Self.BRIGHT),
                     Self.L("INCIDENTS", Fmt.commas(o["incidents"].int ?? 0))]
        for st in o["states"].array.prefix(4) {
            lines.append(Self.L("  \(st[0].s())", Fmt.commas(st[1].int ?? 0)))
        }
        lines.append(Self.L(nil, "ODIN-reporting utilities only", Self.LABEL))
        return lines
    }

    func pSeismic(_ now: Double) -> [Line] {
        let qs = hub.get("quakes").array
        guard !qs.isEmpty, let big = qs.max(by: { $0["mag"].d() < $1["mag"].d() }) else {
            return [Self.L(nil, "Waiting for USGS…", Self.LABEL)]
        }
        let energy = qs.reduce(0.0) { $0 + pow(10, 1.5 * $1["mag"].d() + 4.8) }
        let bigMag = big["mag"].d()
        var lines = [
            Self.L("EVENTS", "\(qs.count) · \(qs.filter { $0["mag"].d() >= 4.5 }.count) ≥ M4.5"),
            Self.L("LARGEST", String(format: "M%.1f ", bigMag) + big["place"].s(), bigMag >= 6 ? Self.WARN : Self.BRIGHT),
        ]
        if let loc = location {
            func km(_ q: J) -> Double { Astro.haversineKm(loc.lat, loc.lon, q["lat"].d(), q["lon"].d()) }
            if let near = qs.min(by: { km($0) < km($1) }) {
                let region = near["place"].s().components(separatedBy: ", ").last ?? ""
                lines.append(Self.L("NEAREST YOU", String(format: "M%.1f · ", near["mag"].d()) + dist(km(near)) + " · " + region))
            }
        }
        let last = qs[qs.count - 1]
        lines.append(Self.L("LATEST", String(format: "M%.1f · %d min ago", last["mag"].d(), Int((now - last["t"].d()) / 60))))
        lines.append(Self.L("ENERGY", String(format: "%.2e J · ", energy) + Fmt.commas(energy / 4.184e12, 2) + " kt TNT"))
        lines.append(Self.L("DEEPEST", Fmt.commas(qs.map { $0["depth"].d() }.max() ?? 0, 0) + " km"))
        return lines
    }

    private static func hms(_ hours: Double) -> String {
        String(format: "%02d:%02d:%02d", Int(hours), Int(hours * 60) % 60, Int(hours * 3600) % 60)
    }

    func pChrono(_ now: Double) -> [Line] {
        let date = Date(timeIntervalSince1970: now)
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let g = Astro.gmstDeg(now) / 15
        let lmst = location.map { Self.hms(Astro.mod(Astro.gmstDeg(now) + $0.lon, 360) / 15) } ?? Self.NA
        let year = cal.component(.year, from: date)
        let y0 = cal.date(from: DateComponents(year: year, month: 1, day: 1))!.timeIntervalSince1970
        let y1 = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!.timeIntervalSince1970
        let doy = cal.ordinality(of: .day, in: .year, for: date) ?? 0
        let week = cal.component(.weekOfYear, from: date)
        let tz = hub.get("weather")["timezone"].string ?? TimeZone.current.identifier
        return [
            Self.L("UNIX", String(format: "%.3f", now), Self.BRIGHT),
            Self.L("JULIAN DATE", String(format: "%.5f", Astro.julianDay(now))),
            Self.L("GMST", Self.hms(g)),
            Self.L("LOCAL SIDEREAL", lmst),
            Self.L("DAY / WEEK", "day \(doy) · ISO week \(week)"),
            Self.L("TIME ZONE", tz),
            Self.L("YEAR", String(format: "%.5f%% complete", (now - y0) / (y1 - y0) * 100)),
        ]
    }

    /// Memory in use (active + wired + compressed pages), in bytes.
    private static func memoryUsed() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        return (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    func pMachine(_ now: Double) -> [Line] {
        let info = ProcessInfo.processInfo
        let up = info.systemUptime
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        let gib = 1_073_741_824.0
        let total = Double(info.physicalMemory) / gib
        let used = Self.memoryUsed() / gib
        let host = info.hostName.replacingOccurrences(of: ".local", with: "")
        return [
            Self.L("HOST", host),
            Self.L("UPTIME", "\(Int(up / 86400))d \(Int(up.truncatingRemainder(dividingBy: 86400) / 3600))h \(Int(up.truncatingRemainder(dividingBy: 3600) / 60))m"),
            Self.L("LOAD", String(format: "%.2f  %.2f  %.2f  (%d CPUs)", load[0], load[1], load[2], info.activeProcessorCount)),
            Self.L("MEMORY", String(format: "%.1f / %.1f GiB used", used, total)),
            Self.L("SAVER ON FOR", "\(Int((now - started) / 60)) min"),
        ]
    }

    func pCameras(_ now: Double) -> [Line] {
        let cams = hub.get("cameras")
        if !cams.exists { return [Self.L(nil, "Finding nearby cameras…", Self.LABEL)] }
        if cams.count == 0 { return [Self.L(nil, "No WisDOT cameras within \(Int(radarMiles)) miles", Self.LABEL)] }
        return []  // the grid itself is drawn live
    }
}
