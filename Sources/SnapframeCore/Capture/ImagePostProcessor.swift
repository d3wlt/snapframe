import AppKit

/// Applies Screenshots settings: scale to 1x, sRGB conversion, 1px border, background preset.
public enum ImagePostProcessor {
    public static func process(_ image: CGImage, scale: CGFloat) -> (image: CGImage, scale: CGFloat) {
        process(image, scale: scale,
                scaleTo1x: Prefs.bool(PrefKey.shotScaleTo1x),
                convertSRGB: Prefs.bool(PrefKey.shotConvertSRGB),
                border: Prefs.bool(PrefKey.shotBorder),
                presetID: Prefs.string(PrefKey.shotBackgroundPreset))
    }

    /// Explicit-parameter variant (what the tests drive).
    static func process(_ image: CGImage, scale: CGFloat, scaleTo1x: Bool, convertSRGB: Bool, border: Bool,
                        presetID: String) -> (image: CGImage, scale: CGFloat) {
        var img = image
        var outScale = scale

        if scaleTo1x, scale > 1 {
            let w = max(1, Int((CGFloat(img.width) / scale).rounded()))
            let h = max(1, Int((CGFloat(img.height) / scale).rounded()))
            if let scaled = redraw(img, width: w, height: h, space: convertSRGB ? ImageOps.sRGB : img.colorSpace) {
                img = scaled
                outScale = 1
            }
        }
        if convertSRGB, img.colorSpace?.name != CGColorSpace.sRGB,
           let converted = redraw(img, width: img.width, height: img.height, space: ImageOps.sRGB) {
            img = converted
        }
        if border, let bordered = addBorder(img) { img = bordered }
        if !presetID.isEmpty, let preset = BackgroundStyle.preset(withID: presetID) {
            img = BackgroundRenderer.apply(preset, to: img, scale: outScale)
        }
        return (img, outScale)
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int, space: CGColorSpace?) -> CGImage? {
        guard let ctx = ImageOps.context(width: width, height: height, colorSpace: space) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Surrounds the image with a 1 px subtle dark-gray frame (grows each side by 1 px).
    static func addBorder(_ image: CGImage) -> CGImage? {
        let w = image.width + 2, h = image.height + 2
        guard let ctx = ImageOps.context(width: w, height: h, colorSpace: image.colorSpace) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let inner = CGRect(x: 1, y: 1, width: image.width, height: image.height)
        ctx.clear(inner) // keep transparent screenshots transparent inside the frame
        ctx.draw(image, in: inner)
        return ctx.makeImage()
    }
}
