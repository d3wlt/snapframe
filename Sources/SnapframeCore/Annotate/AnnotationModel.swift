import AppKit

/// One drawn object. All geometry is in image points with the origin at the image's top-left (y down).
public struct Annotation: Identifiable, Equatable {
    public enum Kind: String, CaseIterable {
        case arrow, line, rectangle, ellipse, text, pencil, highlighter, counter, pixelate, blur, spotlight

        /// Kinds whose geometry is the rectangle spanned by start/end.
        var isRectLike: Bool { [.rectangle, .ellipse, .pixelate, .blur, .spotlight].contains(self) }
        /// Kinds that sample or dim the base image instead of drawing vector shapes.
        var isEffect: Bool { [.pixelate, .blur, .spotlight].contains(self) }
        var isFreehand: Bool { self == .pencil || self == .highlighter }
    }

    public enum Handle: Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case startPoint, endPoint
    }

    public var id = UUID()
    public var kind: Kind
    /// Arrow/line: tail and head. Rect-like: opposite corners. Text: top-left. Counter: centre.
    public var start: CGPoint
    public var end: CGPoint
    public var points: [CGPoint] = []
    public var color: NSColor = Annotation.defaultColor
    public var lineWidth: CGFloat = 4
    public var filled = false
    public var rounded = false
    public var text = ""
    public var fontSize: CGFloat = 24
    public var textBackground = false
    public var number = 1
    /// Arrow only: head at `start` instead of `end`.
    public var inverse = false
    /// Pencil only: render as a smoothed curve.
    public var smooth = true
    /// Pixelate block size / blur radius in points.
    public var strength: CGFloat = 12

    public static let defaultColor = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)

    public init(kind: Kind, start: CGPoint, end: CGPoint) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    // MARK: Convenience constructors

    public static func arrow(from: CGPoint, to: CGPoint, inverse: Bool = false, color: NSColor = defaultColor,
                             lineWidth: CGFloat = 4) -> Annotation {
        var a = Annotation(kind: .arrow, start: from, end: to)
        a.inverse = inverse; a.color = color; a.lineWidth = lineWidth
        return a
    }

    public static func rectangle(_ rect: CGRect, color: NSColor = defaultColor, lineWidth: CGFloat = 4,
                                 filled: Bool = false, rounded: Bool = false) -> Annotation {
        var a = Annotation(kind: .rectangle, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY))
        a.color = color; a.lineWidth = lineWidth; a.filled = filled; a.rounded = rounded
        return a
    }

    public static func counter(at p: CGPoint, number: Int, color: NSColor = defaultColor, lineWidth: CGFloat = 4) -> Annotation {
        var a = Annotation(kind: .counter, start: p, end: p)
        a.number = number; a.color = color; a.lineWidth = lineWidth
        return a
    }

    public static func region(_ kind: Kind, _ rect: CGRect, strength: CGFloat = 12) -> Annotation {
        var a = Annotation(kind: kind, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY))
        a.strength = strength
        return a
    }

    public static func text(_ string: String, at p: CGPoint, fontSize: CGFloat = 24, color: NSColor = defaultColor,
                            background: Bool = false) -> Annotation {
        var a = Annotation(kind: .text, start: p, end: p)
        a.text = string; a.fontSize = fontSize; a.color = color; a.textBackground = background
        return a
    }

    // MARK: Geometry

    /// Normalised rectangle spanned by start/end.
    public var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var counterDiameter: CGFloat { 14 + lineWidth * 3 }

    var textFont: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }

    var textPadding: CGSize { textBackground ? CGSize(width: fontSize * 0.5, height: fontSize * 0.25) : CGSize(width: 2, height: 1) }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: textFont, .foregroundColor: textBackground ? Annotation.contrastColor(for: color) : color]
    }

    static func contrastColor(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma > 0.62 ? NSColor(white: 0.08, alpha: 1) : .white
    }

    /// Text box including padding.
    public var textBox: CGRect {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes)
            .boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin])
        let pad = textPadding
        return CGRect(x: start.x, y: start.y, width: ceil(max(measured.width, fontSize * 0.4)) + pad.width * 2,
                      height: ceil(measured.height) + pad.height * 2)
    }

    /// Geometric bounds of the object, without stroke thickness.
    public var bounds: CGRect {
        switch kind {
        case .arrow, .line, .rectangle, .ellipse, .pixelate, .blur, .spotlight:
            return rect
        case .text:
            return textBox
        case .counter:
            let d = counterDiameter
            return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        case .pencil, .highlighter:
            guard let first = points.first else { return CGRect(origin: start, size: .zero) }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    var strokeWidth: CGFloat { kind == .highlighter ? lineWidth * 4 : lineWidth }

    /// Bounds including stroke thickness (and the arrow head), used for canvas auto-expansion and repaint.
    public var renderBounds: CGRect {
        switch kind {
        case .text, .counter, .pixelate, .blur, .spotlight: return bounds.insetBy(dx: -1, dy: -1)
        case .arrow: return bounds.insetBy(dx: -(lineWidth * 3 + 6), dy: -(lineWidth * 3 + 6))
        default:
            let inset = (filled && (kind == .rectangle || kind == .ellipse)) ? 1 : strokeWidth / 2 + 1
            return bounds.insetBy(dx: -inset, dy: -inset)
        }
    }

    public func moved(by d: CGSize) -> Annotation {
        var a = self
        a.start.x += d.width; a.start.y += d.height
        a.end.x += d.width; a.end.y += d.height
        a.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return a
    }

    // MARK: Handles

    public var handles: [(Handle, CGPoint)] {
        switch kind {
        case .arrow, .line:
            return [(.startPoint, start), (.endPoint, end)]
        case .counter:
            return []
        case .text:
            let b = bounds
            return [(.bottomRight, CGPoint(x: b.maxX, y: b.maxY))]
        default:
            let r = bounds
            guard kind.isRectLike || kind.isFreehand, r.width > 0 || r.height > 0 else { return [] }
            return [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
                    (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
                    (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                    (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
        }
    }

    static func rect(_ r: CGRect, dragging h: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch h {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        case .startPoint, .endPoint: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    public func resized(_ handle: Handle, to p: CGPoint) -> Annotation {
        var a = self
        switch kind {
        case .arrow, .line:
            if handle == .startPoint { a.start = p } else if handle == .endPoint { a.end = p }
        case .text:
            let b = bounds
            guard b.height > 0 else { return self }
            let newHeight = max(8, p.y - b.minY)
            a.fontSize = min(200, max(8, (fontSize * newHeight / b.height).rounded()))
        case .counter:
            break
        default:
            let old = bounds
            let new = Annotation.rect(old, dragging: handle, to: p)
            if kind.isRectLike {
                a.start = new.origin
                a.end = CGPoint(x: new.maxX, y: new.maxY)
            } else if old.width > 0 || old.height > 0 {
                let sx = old.width > 0 ? new.width / old.width : 1
                let sy = old.height > 0 ? new.height / old.height : 1
                a.points = points.map {
                    CGPoint(x: new.minX + ($0.x - old.minX) * sx, y: new.minY + ($0.y - old.minY) * sy)
                }
            }
        }
        return a
    }

    // MARK: Hit testing

    public func hitTest(_ p: CGPoint, tolerance t: CGFloat = 5) -> Bool {
        switch kind {
        case .arrow, .line:
            return Annotation.distance(from: p, toSegment: start, end) <= max(strokeWidth, 6) / 2 + t
        case .rectangle:
            let r = rect
            if filled { return r.insetBy(dx: -t, dy: -t).contains(p) }
            let outer = r.insetBy(dx: -(strokeWidth / 2 + t), dy: -(strokeWidth / 2 + t))
            let inner = r.insetBy(dx: strokeWidth / 2 + t, dy: strokeWidth / 2 + t)
            return outer.contains(p) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(p))
        case .ellipse:
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = (nx * nx + ny * ny).squareRoot()
            if filled { return d <= 1 + t / max(1, min(r.width, r.height) / 2) }
            let band = (strokeWidth / 2 + t) / max(1, min(r.width, r.height) / 2)
            return abs(d - 1) <= band
        case .text, .counter, .pixelate, .blur, .spotlight:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        case .pencil, .highlighter:
            guard points.count > 1 else { return points.first.map { hypot($0.x - p.x, $0.y - p.y) <= strokeWidth / 2 + t } ?? false }
            for i in 1..<points.count where Annotation.distance(from: p, toSegment: points[i - 1], points[i]) <= strokeWidth / 2 + t {
                return true
            }
            return false
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Everything needed to produce the final image: base pixels + objects + crop + background.
public struct AnnotationDocument {
    public var baseImage: CGImage
    /// Backing scale of the base image (pixels per point).
    public var scale: CGFloat
    public var annotations: [Annotation] = []
    /// Output crop in image points (same space as annotations). nil = whole canvas.
    public var cropRect: CGRect?
    public var background: BackgroundStyle?
    /// Grow the canvas (transparent padding) when objects extend past the image.
    public var autoExpandCanvas: Bool
    public var objectShadow: Bool

    public init(baseImage: CGImage, scale: CGFloat, autoExpandCanvas: Bool = false, objectShadow: Bool = false) {
        self.baseImage = baseImage
        self.scale = max(scale, 1)
        self.autoExpandCanvas = autoExpandCanvas
        self.objectShadow = objectShadow
    }

    public var imageSize: CGSize { CGSize(width: CGFloat(baseImage.width) / scale, height: CGFloat(baseImage.height) / scale) }
    public var imageRect: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// The image, grown to contain every vector object when auto-expand is on.
    public var canvasRect: CGRect {
        var r = imageRect
        if autoExpandCanvas {
            for a in annotations where !a.kind.isEffect { r = r.union(a.renderBounds) }
            // Snap outwards to whole pixels so the expanded canvas stays on the pixel grid.
            let minX = floor(r.minX * scale) / scale, minY = floor(r.minY * scale) / scale
            let maxX = ceil(r.maxX * scale) / scale, maxY = ceil(r.maxY * scale) / scale
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return r
    }

    /// Region written to the output (crop clipped to the canvas).
    public var outputRect: CGRect {
        let canvas = canvasRect
        guard let crop = cropRect else { return canvas }
        let c = crop.intersection(canvas)
        return c.isNull || c.width < 1 || c.height < 1 ? canvas : c
    }

    public var nextCounterNumber: Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    public func renderFlattened() -> CGImage {
        let out = outputRect
        let pxRect = CGRect(x: (out.minX * scale).rounded(), y: (out.minY * scale).rounded(),
                            width: max(1, (out.width * scale).rounded()), height: max(1, (out.height * scale).rounded()))
        let W = Int(pxRect.width), H = Int(pxRect.height)
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let s = baseImage.colorSpace, s.model == .rgb { space = s }
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ?? CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -pxRect.minX / scale, y: -pxRect.minY / scale)
        AnnotationRenderer.draw(self, in: ctx, cache: nil)
        return ctx.makeImage()!
    }

    /// Final image at full pixel resolution, including the background style if any.
    public func render() -> CGImage {
        let flat = renderFlattened()
        guard let background else { return flat }
        return BackgroundRenderer.apply(background, to: flat, scale: scale)
    }
}
