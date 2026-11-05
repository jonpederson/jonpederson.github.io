import Foundation

// Background fetching of live data for the HUD style (port of `hud_data.py`).
//
// Each source is polled on its own interval while a HUD is on screen. Results are kept
// in memory (they survive between screensaver runs, since the app stays running) and
// the slow-changing ones in ~/Library/Caches/Screenie/hud.json, so the HUD fills in
// immediately. Drawing code only ever reads `Hub.get()`; it never waits.

/// Loosely typed JSON, read like the Python dicts: `j["current"]["temperature_2m"].double`.
struct J: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    static let null = J(nil)

    subscript(key: String) -> J { J((raw as? [String: Any])?[key]) }

    subscript(index: Int) -> J {
        guard let a = raw as? [Any], index >= 0, index < a.count else { return .null }
        return J(a[index])
    }

    var isNull: Bool { raw == nil || raw is NSNull }
    var exists: Bool { !isNull }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    var int: Int? { double.map { Int($0) } }
    var string: String? { raw as? String }
    var bool: Bool? { (raw as? NSNumber)?.boolValue }
    var data: Data? { raw as? Data }
    var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    var count: Int { (raw as? [Any])?.count ?? 0 }
    var last: J { self[count - 1] }

    func d(_ fallback: Double = 0) -> Double { double ?? fallback }
    func s(_ fallback: String = "") -> String { string ?? fallback }

    static func parse(_ data: Data) throws -> J {
        J(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }
}

enum HubError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}

/// What a source function can see: a snapshot of the other sources and settings.
struct HubContext: @unchecked Sendable {
    let entries: [String: J]
    let hudLocation: String
    let imperial: Bool
    let stillWanted: [String]

    func get(_ name: String) -> J { entries[name] ?? .null }
}

enum Net {
    static let userAgent = "screenie-screensaver/1.0"

    static func url(_ base: String, _ params: [(String, String)] = []) -> URL {
        var c = URLComponents(string: base)!
        if !params.isEmpty {
            c.queryItems = (c.queryItems ?? []) + params.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" alone, which servers read as a space.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    static func bytes(_ base: String, _ params: [(String, String)] = [], timeout: Double = 20,
                      headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url(base, params), timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HubError.message("HTTP \(http.statusCode)")
        }
        return data
    }

    static func json(_ base: String, _ params: [(String, String)] = [], timeout: Double = 15,
                     headers: [String: String] = [:]) async throws -> J {
        var h = ["Accept": "application/json"]
        h.merge(headers) { _, new in new }
        return try J.parse(try await bytes(base, params, timeout: timeout, headers: h))
    }
}

func parseCoords(_ text: String) -> (lat: Double, lon: Double)? {
    let parts = text.replacingOccurrences(of: ";", with: ",").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
    guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
    return (lat, lon)
}

let radarMiles = 200.0

/// A box `miles` from the center each way (lon_min, lat_min, lon_max, lat_max), equirectangular.
func radarBBox(_ lat: Double, _ lon: Double, miles: Double = radarMiles) -> [Double] {
    let dlat = miles / 69.0
    let dlon = miles / (69.17 * cos(Astro.rad(lat)))
    return [lon - dlon, lat - dlat, lon + dlon, lat + dlat]
}

/// Ground-track velocity (deg/s lat, deg/s lon) from the last two fixes, or nil.
func issMotion(_ iss: J) -> (dlat: Double, dlon: Double)? {
    let prev = iss["prev"]
    guard iss.exists, prev.count == 3,
          let plat = prev[0].double, let plon = prev[1].double, let pts = prev[2].double,
          let ts = iss["timestamp"].double, let lat = iss["latitude"].double, let lon = iss["longitude"].double
    else { return nil }
    let dt = ts - pts
    if dt <= 0 || dt > 120 { return nil }
    let dlon = Astro.mod(lon - plon + 540, 360) - 180
    return ((lat - plat) / dt, dlon / dt)
}

/// Dead-reckoned ISS sub-point (lat, lon) at `now`.
func issPosition(_ iss: J, _ now: Double) -> (lat: Double, lon: Double) {
    var lat = iss["latitude"].d(), lon = iss["longitude"].d()
    if let v = issMotion(iss) {
        let dt = now - iss["timestamp"].d()
        lat += v.dlat * dt
        lon = Astro.mod(lon + v.dlon * dt + 540, 360) - 180
    }
    return (lat, lon)
}

private let stateFIPS: [String: String] = [
    "01": "AL", "02": "AK", "04": "AZ", "05": "AR", "06": "CA", "08": "CO", "09": "CT", "10": "DE",
    "11": "DC", "12": "FL", "13": "GA", "15": "HI", "16": "ID", "17": "IL", "18": "IN", "19": "IA",
    "20": "KS", "21": "KY", "22": "LA", "23": "ME", "24": "MD", "25": "MA", "26": "MI", "27": "MN",
    "28": "MS", "29": "MO", "30": "MT", "31": "NE", "32": "NV", "33": "NH", "34": "NJ", "35": "NM",
    "36": "NY", "37": "NC", "38": "ND", "39": "OH", "40": "OK", "41": "OR", "42": "PA", "44": "RI",
    "45": "SC", "46": "SD", "47": "TN", "48": "TX", "49": "UT", "50": "VT", "51": "VA", "53": "WA",
    "54": "WV", "55": "WI", "56": "WY", "72": "PR",
]

private func ymd(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

private func regexMatches(_ pattern: String, _ text: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

private func replacing(_ pattern: String, in text: String, with template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
    return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: template)
}

private func collapseSpaces(_ s: String) -> String {
    replacing("\\s+", in: s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Sources

enum Sources {
    typealias Fn = @Sendable (HubContext) async throws -> J

    struct Source {
        let fn: Fn
        let interval: Double
        let needsLocation: Bool
        let cached: Bool
    }

    /// name: (function, refresh seconds, needs location, cached on disk). Order matters
    /// only for the first fetch.
    static let all: [(String, Source)] = [
        ("location", Source(fn: location, interval: 6 * 3600, needsLocation: false, cached: true)),
        ("weather", Source(fn: weather, interval: 600, needsLocation: true, cached: true)),
        ("air", Source(fn: air, interval: 1800, needsLocation: true, cached: true)),
        ("cameras", Source(fn: cameras, interval: 24 * 3600, needsLocation: true, cached: true)),
        ("radar", Source(fn: radar, interval: 300, needsLocation: true, cached: false)),
        ("borders", Source(fn: borders, interval: 30 * 86400, needsLocation: true, cached: true)),
        ("stills", Source(fn: stills, interval: 5, needsLocation: false, cached: false)),
        ("quakes", Source(fn: quakes, interval: 120, needsLocation: false, cached: true)),
        ("neo", Source(fn: neo, interval: 6 * 3600, needsLocation: false, cached: true)),
        ("iss", Source(fn: iss, interval: 5, needsLocation: false, cached: false)),
        ("isscam", Source(fn: isscam, interval: 12, needsLocation: false, cached: false)),
        ("iss_stream", Source(fn: issStream, interval: 6 * 3600, needsLocation: false, cached: true)),
        ("history", Source(fn: history, interval: 600, needsLocation: true, cached: true)),
        ("votd", Source(fn: votd, interval: 3600, needsLocation: false, cached: true)),  // rolls over with the day
        ("space", Source(fn: space, interval: 300, needsLocation: false, cached: true)),
        ("outages", Source(fn: outages, interval: 600, needsLocation: false, cached: true)),
    ]

    static func location(_ ctx: HubContext) async throws -> J {
        if let m = parseCoords(ctx.hudLocation) {
            return J(["lat": m.lat, "lon": m.lon, "source": "manual", "city": "", "region": "", "country": ""])
        }
        let d = try await Net.json("https://ipwho.is/")
        guard d["success"].bool == true else { throw HubError.message(d["message"].s("IP lookup failed")) }
        return J(["lat": d["latitude"].d(), "lon": d["longitude"].d(), "source": "IP estimate",
                  "city": d["city"].s(), "region": d["region"].s(), "country": d["country_code"].s()])
    }

    private static func latLon(_ ctx: HubContext) -> [(String, String)] {
        let loc = ctx.get("location")
        return [("latitude", "\(loc["lat"].d())"), ("longitude", "\(loc["lon"].d())")]
    }

    static func weather(_ ctx: HubContext) async throws -> J {
        let imp = ctx.imperial
        return try await Net.json("https://api.open-meteo.com/v1/forecast", latLon(ctx) + [
            ("timezone", "auto"),
            ("current", "temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,weather_code,"
                + "cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,"
                + "precipitation,uv_index,visibility,is_day"),
            ("hourly", "temperature_2m,precipitation_probability,weather_code"),
            ("daily", "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
                + "sunrise,sunset,uv_index_max,wind_speed_10m_max"),
            ("forecast_hours", "13"), ("forecast_days", "6"),
            ("temperature_unit", imp ? "fahrenheit" : "celsius"),
            ("wind_speed_unit", imp ? "mph" : "kmh"),
            ("precipitation_unit", imp ? "inch" : "mm"),
        ])
    }

    static func air(_ ctx: HubContext) async throws -> J {
        try await Net.json("https://air-quality-api.open-meteo.com/v1/air-quality",
                           latLon(ctx) + [("current", "us_aqi,pm2_5,pm10,ozone,european_aqi")])["current"]
    }

    static func quakes(_ ctx: HubContext) async throws -> J {
        let d = try await Net.json("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson", timeout: 25)
        var out: [[String: Any]] = []
        for f in d["features"].array {
            let p = f["properties"], c = f["geometry"]["coordinates"]
            guard let mag = p["mag"].double, let time = p["time"].double else { continue }
            out.append(["t": time / 1000, "mag": mag, "place": p["place"].s(), "lat": c[1].d(), "lon": c[0].d(),
                        "depth": c[2].d(), "tsunami": p["tsunami"].int ?? 0])
        }
        out.sort { ($0["t"] as! Double) < ($1["t"] as! Double) }
        return J(out)
    }

    static func neo(_ ctx: HubContext) async throws -> J {
        let now = Date()
        var params: [(String, String)] = [
            ("date-min", ymd(now.addingTimeInterval(-7 * 86400))),
            ("date-max", ymd(now.addingTimeInterval(30 * 86400))),
            ("dist-max", "0.2"), ("fullname", "true"),
        ]
        let d: J
        do {
            d = try await Net.json("https://ssd-api.jpl.nasa.gov/cad.api", params)
        } catch {  // the API sometimes 502s on full names; designations still work
            params.removeLast()
            d = try await Net.json("https://ssd-api.jpl.nasa.gov/cad.api", params)
        }
        let fields = d["fields"].array.map { $0.s() }
        var rows: [[String: Any]] = []
        for r in d["data"].array {
            var row: [String: Any] = [:]
            for (i, f) in fields.enumerated() { row[f] = r[i].raw ?? NSNull() }
            let rj = J(row)
            row["jd"] = rj["jd"].d()
            row["dist"] = rj["dist"].d()
            row["v_rel"] = rj["v_rel"].d()
            row["h"] = rj["h"].double ?? NSNull()
            let full = rj["fullname"].s().trimmingCharacters(in: .whitespaces)
            row["name"] = full.isEmpty ? rj["des"].s() : full
            rows.append(row)
        }
        return J(rows)
    }

    static func iss(_ ctx: HubContext) async throws -> J {
        let d = try await Net.json("https://api.wheretheiss.at/v1/satellites/25544", timeout: 8)
        guard var out = d.raw as? [String: Any] else { throw HubError.message("bad ISS data") }
        let prev = ctx.get("iss")
        if prev.exists && prev["timestamp"].double != d["timestamp"].double {
            out["prev"] = [prev["latitude"].d(), prev["longitude"].d(), prev["timestamp"].d()]
        } else if prev.exists, let p = prev["prev"].raw {
            out["prev"] = p
        }
        return J(out)
    }

    static let issViewDeg = 3.2  // half-height of each imagery tile, degrees of latitude
    static let gibs = "https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi"

    /// NASA GIBS imagery under where the ISS is about to be (fallback for the live camera).
    static func isscam(_ ctx: HubContext) async throws -> J {
        let iss = ctx.get("iss")
        guard iss.exists, issMotion(iss) != nil else { return .null }  // waiting for two position fixes
        let now = Date().timeIntervalSince1970
        var (lat, lon) = issPosition(iss, now + 8)
        lat = max(-80, min(80, lat))
        let dlat = issViewDeg
        let dlon = issViewDeg / max(0.2, cos(Astro.rad(lat)))
        let bbox = [lon - dlon, lat - dlat, lon + dlon, lat + dlat]
        let s = Astro.sun(now)
        let sunAlt = Astro.altAz(ra: s.ra, dec: s.dec, lat: lat, lon: lon, ts: now).alt
        let night = sunAlt < -4
        let params: [(String, String)] = [
            ("SERVICE", "WMS"), ("REQUEST", "GetMap"), ("VERSION", "1.3.0"), ("STYLES", ""), ("CRS", "EPSG:4326"),
            ("BBOX", String(format: "%.4f,%.4f,%.4f,%.4f", bbox[1], bbox[0], bbox[3], bbox[2])),  // 1.3.0: lat,lon order
            ("WIDTH", "1024"), ("HEIGHT", "1024"), ("FORMAT", "image/jpeg"),
        ]
        var data = Data(), layer = ""
        if night {
            layer = "VIIRS Black Marble (city lights)"
            data = try await Net.bytes(gibs, params + [("LAYERS", "VIIRS_Black_Marble")])
        } else {
            for days in 1...3 {  // the newest daily mosaic may still be processing
                let day = ymd(Date().addingTimeInterval(-Double(days) * 86400))
                data = try await Net.bytes(gibs, params + [("LAYERS", "MODIS_Terra_CorrectedReflectance_TrueColor"), ("TIME", day)])
                layer = "MODIS Terra true color \(day)"
                if data.count > 20000 { break }
            }
        }
        return J(["jpg": data, "bbox": bbox, "layer": layer, "night": night, "t": now])
    }

    /// Current YouTube ID of NASA's official "Live High-Definition Views from the ISS" stream.
    static func issStream(_ ctx: HubContext) async throws -> J {
        let html = String(decoding: try await Net.bytes("https://www.youtube.com/@NASA/streams", timeout: 15,
                                                         headers: ["User-Agent": "Mozilla/5.0", "Accept-Language": "en-US"]),
                          as: UTF8.self)
        var ids: [String] = []
        for m in regexMatches("\"videoId\":\"([A-Za-z0-9_-]{11})\"", html) where !ids.contains(m[1]) {
            ids.append(m[1])
            if ids.count >= 12 { break }
        }
        for vid in ids {
            guard let title = try? await Net.json("https://www.youtube.com/oembed",
                                                  [("url", "https://www.youtube.com/watch?v=\(vid)"), ("format", "json")])["title"].string
            else { continue }  // unembeddable or private
            if title.contains("International Space Station") && title.contains("Live") {
                return J(["id": vid, "title": title])
            }
        }
        throw HubError.message("NASA ISS stream not found")
    }

    /// Last 3 hours of wind (15-minute) and last 24 hours of precipitation (hourly), Open-Meteo.
    static func history(_ ctx: HubContext) async throws -> J {
        let imp = ctx.imperial
        let d = try await Net.json("https://api.open-meteo.com/v1/forecast", latLon(ctx) + [
            ("timezone", "auto"),
            ("minutely_15", "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            ("past_minutely_15", "12"), ("forecast_minutely_15", "1"),
            ("hourly", "precipitation"), ("past_hours", "24"), ("forecast_hours", "1"),
            ("wind_speed_unit", imp ? "mph" : "kmh"),
            ("precipitation_unit", imp ? "inch" : "mm"),
        ])
        let m = d["minutely_15"], hr = d["hourly"]
        func list(_ j: J) -> [Any] { j.array.map { $0.raw ?? NSNull() } }
        return J(["wind_t": list(m["time"]), "wind": list(m["wind_speed_10m"]), "gust": list(m["wind_gusts_10m"]),
                  "wdir": list(m["wind_direction_10m"]),
                  "rain_t": Array(list(hr["time"]).dropLast()), "rain": Array(list(hr["precipitation"]).dropLast())])
    }

    static func space(_ ctx: HubContext) async throws -> J {
        let base = "https://services.swpc.noaa.gov/products/"
        let kp = try await Net.json(base + "noaa-planetary-k-index.json")
        var out: [String: Any] = ["kp": kp.last["Kp"].d(), "kp_time": kp.last["time_tag"].s()]
        for (name, key, path) in [("wind", "proton_speed", "summary/solar-wind-speed.json"),
                                  ("bz", "bz_gsm", "summary/solar-wind-mag-field.json"),
                                  ("bt", "bt", "summary/solar-wind-mag-field.json"),
                                  ("flux", "flux", "summary/10cm-flux.json")] {
            // Partial space weather is still useful.
            if let v = try? await Net.json(base + path) {
                let obj = v.count > 0 ? v[0] : v
                out[name] = obj[key].double ?? NSNull()
            } else {
                out[name] = NSNull()
            }
        }
        return J(out)
    }

    static func outages(_ ctx: HubContext) async throws -> J {
        let base = "https://ornl.opendatasoft.com/api/explore/v2.1/catalog/datasets/odin-real-time-outages-county"
        let rows = try await Net.json(base + "/exports/json", [("select", "communitydescriptor,metersaffected")], timeout: 25)
        var states: [String: Int] = [:]
        for r in rows.array {
            let code = String(r["communitydescriptor"].s().prefix(2))
            states[stateFIPS[code] ?? "??", default: 0] += r["metersaffected"].int ?? 0
        }
        let top = states.sorted { $0.value > $1.value }.prefix(5).map { [$0.key, $0.value] as [Any] }
        return J(["total": states.values.reduce(0, +), "incidents": rows.count, "states": top])
    }

    /// WisDOT 511 traffic cameras nearest to you (stills plus live HLS video).
    static func cameras(_ ctx: HubContext) async throws -> J {
        let loc = ctx.get("location")
        var rows: [J] = []
        var start = 0
        while start < 2000 {
            let query = "{\"columns\":[{\"data\":null,\"name\":\"\"},{\"name\":\"sortOrder\",\"s\":true}],"
                + "\"order\":[{\"column\":1,\"dir\":\"asc\"}],\"start\":\(start),\"length\":100,\"search\":{\"value\":\"\"}}"
            let d = try await Net.json("https://511wi.gov/List/GetData/Cameras", [("query", query), ("lang", "en-US")])
            rows += d["data"].array
            if start + 100 >= d["recordsTotal"].int ?? 0 { break }
            start += 100
        }
        var cams: [[String: Any]] = []
        for r in rows {
            let wkt = r["latLng"]["geography"]["wellKnownText"].s()
            guard let m = regexMatches("POINT \\(([-\\d.]+) ([-\\d.]+)\\)", wkt).first,
                  let lon = Double(m[1]), let lat = Double(m[2]) else { continue }
            let imgs = r["images"].array.filter { $0["disabled"].bool != true && $0["blocked"].bool != true }
            guard let img = imgs.first, let path = img["imageUrl"].string else { continue }
            let km = Astro.haversineKm(loc["lat"].d(), loc["lon"].d(), lat, lon)
            if km > radarMiles * 1.609 { continue }
            let video: Any = (img["videoDisabled"].bool != true && img["isVideoAuthRequired"].bool != true)
                ? (img["videoUrl"].string ?? NSNull()) : NSNull()
            let name = r["location"].string ?? r["roadway"].string ?? "Camera"
            cams.append(["name": name, "lat": lat, "lon": lon, "km": km, "image": "https://511wi.gov" + path, "video": video])
        }
        cams.sort { ($0["km"] as! Double) < ($1["km"] as! Double) }
        return J(Array(cams.prefix(16)))
    }

    /// NEXRAD base reflectivity composite (NOAA via Iowa Environmental Mesonet) for the scope.
    static func radar(_ ctx: HubContext) async throws -> J {
        let loc = ctx.get("location")
        let bbox = radarBBox(loc["lat"].d(), loc["lon"].d())
        let png = try await Net.bytes("https://mesonet.agron.iastate.edu/cgi-bin/wms/nexrad/n0q.cgi", [
            ("SERVICE", "WMS"), ("REQUEST", "GetMap"), ("VERSION", "1.1.1"), ("LAYERS", "nexrad-n0q-900913"),
            ("STYLES", ""), ("SRS", "EPSG:4326"), ("BBOX", bbox.map { String(format: "%.4f", $0) }.joined(separator: ",")),
            ("WIDTH", "1024"), ("HEIGHT", "1024"), ("FORMAT", "image/png"), ("TRANSPARENT", "true"),
        ])
        return J(["png": png, "bbox": bbox, "t": Date().timeIntervalSince1970])
    }

    private static func topoArcs(_ topo: J, _ bbox: [Double]) -> [[[Double]]] {
        let sx = topo["transform"]["scale"][0].d(), sy = topo["transform"]["scale"][1].d()
        let tx = topo["transform"]["translate"][0].d(), ty = topo["transform"]["translate"][1].d()
        var out: [[[Double]]] = []
        for arc in (topo["arcs"].raw as? [[[NSNumber]]]) ?? [] {
            var x = 0.0, y = 0.0
            var pts: [[Double]] = []
            pts.reserveCapacity(arc.count)
            var inside = false
            for p in arc where p.count >= 2 {
                x += p[0].doubleValue
                y += p[1].doubleValue
                let px = x * sx + tx, py = y * sy + ty
                pts.append([(px * 1e4).rounded() / 1e4, (py * 1e4).rounded() / 1e4])
                if bbox[0] <= px && px <= bbox[2] && bbox[1] <= py && py <= bbox[3] { inside = true }
            }
            if inside { out.append(pts) }
        }
        return out
    }

    /// State and county outlines (US Census via the us-atlas package) around you.
    static func borders(_ ctx: HubContext) async throws -> J {
        let loc = ctx.get("location")
        let bbox = radarBBox(loc["lat"].d(), loc["lon"].d(), miles: radarMiles * 1.5)
        let base = "https://cdn.jsdelivr.net/npm/us-atlas@3/"
        let states = topoArcs(try await Net.json(base + "states-10m.json", timeout: 30), bbox)
        let counties = topoArcs(try await Net.json(base + "counties-10m.json", timeout: 40), bbox)
        return J(["states": states, "counties": counties])
    }

    /// Camera snapshots, only for cameras whose live stream isn't playing.
    static func stills(_ ctx: HubContext) async throws -> J {
        var out = (ctx.get("stills").raw as? [String: Any]) ?? [:]
        let now = Date().timeIntervalSince1970
        for url in ctx.stillWanted.prefix(8) {
            if let got = out[url] as? [Any], let t = got.last as? Double, now - t < 60 { continue }
            if let data = try? await Net.bytes(url, timeout: 15) {  // keep the previous frame on failure
                out[url] = [data, Date().timeIntervalSince1970] as [Any]
            }
        }
        return J(out)
    }

    // MARK: Verse of the day

    static let usfmBooks = ("GEN EXO LEV NUM DEU JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST JOB PSA PRO ECC SNG ISA JER "
        + "LAM EZK DAN HOS JOL AMO OBA JON MIC NAM HAB ZEP HAG ZEC MAL MAT MRK LUK JHN ACT ROM 1CO 2CO GAL "
        + "EPH PHP COL 1TH 2TH 1TI 2TI TIT PHM HEB JAS 1PE 2PE 1JN 2JN 3JN JUD REV").split(separator: " ").map(String.init)
    static let bookNames = ["Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth", "1 Samuel",
                            "2 Samuel", "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra", "Nehemiah", "Esther", "Job",
                            "Psalms", "Proverbs", "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah", "Lamentations",
                            "Ezekiel", "Daniel", "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk",
                            "Zephaniah", "Haggai", "Zechariah", "Malachi", "Matthew", "Mark", "Luke", "John", "Acts", "Romans",
                            "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians", "Philippians", "Colossians",
                            "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus", "Philemon", "Hebrews",
                            "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John", "Jude", "Revelation"]

    /// Plain text of verses v1...v2 of one chapter from bolls.life (book numbered 1-66).
    private static func bollsText(_ translation: String, _ book: Int, _ chap: Int, _ v1: Int, _ v2: Int) async throws -> String {
        let verses = try await Net.json("https://bolls.life/get-text/\(translation)/\(book)/\(chap)/")
        let parts = verses.array.filter { v1 <= ($0["verse"].int ?? 0) && ($0["verse"].int ?? 0) <= v2 }.map { $0["text"].s() }
        let text = parts.map { replacing("<S>.*?</S>|<m>.*?</m>|<[^>]+>", in: $0, with: "") }.joined(separator: " ")
        return collapseSpaces(text)
    }

    /// The NET Bible's daily pick, with the ESV and the Hebrew or Greek original from bolls.life.
    static func votd(_ ctx: HubContext) async throws -> J {
        let verses = try await Net.json("https://labs.bible.org/api/", [("passage", "votd"), ("type", "json"), ("formatting", "plain")])
        let first = verses[0], last = verses.last
        let name = first["bookname"].s().replacingOccurrences(of: "Psalm ", with: "Psalms ")
            .trimmingCharacters(in: .whitespaces)
        let normalized = name == "Psalm" ? "Psalms" : name
        guard let bookIndex = bookNames.firstIndex(of: normalized) else { throw HubError.message("unknown book \(name)") }
        let book = bookIndex + 1
        let chap = first["chapter"].int ?? 1, v1 = first["verse"].int ?? 1
        let v2 = (last["chapter"].int == chap) ? (last["verse"].int ?? v1) : v1
        let passage = "\(usfmBooks[book - 1]).\(chap).\(v1)" + (v2 != v1 ? "-\(v2)" : "")
        let ref = "\(normalized == "Psalms" ? "Psalm" : normalized) \(chap):\(v1)" + (v2 != v1 ? "–\(v2)" : "")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        var out: [String: Any] = ["date": f.string(from: Date()), "passage": passage, "ref": ref]
        let netText = collapseSpaces(verses.array.map { $0["text"].s() }.joined(separator: " "))
        if let esv = try? await bollsText("ESV", book, chap, v1, v2), !esv.isEmpty {
            out["text"] = esv
            out["version"] = "ESV"
        } else {  // the NET text came with the pick
            out["text"] = netText
            out["version"] = "NET"
        }
        let hebrew = book <= 39
        do {
            out["orig"] = try await bollsText(hebrew ? "WLC" : "SBLGNT", book, chap, v1, v2)
            out["orig_lang"] = hebrew ? "Hebrew" : "Greek"
            out["orig_src"] = hebrew ? "Westminster Leningrad Codex" : "SBL Greek New Testament"
            out["rtl"] = hebrew
        } catch {  // English still shows
            out["orig_error"] = String(error.localizedDescription.prefix(60))
        }
        return J(out)
    }
}

// MARK: - Hub

/// Used only from the main thread (the drawing code and its own main-thread loop).
final class Hub {
    private static var instance: Hub?
    static let retrySeconds = 90.0
    static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenie/hud.json")

    /// The shared hub, reset if settings that change location-based data changed.
    static func shared(config: Config) -> Hub {
        let sig = [config.hudLocation, config.hudUnits, "3"]
        if let hub = instance, hub.signature == sig { return hub }
        let hub = Hub(signature: sig, hudLocation: config.hudLocation, hudUnits: config.hudUnits)
        instance?.users = 0
        instance = hub
        return hub
    }

    private struct Entry {
        var t: Double
        var data: J
        var loc: String?
    }

    let signature: [String]
    private let hudLocation: String
    private let hudUnits: String
    private var entries: [String: Entry] = [:]
    private var errors: [String: String] = [:]
    private var retry: [String: Double] = [:]
    private var inFlight: Set<String> = []
    private var users = 0
    private var loop: Task<Void, Never>?
    /// Camera snapshot URLs the renderer needs (the live stream isn't playing).
    var stillWanted: Set<String> = []

    private init(signature: [String], hudLocation: String, hudUnits: String) {
        self.signature = signature
        self.hudLocation = hudLocation
        self.hudUnits = hudUnits
        loadCache()
    }

    func get(_ name: String) -> J { entries[name]?.data ?? .null }
    func age(_ name: String) -> Double? { entries[name].map { Date().timeIntervalSince1970 - $0.t } }
    func fetchedAt(_ name: String) -> Double? { entries[name]?.t }
    func error(_ name: String) -> String? { errors[name] }

    var imperial: Bool {
        if hudUnits != "auto" { return hudUnits == "imperial" }
        let country = get("location")["country"].string ?? "US"
        return ["US", "LR", "MM", ""].contains(country)
    }

    private var locKey: String? {
        let loc = get("location")
        guard let lat = loc["lat"].double, let lon = loc["lon"].double else { return nil }
        return String(format: "%.3f,%.3f", lat, lon)
    }

    /// Fetching runs only while at least one HUD is on screen.
    func retain() {
        users += 1
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while let hub = self, hub.users > 0, !Task.isCancelled {
                hub.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.loop = nil
        }
    }

    func release() {
        users = max(0, users - 1)
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        let loc = locKey
        for (name, src) in Sources.all {
            if src.needsLocation && loc == nil { continue }
            if inFlight.contains(name) || now < retry[name, default: 0] { continue }
            let e = entries[name]
            let due = e == nil || now - e!.t > src.interval || (src.needsLocation && e!.loc != loc)
            guard due else { continue }
            inFlight.insert(name)
            let ctx = HubContext(entries: entries.mapValues(\.data), hudLocation: hudLocation, imperial: imperial,
                                 stillWanted: Array(stillWanted))
            let fn = src.fn
            let hub = self
            Task.detached(priority: .utility) {
                let result: Result<J, Error>
                do { result = .success(try await fn(ctx)) } catch { result = .failure(error) }
                let cached = src.cached
                await MainActor.run { hub.finish(name, result, loc: loc, cached: cached) }
            }
        }
    }

    private func finish(_ name: String, _ result: Result<J, Error>, loc: String?, cached: Bool) {
        inFlight.remove(name)
        switch result {
        case .success(let data):
            entries[name] = Entry(t: Date().timeIntervalSince1970, data: data, loc: loc)
            errors[name] = nil
            if cached { saveCache() }
        case .failure(let err):
            errors[name] = String(err.localizedDescription.prefix(80))
            retry[name] = Date().timeIntervalSince1970 + Self.retrySeconds
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["_sig"] as? [String]) == signature else { return }
        for (name, value) in obj where name != "_sig" {
            guard let e = value as? [String: Any], let t = e["t"] as? Double else { continue }
            entries[name] = Entry(t: t, data: J(e["data"]), loc: e["loc"] as? String)
        }
    }

    private func saveCache() {
        let cachedNames = Set(Sources.all.filter { $0.1.cached }.map(\.0))
        var obj: [String: Any] = ["_sig": signature]
        for (name, e) in entries where cachedNames.contains(name) {
            obj[name] = ["t": e.t, "data": e.data.raw ?? NSNull(), "loc": e.loc ?? NSNull()] as [String: Any]
        }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}
