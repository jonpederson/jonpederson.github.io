import AVFoundation
import CoreVideo
import SwiftUI
import VideoToolbox
import WebKit

/// One traffic camera's HLS stream (H.264 in MPEG-TS, which AVPlayer plays natively),
/// pulled frame by frame so it can be drawn inside the HUD canvas.
final class CameraStream {
    let url: URL
    let started: Double
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var frame: CGImage?

    init?(urlString: String, now: Double) {
        guard let url = URL(string: urlString) else { return nil }
        self.url = url
        started = now
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        let item = AVPlayerItem(url: url)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
    }

    var failed: Bool { player.currentItem?.status == .failed || player.currentItem?.error != nil }

    /// The newest decoded frame, if the stream has produced any.
    func currentFrame() -> CGImage? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            if let image { frame = image }
        }
        return frame
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Where the HUD wants NASA's live ISS stream; the scene shows a web view there.
final class HudOverlayModel: ObservableObject {
    @Published var streamID: String?
    @Published var rect: CGRect = .zero

    /// Called while drawing, so the change is published on the next run loop pass
    /// (SwiftUI doesn't allow publishing during a view update).
    func update(streamID: String?, rect: CGRect) {
        guard streamID != self.streamID || rect != self.rect else { return }
        DispatchQueue.main.async {
            if self.streamID != streamID { self.streamID = streamID }
            if self.rect != rect { self.rect = rect }
        }
    }
}

struct HudOverlayView: View {
    @ObservedObject var model: HudOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let id = model.streamID, model.rect.width > 10 {
                YouTubeView(videoID: id)
                    .frame(width: model.rect.width, height: model.rect.height)
                    .offset(x: model.rect.minX, y: model.rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// NASA's live ISS stream through YouTube's embedded player, muted and autoplaying.
/// It never takes mouse or keyboard input, so any input still dismisses the saver.
struct YouTubeView: NSViewRepresentable {
    let videoID: String

    final class PassthroughWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }

    final class Coordinator {
        var loadedID: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = PassthroughWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        load(view, context: context)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        load(view, context: context)
    }

    private func load(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedID != videoID else { return }
        context.coordinator.loadedID = videoID
        let src = "https://www.youtube.com/embed/\(videoID)?autoplay=1&mute=1&controls=0&playsinline=1&rel=0&modestbranding=1"
        let html = """
        <html><body style="margin:0;background:#000;overflow:hidden">
        <iframe src="\(src)" style="position:absolute;inset:0;width:100%;height:100%;border:0"
        allow="autoplay; encrypted-media" referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
    }
}
