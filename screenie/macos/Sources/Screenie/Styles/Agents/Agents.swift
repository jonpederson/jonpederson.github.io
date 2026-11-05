import AppKit
import SwiftUI

/// Agents style: mission control for the AI agents working on this Mac (port of `agents.py`).
///
/// Left: a living constellation. This machine is the core, each project is a hub around
/// it and each agent orbits its project. Working agents blaze and stream token particles
/// into their project; every real tool call sends out a shockwave labelled with the tool,
/// and every new task fires a beam from the core. Right: a card per agent with live
/// stats. Bottom: the live event feed, 24 hours of activity, and the day's toolkit and
/// token mix.
final class AgentsStyle: SaverStyle {
    var drawsOwnClock: Bool { true }

    static let BG = "#05060a", PANEL = "#0b0e16", ACCENT = "#e07a52", TEXT = "#e9e7e2", DIM = "#7a8291"
    static let FAINT = "#262a36", WORKING = "#7dffa0", WARN = "#ff6b6b"
    static let palette = ["#6fe3ff", "#c792ff", "#ffb347", "#7dffa0", "#ff7ab6", "#7aa2ff", "#ffe066", "#5ff0c8"]
    static let ctxLimit = 1_000_000.0

    static func c(_ hex: String, _ a: CGFloat = 1) -> CGColor { cgColor(hex: hex, alpha: a) }

    static func human(_ n: Double) -> String {
        for (div, suf) in [(1e9, "B"), (1e6, "M"), (1e3, "k")] where abs(n) >= div {
            return String(format: "%.1f%@", n / div, suf)
        }
        return String(format: "%.0f", n)
    }

    static func human(_ n: Int?) -> String { human(Double(n ?? 0)) }

    static func dur(_ s: Double) -> String {
        let s = max(0, Int(s))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm%02ds", s / 60, s % 60) }
        if s < 86400 { return String(format: "%dh%02dm", s / 3600, s % 3600 / 60) }
        return "\(s / 86400)d\(s % 86400 / 3600)h"
    }

    /// CRC-32 (IEEE), the same as Python's zlib.crc32, so projects get the same colours as on Linux.
    static func crc32(_ s: String) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in s.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static func colorFor(_ project: String) -> String {
        palette[Int(crc32(project) % UInt32(palette.count))]
    }

    private struct Particle {
        let project: String
        let x, y, v, bend: Double
        var f: Double
    }

    private struct Effect {
        let kind, sid, name, target: String
        let t0: Double
    }

    private let hub = AgentHub.shared
    private let details: Bool
    private let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    private var size = CGSize.zero
    private var scale: CGFloat = 0
    private var lastSeq: Int?
    private var particles: [Particle] = []
    private var effects: [Effect] = []
    private var phase: [String: Double] = [:]
    private var pos: [String: CGPoint] = [:]
    private var hubPos: [String: CGPoint] = [:]
    private var cardImages: [String: CGImage] = [:]
    private var cardRR = 0
    private var cardSig = ""
    private var bottomImage: CGImage?
    private var bottomT = 0.0
    private var feedImage: CGImage?
    private var feedSeq: Int?
    private var feedT = 0.0
    private var feedRowH: CGFloat = 0
    private var feedTop: CGFloat = 0
    private var lastT: Double?
    private var names: [String: String] = [:]

    // Layout
    private var m: CGFloat = 0
    private var header = CGRect.zero
    private var const = CGRect.zero
    private var cards = CGRect.zero
    private var bottom = CGRect.zero
    private var fHuge = Painter.sans(40), fNum = Painter.mono(30), fLabel = Painter.sans(10), fSmall = Painter.mono(10)
    private var fNode = Painter.sans(10), fNodeB = Painter.sans(11), fFx = Painter.mono(11)

    init(config: Config) {
        details = config.agentsDetails
        hub.retain()
    }

    deinit {
        hub.release()
    }

    // MARK: Privacy

    private func title(_ a: AgentInfo) -> String {
        if details { return a.title }
        if let n = names[a.sid] { return n }
        let n = "Agent \(names.count + 1)"
        names[a.sid] = n
        return n
    }

    private func project(_ name: String) -> String {
        if details { return name }
        let letter = UnicodeScalar(UInt8(65 + Self.crc32(name) % 26))
        return "project \(Character(letter))"
    }

    private func target(_ t: String) -> String { details ? t : "" }

    // MARK: Layout

    private func setup(_ size: CGSize, _ scale: CGFloat) {
        self.size = size
        self.scale = scale
        let w = size.width, h = size.height
        m = (h * 0.028).rounded()
        header = CGRect(x: m, y: m, width: w - 2 * m, height: h * 0.11)
        let top = m + h * 0.11 + m * 0.6
        let bottomH = h * 0.25
        let bottomY = h - m - bottomH
        let mainH = bottomY - m * 0.6 - top
        let cw = (w - 2 * m) * (w / h > 2 ? 0.52 : 0.5)
        const = CGRect(x: m, y: top, width: cw, height: mainH)
        cards = CGRect(x: m + cw + m, y: top, width: w - 2 * m - cw - m, height: mainH)
        bottom = CGRect(x: m, y: bottomY, width: w - 2 * m, height: bottomH)
        fHuge = Painter.sans(h * 0.052, weight: .bold)
        fNum = Painter.mono(h * 0.036, weight: .bold)
        fLabel = Painter.sans(h * 0.0125, weight: .bold)
        fSmall = Painter.mono(h * 0.0135)
        fNode = Painter.sans(h * 0.014)
        fNodeB = Painter.sans(h * 0.0155, weight: .bold)
        fFx = Painter.mono(h * 0.0145, weight: .bold)
        cardImages = [:]
        bottomImage = nil
        feedImage = nil
    }

    private func glow(_ p: Painter, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: String, _ alpha: Double) {
        guard alpha > 0.01, let img = Painter.glow(color) else { return }
        p.image(img, CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size), alpha: min(1, alpha))
    }

    // MARK: Frame

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, scale: CGFloat) {
        if size != self.size || scale != self.scale { setup(size, scale) }
        let dt = lastT.map { min(max(t - $0, 0), 0.1) } ?? 0.016
        lastT = t
        let now = Date().timeIntervalSince1970
        let snap = hub.snapshot
        let jx = 5 * sin(t * 0.008), jy = 5 * cos(t * 0.011)
        ctx.withCGContext { cg in
            let p = Painter(cg)
            p.fill(CGRect(origin: .zero, size: size), Self.c(Self.BG))
            cg.translateBy(x: jx, y: jy)
            guard let s = snap else {
                p.text("Scanning for agents…", size.width / 2 - size.height * 0.15, size.height / 2, Self.c(Self.DIM), fNodeB)
                return
            }
            ingestEvents(s, now)
            drawHeader(p, s, now)
            constellation(p, s, t, dt, now)
            drawCards(p, s, t, now)
            drawBottom(p, s, now)
        }
    }

    private func ingestEvents(_ s: AgentSnapshot, _ now: Double) {
        guard let newest = s.events.last else { return }
        guard let last = lastSeq else {
            lastSeq = newest.seq  // don't replay history at launch
            return
        }
        for e in s.events where e.seq > last {
            effects.append(Effect(kind: e.kind, sid: e.sid, name: e.name, target: target(e.target), t0: now))
        }
        lastSeq = newest.seq
        if effects.count > 40 { effects.removeFirst(effects.count - 40) }
    }

    // MARK: Header

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func drawHeader(_ p: Painter, _ s: AgentSnapshot, _ now: Double) {
        let x = header.minX, y = header.minY, w = header.width, h = header.height
        let busy = s.agents.filter(\.busy).count
        p.text("AGENTS", x, y - h * 0.08, Self.c(Self.ACCENT), fHuge)
        var sub = "MISSION CONTROL · \(host) · \(Self.clock.string(from: Date()))"
        if !s.others.isEmpty { sub += " · also running: " + s.others.joined(separator: ", ") }

        let today = s.today
        let total = ["input", "cache_write", "cache_read", "output"].reduce(0) { $0 + (today[$1] ?? 0) }
        let rate = s.agents.reduce(0) { $0 + $1.outRate }
        let pages = Double(today["output"] ?? 0) * 0.75 / 500
        let tiles: [(String, String, String)] = [
            ("AGENTS ONLINE", "\(s.agents.count)", Self.TEXT),
            ("WORKING NOW", "\(busy)", busy > 0 ? Self.WORKING : Self.DIM),
            ("OUTPUT TOKENS / MIN", Self.human(rate), rate > 0 ? Self.ACCENT : Self.DIM),
            ("TOKENS TODAY", Self.human(total), Self.TEXT),
            ("TOOL CALLS TODAY", Fmt.commas(today["tool_calls"] ?? 0), Self.TEXT),
            ("FILES EDITED TODAY", "\(s.filesToday)", Self.TEXT),
            ("PAGES WRITTEN TODAY", "≈" + Fmt.commas(pages, 0), Self.TEXT),
        ]
        var right = x + w
        let gap = h * 0.45
        for (label, value, color) in tiles.reversed() {
            let vw = Painter.measure(value, fNum).width
            let lw = Painter.measure(label, fLabel).width
            p.text(value, right - vw, y - h * 0.02, Self.c(color), fNum)
            p.text(label, right - lw, y + h * 0.58, Self.c(Self.DIM), fLabel)
            right -= max(vw, lw) + gap
            if right < x + w * 0.3 { break }
        }
        // The subtitle gets whatever room the tiles left, so a long host name can't run into them.
        p.text(sub, x, y + h * 0.58, Self.c(Self.DIM), fLabel, width: max(right + gap * 0.5 - x, h))
        p.fill(x, y + h, w, 1, Self.c(Self.FAINT))
    }

    // MARK: Constellation

    private func constellation(_ p: Painter, _ s: AgentSnapshot, _ t: Double, _ dt: Double, _ now: Double) {
        let x0 = const.minX, y0 = const.minY, cw = const.width, ch = const.height
        let agents = s.agents
        let cx = x0 + cw / 2, cy = y0 + ch / 2
        let mn = min(cw, ch)
        let rc = mn * 0.065
        let busyTotal = agents.filter(\.busy).count

        // faint polar grid
        for k in 1...3 {
            p.strokeCircle(cx, cy, mn * 0.16 * CGFloat(k), 1.0, Self.c(Self.FAINT, 0.7), dash: [2, 10], phase: -t * 3 * Double(k))
        }

        let projects = Array(Set(agents.map(\.project))).sorted()
        let n = projects.count
        let rx = cw * 0.34, ry = ch * 0.33
        hubPos = [:]
        for (i, pr) in projects.enumerated() {
            let ang = -Double.pi / 2 + 2 * .pi * Double(i) / Double(max(n, 1)) + t * 0.012
            hubPos[pr] = n > 1 ? CGPoint(x: cx + rx * cos(ang), y: cy + ry * sin(ang)) : CGPoint(x: cx, y: cy - ry)
        }

        // agents orbit their project hub
        pos = [:]
        var byProj: [String: [AgentInfo]] = [:]
        for a in agents { byProj[a.project, default: []].append(a) }
        let ro = mn * 0.17
        for (pr, members) in byProj {
            guard let hp = hubPos[pr] else { continue }
            for (j, a) in members.enumerated() {
                let sp = a.busy ? 0.32 : 0.045
                let ph = (phase[a.sid] ?? Double.random(in: 0...6.28)) + sp * dt
                phase[a.sid] = ph
                let ang = ph + 2 * .pi * Double(j) / Double(members.count)
                let r = ro * (1 + 0.28 * CGFloat(j % 2))
                pos[a.sid] = CGPoint(x: hp.x + r * cos(ang), y: hp.y + r * 0.8 * sin(ang))
            }
        }

        // links
        for (pr, hp) in hubPos {
            let col = Self.colorFor(pr)
            let active = byProj[pr]?.contains(where: \.busy) ?? false
            p.line(cx, cy, hp.x, hp.y, active ? 1.4 : 1.0, Self.c(col, active ? 0.35 : 0.14))
            if active {  // data pulses along the link
                for k in 0..<3 {
                    let f = Astro.mod(t * 0.45 + Double(k) / 3, 1)
                    glow(p, cx + (hp.x - cx) * f, cy + (hp.y - cy) * f, mn * 0.05, col, 0.5)
                }
            }
            for a in byProj[pr] ?? [] {
                guard let ap = pos[a.sid] else { continue }
                p.line(hp.x, hp.y, ap.x, ap.y, 1.0, Self.c(col, a.busy ? 0.28 : 0.1))
            }
        }

        // token particles from working agents into their project
        for a in agents where a.busy {
            let rate = 5 + min(30, a.outRate / 60)
            if Double.random(in: 0..<1) < rate * dt, let ap = pos[a.sid] {
                particles.append(Particle(project: a.project, x: ap.x, y: ap.y, v: .random(in: 0.5...0.9),
                                          bend: .random(in: -0.35...0.35), f: 0))
            }
        }
        var alive: [Particle] = []
        for var q in particles.suffix(500) {
            q.f += q.v * dt
            guard q.f < 1, let hp = hubPos[q.project] else { continue }
            let f = q.f
            let mx = (q.x + hp.x) / 2 - (hp.y - q.y) * q.bend, my = (q.y + hp.y) / 2 + (hp.x - q.x) * q.bend
            let px = pow(1 - f, 2) * q.x + 2 * (1 - f) * f * mx + f * f * hp.x
            let py = pow(1 - f, 2) * q.y + 2 * (1 - f) * f * my + f * f * hp.y
            glow(p, px, py, mn * 0.028, Self.colorFor(q.project), 0.9 * sin(.pi * f))
            alive.append(q)
        }
        particles = alive

        // core: this machine
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        let load = loads[0] / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        let pulse = 0.5 + 0.5 * sin(t * (1.2 + 3 * min(load, 1)))
        glow(p, cx, cy, rc * (7 + CGFloat(busyTotal) * 0.6), Self.ACCENT, 0.35 + 0.25 * pulse)
        p.fillCircle(cx, cy, rc, Self.c("#120c0a"))
        p.strokeCircle(cx, cy, rc, 2.0, Self.c(Self.ACCENT, 0.9))
        p.strokeCircle(cx, cy, rc * 1.28, 1.5, Self.c(Self.ACCENT, 0.55), dash: [rc * 0.5, rc * 0.25], phase: -t * 20)
        p.strokeCircle(cx, cy, rc * 1.55, 1.0, Self.c(Self.ACCENT, 0.3), dash: [rc * 0.12, rc * 0.2], phase: t * 12)
        let hw = rc * 1.8
        p.text(host, cx - hw / 2, cy - rc * 0.42, Self.c(Self.TEXT), fNodeB, width: hw, align: .center)
        p.text(String(format: "load %.2f", loads[0]), cx - hw / 2, cy + rc * 0.08, Self.c(Self.DIM), fNode, width: hw, align: .center)

        // project hubs
        let rh = mn * 0.04
        for (pr, hp) in hubPos {
            let col = Self.colorFor(pr)
            let members = byProj[pr] ?? []
            let active = members.contains(where: \.busy)
            glow(p, hp.x, hp.y, rh * 6, col, active ? 0.45 : 0.18)
            p.fillCircle(hp.x, hp.y, rh, Self.c(Self.BG))
            p.strokeCircle(hp.x, hp.y, rh, 2.0, Self.c(col, active ? 0.95 : 0.55))
            p.strokeCircle(hp.x, hp.y, rh * 0.62, 1.0, Self.c(col, 0.4), dash: [3, 4], phase: -t * (active ? 12 : 2))
            let lw = mn * 0.4
            p.text(project(pr), hp.x - lw / 2, hp.y + rh * 1.25, Self.c(col), fNodeB, width: lw, align: .center)
            var info = "\(members.count) agent\(members.count != 1 ? "s" : "")"
            if let g = members.compactMap(\.git).first {
                info += " · \(g.branch)"
                if g.add > 0 || g.del > 0 { info += " +\(g.add) −\(g.del)" }
            }
            p.text(info, hp.x - lw / 2, hp.y + rh * 1.25 + size.height * 0.02, Self.c(Self.DIM), fNode, width: lw, align: .center)
        }

        // agents
        let ra = mn * 0.02
        for a in agents {
            guard let ap = pos[a.sid] else { continue }
            let col = Self.colorFor(a.project)
            if a.busy {
                let beat = 0.5 + 0.5 * sin(t * 5 + Double(a.pid))
                glow(p, ap.x, ap.y, ra * (9 + 3 * beat), col, 0.75)
                p.fillCircle(ap.x, ap.y, ra * 1.15, Self.c("#ffffff", 0.95))
                p.strokeCircle(ap.x, ap.y, ra * 1.9, 2.0, Self.c(col, 0.9), dash: [ra * 1.2, ra * 0.8], phase: -t * 30)
                let lw = mn * 0.36
                p.text(title(a), ap.x - lw / 2, ap.y + ra * 2.2, Self.c(Self.TEXT), fNode, width: lw, align: .center)
                p.text("WORKING \(Self.dur(now - a.since))", ap.x - lw / 2, ap.y - ra * 2.2 - size.height * 0.02,
                       Self.c(Self.WORKING), fLabel, width: lw, align: .center)
            } else {  // idle agents stay quiet; their cards carry the details
                let breathe = 0.5 + 0.5 * sin(t * 0.8 + Double(a.pid))
                glow(p, ap.x, ap.y, ra * 5, col, 0.12 + 0.08 * breathe)
                p.fillCircle(ap.x, ap.y, ra * 0.75, Self.c(col, 0.55))
            }
        }

        // event effects: shockwaves, floating tool labels, task beams
        var stack: [String: Int] = [:]
        var keep: [Effect] = []
        for e in effects {
            let age = now - e.t0
            guard let ap = pos[e.sid], age <= 4.0 else { continue }
            keep.append(e)
            let col = e.kind == "prompt" ? Self.WORKING : Self.colorFor(agents.first { $0.sid == e.sid }?.project ?? "?")
            if age < 1.6 {
                let k = age / 1.6
                let scale: Double = e.kind == "prompt" ? 9 : e.kind == "tool" ? 6 : 4
                p.strokeCircle(ap.x, ap.y, ra * (1.5 + scale * k), 2.5 * (1 - k) + 0.5, Self.c(col, 0.9 * (1 - k)))
            }
            if e.kind == "prompt" && age < 2.0 {
                let k = age / 2.0
                p.line(cx, cy, ap.x, ap.y, 3 * (1 - k) + 0.5, Self.c(Self.WORKING, 0.8 * (1 - k)))
                let f = min(1.0, age / 0.6)
                glow(p, cx + (ap.x - cx) * f, cy + (ap.y - cy) * f, mn * 0.08, Self.WORKING, 1 - k)
            }
            let idx = stack[e.sid] ?? 0
            stack[e.sid] = idx + 1
            let alpha = min(1.0, (4.0 - age) / 1.2)
            let label = e.name + (e.target.isEmpty ? "" : "  \(e.target)")
            let ly = ap.y - ra * 3 - age * size.height * 0.012 - CGFloat(idx) * size.height * 0.022
            p.text(label, ap.x + ra * 2.5, ly, Self.c(col), fFx, alpha: alpha, width: mn * 0.45)
        }
        effects = keep

        // caption
        let caption = agents.isEmpty ? "No agents running right now"
            : "\(agents.count) agent\(agents.count != 1 ? "s" : "") · \(n) project\(n != 1 ? "s" : "") · \(busyTotal) working right now"
        p.text(caption.uppercased(), x0, y0, Self.c(Self.DIM), fLabel)
    }

    // MARK: Cards

    private func drawCards(_ p: Painter, _ s: AgentSnapshot, _ t: Double, _ now: Double) {
        let x0 = cards.minX, y0 = cards.minY, w = cards.width, h = cards.height
        let agents = Array(s.agents.prefix(10))
        guard !agents.isEmpty else {
            p.text("Start a Claude Code session and it will appear here.", x0, y0 + h / 2, Self.c(Self.DIM), fNodeB)
            return
        }
        let n = agents.count
        let cols = n <= 3 ? 1 : 2
        let rows = (n + cols - 1) / cols
        let gap = m * 0.5
        let cardW = (w - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cardH = (h - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let sig = "\(n)|\(cols)|\(Int(cardW))|\(Int(cardH))|" + agents.map(\.sid).joined(separator: ",")
        if sig != cardSig {
            cardSig = sig
            cardImages = [:]
        }
        for a in agents where cardImages[a.sid] == nil {  // build missing cards, then refresh one per frame
            cardImages[a.sid] = buildCard(a, cardW, cardH, now)
        }
        let rr = agents[cardRR % n]
        cardImages[rr.sid] = buildCard(rr, cardW, cardH, now)
        cardRR += 1
        let beat = 0.5 + 0.5 * sin(t * 3)
        for (i, a) in agents.enumerated() {
            let cx = x0 + CGFloat(i % cols) * (cardW + gap)
            let cy = y0 + CGFloat(i / cols) * (cardH + gap)
            let col = Self.colorFor(a.project)
            if a.busy {
                glow(p, cx + cardW / 2, cy + cardH / 2, max(cardW, cardH) * 1.1, col, 0.10 + 0.08 * beat)
            }
            if let img = cardImages[a.sid] { p.image(img, CGRect(x: cx, y: cy, width: cardW, height: cardH)) }
            if a.busy {
                let r = min(8, cardW / 2, cardH / 2)
                p.stroke(CGPath(roundedRect: CGRect(x: cx, y: cy, width: cardW, height: cardH), cornerWidth: r, cornerHeight: r,
                                transform: nil), 1.5, Self.c(col, 0.5 + 0.4 * beat))
            }
        }
    }

    private func buildCard(_ a: AgentInfo, _ w: CGFloat, _ h: CGFloat, _ now: Double) -> CGImage? {
        let col = Self.colorFor(a.project)
        let lh = min(h / 7.3, size.height * 0.026)
        let pad = lh * 0.55
        let x = pad + 4, inner = w - 2 * pad - 4
        let fT = Painter.sans(lh * 0.72, weight: .bold)
        let fV = Painter.mono(lh * 0.56)
        let fL = Painter.sans(lh * 0.46, weight: .bold)
        return Painter.render(size: CGSize(width: w, height: h), scale: scale) { p in
            let r = min(8, w / 2, h / 2)
            p.with(clip: CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)) {
                p.fill(0, 0, w, h, Self.c(Self.PANEL, 0.92))
                p.fill(0, 0, 4, h, Self.c(col, a.busy ? 0.9 : 0.45))
            }
            var y = pad * 0.6

            let status = (a.busy ? "WORKING " : "IDLE ") + Self.dur(now - a.since)
            let sw = Painter.measure(status, fL).width
            p.text(title(a), x, y, Self.c(Self.TEXT), fT, width: inner - sw - lh)
            let sc = a.busy ? Self.WORKING : Self.DIM
            p.fillCircle(x + inner - sw - lh * 0.35, y + lh * 0.42, lh * 0.14, Self.c(sc))
            p.text(status, x + inner - sw, y + lh * 0.18, Self.c(sc), fL)
            y += lh
            p.text("\(project(a.project)) · \(a.model) · \(a.effort) effort · up \(Self.dur(now - a.started))",
                   x, y, Self.c(col), fV, width: inner)
            y += lh

            if let last = a.last {
                let tg = target(last.target)
                p.text(a.busy ? "NOW" : "LAST", x, y + lh * 0.08, Self.c(Self.DIM), fL)
                let lw = lh * 2.2
                p.text(last.name + (tg.isEmpty ? "" : "  " + tg), x + lw, y, Self.c(Self.TEXT), fV, width: inner - lw - lh * 3.5)
                p.text("\(Self.dur(now - last.t)) ago", x + inner - lh * 3.4, y, Self.c(Self.DIM), fV, width: lh * 3.4, align: .right)
            }
            y += lh

            let stats: [(String, String)] = [("TASKS", "\(a.prompts)"), ("TOOLS", Fmt.commas(a.toolCalls)), ("ERRORS", "\(a.errors)"),
                                             ("SUBAGENTS", "\(a.subagents)"), ("FILES", "\(a.files)")]
            let cw = inner / CGFloat(stats.count)
            for (i, (lab, val)) in stats.enumerated() {
                // In a narrow card the label gives way (ellipsized) so the number always shows.
                let vw = Painter.measure(val, fV).width
                let lw = min(Painter.measure(lab + " ", fL).width, max(cw - vw - lh * 0.35, lh))
                p.text(lab, x + CGFloat(i) * cw, y + lh * 0.08, Self.c(Self.DIM), fL, width: lw)
                p.text(val, x + CGFloat(i) * cw + lw, y, Self.c(lab == "ERRORS" && a.errors > 0 ? Self.WARN : Self.TEXT), fV)
            }
            y += lh

            let tok = a.tokens
            let reads = Double(tok["cache_read"] ?? 0)
            let fresh = Double((tok["input"] ?? 0) + (tok["cache_write"] ?? 0))
            let hit = reads + fresh > 0 ? reads / (reads + fresh) * 100 : 0
            p.text("OUT \(Self.human(tok["output"]))  THINK \(Self.human(tok["thinking"]))  " + String(format: "CACHE %.0f%%", hit),
                   x, y, Self.c(Self.TEXT), fV, width: inner * 0.6)
            let bx = x + inner * 0.62, bw = inner * 0.38
            let fill = min(1.0, Double(a.ctx) / Self.ctxLimit)
            p.text("CTX \(Self.human(a.ctx))", bx, y, Self.c(Self.DIM), fV)
            let barX = bx + Painter.measure("CTX 000.0k ", fV).width
            let barW = max(0, bx + bw - barX)
            p.fill(barX, y + lh * 0.3, barW, lh * 0.28, Self.c(Self.FAINT))
            p.fill(barX, y + lh * 0.3, barW * fill, lh * 0.28, Self.c(fill > 0.8 ? Self.WARN : col, 0.85))
            y += lh

            // activity sparkline (tool calls per minute, last hour) + process stats
            let sparkW = inner * 0.45
            let peak = Double(max(a.spark.max() ?? 0, 1))
            let barWidth = sparkW / CGFloat(max(a.spark.count, 1))
            for (i, v) in a.spark.enumerated() where v > 0 {
                let bh = lh * 0.85 * Double(v) / peak
                p.fill(x + CGFloat(i) * barWidth, y + lh * 0.9 - bh, max(barWidth - 1, 1), bh, Self.c(col, 0.85))
            }
            p.fill(x, y + lh * 0.9, sparkW, 1, Self.c(Self.FAINT))
            let kids = a.kids.map { $0.1 > 1 ? "\($0.0)×\($0.1)" : $0.0 }.joined(separator: ", ")
            p.text(String(format: "CPU %.0f%%  MEM ", a.cpu) + Self.human(a.rss) + "B  ▸ " + (kids.isEmpty ? "—" : kids),
                   x + sparkW + lh * 0.5, y, Self.c(Self.DIM), fV, width: inner - sparkW - lh * 0.5)
            y += lh

            var g = "not a git repository"
            if let git = a.git {
                g = "⎇ \(git.branch)  +\(git.add) −\(git.del)  \(git.changed) changed"
                if git.ahead > 0 { g += "  \(git.ahead) unpushed" }
            }
            let tools = a.tools.prefix(3).map { "\($0.0) \($0.1)" }.joined(separator: "  ")
            p.text(g, x, y, Self.c(Self.DIM), fV, width: inner * 0.5)
            p.text(tools, x + inner * 0.5, y, Self.c(Self.DIM), fV, width: inner * 0.5, align: .right)
        }
    }

    // MARK: Bottom strip

    private func drawBottom(_ p: Painter, _ s: AgentSnapshot, _ now: Double) {
        let x0 = bottom.minX, y0 = bottom.minY, w = bottom.width, h = bottom.height
        p.fill(x0, y0 - m * 0.3, w, 1, Self.c(Self.FAINT))
        let feedW = w * 0.42
        // live feed (rebuilt when new events arrive, and every second for the fades)
        let seq = s.events.last?.seq ?? 0
        if seq != feedSeq || feedImage == nil || now - feedT > 1 {
            feedSeq = seq
            feedT = now
            feedImage = buildFeed(s, feedW, h)
        }
        if let img = feedImage { p.image(img, CGRect(x: x0, y: y0, width: feedW, height: h)) }
        // flash the newest row
        if let newest = s.events.last {
            let age = now - newest.t
            if age < 2 {
                p.fill(x0, y0 + feedTop, feedW, feedRowH, Self.c(Self.ACCENT, 0.18 * (1 - age / 2)))
            }
        }
        let statsW = w - feedW - m
        if bottomImage == nil || now - bottomT > 2 {
            bottomT = now
            bottomImage = buildStats(s, statsW, h)
        }
        if let img = bottomImage { p.image(img, CGRect(x: x0 + feedW + m, y: y0, width: statsW, height: h)) }
    }

    private static let feedClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func buildFeed(_ s: AgentSnapshot, _ w: CGFloat, _ h: CGFloat) -> CGImage? {
        let rh = size.height * 0.024
        let top = size.height * 0.026
        feedRowH = rh
        feedTop = top
        let byID = Dictionary(s.agents.map { ($0.sid, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = Int((h - top) / rh)
        let events = Array(s.events.reversed().prefix(max(rows, 0)))
        let tw = Painter.measure("00:00:00  ", fSmall).width
        return Painter.render(size: CGSize(width: w, height: h), scale: scale) { p in
            p.text("LIVE FEED", 0, 0, Self.c(Self.ACCENT), fLabel)
            if events.isEmpty {
                p.text("Waiting for the next tool call…", 0, top, Self.c(Self.DIM), fSmall)
            }
            for (i, e) in events.enumerated() {
                let y = top + CGFloat(i) * rh
                let a = byID[e.sid]
                let proj = a?.project ?? "?"
                let col = Self.colorFor(proj)
                let fade = max(0.35, 1 - Double(i) / Double(max(rows, 1)) * 0.75)
                p.text(Self.feedClock.string(from: Date(timeIntervalSince1970: e.t)), 0, y, Self.c(Self.DIM), fSmall, alpha: fade)
                p.fillCircle(tw + rh * 0.2, y + rh * 0.42, rh * 0.16, Self.c(col, fade))
                let px = tw + rh * 0.6
                let pw = w * 0.17
                p.text(project(proj), px, y, Self.c(col), fSmall, alpha: fade, width: pw)
                let nx = px + pw
                let label = (e.kind == "prompt" ? "◆ " : e.kind == "subtool" ? "↳ " : "") + e.name
                let nw = w * 0.2
                p.text(label, nx, y, Self.c(e.kind == "prompt" ? Self.WORKING : Self.TEXT), fSmall, alpha: fade, width: nw)
                var detail = target(e.target)
                if detail.isEmpty, let a, e.kind == "prompt" { detail = title(a) }
                p.text(detail, nx + nw, y, Self.c(Self.DIM), fSmall, alpha: fade, width: max(w - nx - nw, 1))
            }
        }
    }

    private func buildStats(_ s: AgentSnapshot, _ w: CGFloat, _ h: CGFloat) -> CGImage? {
        let H = size.height
        let chartW = w * 0.56
        let legendY = H * 0.024
        let top = H * 0.052
        let ch = h - top - H * 0.03
        let peak = max(s.hours.map { $0.reduce(0) { $0 + $1.1 } }.max() ?? 0, 1)
        return Painter.render(size: CGSize(width: w, height: h), scale: scale) { p in
            // 24h activity, stacked by project
            p.text("ACTIVITY · LAST 24 HOURS", 0, 0, Self.c(Self.ACCENT), fLabel)
            let bw = chartW / 24
            for (i, hr) in s.hours.enumerated() {
                var y = top + ch
                for (pr, c) in hr where c > 0 {
                    let bh = ch * CGFloat(c) / CGFloat(peak)
                    y -= bh
                    p.fill(CGFloat(i) * bw + 1, y, bw - 2, bh, Self.c(Self.colorFor(pr), 0.85))
                }
            }
            p.fill(0, top + ch, chartW, 1, Self.c(Self.FAINT))
            for (i, lab) in [(0, "−24h"), (6, "−18h"), (12, "−12h"), (18, "−6h")] {
                p.text(lab, CGFloat(i) * bw, top + ch + 2, Self.c(Self.DIM), fSmall)
            }
            p.text("now", chartW - Painter.measure("now", fSmall).width, top + ch + 2, Self.c(Self.DIM), fSmall)
            p.text("peak \(peak) actions/h", chartW * 0.5, 0, Self.c(Self.DIM), fSmall, width: chartW * 0.5, align: .right)
            // legend
            var lx: CGFloat = 0
            for pr in s.projects.prefix(6) {
                let label = project(pr)
                p.fillCircle(lx + 5, legendY + H * 0.009, 4, Self.c(Self.colorFor(pr)))
                p.text(label, lx + 13, legendY - 2, Self.c(Self.DIM), fSmall)
                lx += Painter.measure(label, fSmall).width + 30
            }

            // toolkit + token mix
            let x = chartW + m
            let tw = w - x
            p.text("TOOLKIT TODAY", x, 0, Self.c(Self.ACCENT), fLabel)
            let tools = s.toolsToday.prefix(6)
            let tpeak = Double(max(tools.map(\.1).max() ?? 0, 1))
            let rh = H * 0.021
            var y = legendY
            for (name, c) in tools {
                p.text(name, x, y, Self.c(Self.TEXT), fSmall, width: tw * 0.32)
                p.fill(x + tw * 0.34, y + rh * 0.25, tw * 0.5 * Double(c) / tpeak, rh * 0.5, Self.c(Self.ACCENT, 0.75))
                p.text("\(c)", x + tw * 0.86, y, Self.c(Self.DIM), fSmall)
                y += rh
            }
            let today = s.today
            let out = Double(today["output"] ?? 0)
            let typistH = out * 0.75 / 40 / 60
            let reads = Double(today["cache_read"] ?? 0)
            let fresh = Double((today["input"] ?? 0) + (today["cache_write"] ?? 0))
            let hit = reads + fresh > 0 ? reads / (reads + fresh) * 100 : 0
            y += rh * 0.4
            let lines = [
                "output \(Self.human(out)) · thinking \(Self.human(today["thinking"]))",
                "context read \(Self.human(reads + fresh)) · " + String(format: "cache hit %.0f%%", hit),
                "≈" + Fmt.commas(typistH, 1) + " h of human typing · \(s.sessionsToday) sessions today",
            ]
            for line in lines {
                if y + rh > h { break }
                p.text(line, x, y, Self.c(Self.DIM), fSmall, width: tw)
                y += rh
            }
        }
    }
}
