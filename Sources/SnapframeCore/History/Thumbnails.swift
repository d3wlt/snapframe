import AppKit
import AVFoundation
import QuickLookThumbnailing

/// Thumbnails and durations for Quick Access cards and the history grid.
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    private static func key(_ item: CapturedItem, _ size: CGSize, _ scale: CGFloat) -> NSString {
        let mtime = ((try? item.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
        return "\(item.id.uuidString)-\(Int(size.width))x\(Int(size.height))@\(Int(scale))-\(Int(mtime))" as NSString
    }

    /// Cached thumbnail if one was generated before, else nil.
    static func cached(_ item: CapturedItem, size: CGSize, scale: CGFloat) -> NSImage? {
        cache.object(forKey: key(item, size, scale))
    }

    /// Generates a thumbnail that fits `size` (points). Works for images, GIFs and videos (first frame).
    static func thumbnail(for item: CapturedItem, size: CGSize, scale: CGFloat) async -> NSImage? {
        let k = key(item, size, scale)
        if let hit = cache.object(forKey: k) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: item.fileURL, size: size, scale: scale,
                                                    representationTypes: .thumbnail)
        request.iconMode = false
        let image: NSImage?
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = NSImage(cgImage: rep.cgImage, size: CGSize(width: CGFloat(rep.cgImage.width) / scale,
                                                              height: CGFloat(rep.cgImage.height) / scale))
        } else if item.kind != .video {
            image = await downsampled(url: item.fileURL, maxPixel: max(size.width, size.height) * scale)
        } else {
            image = await firstFrame(of: item.fileURL, maxSize: CGSize(width: size.width * scale, height: size.height * scale))
        }
        if let image { cache.setObject(image, forKey: k) }
        return image
    }

    /// Decodes at most `maxPixel` on the longer side straight from the file (never the full bitmap).
    /// The returned image is sized in points for the given backing scale.
    static func downsampled(url: URL, maxPixel: CGFloat, scale: CGFloat = 1) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded(.up)),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        }.value
    }

    private static func firstFrame(of url: URL, maxSize: CGSize) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    /// Duration in seconds of a video, nil for images and unreadable files.
    static func duration(of item: CapturedItem) async -> TimeInterval? {
        guard item.kind == .video else { return nil }
        guard let time = try? await AVURLAsset(url: item.fileURL).load(.duration), time.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? seconds : nil
    }

    /// "0:07", "1:05", "1:02:03".
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
