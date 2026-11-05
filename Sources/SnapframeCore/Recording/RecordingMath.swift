import AppKit
import CoreMedia

// Pure helpers behind the recorder: pixel sizing, bitrate, pause timeline, elapsed clock,
// geometry and keystroke formatting. Kept free of UI/ScreenCaptureKit so they can be tested.

public enum RecordingMath {
    /// Rounds to the nearest even integer, minimum 2 (H.264/HEVC need even dimensions).
    public static func even(_ value: CGFloat) -> Int {
        let r = Int(value.rounded())
        let e = r % 2 == 0 ? r : r + 1
        return max(2, e)
    }

    /// Output pixel size for a region in points. `scale` is the display's backing scale (2 on Retina);
    /// with `scaleTo1x` the video is written at point size.
    public static func pixelSize(points: CGSize, scale: CGFloat, scaleTo1x: Bool) -> (width: Int, height: Int) {
        let s = scaleTo1x ? 1 : max(1, scale)
        return (even(points.width * s), even(points.height * s))
    }

    /// Scale used for GIF recordings: native, but not much wider than the GIF's maximum width (0 = no limit).
    public static func gifCaptureScale(pointWidth: CGFloat, nativeScale: CGFloat, maxWidth: Int) -> CGFloat {
        guard pointWidth > 0 else { return 1 }
        if maxWidth <= 0 { return max(1, nativeScale) } // 0 = original size
        return min(max(1, nativeScale), max(1, CGFloat(maxWidth) / pointWidth))
    }

    /// Average video bitrate in bits per second from resolution, frame rate, codec and quality.
    public static func bitrate(width: Int, height: Int, fps: Int, codec: VideoCodec, quality: VideoQuality) -> Int {
        let bitsPerPixel: Double
        switch quality {
        case .low: bitsPerPixel = 0.04
        case .medium: bitsPerPixel = 0.075
        case .high: bitsPerPixel = 0.13
        }
        let codecFactor = codec == .hevc ? 0.6 : 1.0
        let raw = Double(width) * Double(height) * Double(max(1, fps)) * bitsPerPixel * codecFactor
        return Int(min(max(raw, 1_000_000), 100_000_000))
    }

    /// "0:07", "12:03", "1:02:03"
    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "displayID x y w h" (display points), the same layout as PrefKey.lastArea.
    public static func encode(_ area: ScreenArea) -> String {
        let r = area.rect
        return "\(area.displayID) \(r.minX) \(r.minY) \(r.width) \(r.height)"
    }

    public static func decodeArea(_ string: String) -> ScreenArea? {
        let p = string.split(separator: " ")
        guard p.count == 5, let id = UInt32(p[0]),
              let x = Double(p[1]), let y = Double(p[2]), let w = Double(p[3]), let h = Double(p[4]),
              w > 0, h > 0 else { return nil }
        return ScreenArea(displayID: id, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Converts a display-relative top-left rect into Cocoa global coordinates.
    public static func cocoaRect(_ rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Browser-style GIF delays: a missing, zero or sub-0.02 s delay plays as 0.1 s.
    public static func gifDelays(_ raw: [Double]) -> [Double] {
        raw.map { $0 >= 0.02 ? $0 : 0.1 }
    }

    /// Frames to keep when trimming a GIF to [start, end) seconds: those whose midpoint lies in the range.
    /// A non-empty GIF always keeps at least the frame containing `start`; empty input gives 0..<0.
    public static func gifFrameRange(delays: [Double], start: Double, end: Double) -> Range<Int> {
        guard !delays.isEmpty else { return 0..<0 }
        let total = delays.reduce(0, +)
        let a = min(max(min(start, end), 0), total), b = min(max(max(start, end), 0), total)
        var t = 0.0
        var first: Int?, last = 0, containing = delays.count - 1, found = false
        for (i, d) in delays.enumerated() {
            let mid = t + d / 2
            if mid >= a, mid < b { if first == nil { first = i }; last = i }
            if !found, a < t + d { containing = i; found = true }
            t += d
        }
        if let first { return first..<(last + 1) }
        return containing..<(containing + 1)
    }

    /// Clamps the rect to the display bounds and snaps it to whole points.
    public static func normalized(_ rect: CGRect, displaySize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: displaySize)
        let r = rect.standardized.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return bounds }
        return CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                      width: max(1, r.width.rounded()), height: max(1, r.height.rounded())).intersection(bounds)
    }

    /// Frame for a floating HUD next to the recording rect (Cocoa coordinates): below it if there is
    /// room, else above, else inside near the bottom, raised by `insideInset` so reaching for it does not hit
    /// the bottom edge and reveal an auto-hidden Dock into the recording. Always clamped to `visible`.
    public static func hudFrame(size: CGSize, around area: CGRect, in visible: CGRect, gap: CGFloat = 12,
                                insideInset: CGFloat = 96) -> CGRect {
        var x = area.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let below = area.minY - gap - size.height
        let above = area.maxY + gap
        let y: CGFloat
        if below >= visible.minY + 4 {
            y = below
        } else if above + size.height <= visible.maxY - 4 {
            y = above
        } else {
            y = min(max(visible.minY, area.minY) + insideInset, visible.maxY - size.height - 4)
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Maps source timestamps (host clock, as delivered by ScreenCaptureKit) to gap-free output timestamps,
/// dropping everything captured while paused and anything before the first video frame.
public struct PauseTimeline {
    private var origin: CMTime?
    private var closedPauses: [(start: CMTime, end: CMTime)] = []
    private var pauseStart: CMTime?

    public init() {}

    public var isPaused: Bool { pauseStart != nil }
    public var hasOrigin: Bool { origin != nil }

    /// Fixes time zero at the first video frame. Pauses that ended before it no longer matter.
    public mutating func setOrigin(_ t: CMTime) {
        guard origin == nil else { return }
        origin = t
        closedPauses.removeAll { CMTimeCompare($0.start, t) < 0 }
    }

    public mutating func pause(at t: CMTime) { if pauseStart == nil { pauseStart = t } }

    public mutating func resume(at t: CMTime) {
        guard let start = pauseStart else { return }
        if CMTimeCompare(t, start) > 0 { closedPauses.append((start, t)) }
        pauseStart = nil
    }

    /// Output timestamp for a source sample, or nil if it must be dropped. A sample with a duration is
    /// dropped as a whole when it overlaps a pause boundary, so audio never overlaps after a resume.
    public func output(for t: CMTime, duration: CMTime = .zero) -> CMTime? {
        guard let origin, CMTimeCompare(t, origin) >= 0 else { return nil }
        let end = CMTimeAdd(t, duration.isNumeric ? duration : .zero)
        if let ps = pauseStart, CMTimeCompare(end, ps) > 0 || CMTimeCompare(t, ps) >= 0 { return nil }
        var removed = CMTime.zero
        for p in closedPauses {
            if CMTimeCompare(t, p.end) < 0 && (CMTimeCompare(end, p.start) > 0 || CMTimeCompare(t, p.start) >= 0) { return nil }
            if CMTimeCompare(t, p.end) >= 0 { removed = CMTimeAdd(removed, CMTimeSubtract(p.end, p.start)) }
        }
        return CMTimeSubtract(CMTimeSubtract(t, origin), removed)
    }

    /// Output time of the end of the recording when it stops at source time `t`
    /// (a pause in effect at that moment ends the recording at the pause start).
    public func outputEnd(at t: CMTime) -> CMTime? {
        guard let origin else { return nil }
        var tt = t
        if let ps = pauseStart, CMTimeCompare(tt, ps) > 0 { tt = ps }
        var removed = CMTime.zero
        for p in closedPauses {
            if CMTimeCompare(tt, p.end) >= 0 {
                removed = CMTimeAdd(removed, CMTimeSubtract(p.end, p.start))
            } else if CMTimeCompare(tt, p.start) > 0 {
                tt = p.start
            }
        }
        let out = CMTimeSubtract(CMTimeSubtract(tt, origin), removed)
        return CMTimeCompare(out, .zero) < 0 ? .zero : out
    }
}

/// Elapsed recording time that excludes paused spans.
public struct ElapsedClock {
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    public init() {}

    public var isPaused: Bool { startedAt != nil && runningSince == nil }

    public mutating func start(at now: Date) { startedAt = now; accumulated = 0; runningSince = now }

    public mutating func pause(at now: Date) {
        guard let since = runningSince else { return }
        accumulated += now.timeIntervalSince(since)
        runningSince = nil
    }

    public mutating func resume(at now: Date) {
        guard startedAt != nil, runningSince == nil else { return }
        runningSince = now
    }

    public func elapsed(at now: Date) -> TimeInterval {
        accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }
}

/// Text for the keystroke overlay.
public enum KeystrokeFormatter {
    /// Combos with ⌘/⌃/⌥ render as "⌘⇧4"; plain keys as their character or name.
    public static func label(keyCode: UInt32, characters: String?, flags: NSEvent.ModifierFlags) -> (text: String, isCombo: Bool) {
        let combo = !flags.intersection([.command, .control, .option]).isEmpty
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        let named = Shortcut.namedKeys[Int(keyCode)]
        if combo {
            return (prefix + (named ?? Shortcut.keyName(keyCode)), true)
        }
        if let named { return (prefix + named, false) }
        if let c = characters, !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return (c, false)
        }
        return (prefix + Shortcut.keyName(keyCode), false)
    }
}

/// Accumulates typed characters into a short string and shows combos on their own.
public struct KeystrokeBuffer {
    public private(set) var text = ""
    private var lastAt: TimeInterval = -.infinity
    private var lastWasTyping = false
    public let joinWindow: TimeInterval
    public let maxLength: Int

    public init(joinWindow: TimeInterval = 1.2, maxLength: Int = 24) {
        self.joinWindow = joinWindow
        self.maxLength = maxLength
    }

    /// Returns the string to display after this key press.
    public mutating func add(_ label: (text: String, isCombo: Bool), at time: TimeInterval) -> String {
        let typing = !label.isCombo && label.text.count == 1
        if typing, lastWasTyping, time - lastAt <= joinWindow {
            text += label.text
            if text.count > maxLength { text = String(text.suffix(maxLength)) }
        } else {
            text = label.text
        }
        lastWasTyping = typing
        lastAt = time
        return text
    }
}
