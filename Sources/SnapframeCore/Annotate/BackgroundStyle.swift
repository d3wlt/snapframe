import AppKit

/// Background tool settings ("beautify"): padding + backdrop + rounded corners + shadow.
/// Saved as presets (Prefs annBackgroundPresets, JSON) and optionally auto-applied to every
/// screenshot (Prefs shotBackgroundPreset = preset id).
public struct BackgroundStyle: Codable, Equatable, Identifiable {
    public enum Fill: Codable, Equatable {
        case none
        case color(hex: String)
        case gradient(fromHex: String, toHex: String, angle: Double)
        case image(path: String)
    }

    public var id: String
    public var name: String
    public var fill: Fill
    /// Padding as a fraction of the shorter image side (0...0.3).
    public var padding: Double
    /// Corner radius of the screenshot in points (multiplied by the `scale` passed to the renderer).
    public var cornerRadius: Double
    public var shadow: Bool
    /// Optional fixed aspect ratio (w/h), nil = follow image.
    public var aspectRatio: Double?

    public init(id: String = UUID().uuidString, name: String, fill: Fill, padding: Double, cornerRadius: Double,
                shadow: Bool, aspectRatio: Double? = nil) {
        self.id = id
        self.name = name
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspectRatio = aspectRatio
    }

    public static func loadPresets() -> [BackgroundStyle] {
        let json = Prefs.string(PrefKey.annBackgroundPresets)
        return (try? JSONDecoder().decode([BackgroundStyle].self, from: Data(json.utf8))) ?? []
    }

    public static func savePresets(_ presets: [BackgroundStyle]) {
        if let data = try? JSONEncoder().encode(presets) {
            Prefs.set(String(decoding: data, as: UTF8.self), PrefKey.annBackgroundPresets)
        }
    }

    // MARK: Built-in presets

    private static func gradient(_ id: String, _ name: String, _ from: String, _ to: String, angle: Double = 135) -> BackgroundStyle {
        BackgroundStyle(id: "builtin.\(id)", name: name, fill: .gradient(fromHex: from, toHex: to, angle: angle),
                        padding: 0.1, cornerRadius: 12, shadow: true)
    }

    public static let builtIns: [BackgroundStyle] = [
        gradient("sunset", "Sunset", "#FF9A8B", "#FF6A88"),
        gradient("ocean", "Ocean", "#2193B0", "#6DD5ED"),
        gradient("lavender", "Lavender", "#A18CD1", "#FBC2EB"),
        gradient("mint", "Mint", "#84FAB0", "#8FD3F4"),
        gradient("peach", "Peach", "#FFE29F", "#FF719A"),
        gradient("midnight", "Midnight", "#232526", "#505560"),
    ]

    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    /// Looks a preset up by id among the built-ins and the user's saved presets.
    public static func preset(withID id: String) -> BackgroundStyle? {
        guard !id.isEmpty else { return nil }
        return (builtIns + loadPresets()).first { $0.id == id }
    }
}

public enum BackgroundRenderer {
    /// Renders the image onto the styled background. Output pixel size = image + 2 x padding,
    /// stretched to the style's aspect ratio when set. `scale` is the image's backing scale: it
    /// converts the style's point-based corner radius into pixels.
    public static func apply(_ style: BackgroundStyle, to image: CGImage, scale: CGFloat = 1) -> CGImage {
        let w = image.width, h = image.height
        let shorter = CGFloat(min(w, h))
        let pad = (shorter * CGFloat(min(max(style.padding, 0), 0.3))).rounded()
        var outW = CGFloat(w) + 2 * pad
        var outH = CGFloat(h) + 2 * pad
        if let ratio = style.aspectRatio, ratio > 0 {
            if outW / outH < CGFloat(ratio) { outW = (outH * CGFloat(ratio)).rounded(.up) }
            else { outH = (outW / CGFloat(ratio)).rounded(.up) }
        }
        let W = Int(outW), H = Int(outH)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1) // y-down pixel space

        drawBackdrop(style.fill, in: ctx, size: CGSize(width: W, height: H), space: space)

        let rect = CGRect(x: ((CGFloat(W) - CGFloat(w)) / 2).rounded(), y: ((CGFloat(H) - CGFloat(h)) / 2).rounded(),
                          width: CGFloat(w), height: CGFloat(h))
        let radius = min(max(0, CGFloat(style.cornerRadius) * max(scale, 1)), shorter / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        if style.shadow {
            let blur = max(12, shorter * 0.05)
            // Shadow offsets live in base (y-up) space, so a negative height moves it down on screen.
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.4), blur: blur,
                          color: CGColor(gray: 0, alpha: 0.4))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        return ctx.makeImage() ?? image
    }

    private static func drawBackdrop(_ fill: BackgroundStyle.Fill, in ctx: CGContext, size: CGSize, space: CGColorSpace) {
        let full = CGRect(origin: .zero, size: size)
        switch fill {
        case .none:
            break
        case .color(let hex):
            ctx.setFillColor((NSColor(hex: hex) ?? .gray).cgColor)
            ctx.fill(full)
        case .gradient(let fromHex, let toHex, let angle):
            let c1 = (NSColor(hex: fromHex) ?? .gray).cgColor
            let c2 = (NSColor(hex: toHex) ?? .darkGray).cgColor
            guard let gradient = CGGradient(colorsSpace: space, colors: [c1, c2] as CFArray, locations: [0, 1]) else { return }
            let a = angle * .pi / 180
            let d = CGPoint(x: cos(a), y: sin(a))
            let half = (abs(size.width * d.x) + abs(size.height * d.y)) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - d.x * half, y: c.y - d.y * half),
                                   end: CGPoint(x: c.x + d.x * half, y: c.y + d.y * half),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image(let path):
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                ctx.setFillColor(NSColor.gray.cgColor)
                ctx.fill(full)
                return
            }
            let k = max(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
            let iw = CGFloat(img.width) * k, ih = CGFloat(img.height) * k
            ctx.saveGState()
            ctx.translateBy(x: (size.width - iw) / 2, y: (size.height - ih) / 2 + ih)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
            ctx.restoreGState()
        }
    }
}
