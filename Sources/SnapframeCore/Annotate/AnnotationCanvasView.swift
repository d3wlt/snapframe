import AppKit

/// The document view inside the editor's scroll view. Draws the document through
/// `AnnotationRenderer` and turns mouse input into annotation edits.
@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let state: EditorState
    private let cache = EffectCache()

    /// Document-space point shown at the view's top-left.
    private(set) var origin: CGPoint = .zero
    private var preview: CGImage?
    private var previewKey: PreviewKey?

    private enum Drag {
        case drawing(UUID, anchor: CGPoint, optionInverse: Bool)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, Annotation.Handle)
        case crop(anchor: CGPoint)
        case cropHandle(Annotation.Handle)
        case cropMove(last: CGPoint)
    }
    private var drag: Drag?
    private var gestureStart: EditorState.Snapshot?

    private var editor: NSTextView?
    private var editingID: UUID?
    private var editStart: EditorState.Snapshot?

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = false
        syncLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    private var magnification: CGFloat { max(0.05, enclosingScrollView?.magnification ?? 1) }

    // MARK: Layout

    /// The document-space rectangle currently shown.
    private var displayRect: CGRect {
        if state.tool == .background, let p = previewImage() {
            return CGRect(x: 0, y: 0, width: CGFloat(p.width) / state.doc.scale, height: CGFloat(p.height) / state.doc.scale)
        }
        if state.tool == .crop || state.doc.cropRect == nil { return state.doc.canvasRect }
        return state.doc.outputRect
    }

    private struct PreviewKey: Equatable {
        let annotations: [Annotation]
        let crop: CGRect?
        let background: SnapframeCore.BackgroundStyle?
    }

    private func previewImage() -> CGImage? {
        let key = PreviewKey(annotations: state.doc.annotations, crop: state.doc.cropRect, background: state.doc.background)
        if preview == nil || key != previewKey {
            preview = state.doc.render()
            previewKey = key
        }
        return preview
    }

    func syncLayout() {
        if state.tool != .background { preview = nil }
        let r = displayRect
        origin = r.origin
        if frame.size != r.size { setFrameSize(r.size) }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateEditorFrame()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if state.tool == .background, let p = previewImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            AnnotationRenderer.drawImage(p, in: bounds, ctx)
            ctx.restoreGState()
            return
        }
        let doc = state.doc
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        let canvas = doc.canvasRect
        if canvas != doc.imageRect { drawChecker(ctx, canvas) }
        var hidden: Set<UUID> = []
        if let id = editingID { hidden.insert(id) }
        AnnotationRenderer.draw(doc, in: ctx, cache: cache, hiding: hidden, previewing: activeRedactionIDs)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: -origin.x, y: -origin.y)
        if state.tool == .crop { drawCropOverlay(ctx) }
        else if let a = state.selected, editingID == nil { drawSelection(a, ctx) }
        ctx.restoreGState()
    }

    /// Redactions currently being drawn, moved or resized (rendered at reduced quality until mouse-up).
    private var activeRedactionIDs: Set<UUID> {
        switch drag {
        case .drawing(let id, _, _), .moving(let id, _), .resizing(let id, _): return [id]
        default: return []
        }
    }

    private func drawChecker(_ ctx: CGContext, _ rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        let tile: CGFloat = 8
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(CGColor(gray: 0.74, alpha: 1))
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : tile)
            while x < rect.maxX { ctx.fill(CGRect(x: x, y: y, width: tile, height: tile)); x += tile * 2 }
            y += tile; row += 1
        }
        ctx.restoreGState()
    }

    private var handleSize: CGFloat { 9 / magnification }

    private func drawHandle(_ p: CGPoint, _ ctx: CGContext) {
        let s = handleSize
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 / magnification)
        ctx.fillEllipse(in: r)
        ctx.strokeEllipse(in: r)
    }

    private func drawSelection(_ a: Annotation, _ ctx: CGContext) {
        let lw = 1.5 / magnification
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(lw)
        if a.kind != .arrow && a.kind != .line {
            ctx.setLineDash(phase: 0, lengths: [4 / magnification, 3 / magnification])
            ctx.stroke(a.renderBounds.insetBy(dx: -2 / magnification, dy: -2 / magnification))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for (_, p) in a.handles { drawHandle(p, ctx) }
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        let canvas = state.doc.canvasRect
        let crop = state.cropDraft ?? canvas
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.addRect(canvas.insetBy(dx: -4, dy: -4))
        ctx.addRect(crop)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 / magnification)
        ctx.stroke(crop)
        // Rule-of-thirds guides.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.4))
        ctx.setLineWidth(1 / magnification)
        for i in 1...2 {
            let fx = crop.minX + crop.width * CGFloat(i) / 3, fy = crop.minY + crop.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: fx, y: crop.minY)); ctx.addLine(to: CGPoint(x: fx, y: crop.maxY))
            ctx.move(to: CGPoint(x: crop.minX, y: fy)); ctx.addLine(to: CGPoint(x: crop.maxX, y: fy))
        }
        ctx.strokePath()
        for (_, p) in cropHandles(crop) { drawHandle(p, ctx) }
        // Size label.
        let s = state.doc.scale
        let label = "\(Int((crop.width * s).rounded())) x \(Int((crop.height * s).rounded())) px" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 / magnification, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: crop.midX - size.width / 2 - 6 / magnification, y: crop.maxY + 6 / magnification,
                          width: size.width + 12 / magnification, height: size.height + 4 / magnification)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        label.draw(at: CGPoint(x: pill.minX + 6 / magnification, y: pill.minY + 2 / magnification), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func cropHandles(_ r: CGRect) -> [(Annotation.Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch state.tool {
        case .select, .background: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    private func docPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + origin.x, y: p.y + origin.y)
    }

    private func handleHit(_ handles: [(Annotation.Handle, CGPoint)], at p: CGPoint) -> Annotation.Handle? {
        let r = max(handleSize, 10 / magnification)
        return handles.first { hypot($0.1.x - p.x, $0.1.y - p.y) <= r }?.0
    }

    private func topAnnotation(at p: CGPoint) -> Annotation? {
        state.doc.annotations.last { $0.hitTest(p, tolerance: 5 / magnification) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        state.breakCoalescing()
        let p = docPoint(event)
        gestureStart = state.snapshot
        // Handles of the current selection stay grabbable while a drawing tool is active.
        if ![.select, .crop, .background].contains(state.tool), let sel = state.selected,
           let h = handleHit(sel.handles, at: p) {
            drag = .resizing(sel.id, h)
            return
        }
        switch state.tool {
        case .background:
            break
        case .select:
            if let sel = state.selected, let h = handleHit(sel.handles, at: p) {
                drag = .resizing(sel.id, h)
            } else if let hit = topAnnotation(at: p) {
                if event.clickCount == 2, hit.kind == .text { beginTextEditing(hit.id); return }
                state.selection = hit.id
                state.adoptSelectionProperties()
                drag = .moving(hit.id, last: p)
            } else {
                state.selection = nil
            }
            state.refresh()
        case .crop:
            let crop = state.cropDraft ?? state.doc.cropRect ?? state.doc.canvasRect
            if let h = handleHit(cropHandles(crop), at: p) { drag = .cropHandle(h) }
            else if crop.contains(p), crop != state.doc.canvasRect || state.cropDraft != nil { drag = .cropMove(last: p) }
            else { drag = .crop(anchor: p); state.cropDraft = CGRect(origin: p, size: .zero) }
            state.refresh()
        case .text:
            if let hit = topAnnotation(at: p), hit.kind == .text {
                state.selection = hit.id
                beginTextEditing(hit.id)
                return
            }
            var a = Annotation.text("", at: CGPoint(x: p.x - 4, y: p.y - state.fontSize * 0.6), fontSize: state.fontSize,
                                    color: state.color, background: state.textBackground)
            a.lineWidth = state.lineWidth
            state.doc.annotations.append(a)
            state.selection = a.id
            beginTextEditing(a.id, isNew: true)
        case .counter:
            var a = Annotation.counter(at: p, number: state.doc.nextCounterNumber, color: state.color, lineWidth: state.lineWidth)
            a.filled = true
            state.doc.annotations.append(a)
            state.selection = a.id
            state.registerUndo(gestureStart!)
            drag = .moving(a.id, last: p) // allow nudging while the button is held
            gestureStart = state.snapshot
        default:
            var a: Annotation
            switch state.tool {
            case .redact: a = Annotation(kind: state.pixelate ? .pixelate : .blur, start: p, end: p); a.strength = state.strength
            default: a = Annotation(kind: state.tool.annotationKind ?? .rectangle, start: p, end: p)
            }
            a.color = state.color
            a.lineWidth = state.lineWidth
            a.filled = state.filled && (a.kind == .rectangle || a.kind == .ellipse)
            a.rounded = state.rounded && a.kind == .rectangle
            a.smooth = Prefs.bool(PrefKey.annSmoothDrawing)
            let invert = event.modifierFlags.contains(.option)
            a.inverse = Prefs.bool(PrefKey.annInverseArrow) != invert
            if a.kind.isFreehand { a.points = [p] }
            state.doc.annotations.append(a)
            state.selection = a.id
            drag = .drawing(a.id, anchor: p, optionInverse: invert)
            state.changed()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = docPoint(event)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .drawing(let id, let anchor, _):
            guard let i = state.index(of: id) else { return }
            var a = state.doc.annotations[i]
            var q = p
            if a.kind.isFreehand {
                if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) < 1.5 / magnification { return }
                if shift, a.points.count >= 1 {
                    // Shift draws a straight segment from the first point.
                    a.points = [a.points[0], p]
                } else {
                    a.points.append(p)
                }
            } else {
                if shift {
                    switch a.kind {
                    case .arrow, .line:
                        let dx = p.x - anchor.x, dy = p.y - anchor.y
                        let len = hypot(dx, dy)
                        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                        q = CGPoint(x: anchor.x + cos(angle) * len, y: anchor.y + sin(angle) * len)
                    case .rectangle, .ellipse, .pixelate, .blur, .spotlight:
                        let side = max(abs(p.x - anchor.x), abs(p.y - anchor.y))
                        q = CGPoint(x: anchor.x + (p.x >= anchor.x ? side : -side), y: anchor.y + (p.y >= anchor.y ? side : -side))
                    default: break
                    }
                }
                a.end = q
            }
            state.doc.annotations[i] = a
            state.changed()
        case .moving(let id, let last):
            guard let i = state.index(of: id) else { return }
            state.doc.annotations[i] = state.doc.annotations[i].moved(by: CGSize(width: p.x - last.x, height: p.y - last.y))
            self.drag = .moving(id, last: p)
            state.changed()
        case .resizing(let id, let handle):
            guard let i = state.index(of: id) else { return }
            state.doc.annotations[i] = state.doc.annotations[i].resized(handle, to: p)
            state.changed()
        case .crop(let anchor):
            state.cropDraft = clampToCanvas(CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                                   width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)))
            state.refresh()
        case .cropHandle(let handle):
            let crop = state.cropDraft ?? state.doc.cropRect ?? state.doc.canvasRect
            state.cropDraft = clampToCanvas(Annotation.rect(crop, dragging: handle, to: p))
            state.refresh()
        case .cropMove(let last):
            var crop = state.cropDraft ?? state.doc.cropRect ?? state.doc.canvasRect
            let canvas = state.doc.canvasRect
            crop.origin.x = min(max(canvas.minX, crop.minX + p.x - last.x), canvas.maxX - crop.width)
            crop.origin.y = min(max(canvas.minY, crop.minY + p.y - last.y), canvas.maxY - crop.height)
            state.cropDraft = crop
            self.drag = .cropMove(last: p)
            state.refresh()
        }
    }

    private func clampToCanvas(_ r: CGRect) -> CGRect {
        let c = r.intersection(state.doc.canvasRect)
        return c.isNull ? .zero : c
    }

    override func mouseUp(with event: NSEvent) {
        // Clear the drag first so redraws triggered below render full quality, not the drag preview.
        let finished = drag, started = gestureStart
        drag = nil
        gestureStart = nil
        guard let drag = finished, let start = started else { return }
        switch drag {
        case .drawing(let id, _, _):
            guard let i = state.index(of: id) else { return }
            let a = state.doc.annotations[i]
            let tiny: Bool
            switch a.kind {
            case .arrow, .line: tiny = hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 4
            case .pencil, .highlighter: tiny = false
            default: tiny = a.rect.width < 3 || a.rect.height < 3
            }
            if tiny && !a.kind.isFreehand {
                state.doc.annotations.remove(at: i)
                state.selection = nil
                state.changed()
            } else {
                state.registerUndo(start)
            }
        case .moving, .resizing:
            if state.doc.annotations != start.annotations { state.registerUndo(start) } else { state.changed() }
        case .crop, .cropHandle, .cropMove:
            if let d = state.cropDraft, d.width < 4 || d.height < 4 { state.cropDraft = nil }
            state.refresh()
        }
        state.changed()
    }

    // MARK: Crop

    func applyCrop() {
        guard let draft = state.cropDraft else { state.tool = .select; return }
        let full = state.doc.canvasRect
        let before = state.snapshot
        state.doc.cropRect = draft.equalTo(full) ? nil : draft
        state.cropDraft = nil
        state.registerUndo(before)
        state.tool = .select
        state.changed()
    }

    func cancelCrop() {
        state.cropDraft = nil
        state.tool = .select
        state.refresh()
    }

    // MARK: Text editing

    func beginTextEditing(_ id: UUID, isNew: Bool = false) {
        guard let a = state.index(of: id).map({ state.doc.annotations[$0] }) else { return }
        commitTextEditing()
        editStart = isNew ? (gestureStart ?? state.snapshot) : state.snapshot
        if isNew, var s = editStart { s.annotations.removeAll { $0.id == id }; editStart = s }
        editingID = id
        let tv = NSTextView(frame: .zero)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 10_000, height: 10_000)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = a.textPadding
        tv.font = a.textFont
        tv.textColor = a.textAttributes[.foregroundColor] as? NSColor
        tv.insertionPointColor = a.textAttributes[.foregroundColor] as? NSColor ?? .labelColor
        tv.typingAttributes = a.textAttributes
        tv.string = a.text
        tv.delegate = self
        tv.wantsLayer = true
        if a.textBackground {
            tv.layer?.backgroundColor = a.color.cgColor
            tv.layer?.cornerRadius = min(a.textBox.height / 2, a.fontSize * 0.6)
        } else {
            tv.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            tv.layer?.borderWidth = 1 / magnification
        }
        addSubview(tv)
        editor = tv
        updateEditorFrame()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        state.refresh()
    }

    var isEditingText: Bool { editor != nil }

    private func updateEditorFrame() {
        guard let tv = editor, let id = editingID, let i = state.index(of: id) else { return }
        let box = state.doc.annotations[i].textBox
        tv.frame = CGRect(x: box.minX - origin.x, y: box.minY - origin.y, width: box.width, height: box.height)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = editor, let id = editingID, let i = state.index(of: id) else { return }
        state.doc.annotations[i].text = tv.string
        updateEditorFrame()
        state.changed()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    func commitTextEditing() {
        guard let tv = editor, let id = editingID else { return }
        let text = tv.string
        tv.delegate = nil
        tv.removeFromSuperview()
        editor = nil
        editingID = nil
        let start = editStart
        editStart = nil
        window?.makeFirstResponder(self)
        guard let i = state.index(of: id) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.doc.annotations.remove(at: i)
            if state.selection == id { state.selection = nil }
            // Emptying an existing text object is a deletion: keep it undoable.
            if let start, start.annotations.contains(where: { $0.id == id }) { state.registerUndo(start) } else { state.changed() }
            return
        }
        state.doc.annotations[i].text = text
        if let start, state.doc.annotations != start.annotations { state.registerUndo(start) } else { state.changed() }
    }

    // MARK: Keyboard actions (called by the window)

    func deleteSelection() {
        guard let id = state.selection, let i = state.index(of: id) else { return }
        let before = state.snapshot
        state.doc.annotations.remove(at: i)
        state.selection = nil
        state.registerUndo(before)
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let id = state.selection, let i = state.index(of: id) else { return }
        let before = state.snapshot
        state.doc.annotations[i] = state.doc.annotations[i].moved(by: CGSize(width: dx, height: dy))
        state.registerUndo(before, tag: "nudge")
    }
}
