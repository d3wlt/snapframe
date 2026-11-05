import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

enum EngineError: Error, LocalizedError {
    case displayNotFound, startTimedOut, noFrames, ownAppNotFound, writerFailed(String)
    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The display to record is no longer available."
        case .startTimedOut: return "Screen capture did not start. Check the Screen Recording permission and try again."
        case .noFrames: return "No video frames were captured."
        case .ownAppNotFound: return "Snapframe could not hide its own windows from the recording."
        case .writerFailed(let m): return "Could not write the video: \(m)"
        }
    }
}

/// Runs a block at most once; used to race a result against a timeout.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// SCStream → RecordingWriter. Sample handling happens on `queue`; control methods hop onto it.
final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Config {
        var area: ScreenArea
        var backingScale: CGFloat
        var scaleTo1x: Bool
        var fps: Int
        var codec: VideoCodec
        var quality: VideoQuality
        var showCursor: Bool
        var systemAudio: Bool
        var microphone: Bool
        var microphoneDeviceID: String
        /// Forces a specific capture scale (GIF recordings); nil = derive from backingScale/scaleTo1x.
        var scaleOverride: CGFloat?
    }

    typealias Output = RecordingWriter.Output

    let config: Config
    let outputURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    /// Called on an arbitrary thread when the stream dies on its own (display removed, permission revoked…).
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "snapframe.recording.samples", qos: .userInteractive)
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var reportedFailure = false

    init(config: Config, outputURL: URL) {
        self.config = config
        self.outputURL = outputURL
        let scale = config.scaleOverride ?? (config.scaleTo1x ? 1 : config.backingScale)
        let size = RecordingMath.pixelSize(points: config.area.rect.size, scale: scale, scaleTo1x: false)
        pixelWidth = size.width
        pixelHeight = size.height
        super.init()
    }

    static var hostTime: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    // MARK: Start

    /// Snapframe's own windows are hidden from the video except `includedWindowIDs` (click/keystroke overlay).
    /// `requireOwnApp`: fail instead of recording if Snapframe's process is not in the shareable content,
    /// because then its HUD and dimming windows could not be excluded.
    func start(includedWindowIDs: [CGWindowID], requireOwnApp: Bool) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // New windows can take a moment to show up in the snapshot.
        var attempt = 0
        while attempt < 5, !Self.snapshot(content, hasWindows: includedWindowIDs, ownPID: pid, requireOwnApp: requireOwnApp) {
            try await Task.sleep(for: .milliseconds(100))
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            attempt += 1
        }
        guard let display = content.displays.first(where: { $0.displayID == config.area.displayID }) else {
            throw EngineError.displayNotFound
        }
        let me = content.applications.filter { $0.processID == pid }
        if me.isEmpty && requireOwnApp { throw EngineError.ownAppNotFound }
        let keep = content.windows.filter { includedWindowIDs.contains($0.windowID) }
        if keep.count < includedWindowIDs.count {
            NSLog("Snapframe: recording overlay window not found in shareable content; clicks/keystrokes may be missing")
        }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: keep)

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = config.area.rect
        cfg.width = pixelWidth
        cfg.height = pixelHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, config.fps)))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = config.showCursor
        cfg.queueDepth = 6
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.capturesAudio = config.systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        if config.microphone {
            cfg.captureMicrophone = true
            if !config.microphoneDeviceID.isEmpty { cfg.microphoneCaptureDeviceID = config.microphoneDeviceID }
        }

        let w = try RecordingWriter(config: .init(width: pixelWidth, height: pixelHeight, fps: config.fps,
                                                  codec: config.codec, quality: config.quality,
                                                  systemAudio: config.systemAudio, microphone: config.microphone),
                                    outputURL: outputURL)
        w.onFailure = { [weak self] error in self?.reportFailure(error) }
        writer = w
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if config.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if config.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            self.stream = stream
            try await Self.startCapture(stream, timeout: 10)
        } catch {
            self.stream = nil
            queue.sync { w.cancel() }
            writer = nil
            throw error
        }
    }

    private static func snapshot(_ content: SCShareableContent, hasWindows ids: [CGWindowID], ownPID: pid_t,
                                 requireOwnApp: Bool) -> Bool {
        let have = Set(content.windows.map(\.windowID))
        if !ids.allSatisfy(have.contains) { return false }
        return !requireOwnApp || content.applications.contains { $0.processID == ownPID }
    }

    /// startCapture ignores task cancellation, so race it against a timer. If it succeeds after the
    /// timeout the stream is stopped again immediately.
    private static func startCapture(_ stream: SCStream, timeout: Double) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            Task {
                do {
                    try await stream.startCapture()
                    if once.claim() { cont.resume() } else { try? await stream.stopCapture() }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if once.claim() { cont.resume(throwing: EngineError.startTimedOut) }
            }
        }
    }

    // MARK: Pause / resume

    func pause() {
        let now = Self.hostTime
        queue.async { self.writer?.pause(at: now) }
    }

    func resume() {
        let now = Self.hostTime
        queue.async { self.writer?.resume(at: now) }
    }

    // MARK: Stop

    /// Finishes the file. Throws (and removes the file) if nothing usable was written.
    func stop() async throws -> Output {
        let end = Self.hostTime
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let writer = self.writer else {
                    cont.resume(throwing: EngineError.noFrames)
                    return
                }
                writer.finish(endingAt: end) { cont.resume(with: $0) }
            }
        }
    }

    /// Stops everything and deletes the file.
    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync { writer?.cancel() }
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer else { return }
        switch type {
        case .screen: writer.appendVideo(sampleBuffer)
        case .audio: writer.appendAudio(sampleBuffer, kind: .system)
        case .microphone: writer.appendAudio(sampleBuffer, kind: .microphone)
        @unknown default: break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !(self.writer?.isFinished ?? true) else { return }
            self.reportFailure(error)
        }
    }

    private func reportFailure(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        onUnexpectedStop?(error)
    }
}
