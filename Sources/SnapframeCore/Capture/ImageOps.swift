import AppKit
import CoreGraphics

/// Small CoreGraphics helpers shared by the compositing code.
enum ImageOps {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Premultiplied 8-bit RGBA bitmap context. Falls back to sRGB if the colour space can't back a bitmap.
    static func context(width: Int, height: Int, colorSpace: CGColorSpace? = nil) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for space in [colorSpace, sRGB].compactMap({ $0 }) {
            if let ctx = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: space, bitmapInfo: info) {
                ctx.interpolationQuality = .high
                return ctx
            }
        }
        return nil
    }

    /// Rect that fills `container` with an image of `imageSize`, preserving aspect and centring (crops overflow).
    static func aspectFillRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
        let k = max(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * k, h = imageSize.height * k
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// RGBA (non-premultiplied-ish, as stored premultiplied) bytes of one pixel; origin top-left.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (d[0], d[1], d[2], d[3])
    }
}
