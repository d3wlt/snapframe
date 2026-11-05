import AppKit

/// Trim range with its geometry rules: time/x mapping, handle clamping, minimum length and, for GIFs,
/// snapping to frame boundaries. Pure value type; `TrimTimeline` draws and edits it.
public struct TrimSelection: Equatable, Sendable {
    public let duration: Double
    public let minLength: Double
    /// Cumulative frame start times plus the total duration (`frames + 1` entries); empty for continuous media.
    public let boundaries: [Double]
    public private(set) var start: Double
    public private(set) var end: Double

    public init(duration: Double, minLength: Double = 0.1) {
        self.duration = max(0, duration)
        self.minLength = max(0, minLength)
        self.boundaries = []
        start = 0
        end = self.duration
    }

    /// Selection whose handles always sit on frame boundaries and enclose at least one frame.
    public init(delays: [Double]) {
        var b = [0.0]
        for d in delays { b.append(b[b.count - 1] + d) }
        boundaries = delays.isEmpty ? [] : b
        duration = b[b.count - 1]
        minLength = 0
        start = 0
        end = duration
    }

    public var length: Double { end - start }

    /// "0:01.0": time rounded to the nearest tenth, so summed float delays do not truncate (0.1 x 10 -> 1.0).
    public static func label(_ t: Double) -> String {
        let tenths = Int((max(0, t) * 10).rounded())
        return "\(RecordingMath.formatElapsed(Double(tenths / 10))).\(tenths % 10)"
    }

    public func isFull(tolerance: Double) -> Bool { start <= tolerance && end >= duration - tolerance }

    private func snap(_ t: Double) -> Double {
        let c = min(max(t, 0), duration)
        return boundaries.min { abs($0 - c) < abs($1 - c) } ?? c
    }

    public mutating func setStart(_ t: Double) {
        if boundaries.isEmpty {
            start = min(max(t, 0), max(0, end - min(minLength, duration)))
        } else {
            let limit = boundaries.last { $0 < end - 1e-9 } ?? 0
            start = min(snap(t), limit)
        }
    }

    public mutating func setEnd(_ t: Double) {
        if boundaries.isEmpty {
            end = max(min(t, duration), min(start + min(minLength, duration), duration))
        } else {
            let limit = boundaries.first { $0 > start + 1e-9 } ?? duration
            end = max(snap(t), limit)
        }
    }

    /// Index of the frame shown at `t` (GIF); nil for continuous media.
    public func frameIndex(at t: Double) -> Int? {
        guard boundaries.count > 1 else { return nil }
        let i = boundaries.lastIndex { $0 <= t + 1e-9 } ?? 0
        return min(i, boundaries.count - 2)
    }

    public func time(atX x: Double, trackWidth: Double) -> Double {
        guard trackWidth > 0 else { return 0 }
        return min(max(x / trackWidth, 0), 1) * duration
    }

    public func x(forTime t: Double, trackWidth: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(t / duration, 0), 1) * trackWidth
    }
}

/// Always-visible trim bar: thumbnail strip, start/end handles, playhead and start/end/length labels.
@MainActor
final class TrimTimeline: NSView {
    private enum Drag { case start(offset: Double), end(offset: Double), playhead }

    private(set) var selection = TrimSelection(duration: 0)
    private(set) var playhead: Double = 0
    private var thumbnails: [CGImage] = []
    var hasThumbnails: Bool { !thumbnails.isEmpty }
    private var drag: Drag?

    var onSelectionChanged: ((TrimSelection) -> Void)?
    /// Time the user dragged a handle or the playhead to.
    var onScrub: ((Double) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var onTogglePlay: (() -> Void)?

    private let handleWidth: CGFloat = 12
    private let barHeight: CGFloat = 48
    private let labelHeight: CGFloat = 20
    private let accent = NSColor.systemYellow

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: labelHeight + barHeight + 4) }

    func configure(_ selection: TrimSelection) {
        self.selection = selection
        playhead = 0
        needsDisplay = true
    }

    /// Sets the selection handles directly (README renderer), snapping like a drag would.
    func setTrim(start: Double, end: Double) {
        selection.setStart(start)
        selection.setEnd(end)
        onSelectionChanged?(selection)
        needsDisplay = true
    }

    func setThumbnails(_ images: [CGImage]) {
        thumbnails = images
        needsDisplay = true
    }

    func setPlayhead(_ t: Double) {
        playhead = min(max(t, 0), selection.duration)
        needsDisplay = true
    }

    private var trackRect: NSRect {
        NSRect(x: handleWidth, y: labelHeight, width: max(1, bounds.width - 2 * handleWidth), height: barHeight)
    }

    private func xPos(_ t: Double) -> CGFloat { trackRect.minX + CGFloat(selection.x(forTime: t, trackWidth: trackRect.width)) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard selection.duration > 0 else { return }
        let track = trackRect
        let sx = xPos(selection.start), ex = xPos(selection.end)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).addClip()
        NSColor.black.withAlphaComponent(0.25).setFill()
        track.fill()
        if !thumbnails.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            let w = track.width / CGFloat(thumbnails.count)
            for (i, image) in thumbnails.enumerated() {
                let cell = CGRect(x: track.minX + CGFloat(i) * w, y: track.minY, width: w + 0.5, height: track.height)
                let scale = max(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
                let src = CGRect(x: (CGFloat(image.width) - cell.width / scale) / 2, y: (CGFloat(image.height) - cell.height / scale) / 2,
                                 width: cell.width / scale, height: cell.height / scale)
                guard let part = image.cropping(to: src) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: 0, y: cell.minY + cell.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(part, in: cell)
                ctx.restoreGState()
            }
        }
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSRect(x: track.minX, y: track.minY, width: max(0, sx - track.minX), height: track.height).fill()
        NSRect(x: ex, y: track.minY, width: max(0, track.maxX - ex), height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        accent.setFill()
        NSRect(x: sx, y: track.minY - 2, width: max(0, ex - sx), height: 2).fill()
        NSRect(x: sx, y: track.maxY, width: max(0, ex - sx), height: 2).fill()
        drawHandle(NSRect(x: sx - handleWidth, y: track.minY - 2, width: handleWidth, height: track.height + 4))
        drawHandle(NSRect(x: ex, y: track.minY - 2, width: handleWidth, height: track.height + 4))

        let px = xPos(playhead)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: px - 1, y: track.minY - 4, width: 2, height: track.height + 8), xRadius: 1, yRadius: 1).fill()

        drawLabels()
    }

    private func drawHandle(_ rect: NSRect) {
        let radius: CGFloat = 4
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        accent.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 1, y: rect.midY - 7, width: 2, height: 14), xRadius: 1, yRadius: 1).fill()
    }

    private func drawLabels() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let left = NSAttributedString(string: TrimSelection.label(selection.start), attributes: attrs)
        let right = NSAttributedString(string: TrimSelection.label(selection.end), attributes: attrs)
        let mid = NSAttributedString(string: "Selected \(TrimSelection.label(selection.length))", attributes: attrs)
        let y: CGFloat = 2
        left.draw(at: NSPoint(x: handleWidth, y: y))
        right.draw(at: NSPoint(x: bounds.width - handleWidth - right.size().width, y: y))
        mid.draw(at: NSPoint(x: (bounds.width - mid.size().width) / 2, y: y))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard selection.duration > 0 else { return }
        window?.makeFirstResponder(self)
        let x = convert(event.locationInWindow, from: nil).x
        let sx = xPos(selection.start), ex = xPos(selection.end)
        let hitStart = x >= sx - handleWidth - 4 && x <= sx + 2
        let hitEnd = x >= ex - 2 && x <= ex + handleWidth + 4
        if hitStart && (!hitEnd || x < (sx + ex) / 2) {
            drag = .start(offset: Double(x - sx))
        } else if hitEnd {
            drag = .end(offset: Double(x - ex))
        } else {
            drag = .playhead
        }
        onInteraction?(true)
        update(toX: x)
    }

    override func mouseDragged(with event: NSEvent) {
        update(toX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        onInteraction?(false)
    }

    private func update(toX x: CGFloat) {
        guard let drag else { return }
        let width = Double(trackRect.width), local = Double(x - trackRect.minX)
        switch drag {
        case .playhead:
            setPlayhead(selection.time(atX: local, trackWidth: width))
        case .start(let offset):
            selection.setStart(selection.time(atX: local - offset, trackWidth: width))
            setPlayhead(selection.start)
            onSelectionChanged?(selection)
        case .end(let offset):
            selection.setEnd(selection.time(atX: local - offset, trackWidth: width))
            setPlayhead(selection.end)
            onSelectionChanged?(selection)
        }
        onScrub?(playhead)
    }

    // MARK: Keyboard

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": if !event.isARepeat { onTogglePlay?() }
        case "i": selection.setStart(playhead); needsDisplay = true; onSelectionChanged?(selection)
        case "o": selection.setEnd(playhead); needsDisplay = true; onSelectionChanged?(selection)
        default: return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }
}
