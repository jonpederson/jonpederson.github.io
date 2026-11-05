import AppKit
import SwiftUI

/// `Screenie --snapshot <style> <seconds> <out.png> [width height]` renders one frame
/// of a style offscreen, after simulating `seconds` of animation. Used by CI to
/// produce screenshots; no windows are shown.
enum Snapshot {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 3, let seconds = Double(args[1]) else {
            FileHandle.standardError.write("usage: Screenie --snapshot <style> <seconds> <out.png> [width height]\n".data(using: .utf8)!)
            return 2
        }
        var config = Config.load()
        config.style = args[0]
        config.showClock = true
        let width = args.count >= 5 ? Double(args[3]) ?? 1728 : 1728
        let height = args.count >= 5 ? Double(args[4]) ?? 1117 : 1117
        let scale: CGFloat = 2
        let model = SceneModel(config: config)
        let start = Date()
        let steps = max(1, Int(seconds / 0.1))

        let view = Canvas { ctx, size in
            for k in 0...steps {
                let now = start.addingTimeInterval(Double(k) * seconds / Double(steps))
                model.render(&ctx, size: size, now: now, scale: scale)
            }
        }
        .frame(width: width, height: height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write("snapshot: rendering failed\n".data(using: .utf8)!)
            return 1
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: args[2]))
        } catch {
            FileHandle.standardError.write("snapshot: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
        print("wrote \(args[2]) (\(image.width)x\(image.height))")
        return 0
    }
}
