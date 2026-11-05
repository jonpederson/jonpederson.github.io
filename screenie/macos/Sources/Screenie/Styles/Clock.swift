import SwiftUI

/// Time and date that drift slowly and bounce off the edges so nothing burns in.
final class DriftingClock {
    private var pos: CGPoint?
    private var vel: CGVector
    private let timeFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()

    init() {
        vel = CGVector(dx: (Bool.random() ? 1 : -1) * 18.0, dy: (Bool.random() ? 1 : -1) * 13.0)
        // Follow the system's 12/24-hour preference, without an AM/PM marker (like Linux).
        let hourPattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        timeFormatter.dateFormat = hourPattern.contains("a") ? "h:mm" : "HH:mm"
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
    }

    func advance(dt: Double) {
        guard let p = pos else { return }
        pos = CGPoint(x: p.x + vel.dx * dt, y: p.y + vel.dy * dt)
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let now = Date()
        let big = ctx.resolve(Text(timeFormatter.string(from: now))
            .font(.system(size: h * 0.13, weight: .light))
            .foregroundColor(.white.opacity(0.85)))
        let small = ctx.resolve(Text(dateFormatter.string(from: now))
            .font(.system(size: h * 0.03, weight: .regular))
            .foregroundColor(.white.opacity(0.6)))
        let bs = big.measure(in: size)
        let ss = small.measure(in: size)
        let cw = max(bs.width, ss.width), ch = bs.height + ss.height

        var p = pos ?? CGPoint(x: (w - cw) / 2, y: (h - ch) / 2)
        if p.x < 0 || p.x + cw > w {
            if (p.x < 0) == (vel.dx < 0) { vel.dx = -vel.dx }
        }
        if p.y < 0 || p.y + ch > h {
            if (p.y < 0) == (vel.dy < 0) { vel.dy = -vel.dy }
        }
        p.x = min(max(p.x, 0), max(w - cw, 0))
        p.y = min(max(p.y, 0), max(h - ch, 0))
        pos = p

        ctx.draw(big, at: CGPoint(x: p.x + (cw - bs.width) / 2, y: p.y), anchor: .topLeading)
        ctx.draw(small, at: CGPoint(x: p.x + (cw - ss.width) / 2, y: p.y + bs.height), anchor: .topLeading)
    }
}
