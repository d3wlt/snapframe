import AVFoundation
import AppKit
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import Darwin
@testable import SnapframeCore

/// Writes a small MP4 (and optionally an AAC track): `bands` solid colours, each lasting `seconds / bands`.
private func makeSyntheticVideo(seconds: Double = 1.0, fps: Int = 10, size: CGSize = CGSize(width: 320, height: 180),
                                bands: Int = 5, withAudio: Bool = false, audioTracks: Int = 1, textured: Bool = false,
                                movingSquare: Bool = false) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-synth-\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAverageBitRateKey: 2_000_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(video)
    var audioInputs: [AVAssetWriterInput] = []
    for _ in 0..<(withAudio ? audioTracks : 0) {
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        writer.add(a)
        audioInputs.append(a)
    }
    guard writer.startWriting() else { throw CheckFailure(description: "writer: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    let palette: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1)]
    func waitReady(_ input: AVAssetWriterInput) throws {
        var spins = 0
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1
            if spins > 5000 { throw CheckFailure(description: "writer input never became ready") }
        }
    }
    let frames = Int(seconds * Double(fps))
    for i in 0..<frames {
        let t = Double(i) / Double(fps)
        let band = min(bands - 1, i * bands / frames)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { throw CheckFailure(description: "pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let c = palette[band % palette.count]
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        if textured { // many frame-specific colours, so every frame needs its own palette
            for s in 0..<24 {
                let h = CGFloat((i * 37 + s * 11) % 100) / 100
                ctx.setFillColor(red: h, green: 1 - h, blue: CGFloat((i * 13 + s * 7) % 100) / 100, alpha: 1)
                ctx.fill(CGRect(x: 0, y: CGFloat(s) * size.height / 24, width: size.width, height: size.height / 24))
            }
        }
        if movingSquare { // static screen-like background with one small moving region, as in a typical recording
            for s in 0..<12 {
                ctx.setFillColor(red: CGFloat(s) / 12, green: 0.5, blue: 1 - CGFloat(s) / 12, alpha: 1)
                ctx.fill(CGRect(x: CGFloat(s) * size.width / 12, y: 0, width: size.width / 12, height: size.height))
            }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i * 6 % Int(size.width - 24)), y: size.height / 2, width: 24, height: 24))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        try waitReady(video)
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))

        for audio in audioInputs {
            let chunk = makeAudioSample(start: t, seconds: 1.0 / Double(fps), channels: 1, rate: 44_100)
            try waitReady(audio)
            audio.append(chunk)
        }
    }
    video.markAsFinished()
    audioInputs.forEach { $0.markAsFinished() }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw CheckFailure(description: "synthetic video failed: \(String(describing: writer.error))") }
    return url
}

/// Interleaved float PCM sine chunk starting at `start` seconds.
private func makeAudioSample(start: Double, seconds: Double, channels: Int = 2, rate: Int = 48_000) -> CMSampleBuffer {
    let n = Int(seconds * Double(rate))
    var samples = [Float](repeating: 0, count: n * channels)
    let first = Int(start * Double(rate))
    for k in 0..<n {
        let phase: Double = Double(k + first) * 2.0 * Double.pi * 440.0 / Double(rate)
        let v = Float(sin(phase)) * 0.3
        for c in 0..<channels { samples[k * channels + c] = v }
    }
    var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                           mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                           mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var block: CMBlockBuffer?
    let bytes = n * 4 * channels
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                       blockBufferOut: &block)
    CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: n,
        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: CMTimeScale(rate)),
        packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

/// A BGRA frame sample carrying an SCStream-style frame status attachment.
private func makeVideoSample(at seconds: Double, shade: Int, size: CGSize = CGSize(width: 128, height: 72),
                             status: SCFrameStatus = .complete) -> CMSampleBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: Int(size.width), height: Int(size.height),
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let v = CGFloat((shade * 53) % 256) / 255
    ctx.setFillColor(red: v, green: 1 - v, blue: CGFloat((shade * 97) % 256) / 255, alpha: 1)
    ctx.fill(CGRect(origin: .zero, size: size))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                    decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: format!,
                                             sampleTiming: &timing, sampleBufferOut: &sb)
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sb!, createIfNecessary: true) as! [NSMutableDictionary]
    attachments[0][SCStreamFrameInfo.status.rawValue] = status.rawValue
    return sb!
}

/// Presentation times (seconds) of a track's samples, in file order.
private func sampleTimes(_ url: URL, _ type: AVMediaType) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: type).first else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(out)
    reader.startReading()
    var times: [Double] = []
    while let sb = out.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sb) > 0, CMSampleBufferGetTotalSampleSize(sb) > 0 else { continue } // skip marker buffers
        times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }
    return times
}

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

/// Samples the process footprint on a background thread until stopped.
private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var peak = 0.0
    func start() {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let go = running
                peak = max(peak, footprintMB())
                lock.unlock()
                if !go { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
    func stop() -> Double {
        lock.lock(); running = false; let p = peak; lock.unlock()
        return p
    }
}

private func writerConfig(audio: Bool = false) -> RecordingWriter.Config {
    .init(width: 128, height: 72, fps: 10, codec: .h264, quality: .medium, systemAudio: audio, microphone: false)
}

private func gifInfo(_ url: URL) throws -> (frames: Int, size: CGSize, loop: Int?, totalDelay: Double) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CheckFailure(description: "not an image") }
    let n = CGImageSourceGetCount(src)
    let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
    let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
    var total = 0.0
    for i in 0..<n {
        let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        total += ((p?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
    }
    let p0 = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let size = CGSize(width: p0?[kCGImagePropertyPixelWidth] as? Int ?? 0, height: p0?[kCGImagePropertyPixelHeight] as? Int ?? 0)
    return (n, size, loop, total)
}

private func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-test-\(UUID().uuidString).\(ext)")
}

private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

extension SelfTests {
    static let recording: [TestCase] = [
        TestCase("Recording: pixel sizes are even and follow scale") {
            let a = RecordingMath.pixelSize(points: CGSize(width: 501, height: 333), scale: 2, scaleTo1x: false)
            try check(a.width % 2 == 0 && a.height % 2 == 0, "\(a)")
            try checkEqual(a.width, 1002)
            try checkEqual(a.height, 666)
            let b = RecordingMath.pixelSize(points: CGSize(width: 501, height: 333), scale: 2, scaleTo1x: true)
            try checkEqual(b.width, 502)
            try checkEqual(b.height, 334)
            let tiny = RecordingMath.pixelSize(points: CGSize(width: 0.4, height: 1), scale: 1, scaleTo1x: false)
            try check(tiny.width >= 2 && tiny.height >= 2)
        },
        TestCase("Recording: GIF capture scale never exceeds native and shrinks for narrow max width") {
            try checkEqual(RecordingMath.gifCaptureScale(pointWidth: 600, nativeScale: 2, maxWidth: 1280), 2)
            try checkEqual(RecordingMath.gifCaptureScale(pointWidth: 1600, nativeScale: 2, maxWidth: 1280), 1)
            try checkEqual(RecordingMath.gifCaptureScale(pointWidth: 1000, nativeScale: 2, maxWidth: 1500), 1.5)
        },
        TestCase("Recording: bitrate grows with quality/fps/size, HEVC is cheaper, result is clamped") {
            func br(_ w: Int, _ h: Int, _ fps: Int, _ c: VideoCodec, _ q: VideoQuality) -> Int {
                RecordingMath.bitrate(width: w, height: h, fps: fps, codec: c, quality: q)
            }
            try check(br(1920, 1080, 60, .h264, .low) < br(1920, 1080, 60, .h264, .medium))
            try check(br(1920, 1080, 60, .h264, .medium) < br(1920, 1080, 60, .h264, .high))
            try check(br(1920, 1080, 30, .h264, .high) < br(1920, 1080, 60, .h264, .high))
            try check(br(1920, 1080, 60, .hevc, .high) < br(1920, 1080, 60, .h264, .high))
            try checkEqual(br(16, 16, 5, .h264, .low), 1_000_000)
            try checkEqual(br(15360, 8640, 120, .h264, .high), 100_000_000)
        },
        TestCase("Recording: elapsed time formatting") {
            try checkEqual(RecordingMath.formatElapsed(0), "0:00")
            try checkEqual(RecordingMath.formatElapsed(7.9), "0:07")
            try checkEqual(RecordingMath.formatElapsed(723), "12:03")
            try checkEqual(RecordingMath.formatElapsed(3723), "1:02:03")
        },
        TestCase("Recording: pause timeline closes gaps and drops paused/early samples") {
            var tl = PauseTimeline()
            try check(tl.output(for: t(1)) == nil, "before origin")
            tl.setOrigin(t(10))
            try check(tl.output(for: t(9.5)) == nil, "samples before the first frame are dropped")
            try checkEqual(tl.output(for: t(11))?.seconds ?? -1, 1.0)
            tl.pause(at: t(12))
            try check(tl.output(for: t(13)) == nil, "while paused")
            tl.resume(at: t(15))
            try check(tl.output(for: t(14)) == nil, "captured during the pause")
            try checkEqual(tl.output(for: t(15))?.seconds ?? -1, 2.0) // 5s since origin minus the 3s pause
            try checkEqual(tl.output(for: t(18))?.seconds ?? -1, 5.0)
            tl.pause(at: t(20))
            tl.resume(at: t(21))
            try checkEqual(tl.output(for: t(22))?.seconds ?? -1, 8.0) // 12s - 3s - 1s
            try checkEqual(tl.output(for: t(11.5))?.seconds ?? -1, 1.5) // earlier samples unaffected
        },
        TestCase("Recording: elapsed clock excludes paused time") {
            var c = ElapsedClock()
            let t0 = Date(timeIntervalSince1970: 1000)
            c.start(at: t0)
            try checkEqual(c.elapsed(at: t0.addingTimeInterval(4)), 4)
            c.pause(at: t0.addingTimeInterval(4))
            try check(c.isPaused)
            try checkEqual(c.elapsed(at: t0.addingTimeInterval(30)), 4)
            c.resume(at: t0.addingTimeInterval(30))
            try checkEqual(c.elapsed(at: t0.addingTimeInterval(36)), 10)
        },
        TestCase("Recording: area encoding round-trips and rejects junk") {
            let area = ScreenArea(displayID: 69_733_058, rect: CGRect(x: 10.5, y: 20, width: 640, height: 360.25))
            try checkEqual(RecordingMath.decodeArea(RecordingMath.encode(area)), area)
            try check(RecordingMath.decodeArea("") == nil)
            try check(RecordingMath.decodeArea("1 2 3 0 5") == nil, "zero width")
        },
        TestCase("Recording: geometry conversion, clamping and HUD placement") {
            let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
            let r = RecordingMath.cocoaRect(CGRect(x: 100, y: 50, width: 400, height: 300), screenFrame: screen)
            try checkEqual(r, CGRect(x: -1340, y: 650, width: 400, height: 300))
            let n = RecordingMath.normalized(CGRect(x: -20, y: 10.4, width: 200.6, height: 5000), displaySize: CGSize(width: 1440, height: 900))
            try checkEqual(n, CGRect(x: 0, y: 10, width: 181, height: 890))
            try checkEqual(RecordingMath.normalized(CGRect(x: 5000, y: 5000, width: 10, height: 10), displaySize: CGSize(width: 100, height: 100)),
                           CGRect(x: 0, y: 0, width: 100, height: 100))

            let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let hud = CGSize(width: 300, height: 42)
            let below = RecordingMath.hudFrame(size: hud, around: CGRect(x: 350, y: 300, width: 300, height: 300), in: visible)
            try checkEqual(below.maxY + 12, 300)
            try checkEqual(below.midX, 500)
            let above = RecordingMath.hudFrame(size: hud, around: CGRect(x: 350, y: 10, width: 300, height: 400), in: visible)
            try checkEqual(above.minY, 422)
            let inside = RecordingMath.hudFrame(size: hud, around: visible, in: visible)
            try check(visible.contains(inside) && inside.minY >= 80 && inside.minY < 200, "clear of the Dock reveal edge: \(inside)")
            let edge = RecordingMath.hudFrame(size: hud, around: CGRect(x: 0, y: 300, width: 100, height: 100), in: visible)
            try check(edge.minX >= 8, "clamped to the screen edge")
        },
        TestCase("Recording: keystroke labels and typing buffer") {
            let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
            let combo = KeystrokeFormatter.label(keyCode: UInt32(kVK_ANSI_4), characters: "$", flags: cmdShift)
            try checkEqual(combo.text, "⇧⌘4")
            try check(combo.isCombo)
            let ctrlOpt = KeystrokeFormatter.label(keyCode: UInt32(kVK_Return), characters: "\r", flags: [.control, .option])
            try checkEqual(ctrlOpt.text, "⌃⌥↩")
            try checkEqual(KeystrokeFormatter.label(keyCode: UInt32(kVK_Space), characters: " ", flags: []).text, "Space")
            try checkEqual(KeystrokeFormatter.label(keyCode: UInt32(kVK_ANSI_A), characters: "a", flags: .shift).text, "a")

            var buf = KeystrokeBuffer()
            let a = (text: "h", isCombo: false), b = (text: "i", isCombo: false)
            try checkEqual(buf.add(a, at: 0), "h")
            try checkEqual(buf.add(b, at: 0.5), "hi")
            try checkEqual(buf.add(b, at: 5), "i") // pause in typing starts over
            try checkEqual(buf.add((text: "⌘C", isCombo: true), at: 5.2), "⌘C")
            try checkEqual(buf.add(a, at: 5.4), "h") // a combo is never merged with typing
        },
        TestCase("GIF: delays use cumulative centisecond rounding and a 2cs floor") {
            let times = (0..<15).map { Double($0) / 15 }
            let d = GIFConverter.centisecondDelays(frameTimes: times, end: 1)
            try checkEqual(d.reduce(0, +), 100)
            try check(d.allSatisfy { $0 == 6 || $0 == 7 }, "\(d)")
            let fast = GIFConverter.centisecondDelays(frameTimes: [0, 0.001, 0.002], end: 0.003)
            try check(fast.allSatisfy { $0 >= 2 })
        },
        TestCase("GIF: frame dedupe ignores codec noise but not a single changed pixel") {
            let base = [UInt8](repeating: 120, count: 64 * 64 * 4)
            var noisy = base
            for i in stride(from: 0, to: noisy.count, by: 7) { noisy[i] = 124 }
            try check(GIFConverter.similar(base, noisy))
            var changed = base
            changed[1000] = 220 // e.g. a blinking text cursor
            try check(!GIFConverter.similar(base, changed))
            try check(!GIFConverter.similar(base, [UInt8](repeating: 120, count: 10)))
        },
        TestCase("GIF: converts a synthetic video with loop, width limit and frame merging") {
            let video = try makeSyntheticVideo()
            let out = tempURL("gif")
            defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
            let result = try await GIFConverter.convert(videoURL: video, to: out, fps: 10, maxWidth: 160)
            let info = try gifInfo(out)
            try checkEqual(info.size, CGSize(width: 160, height: 90))
            try checkEqual(result.pixelSize, CGSize(width: 160, height: 90))
            try checkEqual(info.loop, 0) // 0 = loop forever
            try checkEqual(info.frames, 5) // five colour bands, ten sampled frames merged pairwise
            try checkEqual(result.frameCount, 5)
            try check(abs(info.totalDelay - 1.0) < 0.05, "total delay \(info.totalDelay)")
        },
        TestCase("GIF: without dedupe every sampled frame is kept; small videos are not upscaled") {
            let video = try makeSyntheticVideo()
            let out = tempURL("gif")
            defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
            _ = try await GIFConverter.convert(videoURL: video, to: out, fps: 10, maxWidth: 4000, dedupe: false)
            let info = try gifInfo(out)
            try checkEqual(info.frames, 10)
            try checkEqual(info.size, CGSize(width: 320, height: 180))
            try check(abs(info.totalDelay - 1.0) < 0.05, "total delay \(info.totalDelay)")
        },
        TestCase("GIF: a sub-range only converts that span") {
            let video = try makeSyntheticVideo(seconds: 2.0, bands: 10)
            let out = tempURL("gif")
            defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
            let range = CMTimeRange(start: t(0.5), duration: t(1.0))
            _ = try await GIFConverter.convert(videoURL: video, to: out, fps: 10, maxWidth: 160, range: range, dedupe: false)
            let info = try gifInfo(out)
            try checkEqual(info.frames, 10)
            try check(abs(info.totalDelay - 1.0) < 0.05, "total delay \(info.totalDelay)")
        },
        TestCase("Trim: exporting a range shortens the video; muting drops audio only when asked") {
            let video = try makeSyntheticVideo(seconds: 2.0, bands: 4, withAudio: true)
            let trimmed = tempURL("mp4"), muted = tempURL("mp4"), plain = tempURL("mp4")
            defer { [video, trimmed, muted, plain].forEach { try? FileManager.default.removeItem(at: $0) } }
            let source = AVURLAsset(url: video)
            let sourceDuration = try await source.load(.duration).seconds
            try check(abs(sourceDuration - 2.0) < 0.15, "source \(sourceDuration)")
            try checkEqual(try await source.loadTracks(withMediaType: .audio).count, 1)

            try await VideoTrimmer.export(url: video, range: CMTimeRange(start: t(0.5), duration: t(1.0)), mute: false, to: trimmed)
            let a = AVURLAsset(url: trimmed)
            let trimmedDuration = try await a.load(.duration).seconds
            try check(abs(trimmedDuration - 1.0) < 0.2, "trimmed duration \(trimmedDuration)")
            try check(trimmedDuration < sourceDuration - 0.5)
            try checkEqual(try await a.loadTracks(withMediaType: .audio).count, 1)
            try checkEqual(try await a.loadTracks(withMediaType: .video).count, 1)

            try await VideoTrimmer.export(url: video, range: nil, mute: true, to: muted)
            let m = AVURLAsset(url: muted)
            try checkEqual(try await m.loadTracks(withMediaType: .audio).count, 0)
            try checkEqual(try await m.loadTracks(withMediaType: .video).count, 1)
            let mutedDuration = try await m.load(.duration).seconds
            try check(abs(mutedDuration - sourceDuration) < 0.15)

            try await VideoTrimmer.export(url: video, range: nil, mute: false, to: plain)
            try checkEqual(try await AVURLAsset(url: plain).loadTracks(withMediaType: .audio).count, 1)
        },
        TestCase("Recording: pause timeline ignores pauses before the first frame and never goes negative") {
            var tl = PauseTimeline()
            tl.pause(at: t(1))
            tl.resume(at: t(3))
            tl.setOrigin(t(4)) // first frame arrives after the early pause
            try checkEqual(tl.output(for: t(5))?.seconds ?? -1, 1.0)
            try check((tl.output(for: t(4))?.seconds ?? -1) >= 0)
        },
        TestCase("Recording: audio buffers overlapping a pause boundary are dropped") {
            var tl = PauseTimeline()
            tl.setOrigin(t(0))
            try checkEqual(tl.output(for: t(9.8), duration: t(0.1))?.seconds ?? -1, 9.8)
            tl.pause(at: t(10))
            try check(tl.output(for: t(9.95), duration: t(0.1)) == nil, "runs into the pause")
            tl.resume(at: t(12))
            try check(tl.output(for: t(11.95), duration: t(0.1)) == nil, "runs out of the pause")
            try check(tl.output(for: t(9.95), duration: t(0.1)) == nil, "still straddles the closed pause")
            try checkEqual(tl.output(for: t(12), duration: t(0.1))?.seconds ?? -1, 10.0)
        },
        TestCase("Recording: stop time maps past pauses and holds at an active pause") {
            var tl = PauseTimeline()
            tl.setOrigin(t(100))
            tl.pause(at: t(102))
            tl.resume(at: t(105))
            try checkEqual(tl.outputEnd(at: t(108))?.seconds ?? -1, 5.0) // 8s - 3s paused
            tl.pause(at: t(110))
            try checkEqual(tl.outputEnd(at: t(200))?.seconds ?? -1, 7.0) // stopped while paused: ends at the pause
        },
        TestCase("Writer: idle frame notifications are skipped, complete frames kept") {
            let url = tempURL("mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let w = try RecordingWriter(config: writerConfig(), outputURL: url)
            let base = 5000.0
            let plan: [(Double, SCFrameStatus)] = [(0, .complete), (0.1, .complete), (0.2, .idle), (0.3, .complete), (0.4, .idle)]
            for (i, f) in plan.enumerated() {
                let sample = makeVideoSample(at: base + f.0, shade: i, status: f.1)
                try check(RecordingWriter.isCompleteFrame(sample) == (f.1 == .complete))
                w.appendVideo(sample)
                try await Task.sleep(for: .milliseconds(5))
            }
            let out = try await w.finish(endingAt: t(base + 0.5))
            let times = try await sampleTimes(out.url, .video)
            try checkEqual(times.count, 3)
            try check(abs(times[2] - 0.3) < 0.01, "timestamps follow the source: \(times)")
        },
        TestCase("Writer: a mid-recording pause with audio leaves no gap and no overlapping audio") {
            let url = tempURL("mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let w = try RecordingWriter(config: writerConfig(audio: true), outputURL: url)
            let base = 8000.0
            for tick in 0..<30 {
                let at = Double(tick) / 10
                if tick == 10 { w.pause(at: t(base + 1.0)) }
                if tick == 20 { w.resume(at: t(base + 2.0)) }
                w.appendVideo(makeVideoSample(at: base + at, shade: tick))
                w.appendAudio(makeAudioSample(start: base + at, seconds: 0.1), kind: .system)
                try await Task.sleep(for: .milliseconds(5))
            }
            let out = try await w.finish(endingAt: t(base + 3.0))
            try check(abs(out.duration - 2.0) < 0.15, "duration \(out.duration)")
            let asset = AVURLAsset(url: out.url)
            let fileDuration = try await asset.load(.duration).seconds
            try check(abs(fileDuration - 2.0) < 0.2, "file duration \(fileDuration)")
            let video = try await sampleTimes(out.url, .video)
            try checkEqual(video.count, 20)
            try check(video.sorted() == video && Set(video).count == video.count, "video timestamps strictly increase")
            try check(abs(video[10] - 1.0) < 0.01, "first frame after the pause follows the last one directly: \(video[10])")
            let audio = try await sampleTimes(out.url, .audio)
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first!
            let audioSpan = try await audioTrack.load(.timeRange)
            try check(abs(audioSpan.duration.seconds - 2.0) < 0.25, "audio covers the recorded 2 s, not the paused one: \(audioSpan.duration.seconds)")
            try check(zip(audio, audio.dropFirst()).allSatisfy { $0 < $1 }, "audio timestamps strictly increase")
            try check((audio.last ?? 9) < 2.1, "no audio from the paused span after the end")
        },
        TestCase("Writer: a static screen holds its only frame until the stop time") {
            let url = tempURL("mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let w = try RecordingWriter(config: writerConfig(), outputURL: url)
            w.appendVideo(makeVideoSample(at: 3000, shade: 1))
            let out = try await w.finish(endingAt: t(3005))
            let d = try await AVURLAsset(url: out.url).load(.duration).seconds
            try check(d > 4.8 && d < 5.2, "duration \(d)")
        },
        TestCase("Writer: finishing without frames, after cancel, or twice fails cleanly and removes the file") {
            func fails(_ w: RecordingWriter, _ end: Double) async -> Bool {
                do { _ = try await w.finish(endingAt: t(end)); return false } catch { return true }
            }
            let a = tempURL("mp4"), b = tempURL("mp4"), c = tempURL("mp4")
            defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }
            let noFrames = try RecordingWriter(config: writerConfig(), outputURL: a)
            noFrames.appendVideo(makeVideoSample(at: 10, shade: 0, status: .idle)) // never a complete frame
            let r_noFrames = await fails(noFrames, 11)
            try check(r_noFrames, "no frames")
            try check(!FileManager.default.fileExists(atPath: a.path))

            let cancelled = try RecordingWriter(config: writerConfig(), outputURL: b)
            cancelled.appendVideo(makeVideoSample(at: 10, shade: 0))
            cancelled.cancel()
            cancelled.appendVideo(makeVideoSample(at: 10.1, shade: 1)) // ignored, must not crash
            let r_cancelled = await fails(cancelled, 11)
            try check(r_cancelled, "after cancel")

            let twice = try RecordingWriter(config: writerConfig(), outputURL: c)
            twice.appendVideo(makeVideoSample(at: 10, shade: 0))
            _ = try await twice.finish(endingAt: t(11))
            let r_twice = await fails(twice, 12)
            try check(r_twice, "second finish")
        },
        TestCase("GIF: frames spliced from separate chunks decode correctly and keep their delays") {
            let video = try makeSyntheticVideo() // red, green, blue, yellow, cyan
            let out = tempURL("gif")
            defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
            let result = try await GIFConverter.convert(videoURL: video, to: out, fps: 10, maxWidth: 0, chunkSize: 2)
            try checkEqual(result.frameCount, 5) // chunks of 2 + 2 + 1
            let info = try gifInfo(out)
            try checkEqual(info.frames, 5)
            try checkEqual(info.loop, 0)
            try check(abs(info.totalDelay - 1.0) < 0.05, "total delay \(info.totalDelay)")
            let src = CGImageSourceCreateWithURL(out as CFURL, nil)!
            let expected: [(Int, Int, Int)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255)]
            for (i, e) in expected.enumerated() {
                let img = CGImageSourceCreateImageAtIndex(src, i, nil)!
                var px = [UInt8](repeating: 0, count: 4)
                let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
                let d = abs(Int(px[0]) - e.0) + abs(Int(px[1]) - e.1) + abs(Int(px[2]) - e.2)
                try check(d < 60, "frame \(i) is \(px), expected \(e)")
            }
        },
        TestCase("GIFTrimmer: a trim spanning GIFConverter chunks is pixel-identical to the source frames") {
            let video = try makeSyntheticVideo(seconds: 3.0, bands: 12, textured: true) // 30 frames at 10 fps
            let gif = tempURL("gif"), out = tempURL("gif")
            defer { for u in [video, gif, out] { try? FileManager.default.removeItem(at: u) } }
            _ = try await GIFConverter.convert(videoURL: video, to: gif, fps: 10, maxWidth: 0, dedupe: false, chunkSize: 2)
            let source = try GIFTrimmer.info(url: gif)
            let range = RecordingMath.gifFrameRange(delays: source.delays, start: 0.55, end: 2.35)
            try check(range.count >= 10 && range.lowerBound % 2 == 1, "range \(range) should span several chunks and start mid-chunk")
            let result = try GIFTrimmer.trim(url: gif, start: 0.55, end: 2.35, to: out)
            try checkEqual(result.frameCount, range.count)
            try checkEqual(result.loopCount, source.loopCount)
            func rgba(_ url: URL, _ i: Int) -> [UInt8] {
                let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, i, nil)!
                var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
                let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                return px
            }
            for k in 0..<range.count {
                try check(rgba(out, k) == rgba(gif, range.lowerBound + k), "frame \(k) differs from source frame \(range.lowerBound + k)")
                try check(abs(result.delays[k] - source.delays[range.lowerBound + k]) < 0.001, "delay of frame \(k)")
            }
        },
        TestCase("GIFTrimmer: trimming a recording with partial frames stays pixel-identical and proportional in size") {
            let video = try makeSyntheticVideo(seconds: 6.0, size: CGSize(width: 640, height: 360), movingSquare: true)
            let gif = tempURL("gif"), out = tempURL("gif")
            defer { for u in [video, gif, out] { try? FileManager.default.removeItem(at: u) } }
            _ = try await GIFConverter.convert(videoURL: video, to: gif, fps: 10, maxWidth: 0)
            let source = try GIFTrimmer.info(url: gif)
            let result = try GIFTrimmer.trim(url: gif, start: source.duration * 0.1, end: source.duration * 0.9, to: out)
            let range = RecordingMath.gifFrameRange(delays: source.delays, start: source.duration * 0.1, end: source.duration * 0.9)
            try checkEqual(result.frameCount, range.count)
            let src = CGImageSourceCreateWithURL(gif as CFURL, nil)!, dst = CGImageSourceCreateWithURL(out as CFURL, nil)!
            func rgba(_ s: CGImageSource, _ i: Int) -> [UInt8] {
                let img = CGImageSourceCreateImageAtIndex(s, i, nil)!
                var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
                let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                return px
            }
            for k in 0..<range.count {
                try check(rgba(dst, k) == rgba(src, range.lowerBound + k), "frame \(k) differs from source frame \(range.lowerBound + k)")
            }
            let sourceBytes = Double(try Data(contentsOf: gif).count), trimmedBytes = Double(try Data(contentsOf: out).count)
            let proportional = sourceBytes * Double(range.count) / Double(source.frameCount)
            print(String(format: "      GIF trim size: source %.0f B, %d of %d frames, trimmed %.0f B (%.2fx proportional)",
                         sourceBytes, range.count, source.frameCount, trimmedBytes, trimmedBytes / proportional))
            try check(trimmedBytes < proportional * 1.3, "trimmed \(trimmedBytes) B vs proportional \(proportional) B")
        },
        TestCase("GIF: max width 0 keeps the original size") {
            try checkEqual(GIFConverter.targetSize(source: CGSize(width: 2000, height: 1000), maxWidth: 0).width, 2000)
            let capped = GIFConverter.targetSize(source: CGSize(width: 3000, height: 1500), maxWidth: 0)
            try check(CGFloat(capped.width * capped.height) <= GIFConverter.maxGIFPixels && capped.width > 2700, "\(capped)")
            try checkEqual(GIFConverter.targetSize(source: CGSize(width: 3000, height: 1500), maxWidth: 1280).height, 640)
            try checkEqual(RecordingMath.gifCaptureScale(pointWidth: 2000, nativeScale: 2, maxWidth: 0), 2)
            let video = try makeSyntheticVideo()
            let out = tempURL("gif")
            defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
            _ = try await GIFConverter.convert(videoURL: video, to: out, fps: 10, maxWidth: 0)
            try checkEqual(try gifInfo(out).size, CGSize(width: 320, height: 180))
        },
        TestCase("GIF: converting a long, all-different 1024px video keeps memory bounded") {
            let video = try makeSyntheticVideo(seconds: 24, fps: 10, size: CGSize(width: 1024, height: 576), bands: 240)
            let out = tempURL("gif")
            defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
            let before = footprintMB()
            let sampler = PeakSampler()
            sampler.start()
            let result = try await GIFConverter.convert(videoURL: video, to: out, fps: 10, maxWidth: 0)
            let delta = sampler.stop() - before
            print(String(format: "      GIF memory: %d frames of 1024x576, peak +%.0f MB over baseline %.0f MB", result.frameCount, delta, before))
            try check(result.frameCount >= 235, "every frame differs, got \(result.frameCount)")
            let info = try gifInfo(out)
            try checkEqual(info.frames, result.frameCount)
            try check(abs(info.totalDelay - 24) < 0.5, "total delay \(info.totalDelay)")
            try check(delta < 300, "peak footprint grew by \(delta) MB")
        },
        TestCase("GIF: a full-resolution Retina-size GIF (max width 0) keeps memory bounded") {
            try checkEqual(GIFConverter.chunkFrames(for: CGSize(width: 1280, height: 800), limit: 12), 12)
            try checkEqual(GIFConverter.chunkFrames(for: CGSize(width: 2880, height: 1800), limit: 12), 2)
            try checkEqual(GIFConverter.chunkFrames(for: CGSize(width: 5120, height: 2880), limit: 12), 1)
            let video = try makeSyntheticVideo(seconds: 4, fps: 10, size: CGSize(width: 2880, height: 1800), bands: 40)
            let out = tempURL("gif")
            defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
            let before = footprintMB()
            let sampler = PeakSampler()
            sampler.start()
            let result = try await GIFConverter.convert(videoURL: video, to: out, fps: 10, maxWidth: 0)
            let delta = sampler.stop() - before
            print(String(format: "      GIF memory: %d frames from a 2880x1800 source, peak +%.0f MB", result.frameCount, delta))
            // Capped to ~4 MP so macOS can decode it (ImageIO refuses e.g. 2880x1800 GIFs).
            let info = try gifInfo(out)
            try check(info.size.width * info.size.height <= GIFConverter.maxGIFPixels, "size \(info.size)")
            try check(info.size.width >= 2500, "should stay near full size, got \(info.size)")
            try check(delta < 300, "peak footprint grew by \(delta) MB")
        },
        TestCase("Audio mix: two audio tracks become one, video is untouched") {
            let video = try makeSyntheticVideo(seconds: 2.0, bands: 4, withAudio: true, audioTracks: 2)
            defer { try? FileManager.default.removeItem(at: video) }
            let before = AVURLAsset(url: video)
            try checkEqual(try await before.loadTracks(withMediaType: .audio).count, 2)
            let videoBefore = try await sampleTimes(video, .video)
            let sizeBefore = try await before.loadTracks(withMediaType: .video).first!.load(.naturalSize)

            try await AudioTrackMixer.mergeAudioTracks(in: video)
            let after = AVURLAsset(url: video)
            try checkEqual(try await after.loadTracks(withMediaType: .audio).count, 1)
            try checkEqual(try await after.loadTracks(withMediaType: .video).count, 1)
            let videoAfter = try await sampleTimes(video, .video)
            try checkEqual(videoAfter.count, videoBefore.count)
            let sizeAfter = try await after.loadTracks(withMediaType: .video).first!.load(.naturalSize)
            try checkEqual(sizeAfter, sizeBefore)
            let audioDuration = try await after.loadTracks(withMediaType: .audio).first!.load(.timeRange).duration.seconds
            try check(abs(audioDuration - 2.0) < 0.2, "mixed audio duration \(audioDuration)")

            let single = try makeSyntheticVideo(seconds: 1.0, withAudio: true, audioTracks: 1)
            defer { try? FileManager.default.removeItem(at: single) }
            let bytes = try Data(contentsOf: single)
            try await AudioTrackMixer.mergeAudioTracks(in: single)
            try check(try Data(contentsOf: single) == bytes, "a single audio track is left alone")
        },
        TestCase("GIF frame range: midpoint rule, at least one frame, clamping") {
            let d = [0.1, 0.2, 0.1, 0.2, 0.1]   // frames start at 0, .1, .3, .4, .6; total 0.7
            try checkEqual(RecordingMath.gifFrameRange(delays: d, start: 0.25, end: 0.65), 2..<4)  // mids .35 and .5 in; .65 is out
            try checkEqual(RecordingMath.gifFrameRange(delays: d, start: 0.1, end: 0.5), 1..<3)
            try checkEqual(RecordingMath.gifFrameRange(delays: d, start: 0, end: 0.7), 0..<5)
            try checkEqual(RecordingMath.gifFrameRange(delays: d, start: 5, end: -5), 0..<5)
            try checkEqual(RecordingMath.gifFrameRange(delays: d, start: 0.5, end: 0.1), 1..<3)
            try checkEqual(RecordingMath.gifFrameRange(delays: d, start: 0.32, end: 0.34), 2..<3)  // narrower than a frame, no midpoint inside
            try checkEqual(RecordingMath.gifFrameRange(delays: d, start: 9, end: 10), 4..<5)       // past the end keeps the last frame
            try checkEqual(RecordingMath.gifFrameRange(delays: [], start: 0, end: 1), 0..<0)
            try checkEqual(RecordingMath.gifDelays([0, 0.01, 0.02, 0.5]), [0.1, 0.1, 0.02, 0.5])
        },
        TestCase("GIFTrimmer: keeps selected frames, delays, loop count and pixels") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-gif-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("in.gif"), output = dir.appendingPathComponent("out.gif")
            let delays = (0..<10).map { $0 % 2 == 0 ? 0.1 : 0.2 }
            let colors: [UInt8] = (0..<10).map { UInt8($0 * 25) }
            func frame(_ v: UInt8) -> CGImage {
                let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(red: CGFloat(v) / 255, green: CGFloat(255 - v) / 255, blue: 0, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                return ctx.makeImage()!
            }
            let dest = CGImageDestinationCreateWithURL(input as CFURL, "com.compuserve.gif" as CFString, 10, nil)!
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for i in 0..<10 {
                CGImageDestinationAddImage(dest, frame(colors[i]), [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delays[i], kCGImagePropertyGIFUnclampedDelayTime: delays[i]]] as CFDictionary)
            }
            try check(CGImageDestinationFinalize(dest), "synthesise GIF")

            let src = try GIFTrimmer.info(url: input)
            try checkEqual(src.frameCount, 10)
            try checkEqual(src.pixelSize, CGSize(width: 8, height: 8))
            // frame midpoints .05,.2,.35,.5,.65,.8,.95,...; [0.35, 0.95) keeps frames 2...5
            let out = try GIFTrimmer.trim(url: input, start: 0.35, end: 0.95, to: output)
            try checkEqual(out.frameCount, 4)
            try checkEqual(out.loopCount, 0)
            for (a, b) in zip(out.delays, Array(delays[2...5])) { try check(abs(a - b) < 0.001, "delay \(a) vs \(b)") }

            func pixel(_ url: URL, _ i: Int) throws -> [UInt8] {
                let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
                let img = CGImageSourceCreateImageAtIndex(s, i, nil)!
                var px = [UInt8](repeating: 0, count: 4)
                let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: -3, y: -3, width: 8, height: 8))
                return px
            }
            try checkEqual(try pixel(output, 0), try pixel(input, 2))
            try checkEqual(try pixel(output, 3), try pixel(input, 5))
            try check(try pixel(output, 0) != (try pixel(input, 0)), "frame 0 of the output is the source's frame 2, not frame 0")
        },

        TestCase("TrimSelection: x/time mapping, handle clamping and minimum length") {
            var sel = TrimSelection(duration: 10, minLength: 0.5)
            try checkEqual(sel.time(atX: 50, trackWidth: 200), 2.5)
            try checkEqual(sel.x(forTime: 7.5, trackWidth: 200), 150)
            try checkEqual(sel.time(atX: -30, trackWidth: 200), 0)
            try checkEqual(sel.time(atX: 999, trackWidth: 200), 10)
            try checkEqual(sel.x(forTime: 12, trackWidth: 200), 200)
            try check(sel.isFull(tolerance: 0.05))
            sel.setStart(4); sel.setEnd(6)
            try check(!sel.isFull(tolerance: 0.05))
            sel.setStart(9)
            try checkEqual(sel.start, 5.5)
            sel.setEnd(1)
            try checkEqual(sel.end, 6.0)
            sel.setStart(-3)
            try checkEqual(sel.start, 0)
            sel.setEnd(50)
            try checkEqual(sel.end, 10)
            var tiny = TrimSelection(duration: 0.2, minLength: 0.5)
            tiny.setStart(0.15)
            try check(tiny.start <= tiny.end, "start stays before end on clips shorter than the minimum")
            try checkEqual(tiny.end, 0.2)
        },

        TestCase("TrimSelection (GIF): handles snap to frame boundaries and keep one frame") {
            let delays = [0.1, 0.2, 0.3, 0.4]
            var sel = TrimSelection(delays: delays)
            try check(abs(sel.duration - 1.0) < 1e-9)
            sel.setStart(0.28)
            try check(abs(sel.start - 0.3) < 1e-9, "start \(sel.start)")
            sel.setEnd(0.62)
            try check(abs(sel.end - 0.6) < 1e-9, "end \(sel.end)")
            try checkEqual(RecordingMath.gifFrameRange(delays: delays, start: sel.start, end: sel.end), 2..<3)
            sel.setStart(0.9)
            try check(abs(sel.start - 0.3) < 1e-9, "start cannot pass the last frame: \(sel.start)")
            sel.setEnd(0.0)
            try check(abs(sel.end - 0.6) < 1e-9, "end keeps one frame: \(sel.end)")
            try checkEqual(sel.frameIndex(at: 0.0), 0)
            try checkEqual(sel.frameIndex(at: 0.29), 1)
            try checkEqual(sel.frameIndex(at: 0.3), 2)
            try checkEqual(sel.frameIndex(at: 5), 3)
            try check(TrimSelection(duration: 1).frameIndex(at: 0.5) == nil)
        },

        TestCase("TrimSelection labels round to tenths instead of truncating float sums") {
            var sum = 0.0
            for _ in 0..<10 { sum += 0.1 }
            try check(sum < 1.0, "premise: ten 0.1 delays sum below 1.0")
            try checkEqual(TrimSelection.label(sum), "0:01.0")
            var sel = TrimSelection(delays: Array(repeating: 0.1, count: 10))
            sel.setEnd(0.8)
            try checkEqual(TrimSelection.label(sel.end), "0:00.8")
            try checkEqual(TrimSelection.label(61.26), "1:01.3")
            try checkEqual(TrimSelection.label(0), "0:00.0")
        },
    ]
}
