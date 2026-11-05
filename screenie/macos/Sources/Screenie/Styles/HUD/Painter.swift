import AppKit
import CoreText
import ImageIO

/// Core Graphics + Core Text drawing in top-left, y-down coordinates: the small slice of
/// Pango and GtkSnapshot the HUD needs (text with ellipsizing and alignment, wrapped
/// paragraphs, rects, paths, images, clips).
final class Painter {
    enum Align { case left, center, right }

    let cg: CGContext

    /// `cg` must already use y-down coordinates (a SwiftUI Canvas context does).
    init(_ cg: CGContext) {
        self.cg = cg
    }

    /// Draws into a new bitmap of `size` points at `scale`, origin top-left.
    static func render(size: CGSize, scale: CGFloat, _ body: (Painter) -> Void) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded(.up))), h = max(1, Int((size.height * scale).rounded(.up)))
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: scale, y: -scale)
        body(Painter(cg))
        return cg.makeImage()
    }

    // MARK: Colours and fonts

    static func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor { cgColor(hex: hex, alpha: alpha) }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: max(size, 1), weight: weight) as CTFont
    }

    static func serif(_ size: CGFloat, italic: Bool = false) -> CTFont {
        var desc = NSFont.systemFont(ofSize: max(size, 1)).fontDescriptor.withDesign(.serif)
            ?? NSFont.systemFont(ofSize: max(size, 1)).fontDescriptor
        if italic { desc = desc.withSymbolicTraits(.italic) }
        return (NSFont(descriptor: desc, size: max(size, 1)) ?? NSFont.systemFont(ofSize: max(size, 1))) as CTFont
    }

    // MARK: Text

    private static func line(_ s: String, _ font: CTFont, _ color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    static func lineHeight(_ font: CTFont) -> CGFloat {
        CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    static func measure(_ s: String, _ font: CTFont) -> CGSize {
        let w = CTLineGetTypographicBounds(line(s, font, CGColor(gray: 1, alpha: 1)), nil, nil, nil)
        return CGSize(width: CGFloat(w), height: lineHeight(font))
    }

    /// Draws one line with its top-left at (x, y). With `width`, it's ellipsized to fit
    /// and aligned within that width. Returns the drawn size.
    @discardableResult
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ color: CGColor, _ font: CTFont,
              alpha: CGFloat = 1, width: CGFloat? = nil, align: Align = .left) -> CGSize {
        guard !s.isEmpty else { return .zero }
        let c = alpha < 1 ? (color.copy(alpha: color.alpha * alpha) ?? color) : color
        var ln = Self.line(s, font, c)
        var w = CGFloat(CTLineGetTypographicBounds(ln, nil, nil, nil))
        var dx: CGFloat = 0
        if let width {
            if w > width {
                let token = Self.line("…", font, c)
                if let t = CTLineCreateTruncatedLine(ln, Double(max(width, 1)), .end, token) {
                    ln = t
                    w = CGFloat(CTLineGetTypographicBounds(ln, nil, nil, nil))
                }
            }
            switch align {
            case .left: dx = 0
            case .center: dx = (width - w) / 2
            case .right: dx = width - w
            }
        }
        draw(ln, x + dx, y + CTFontGetAscent(font))
        return CGSize(width: w, height: Self.lineHeight(font))
    }

    private func draw(_ ln: CTLine, _ x: CGFloat, _ baseline: CGFloat) {
        cg.saveGState()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(ln, cg)
        cg.restoreGState()
    }

    /// Word-wrapped lines for `width` (Pango WORD_CHAR wrapping).
    static func wrap(_ s: String, _ font: CTFont, width: CGFloat) -> [String] {
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let ns = s as NSString
        var lines: [String] = []
        var start = 0
        while start < ns.length {
            let n = CTTypesetterSuggestLineBreak(ts, start, Double(max(width, 1)))
            guard n > 0 else { break }
            lines.append(ns.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespaces))
            start += n
        }
        return lines
    }

    /// Draws a wrapped paragraph; returns its height.
    @discardableResult
    func paragraph(_ lines: [String], _ x: CGFloat, _ y: CGFloat, _ color: CGColor, _ font: CTFont,
                   width: CGFloat, align: Align = .left) -> CGFloat {
        let lh = Self.lineHeight(font)
        for (i, s) in lines.enumerated() {
            text(s, x, y + CGFloat(i) * lh, color, font, width: width, align: align)
        }
        return CGFloat(lines.count) * lh
    }

    // MARK: Shapes

    func fill(_ r: CGRect, _ color: CGColor) {
        cg.setFillColor(color)
        cg.fill(r)
    }

    func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor) {
        fill(CGRect(x: x, y: y, width: w, height: h), color)
    }

    func fillEllipse(_ r: CGRect, _ color: CGColor) {
        cg.setFillColor(color)
        cg.fillEllipse(in: r)
    }

    func fillCircle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: CGColor) {
        fillEllipse(CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), color)
    }

    func fill(_ path: CGPath, _ color: CGColor) {
        cg.addPath(path)
        cg.setFillColor(color)
        cg.fillPath()
    }

    func stroke(_ path: CGPath, _ width: CGFloat, _ color: CGColor, dash: [CGFloat]? = nil) {
        cg.saveGState()
        cg.addPath(path)
        cg.setStrokeColor(color)
        cg.setLineWidth(width)
        cg.setLineJoin(.round)
        if let dash { cg.setLineDash(phase: 0, lengths: dash) }
        cg.strokePath()
        cg.restoreGState()
    }

    func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ width: CGFloat, _ color: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x1, y: y1))
        stroke(p, width, color)
    }

    func strokeCircle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ width: CGFloat, _ color: CGColor) {
        stroke(CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil), width, color)
    }

    // MARK: Images and state

    /// Draws an image right side up in y-down coordinates.
    func image(_ img: CGImage, _ r: CGRect, alpha: CGFloat = 1) {
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.interpolationQuality = .high
        cg.translateBy(x: r.minX, y: r.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        cg.restoreGState()
    }

    /// Runs `body` with clipping (and any other state changes) undone afterwards.
    func with(clip: CGPath? = nil, alpha: CGFloat? = nil, _ body: () -> Void) {
        cg.saveGState()
        if let clip {
            cg.addPath(clip)
            cg.clip()
        }
        if let alpha { cg.setAlpha(alpha) }
        body()
        cg.restoreGState()
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
