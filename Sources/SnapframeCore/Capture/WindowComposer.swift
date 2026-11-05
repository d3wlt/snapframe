import AppKit

/// Places a captured window on a background with padding and a drop shadow. Pure: no screen access.
public enum WindowComposer {
    public enum Background {
        case transparent
        case color(CGColor)
        /// Aspect-filled into the output (e.g. the desktop wallpaper).
        case image(CGImage)
    }

    /// Padding in pixels for a 0...6 tick setting. Scales with the window's shorter side (5% per tick,
    /// clamped to 8...60 px per tick); 0 ticks = no padding.
    public static func paddingPixels(ticks: Int, windowSize: CGSize) -> Int {
        let t = max(0, min(6, ticks))
        guard t > 0 else { return 0 }
        let perTick = min(max(min(windowSize.width, windowSize.height) * 0.05, 8), 60)
        return Int((perTick * CGFloat(t)).rounded())
    }

    /// Room reserved for the shadow when there is no other padding: 8% of the shorter side, 16...60 px.
    static func shadowMargin(for window: CGImage) -> Int {
        Int(min(max(CGFloat(min(window.width, window.height)) * 0.08, 16), 60).rounded())
    }

    /// Output size is the window size plus `padding` on every side. The shadow follows the window's alpha
    /// and needs padding to be visible; with 0 padding it is only drawn on a transparent background
    /// (a margin is added), otherwise it would be clipped away.
    public static func compose(window: CGImage, background: Background, padding: Int, shadow: Bool) -> CGImage? {
        var pad = max(0, padding)
        // On a transparent background the shadow is the only thing around the window, so give it room even
        // at padding 0 (the system shadow is not captured).
        if shadow, case .transparent = background { pad = max(pad, shadowMargin(for: window)) }
        let w = window.width + 2 * pad, h = window.height + 2 * pad
        guard let ctx = ImageOps.context(width: w, height: h) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        switch background {
        case .transparent: break
        case .color(let c):
            ctx.setFillColor(c)
            ctx.fill(full)
        case .image(let img):
            ctx.draw(img, in: ImageOps.aspectFillRect(imageSize: CGSize(width: img.width, height: img.height),
                                                      in: full.size))
        }
        let windowRect = CGRect(x: pad, y: pad, width: window.width, height: window.height)
        if shadow && pad > 0 {
            let blur = min(CGFloat(pad) * 0.5, 60)
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.3), blur: blur,
                          color: CGColor(gray: 0, alpha: 0.45))
        }
        ctx.draw(window, in: windowRect)
        return ctx.makeImage()
    }
}
