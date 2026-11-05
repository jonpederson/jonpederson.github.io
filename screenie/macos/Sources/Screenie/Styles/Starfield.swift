import SwiftUI

/// 500 stars flying toward the viewer (`saver.py`).
final class StarfieldStyle: SaverStyle {
    private struct Star {
        var x, y, z: Double
    }

    private var stars: [Star]

    init() {
        stars = (0..<500).map { _ in Self.newStar(z: .random(in: 0.05...1.0)) }
    }

    private static func newStar(z: Double = 1.0) -> Star {
        Star(x: .random(in: -1...1), y: .random(in: -1...1), z: z)
    }

    func advance(dt: Double, size: CGSize) {
        for i in stars.indices {
            stars[i].z -= dt * 0.12
            if stars[i].z <= 0.02 { stars[i] = Self.newStar() }
        }
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let cx = w / 2, cy = h / 2
        let f = max(w, h) * 0.5
        for s in stars {
            let sx = cx + s.x / s.z * f * 0.5
            let sy = cy + s.y / s.z * f * 0.5
            guard sx >= 0, sx < w, sy >= 0, sy < h else { continue }
            let near = 1.0 - s.z
            let d = 0.8 + near * 3.2
            let b = min(1.0, near * 1.3)
            ctx.fill(Path(CGRect(x: sx - d / 2, y: sy - d / 2, width: d, height: d)),
                     with: .color(Color(red: 0.8 + 0.2 * b, green: 0.85 + 0.15 * b, blue: 1.0, opacity: b)))
        }
    }
}
