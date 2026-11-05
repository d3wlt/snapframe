import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Video → animated GIF using ImageIO.
public enum GIFConverter {
    public struct Result {
        public var url: URL
        public var pixelSize: CGSize
        /// Frames written after merging identical neighbours.
        public var frameCount: Int
    }

    public enum ConvertError: Error, LocalizedError {
        case noVideo, cannotCreate, cannotFinalize
        public var errorDescription: String? {
            switch self {
            case .noVideo: return "The recording has no video frames."
            case .cannotCreate: return "Could not create the GIF file."
            case .cannotFinalize: return "Could not write the GIF file."
            }
        }
    }

    /// Output size: never upscaled; `maxWidth` 0 (or less) means "original size".
    /// macOS (ImageIO, so Finder, Quick Look and Safari) won't decode GIFs much above 4 MP, so even
    /// "Original" (maxWidth 0) is capped to this pixel area.
    public static let maxGIFPixels: CGFloat = 4_000_000

    public static func targetSize(source: CGSize, maxWidth: Int) -> (width: Int, height: Int) {
        guard source.width > 0, source.height > 0 else { return (2, 2) }
        var w = maxWidth <= 0 ? source.width : min(CGFloat(maxWidth), source.width)
        if w * (source.height * w / source.width) > maxGIFPixels {
            w = (maxGIFPixels * source.width / source.height).squareRoot().rounded(.down)
        }
        let h = source.height * w / source.width
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    /// GIF delays are whole centiseconds; deriving each from cumulative rounded times avoids drift.
    public static func centisecondDelays(frameTimes: [Double], end: Double) -> [Int] {
        var delays: [Int] = []
        for (i, t) in frameTimes.enumerated() {
            let next = i + 1 < frameTimes.count ? frameTimes[i + 1] : end
            delays.append(delay(from: t, to: next))
        }
        return delays
    }

    static func delay(from t: Double, to next: Double) -> Int {
        max(2, Int((next * 100).rounded()) - Int((t * 100).rounded()))
    }

    /// ImageIO keeps every frame of a destination until it is finalised, so a long GIF would need all frames in
    /// memory. Frames go into small chunk destinations instead; each chunk is a complete GIF whose frame data
    /// (every frame carries its own colour table) is appended to the output file, then released.
    fileprivate final class ChunkedGIFWriter {
        private let handle: FileHandle
        private let url: URL
        private let chunkSize: Int
        private var dest: CGImageDestination?
        private var data = NSMutableData()
        private var inChunk = 0
        private var chunks = 0
        private(set) var frameCount = 0

        init(url: URL, chunkSize: Int) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            self.url = url
            self.chunkSize = max(1, chunkSize)
        }

        func add(_ image: CGImage, delayCS: Int) throws {
            if dest == nil {
                data = NSMutableData()
                guard let d = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, chunkSize, nil) else {
                    throw ConvertError.cannotCreate
                }
                if chunks == 0 {
                    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                }
                dest = d
            }
            CGImageDestinationAddImage(dest!, image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: Double(delayCS) / 100,
                kCGImagePropertyGIFUnclampedDelayTime: Double(delayCS) / 100,
            ]] as CFDictionary)
            inChunk += 1
            frameCount += 1
            if inChunk == chunkSize { try flush() }
        }

        private func flush() throws {
            guard let d = dest else { return }
            guard CGImageDestinationFinalize(d) else { throw ConvertError.cannotFinalize }
            dest = nil
            inChunk = 0
            let bytes = [UInt8](data as Data)
            guard bytes.count > 14 else { throw ConvertError.cannotFinalize }
            if chunks == 0 {
                // Keep header, screen descriptor, loop extension and global table; only drop the trailer.
                try handle.write(contentsOf: Data(bytes.last == 0x3B ? bytes.dropLast() : bytes[...]))
            } else {
                guard let body = Self.framesWithLocalTables(bytes) else { throw ConvertError.cannotFinalize }
                try handle.write(contentsOf: Data(body))
            }
            chunks += 1
            data = NSMutableData()
        }

        /// The frame blocks of a GIF, each with the file's global colour table copied in as a local table, so
        /// they stay valid when appended to a file with a different global table. nil if the data is malformed.
        static func framesWithLocalTables(_ b: [UInt8]) -> [UInt8]? {
            guard b.count > 14 else { return nil }
            var i = 13
            var table: [UInt8] = []
            var tableBits: UInt8 = 0
            if b[10] & 0x80 != 0 {
                tableBits = b[10] & 0x07
                let n = 3 * (1 << (Int(tableBits) + 1))
                guard i + n <= b.count else { return nil }
                table = Array(b[i..<(i + n)])
                i += n
            }
            var out: [UInt8] = []
            func copySubBlocks() -> Bool {
                while i < b.count {
                    let size = Int(b[i])
                    guard i + 1 + size <= b.count else { return false }
                    out.append(contentsOf: b[i..<(i + 1 + size)])
                    i += 1 + size
                    if size == 0 { return true }
                }
                return false
            }
            while i < b.count {
                switch b[i] {
                case 0x3B:
                    return out
                case 0x21: // extension: introducer, label, sub-blocks
                    guard i + 2 <= b.count else { return nil }
                    out.append(contentsOf: b[i..<(i + 2)])
                    i += 2
                    if !copySubBlocks() { return nil }
                case 0x2C: // image descriptor: 10 bytes, optional local table, LZW size, sub-blocks
                    guard i + 10 <= b.count else { return nil }
                    var desc = Array(b[i..<(i + 10)])
                    i += 10
                    if desc[9] & 0x80 != 0 {
                        let n = 3 * (1 << (Int(desc[9] & 0x07) + 1))
                        guard i + n <= b.count else { return nil }
                        out.append(contentsOf: desc)
                        out.append(contentsOf: b[i..<(i + n)])
                        i += n
                    } else {
                        guard !table.isEmpty else { return nil }
                        desc[9] = (desc[9] & 0x60) | 0x80 | tableBits // keep interlace/sort flags
                        out.append(contentsOf: desc)
                        out.append(contentsOf: table)
                    }
                    guard i < b.count else { return nil }
                    out.append(b[i]) // LZW minimum code size
                    i += 1
                    if !copySubBlocks() { return nil }
                default:
                    return nil
                }
            }
            return out
        }

        func finish() throws {
            try flush()
            try handle.write(contentsOf: Data([0x3B]))
            try handle.close()
        }

        func abort() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// ImageIO holds roughly 2.5× each frame's raw pixels until a chunk is finalized, so cap a chunk at
    /// ~50 MB of raw pixels: 12 frames at 1280 px wide, 2 at 2880×1800, 1 at 5K.
    static func chunkFrames(for size: CGSize, limit: Int) -> Int {
        let perFrame = max(1, Int(size.width) * Int(size.height) * 4)
        return max(1, min(limit, 50_000_000 / perFrame))
    }

    private struct Frame {
        var image: CGImage
        var pixels: [UInt8]
        var id: Int
    }

    /// Converts `videoURL` (optionally just `range`) to a looping GIF at `fps`, at most `maxWidth` pixels wide
    /// (0 = original size). Frames are decoded sequentially and written as soon as the following distinct frame
    /// is known, so memory stays at a few frames regardless of length. With `dedupe`, consecutive identical
    /// frames are merged into one frame with a longer delay.
    public static func convert(videoURL: URL, to outputURL: URL, fps: Int, maxWidth: Int,
                               range: CMTimeRange? = nil, dedupe: Bool = true, chunkSize: Int = 12,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ConvertError.noVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let source = natural.applying(transform)
        let srcSize = CGSize(width: abs(source.width), height: abs(source.height))
        let full = try await asset.load(.duration)
        let span = range ?? CMTimeRange(start: .zero, duration: full)
        let start = max(0, span.start.seconds)
        let duration = max(0.01, span.duration.seconds)
        let rate = Double(min(max(fps, 1), 50))
        let step = 1 / rate
        let target = targetSize(source: srcSize, maxWidth: maxWidth)

        try? FileManager.default.removeItem(at: outputURL)
        let gif = try ChunkedGIFWriter(url: outputURL, chunkSize: chunkFrames(for: CGSize(width: target.width, height: target.height), limit: chunkSize))
        var finished = false
        defer { if !finished { gif.abort() } }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConvertError.noVideo }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ConvertError.noVideo }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var pending: (frame: Frame, time: Double)?
        var held: Frame?
        var nextID = 0
        var nextGrid = 0.0
        var writeError: Error?

        func add(_ frame: Frame, delayCS: Int) {
            do { try gif.add(frame.image, delayCS: delayCS) } catch { writeError = writeError ?? error }
        }

        /// Shows `held` at every grid time before `limit`; a new GIF frame starts only when it really changed.
        func emitGrid(before limit: Double) {
            guard let frame = held else { return }
            while nextGrid < limit - 1e-9, nextGrid < duration - 1e-9 {
                autoreleasepool {
                    guard let p = pending else { pending = (frame, nextGrid); return }
                    let same = dedupe && (p.frame.id == frame.id || similar(p.frame.pixels, frame.pixels))
                    if !same {
                        add(p.frame, delayCS: delay(from: p.time, to: nextGrid))
                        pending = (frame, nextGrid)
                    }
                }
                nextGrid += step
            }
        }

        while true {
            try Task.checkCancellation()
            var finishedReading = false
            autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { finishedReading = true; return }
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
                emitGrid(before: t) // the previous frame stays on screen until this one arrives
                if let (image, bytes) = render(pixels, width: target.width, height: target.height) {
                    held = Frame(image: image, pixels: bytes, id: nextID)
                    nextID += 1
                }
                progress?(min(1, max(0, t / duration)))
            }
            if finishedReading { break }
        }
        if reader.status == .failed, held == nil { throw reader.error ?? ConvertError.noVideo }
        guard held != nil else { throw ConvertError.noVideo }
        emitGrid(before: duration)
        if let p = pending { add(p.frame, delayCS: delay(from: p.time, to: duration)) }
        if let writeError { throw writeError }
        guard gif.frameCount > 0 else { throw ConvertError.cannotFinalize }
        try gif.finish()
        finished = true
        progress?(1)
        return Result(url: outputURL, pixelSize: CGSize(width: target.width, height: target.height), frameCount: gif.frameCount)
    }

    /// Scales a decoded frame into an sRGB BGRA bitmap of exactly width×height and returns it with its bytes.
    private static func render(_ buffer: CVPixelBuffer, width: Int, height: Int) -> (CGImage, [UInt8])? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let src = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: info),
              let srcImage = src.makeImage(),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage(), let data = ctx.data else { return nil }
        let bytes = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * 4 * height))
        return (out, bytes)
    }

    /// Frames count as identical when no channel differs by more than `tolerance` (absorbs codec noise).
    static func similar(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 8) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count where abs(Int(pa[i]) - Int(pb[i])) > tolerance { return false }
                return true
            }
        }
    }
}

/// Trim / mute export of a recorded video.
public enum VideoTrimmer {
    public enum TrimError: Error, LocalizedError {
        case exportFailed(String)
        public var errorDescription: String? {
            if case .exportFailed(let m) = self { return "Export failed: \(m)" }
            return nil
        }
    }

    /// Writes `range` of the video at `url` to `output` (MP4). Tries passthrough first (no re-encode)
    /// and falls back to re-encoding. With `mute` the audio tracks are dropped.
    public static func export(url: URL, range: CMTimeRange?, mute: Bool, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let span = range ?? CMTimeRange(start: .zero, duration: duration)

        let source: AVAsset
        if mute {
            let comp = AVMutableComposition()
            guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first,
                  let dstVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw TrimError.exportFailed("no video track") }
            try dstVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: srcVideo, at: .zero)
            dstVideo.preferredTransform = try await srcVideo.load(.preferredTransform)
            source = comp
        } else {
            source = asset
        }

        var lastError: Error?
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            try? FileManager.default.removeItem(at: output)
            guard let session = AVAssetExportSession(asset: source, presetName: preset) else { continue }
            session.timeRange = span
            do {
                try await session.export(to: output, as: .mp4)
                return
            } catch {
                lastError = error
            }
        }
        throw TrimError.exportFailed(lastError?.localizedDescription ?? "unsupported")
    }
}

/// Post-pass for recordings with separate system-audio and microphone tracks: many players only play
/// the first audio track, so mix them into one.
public enum AudioTrackMixer {
    public enum MixError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            if case .failed(let m) = self { return "Could not mix audio: \(m)" }
            return nil
        }
    }

    /// No-op unless the file has more than one audio track. Video samples are copied without re-encoding;
    /// the audio tracks are mixed into a single AAC track and the file is replaced.
    public static func mergeAudioTracks(in url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count > 1, let video = try await asset.loadTracks(withMediaType: .video).first else { return }
        let hint = try await video.load(.formatDescriptions).first
        let transform = try await video.load(.preferredTransform)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".mix-\(UUID().uuidString).mp4")
        do {
            try await Task.detached {
                try mix(asset: asset, video: video, audio: audio, hint: hint, transform: transform, to: temp)
            }.value
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func mix(asset: AVAsset, video: AVAssetTrack, audio: [AVAssetTrack], hint: CMFormatDescription?,
                            transform: CGAffineTransform, to output: URL) throws {
        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let aOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut), reader.canAdd(aOut) else { throw MixError.failed("unsupported tracks") }
        reader.add(vOut)
        reader.add(aOut)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        vIn.transform = transform
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw MixError.failed("cannot write tracks") }
        writer.add(vIn)
        writer.add(aIn)
        guard reader.startReading() else { throw MixError.failed(reader.error?.localizedDescription ?? "cannot read") }
        guard writer.startWriting() else { throw MixError.failed(writer.error?.localizedDescription ?? "cannot write") }
        writer.startSession(atSourceTime: .zero)

        var videoDone = false, audioDone = false
        while !(videoDone && audioDone) {
            var progressed = false
            if !videoDone, vIn.isReadyForMoreMediaData {
                if let sb = vOut.copyNextSampleBuffer() { vIn.append(sb) } else { vIn.markAsFinished(); videoDone = true }
                progressed = true
            }
            if !audioDone, aIn.isReadyForMoreMediaData {
                if let sb = aOut.copyNextSampleBuffer() { aIn.append(sb) } else { aIn.markAsFinished(); audioDone = true }
                progressed = true
            }
            if writer.status == .failed || reader.status == .failed {
                writer.cancelWriting()
                throw MixError.failed((writer.error ?? reader.error)?.localizedDescription ?? "unknown")
            }
            if !progressed { Thread.sleep(forTimeInterval: 0.002) }
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw MixError.failed(writer.error?.localizedDescription ?? "unknown") }
    }
}

/// Lossless GIF trimming: frames are copied between ImageIO sources and destinations without re-quantising.
public enum GIFTrimmer {
    public struct Info: Sendable {
        public let frameCount: Int
        public let delays: [Double]
        public let duration: Double
        public let loopCount: Int
        public let pixelSize: CGSize
    }

    public enum TrimError: Error, LocalizedError {
        case unreadable, cannotCreate, cannotFinalize
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "Could not read the GIF file."
            case .cannotCreate: return "Could not create the GIF file."
            case .cannotFinalize: return "Could not write the GIF file."
            }
        }
    }

    private static func open(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              CGImageSourceGetType(src) as String? == UTType.gif.identifier else { throw TrimError.unreadable }
        return src
    }

    private static func info(of src: CGImageSource) -> Info {
        let n = CGImageSourceGetCount(src)
        var raw: [Double] = []
        for i in 0..<n {
            let gif = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            raw.append((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0)
        }
        let delays = RecordingMath.gifDelays(raw)
        let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int ?? 0
        let p0 = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let size = CGSize(width: p0?[kCGImagePropertyPixelWidth] as? Int ?? 0, height: p0?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        return Info(frameCount: n, delays: delays, duration: delays.reduce(0, +), loopCount: loop, pixelSize: size)
    }

    public static func info(url: URL) throws -> Info {
        info(of: try open(url))
    }

    /// Writes the frames of `url` chosen by `RecordingMath.gifFrameRange` to `output`, keeping their delays and the loop count.
    /// The first kept frame is rebuilt as a full frame; later frames are copied byte for byte (partial frames stay partial).
    public static func trim(url: URL, start: Double, end: Double, to output: URL) throws -> Info {
        let src = try open(url)
        let source = info(of: src)
        let range = RecordingMath.gifFrameRange(delays: source.delays, start: start, end: end)
        guard !range.isEmpty else { throw TrimError.cannotCreate }
        let bytes = (try? Data(contentsOf: url)).map { [UInt8]($0) } ?? []
        var file: [UInt8]
        if let layout = GIFLayout(bytes), layout.frames.count == source.frameCount {
            file = []
            var i = range.lowerBound
            while true {
                // A rebuilt full frame only stands in for the source canvas if the source frame keeps its pixels.
                let keeps = layout.frames[i].disposal <= 1 || i == range.upperBound - 1
                file += try rebuilt(src, i, source, first: i == range.lowerBound, disposal: keeps ? 1 : 2)
                i += 1
                if keeps { break }
            }
            for j in i..<range.upperBound { file += layout.rawFrame(j, from: bytes) }
        } else {
            file = []
            for i in range { file += try rebuilt(src, i, source, first: i == range.lowerBound, disposal: 2) }
        }
        file.append(0x3B)
        do { try Data(file).write(to: output) } catch { throw TrimError.cannotFinalize }
        return try info(url: output)
    }

    /// Frame `i` as a full composited frame from its own one-frame destination (its own palette, so frames are not re-quantised together): with the
    /// header, screen descriptor and loop extension when `first`, else as frame blocks with a local colour table.
    private static func rebuilt(_ src: CGImageSource, _ i: Int, _ source: Info, first: Bool, disposal: UInt8) throws -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else { throw TrimError.cannotCreate }
        if first {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: source.loopCount]] as CFDictionary)
        }
        CGImageDestinationAddImageFromSource(dest, src, i, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: source.delays[i],
            kCGImagePropertyGIFUnclampedDelayTime: source.delays[i],
        ]] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TrimError.cannotFinalize }
        var bytes = [UInt8](data as Data)
        guard bytes.count > 14 else { throw TrimError.cannotFinalize }
        guard let gce = GIFLayout(bytes)?.frames.first?.gce else { throw TrimError.cannotFinalize }
        bytes[gce.lowerBound + 3] = (bytes[gce.lowerBound + 3] & ~0x1C) | (disposal << 2)
        if first { return bytes.last == 0x3B ? Array(bytes.dropLast()) : bytes }
        guard let body = GIFConverter.ChunkedGIFWriter.framesWithLocalTables(bytes) else { throw TrimError.cannotFinalize }
        return body
    }
}

/// Byte ranges of a GIF's frames: each frame's graphic control extension (if any) and its image block
/// (descriptor, optional local colour table, LZW data). nil if the data is malformed.
private struct GIFLayout {
    struct Frame {
        var gce: Range<Int>?
        var image: Range<Int>
        var hasLocalTable: Bool
        var disposal: UInt8
    }
    var globalTable: ArraySlice<UInt8> = []
    var globalTableBits: UInt8 = 0
    var frames: [Frame] = []

    init?(_ b: [UInt8]) {
        guard b.count > 13, b.starts(with: Array("GIF".utf8)) else { return nil }
        var i = 13
        if b[10] & 0x80 != 0 {
            globalTableBits = b[10] & 0x07
            let n = 3 * (1 << (Int(globalTableBits) + 1))
            guard i + n <= b.count else { return nil }
            globalTable = b[i..<(i + n)]
            i += n
        }
        func skipSubBlocks() -> Bool {
            while i < b.count {
                let size = Int(b[i])
                i += 1 + size
                if size == 0 { return i <= b.count }
            }
            return false
        }
        var gce: Range<Int>?
        while i < b.count {
            switch b[i] {
            case 0x3B:
                return
            case 0x21:
                let start = i
                guard i + 2 <= b.count else { return nil }
                let isGCE = b[i + 1] == 0xF9
                i += 2
                guard skipSubBlocks() else { return nil }
                if isGCE {
                    guard i - start >= 8 else { return nil }
                    gce = start..<i
                }
            case 0x2C:
                let start = i
                guard i + 10 <= b.count else { return nil }
                let packed = b[i + 9]
                i += 10
                if packed & 0x80 != 0 { i += 3 * (1 << (Int(packed & 0x07) + 1)) }
                i += 1 // LZW minimum code size
                guard i <= b.count, skipSubBlocks() else { return nil }
                let disposal = gce.map { (b[$0.lowerBound + 3] >> 2) & 0x07 } ?? 0
                frames.append(Frame(gce: gce, image: start..<i, hasLocalTable: packed & 0x80 != 0, disposal: disposal))
                gce = nil
            default:
                return nil
            }
        }
        return nil
    }

    /// Frame `j` exactly as stored, with the global colour table copied in as a local one if it used it.
    func rawFrame(_ j: Int, from b: [UInt8]) -> [UInt8] {
        let f = frames[j]
        var out: [UInt8] = f.gce.map { Array(b[$0]) } ?? []
        if f.hasLocalTable || globalTable.isEmpty {
            out += b[f.image]
        } else {
            var descriptor = Array(b[f.image.lowerBound..<(f.image.lowerBound + 10)])
            descriptor[9] = (descriptor[9] & 0x60) | 0x80 | globalTableBits
            out += descriptor
            out += globalTable
            out += b[(f.image.lowerBound + 10)..<f.image.upperBound]
        }
        return out
    }
}
