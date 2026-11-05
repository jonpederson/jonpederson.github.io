import CoreGraphics
import SwiftUI

/// Seven soft glows drifting on Lissajous paths over near-black (`saver.py`).
final class AuroraStyle: SaverStyle {
    static let colors: [(Double, Double, Double)] = [
        (0.20, 0.45, 1.00),
        (0.55, 0.25, 0.95),
        (0.10, 0.80, 0.75),
        (0.95, 0.35, 0.60),
        (0.25, 0.65, 1.00),
    ]

    private struct Orb {
        let image: Image
        let fx, fy, px, py, fr, size: Double
    }

    private let orbs: [Orb]

    init() {
        orbs = (0..<7).map { i in
            let c = Self.colors[i % Self.colors.count]
            return Orb(image: Self.orbImage(r: c.0, g: c.1, b: c.2),
                       fx: .random(in: 0.03...0.08), fy: .random(in: 0.03...0.08),
                       px: .random(in: 0...6.28), py: .random(in: 0...6.28),
                       fr: .random(in: 0.05...0.12), size: .random(in: 0.7...1.2))
        }
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, scale: CGFloat) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(Color(red: 0.01, green: 0.01, blue: 0.04)))
        let base = max(w, h) * 0.75
        for o in orbs {
            let s = base * o.size * (1 + 0.25 * sin(t * o.fr * 6.28))
            let cx = w * (0.5 + 0.45 * sin(t * o.fx * 6.28 + o.px))
            let cy = h * (0.5 + 0.45 * sin(t * o.fy * 6.28 + o.py))
            ctx.draw(o.image, in: CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s))
        }
    }

    /// A soft radial glow, rendered once and scaled up on the GPU every frame.
    static func orbImage(r: Double, g: Double, b: Double, size: Int = 256) -> Image {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Image(systemName: "circle.fill")
        }
        let colors = [
            CGColor(colorSpace: space, components: [r, g, b, 0.38])!,
            CGColor(colorSpace: space, components: [r, g, b, 0.14])!,
            CGColor(colorSpace: space, components: [r, g, b, 0.0])!,
        ] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.4, 1])!
        let center = CGPoint(x: Double(size) / 2, y: Double(size) / 2)
        cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                              endCenter: center, endRadius: Double(size) / 2, options: [])
        guard let image = cg.makeImage() else { return Image(systemName: "circle.fill") }
        return Image(decorative: image, scale: 1)
    }
}
