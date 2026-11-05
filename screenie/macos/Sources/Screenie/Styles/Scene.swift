import SwiftUI

/// One style's animation. Each display gets its own instance (as each Linux window
/// gets its own Scene), so random layouts differ between screens.
protocol SaverStyle: AnyObject {
    /// Farm, HUD and Agents show the time themselves, so they skip the drifting clock.
    var drawsOwnClock: Bool { get }
    func advance(dt: Double, size: CGSize)
    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double)
}

extension SaverStyle {
    var drawsOwnClock: Bool { false }
    func advance(dt: Double, size: CGSize) {}
}

enum Styles {
    static func make(_ id: StyleID) -> SaverStyle {
        switch id {
        case .aurora: return AuroraStyle()
        case .starfield: return StarfieldStyle()
        case .black: return BlackStyle()
        case .farm, .hud, .agents: return AuroraStyle()  // not built yet (later phases)
        }
    }
}

/// Frame timing and the parts every style shares: black backdrop, fade in, clock.
final class SceneModel {
    static let fadeSeconds = 1.5

    let style: SaverStyle
    let clock: DriftingClock?
    private var start: TimeInterval?
    private var last: TimeInterval = 0

    init(config: Config) {
        style = Styles.make(config.renderStyle)
        clock = config.showClock && !style.drawsOwnClock ? DriftingClock() : nil
    }

    func render(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        guard size.width > 0, size.height > 0 else { return }
        let time = now.timeIntervalSinceReferenceDate
        if start == nil {
            start = time
            last = time
        }
        let dt = min(max(time - last, 0), 0.1)
        last = time
        let t = time - (start ?? time)

        style.advance(dt: dt, size: size)
        clock?.advance(dt: dt)

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        ctx.opacity = min(1, t / Self.fadeSeconds)
        style.draw(&ctx, size: size, t: t)
        clock?.draw(&ctx, size: size)
    }
}

struct SceneView: View {
    let model: SceneModel

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                model.render(&ctx, size: size, now: timeline.date)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

final class BlackStyle: SaverStyle {
    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {}
}
