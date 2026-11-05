import AVFoundation
import AppKit

@MainActor
public enum VideoEditor {
    private static var windows: [UUID: VideoEditorWindow] = [:]

    /// Opens the trim editor for a video or GIF; saving writes back to item.fileURL and posts .snapframeItemUpdated.
    public static func open(_ item: CapturedItem) {
        guard item.kind != .image else { return }
        if let existing = windows[item.id] {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = VideoEditorWindow(item: item)
        windows[item.id] = window
        window.onClose = { windows[item.id] = nil }
        window.center()
        DockIcon.windowOpened()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }
}

private enum EditorError: LocalizedError {
    case empty
    var errorDescription: String? { "The file has no playable content." }
}

@MainActor
final class VideoEditorWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let item: CapturedItem
    let media: EditorMedia
    let timeline = TrimTimeline()
    private let muteButton = NSButton()
    private let gifButton = NSButton()
    private let cancelButton = NSButton()
    private let saveButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var busy = false
    private var loaded = false
    private var resumeAfterDrag = false
    private var closed = false

    private var isVideo: Bool { item.kind == .video }
    private var selection: TrimSelection { timeline.selection }

    init(item: CapturedItem) {
        self.item = item
        media = item.kind == .video ? VideoMedia(url: item.fileURL) : GIFMedia(url: item.fileURL)

        let screen = NSScreen.underMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let barHeight: CGFloat = 52
        let timelineHeight: CGFloat = 76
        let chrome = barHeight + timelineHeight + 12
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8 - chrome)
        let natural = item.pointSize.width > 0 ? item.pointSize : CGSize(width: 800, height: 450)
        let fit = min(1, maxSize.width / natural.width, maxSize.height / natural.height)
        let content = CGSize(width: max(560, (natural.width * fit).rounded()),
                             height: max(320, (natural.height * fit).rounded()) + chrome)
        super.init(contentRect: CGRect(origin: .zero, size: content),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = item.baseName
        isReleasedWhenClosed = false
        minSize = CGSize(width: 520, height: 400)
        delegate = self
        setFrameAutosaveName("")

        let root = NSView()
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active

        configure(muteButton, "Mute", symbol: "speaker.slash", action: #selector(muteTapped))
        muteButton.setButtonType(.pushOnPushOff)
        configure(gifButton, "Export GIF", symbol: "photo.stack", action: #selector(gifTapped))
        configure(cancelButton, "Cancel", symbol: nil, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        configure(saveButton, "Save", symbol: nil, action: #selector(saveTapped))
        saveButton.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: isVideo ? [muteButton, status, spacer, spinner, gifButton, cancelButton, saveButton]
                                               : [status, spacer, spinner, cancelButton, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        let mediaView = media.view
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        timeline.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mediaView)
        root.addSubview(timeline)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            mediaView.topAnchor.constraint(equalTo: root.topAnchor),
            mediaView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mediaView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mediaView.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -8),
            timeline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            timeline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            timeline.heightAnchor.constraint(equalToConstant: timelineHeight),
            timeline.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        contentView = root

        muteButton.isHidden = true
        gifButton.isEnabled = false
        saveButton.isEnabled = false
        wireTimeline()
        makeFirstResponder(timeline)
        Task { [weak self] in await self?.prepare() }
    }

    private func prepare() async {
        do {
            let initial = try await media.load()
            guard !closed else { return }
            guard initial.duration > 0 else { throw EditorError.empty }
            timeline.configure(initial)
            muteButton.isHidden = !media.hasAudio
            loaded = true
            saveButton.isEnabled = !busy
            gifButton.isEnabled = !busy
            applyLoop()
            media.play()
            let thumbs = await media.thumbnails(count: 14)
            if !closed { timeline.setThumbnails(thumbs) }
        } catch {
            if !closed { showFailure("Could not open the \(isVideo ? "video" : "GIF")", error) }
        }
    }

    private func wireTimeline() {
        timeline.onScrub = { [weak self] t in self?.media.seek(to: t) }
        timeline.onSelectionChanged = { [weak self] _ in self?.selectionChanged() }
        timeline.onTogglePlay = { [weak self] in self?.togglePlay() }
        timeline.onInteraction = { [weak self] began in
            guard let self else { return }
            if began {
                self.resumeAfterDrag = self.media.isPlaying
                self.media.pause()
            } else if self.resumeAfterDrag {
                self.playWithinSelection()
            }
        }
        media.onTick = { [weak self] t in self?.timeline.setPlayhead(t) }
    }

    private func applyLoop() {
        media.loop = selection.start...selection.end
    }

    private func selectionChanged() {
        applyLoop()
        timeline.needsDisplay = true
        let t = timeline.playhead
        if t < selection.start || t > selection.end {
            timeline.setPlayhead(selection.start)
            media.seek(to: selection.start)
        } else {
            media.seek(to: t)
        }
    }

    private func togglePlay() {
        guard loaded else { return }
        if media.isPlaying { media.pause() } else { playWithinSelection() }
    }

    private func playWithinSelection() {
        let t = timeline.playhead
        if t < selection.start || t >= selection.end - 0.01 {
            timeline.setPlayhead(selection.start)
            media.seek(to: selection.start)
        }
        media.play()
    }

    override func keyDown(with event: NSEvent) {
        if !timeline.handleKey(event) { super.keyDown(with: event) }
    }

    private func configure(_ b: NSButton, _ title: String, symbol: String?, action: Selector) {
        b.title = title
        b.bezelStyle = .rounded
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
        }
        b.target = self
        b.action = action
    }

    // MARK: Trim state

    /// The selected range for video, nil when it covers (almost) the whole clip.
    private var videoRange: CMTimeRange? {
        guard !selection.isFull(tolerance: 0.05) else { return nil }
        return CMTimeRange(start: CMTime(seconds: selection.start, preferredTimescale: 600),
                           end: CMTime(seconds: selection.end, preferredTimescale: 600))
    }

    // MARK: Actions

    @objc private func muteTapped() {
        media.muted = muteButton.state == .on
        muteButton.image = NSImage(systemSymbolName: media.muted ? "speaker.slash.fill" : "speaker.slash", accessibilityDescription: "Mute")
    }

    @objc private func cancelTapped() { close() }

    @objc private func saveTapped() {
        guard !busy, loaded else { return }
        let mute = media.muted
        let trimmed = isVideo ? videoRange != nil : !selection.isFull(tolerance: 0.001)
        if !trimmed && !mute { close(); return }
        media.pause()
        setBusy(true, "Saving…")
        let url = item.fileURL
        let temp = url.deletingLastPathComponent().appendingPathComponent(".edit-\(UUID().uuidString).\(url.pathExtension)")
        let range = videoRange
        let (start, end) = (selection.start, selection.end)
        Task {
            var gifSize: CGSize?
            do {
                if isVideo {
                    try await VideoTrimmer.export(url: url, range: range, mute: mute, to: temp)
                } else {
                    let info = try await Task.detached { try GIFTrimmer.trim(url: url, start: start, end: end, to: temp) }.value
                    gifSize = info.pixelSize
                }
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                var updated = HistoryStore.shared.items.first { $0.id == item.id } ?? item
                if let gifSize { updated.pixelSize = gifSize }
                HistoryStore.shared.update(updated)
                NotificationCenter.default.post(name: .snapframeItemUpdated, object: updated)
                setBusy(false, "")
                close()
            } catch {
                try? FileManager.default.removeItem(at: temp)
                setBusy(false, "")
                showFailure("Could not save the \(isVideo ? "video" : "GIF")", error)
            }
        }
    }

    @objc private func gifTapped() {
        guard !busy, loaded else { return }
        media.pause()
        setBusy(true, "Creating GIF…")
        let range = videoRange
        let source = item
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Snapframe-edit-\(UUID().uuidString).gif")
        Task {
            do {
                let result = try await GIFConverter.convert(videoURL: source.fileURL, to: temp,
                                                            fps: max(1, Prefs.int(PrefKey.recGifFPS)),
                                                            maxWidth: max(0, Prefs.int(PrefKey.recGifMaxWidth)), range: range)
                let pointWidth = source.pointSize.width
                let scale = max(1, pointWidth > 0 ? result.pixelSize.width / pointWidth : 1)
                let gif = try ItemFactory.makeMediaItem(movedFrom: result.url, kind: .gif, pixelSize: result.pixelSize, scale: scale)
                setBusy(false, "")
                deliver(gif)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                setBusy(false, "")
                showFailure("Could not create the GIF", error)
            }
        }
    }

    /// After-recording actions for a derived item, without re-opening an editor.
    private func deliver(_ gif: CapturedItem) {
        NotificationCenter.default.post(name: .snapframeItemCreated, object: gif)
        var current = gif
        if Prefs.bool(PrefKey.afterRecCopy) { Clipboard.copy(current) }
        if Prefs.bool(PrefKey.afterRecSave), let url = Exporter.save(current) { current.savedURL = url }
        if Prefs.bool(PrefKey.afterRecQuickAccess) { QuickAccessController.shared.show(current) }
        status.stringValue = "GIF created"
    }

    private func setBusy(_ value: Bool, _ text: String) {
        busy = value
        [muteButton, gifButton, saveButton].forEach { $0.isEnabled = !value && loaded }
        cancelButton.isEnabled = !value
        status.stringValue = text
        value ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func showFailure(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }

    func windowWillClose(_ notification: Notification) {
        closed = true
        media.teardown()
        DockIcon.windowClosed()
        onClose?()
    }
}
