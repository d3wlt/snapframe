import AppKit
import UniformTypeIdentifiers

public enum MediaKind: String, Codable, Sendable { case image, video, gif }

/// One capture. `fileURL` always points at Snapframe's own copy inside the history directory;
/// saving to the export location makes a separate copy (`savedURL`).
public struct CapturedItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: MediaKind
    public var fileURL: URL
    public var savedURL: URL?
    public var createdAt: Date
    /// Size in pixels of the stored file.
    public var pixelSize: CGSize
    /// Backing scale the capture was taken at (2 on Retina). Drives the "@2x" suffix.
    public var scale: CGFloat
    /// File name without extension, produced from the template at capture time.
    public var baseName: String

    public init(id: UUID = UUID(), kind: MediaKind, fileURL: URL, savedURL: URL? = nil, createdAt: Date = Date(),
                pixelSize: CGSize, scale: CGFloat, baseName: String) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.savedURL = savedURL
        self.createdAt = createdAt
        self.pixelSize = pixelSize
        self.scale = scale
        self.baseName = baseName
    }

    public var fileExtension: String { fileURL.pathExtension }

    /// Name used when saving/dragging: base name + optional "@2x" + extension.
    public var exportFileName: String {
        let suffix = (kind == .image && scale >= 2 && Prefs.bool(PrefKey.add2xSuffix)) ? "@2x" : ""
        return "\(baseName)\(suffix).\(fileExtension)"
    }

    /// Size in points (pixels / scale), what the capture looked like on screen.
    public var pointSize: CGSize { CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale) }

    public func loadImage() -> NSImage? {
        guard kind != .video, let image = NSImage(contentsOf: fileURL) else { return nil }
        image.size = pointSize
        return image
    }
}

extension Notification.Name {
    /// object: CapturedItem — posted when an item's file changed (e.g. annotations saved).
    public static let snapframeItemUpdated = Notification.Name("snapframe.itemUpdated")
    /// object: CapturedItem — posted when a new item was produced.
    public static let snapframeItemCreated = Notification.Name("snapframe.itemCreated")
}

/// Turns raw captures into stored items.
@MainActor
public enum ItemFactory {
    /// Encodes a screenshot with the user's format, writes it to the history directory and returns the item.
    /// Post-processing (1x scaling, sRGB, border, background preset) is applied by ImagePostProcessor first.
    public static func makeImageItem(_ image: CGImage, scale: CGFloat, date: Date = Date()) throws -> CapturedItem {
        let processed = ImagePostProcessor.process(image, scale: scale)
        let format = Prefs.imageFormat
        let id = UUID()
        let url = HistoryStore.directory.appendingPathComponent("\(id.uuidString).\(format.fileExtension)")
        try ImageIOWriter.write(processed.image, to: url, format: format)
        let item = CapturedItem(id: id, kind: .image, fileURL: url, createdAt: date,
                                pixelSize: CGSize(width: processed.image.width, height: processed.image.height),
                                scale: processed.scale, baseName: FileNamer.baseName(date: date))
        HistoryStore.shared.add(item)
        return item
    }

    /// Registers an already-written video or GIF (e.g. from the recorder) as an item.
    public static func makeMediaItem(movedFrom tempURL: URL, kind: MediaKind, pixelSize: CGSize, scale: CGFloat,
                                     date: Date = Date()) throws -> CapturedItem {
        let id = UUID()
        let url = HistoryStore.directory.appendingPathComponent("\(id.uuidString).\(tempURL.pathExtension)")
        try FileManager.default.moveItem(at: tempURL, to: url)
        let item = CapturedItem(id: id, kind: kind, fileURL: url, createdAt: date, pixelSize: pixelSize,
                                scale: scale, baseName: FileNamer.baseName(date: date))
        HistoryStore.shared.add(item)
        return item
    }

    /// Wraps an arbitrary image file (Open Annotate / Pin from file) as an item without copying into history.
    public static func itemForExternalFile(_ url: URL) -> CapturedItem? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let dpi = props[kCGImagePropertyDPIWidth] as? Double ?? 72
        let scale = url.deletingPathExtension().lastPathComponent.hasSuffix("@2x") ? 2 : max(1, CGFloat(dpi / 72).rounded())
        var base = url.deletingPathExtension().lastPathComponent
        if base.hasSuffix("@2x") { base.removeLast(3) }
        return CapturedItem(kind: .image, fileURL: url, savedURL: url, pixelSize: CGSize(width: w, height: h),
                            scale: scale, baseName: base)
    }
}

public enum ImageIOWriter {
    public enum WriteError: Error { case cannotCreate, cannotFinalize }

    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, jpegQuality: Double = 0.9) throws {
        let type: UTType = format == .png ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw WriteError.cannotCreate
        }
        var props: [CFString: Any] = [:]
        if format == .jpg { props[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.cannotFinalize }
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
