import AppKit

/// Borderless full-screen panel that can take key events without activating Snapframe (so the app being
/// captured keeps its active look).
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make(for screen: NSScreen, view: NSView) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false, screen: screen)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setFrame(screen.frame, display: false)
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        panel.contentView = view
        return panel
    }
}

enum OverlayDraw {
    /// Dark rounded label with white text, anchored with its bottom-left at `origin` (view coordinates).
    @discardableResult
    static func pill(_ text: String, origin: CGPoint, font: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                     centered: Bool = false, in bounds: CGRect? = nil) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var rect = CGRect(x: origin.x, y: origin.y, width: ceil(size.width) + 16, height: ceil(size.height) + 8)
        if centered { rect.origin = CGPoint(x: origin.x - rect.width / 2, y: origin.y - rect.height / 2) }
        if let b = bounds {
            rect.origin.x = min(max(rect.minX, b.minX + 6), b.maxX - rect.width - 6)
            rect.origin.y = min(max(rect.minY, b.minY + 6), b.maxY - rect.height - 6)
        }
        NSColor.black.withAlphaComponent(0.74).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        str.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4))
        return rect
    }

    /// Hairline width in points for the current backing scale.
    @MainActor static func hairline(_ view: NSView) -> CGFloat { 1 / max(view.window?.backingScaleFactor ?? 2, 1) }
}

struct EventBox: @unchecked Sendable { let event: NSEvent? }

/// Wraps a main-actor event handler for `NSEvent.addLocalMonitorForEvents` (which calls it on the main thread).
func localMonitor(_ mask: NSEvent.EventTypeMask, _ body: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: mask) { event in
        let box = EventBox(event: event)
        return MainActor.assumeIsolated { EventBox(event: body(box.event!)) }.event
    }
}

/// Remembers the frontmost app, activates Snapframe so overlays get key/mouse events and the Esc key, and
/// hands focus back afterwards so the captured app regains its active look.
///
/// Activating would also raise Snapframe's own background windows (editor, Settings) above the app being
/// captured, so those are ordered out first and put back below that app's front window on restore.
@MainActor
final class FocusKeeper {
    private var previous: NSRunningApplication?
    /// Snapframe's ordinary windows hidden for the capture, front to back.
    private var hiddenWindows: [NSWindow] = []

    /// The app restored most recently; reused when a quick second capture still sees Snapframe as frontmost.
    private static var lastRestored: (app: NSRunningApplication, at: Date)?

    func activate() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != getpid() {
            previous = front
        } else if let last = Self.lastRestored, Date().timeIntervalSince(last.at) < 0.5, !last.app.isTerminated {
            previous = last.app
        }
        if previous != nil {
            hiddenWindows = NSApp.orderedWindows.filter {
                $0.isVisible && $0.level == .normal && !($0 is NSPanel) && !$0.isMiniaturized
            }
            hiddenWindows.forEach { $0.orderOut(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func restore() {
        defer { previous = nil; hiddenWindows = [] }
        guard let previous else { return }
        let activated = !previous.isTerminated && previous.activate()
        if activated {
            Self.lastRestored = (previous, Date())
        } else {
            NSApp.deactivate()
        }
        // Put Snapframe's windows back behind the restored app, keeping their relative order.
        if let anchor = Self.frontWindowNumber(of: previous.processIdentifier), activated {
            var below = anchor
            for window in hiddenWindows {
                window.order(.below, relativeTo: below)
                below = window.windowNumber
            }
        } else {
            for window in hiddenWindows { window.orderBack(nil) }
        }
    }

    /// Frontmost on-screen normal-level window of a process (CGWindowList is ordered front to back).
    private static func frontWindowNumber(of pid: pid_t) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowNumber as String] as? Int
    }
}
