import AppKit

/// Result of an interactive selection. `frozen` holds the pre-captured display frames when
/// "Freeze screen" is on, so the capture can be cropped from exactly what the user saw.
struct AreaSelection {
    var area: ScreenArea
    var frozen: [CGDirectDisplayID: CGImage]
}

@MainActor
public enum AreaSelector {
    public enum Purpose { case screenshot, recording, text }

    /// Shows the crosshair selection overlay on all displays. Returns nil if cancelled (Esc).
    public static func select(purpose: Purpose, initial: ScreenArea? = nil) async -> ScreenArea? {
        await selectWithFrames(purpose: purpose, initial: initial)?.area
    }

    static func selectWithFrames(purpose: Purpose, initial: ScreenArea? = nil) async -> AreaSelection? {
        let freeze = purpose != .recording && Prefs.bool(PrefKey.shotFreezeScreen)
        let loupe = Prefs.bool(PrefKey.shotShowMagnifier)
        let frames = (freeze || loupe) ? await ScreenGrabber.grabAllDisplays() : [:]
        let overlay = SelectionOverlay(initial: initial, frames: frames, frozen: freeze && !frames.isEmpty)
        guard let area = await overlay.run() else { return nil }
        return AreaSelection(area: area, frozen: overlay.frozen ? frames : [:])
    }
}

@MainActor
final class SelectionOverlay {
    let frames: [CGDirectDisplayID: CGImage]
    let frozen: Bool
    let crosshair = Prefs.enumValue(PrefKey.shotCrosshairMode, CrosshairMode.disabled)
    let showLoupe = Prefs.bool(PrefKey.shotShowMagnifier)
    let displays = DisplayInfo.current
    private(set) var selection: CGRect?
    private(set) var cursor = NSEvent.mouseLocation
    private(set) var isDragging = false
    private(set) var hasInitial = false

    private var initialArea: ScreenArea?
    private var tracker: SelectionTracker?
    private var spaceHeld = false
    private var panels: [OverlayPanel] = []
    private var monitor: Any?
    private let focus = FocusKeeper()
    private var continuation: CheckedContinuation<ScreenArea?, Never>?

    init(initial: ScreenArea?, frames: [CGDirectDisplayID: CGImage], frozen: Bool) {
        self.frames = frames
        self.frozen = frozen
        initialArea = initial
    }

    func run() async -> ScreenArea? {
        await withCheckedContinuation { cont in
            continuation = cont
            present()
        }
    }

    // MARK: Presentation

    private func present() {
        if let a = initialArea, let d = displays.first(where: { $0.id == a.displayID }) {
            let r = CaptureGeometry.globalRect(fromLocal: a.rect, displayFrame: d.frame).intersection(d.frame)
            if !r.isNull, r.width > 0, r.height > 0 {
                selection = r
                hasInitial = true
            }
        }
        focus.activate()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let view = SelectionView(overlay: self, display: DisplayInfo(id: id, frame: screen.frame))
            let panel = OverlayPanel.make(for: screen, view: view)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        let under = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(under) } ?? panels.first)?.makeKey()
        monitor = localMonitor([.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        NSCursor.crosshair.set()
        redraw()
        if panels.isEmpty { finish(nil) }
    }

    private func redraw() {
        for p in panels { p.contentView?.needsDisplay = true }
        for p in panels { p.invalidateCursorRects(for: p.contentView!) }
    }

    // MARK: Events

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard continuation != nil else { return event }
        let p = NSEvent.mouseLocation
        cursor = p
        NSCursor.crosshair.set()
        switch event.type {
        case .mouseMoved:
            break
        case .leftMouseDown:
            guard let d = CaptureGeometry.display(containing: p, in: displays) else { break }
            tracker = SelectionTracker(start: p, bounds: d.frame)
            selection = nil
            isDragging = true
        case .leftMouseDragged:
            guard tracker != nil else { break }
            tracker!.drag(to: p, space: spaceHeld, square: event.modifierFlags.contains(.shift))
            selection = tracker!.rect
        case .leftMouseUp:
            guard let t = tracker else { break }
            tracker = nil
            isDragging = false
            if t.isClick {
                if let d = CaptureGeometry.display(containing: p, in: displays) {
                    finish(ScreenArea(displayID: d.id, rect: CGRect(origin: .zero, size: d.frame.size)))
                } else { finish(nil) }
            } else {
                finish(CaptureGeometry.area(forGlobalRect: t.rect, anchor: CGPoint(x: t.rect.midX, y: t.rect.midY),
                                            displays: displays))
            }
        case .keyDown:
            switch event.keyCode {
            case 53: finish(nil)
            case 36, 76:
                if let sel = selection, sel.width > 0, sel.height > 0, !isDragging {
                    finish(CaptureGeometry.area(forGlobalRect: sel, anchor: CGPoint(x: sel.midX, y: sel.midY), displays: displays))
                }
            case 49: spaceHeld = true
            default: break
            }
            redraw()
            return nil
        case .keyUp:
            if event.keyCode == 49 { spaceHeld = false }
            redraw()
            return nil
        default:
            break
        }
        redraw()
        return nil
    }

    private func finish(_ area: ScreenArea?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        for p in panels { p.orderOut(nil); p.close() }
        panels = []
        NSCursor.arrow.set()
        focus.restore()
        cont.resume(returning: area)
    }
}

// MARK: - View

@MainActor
final class SelectionView: NSView {
    private unowned let overlay: SelectionOverlay
    private let display: DisplayInfo

    init(overlay: SelectionOverlay, display: DisplayInfo) {
        self.overlay = overlay
        self.display = display
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - display.frame.minX, y: p.y - display.frame.minY) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hair = OverlayDraw.hairline(self)
        if overlay.frozen, let img = overlay.frames[display.id] {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: bounds)
        }

        // Dim everything outside the selection.
        let sel = overlay.selection.map { local($0).intersection(bounds) }.flatMap { $0.isNull ? nil : $0 }
        ctx.saveGState()
        if let sel, sel.width > 0, sel.height > 0 {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.42))
            ctx.addRect(bounds)
            ctx.addRect(sel)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.18))
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        let cursor = local(overlay.cursor)
        let cursorHere = bounds.contains(cursor)

        // Crosshair guides (inverted against whatever is underneath, so visible on light and dark).
        let showGuides = overlay.crosshair == .always
            || (overlay.crosshair == .whileHoldingCommand && NSEvent.modifierFlags.contains(.command))
        if showGuides, cursorHere {
            ctx.saveGState()
            ctx.setBlendMode(.difference)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7))
            ctx.setLineWidth(hair)
            ctx.move(to: CGPoint(x: bounds.minX, y: cursor.y.rounded() + 0.5 * hair))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: cursor.y.rounded() + 0.5 * hair))
            ctx.move(to: CGPoint(x: cursor.x.rounded() + 0.5 * hair, y: bounds.minY))
            ctx.addLine(to: CGPoint(x: cursor.x.rounded() + 0.5 * hair, y: bounds.maxY))
            ctx.strokePath()
            ctx.restoreGState()
        }

        if let sel, sel.width > 0, sel.height > 0 {
            ctx.saveGState()
            ctx.setLineWidth(hair)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
            ctx.stroke(sel.insetBy(dx: -hair, dy: -hair))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.stroke(sel.insetBy(dx: hair / 2, dy: hair / 2))
            ctx.restoreGState()
            if let full = overlay.selection {
                let label = "\(Int(full.width.rounded())) × \(Int(full.height.rounded()))"
                var origin = CGPoint(x: sel.minX, y: sel.minY - 30)
                if origin.y < 6 { origin.y = sel.minY + 8 }
                OverlayDraw.pill(label, origin: origin, in: bounds)
            }
            if overlay.hasInitial, !overlay.isDragging {
                OverlayDraw.pill("Return to confirm  ·  Esc to cancel",
                                 origin: CGPoint(x: bounds.midX, y: bounds.maxY - 70),
                                 font: .systemFont(ofSize: 12, weight: .medium), centered: true, in: bounds)
            }
        }

        if overlay.showLoupe, cursorHere, let img = overlay.frames[display.id] {
            drawLoupe(ctx, image: img, cursor: cursor)
        }
    }

    private func drawLoupe(_ ctx: CGContext, image: CGImage, cursor: CGPoint) {
        let cells = 15, zoom: CGFloat = 8
        let d = CGFloat(cells) * zoom
        var origin = CGPoint(x: cursor.x + 22, y: cursor.y - 22 - d)
        if origin.x + d > bounds.maxX - 6 { origin.x = cursor.x - 22 - d }
        if origin.y < bounds.minY + 34 { origin.y = cursor.y + 22 }
        let loupe = CGRect(origin: origin, size: CGSize(width: d, height: d))

        // Pixel under the cursor in the pre-captured frame (top-left origin).
        let k = CGFloat(image.width) / max(display.frame.width, 1)
        let px = Int(floor(cursor.x * k)), py = Int(floor((bounds.height - cursor.y) * k))
        let src = CGRect(x: px - cells / 2, y: py - cells / 2, width: cells, height: cells)
        let visible = src.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        ctx.saveGState()
        ctx.addEllipse(in: loupe)
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(loupe)
        if !visible.isNull, let crop = image.cropping(to: visible) {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: loupe.minX + (visible.minX - src.minX) * zoom,
                                      y: loupe.maxY - (visible.maxY - src.minY) * zoom,
                                      width: visible.width * zoom, height: visible.height * zoom))
        }
        let centre = CGRect(x: loupe.midX - zoom / 2, y: loupe.midY - zoom / 2, width: zoom, height: zoom)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        ctx.stroke(centre.insetBy(dx: -0.5, dy: -0.5))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.stroke(centre.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: CGColor(gray: 0, alpha: 0.5))
        ctx.strokeEllipse(in: loupe.insetBy(dx: 1, dy: 1))
        ctx.restoreGState()

        let pt = "\(Int(cursor.x)), \(Int(bounds.height - cursor.y))"
        OverlayDraw.pill(pt, origin: CGPoint(x: loupe.midX, y: loupe.minY - 16), centered: true, in: bounds)
    }
}
