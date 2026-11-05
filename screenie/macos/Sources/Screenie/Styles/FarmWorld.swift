import CoreGraphics
import Foundation

// The procedurally generated farm (`farm.py`): bands of fields, hedges and fences,
// a road, and the animals and vehicles moving on them. Pure model, no drawing.

/// Colour pairs (foreground, background) for every kind of ground cell.
enum Tone: CaseIterable {
    case grass, flower, wheat, wheat2, corn, corn2, soil, plowed, cabbage, sunflower, sunleaf
    case hay, bale, tree, tree2, water, water2, reed, hedge, hedge2, fence, road, verge, yard
    case barn, barnedge, roof, roofedge, silo

    var hex: (fg: String, bg: String) {
        switch self {
        case .grass: return ("#4f9a3a", "#10200d")
        case .flower: return ("#e8d84a", "#10200d")
        case .wheat: return ("#d9b54a", "#2b230e")
        case .wheat2: return ("#b08a36", "#2b230e")
        case .corn: return ("#6fc04a", "#18160c")
        case .corn2: return ("#4f9a34", "#18160c")
        case .soil: return ("#6a4e30", "#1d150c")
        case .plowed: return ("#8c6a40", "#1d150c")
        case .cabbage: return ("#9ad46c", "#17140b")
        case .sunflower: return ("#f2c41e", "#1a1c0c")
        case .sunleaf: return ("#5c9a34", "#1a1c0c")
        case .hay: return ("#b89a50", "#262010")
        case .bale: return ("#f0d27a", "#262010")
        case .tree: return ("#3f8f3a", "#0b1a09")
        case .tree2: return ("#6cbf4e", "#0b1a09")
        case .water: return ("#5a9ae0", "#0c1c33")
        case .water2: return ("#9ccaf4", "#0c1c33")
        case .reed: return ("#7aa83e", "#10200d")
        case .hedge: return ("#2f7a2e", "#0a160a")
        case .hedge2: return ("#459a3c", "#0a160a")
        case .fence: return ("#a89272", "#10200d")
        case .road: return ("#8a7456", "#2c2216")
        case .verge: return ("#6a8a3a", "#18200f")
        case .yard: return ("#8a8478", "#1e1c18")
        case .barn: return ("#d0503e", "#3a1210")
        case .barnedge: return ("#ece4d4", "#3a1210")
        case .roof: return ("#a8a8b4", "#26262e")
        case .roofedge: return ("#e8e8f0", "#26262e")
        case .silo: return ("#c8ccd4", "#2a2c30")
        }
    }

    private static let colors: [Tone: (fg: CGColor, bg: CGColor)] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, (cgColor(hex: $0.hex.fg), cgColor(hex: $0.hex.bg))) })

    var fg: CGColor { Tone.colors[self]!.fg }
    var bg: CGColor { Tone.colors[self]!.bg }
}

func cgColor(hex: String, alpha: CGFloat = 1) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

/// Deterministic per-cell hash, so the same world cell always looks the same.
@inline(__always)
func h2(_ x: Int, _ y: Int, _ s: Int) -> Int {
    let a: UInt32 = 374_761_393, b: UInt32 = 668_265_263, c: UInt32 = 2_246_822_519, m: UInt32 = 1_274_126_177
    var n = UInt32(truncatingIfNeeded: x) &* a &+ UInt32(truncatingIfNeeded: y) &* b &+ UInt32(truncatingIfNeeded: s) &* c
    n = (n ^ (n >> 13)) &* m
    return Int(n ^ (n >> 16))
}

/// Python's `random` helpers.
enum Rnd {
    static func uniform(_ a: Double, _ b: Double) -> Double { a < b ? Double.random(in: a..<b) : a }
    static func randint(_ a: Int, _ b: Int) -> Int { Int.random(in: a...max(a, b)) }
    static func chance(_ p: Double) -> Bool { Double.random(in: 0..<1) < p }
    static func sign() -> Int { Bool.random() ? 1 : -1 }
    static func choice<T>(_ items: [T]) -> T { items.randomElement()! }
    static func weighted<T>(_ items: [(T, Int)]) -> T {
        var r = Int.random(in: 0..<items.reduce(0) { $0 + $1.1 })
        for (item, w) in items {
            if r < w { return item }
            r -= w
        }
        return items[items.count - 1].0
    }
}

typealias Cell = (ch: UInt8, tone: Tone)

private let space = UInt8(ascii: " ")

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

private func pick(_ chars: [UInt8], _ i: Int) -> UInt8 { chars[i % chars.count] }

private let grassChars = bytes(".,'\"")
private let hayChars = bytes(",'`.")
private let vergeChars = bytes(",'\".")
private let hedgeChars = bytes("%&%@")
private let edgeChars = Set(bytes(".-|'()"))

private let treeArt = [" ,@@@, ", "@@@%@@@", " '@@@' ", "       "].map(bytes)
private let barnArt = [".------------.", "|" + String(repeating: "\\", count: 12) + "|", "|============|",
                       "|////////////|", "'------------'"].map(bytes)
private let houseArt = [".--------.", "|##n#####|", "|########|", "'--------'"].map(bytes)
private let siloArt = [" .--. ", "( () )", " '--' "].map(bytes)

final class Field {
    enum Kind: CaseIterable {
        case pasture, wheat, corn, plowed, hay, orchard, cabbage, sunflower, pond, farmstead
    }

    static let kinds: [(Kind, Int)] = [
        (.pasture, 4), (.wheat, 3), (.corn, 3), (.plowed, 2), (.hay, 2),
        (.orchard, 2), (.cabbage, 1), (.sunflower, 1), (.pond, 1), (.farmstead, 1),
    ]

    private struct Building {
        let x, y: Int
        let art: [[UInt8]]
        let edge, inner: Tone
        var w: Int { art[0].count }
        var h: Int { art.count }
    }

    let x0, y0, w, h: Int   // interior, world cells
    let seed = Int.random(in: 0..<(1 << 30))
    let vert = Bool.random()
    private(set) var kind: Kind
    private var buildings: [Building] = []
    private(set) var yard = (x0: 0, y0: 0, x1: 0, y1: 0)
    private var cx = 0.0, cy = 0.0, rx = 1.0, ry = 1.0

    init(x0: Int, y0: Int, w: Int, h: Int, kind: Kind) {
        self.x0 = x0
        self.y0 = y0
        self.w = w
        self.h = h
        self.kind = kind
        if kind == .farmstead && !layoutFarm() { self.kind = .pasture }
        if self.kind == .pond {
            cx = Double(w) / 2 - 0.5
            cy = Double(h) / 2 - 0.5
            rx = max(Double(w) * 0.38, 2)
            ry = max(Double(h) * 0.36, 1.5)
        }
    }

    var baseTone: Tone {
        switch kind {
        case .pasture, .pond, .farmstead: return .grass
        case .orchard: return .tree
        case .wheat: return .wheat
        case .corn: return .corn
        case .plowed: return .plowed
        case .hay: return .hay
        case .cabbage: return .cabbage
        case .sunflower: return .sunflower
        }
    }

    var bg: CGColor { baseTone.bg }

    private func layoutFarm() -> Bool {
        if w < 20 || h < 7 { return false }
        func fits(_ x: Int, _ y: Int, _ art: [[UInt8]]) -> Bool {
            let sw = art[0].count, sh = art.count
            if x < 1 || y < 1 || x + sw > w - 1 || y + sh > h - 1 { return false }
            return buildings.allSatisfy { p in
                x + sw + 1 <= p.x || p.x + p.w + 1 <= x || y + sh + 1 <= p.y || p.y + p.h + 1 <= y
            }
        }
        @discardableResult
        func place(_ art: [[UInt8]], _ edge: Tone, _ inner: Tone, _ spots: [(Int, Int)]) -> Bool {
            for (x, y) in spots where fits(x, y, art) {
                buildings.append(Building(x: x, y: y, art: art, edge: edge, inner: inner))
                return true
            }
            return false
        }
        let bx = 2, by = 1 + Rnd.randint(0, max(0, h - 8))
        if !place(barnArt, .barnedge, .barn, [(bx, by)]) { return false }
        place(houseArt, .roofedge, .roof, [(bx + 17, by), (bx + 17, by + 1), (bx, by + 7)])
        place(siloArt, .silo, .silo, [(bx + 15, by + 3), (bx + 2, by + 6), (bx + 29, by)])
        let yx0 = buildings.map(\.x).min()! - 1
        let yy0 = buildings.map(\.y).min()! - 1
        let yx1 = buildings.map { $0.x + $0.w }.max()! + 1
        let yy1 = buildings.map { $0.y + $0.h }.max()! + 1
        yard = (max(yx0, 0), max(yy0, 0), min(yx1, w), min(yy1, h))
        return true
    }

    func cell(_ lx: Int, _ ly: Int) -> Cell {
        let hs = h2(lx + x0, ly + y0, seed)
        let (a, b) = vert ? (lx, ly) : (ly, lx)  // a = row index, b = position along row
        switch kind {
        case .wheat:
            return (UInt8(ascii: a % 2 == 0 ? ";" : ":"), hs % 5 != 0 ? .wheat : .wheat2)
        case .corn:
            if a % 2 == 0 {
                return (UInt8(ascii: hs % 3 != 0 ? "Y" : "y"), hs % 4 != 0 ? .corn : .corn2)
            }
            return (hs % 6 == 0 ? UInt8(ascii: ".") : space, .soil)
        case .plowed:
            if vert {
                return (UInt8(ascii: a % 2 == 0 ? "|" : ":"), a % 2 == 0 ? .plowed : .soil)
            }
            return (UInt8(ascii: a % 2 == 0 ? "=" : "-"), a % 2 == 0 ? .plowed : .soil)
        case .cabbage:
            if a % 2 == 0 && b % 2 == 0 {
                return (UInt8(ascii: hs % 5 != 0 ? "o" : "@"), .cabbage)
            }
            return (hs % 5 == 0 ? UInt8(ascii: ".") : space, .soil)
        case .sunflower:
            if a % 2 == 0 {
                return (UInt8(ascii: hs % 4 != 0 ? "*" : "o"), .sunflower)
            }
            return (UInt8(ascii: hs % 3 == 0 ? "," : "."), .sunleaf)
        case .hay:
            if 1 <= lx && lx < w - 2 && 1 <= ly && ly < h - 1 && hs % 47 == 0 {
                return (UInt8(ascii: "O"), .bale)
            }
            return (hs % 3 != 0 ? pick(hayChars, hs % 4) : space, .hay)
        case .orchard:
            let shift = (ly / 4) % 2 != 0 ? 3 : 0
            let ch = treeArt[ly % 4][(lx + shift) % 7]
            if ch != space {
                return (ch, ch == UInt8(ascii: "%") ? .tree2 : .tree)
            }
            return Self.grass(hs)
        case .pond:
            let dx = (Double(lx) - cx) / rx, dy = (Double(ly) - cy) / ry
            let d = dx * dx + dy * dy
            if d < 0.8 {
                return (UInt8(ascii: (lx + ly * 3) % 5 != 0 ? "~" : "-"), hs % 6 != 0 ? .water : .water2)
            }
            if d < 1.0 { return (hs % 3 != 0 ? UInt8(ascii: "~") : space, .water) }
            if d < 1.35 { return (UInt8(ascii: hs % 2 != 0 ? "\"" : "'"), .reed) }
            return Self.grass(hs)
        case .farmstead:
            for o in buildings where o.x <= lx && lx < o.x + o.w && o.y <= ly && ly < o.y + o.h {
                let ch = o.art[ly - o.y][lx - o.x]
                if ch != space { return (ch, edgeChars.contains(ch) ? o.edge : o.inner) }
            }
            if yard.x0 <= lx && lx < yard.x1 && yard.y0 <= ly && ly < yard.y1 {
                return (hs % 4 == 0 ? UInt8(ascii: ".") : space, .yard)
            }
            return Self.grass(hs)
        case .pasture:
            return Self.grass(hs)
        }
    }

    private static func grass(_ hs: Int) -> Cell {
        if hs % 97 == 0 { return (UInt8(ascii: "*"), .flower) }
        return (hs % 6 == 0 ? pick(grassChars, hs % 4) : space, .grass)
    }
}

final class Band {
    enum Separator { case hedge, fence, lane }

    let x0, w: Int
    let sep: Separator
    let sepw: Int
    var fields: [(field: Field, border: Int?)] = []

    init(x0: Int, w: Int, sep: Separator) {
        self.x0 = x0
        self.w = w
        self.sep = sep
        switch sep {
        case .hedge: sepw = 2
        case .fence: sepw = 1
        case .lane: sepw = 2
        }
    }
}

final class FarmWorld {
    let rows: Int
    let road: Int  // 4 rows: verge, lane, lane, verge
    private var bands: [Band] = []
    private var bandX: [Int] = []
    private var nextX = 0
    var actors: [Mover] = []

    init(rows: Int) {
        self.rows = rows
        road = Int(Double(rows) * 0.58)
    }

    private func newBand() {
        let band = Band(x0: nextX, w: Rnd.randint(24, 56), sep: Rnd.choice([.hedge, .hedge, .fence, .fence, .lane]))
        var hasFarm = false
        for (top, bottom) in [(0, road), (road + 4, rows)] {
            var y = top
            while y < bottom {
                var h = Rnd.randint(8, 18)
                if bottom - (y + h) < 6 { h = bottom - y }
                let last = y + h >= bottom
                var kind = Rnd.weighted(Field.kinds)
                if kind == .farmstead && hasFarm { kind = .pasture }
                let f = Field(x0: band.x0, y0: y, w: band.w - band.sepw, h: h - (last ? 0 : 1), kind: kind)
                hasFarm = hasFarm || f.kind == .farmstead
                band.fields.append((f, last ? nil : y + h - 1))
                spawn(f)
                y += h
            }
        }
        bands.append(band)
        bandX.append(band.x0)
        nextX += band.w
    }

    private func spawn(_ f: Field) {
        switch f.kind {
        case .pasture:
            let kind: Mover.Kind = Rnd.choice([.cow, .cow, .sheep])
            for _ in 0..<max(1, f.w * f.h / 150) {
                actors.append(Animal(kind, field: f))
            }
        case .farmstead:
            let y = f.yard  // the yard's bottom strip is clear of buildings
            for _ in 0..<Rnd.randint(2, 4) {
                actors.append(Animal(.chicken, field: f, area: (y.x0, y.y1 - 1, y.x1, y.y1)))
            }
        case .wheat, .hay, .plowed:
            if Rnd.chance(0.3) && f.w > 12 && f.h > 2 { actors.append(Tractor(field: f)) }
        default:
            break
        }
    }

    private func band(at x: Int) -> Band {
        while nextX <= x { newBand() }
        // bisect_right(bandX, x) - 1
        var lo = 0, hi = bandX.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bandX[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return bands[max(lo - 1, 0)]
    }

    func cell(_ x: Int, _ y: Int) -> Cell {
        if road <= y && y < road + 4 {
            let hs = h2(x, y, 7)
            if y == road || y == road + 3 {
                return (hs % 3 == 0 ? pick(vergeChars, hs % 4) : space, .verge)
            }
            return (hs % 9 == 0 ? UInt8(ascii: ":") : hs % 4 == 0 ? UInt8(ascii: ".") : space, .road)
        }
        let band = band(at: x)
        let lx = x - band.x0
        let hs = h2(x, y, 3)
        if lx >= band.w - band.sepw {
            return Self.separator(band.sep, hs, vertical: true, along: y)
        }
        for (f, border) in band.fields {
            if border == y { return Self.separator(band.sep, hs, vertical: false, along: x) }
            if f.y0 <= y && y < f.y0 + f.h { return f.cell(lx, y - f.y0) }
        }
        return (space, .grass)
    }

    private static func separator(_ kind: Band.Separator, _ hs: Int, vertical: Bool, along: Int) -> Cell {
        switch kind {
        case .hedge:
            return (pick(hedgeChars, hs % 4), hs % 3 != 0 ? .hedge : .hedge2)
        case .fence:
            if vertical { return (UInt8(ascii: along % 4 == 0 ? "+" : "|"), .fence) }
            return (UInt8(ascii: along % 6 == 0 ? "+" : "-"), .fence)
        case .lane:
            return (hs % 5 == 0 ? UInt8(ascii: ":") : hs % 2 != 0 ? UInt8(ascii: ".") : space, .road)
        }
    }
}

// MARK: Moving things

class Mover {
    enum Kind { case cow, sheep, chicken, tractor, truck }

    let kind: Kind
    let width: Int
    let bg: CGColor
    var dir: Int
    var y: Int

    init(kind: Kind, width: Int, bg: CGColor, dir: Int, y: Int) {
        self.kind = kind
        self.width = width
        self.bg = bg
        self.dir = dir
        self.y = y
    }

    var x: Int { 0 }
    func update(t: Double, dt: Double) {}

    /// Coloured runs, facing right (mirrored when facing left).
    static func sprite(_ kind: Kind) -> [(String, String)] {
        switch kind {
        case .cow: return [("~(", "#f0ece0"), ("##", "#8a5a34"), (")>", "#f0ece0")]
        case .sheep: return [("{@@}", "#f6f6f2"), (">", "#b0b0b0")]
        case .chicken: return [("o", "#ffffff"), (">", "#f0a030")]
        case .tractor: return [("=", "#9a9a9a"), ("[##]", "#3fae4a"), (">", "#ffe066")]
        case .truck: return [("[==]", "#e0483a"), (">", "#ffe066")]
        }
    }

    static func spriteWidth(_ kind: Kind) -> Int { sprite(kind).reduce(0) { $0 + $1.0.count } }
}

final class Animal: Mover {
    private var cx: Int
    private let bounds: (x0: Int, y0: Int, x1: Int, y1: Int)
    private var nextT = Rnd.uniform(0, 3)

    init(_ kind: Kind, field: Field, area: (Int, Int, Int, Int)? = nil) {
        let width = Mover.spriteWidth(kind)
        let (ax0, ay0, ax1, ay1) = area ?? (0, 0, field.w, field.h)
        bounds = (field.x0 + ax0, field.y0 + ay0, field.x0 + ax1 - width, field.y0 + ay1 - 1)
        cx = Rnd.randint(bounds.x0, max(bounds.x0, bounds.x1))
        let y = Rnd.randint(bounds.y0, max(bounds.y0, bounds.y1))
        super.init(kind: kind, width: width, bg: area == nil ? field.bg : Tone.yard.bg, dir: Rnd.sign(), y: y)
    }

    override var x: Int { cx }

    override func update(t: Double, dt: Double) {
        guard t >= nextT else { return }
        nextT = t + (kind == .chicken ? Rnd.uniform(0.2, 1.2) : Rnd.uniform(1.0, 4.0))
        if Rnd.chance(0.25) {
            dir = -dir
            return
        }
        cx = min(max(cx + dir, bounds.x0), max(bounds.x0, bounds.x1))
        if Rnd.chance(0.3) {
            y = min(max(y + Rnd.sign(), bounds.y0), max(bounds.y0, bounds.y1))
        }
    }
}

final class Tractor: Mover {
    private var fx: Double
    private let x0, x1: Double
    private let speed = Rnd.uniform(1.0, 1.8)

    init(field: Field) {
        let width = 6
        x0 = Double(field.x0 + 1)
        x1 = Double(field.x0 + field.w - width - 1)
        fx = Rnd.uniform(x0, x1)
        super.init(kind: .tractor, width: width, bg: field.bg, dir: Rnd.sign(),
                   y: field.y0 + Rnd.randint(0, field.h - 1))
    }

    override var x: Int { Int(fx) }

    override func update(t: Double, dt: Double) {
        fx += Double(dir) * speed * dt
        if fx > x1 || fx < x0 {
            dir = -dir
            fx = min(max(fx, x0), x1)
        }
    }
}

final class Truck: Mover {
    private(set) var fx: Double
    private let speed: Double

    init(x: Double, y: Int, dir: Int, speed: Double) {
        fx = x
        self.speed = speed
        super.init(kind: .truck, width: 5, bg: Tone.road.bg, dir: dir, y: y)
    }

    override var x: Int { Int(fx) }

    override func update(t: Double, dt: Double) {
        fx += Double(dir) * speed * dt
    }
}
