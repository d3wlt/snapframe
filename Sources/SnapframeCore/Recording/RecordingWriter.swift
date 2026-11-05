import AVFoundation
import CoreMedia
import ScreenCaptureKit

// AVAssetWriter's status and error are safe to read from the finishWriting handler, its documented completion path.
private struct WriterBox: @unchecked Sendable { let writer: AVAssetWriter }

/// The writing half of the recorder: turns captured sample buffers into an MP4 with pause/resume support.
/// It knows nothing about ScreenCaptureKit streams, so it can be driven with synthetic buffers in tests.
/// Not thread-safe: the owner must call everything from one serial context.
final class RecordingWriter {
    struct Config {
        var width: Int
        var height: Int
        var fps: Int
        var codec: VideoCodec
        var quality: VideoQuality
        var systemAudio: Bool
        var microphone: Bool
    }

    enum AudioKind { case system, microphone }

    struct Output {
        var url: URL
        var pixelSize: CGSize
        var duration: TimeInterval
    }

    let outputURL: URL
    private let config: Config
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var timeline = PauseTimeline()
    private var sessionStarted = false
    private var lastVideoOut: CMTime = .zero
    private(set) var isFinished = false
    private(set) var failure: Error?
    /// Called once if the underlying AVAssetWriter fails while recording.
    var onFailure: ((Error) -> Void)?

    init(config: Config, outputURL: URL) throws {
        self.config = config
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)
        let w = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = RecordingMath.bitrate(width: config.width, height: config.height, fps: config.fps,
                                            codec: config.codec, quality: config.quality)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: config.fps,
            AVVideoMaxKeyFrameIntervalKey: max(1, config.fps) * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if config.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: config.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { throw EngineError.writerFailed("video settings rejected") }
        w.add(v)
        videoInput = v
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: nil)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        func audioInput() -> AVAssetWriterInput? {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(a) else { return nil }
            w.add(a)
            return a
        }
        if config.systemAudio { systemInput = audioInput() }
        if config.microphone { micInput = audioInput() }
        guard w.startWriting() else {
            throw EngineError.writerFailed(w.error?.localizedDescription ?? "cannot start writing")
        }
        writer = w
    }

    // MARK: Pause / resume

    func pause(at hostTime: CMTime) { timeline.pause(at: hostTime) }
    func resume(at hostTime: CMTime) { timeline.resume(at: hostTime) }

    // MARK: Samples

    /// True for frames that carry pixels; idle/blank/suspended status notifications do not.
    static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete && CMSampleBufferGetImageBuffer(sample) != nil
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        guard writable(), sample.isValid, Self.isCompleteFrame(sample),
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !timeline.hasOrigin && !timeline.isPaused { timeline.setOrigin(pts) }
        guard let out = timeline.output(for: pts) else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData, CMTimeCompare(out, lastVideoOut) >= 0 else { return }
        if adaptor.append(pixels, withPresentationTime: out) {
            lastVideoOut = out
        } else {
            checkWriterStatus()
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, kind: AudioKind) {
        guard writable(), sample.isValid, sessionStarted,
              let input = kind == .system ? systemInput : micInput, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        guard let out = timeline.output(for: pts, duration: duration) else { return }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: out, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                    sampleBufferOut: &retimed) == noErr, let retimed else { return }
        if !input.append(retimed) { checkWriterStatus() }
    }

    private func writable() -> Bool {
        if isFinished { return false }
        if writer.status == .writing { return true }
        checkWriterStatus()
        return false
    }

    private func checkWriterStatus() {
        guard writer.status == .failed, failure == nil else { return }
        let error = EngineError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        failure = error
        onFailure?(error)
    }

    // MARK: Finish

    /// Finalises the file. The recording ends at source time `hostTime`; a static screen delivers no
    /// frames, so the last frame is held until then. Fails (and deletes the file) if nothing usable was written.
    func finish(endingAt hostTime: CMTime, completion: @escaping @Sendable (Result<Output, Error>) -> Void) {
        guard !isFinished else {
            completion(.failure(failure ?? EngineError.writerFailed("already finished")))
            return
        }
        isFinished = true
        guard writer.status == .writing else {
            discard()
            completion(.failure(failure ?? EngineError.writerFailed(writer.error?.localizedDescription ?? "the writer stopped")))
            return
        }
        guard sessionStarted else {
            discard()
            completion(.failure(failure ?? EngineError.noFrames))
            return
        }
        let rawEnd = timeline.outputEnd(at: hostTime) ?? lastVideoOut
        let endTime = CMTimeCompare(rawEnd, lastVideoOut) < 0 ? lastVideoOut : rawEnd
        writer.endSession(atSourceTime: endTime)
        videoInput.markAsFinished()
        systemInput?.markAsFinished()
        micInput?.markAsFinished()
        let url = outputURL
        let size = CGSize(width: config.width, height: config.height)
        let box = WriterBox(writer: writer)
        writer.finishWriting {
            let writer = box.writer
            if writer.status == .completed {
                completion(.success(Output(url: url, pixelSize: size, duration: endTime.seconds)))
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(EngineError.writerFailed(writer.error?.localizedDescription ?? "unknown")))
            }
        }
    }

    func finish(endingAt hostTime: CMTime) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            finish(endingAt: hostTime) { cont.resume(with: $0) }
        }
    }

    /// Stops writing and deletes the file.
    func cancel() {
        isFinished = true
        discard()
    }

    private func discard() {
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
