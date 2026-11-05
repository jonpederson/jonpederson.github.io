import SwiftUI

/// One style's animation. Each display gets its own instance (as each Linux window
/// gets its own Scene), so random layouts differ between screens.
protocol SaverStyle: AnyObject {
    /// Farm, HUD and Agents show the time themselves, so they skip the drifting clock.
    var drawsOwnClock: Bool { get }
    func advance(dt: Double, size: CGSize)
    /// `scale` is the display's backing scale (2 on Retina), for styles that rasterize.
    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, scale: CGFloat)
}

extension SaverStyle {
    var drawsOwnClock: Bool { false }
    func advance(dt: Double, size: CGSize) {}
}

enum Styles {
    static func make(_ config: Config) -> SaverStyle {
        switch config.renderStyle {
        case .aurora: return AuroraStyle()
        case .starfield: return StarfieldStyle()
        case .farm: return FarmStyle(showClock: config.showClock)
        case .black: return BlackStyle()
        case .hud: return HudStyle(config: config)
        case .agents: return AuroraStyle()  // not built yet (a later phase)
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
        style = Styles.make(config)
        clock = config.showClock && !style.drawsOwnClock ? DriftingClock() : nil
    }

    func render(_ ctx: inout GraphicsContext, size: CGSize, now: Date, scale: CGFloat) {
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
        style.draw(&ctx, size: size, t: t, scale: scale)
        clock?.draw(&ctx, size: size)
    }
}

struct SceneView: View {
    let model: SceneModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    model.render(&ctx, size: size, now: timeline.date, scale: displayScale)
                }
            }
            if let hud = model.style as? HudStyle {
                HudOverlayView(model: hud.overlay)  // NASA's live ISS stream
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

final class BlackStyle: SaverStyle {
    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, scale: CGFloat) {}
}
