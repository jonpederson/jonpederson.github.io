import AppKit
import CoreText
import SwiftUI

/// Farm style: an endless ASCII-art farm seen from a drone flying overhead (`farm.py`).
///
/// Each run of `chunk` columns of ground is rasterized once into a bitmap at the
/// display's scale, so a frame only places those bitmaps and draws the few moving
/// things (animals, tractors, traffic, birds, clouds and the camera HUD) on top.
final class FarmStyle: SaverStyle {
    static let chunk = 48          // columns per cached bitmap
    static let rowsOnScreen = 64.0 // sets the font size
    static let speed = 3.0         // drone ground speed, columns per second
    static let swayRows = 6        // the drone drifts up and down by this much

    var drawsOwnClock: Bool { true }

    private let showClock: Bool
    private let timeFormatter = DateFormatter()
    private let shadowImage = AuroraStyle.orbImage(r: 0, g: 0, b: 0)
    private let cloudImage = AuroraStyle.orbImage(r: 1, g: 1, b: 1)

    private var size = CGSize.zero
    private var scale: CGFloat = 0
    private var raster: GlyphRaster!
    private var world: FarmWorld!
    private var chunks: [Int: CGImage] = [:]
    private var sprites: [String: CGImage] = [:]
    private var screenCols = 0
    private var lastT = 0.0

    private var trucks: [Truck] = []
    private var nextTruck = 0.0
    private var birds: Birds?
    private var nextBirds = 0.0
    private var shadows: [Blob] = []
    private var clouds: [Blob] = []

    private struct Blob { var x, y, size: Double }
    private struct Birds {
        var x, y: Double
        let dir, v, vy: Double
        let flock: [(dx: Double, dy: Double, phase: Double)]
    }

    init(showClock: Bool) {
        self.showClock = showClock
        timeFormatter.dateFormat = DriftingClock.timeFormat(seconds: true)
    }

    private func setup(_ size: CGSize, _ scale: CGFloat) {
        self.size = size
        self.scale = scale
        let w = size.width, h = size.height
        raster = GlyphRaster(pointSize: h / Self.rowsOnScreen, scale: scale)
        screenCols = Int(w / raster.cw) + 2
        world = FarmWorld(rows: Int(h / raster.ch) + Self.swayRows + 2)
        chunks = [:]
        sprites = [:]
        trucks = []
        nextTruck = lastT + Rnd.uniform(2, 10)
        birds = nil
        nextBirds = lastT + Rnd.uniform(8, 25)
        shadows = (0..<3).map { _ in Blob(x: Rnd.uniform(0, w * 2), y: Rnd.uniform(0, h), size: Rnd.uniform(0.5, 0.9) * h) }
        clouds = (0..<2).map { _ in Blob(x: w + Rnd.uniform(0, w * 3), y: Rnd.uniform(0, h), size: Rnd.uniform(0.6, 1.1) * h) }
    }

    /// Rounds to whole device pixels, so cached bitmaps are never resampled.
    private func snap(_ v: Double) -> Double { (v * scale).rounded() / scale }

    // MARK: Frame

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, scale: CGFloat) {
        if size != self.size || scale != self.scale { setup(size, scale) }
        let dt = min(max(t - lastT, 0), 0.1)
        lastT = t
        let w = size.width, h = size.height
        let cw = raster.cw, ch = raster.ch
        let chunkW = Double(Self.chunk) * cw
        let scroll = snap(t * Self.speed * cw)
        let sway = snap(Double(Self.swayRows) * ch * 0.5 * (1 - cos(t * 0.045)))
        let col0 = scroll / cw

        // Ground
        let first = Int((scroll / chunkW).rounded(.down)), last = Int(((scroll + w) / chunkW).rounded(.down))
        let groundH = Double(world.rows) * ch
        for ci in first...last {
            guard let img = chunk(ci) else { continue }
            ctx.draw(Image(decorative: img, scale: scale).interpolation(.none),
                     in: CGRect(x: Double(ci) * chunkW - scroll, y: -sway, width: chunkW, height: groundH))
        }
        _ = chunk(last + 1)  // build ahead (cached)
        chunks = chunks.filter { $0.key >= first - 1 }

        // Moving things on the ground
        traffic(t: t, col0: col0)
        world.actors.removeAll { Double($0.x + $0.width) < col0 - 20 }
        for a in world.actors + (trucks as [Mover]) {
            a.update(t: t, dt: dt)
            if Double(a.x + a.width) < col0 - 1 || Double(a.x) > col0 + Double(screenCols) { continue }
            let x = Double(a.x) * cw - scroll, y = Double(a.y) * ch - sway
            ctx.fill(Path(CGRect(x: x, y: y, width: Double(a.width) * cw, height: ch)), with: .color(Color(cgColor: a.bg)))
            if a.kind == .tractor {
                let tx = a.dir > 0 ? x - 3 * cw : x + Double(a.width) * cw
                let trail = a.dir > 0 ? ". :" : ": ."
                drawText(&ctx, trail, Tone.plowed.fg, x: tx, y: y, opacity: 0.7)
            }
            if let img = sprite(a.kind, dir: a.dir) {
                ctx.draw(Image(decorative: img, scale: scale).interpolation(.none),
                         in: CGRect(x: x, y: y, width: Double(a.width) * cw, height: ch))
            }
        }

        sky(&ctx, w: w, h: h, t: t, dt: dt, scroll: scroll)
        hud(&ctx, w: w, h: h, t: t, sway: sway)
    }

    private func chunk(_ ci: Int) -> CGImage? {
        if let img = chunks[ci] { return img }
        guard ci >= 0 else { return nil }
        let world = self.world!
        let img = raster.renderGround(cols: Self.chunk, rows: world.rows) { col, row in
            world.cell(ci * Self.chunk + col, row)
        }
        chunks[ci] = img
        return img
    }

    private func sprite(_ kind: Mover.Kind, dir: Int) -> CGImage? {
        let key = "\(kind)\(dir)"
        if let img = sprites[key] { return img }
        var runs = Mover.sprite(kind)
        if dir < 0 {
            runs = runs.reversed().map { (Self.mirror($0.0), $0.1) }
        }
        let img = raster.renderRuns(runs.map { (Array($0.0.utf8), cgColor(hex: $0.1)) })
        sprites[key] = img
        return img
    }

    private static func mirror(_ s: String) -> String {
        let swap: [Character: Character] = ["<": ">", ">": "<", "(": ")", ")": "(", "[": "]", "]": "[",
                                            "{": "}", "}": "{", "/": "\\", "\\": "/"]
        return String(s.reversed().map { swap[$0] ?? $0 })
    }

    /// Small runs of ground-font text (tractor trails, birds), cached as bitmaps.
    private func drawText(_ ctx: inout GraphicsContext, _ text: String, _ color: CGColor, x: Double, y: Double, opacity: Double) {
        let key = "text:\(text):\(color.components ?? [])"
        var img = sprites[key]
        if img == nil {
            img = raster.renderRuns([(Array(text.utf8), color)])
            sprites[key] = img
        }
        guard let img else { return }
        var c = ctx
        c.opacity *= opacity
        c.draw(Image(decorative: img, scale: scale), in: CGRect(x: x, y: y, width: Double(text.utf8.count) * raster.cw, height: raster.ch))
    }

    private func traffic(t: Double, col0: Double) {
        if t >= nextTruck {
            nextTruck = t + Rnd.uniform(12, 40)
            let road = world.road
            if Rnd.chance(0.5) {  // oncoming
                trucks.append(Truck(x: col0 + Double(screenCols) + 2, y: road + 1, dir: -1, speed: Rnd.uniform(3, 6)))
            } else {  // overtaking the drone
                trucks.append(Truck(x: col0 - 6, y: road + 2, dir: 1, speed: Self.speed + Rnd.uniform(3, 6)))
            }
        }
        trucks.removeAll { !(col0 - 10 < $0.fx && $0.fx < col0 + Double(screenCols) + 10) }
    }

    // MARK: Sky

    private func sky(_ ctx: inout GraphicsContext, w: Double, h: Double, t: Double, dt: Double, scroll: Double) {
        // Cloud shadows sit on the ground and drift slowly with the wind.
        for i in shadows.indices {
            shadows[i].x += 14 * dt
            let x = shadows[i].x - scroll
            if x + shadows[i].size < 0 {
                shadows[i] = Blob(x: scroll + w + Rnd.uniform(0, w), y: Rnd.uniform(-0.2, 1.0) * h, size: Rnd.uniform(0.5, 0.9) * h)
            }
            let s = shadows[i]
            var c = ctx
            c.opacity *= 0.55
            c.draw(shadowImage, in: CGRect(x: s.x - scroll, y: s.y, width: s.size * 1.6, height: s.size))
        }

        // Birds below the drone cross faster than the ground.
        if birds == nil && t >= nextBirds {
            let d = Double(Rnd.sign())
            birds = Birds(x: d > 0 ? -200 : w + 200, y: Rnd.uniform(0.1, 0.8) * h, dir: d,
                          v: Rnd.uniform(90, 160), vy: Rnd.uniform(-15, 15),
                          flock: (0..<Rnd.randint(3, 9)).map { _ in
                              (Rnd.uniform(-120, 120), Rnd.uniform(-60, 60), Rnd.uniform(0, 6))
                          })
        }
        if var b = birds {
            b.x += b.dir * b.v * dt - Self.speed * raster.cw * dt * 0.4
            b.y += b.vy * dt
            let white = cgColor(hex: "#f0f0f0")
            for bird in b.flock {
                drawText(&ctx, sin(t * 7 + bird.phase) > 0 ? "v" : "^", white, x: b.x + bird.dx, y: b.y + bird.dy, opacity: 0.9)
            }
            if b.x < -400 || b.x > w + 400 {
                birds = nil
                nextBirds = t + Rnd.uniform(20, 60)
            } else {
                birds = b
            }
        }

        // Wisps of cloud between the drone and the ground race past.
        for i in clouds.indices {
            clouds[i].x -= Self.speed * raster.cw * 2.4 * dt
            if clouds[i].x + clouds[i].size * 2 < 0 {
                clouds[i] = Blob(x: w + Rnd.uniform(w, w * 4), y: Rnd.uniform(-0.2, 1.0) * h, size: Rnd.uniform(0.6, 1.1) * h)
            }
            let c = clouds[i]
            var g = ctx
            g.opacity *= 0.22
            g.draw(cloudImage, in: CGRect(x: c.x, y: c.y, width: c.size * 2, height: c.size))
        }
    }

    // MARK: Camera overlay

    private func hud(_ ctx: inout GraphicsContext, w: Double, h: Double, t: Double, sway: Double) {
        // Everything drifts a few points over time so the HUD never burns in.
        let jx = 8 * sin(t * 0.011), jy = 8 * cos(t * 0.017)
        let m = h * 0.045
        let white = Color.white.opacity(0.55)
        let arm = h * 0.05, th = max(2.0, h / 600)
        for (cx, cy, sx, sy) in [(m, m, 1.0, 1.0), (w - m, m, -1.0, 1.0), (m, h - m, 1.0, -1.0), (w - m, h - m, -1.0, -1.0)] {
            let x = cx + jx, y = cy + jy
            ctx.fill(Path(CGRect(x: min(x, x + sx * arm), y: y - (sy < 0 ? th : 0), width: arm, height: th)), with: .color(white))
            ctx.fill(Path(CGRect(x: x - (sx < 0 ? th : 0), y: min(y, y + sy * arm), width: th, height: arm)), with: .color(white))
        }
        let cx = w / 2 + jx, cy = h / 2 + jy, c = h * 0.018
        let faint = GraphicsContext.Shading.color(.white.opacity(0.3))
        ctx.fill(Path(CGRect(x: cx - c, y: cy - th / 2, width: c * 0.6, height: th)), with: faint)
        ctx.fill(Path(CGRect(x: cx + c * 0.4, y: cy - th / 2, width: c * 0.6, height: th)), with: faint)
        ctx.fill(Path(CGRect(x: cx - th / 2, y: cy - c, width: th, height: c * 0.6)), with: faint)
        ctx.fill(Path(CGRect(x: cx - th / 2, y: cy + c * 0.4, width: th, height: c * 0.6)), with: faint)

        let tx = m + arm * 0.4 + jx, ty = m + arm * 0.3 + jy
        if Int(t * 1.2) % 2 == 0 {  // blinking record light
            let d = raster.ch * 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: tx, y: ty + d / 2, width: d, height: d)),
                     with: .color(Color(red: 1, green: 0.25, blue: 0.25).opacity(0.9)))
        }
        let el = Int(t)
        hudText(&ctx, String(format: "  REC  %02d:%02d:%02d", el / 3600, el / 60 % 60, el % 60), x: tx, y: ty)
        if showClock {
            hudText(&ctx, timeFormatter.string(from: Date()), right: w - m - arm * 0.4 + jx, y: ty)
        }
        let alt = 120 + sway / raster.ch * 1.5
        let by = h - m - arm * 0.3 - raster.ch + jy
        hudText(&ctx, String(format: "ALT %5.1fm   SPD 8.4m/s   HDG 090°", alt), x: tx, y: by)
        let lon = 71.0589 - t * 0.00008
        hudText(&ctx, String(format: "N 42.3601°  W %08.4f°", lon), right: w - m - arm * 0.4 + jx, y: by)
    }

    private func hudText(_ ctx: inout GraphicsContext, _ s: String, x: Double? = nil, right: Double? = nil, y: Double) {
        let text = ctx.resolve(Text(s).font(Font(raster.font)).foregroundColor(.white.opacity(0.7)))
        let left = x ?? ((right ?? 0) - text.measure(in: size).width)
        ctx.draw(text, at: CGPoint(x: left, y: y), anchor: .topLeading)
    }
}

/// Draws monospaced ASCII into bitmaps on a grid of whole device pixels.
final class GlyphRaster {
    let font: CTFont
    let scale: CGFloat
    let cw: CGFloat        // cell width in points (a whole number of pixels)
    let ch: CGFloat        // cell height in points (a whole number of pixels)
    private let cwPx: Int
    private let chPx: Int
    private let baseline: CGFloat  // from the top of a cell
    private var glyphs = [CGGlyph](repeating: 0, count: 128)

    init(pointSize: CGFloat, scale: CGFloat) {
        font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular) as CTFont
        self.scale = scale
        let chars = (0..<128).map { UniChar($0) }
        _ = CTFontGetGlyphsForCharacters(font, chars, &glyphs, 128)
        var m = glyphs[Int(UInt8(ascii: "M"))]
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &m, &advance, 1)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        cwPx = max(1, Int((advance.width * scale).rounded()))
        chPx = max(1, Int(((ascent + descent + leading) * scale).rounded()))
        cw = CGFloat(cwPx) / scale
        ch = CGFloat(chPx) / scale
        baseline = (ch - (ascent + descent)) / 2 + ascent
    }

    private func context(cols: Int, rows: Int) -> CGContext? {
        let ctx = CGContext(data: nil, width: cols * cwPx, height: rows * chPx, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.scaleBy(x: scale, y: scale)
        ctx?.setShouldAntialias(true)
        return ctx
    }

    /// A block of ground: every cell gets its background, then the characters
    /// are drawn in one batch per colour.
    func renderGround(cols: Int, rows: Int, cell: (Int, Int) -> Cell) -> CGImage? {
        guard let ctx = context(cols: cols, rows: rows) else { return nil }
        let height = CGFloat(rows) * ch
        var batches: [Tone: ([CGGlyph], [CGPoint])] = [:]
        for row in 0..<rows {
            let top = height - CGFloat(row + 1) * ch  // Core Graphics counts up from the bottom
            var runStart = 0
            var runBG: CGColor?
            func flush(_ end: Int) {
                guard let bg = runBG else { return }
                ctx.setFillColor(bg)
                ctx.fill(CGRect(x: CGFloat(runStart) * cw, y: top, width: CGFloat(end - runStart) * cw, height: ch))
            }
            for col in 0..<cols {
                let c = cell(col, row)
                let bg = c.tone.bg
                if bg != runBG {
                    flush(col)
                    runBG = bg
                    runStart = col
                }
                if c.ch != UInt8(ascii: " ") && c.ch < 128 {
                    batches[c.tone, default: ([], [])].0.append(glyphs[Int(c.ch)])
                    batches[c.tone, default: ([], [])].1.append(CGPoint(x: CGFloat(col) * cw, y: height - CGFloat(row) * ch - baseline))
                }
            }
            flush(cols)
        }
        for (tone, batch) in batches {
            ctx.setFillColor(tone.fg)
            batch.0.withUnsafeBufferPointer { g in
                batch.1.withUnsafeBufferPointer { p in
                    CTFontDrawGlyphs(font, g.baseAddress!, p.baseAddress!, g.count, ctx)
                }
            }
        }
        return ctx.makeImage()
    }

    /// One line of coloured runs on a transparent background.
    func renderRuns(_ runs: [([UInt8], CGColor)]) -> CGImage? {
        let cols = runs.reduce(0) { $0 + $1.0.count }
        guard cols > 0, let ctx = context(cols: cols, rows: 1) else { return nil }
        var col = 0
        for (text, color) in runs {
            var g: [CGGlyph] = []
            var p: [CGPoint] = []
            for c in text {
                if c != UInt8(ascii: " ") && c < 128 {
                    g.append(glyphs[Int(c)])
                    p.append(CGPoint(x: CGFloat(col) * cw, y: ch - baseline))
                }
                col += 1
            }
            if !g.isEmpty {
                ctx.setFillColor(color)
                CTFontDrawGlyphs(font, g, p, g.count, ctx)
            }
        }
        return ctx.makeImage()
    }
}
