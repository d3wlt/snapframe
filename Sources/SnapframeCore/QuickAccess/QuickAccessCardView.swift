import AppKit

/// Round or pill button used on the card overlay. White fill with dark glyphs reads on any capture.
final class QuickAccessButton: NSButton {
    enum Style { case circle, pill }
    var handler: (() -> Void)?
    private let style: Style

    init(symbol: String, title: String? = nil, tooltip: String) {
        style = title == nil ? .circle : .pill
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        let config = NSImage.SymbolConfiguration(pointSize: style == .pill ? 11 : 10, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        contentTintColor = NSColor(white: 0.1, alpha: 0.9)
        if let title {
            imagePosition = .imageLeft
            imageHugsTitle = true
            attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor(white: 0.1, alpha: 0.9),
            ])
        } else {
            imagePosition = .imageOnly
        }
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.94).cgColor
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        style == .circle ? NSSize(width: 22, height: 22) : NSSize(width: 68, height: 24)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override var isHighlighted: Bool {
        didSet { layer?.backgroundColor = NSColor(white: isHighlighted ? 0.8 : 1, alpha: 0.94).cgColor }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func fire() { handler?() }
}

/// A single floating thumbnail card. Pure view: all behaviour is injected by QuickAccessController.
final class QuickAccessCardView: NSView, NSDraggingSource {
    var onCopy: (() -> Void)?
    var onSave: ((_ ask: Bool) -> Void)?
    var onPrimaryEdit: (() -> Void)?
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var dragURL: (() -> URL?)?
    var onDragFinished: ((_ succeeded: Bool) -> Void)?

    private let backdrop = NSVisualEffectView()
    private let imageView = NSImageView()
    private let overlay = NSView()
    private let closeButton = QuickAccessButton(symbol: "xmark", tooltip: "Close")
    private let copyButton = QuickAccessButton(symbol: "doc.on.doc", title: "Copy", tooltip: "Copy to clipboard")
    private let saveButton = QuickAccessButton(symbol: "square.and.arrow.down", title: "Save",
                                               tooltip: "Save (Option-click to choose a location)")
    private var editButton: QuickAccessButton?
    private var pinButton: QuickAccessButton?
    private let feedback = NSView()
    private let feedbackIcon = NSImageView()
    private let feedbackLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let badgeIcon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")

    private var hovering = false
    private var flashWork: DispatchWorkItem?
    private var dragOrigin: NSPoint?
    private var thumbnailToken = UUID()
    private(set) var item: CapturedItem

    init(item: CapturedItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        addSubview(backdrop)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        addSubview(imageView)

        configureBadge()

        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        overlay.alphaValue = 0
        addSubview(overlay)

        closeButton.handler = { [weak self] in self?.onClose?() }
        copyButton.handler = { [weak self] in self?.onCopy?() }
        saveButton.handler = { [weak self] in
            let ask = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
            self?.onSave?(ask)
        }
        [closeButton, copyButton, saveButton].forEach(overlay.addSubview)
        configureFeedback()
        rebuildOptionalButtons()
        apply(item: item)
        updateBorderColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    func apply(item: CapturedItem) {
        self.item = item
        rebuildOptionalButtons()
        let token = UUID()
        thumbnailToken = token
        // Keep the previous thumbnail until the new one is ready (no flicker on update).
        loadThumbnail(token: token)
        imageView.animates = false
        updateBadge(duration: nil)
        if item.kind == .video {
            Task { @MainActor [weak self] in
                let d = await Thumbnails.duration(of: item)
                guard let self, self.thumbnailToken == token else { return }
                self.updateBadge(duration: d)
            }
        }
        needsLayout = true
    }

    private func loadThumbnail(token: UUID) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let item = self.item
        Task { @MainActor [weak self] in
            // Largest possible card is 320 x 416 pt; never hold more than that many pixels.
            let size = CGSize(width: 320, height: 416)
            let image: NSImage?
            if item.kind == .image {
                image = await Thumbnails.downsampled(url: item.fileURL, maxPixel: 416 * scale, scale: scale)
            } else {
                image = await Thumbnails.thumbnail(for: item, size: size, scale: scale)
            }
            guard let self, self.thumbnailToken == token else { return }
            self.imageView.image = image
        }
    }

    private func rebuildOptionalButtons() {
        editButton?.removeFromSuperview()
        pinButton?.removeFromSuperview()
        editButton = nil
        pinButton = nil
        switch item.kind {
        case .image:
            editButton = QuickAccessButton(symbol: "pencil", tooltip: "Annotate")
        case .video:
            editButton = QuickAccessButton(symbol: "scissors", tooltip: "Edit video")
        case .gif:
            editButton = QuickAccessButton(symbol: "scissors", tooltip: "Edit GIF")
        }
        if item.kind != .video {
            pinButton = QuickAccessButton(symbol: "pin", tooltip: "Pin to screen")
        }
        editButton?.handler = { [weak self] in self?.onPrimaryEdit?() }
        pinButton?.handler = { [weak self] in self?.onPin?() }
        if let editButton { overlay.addSubview(editButton) }
        if let pinButton { overlay.addSubview(pinButton) }
        // Keep the feedback pill above the buttons.
        overlay.addSubview(feedback)
    }

    private func configureBadge() {
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        badgeIcon.contentTintColor = .white
        badgeIcon.imageScaling = .scaleProportionallyDown
        badgeLabel.textColor = .white
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        badge.addSubview(badgeIcon)
        badge.addSubview(badgeLabel)
        addSubview(badge)
    }

    private func updateBadge(duration: TimeInterval?) {
        switch item.kind {
        case .image:
            badge.isHidden = true
        case .video:
            badge.isHidden = false
            badgeIcon.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
            badgeLabel.stringValue = duration.map(Thumbnails.formatDuration) ?? "Video"
        case .gif:
            badge.isHidden = false
            badgeIcon.image = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
            badgeLabel.stringValue = "GIF"
        }
        needsLayout = true
    }

    private func configureFeedback() {
        feedback.wantsLayer = true
        feedback.layer?.backgroundColor = NSColor(white: 1, alpha: 0.94).cgColor
        feedback.alphaValue = 0
        feedbackIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        feedbackIcon.contentTintColor = .systemGreen
        feedbackLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        feedbackLabel.textColor = NSColor(white: 0.1, alpha: 0.9)
        feedback.addSubview(feedbackIcon)
        feedback.addSubview(feedbackLabel)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let b = bounds
        backdrop.frame = b
        imageView.frame = b
        overlay.frame = b

        // CleanShot-style corners: close top-left, pin top-right, annotate/edit bottom-left;
        // Copy and Save stacked in the middle.
        let inset: CGFloat = 8
        let top = b.height - inset - 22
        closeButton.frame = NSRect(x: inset, y: top, width: 22, height: 22)
        pinButton?.frame = NSRect(x: b.width - inset - 22, y: top, width: 22, height: 22)
        editButton?.frame = NSRect(x: inset, y: inset, width: 22, height: 22)
        let pillW: CGFloat = 68, pillH: CGFloat = 24, gap: CGFloat = 6
        let fitsStacked = b.height >= 2 * pillH + gap + 2 * (22 + inset)
        if fitsStacked {
            let x = (b.width - pillW) / 2
            let y0 = (b.height - (2 * pillH + gap)) / 2
            saveButton.frame = NSRect(x: x, y: y0, width: pillW, height: pillH)
            copyButton.frame = NSRect(x: x, y: y0 + pillH + gap, width: pillW, height: pillH)
        } else {
            let rowWidth = pillW * 2 + gap
            let rowY = (b.height - pillH) / 2
            copyButton.frame = NSRect(x: (b.width - rowWidth) / 2, y: rowY, width: pillW, height: pillH)
            saveButton.frame = NSRect(x: copyButton.frame.maxX + gap, y: rowY, width: pillW, height: pillH)
        }
        let rowY = (b.height - pillH) / 2

        feedbackLabel.sizeToFit()
        let fw = 20 + feedbackLabel.frame.width + 12 + 10
        feedback.frame = NSRect(x: (b.width - fw) / 2, y: rowY - 1, width: fw, height: 26)
        feedback.layer?.cornerRadius = 13
        feedbackIcon.frame = NSRect(x: 8, y: 5, width: 16, height: 16)
        feedbackLabel.frame = NSRect(x: 28, y: (26 - feedbackLabel.frame.height) / 2,
                                     width: feedbackLabel.frame.width, height: feedbackLabel.frame.height)

        badgeLabel.sizeToFit()
        let bw = 8 + 10 + 4 + badgeLabel.frame.width + 8
        badge.frame = NSRect(x: b.width - 8 - bw, y: 8, width: bw, height: 18)
        badge.layer?.cornerRadius = 9
        badgeIcon.frame = NSRect(x: 8, y: 4, width: 10, height: 10)
        badgeLabel.frame = NSRect(x: 22, y: (18 - badgeLabel.frame.height) / 2,
                                  width: badgeLabel.frame.width, height: badgeLabel.frame.height)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.2)).cgColor
        }
    }

    // MARK: - Hover and feedback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        onHoverChanged?(value)
        // Keep the overlay up while a "Copied" confirmation is showing.
        guard flashWork == nil else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = value ? 1 : 0
        }
    }

    /// Short confirmation in place of the Copy/Save buttons.
    func flash(_ text: String) {
        flashWork?.cancel()
        feedbackLabel.stringValue = text
        needsLayout = true
        layoutSubtreeIfNeeded()
        overlay.animator().alphaValue = 1
        [copyButton, saveButton].forEach { $0.animator().alphaValue = 0 }
        feedback.animator().alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashWork = nil
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.feedback.animator().alphaValue = 0
                [self.copyButton, self.saveButton].forEach { $0.animator().alphaValue = 1 }
                self.overlay.animator().alphaValue = self.hovering ? 1 : 0
            }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    // MARK: - Mouse: double-click and drag out

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        if event.clickCount == 2 { onPrimaryEdit?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let p = event.locationInWindow
        guard hypot(p.x - origin.x, p.y - origin.y) > 4 else { return }
        dragOrigin = nil
        guard let url = dragURL?() else { NSSound.beep(); return }
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = imageView.image ?? NSImage(size: bounds.size)
        let frame = imageView.image == nil ? bounds : fittedImageRect(for: preview)
        dragItem.setDraggingFrame(frame, contents: preview)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    private func fittedImageRect(for image: NSImage) -> NSRect {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return bounds }
        let k = min(bounds.width / s.width, bounds.height / s.height)
        let size = NSSize(width: s.width * k, height: s.height * k)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragFinished?(operation != [])
    }
}
