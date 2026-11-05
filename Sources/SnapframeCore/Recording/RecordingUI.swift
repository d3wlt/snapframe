import AppKit
import QuartzCore

// Windows used while recording. Everything here belongs to Snapframe's process and is therefore excluded from
// the video by the content filter, except `RecordingOverlayWindow` (click rings + keystrokes), which is
// explicitly re-included.

// MARK: - Dimming

/// Dims one display; on the recording display the area is cut out and outlined.
final class DimWindow: NSWindow {
    private final class DimView: NSView {
        var hole: CGRect?
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            let dim = NSBezierPath(rect: bounds)
            if let hole { dim.appendRect(hole) }
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            dim.fill()
            guard let hole else { return }
            // Hairline just outside the area so it never lands in the video.
            let border = NSBezierPath(rect: hole.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.85).setStroke()
            border.stroke()
        }
    }

    /// `hole` is in global Cocoa coordinates, nil for displays that are only dimmed.
    init(screen: NSScreen, hole: CGRect?) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = DimView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.hole = hole.map { CGRect(x: $0.minX - screen.frame.minX, y: $0.minY - screen.frame.minY,
                                      width: $0.width, height: $0.height) }
        contentView = view
        setFrame(screen.frame, display: false)
        orderFrontRegardless()
    }
}

// MARK: - Click rings and keystrokes

final class RecordingOverlayWindow: NSWindow {
    private final class OverlayView: NSView {
        private let pill = NSView()
        private let label = NSTextField(labelWithString: "")
        private var hideWork: DispatchWorkItem?
        var areaInView: CGRect = .zero

        override var isOpaque: Bool { false }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            pill.layer?.cornerRadius = 14
            pill.alphaValue = 0
            label.font = .systemFont(ofSize: 26, weight: .medium)
            label.textColor = .white
            label.alignment = .center
            label.lineBreakMode = .byTruncatingHead
            label.maximumNumberOfLines = 1
            pill.addSubview(label)
            addSubview(pill)
        }
        required init?(coder: NSCoder) { fatalError() }

        func addRing(at p: CGPoint, color: NSColor) {
            guard let root = layer else { return }
            let d: CGFloat = 60
            let ring = CAShapeLayer()
            ring.frame = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            ring.contentsScale = window?.backingScaleFactor ?? 2
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 3, dy: 3), transform: nil)
            ring.fillColor = color.withAlphaComponent(0.28).cgColor
            ring.strokeColor = color.cgColor
            ring.lineWidth = 3
            root.addSublayer(ring)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.3
            scale.toValue = 1.0
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1.0, 1.0, 0.0]
            fade.keyTimes = [0, 0.55, 1]
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.6
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            ring.add(group, forKey: "click")
            CATransaction.commit()
        }

        func showKeys(_ text: String) {
            label.stringValue = text
            label.sizeToFit()
            let maxWidth = max(80, areaInView.width - 40)
            let width = min(label.frame.width, maxWidth)
            let size = CGSize(width: width + 36, height: label.frame.height + 20)
            let x = areaInView.midX - size.width / 2
            let y = areaInView.minY + 28
            pill.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            label.frame = CGRect(x: 18, y: 10, width: width, height: label.frame.height)
            pill.alphaValue = 1
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    self?.pill.animator().alphaValue = 0
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }

    private let overlay: OverlayView
    private let screenFrame: CGRect

    /// `area` in global Cocoa coordinates.
    init(screen: NSScreen, area: CGRect) {
        screenFrame = screen.frame
        overlay = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        overlay.areaInView = CGRect(x: area.minX - screen.frame.minX, y: area.minY - screen.frame.minY,
                                    width: area.width, height: area.height)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = overlay
        setFrame(screen.frame, display: false)
        orderFrontRegardless()
    }

    /// `point` in global Cocoa coordinates.
    func ring(atGlobal point: CGPoint, color: NSColor) {
        overlay.addRing(at: CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY), color: color)
    }

    func showKeys(_ text: String) { overlay.showKeys(text) }
}

// MARK: - Global input monitoring

@MainActor
final class InputMonitor {
    private var monitors: [Any] = []
    private var buffer = KeystrokeBuffer()
    private let area: CGRect
    private let excluded: () -> CGRect?

    /// `area` is in global Cocoa coordinates; clicks outside it (or on the controls HUD) are ignored.
    init(area: CGRect, excluding: @escaping () -> CGRect?) {
        self.area = area
        self.excluded = excluding
    }

    func start(clicks: ((CGPoint) -> Void)?, keys: ((String) -> Void)?) {
        if let clicks {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let p = NSEvent.mouseLocation
                    if self.area.contains(p), !(self.excluded()?.contains(p) ?? false) { clicks(p) }
                }
            }) { monitors.append(m) }
        }
        if let keys {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                let code = UInt32(event.keyCode)
                let chars = event.charactersIgnoringModifiers
                let flags = event.modifierFlags
                let isRepeat = event.isARepeat
                MainActor.assumeIsolated {
                    guard let self, !isRepeat else { return }
                    let label = KeystrokeFormatter.label(keyCode: code, characters: chars, flags: flags)
                    keys(self.buffer.add(label, at: ProcessInfo.processInfo.systemUptime))
                }
            }) { monitors.append(m) }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

// MARK: - Controls HUD

@MainActor
final class RecordingControlsHUD: NSPanel {
    var onStop: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?

    private let dot = NSImageView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let pauseButton = NSButton()
    private var paused = false

    init(showsMicrophone: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        dot.image = Self.symbol("circle.fill", size: 9)
        dot.contentTintColor = .systemRed
        dot.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .labelColor
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let stop = NSButton()
        stop.image = Self.symbol("stop.fill", size: 12, weight: .bold)
        stop.imagePosition = .imageOnly
        stop.isBordered = false
        stop.contentTintColor = .white
        stop.wantsLayer = true
        stop.layer?.backgroundColor = NSColor.systemRed.cgColor
        stop.layer?.cornerRadius = 13
        stop.toolTip = "Stop recording"
        stop.target = self
        stop.action = #selector(stopTapped)
        NSLayoutConstraint.activate([stop.widthAnchor.constraint(equalToConstant: 26), stop.heightAnchor.constraint(equalToConstant: 26)])

        configure(pauseButton, symbol: "pause.fill", tip: "Pause", action: #selector(pauseTapped))
        let restart = makeButton(symbol: "arrow.counterclockwise", tip: "Restart", action: #selector(restartTapped))
        let cancel = makeButton(symbol: "trash", tip: "Discard recording", action: #selector(cancelTapped))

        var views: [NSView] = [dot, timeLabel, divider(), pauseButton, restart, cancel]
        if showsMicrophone {
            let mic = NSImageView(image: Self.symbol("mic.fill", size: 12))
            mic.contentTintColor = .secondaryLabelColor
            mic.toolTip = "Microphone is on"
            views.append(mic)
        }
        views.append(divider())
        views.append(stop)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        let size = stack.fittingSize
        setContentSize(CGSize(width: ceil(size.width), height: max(42, ceil(size.height))))
        pulse(true)
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = Self.symbol(symbol, size: 14)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
    }

    private func makeButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton()
        configure(b, symbol: symbol, tip: tip, action: action)
        return b
    }

    private func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 1), v.heightAnchor.constraint(equalToConstant: 18)])
        return v
    }

    private func pulse(_ on: Bool) {
        dot.wantsLayer = true
        dot.layer?.removeAnimation(forKey: "pulse")
        guard on else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.35
        a.duration = 0.9
        a.autoreverses = true
        a.repeatCount = .infinity
        dot.layer?.add(a, forKey: "pulse")
    }

    func setElapsed(_ text: String) { timeLabel.stringValue = text }

    func setPaused(_ value: Bool) {
        paused = value
        dot.image = Self.symbol(value ? "pause.fill" : "circle.fill", size: 9)
        dot.contentTintColor = value ? .systemOrange : .systemRed
        timeLabel.textColor = value ? .secondaryLabelColor : .labelColor
        pauseButton.image = Self.symbol(value ? "play.fill" : "pause.fill", size: 14)
        pauseButton.toolTip = value ? "Resume" : "Pause"
        pulse(!value)
    }

    override var canBecomeKey: Bool { false }

    @objc private func stopTapped() { onStop?() }
    @objc private func pauseTapped() { onPauseToggle?() }
    @objc private func restartTapped() { onRestart?() }
    @objc private func cancelTapped() { onCancel?() }
}

// MARK: - Countdown

@MainActor
final class RecordingCountdownHUD: NSPanel {
    private let label = NSTextField(labelWithString: "3")

    init(center: CGPoint) {
        let size = CGSize(width: 132, height: 132)
        super.init(contentRect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                       width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // a window shadow would follow the square frame, not the circle
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = size.width / 2
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        label.font = .systemFont(ofSize: 72, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        contentView = effect
        orderFrontRegardless()
    }

    func show(_ number: Int) {
        label.stringValue = "\(number)"
        label.wantsLayer = true
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.3
        pop.toValue = 1.0
        pop.duration = 0.25
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        label.layer?.add(pop, forKey: "pop")
    }
}

// MARK: - GIF progress

@MainActor
final class ConvertingPanel: NSPanel {
    private let bar = NSProgressIndicator()

    init(screen: NSScreen) {
        let size = CGSize(width: 220, height: 64)
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 60)
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Creating GIF…")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let stack = NSStackView(views: [title, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        contentView = effect
        orderFrontRegardless()
    }

    func setProgress(_ value: Double) { bar.doubleValue = value }
}
