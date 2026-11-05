import AppKit

/// Non-activating panel that can still become key, so the countdown's local monitor receives Esc.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private func hudPanel(size: CGSize, on screen: NSScreen?, anchorY: CGFloat) -> NSPanel {
    let frame = (screen ?? NSScreen.main)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let rect = CGRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * anchorY - size.height / 2,
                      width: size.width, height: size.height)
    let panel = HUDPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return panel
}

private func hudBackground(size: CGSize, radius: CGFloat) -> NSVisualEffectView {
    let v = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    // A mask image (not a layer mask) makes the window shadow follow the rounded shape.
    let mask = NSImage(size: CGSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    mask.resizingMode = .stretch
    v.maskImage = mask
    return v
}

/// Transient pill ("Text copied"). Dismisses itself.
@MainActor
enum Toast {
    private static var current: NSPanel?

    static func show(_ text: String, symbol: String, duration: TimeInterval = 1.6) {
        current?.orderOut(nil)
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.sizeToFit()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        icon.contentTintColor = .labelColor
        let size = CGSize(width: 18 + 20 + 8 + ceil(label.frame.width) + 18, height: 44)
        let panel = hudPanel(size: size, on: NSScreen.underMouse, anchorY: 0.18)
        let bg = hudBackground(size: size, radius: 22)
        icon.frame = CGRect(x: 18, y: (size.height - 20) / 2, width: 20, height: 20)
        label.frame = CGRect(x: 46, y: (size.height - label.frame.height) / 2, width: ceil(label.frame.width), height: label.frame.height)
        bg.addSubview(icon)
        bg.addSubview(label)
        panel.contentView = bg
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        current = panel
        Task { @MainActor [weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    panel.close()
                    if current === panel { current = nil }
                }
            }
        }
    }
}

/// Centered countdown for the self-timer. Esc or the close button cancels.
@MainActor
final class CountdownHUD {
    private var panel: NSPanel?
    private let number = NSTextField(labelWithString: "")
    private var monitors: [Any] = []
    private(set) var cancelled = false
    private let focus = FocusKeeper()

    /// Returns true when the countdown finished, false when cancelled.
    func run(seconds: Int, on screen: NSScreen?) async -> Bool {
        present(on: screen)
        defer { dismiss() }
        var remaining = seconds
        while remaining > 0, !cancelled {
            number.stringValue = "\(remaining)"
            pulse()
            for _ in 0..<10 where !cancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
            remaining -= 1
        }
        return !cancelled
    }

    private func present(on screen: NSScreen?) {
        let size = CGSize(width: 168, height: 168)
        let panel = hudPanel(size: size, on: screen ?? NSScreen.underMouse, anchorY: 0.5)
        panel.ignoresMouseEvents = false
        let bg = hudBackground(size: size, radius: 34)

        number.font = {
            let base = NSFont.systemFont(ofSize: 84, weight: .semibold)
            guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: d, size: 84) ?? base
        }()
        number.textColor = .labelColor
        number.alignment = .center
        number.frame = CGRect(x: 0, y: 36, width: size.width, height: 100)
        bg.addSubview(number)

        let hint = NSTextField(labelWithString: "Esc to cancel")
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = CGRect(x: 0, y: 14, width: size.width, height: 16)
        bg.addSubview(hint)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")!,
                             target: self, action: #selector(cancel))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = CGRect(x: size.width - 34, y: size.height - 34, width: 24, height: 24)
        bg.addSubview(close)

        panel.contentView = bg
        // Hotkeys don't activate Snapframe and a non-activating key panel isn't guaranteed Esc, so take focus for
        // the countdown; it goes back to the previous app in dismiss(), before the capture.
        focus.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        // Global monitor sees Esc while another app is active (needs input-monitoring rights; best effort).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.cancelled = true } }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.cancelled = true }
            return nil
        }) { monitors.append(m) }
    }

    @objc private func cancel() { cancelled = true }

    private func pulse() {
        guard let layer = number.layer ?? { number.wantsLayer = true; return number.layer }() else { return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.18
        a.toValue = 1.0
        a.duration = 0.25
        layer.add(a, forKey: "pulse")
    }

    private func dismiss() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        focus.restore()
    }
}
