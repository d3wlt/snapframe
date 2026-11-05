import AppKit

struct WindowCandidate {
    var id: CGWindowID
    /// AppKit global coordinates (bottom-left origin).
    var frame: CGRect
    var appName: String
    var title: String
}

struct WindowPick {
    var window: WindowCandidate
    var modifiers: NSEvent.ModifierFlags
}

/// Hover-to-highlight window chooser.
@MainActor
enum WindowPicker {
    static let minimumSize: CGFloat = 40

    /// On-screen normal windows (layer 0), front to back, excluding Snapframe's own and tiny ones.
    /// Uses CGWindowList (frames and owners need no Screen Recording permission).
    static func candidates() -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let own = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: dict),
                  quartz.width >= minimumSize, quartz.height >= minimumSize else { return nil }
            return WindowCandidate(id: id, frame: CaptureGeometry.appKitRect(fromQuartz: quartz, primaryHeight: primaryHeight),
                                   appName: info[kCGWindowOwnerName as String] as? String ?? "",
                                   title: info[kCGWindowName as String] as? String ?? "")
        }
    }

    static func pick() async -> WindowPick? {
        let overlay = WindowPickOverlay(candidates: candidates())
        return await overlay.run()
    }
}

@MainActor
final class WindowPickOverlay {
    let candidates: [WindowCandidate]
    private(set) var hovered: WindowCandidate?
    private(set) var cursor = NSEvent.mouseLocation
    private var panels: [OverlayPanel] = []
    private var monitor: Any?
    private let focus = FocusKeeper()
    private var continuation: CheckedContinuation<WindowPick?, Never>?

    init(candidates: [WindowCandidate]) {
        self.candidates = candidates
        hovered = CaptureGeometry.topmost(at: cursor, in: candidates) { $0.frame }
    }

    func run() async -> WindowPick? {
        await withCheckedContinuation { cont in
            continuation = cont
            present()
        }
    }

    private func present() {
        focus.activate()
        for screen in NSScreen.screens {
            let view = PickView(overlay: self, frame: screen.frame)
            let panel = OverlayPanel.make(for: screen, view: view)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        (panels.first { $0.frame.contains(cursor) } ?? panels.first)?.makeKey()
        monitor = localMonitor([.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        NSCursor.pointingHand.set()
        redraw()
        if panels.isEmpty { finish(nil) }
    }

    private func redraw() { for p in panels { p.contentView?.needsDisplay = true } }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard continuation != nil else { return event }
        cursor = NSEvent.mouseLocation
        NSCursor.pointingHand.set()
        switch event.type {
        case .mouseMoved, .leftMouseDragged:
            hovered = CaptureGeometry.topmost(at: cursor, in: candidates) { $0.frame }
        case .leftMouseDown:
            hovered = CaptureGeometry.topmost(at: cursor, in: candidates) { $0.frame }
            if let w = hovered { finish(WindowPick(window: w, modifiers: event.modifierFlags)) }
        case .keyDown:
            if event.keyCode == 53 { finish(nil) }
            return nil
        case .keyUp:
            return nil
        default:
            break
        }
        redraw()
        return nil
    }

    private func finish(_ pick: WindowPick?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        for p in panels { p.orderOut(nil); p.close() }
        panels = []
        NSCursor.arrow.set()
        focus.restore()
        cont.resume(returning: pick)
    }
}

@MainActor
final class PickView: NSView {
    private unowned let overlay: WindowPickOverlay
    private let screenFrame: CGRect

    init(overlay: WindowPickOverlay, frame: CGRect) {
        self.overlay = overlay
        screenFrame = frame
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // A near-invisible fill keeps the panel hit-testable without visibly dimming anything.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.01))
        ctx.fill(bounds)

        if let w = overlay.hovered {
            let r = w.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            if r.intersects(bounds) {
                let accent = NSColor.controlAccentColor
                let path = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
                accent.withAlphaComponent(0.28).setFill()
                path.fill()
                accent.withAlphaComponent(0.95).setStroke()
                path.lineWidth = 3
                path.stroke()
                let name = w.appName.isEmpty ? "Window" : w.appName
                let label = "\(name)  ·  \(Int(w.frame.width)) × \(Int(w.frame.height))"
                let visible = r.intersection(bounds)
                OverlayDraw.pill(label, origin: CGPoint(x: visible.midX, y: visible.midY),
                                 font: .systemFont(ofSize: 12, weight: .medium), centered: true, in: bounds)
            }
        }
        if bounds.contains(CGPoint(x: overlay.cursor.x - screenFrame.minX, y: overlay.cursor.y - screenFrame.minY)) {
            OverlayDraw.pill("Click a window  ·  ⌥ no shadow  ·  ⇧ transparent  ·  Esc to cancel",
                             origin: CGPoint(x: bounds.midX, y: bounds.maxY - 64),
                             font: .systemFont(ofSize: 12, weight: .medium), centered: true, in: bounds)
        }
    }
}
