import AVFoundation
import AVKit
import AppKit
import ImageIO

/// What the editor needs from a previewable medium; the timeline drives it.
@MainActor
protocol EditorMedia: AnyObject {
    var view: NSView { get }
    var onTick: ((Double) -> Void)? { get set }
    var isPlaying: Bool { get }
    var hasAudio: Bool { get }
    var muted: Bool { get set }
    /// Playback loops inside this range.
    var loop: ClosedRange<Double> { get set }
    func load() async throws -> TrimSelection
    func thumbnails(count: Int) async -> [CGImage]
    func seek(to t: Double)
    func play()
    func pause()
    func teardown()
}

private final class NoFocusPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class VideoMedia: EditorMedia {
    private let asset: AVURLAsset
    private let player: AVPlayer
    private let playerView = NoFocusPlayerView()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var duration: Double = 0
    var onTick: ((Double) -> Void)?
    var hasAudio = false
    var loop: ClosedRange<Double> = 0...0

    var view: NSView { playerView }
    var isPlaying: Bool { player.rate != 0 }
    var muted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    init(url: URL) {
        asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                let t = time.seconds
                if t >= self.loop.upperBound - 0.01 { self.restart() } else { self.onTick?(t) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private func restart() {
        seek(to: loop.lowerBound)
        onTick?(loop.lowerBound)
        player.play()
    }

    func load() async throws -> TrimSelection {
        duration = try await asset.load(.duration).seconds
        hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        loop = 0...duration
        return TrimSelection(duration: duration)
    }

    func thumbnails(count: Int) async -> [CGImage] {
        guard duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if case .success(_, let image, _) = result { images.append(image) }
        }
        return images
    }

    func seek(to t: Double) {
        let time = CMTime(seconds: min(max(t, 0), duration), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func teardown() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playerView.player = nil
    }
}

/// Plays a GIF frame by frame from ImageIO, honouring per-frame delays; at most `cacheLimit` decoded frames are kept.
@MainActor
final class GIFMedia: EditorMedia {
    private let url: URL
    private let source: CGImageSource?
    private let imageView = NSImageView()
    private var selection = TrimSelection(duration: 0)
    private var delays: [Double] = []
    private var cache: [(index: Int, image: NSImage)] = []
    private let cacheLimit = 6
    private var timer: Timer?
    private var current = 0
    var onTick: ((Double) -> Void)?
    let hasAudio = false
    var muted = false
    var loop: ClosedRange<Double> = 0...0

    var view: NSView { imageView }
    var isPlaying: Bool { timer != nil }

    init(url: URL) {
        self.url = url
        source = CGImageSourceCreateWithURL(url as CFURL, nil)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
    }

    func load() async throws -> TrimSelection {
        let info = try GIFTrimmer.info(url: url)
        delays = info.delays
        selection = TrimSelection(delays: delays)
        loop = 0...selection.duration
        show(0)
        return selection
    }

    func thumbnails(count: Int) async -> [CGImage] {
        let url = url, selection = selection
        return await Task.detached {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [CGImage]() }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 240]
            return (0..<count).compactMap { i in
                let t = selection.duration * (Double(i) + 0.5) / Double(count)
                return CGImageSourceCreateThumbnailAtIndex(src, selection.frameIndex(at: t) ?? 0, options as CFDictionary)
            }
        }.value
    }

    private func frame(_ index: Int) -> NSImage? {
        if let hit = cache.firstIndex(where: { $0.index == index }) { return cache[hit].image }
        guard let source, let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.append((index, image))
        if cache.count > cacheLimit { cache.removeFirst() }
        return image
    }

    private func show(_ index: Int) {
        current = index
        if let image = frame(index) { imageView.image = image }
    }

    func seek(to t: Double) {
        show(selection.frameIndex(at: t) ?? 0)
    }

    func play() {
        guard timer == nil, !delays.isEmpty else { return }
        scheduleNext()
    }

    private func scheduleNext() {
        timer = Timer.scheduledTimer(withTimeInterval: delays[current], repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func advance() {
        var next = current + 1
        if next >= delays.count || selection.boundaries[next] >= loop.upperBound - 1e-9 {
            next = selection.frameIndex(at: loop.lowerBound) ?? 0
        }
        show(next)
        onTick?(selection.boundaries[next])
        scheduleNext()
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func teardown() {
        pause()
        cache.removeAll()
        imageView.image = nil
    }
}
