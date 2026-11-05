import CoreGraphics

/// Pure geometry for the Quick Access stack, kept free of AppKit state so it can be tested.
public enum QuickAccessLayout {
    public static let margin: CGFloat = 16
    public static let spacing: CGFloat = 10
    public static let tickRange = 0...4
    /// Card height relative to width: very wide / very tall captures are letterboxed inside the card.
    public static let heightRatioRange: ClosedRange<CGFloat> = 0.6...1.3

    /// Card width for a size tick (0...4, 2 = default): 160, 200, 240, 280, 320 pt.
    public static func cardWidth(tick: Int) -> CGFloat {
        let t = min(max(tick, tickRange.lowerBound), tickRange.upperBound)
        return 160 + 40 * CGFloat(t)
    }

    /// Fixed width from the tick, height from the image aspect ratio (width / height), clamped.
    public static func cardSize(tick: Int, aspect: CGFloat) -> CGSize {
        let width = cardWidth(tick: tick)
        let a = (aspect.isFinite && aspect > 0) ? aspect : 1.6
        let ratio = min(max(1 / a, heightRatioRange.lowerBound), heightRatioRange.upperBound)
        return CGSize(width: width, height: (width * ratio).rounded())
    }

    /// Frames for a stack of cards, `sizes[0]` being the newest, which sits at the bottom corner.
    /// Older cards are pushed up. `visibleFrame` is the screen's usable area (menu bar and Dock excluded).
    public static func frames(sizes: [CGSize], in visibleFrame: CGRect, position: QuickAccessPosition) -> [CGRect] {
        var y = visibleFrame.minY + margin
        return sizes.map { size in
            let x = position == .left ? visibleFrame.minX + margin : visibleFrame.maxX - margin - size.width
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            y += size.height + spacing
            return frame
        }
    }

    /// Whether a frame from `frames(...)` still fits below the top margin of the visible area.
    public static func fits(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        frame.maxY <= visibleFrame.maxY - margin + 0.5
    }

    /// Start / end frame of the slide animation: nudged toward its screen edge by at most `margin`, so the
    /// card stays inside the visible frame and never shows up on a neighbouring display, while fading.
    public static func slideFrame(for frame: CGRect, position: QuickAccessPosition) -> CGRect {
        frame.offsetBy(dx: position == .left ? -margin : margin, dy: 0)
    }
}
