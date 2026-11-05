import AppKit

/// Pure sizing helpers for pinned images.
public enum PinLayout {
    /// Point size to show an image at: its natural size, shrunk (never enlarged) to fit 90% of the screen.
    public static func initialSize(for natural: CGSize, in visibleFrame: CGRect) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: 200, height: 200) }
        let k = min(1, visibleFrame.width * 0.9 / natural.width, visibleFrame.height * 0.9 / natural.height)
        return CGSize(width: (natural.width * k).rounded(), height: (natural.height * k).rounded())
    }

    /// New frame after zooming by `factor` around `anchor` (a point in screen coordinates), keeping the
    /// aspect ratio and clamping the longer side to `limits`.
    public static func zoomed(_ frame: CGRect, factor: CGFloat, anchor: CGPoint, limits: ClosedRange<CGFloat>) -> CGRect {
        guard frame.width > 0, frame.height > 0, factor > 0 else { return frame }
        let longer = max(frame.width, frame.height)
        let k = min(max(longer * factor, limits.lowerBound), limits.upperBound) / longer
        let size = CGSize(width: frame.width * k, height: frame.height * k)
        let fx = (anchor.x - frame.minX) / frame.width
        let fy = (anchor.y - frame.minY) / frame.height
        return CGRect(x: anchor.x - fx * size.width, y: anchor.y - fy * size.height, width: size.width, height: size.height)
    }
}

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Content of a pin: the image, styling, drag-to-move, key handling, right-click menu.
final class PinView: NSView {
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onOpacity: ((CGFloat) -> Void)?
    var onZoom: ((_ factor: CGFloat) -> Void)?
    var canAnnotate = true
    var opacity: CGFloat = 1

    private let imageView = NSImageView()
    private let rounded: Bool
    private let bordered: Bool

    init(image: NSImage, rounded: Bool, bordered: Bool) {
        self.rounded = rounded
        self.bordered = bordered
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = rounded ? 10 : 0
        layer?.borderWidth = bordered ? 1 : 0
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        addSubview(imageView)
        updateBorderColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) { imageView.image = image }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        guard bordered else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.25)).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            if canAnnotate { onAnnotate?() }
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.06
        guard delta != 0 else { return }
        onZoom?(exp(delta))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return } // Esc
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": onClose?(); return true
        case "c": onCopy?(); return true
        default: return false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled
        }
        add("Copy", #selector(copyAction), key: "c")
        add("Save…", #selector(saveAction))
        add("Annotate", #selector(annotateAction), enabled: canAnnotate)
        menu.addItem(.separator())
        let opacityMenu = NSMenu(title: "Opacity")
        for percent in [100, 75, 50, 25] {
            let item = opacityMenu.addItem(withTitle: "\(percent)%", action: #selector(opacityAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = abs(opacity - CGFloat(percent) / 100) < 0.01 ? .on : .off
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        add("Close", #selector(closeAction), key: "w")
        return menu
    }

    @objc private func copyAction() { onCopy?() }
    @objc private func saveAction() { onSave?() }
    @objc private func annotateAction() { onAnnotate?() }
    @objc private func closeAction() { onClose?() }
    @objc private func opacityAction(_ sender: NSMenuItem) { onOpacity?(CGFloat(sender.tag) / 100) }
}

@MainActor
public final class PinController {
    public static let shared = PinController()

    private final class Pin {
        var item: CapturedItem
        let panel: PinPanel
        let view: PinView
        init(item: CapturedItem, panel: PinPanel, view: PinView) {
            self.item = item
            self.panel = panel
            self.view = view
        }
    }

    private var pins: [Pin] = []

    /// IDs of items currently pinned (protected from history pruning).
    public var openItemIDs: Set<UUID> { Set(pins.map { $0.item.id }) }
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .snapframeItemUpdated, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? CapturedItem else { return }
            MainActor.assumeIsolated { self?.itemUpdated(item) }
        }
    }

    /// Floats the image above all windows.
    public func pin(_ item: CapturedItem) {
        guard let image = item.loadImage() else { NSSound.beep(); return }
        let screen = NSScreen.underMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PinLayout.initialSize(for: item.pointSize, in: visible)
        // Cascade extra pins slightly so they never hide each other completely.
        let cascade = CGFloat(pins.count % 6) * 24
        let origin = CGPoint(x: visible.midX - size.width / 2 + cascade, y: visible.midY - size.height / 2 - cascade)

        let view = PinView(image: image, rounded: Prefs.bool(PrefKey.pinRoundedCorners),
                           bordered: Prefs.bool(PrefKey.pinBorder))
        let panel = PinPanel(contentRect: CGRect(origin: origin, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = Prefs.bool(PrefKey.pinShadow)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = view

        let pin = Pin(item: item, panel: panel, view: view)
        view.canAnnotate = item.kind == .image
        view.onClose = { [weak self, weak pin] in if let pin { self?.close(pin) } }
        view.onCopy = { [weak pin] in if let pin { Clipboard.copy(pin.item) } }
        view.onSave = { [weak pin] in
            guard let pin, let url = Exporter.save(pin.item, ask: true) else { return }
            pin.item.savedURL = url
        }
        view.onAnnotate = { [weak pin] in if let pin { AnnotationEditor.open(pin.item) } }
        view.onOpacity = { [weak pin] value in
            guard let pin else { return }
            pin.panel.alphaValue = value
            pin.view.opacity = value
        }
        view.onZoom = { [weak self, weak pin] factor in if let pin { self?.zoom(pin, by: factor) } }

        pins.append(pin)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    public func pin(fileURL: URL) {
        if let item = ItemFactory.itemForExternalFile(fileURL) { pin(item) }
    }

    private func close(_ pin: Pin) {
        pins.removeAll { $0 === pin }
        pin.panel.orderOut(nil)
        pin.panel.close()
    }

    private func zoom(_ pin: Pin, by factor: CGFloat) {
        let frame = pin.panel.frame
        let screen = pin.panel.screen ?? NSScreen.underMouse
        let maxSide = (screen.map { max($0.frame.width, $0.frame.height) } ?? 2000) * 2
        let anchor = NSEvent.mouseLocation
        let inside = frame.contains(anchor)
        let target = PinLayout.zoomed(frame, factor: factor,
                                      anchor: inside ? anchor : CGPoint(x: frame.midX, y: frame.midY),
                                      limits: 60...maxSide)
        pin.panel.setFrame(target, display: true)
    }

    private func itemUpdated(_ item: CapturedItem) {
        for pin in pins where pin.item.id == item.id {
            guard let image = item.loadImage() else { continue }
            let old = pin.item.pointSize
            pin.item = item
            pin.view.setImage(image)
            // Keep the on-screen scale: new size = old displayed size scaled by the point-size change.
            let frame = pin.panel.frame
            let new = item.pointSize
            guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { continue }
            let k = frame.width / old.width
            let size = CGSize(width: new.width * k, height: new.height * k)
            let target = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                width: size.width, height: size.height)
            pin.panel.setFrame(target, display: true)
        }
    }
}
