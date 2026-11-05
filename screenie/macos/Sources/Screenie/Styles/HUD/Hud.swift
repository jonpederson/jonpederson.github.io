import AppKit
import SwiftUI

/// HUD style: a full-screen dashboard of live and computed data (port of `hud.py`).
///
/// Panels are laid out masonry-style in columns sized to the screen and re-rendered one
/// panel per frame into cached bitmaps; so are the radar scope's base, the verse and the
/// seismograph trace (once a second). The header clock (with milliseconds), the radar
/// sweep, the cameras and the ISS view are drawn every frame.
final class HudStyle: SaverStyle {
    var drawsOwnClock: Bool { true }

    static let seisWindow = 3600.0  // seconds of seismograph visible across the screen
    static let camPageSeconds = 90.0

    // Palette
    static let BG = "#03070c", TITLE = "#ffb347", LABEL = "#5f8798", VALUE = "#c4f1ff", BRIGHT = "#6fe3ff"
    static let WARN = "#ff6b6b", GOOD = "#7dffa0", DIM = "#2b4a58", PHOSPHOR = "#4dff9a", SCOPE_BG = "#03100a"
    static let NA = "—"

    static func c(_ hex: String, _ a: CGFloat = 1) -> CGColor { cgColor(hex: hex, alpha: a) }

    typealias Line = (label: String?, value: String, color: String)

    struct Panel {
        let title: String
        let source: String?
        var lines: Int
        let fn: (HudStyle, Double) -> [Line]
    }

    let overlay = HudOverlayModel()
    let hub: Hub
    let started = Date().timeIntervalSince1970
    var panels: [Panel] = []
    let camIndex: Int
    let issIndex: Int

    // Layout
    private(set) var size = CGSize.zero
    private(set) var scale: CGFloat = 0
    var m: CGFloat = 0
    var headerH: CGFloat = 0
    var seisH: CGFloat = 0
    var lineH: CGFloat = 0
    var font: CTFont = Painter.mono(12)
    var small: CTFont = Painter.mono(10)
    var big: CTFont = Painter.mono(40)
    var mid: CTFont = Painter.mono(18)
    var geom: [Int: CGRect] = [:]
    var verseBox: CGRect?
    var windBox = CGRect.zero
    var scopeC = CGPoint.zero
    var scopeR: CGFloat = 0
    var gauge = CGRect.zero

    // Caches
    private var panelImages: [Int: CGImage] = [:]
    private var nextPanel = 0
    private var scopeImage: (key: String, image: CGImage?, rect: CGRect)?
    private var radarImage: CGImage?
    private var radarT: Double?
    private var verseImage: (key: String, image: CGImage?)?
    private var seisCache: [Int: Double] = [:]
    private var seisFeedKey: String?
    private var seisImage: CGImage?
    private var seisBuiltFor: Int?
    private var streams: [String: CameraStream] = [:]
    private var stillImages: [String: (fetched: Double, image: CGImage)] = [:]
    private var issImages: [(t: Double, image: CGImage, data: J)] = []

    init(config: Config) {
        hub = Hub.shared(config: config)
        panels = [
            Panel(title: "LOCATION", source: "location", lines: 7) { $0.pLocation($1) },
            Panel(title: "WEATHER", source: "weather", lines: 8) { $0.pWeather($1) },
            Panel(title: "FORECAST", source: "weather", lines: 8) { $0.pForecast($1) },
            Panel(title: "GRAVITY  G vs g", source: nil, lines: 8) { $0.pGravity($1) },
            Panel(title: "MOTION  GALILEAN FRAMES", source: nil, lines: 7) { $0.pMotion($1) },
            Panel(title: "SUN & MOON", source: nil, lines: 8) { $0.pSunMoon($1) },
            Panel(title: "NEAREST NEO", source: "neo", lines: 7) { $0.pNeo($1) },
            Panel(title: "ISS", source: "iss", lines: 6) { $0.pISS($1) },
            Panel(title: "SPACE WEATHER", source: "space", lines: 5) { $0.pSpace($1) },
            Panel(title: "US POWER OUTAGES", source: "outages", lines: 7) { $0.pOutages($1) },
            Panel(title: "SEISMIC  24H", source: "quakes", lines: 6) { $0.pSeismic($1) },
            Panel(title: "CHRONO", source: nil, lines: 7) { $0.pChrono($1) },
            Panel(title: "THIS MACHINE", source: nil, lines: 5) { $0.pMachine($1) },
            Panel(title: "CAMERAS  WisDOT 511", source: "cameras", lines: 12) { $0.pCameras($1) },
            Panel(title: "ISS CAMERA", source: "isscam", lines: 10) { _, _ in [] },
        ]
        camIndex = panels.count - 2
        issIndex = panels.count - 1
        hub.retain()
    }

    deinit {
        streams.values.forEach { $0.stop() }
        hub.release()
    }

    var imperial: Bool { hub.imperial }

    // MARK: Layout

    private func setup(_ size: CGSize, _ scale: CGFloat) {
        self.size = size
        self.scale = scale
        let w = size.width, h = size.height
        panelImages = [:]
        seisImage = nil
        seisBuiltFor = nil
        scopeImage = nil
        verseImage = nil
        m = (h * 0.03).rounded()
        headerH = h * 0.115
        seisH = h * 0.12
        let top = m + headerH + m * 0.5
        let bottom = h - m - seisH - m * 0.6
        let mainH = bottom - top

        // Right: the radar scope at full height, nothing on top of it. Rain gauge just left of it.
        let labelRoom = h * 0.03  // bearing labels around the ring
        let r = min(mainH / 2 - labelRoom, w * 0.22)
        scopeC = CGPoint(x: w - m - labelRoom - r, y: top + mainH / 2)
        scopeR = r
        let gaugeW = h * 0.07
        let gaugeX = scopeC.x - r - labelRoom - m - gaugeW
        gauge = CGRect(x: gaugeX, y: top, width: gaugeW, height: mainH)

        // Left: masonry columns of panels.
        let panelsW = gaugeX - m - m
        let ncols = max(2, min(6, Int((panelsW / (h * 0.36)).rounded())))
        let gap = m * 0.8
        let colW = (panelsW - gap * CGFloat(ncols - 1)) / CGFloat(ncols)

        let lhGuess = h * 0.022
        let cellW = (colW - lhGuess * 1.2) / 2
        let camH = 2 * (cellW * 240 / 352 + lhGuess * 1.1) + lhGuess * 0.4
        let issH = (colW - lhGuess * 0.8) * 9 / 16 + lhGuess * 1.3
        panels[camIndex].lines = Int((camH / lhGuess).rounded(.up))
        panels[issIndex].lines = Int((issH / lhGuess).rounded(.up))

        var heights = [CGFloat](repeating: 0, count: ncols)
        var cols = [[Int]](repeating: [], count: ncols)
        for (i, p) in panels.enumerated() {
            let c = heights.firstIndex(of: heights.min()!)!
            cols[c].append(i)
            heights[c] += CGFloat(p.lines) + 2.2  // title + padding, in line units
        }
        let units = heights.max()!
        lineH = min(h * 0.028, mainH / units)
        font = Painter.mono(lineH * 0.74)
        small = Painter.mono(lineH * 0.6)
        geom = [:]
        var colBottom: [CGFloat] = []
        for (c, idxs) in cols.enumerated() {
            var y = top
            for i in idxs {
                let ph = (CGFloat(panels[i].lines) + 1.6) * lineH
                geom[i] = CGRect(x: m + CGFloat(c) * (colW + gap), y: y, width: colW, height: ph)
                y += ph + 0.6 * lineH
            }
            colBottom.append(y)
        }

        // Verse of the day: the biggest open rectangle under the shorter columns.
        verseBox = nil
        var best: CGFloat = 0
        for a in 0..<ncols {
            for b in a..<ncols {
                let freeTop = colBottom[a...b].max()! + lineH * 0.2
                let fh = bottom - freeTop
                let fw = CGFloat(b - a + 1) * colW + CGFloat(b - a) * gap
                if fh >= lineH * 4.5 && fw * fh > best {
                    best = fw * fh
                    verseBox = CGRect(x: m + CGFloat(a) * (colW + gap), y: freeTop, width: fw, height: fh)
                }
            }
        }
        big = Painter.mono(headerH * 0.46)
        mid = Painter.mono(headerH * 0.2)

        // Header middle: wind graph between the clock and the location block.
        let leftEnd = m + Painter.measure("UTC 0000-00-00 00:00:00.000", big).width + m * 1.5
        let rightW = max(Painter.measure("XXXXXXXX+XX", big).width, Painter.measure(String(repeating: "X", count: 38), mid).width)
        let rightStart = w - m - rightW - m * 1.5
        windBox = CGRect(x: leftEnd, y: m * 0.6, width: max(rightStart - leftEnd, 0), height: headerH * 0.95)
    }

    // MARK: Frame

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, scale: CGFloat) {
        if size != self.size || scale != self.scale { setup(size, scale) }
        let now = Date().timeIntervalSince1970

        // Refresh one panel per frame (all of them on the first frame).
        let todo = panelImages.isEmpty ? Array(panels.indices) : [nextPanel]
        for i in todo { panelImages[i] = buildPanel(i, now) }
        nextPanel = (nextPanel + 1) % panels.count

        let jx = 6 * sin(t * 0.009), jy = 6 * cos(t * 0.013)  // slow drift against burn-in
        ctx.withCGContext { cg in
            let p = Painter(cg)
            p.fill(CGRect(origin: .zero, size: size), Self.c(Self.BG))
            cg.translateBy(x: jx, y: jy)
            scope(p, t, now)
            for (i, img) in panelImages {
                if let r = geom[i] { p.image(img, r) }
            }
            cameras(p, now)
            issView(p, t, now)
            rainGauge(p, t)
            verse(p)
            header(p, size.width, now)
            windGraph(p)
            seismograph(p, size.width, size.height, now)
        }
    }

    // MARK: Header

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func header(_ p: Painter, _ w: CGFloat, _ now: Double) {
        let date = Date(timeIntervalSince1970: now)
        let ms = String(format: ".%03d", Int((now - now.rounded(.down)) * 1000))
        p.text("UTC", m, m + headerH * 0.04, Self.c(Self.TITLE), mid)
        let lw = Painter.measure("UTC ", mid).width
        p.text(Self.utcFormatter.string(from: date) + ms, m + lw, m - headerH * 0.04, Self.c(Self.BRIGHT), big)
        let tz = TimeZone.current
        let offset = tz.secondsFromGMT(for: date)
        let off = String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        p.text("LOCAL \(Self.localFormatter.string(from: date))\(ms)  \(tz.abbreviation(for: date) ?? "")  UTC\(off)",
               m, m + headerH * 0.62, Self.c(Self.VALUE), mid)

        let loc = hub.get("location")
        let wx = hub.get("weather")["current"]
        let right = w - m
        var place = [loc["city"].s(), loc["region"].s()].filter { !$0.isEmpty }.joined(separator: ", ").uppercased()
        if place.isEmpty { place = "LOCATING…" }
        if let temp = wx["temperature_2m"].double {
            let u = imperial ? "°F" : "°C"
            place += String(format: "   %.0f%@ ", temp, u) + (Self.wmo[wx["weather_code"].int ?? -1] ?? "").uppercased()
        }
        p.text(place, right - w * 0.5, m + headerH * 0.04, Self.c(Self.VALUE), mid, width: w * 0.5, align: .right)
        if let lat = loc["lat"].double, let lon = loc["lon"].double {
            p.text(Astro.plusCode(lat, lon), right - w * 0.5, m + headerH * 0.3, Self.c(Self.BRIGHT), big,
                   width: w * 0.5, align: .right)
        }
    }

    // MARK: Panels

    static func ago(_ seconds: Double?) -> String {
        guard let s = seconds else { return "loading…" }
        if s < 60 { return "live" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3600))h ago"
    }

    private func corners(_ p: Painter, _ w: CGFloat, _ h: CGFloat, _ th: CGFloat, _ arm: CGFloat) {
        let c = Self.c(Self.DIM)
        for (x, y, sx, sy) in [(0, 0, 1.0, 1.0), (w, 0, -1.0, 1.0), (0, h, 1.0, -1.0), (w, h, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            p.fill(min(x, x + sx * arm), y - (sy < 0 ? th : 0), arm, th, c)
            p.fill(x - (sx < 0 ? th : 0), min(y, y + sy * arm), th, arm, c)
        }
    }

    private func buildPanel(_ i: Int, _ now: Double) -> CGImage? {
        guard let g = geom[i] else { return nil }
        let panel = panels[i]
        let pw = g.width, ph = g.height
        let lh = lineH
        let lines = panel.fn(self, now)
        return Painter.render(size: g.size, scale: scale) { p in
            p.fill(0, 0, pw, ph, Self.c(Self.BG, 0.66))
            let th = max(1.0, lh / 14), arm = lh * 0.6
            corners(p, pw, ph, th, arm)
            let pad = lh * 0.4
            p.text(panel.title, pad, pad * 0.6, Self.c(Self.TITLE), small)
            if let source = panel.source {
                var status = Self.ago(hub.age(source))
                if hub.error(source) != nil && hub.get(source).isNull { status = "offline" }
                p.text(status, pw - pad - pw * 0.4, pad * 0.6, Self.c(status == "offline" ? Self.WARN : Self.LABEL), small,
                       width: pw * 0.4, align: .right)
            }
            p.fill(pad, lh * 1.25, pw - 2 * pad, th, Self.c(Self.DIM, 0.6))

            var y = lh * 1.45
            let inner = pw - 2 * pad
            for line in lines.prefix(panel.lines) {
                if let label = line.label {
                    let lab = p.text(label, pad, y, Self.c(Self.LABEL), small, width: inner * 0.45)
                    let lw = min(lab.width, inner * 0.45) + lh * 0.5
                    p.text(line.value, pad + lw, y + lineH * 0.02, Self.c(line.color), font, width: inner - lw, align: .right)
                } else {
                    p.text(line.value, pad, y, Self.c(line.color), font, width: inner)
                }
                y += lh
            }
        }
    }

    // MARK: Seismograph

    private func seisValue(_ s: Int, _ quakes: [J], _ times: [Double]) -> Double {
        if let v = seisCache[s] { return v }
        let n = Double((((s &* 2_654_435_761) ^ ((s >> 3) &* 40503)) & 0xFFFF)) / 32768.0 - 1.0
        let sd = Double(s)
        var v = n * 0.03 + 0.025 * sin(sd * 2 * .pi / 6.3) + 0.012 * sin(sd * 2 * .pi / 17.0)
        let lo = Self.bisectLeft(times, sd - 600), hi = Self.bisectRight(times, sd)
        if lo < hi {
            for q in quakes[lo..<hi] {
                let mag = max(q["mag"].d(), 0)
                let qt = q["t"].d()
                let dur = 30 + 25 * pow(mag, 1.5)
                let k = sd - qt
                if k < 0 || k > dur { continue }
                let amp = min(1.3, 0.015 * pow(2.1, mag))
                let pw = 0.35 * amp * exp(-k / (0.12 * dur))
                let ks = 0.22 * dur
                let sw = k >= ks ? amp * exp(-(k - ks) / (0.3 * dur)) * min(1.0, (k - ks) / 4) : 0
                v += (pw + sw) * sin(k * 2.6 + qt) * (0.7 + 0.3 * n)
            }
        }
        v = max(-1, min(1, v))
        seisCache[s] = v
        return v
    }

    static func bisectLeft(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] < x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    static func bisectRight(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    private func seismograph(_ p: Painter, _ w: CGFloat, _ h: CGFloat, _ now: Double) {
        let x0 = m, x1 = w - m
        let y0 = h - m - seisH
        let sh = seisH
        let mid = y0 + sh * 0.6
        let amp = sh * 0.36
        let pps = (x1 - x0) / Self.seisWindow
        let quakes = hub.get("quakes").array
        let times = quakes.map { $0["t"].d() }
        let feedT = hub.age("quakes")
        let feedKey = "\(quakes.count):\(times.last ?? 0)"
        if feedKey != seisFeedKey {
            seisFeedKey = feedKey
            seisCache = [:]
            seisBuiltFor = nil
        }

        let s0 = Int(now)
        if seisBuiltFor != s0 {
            seisBuiltFor = s0
            seisImage = buildSeis(s0, quakes, times, y0: y0, sh: sh, mid: mid, amp: amp, pps: pps)
            seisCache = seisCache.filter { $0.key >= s0 - Int(Self.seisWindow) - 70 }
        }

        // Frame + static labels
        p.fill(x0, y0, x1 - x0, sh, Self.c(Self.BG, 0.8))
        p.fill(x0, y0, x1 - x0, 1, Self.c(Self.DIM, 0.8))
        p.fill(x0, y0 + sh, x1 - x0, 1, Self.c(Self.DIM, 0.8))
        p.text("GLOBAL SEISMIC ACTIVITY", x0, y0 + sh * 0.03, Self.c(Self.TITLE), small)
        let n = times.filter { $0 > now - Self.seisWindow }.count
        let status = (feedT == nil && hub.error("quakes") != nil) ? "offline" : Self.ago(feedT)
        p.text("USGS · \(n) events in last 60 min · trace synthesized from event catalog · \(status)",
               x1 - w * 0.6, y0 + sh * 0.03, Self.c(Self.LABEL), small, width: w * 0.6, align: .right)

        // The trace scrolls continuously between one-second rebuilds.
        let span = (Self.seisWindow + 60) * pps
        if let img = seisImage {
            p.with(clip: CGPath(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: sh), transform: nil)) {
                p.image(img, CGRect(x: x1 - (now - Double(s0)) * pps - span, y: y0, width: span, height: sh))
            }
        }
        // Pen
        let penY = mid - seisValue(s0, quakes, times) * amp
        p.fillCircle(x1, penY, lineH * 0.2, Self.c(Self.BRIGHT))
    }

    /// Trace, ticks and event labels for the hour up to second s0, as one bitmap whose
    /// right edge is s0.
    private func buildSeis(_ s0: Int, _ quakes: [J], _ times: [Double], y0: CGFloat, sh: CGFloat,
                           mid: CGFloat, amp: CGFloat, pps: CGFloat) -> CGImage? {
        let spanS = Self.seisWindow + 60
        let spanW = spanS * pps
        let lh = lineH
        // Work out the trace first (it fills the value cache).
        var pts: [CGPoint] = []
        let step = pps < 1 ? max(1, Int(1 / pps)) : 1
        var s = s0 - Int(spanS)
        while s <= s0 {
            pts.append(CGPoint(x: CGFloat(s - s0) * pps, y: mid - seisValue(s, quakes, times) * amp))
            s += step
        }
        return Painter.render(size: CGSize(width: spanW, height: sh), scale: scale) { p in
            p.cg.translateBy(x: spanW, y: -y0)
            // baseline and 10-minute ticks
            p.fill(-spanW, mid, spanW, 1, Self.c(Self.DIM, 0.5))
            let firstTick = (s0 - Int(Self.seisWindow)) / 600 * 600
            var ts = firstTick
            while ts <= s0 {
                let x = CGFloat(ts - s0) * pps
                p.fill(x, y0 + sh * 0.2, 1, sh * 0.8, Self.c(Self.DIM, 0.45))
                let f = DateFormatter()
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "HH:mm'Z'"
                p.text(f.string(from: Date(timeIntervalSince1970: Double(ts))), x + 4, y0 + sh - lh * 0.85,
                       Self.c(Self.LABEL), small)
                ts += 600
            }
            let path = CGMutablePath()
            for (i, pt) in pts.enumerated() {
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            p.stroke(path, max(1.2, lh / 16), Self.c(Self.BRIGHT, 0.9))

            // Label the biggest events in view without overlapping.
            let visible = quakes.filter { $0["t"].d() > Double(s0) - Self.seisWindow }
            var placed: [(x: CGFloat, w: CGFloat, row: Int)] = []
            for q in visible.sorted(by: { $0["mag"].d() > $1["mag"].d() }).prefix(12) {
                let mag = q["mag"].d()
                if mag < 1.5 && !placed.isEmpty { break }
                let x = CGFloat(q["t"].d() - Double(s0)) * pps
                let placeName = q["place"].s()
                let short = placeName.components(separatedBy: " of ").last ?? placeName
                let text = String(format: "M%.1f ", mag) + short
                let tw = Painter.measure(text, small).width
                for row in 0..<2 {
                    let clear = placed.allSatisfy { !($0.row == row && x < $0.x + $0.w + 12 && $0.x < x + tw + 12) }
                    if clear {
                        placed.append((x, tw, row))
                        let ly = y0 + sh * (0.15 + CGFloat(row) * 0.1)
                        let color = mag >= 5 ? Self.WARN : mag >= 3.5 ? Self.TITLE : Self.VALUE
                        p.fill(x, ly + lh * 0.7, 1, mid - ly - lh * 0.7, Self.c(color, 0.5))
                        p.text(text, x + 4, ly, Self.c(color), small)
                        break
                    }
                }
            }
        }
    }

    // MARK: Cameras

    private func camPage(_ now: Double) -> [J] {
        let cams = hub.get("cameras").array
        guard !cams.isEmpty else { return [] }
        let pages = max(1, min(2, Int((Double(cams.count) / 4).rounded(.up))))  // rotate through the nearest 8
        let page = Int(now / Self.camPageSeconds) % pages
        return Array(cams.dropFirst(page * 4).prefix(4))
    }

    private func camCells() -> [CGRect] {
        guard let g = geom[camIndex] else { return [] }
        let lh = lineH, pad = lh * 0.4
        let top = g.minY + lh * 1.45
        let cw = (g.width - pad * 3) / 2
        let ch = (g.maxY - pad - top - pad) / 2
        return (0..<4).map { i in
            CGRect(x: g.minX + pad + CGFloat(i % 2) * (cw + pad), y: top + CGFloat(i / 2) * (ch + pad), width: cw, height: ch)
        }
    }

    private func still(_ url: String) -> CGImage? {
        let got = hub.get("stills")[url]
        guard let data = got[0].data, let fetched = got[1].double else { return nil }
        if let cached = stillImages[url], cached.fetched == fetched { return cached.image }
        guard let img = Painter.decodeImage(data) else { return nil }
        stillImages[url] = (fetched, img)
        return img
    }

    private func cameras(_ p: Painter, _ now: Double) {
        let page = camPage(now)
        let wanted = Set(page.compactMap { $0["video"].string })
        for url in streams.keys where !wanted.contains(url) {  // stop streams that rotated away
            streams.removeValue(forKey: url)?.stop()
        }
        let lh = lineH
        for (cam, cell) in zip(page, camCells()) {
            let x = cell.minX, y = cell.minY, cw = cell.width, ch = cell.height
            let vh = ch - lh * 1.05
            p.fill(x, y, cw, vh, Self.c("#000000", 0.85))
            var live = false
            var frame: CGImage?
            let image = cam["image"].s()
            if let video = cam["video"].string {
                if streams[video] == nil, let s = CameraStream(urlString: video, now: now) {
                    streams[video] = s
                    hub.stillWanted.insert(image)  // something to show while connecting
                }
                if let s = streams[video] {
                    if !s.failed, let f = s.currentFrame() {
                        frame = f
                        live = true
                        hub.stillWanted.remove(image)
                    } else if s.failed || now - s.started > 20 {
                        hub.stillWanted.insert(image)
                    }
                }
            } else {
                hub.stillWanted.insert(image)
            }
            if frame == nil { frame = still(image) }
            if let f = frame {
                let iw = CGFloat(f.width), ih = CGFloat(f.height)
                let s = min(cw / iw, vh / ih)
                let dw = iw * s, dh = ih * s
                p.image(f, CGRect(x: x + (cw - dw) / 2, y: y + (vh - dh) / 2, width: dw, height: dh))
            } else {
                p.text("CONNECTING…", x, y + vh / 2 - lh / 2, Self.c(Self.LABEL), small, width: cw, align: .center)
            }
            let (tag, col) = live ? ("● LIVE", Self.WARN) : ("STILL", Self.LABEL)
            p.text(tag, x + lh * 0.3, y + lh * 0.2, Self.c(col), small, alpha: 0.9)
            p.text(cam["name"].s("Camera"), x, y + vh + lh * 0.1, Self.c(Self.VALUE), small, width: cw * 0.72)
            p.text(dist(cam["km"].d()), x + cw * 0.72, y + vh + lh * 0.1, Self.c(Self.LABEL), small, width: cw * 0.28, align: .right)
        }
    }

    // MARK: ISS camera

    private func issRect() -> CGRect {
        guard let g = geom[issIndex] else { return .zero }
        let lh = lineH, pad = lh * 0.4
        let top = g.minY + lh * 1.45
        let vw = g.width - 2 * pad
        let vh = min(vw * 9 / 16, g.maxY - pad - lh * 1.0 - top)
        return CGRect(x: g.minX + pad, y: top, width: vw, height: vh)
    }

    private func issView(_ p: Painter, _ t: Double, _ now: Double) {
        let r = issRect()
        let x = r.minX, y = r.minY, vw = r.width, vh = r.height
        let lh = lineH
        // NASA's live stream, shown by a web view above the canvas.
        let stream = hub.get("iss_stream")["id"].string
        overlay.update(streamID: stream, rect: r.integral)
        if stream != nil {
            p.fill(r, Self.c("#000000"))
            p.text("NASA LIVE · Official ISS HD Earth view (YouTube)", x, y + vh + lh * 0.1, Self.c(Self.LABEL), small, width: vw)
            return
        }

        // Fallback: real NASA imagery panned under the ISS's live position, travel direction up.
        p.fill(r, Self.c("#000000"))
        let cam = hub.get("isscam")
        if let jpg = cam["jpg"].data, let ct = cam["t"].double, issImages.last?.t != ct, let img = Painter.decodeImage(jpg) {
            issImages = Array((issImages + [(ct, img, cam)]).suffix(2))
        }
        let iss = hub.get("iss")
        if issImages.isEmpty || issMotion(iss) == nil {
            p.text("ACQUIRING ISS…", x, y + vh / 2 - lh / 2, Self.c(Self.LABEL), small, width: vw, align: .center)
        } else if let motion = issMotion(iss) {
            let (plat, plon) = issPosition(iss, now)
            let coslat = max(0.2, cos(Astro.rad(plat)))
            let heading = Astro.deg(atan2(motion.dlon * coslat, motion.dlat))
            let ppd = vh / 2.4  // points per degree of latitude: ~270 km tall view
            p.with(clip: CGPath(rect: r, transform: nil)) {
                p.cg.saveGState()
                p.cg.translateBy(x: x + vw / 2, y: y + vh / 2)
                p.cg.rotate(by: -Astro.rad(heading))
                for (k, item) in issImages.enumerated() {
                    let b = item.data["bbox"]
                    let lon0 = b[0].d(), lat0 = b[1].d(), lon1 = b[2].d(), lat1 = b[3].d()
                    let dlon = Astro.mod(lon0 - plon + 540, 360) - 180
                    let rr = CGRect(x: dlon * coslat * ppd, y: -(lat1 - plat) * ppd,
                                    width: (lon1 - lon0) * coslat * ppd, height: (lat1 - lat0) * ppd)
                    let fade = k == 0 ? 1.0 : min(1.0, (now - item.t) / 2.0)
                    p.image(item.image, rr, alpha: fade)
                }
                p.cg.restoreGState()
                // porthole vignette and reticle
                for edge in 0..<6 {
                    let a = 0.12 * CGFloat(6 - edge) / 6
                    p.fill(x, y + CGFloat(edge) * lh * 0.15, vw, lh * 0.15, Self.c("#000000", a))
                    p.fill(x, y + vh - CGFloat(edge + 1) * lh * 0.15, vw, lh * 0.15, Self.c("#000000", a))
                }
                let cx = x + vw / 2, cy = y + vh / 2, c = lh * 0.8
                for (dx, dy, ww, hh) in [(-c, 0, c * 0.6, 1.2), (c * 0.4, 0, c * 0.6, 1.2), (0, -c, 1.2, c * 0.6), (0, c * 0.4, 1.2, c * 0.6)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                    p.fill(cx + dx, cy + dy, ww, hh, Self.c(Self.BRIGHT, 0.6))
                }
            }
            let data = issImages[issImages.count - 1].data
            let mode = data["night"].bool == true ? "NIGHT" : "DAY"
            let speed = iss["velocity"].d() * (imperial ? 0.621371 : 1)
            p.fill(x, y, vw, lh, Self.c("#000000", 0.55))
            let pos = String(format: "%@ · %.2f°%@ %.2f°%@ · HDG %03.0f° · ", mode, abs(plat), plat >= 0 ? "N" : "S",
                             abs(plon), plon >= 0 ? "E" : "W", Astro.mod(heading, 360))
            p.text(pos + Fmt.commas(speed, 0) + (imperial ? " mph" : " km/h"), x + lh * 0.3, y + lh * 0.2,
                   Self.c(Self.BRIGHT), small, width: vw - lh * 0.6)
            if Int(t * 1.2) % 2 == 0 {
                p.text("● TRACKING", x + vw - lh * 4.6, y + vh - lh * 0.9, Self.c(Self.WARN), small)
            }
        }
        let layer = issImages.last?.data["layer"].string ?? "NASA GIBS"
        p.text("SIMULATED view from \(layer) · live stream unavailable", x, y + vh + lh * 0.1, Self.c(Self.LABEL), small, width: vw)
    }

    // MARK: Rain gauge

    private func rainGauge(_ p: Painter, _ t: Double) {
        let gx = gauge.minX, gy = gauge.minY, gw = gauge.width, gh = gauge.height
        let lh = lineH
        let hist = hub.get("history")
        let imp = imperial
        let unit = imp ? "in" : "mm"
        let total = hist["rain"].array.reduce(0) { $0 + $1.d() }
        p.text("RAIN", gx, gy, Self.c(Self.TITLE), small, width: gw, align: .center)
        p.text("24H", gx, gy + lh * 0.75, Self.c(Self.LABEL), small, width: gw, align: .center)
        let tx = gx + gw * 0.42, tw = gw * 0.4
        let ty = gy + lh * 2.0, th = gh - lh * 4.6
        guard th > tw else { return }
        // scale: a round number comfortably above the total
        let steps: [Double] = imp ? [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12] : [5, 10, 20, 30, 50, 75, 100, 150, 250]
        let full = steps.first { total <= $0 * 0.85 } ?? steps[steps.count - 1]
        let glassRect = CGRect(x: tx, y: ty, width: tw, height: th)
        let glass = CGPath(roundedRect: glassRect, cornerWidth: tw / 2, cornerHeight: tw / 2, transform: nil)
        p.with(clip: glass) {
            p.fill(glassRect, Self.c(Self.BRIGHT, 0.06))
            let level = min(1.0, total / full)
            let wh = th * level
            if wh > 0 {
                let wave = sin(t * 2.2) * min(lh * 0.08, wh / 2)
                p.fill(tx, ty + th - wh + wave, tw, wh - wave, Self.c("#3d8bff", 0.85))
                p.fill(tx, ty + th - wh + wave, tw, max(1.5, lh * 0.06), Self.c("#9cc8ff", 0.9))
            }
        }
        p.stroke(glass, 1.5, Self.c(Self.BRIGHT, 0.55))
        // graduations
        for k in 0...10 {
            let yk = ty + th - th * CGFloat(k) / 10
            let major = k % 5 == 0
            let len = major ? lh * 0.5 : lh * 0.28
            p.fill(tx - len, yk, len, 1.2, Self.c(Self.BRIGHT, major ? 0.6 : 0.3))
            if major {
                let label = String(format: "%g", full * Double(k) / 10)
                let lw = Painter.measure(label, small).width
                p.text(label, tx - lh * 0.6 - lw, yk - lh * 0.35, Self.c(Self.LABEL), small)
            }
        }
        let amount = String(format: imp ? "%.2f" : "%.1f", total)
        p.text("\(amount) \(unit)", gx - lh, ty + th + lh * 0.5, Self.c(total > 0 ? Self.BRIGHT : Self.VALUE), font,
               width: gw + 2 * lh, align: .center)
        p.text("model est.", gx - lh, ty + th + lh * 1.4, Self.c(Self.LABEL), small, width: gw + 2 * lh, align: .center)
    }

    // MARK: Verse of the day

    private func verse(_ p: Painter) {
        guard let box = verseBox else { return }
        let key = "\(hub.fetchedAt("votd") ?? 0)|\(box)|\(hub.error("votd") ?? "")"
        if verseImage?.key != key {
            verseImage = (key, buildVerse(box))
        }
        if let img = verseImage?.image { p.image(img, box) }
    }

    private func buildVerse(_ box: CGRect) -> CGImage? {
        let bw = box.width, bh = box.height
        let lh = lineH
        let votd = hub.get("votd")
        let err = hub.error("votd")
        return Painter.render(size: box.size, scale: scale) { p in
            p.fill(0, 0, bw, bh, Self.c(Self.BG, 0.66))
            let th = max(1.0, lh / 14), arm = lh * 0.6
            corners(p, bw, bh, th, arm)
            let pad = lh * 0.4
            p.text("VERSE OF THE DAY", pad, pad * 0.6, Self.c(Self.TITLE), small)
            p.fill(pad, lh * 1.25, bw - 2 * pad, th, Self.c(Self.DIM, 0.6))
            let bodyY = lh * 1.55
            let availH = bh - bodyY - lh * 1.2
            guard votd.exists else {
                p.text(err.map { "Offline: \($0)" } ?? "Loading…", pad, bodyY, Self.c(Self.LABEL), small, width: bw - 2 * pad)
                return
            }
            let colGap = lh * 1.2
            let leftW = (bw - 2 * pad - colGap) * 0.55
            let rightW = bw - 2 * pad - colGap - leftW
            let eng = votd["text"].s(), orig = votd["orig"].s()
            let rtl = votd["rtl"].bool == true
            // Largest serif size at which both texts fit.
            var px = lh * 1.15
            var engFont = Painter.serif(px), origFont = Painter.serif(px * 1.05)
            var engLines: [String] = [], origLines: [String] = []
            while true {
                engFont = Painter.serif(px)
                origFont = Painter.serif(px * 1.05)
                engLines = Painter.wrap(eng, engFont, width: leftW)
                origLines = Painter.wrap(orig, origFont, width: rightW)
                let hgt = max(CGFloat(engLines.count) * Painter.lineHeight(engFont),
                              CGFloat(origLines.count) * Painter.lineHeight(origFont))
                if hgt <= availH || px <= lh * 0.5 { break }
                px *= 0.93
            }
            p.paragraph(engLines, pad, bodyY, Self.c("#f1efe8"), engFont, width: leftW)
            p.paragraph(origLines, pad + leftW + colGap, bodyY, Self.c("#e9d9b4"), origFont, width: rightW,
                        align: rtl ? .right : .left)
            p.fill(pad + leftW + colGap / 2, bodyY, th, availH, Self.c(Self.DIM, 0.6))
            let footY = bh - lh * 1.0
            p.text("— \(votd["ref"].s()) (\(votd["version"].s("ESV")))", pad, footY, Self.c(Self.BRIGHT), small, width: leftW)
            let src = orig.isEmpty ? "original text unavailable (\(votd["orig_error"].s()))"
                : "\(votd["orig_lang"].s()) · \(votd["orig_src"].s())"
            p.text(src, pad + leftW + colGap, footY, Self.c(Self.LABEL), small, width: rightW, align: rtl ? .right : .left)
        }
    }

    // MARK: Wind graph

    static let compass = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    static func compassName(_ deg: Double) -> String {
        compass[((Int((deg / 22.5).rounded()) % 16) + 16) % 16]
    }

    private func compassRose(_ p: Painter, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                             prevailing: Double, current: Double, steadiness: Double) {
        p.strokeCircle(cx, cy, r, 1.4, Self.c(Self.BRIGHT, 0.55))
        let lh = lineH
        for deg in stride(from: 0, to: 360, by: 45) {
            let a = Astro.rad(Double(deg))
            let inner = r * (deg % 90 == 0 ? 0.78 : 0.88)
            p.line(cx + inner * sin(a), cy - inner * cos(a), cx + r * sin(a), cy - r * cos(a), 1.2,
                   Self.c(Self.BRIGHT, deg % 90 == 0 ? 0.6 : 0.3))
        }
        for (deg, letter) in [(0.0, "N"), (90.0, "E"), (180.0, "S"), (270.0, "W")] {
            let a = Astro.rad(deg)
            let sz = Painter.measure(letter, small)
            let lr = r + lh * 0.45
            p.text(letter, cx + lr * sin(a) - sz.width / 2, cy - lr * cos(a) - sz.height / 2,
                   Self.c(letter == "N" ? Self.TITLE : Self.LABEL), small)
        }
        // Arrow flies downwind: tail on the side the wind comes from, head where it's going.
        let a = Astro.rad(prevailing)
        let sx = sin(a), sy = -cos(a)  // unit vector toward the source
        let tail = CGPoint(x: cx + sx * r * 0.8, y: cy + sy * r * 0.8)
        let head = CGPoint(x: cx - sx * r * 0.8, y: cy - sy * r * 0.8)
        p.line(tail.x, tail.y, head.x, head.y, max(2.0, lh / 9), Self.c(Self.BRIGHT, 0.4 + 0.6 * steadiness))
        let hl = r * 0.32, hw = r * 0.18
        let px = -sy, py = sx  // perpendicular
        let tip = CGMutablePath()
        tip.move(to: head)
        tip.addLine(to: CGPoint(x: head.x + sx * hl + px * hw, y: head.y + sy * hl + py * hw))
        tip.addLine(to: CGPoint(x: head.x + sx * hl - px * hw, y: head.y + sy * hl - py * hw))
        tip.closeSubpath()
        p.fill(tip, Self.c(Self.BRIGHT, 0.95))
        // current direction: a dot on the ring
        let ca = Astro.rad(current)
        p.fillCircle(cx + sin(ca) * r, cy - cos(ca) * r, max(2.5, lh * 0.16), Self.c(Self.TITLE))
    }

    private func windGraph(_ p: Painter) {
        let bx = windBox.minX, by = windBox.minY, bw = windBox.width, bh = windBox.height
        guard bw >= lineH * 8 else { return }
        let hist = hub.get("history")
        let lh = lineH
        let unit = imperial ? "mph" : "km/h"
        p.text("WIND · LAST 3 HOURS", bx, by, Self.c(Self.TITLE), small)
        let speeds = hist["wind"].array.map { $0.d() }
        let gusts = hist["gust"].array.map { $0.d() }
        let dirs = hist["wdir"].array.map { $0.d() }
        guard !speeds.isEmpty, gusts.count == speeds.count, dirs.count == speeds.count else {
            p.text("loading…", bx, by + lh, Self.c(Self.LABEL), small)
            return
        }
        let nowV = speeds[speeds.count - 1], nowDir = dirs[dirs.count - 1]
        // readout on the right of the graph
        let read = String(format: "%.0f", nowV)
        let rw = Painter.measure(read, big).width
        let rx = bx + bw - rw - lh * 3.2
        p.text(read, rx, by + bh * 0.08, Self.c(Self.BRIGHT), big)
        p.text(unit, rx + rw + lh * 0.2, by + bh * 0.2, Self.c(Self.LABEL), small)
        p.text("from \(Self.compassName(nowDir))", rx + rw + lh * 0.2, by + bh * 0.42, Self.c(Self.VALUE), small)
        p.text(String(format: "gust %.0f", gusts[gusts.count - 1]), rx + rw + lh * 0.2, by + bh * 0.64, Self.c(Self.LABEL), small)

        // Prevailing direction: speed-weighted vector mean of the last 3 hours.
        var ex = 0.0, ny = 0.0
        for (v, d) in zip(speeds, dirs) {
            ex += v * sin(Astro.rad(d))
            ny += v * cos(Astro.rad(d))
        }
        let prevailing = Astro.mod(Astro.deg(atan2(ex, ny)), 360)
        let steadiness = hypot(ex, ny) / max(speeds.reduce(0, +), 1e-6)
        let cr = bh * 0.3
        let ccx = rx - lh * 1.4 - cr, ccy = by + bh * 0.58
        compassRose(p, ccx, ccy, cr, prevailing: prevailing, current: nowDir, steadiness: steadiness)
        let plabel = "PREVAILING \(Self.compassName(prevailing))"
        p.text(plabel, ccx - Painter.measure(plabel, small).width / 2, by - lh * 0.15, Self.c(Self.TITLE), small)

        let gx = bx, gy = by + lh * 0.9
        let gw = ccx - cr - lh * 2.6 - bx, gh = bh - lh * 1.9
        guard gw > lh * 2, gh > 0 else { return }
        let peak = max(gusts.max() ?? 0, speeds.max() ?? 0, 1)
        let topV = (peak / 5).rounded(.up) * 5
        p.fill(gx, gy + gh, gw, 1, Self.c(Self.DIM, 0.8))
        for k in [0.5, 1.0] {
            let yk = gy + gh - gh * k
            p.fill(gx, yk, gw, 1, Self.c(Self.DIM, 0.4))
            p.text(String(format: "%g", topV * k), gx + gw + lh * 0.15, yk - lh * 0.35, Self.c(Self.LABEL), small)
        }
        let n = speeds.count
        func path(_ vals: [Double]) -> CGPath {
            let b = CGMutablePath()
            for (i, v) in vals.enumerated() {
                let pt = CGPoint(x: gx + gw * CGFloat(i) / CGFloat(max(n - 1, 1)), y: gy + gh - gh * min(v / topV, 1))
                if i == 0 { b.move(to: pt) } else { b.addLine(to: pt) }
            }
            return b
        }
        p.stroke(path(gusts), max(1.0, lh / 18), Self.c(Self.LABEL, 0.8), dash: [lh * 0.25, lh * 0.2])
        p.stroke(path(speeds), max(1.6, lh / 10), Self.c(Self.BRIGHT, 0.95))
        for (i, lab) in [(0, "−3h"), (n / 3, "−2h"), (2 * n / 3, "−1h"), (n - 1, "now")] {
            let px = gx + gw * CGFloat(i) / CGFloat(max(n - 1, 1))
            p.text(lab, px - (lab == "now" ? lh * 0.9 : 0), gy + gh + lh * 0.1, Self.c(Self.LABEL), small)
        }
    }

    // MARK: Radar scope

    private func scopeXY(_ lat: Double, _ lon: Double, _ bbox: [Double]) -> CGPoint {
        let x0 = bbox[0], y0 = bbox[1], x1 = bbox[2], y1 = bbox[3]
        return CGPoint(x: scopeC.x + ((lon - x0) / (x1 - x0) * 2 - 1) * scopeR,
                       y: scopeC.y - ((lat - y0) / (y1 - y0) * 2 - 1) * scopeR)
    }

    private func scopeBBox() -> [Double]? {
        let b = hub.get("radar")["bbox"].array.map { $0.d() }
        if b.count == 4 { return b }
        let loc = hub.get("location")
        guard let lat = loc["lat"].double, let lon = loc["lon"].double else { return nil }
        return radarBBox(lat, lon)
    }

    private func wedge(_ a0: Double, _ a1: Double) -> CGPath {
        let cx = scopeC.x, cy = scopeC.y, r = scopeR
        let b = CGMutablePath()
        b.move(to: scopeC)
        for j in 0..<5 {
            let a = a0 + (a1 - a0) * Double(j) / 4
            b.addLine(to: CGPoint(x: cx + r * 1.02 * sin(a), y: cy - r * 1.02 * cos(a)))
        }
        b.closeSubpath()
        return b
    }

    private func scope(_ p: Painter, _ t: Double, _ now: Double) {
        guard let bbox = scopeBBox() else { return }
        let cx = scopeC.x, cy = scopeC.y, r = scopeR
        let radar = hub.get("radar")
        if let rt = radar["t"].double, rt != radarT, let png = radar["png"].data {
            radarImage = Painter.decodeImage(png)
            radarT = rt
        }
        let key = "\(radarT ?? 0)|\(hub.age("borders") != nil)|\(bbox.map { String(format: "%.3f", $0) })|\(size)|\(imperial)"
        if scopeImage?.key != key {
            let pad = lineH * 1.6
            let rect = CGRect(x: cx - r - pad, y: cy - r - pad, width: 2 * (r + pad), height: 2 * (r + pad))
            scopeImage = (key, buildScope(bbox, rect), rect)
        }
        if let s = scopeImage, let img = s.image { p.image(img, s.rect) }

        // Sweep: a bright wedge trail lights up the radar echoes as the beam passes.
        let period = 6.0
        let ang = Astro.mod(t, period) / period * 2 * .pi
        let trail = Astro.rad(100), steps = 14
        let circle = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
        let disc = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
        p.with(clip: circle) {
            for k in 0..<steps {
                let a1 = ang - trail * Double(k) / Double(steps)
                let a0 = ang - trail * Double(k + 1) / Double(steps)
                let fade = pow(1 - Double(k) / Double(steps), 2)
                p.with(clip: wedge(a0, a1)) {
                    p.fill(disc, Self.c(Self.PHOSPHOR, 0.10 * fade))
                    if let img = radarImage { p.image(img, disc, alpha: 0.85 * fade) }
                }
            }
        }
        p.line(cx, cy, cx + r * sin(ang), cy - r * cos(ang), 2.0, Self.c(Self.PHOSPHOR, 0.85))

        // Contacts: cameras and nearby earthquakes flare as the beam crosses them.
        func flare(_ pt: CGPoint) -> Double {
            let bearing = atan2(pt.x - cx, cy - pt.y)
            let behind = Astro.mod(ang - bearing, 2 * .pi)
            return max(0, 1 - behind / Astro.rad(120))
        }
        let dot = max(2.0, lineH * 0.14)
        for cam in hub.get("cameras").array {
            let pt = scopeXY(cam["lat"].d(), cam["lon"].d(), bbox)
            p.fill(pt.x - dot, pt.y - dot, 2 * dot, 2 * dot, Self.c(Self.BRIGHT, 0.25 + 0.75 * flare(pt)))
        }
        for q in hub.get("quakes").array {
            let pt = scopeXY(q["lat"].d(), q["lon"].d(), bbox)
            if hypot(pt.x - cx, pt.y - cy) > r { continue }
            p.fillCircle(pt.x, pt.y, dot * (1 + max(q["mag"].d(), 0)), Self.c(Self.TITLE, 0.3 + 0.7 * flare(pt)))
        }
        let beat = 0.5 + 0.5 * sin(t * 3)
        p.fillCircle(cx, cy, dot * (1.4 + beat), Self.c(Self.PHOSPHOR, 0.9))
    }

    private func buildScope(_ bbox: [Double], _ rect: CGRect) -> CGImage? {
        let cx = scopeC.x, cy = scopeC.y, r = scopeR
        let borders = hub.get("borders")
        let radar = radarImage
        let imp = imperial
        return Painter.render(size: rect.size, scale: scale) { p in
            p.cg.translateBy(x: -rect.minX, y: -rect.minY)
            let disc = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            p.with(clip: CGPath(ellipseIn: disc, transform: nil)) {
                p.fill(disc, Self.c(Self.SCOPE_BG))
                if borders.exists {
                    for (name, alpha, width) in [("counties", 0.09, 1.0), ("states", 0.3, 1.6)] as [(String, CGFloat, CGFloat)] {
                        let path = CGMutablePath()
                        for arc in borders[name].array {
                            for (i, pt) in arc.array.enumerated() {
                                let xy = scopeXY(pt[1].d(), pt[0].d(), bbox)
                                if i == 0 { path.move(to: xy) } else { path.addLine(to: xy) }
                            }
                        }
                        p.stroke(path, width, Self.c(Self.PHOSPHOR, alpha))
                    }
                }
                if let radar { p.image(radar, disc, alpha: 0.28) }  // resting echo, dim between sweeps
            }
            let ring = Self.c(Self.PHOSPHOR, 0.22)
            for k in 1...4 {
                let rk = r * CGFloat(k) / 4
                p.strokeCircle(cx, cy, rk, k < 4 ? 1.0 : 1.8, ring)
                let miles = radarMiles * Double(k) / 4
                let label = imp ? String(format: "%.0f mi", miles) : String(format: "%.0f km", miles * 1.609)
                p.text(label, cx + rk * 0.707 + 4, cy - rk * 0.707 - lineH * 0.5, Self.c(Self.PHOSPHOR), small, alpha: 0.45)
            }
            p.line(cx - r, cy, cx + r, cy, 1.0, Self.c(Self.PHOSPHOR, 0.12))
            p.line(cx, cy - r, cx, cy + r, 1.0, Self.c(Self.PHOSPHOR, 0.12))
            for deg in stride(from: 0, to: 360, by: 5) {
                let a = Astro.rad(Double(deg))
                let inner = r * (deg % 30 == 0 ? 0.955 : 0.975)
                p.line(cx + inner * sin(a), cy - inner * cos(a), cx + r * sin(a), cy - r * cos(a), 1.2,
                       Self.c(Self.PHOSPHOR, deg % 30 == 0 ? 0.5 : 0.25))
                if deg % 30 == 0 {
                    let label = [0: "N", 90: "E", 180: "S", 270: "W"][deg] ?? String(format: "%03d", deg)
                    let sz = Painter.measure(label, small)
                    let lr = r + lineH * 0.7
                    p.text(label, cx + lr * sin(a) - sz.width / 2, cy - lr * cos(a) - sz.height / 2, Self.c(Self.PHOSPHOR),
                           small, alpha: deg % 90 == 0 ? 0.75 : 0.45)
                }
            }
            p.text("NEXRAD REFLECTIVITY · NOAA/IEM", cx - r, cy + r - lineH * 0.6, Self.c(Self.PHOSPHOR), small, alpha: 0.4)
        }
    }
}
