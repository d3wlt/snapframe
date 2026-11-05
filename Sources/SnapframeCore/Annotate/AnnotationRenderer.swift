import AppKit
import CoreImage

/// Keeps the latest full-quality pixelate/blur image per annotation (and the pixel rect + settings it
/// was made for), so memory stays bounded by the number of redactions, not by drag frames.
final class EffectCache {
    private var entries: [UUID: (key: String, image: CGImage)] = [:]

    func image(for id: UUID, key: String, make: () -> CGImage?) -> CGImage? {
        if let e = entries[id], e.key == key { return e.image }
        guard let made = make() else { entries[id] = nil; return nil }
        entries[id] = (key, made)
        return made
    }

    func prune(keeping ids: Set<UUID>) {
        for id in entries.keys where !ids.contains(id) { entries[id] = nil }
    }
}

/// Draws a document into a CGContext whose user space is image points with y pointing down
/// (origin = image top-left). Used for both the on-screen canvas and the full-resolution export.
enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// - previewing: redaction ids being dragged/resized; they get a cheap reduced-resolution effect.
    /// - hiding: annotation ids to skip (e.g. the text being edited inline).
    static func draw(_ doc: AnnotationDocument, in ctx: CGContext, cache: EffectCache?,
                     hiding: Set<UUID> = [], previewing: Set<UUID> = []) {
        let image = doc.baseImage
        let rect = doc.imageRect
        ctx.saveGState()
        ctx.interpolationQuality = .high
        drawImage(image, in: rect, ctx)
        ctx.restoreGState()

        for a in doc.annotations where (a.kind == .pixelate || a.kind == .blur) && !hiding.contains(a.id) {
            drawRedaction(a, doc: doc, ctx: ctx, cache: cache, preview: previewing.contains(a.id))
        }
        cache?.prune(keeping: Set(doc.annotations.filter { $0.kind == .pixelate || $0.kind == .blur }.map(\.id)))

        let spots = doc.annotations.filter { $0.kind == .spotlight && !hiding.contains($0.id) }
        if !spots.isEmpty {
            // Dim only the image area; spotlight rects are punched out of the layer, so overlaps stay bright.
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fill(rect)
            ctx.setBlendMode(.clear)
            for s in spots { ctx.fill(s.rect) }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        for a in doc.annotations where !a.kind.isEffect && !hiding.contains(a.id) {
            let shadow = doc.objectShadow && a.kind != .highlighter
            ctx.saveGState()
            if shadow {
                let k = abs(ctx.ctm.a)
                ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * k), blur: 4 * k, color: CGColor(gray: 0, alpha: 0.35))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            drawObject(a, ctx)
            if shadow { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
    }

    /// Draws a CGImage upright into a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: Redaction

    private static func drawRedaction(_ a: Annotation, doc: AnnotationDocument, ctx: CGContext, cache: EffectCache?,
                                      preview: Bool) {
        let s = doc.scale
        let r = a.rect.intersection(doc.imageRect)
        guard !r.isNull, r.width > 0, r.height > 0 else { return }
        let x0 = max(0, Int(floor(r.minX * s))), y0 = max(0, Int(floor(r.minY * s)))
        let x1 = min(doc.baseImage.width, Int(ceil(r.maxX * s))), y1 = min(doc.baseImage.height, Int(ceil(r.maxY * s)))
        guard x1 > x0, y1 > y0 else { return }
        let pxRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard let crop = doc.baseImage.cropping(to: pxRect) else { return }
        let dest = CGRect(x: pxRect.minX / s, y: pxRect.minY / s, width: pxRect.width / s, height: pxRect.height / s)

        func effect(_ image: CGImage, scale k: CGFloat) -> CGImage? {
            a.kind == .pixelate ? pixelate(image, block: a.strength * k) : blur(image, radius: a.strength * k * 0.6)
        }

        if preview {
            // Reduced resolution (long side <= 192 px), recomputed each frame and never cached.
            let f = min(1, 192 / CGFloat(max(crop.width, crop.height)))
            let w = max(1, Int(CGFloat(crop.width) * f)), h = max(1, Int(CGFloat(crop.height) * f))
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            small.interpolationQuality = .medium
            small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let reduced = small.makeImage(), let out = effect(reduced, scale: s * f) else { return }
            ctx.saveGState()
            ctx.interpolationQuality = a.kind == .pixelate ? .none : .medium
            drawImage(out, in: dest, ctx)
            ctx.restoreGState()
            return
        }

        let key = "\(a.kind.rawValue)|\(pxRect)|\(a.strength)|\(doc.baseImage.hashValue)"
        let make: () -> CGImage? = { effect(crop, scale: s) }
        guard let out = cache.map({ $0.image(for: a.id, key: key, make: make) }) ?? make() else { return }
        drawImage(out, in: dest, ctx)
    }

    static func pixelate(_ image: CGImage, block: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        let b = max(2, Int(block.rounded()))
        let sw = max(1, Int(ceil(Double(w) / Double(b)))), sh = max(1, Int(ceil(Double(h) / Double(b))))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tiny = small.makeImage(),
              let big = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: small.colorSpace ?? space, bitmapInfo: info) else { return nil }
        big.interpolationQuality = .none
        big.draw(tiny, in: CGRect(x: 0, y: CGFloat(h) - CGFloat(sh * b), width: CGFloat(sw * b), height: CGFloat(sh * b)))
        return big.makeImage()
    }

    static func blur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(1, radius), forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(out, from: input.extent)
    }

    // MARK: Vector objects

    static func drawObject(_ a: Annotation, _ ctx: CGContext) {
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        switch a.kind {
        case .arrow:
            let (tail, tip) = a.inverse ? (a.end, a.start) : (a.start, a.end)
            guard let path = arrowPath(tail: tail, tip: tip, width: a.lineWidth) else { return }
            ctx.addPath(path)
            ctx.setLineWidth(1)
            ctx.setLineJoin(.round)
            ctx.drawPath(using: .fillStroke)
        case .line:
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rectangle:
            let r = a.rect
            guard r.width > 0, r.height > 0 else { return }
            let radius = a.rounded ? min(10 + a.lineWidth, min(r.width, r.height) / 2) : 0
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineJoin(a.rounded ? .round : .miter)
            ctx.drawPath(using: a.filled ? .fill : .stroke)
        case .ellipse:
            let r = a.rect
            guard r.width > 0, r.height > 0 else { return }
            ctx.setLineWidth(a.lineWidth)
            if a.filled { ctx.fillEllipse(in: r) } else { ctx.strokeEllipse(in: r) }
        case .pencil:
            guard !a.points.isEmpty else { return }
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(freehandPath(a.points, smooth: a.smooth))
            ctx.strokePath()
        case .highlighter:
            guard !a.points.isEmpty else { return }
            ctx.setStrokeColor(a.color.withAlphaComponent(0.42).cgColor)
            ctx.setLineWidth(a.strokeWidth)
            ctx.setLineCap(.square)
            ctx.setLineJoin(.round)
            ctx.addPath(freehandPath(a.points, smooth: a.smooth))
            ctx.strokePath()
        case .counter:
            let b = a.bounds
            ctx.fillEllipse(in: b)
            ctx.setStrokeColor(Annotation.contrastColor(for: a.color).cgColor)
            ctx.setLineWidth(max(1.5, a.lineWidth * 0.4))
            ctx.strokeEllipse(in: b.insetBy(dx: a.lineWidth * 0.35 + 0.75, dy: a.lineWidth * 0.35 + 0.75))
            let font = NSFont.systemFont(ofSize: b.height * 0.5, weight: .bold)
            let str = NSAttributedString(string: String(a.number), attributes: [
                .font: font, .foregroundColor: Annotation.contrastColor(for: a.color)])
            let size = str.size()
            withText(ctx) { str.draw(at: CGPoint(x: b.midX - size.width / 2, y: b.midY - size.height / 2)) }
        case .text:
            guard !a.text.isEmpty else { return }
            let box = a.textBox
            if a.textBackground {
                let radius = min(box.height / 2, a.fontSize * 0.6)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
            let str = NSAttributedString(string: a.text, attributes: a.textAttributes)
            let pad = a.textPadding
            withText(ctx) {
                str.draw(with: CGRect(x: box.minX + pad.width, y: box.minY + pad.height,
                                      width: box.width, height: box.height),
                         options: [.usesLineFragmentOrigin])
            }
        case .pixelate, .blur, .spotlight:
            break
        }
    }

    private static func withText(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Tapered arrow: a thin tail widening towards a triangular head at `tip`.
    static func arrowPath(tail: CGPoint, tip: CGPoint, width w: CGFloat) -> CGPath? {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let len = hypot(dx, dy)
        guard len > 1 else { return nil }
        let d = CGPoint(x: dx / len, y: dy / len)
        let n = CGPoint(x: -d.y, y: d.x)
        let headLen = min(len * 0.6, 10 + w * 3.2)
        let headHalf = headLen * 0.55
        let baseHalf = min(w * 0.5, headHalf * 0.5)
        let tailHalf = max(0.5, w * 0.12)
        let base = CGPoint(x: tip.x - d.x * headLen, y: tip.y - d.y * headLen)
        func pt(_ c: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: c.x + n.x * k, y: c.y + n.y * k) }
        let path = CGMutablePath()
        path.move(to: pt(tail, tailHalf))
        path.addLine(to: pt(base, baseHalf))
        path.addLine(to: pt(base, headHalf))
        path.addLine(to: tip)
        path.addLine(to: pt(base, -headHalf))
        path.addLine(to: pt(base, -baseHalf))
        path.addLine(to: pt(tail, -tailHalf))
        path.closeSubpath()
        return path
    }

    /// Polyline, or a Catmull-Rom spline through the points when `smooth`.
    static func freehandPath(_ pts: [CGPoint], smooth: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)); return path }
        if !smooth || pts.count < 3 {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }
}
