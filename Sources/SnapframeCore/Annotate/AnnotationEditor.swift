import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public enum AnnotationEditor {
    private static var controllers: [EditorWindowController] = []

    /// True while any editor window has unsaved changes (checked before quitting to install an update).
    static var hasUnsavedChanges: Bool { controllers.contains { $0.state.hasUnsavedChanges } }

    static var openItemIDs: Set<UUID> { Set(controllers.map { $0.item.id }) }

    /// Opens the editor window for a captured image. Saving writes the flattened image back to
    /// item.fileURL and posts .snapframeItemUpdated.
    public static func open(_ item: CapturedItem) {
        guard item.kind == .image else { NSSound.beep(); return }
        if let existing = controllers.first(where: {
            $0.item.id == item.id || $0.item.fileURL.standardizedFileURL == item.fileURL.standardizedFileURL
        }) {
            if existing.window.isMiniaturized { existing.window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let controller = EditorWindowController(item: item, index: controllers.count) else {
            NSSound.beep()
            return
        }
        controllers.append(controller)
        controller.show()
    }

    public static func open(fileURL: URL) {
        if let item = ItemFactory.itemForExternalFile(fileURL) { open(item) }
    }

    fileprivate static func closed(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
    }
}

/// Window that routes unmodified keys (tool shortcuts, delete, arrows) and menu-less ⌘ shortcuts
/// to the controller, since an accessory app has no main menu.
final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let doc = documentView {
            if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
            if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        }
        return rect
    }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private static let backgroundOpenKey = "ann.state.backgroundOpen"
    private static let chromeHeight: CGFloat = 44 + 1 + 38 + 1

    private(set) var item: CapturedItem
    let state: EditorState
    let window: EditorWindow
    private let canvas: AnnotationCanvasView
    private let scroll = NSScrollView()
    private let sidebar: NSHostingView<BackgroundSidebar>
    private var sidebarWidth: NSLayoutConstraint!
    private var cancellables: Set<AnyCancellable> = []
    private var lastTool: EditorTool = .arrow
    private var forceClose = false
    private var counted = false
    private var fitMagnification: CGFloat = 1
    private var magnificationBeforeBackground: CGFloat?
    private let showColorNames = Prefs.bool(PrefKey.annShowColorNames)

    init?(item: CapturedItem, index: Int) {
        guard let image = Self.loadBaseImage(item.fileURL) else { return nil }
        self.item = item
        let doc = AnnotationDocument(baseImage: image, scale: item.scale,
                                     autoExpandCanvas: Prefs.bool(PrefKey.annAutoExpandCanvas),
                                     objectShadow: Prefs.bool(PrefKey.annObjectShadow))
        state = EditorState(doc: doc)
        canvas = AnnotationCanvasView(state: state)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        var actions = EditorActions()
        sidebar = NSHostingView(rootView: BackgroundSidebar(state: state, actions: actions))
        super.init()

        actions.undo = { [weak self] in self?.undo() }
        actions.redo = { [weak self] in self?.redo() }
        actions.copy = { [weak self] in self?.copyImage() }
        actions.save = { [weak self] in self?.save() }
        actions.saveAs = { [weak self] in self?.saveAs() }
        actions.done = { [weak self] in self?.done() }
        actions.zoomIn = { [weak self] in self?.zoom(by: 1) }
        actions.zoomOut = { [weak self] in self?.zoom(by: -1) }
        actions.zoomFit = { [weak self] in self?.setMagnification(self?.fitMagnification ?? 1) }
        actions.zoomActual = { [weak self] in self?.setMagnification(1) }
        actions.applyCrop = { [weak self] in self?.canvas.applyCrop() }
        actions.cancelCrop = { [weak self] in self?.canvas.cancelCrop() }
        actions.chooseBackgroundImage = { [weak self] in self?.chooseBackgroundImage() }
        actions.saveBackgroundPreset = { [weak self] in self?.saveBackgroundPreset() }
        sidebar.rootView = BackgroundSidebar(state: state, actions: actions)
        buildWindow(actions: actions, index: index)
    }

    // MARK: Window construction

    private func buildWindow(actions: EditorActions, index: Int) {
        window.title = item.baseName
        window.representedURL = item.fileURL
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        window.level = Prefs.bool(PrefKey.annAlwaysOnTop) ? .floating : .normal
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 420)

        let chrome = NSHostingView(rootView: EditorToolbar(state: state, actions: actions, showColorNames: showColorNames))
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor

        let content = NSView()
        for v in [chrome, scroll, sidebar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: content.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sidebarWidth,
        ])
        window.contentView = content
        sidebar.isHidden = true

        // Size to the image, capped at 85% of the screen.
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let imgSize = state.doc.imageSize
        let margin: CGFloat = 40
        let maxW = screen.width * 0.85, maxH = screen.height * 0.85
        let chromeH = EditorWindowController.chromeHeight + (showColorNames ? 10 : 0)
        fitMagnification = min(1, (maxW - margin) / imgSize.width, (maxH - chromeH - margin) / imgSize.height)
        let contentW = max(720, imgSize.width * fitMagnification + margin)
        let contentH = max(420, imgSize.height * fitMagnification + margin + chromeH)
        window.setContentSize(NSSize(width: contentW, height: contentH))
        window.center()
        if index > 0 {
            let o = window.frame.origin
            window.setFrameOrigin(NSPoint(x: o.x + CGFloat(index % 6) * 26, y: o.y - CGFloat(index % 6) * 26))
        }

        state.onChange = { [weak self] in self?.stateChanged() }
        state.$tool.dropFirst().sink { [weak self] tool in self?.toolWillChange(to: tool) }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
            .sink { [weak self] _ in self?.updateZoomLabel() }.store(in: &cancellables)

        if Prefs.bool(PrefKey.annRememberBackgroundTool), Prefs.bool(Self.backgroundOpenKey) {
            state.tool = .background
            toolWillChange(to: .background)
        }
        lastTool = state.tool
    }

    func show() {
        DockIcon.windowOpened()
        counted = true
        window.makeKeyAndOrderFront(nil)
        scroll.magnification = fitMagnification
        updateZoomLabel()
        canvas.syncLayout()
        recenter()
        window.makeFirstResponder(canvas)
    }

    /// Lays the window out exactly as `show()` does, without ordering it on screen (README renderer).
    func layoutOffscreen() {
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.magnification = fitMagnification
        updateZoomLabel()
        canvas.syncLayout()
        recenter()
    }

    // MARK: State plumbing

    private func stateChanged() {
        canvas.syncLayout()
        recenter()
        window.isDocumentEdited = state.hasUnsavedChanges
    }

    private func recenter() {
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Fired before `state.tool` holds the new value.
    private func toolWillChange(to tool: EditorTool) {
        let old = lastTool
        lastTool = tool
        canvas.commitTextEditing()
        if tool != .select { state.selection = nil }
        if old == .crop && tool != .crop { state.cropDraft = nil }
        if tool == .crop { state.cropDraft = state.doc.cropRect }
        if old == .background && tool != .background { state.leaveBackgroundTool() }
        if tool == .background && old != .background { state.enterBackgroundTool() }
        if (tool == .background) != (old == .background), Prefs.bool(PrefKey.annRememberBackgroundTool) {
            Prefs.set(tool == .background, Self.backgroundOpenKey)
        }
        window.isDocumentEdited = state.hasUnsavedChanges
        sidebar.isHidden = tool != .background
        sidebarWidth.constant = tool == .background ? 280 : 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.canvas.syncLayout()
            if tool == .background, old != .background {
                self.magnificationBeforeBackground = self.scroll.magnification
                self.window.contentView?.layoutSubtreeIfNeeded()
                let vp = self.scroll.contentSize, size = self.canvas.frame.size
                if size.width > 0, size.height > 0 {
                    self.setMagnification(min(1, (vp.width - 40) / size.width, (vp.height - 40) / size.height))
                }
            } else if old == .background, tool != .background, let m = self.magnificationBeforeBackground {
                self.magnificationBeforeBackground = nil
                self.setMagnification(m)
            }
            self.recenter()
            self.window.invalidateCursorRects(for: self.canvas)
            self.window.makeFirstResponder(self.canvas)
        }
    }

    // MARK: Zoom

    private static let zoomSteps: [CGFloat] = [0.1, 0.17, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]

    private func zoom(by direction: Int) {
        let m = scroll.magnification
        if direction > 0 { setMagnification(Self.zoomSteps.first { $0 > m + 0.005 } ?? 8) }
        else { setMagnification(Self.zoomSteps.last { $0 < m - 0.005 } ?? 0.1) }
    }

    private func setMagnification(_ m: CGFloat) {
        let clip = scroll.contentView
        let center = CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scroll.setMagnification(min(8, max(0.1, m)), centeredAt: center)
        recenter()
        updateZoomLabel()
    }

    private func updateZoomLabel() { state.zoomPercent = Int((scroll.magnification * 100).rounded()) }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers ?? ""
        let editingText = window.firstResponder is NSTextView
        if flags.contains(.command) {
            switch (chars.lowercased(), flags.contains(.shift)) {
            case ("s", false): save(); return true
            case ("s", true): saveAs(); return true
            case ("w", _): window.performClose(nil); return true
            case ("=", _), ("+", _): zoom(by: 1); return true
            case ("-", _): zoom(by: -1); return true
            case ("0", _): setMagnification(fitMagnification); return true
            case ("1", _): setMagnification(1); return true
            default: break
            }
            if editingText { return false }
            switch (chars.lowercased(), flags.contains(.shift)) {
            case ("z", false): undo(); return true
            case ("z", true): redo(); return true
            case ("c", false): copyImage(); return true
            default: return false
            }
        }
        if editingText || flags.contains(.control) || flags.contains(.option) { return false }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            canvas.deleteSelection(); return true
        case 36, 76: // return, enter
            if state.tool == .crop { canvas.applyCrop(); return true }
            return false
        case 53: // escape
            if state.tool == .crop { canvas.cancelCrop() } else { state.selection = nil; state.refresh() }
            return true
        case 123, 124, 125, 126:
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: canvas.nudgeSelection(dx: -step, dy: 0)
            case 124: canvas.nudgeSelection(dx: step, dy: 0)
            case 125: canvas.nudgeSelection(dx: 0, dy: step)
            default: canvas.nudgeSelection(dx: 0, dy: -step)
            }
            return state.selection != nil
        default: break
        }
        if flags.subtracting(.shift).isEmpty, let ch = chars.lowercased().first,
           let tool = EditorTool.allCases.first(where: { $0.key == ch }) {
            state.tool = tool
            return true
        }
        return false
    }

    // MARK: Actions

    private func undo() { canvas.commitTextEditing(); state.undo() }
    private func redo() { canvas.commitTextEditing(); state.redo() }

    private func renderFinal() -> CGImage {
        canvas.commitTextEditing()
        if state.tool == .crop, state.cropDraft != nil { canvas.applyCrop() }
        return state.doc.render()
    }

    private func copyImage() {
        let image = renderFinal()
        let scale = state.doc.scale
        let ns = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([ns])
        if let png = ImageIOWriter.pngData(image) { pb.setData(png, forType: .png) }
    }

    @discardableResult
    private func save() -> Bool {
        guard Self.canOverwrite(item.fileURL) else {
            saveAs(markSaved: true)
            return false
        }
        let image = renderFinal()
        var updated = HistoryStore.shared.items.first { $0.id == item.id } ?? item
        do {
            try Self.write(image, to: item.fileURL)
        } catch {
            NSLog("%@", "Snapframe: annotation save failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Could not save the image"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
            return false
        }
        updated.pixelSize = CGSize(width: image.width, height: image.height)
        item = updated
        HistoryStore.shared.update(updated)
        NotificationCenter.default.post(name: .snapframeItemUpdated, object: updated)
        state.markSaved()
        window.isDocumentEdited = false
        Exporter.syncCopiesReportingFailure(of: updated)
        return true
    }

    /// `markSaved` is for a save that could not overwrite the original in place and was redirected here.
    private func saveAs(markSaved: Bool = false) {
        let image = renderFinal()
        let panel = NSSavePanel()
        if Self.canOverwrite(item.fileURL) {
            panel.nameFieldStringValue = item.exportFileName
            panel.directoryURL = item.savedURL?.deletingLastPathComponent() ?? Prefs.exportDirectory
            if let type = UTType(filenameExtension: item.fileExtension) { panel.allowedContentTypes = [type] }
        } else {
            panel.nameFieldStringValue = item.fileURL.deletingPathExtension().lastPathComponent + ".png"
            panel.directoryURL = item.fileURL.deletingLastPathComponent()
            panel.allowedContentTypes = [.png]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.write(image, to: url)
                if markSaved, let self {
                    self.state.markSaved()
                    self.window.isDocumentEdited = false
                }
            } catch {
                NSLog("%@", "Snapframe: save as failed: \(error)")
                NSSound.beep()
            }
        }
    }

    private func done() {
        if state.hasUnsavedChanges {
            guard save() else { return }
        }
        forceClose = true
        window.close()
    }

    /// Decodes frame 0 upright; ImageIO applies the EXIF orientation only through the thumbnail path.
    static func loadBaseImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let orientation = props?[kCGImagePropertyOrientation] as? Int, orientation > 1,
           let w = props?[kCGImagePropertyPixelWidth] as? Int, let h = props?[kCGImagePropertyPixelHeight] as? Int {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let upright = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) { return upright }
        }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// ImageIO has no encoder for every type it can decode (webp, avif, dng).
    static func canEncode(_ type: UTType) -> Bool {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ids.contains(type.identifier)
    }

    /// False when saving over `url` would change its format or drop frames.
    static func canOverwrite(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), canEncode(type) else { return false }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return true }
        return CGImageSourceGetCount(src) <= 1
    }

    /// Writes in the format implied by the extension; throws if ImageIO cannot encode it. JPEG is flattened on white.
    static func write(_ image: CGImage, to url: URL) throws {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), canEncode(type) else {
            throw ImageIOWriter.WriteError.cannotCreate
        }
        var out = image
        if type == .jpeg, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            out = ctx.makeImage() ?? image
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageIOWriter.WriteError.cannotCreate
        }
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, out, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageIOWriter.WriteError.cannotFinalize }
    }

    // MARK: Background helpers

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.state.updateBackground(tag: "bgimage") { $0.fill = .image(path: url.path) }
        }
    }

    private func saveBackgroundPreset() {
        guard var style = state.background else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Preset name"
        let alert = NSAlert()
        alert.messageText = "Save background preset"
        alert.informativeText = "Name this look to reuse it later."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            style.id = UUID().uuidString
            style.name = name.isEmpty ? "Custom" : name
            BackgroundStyle.savePresets(BackgroundStyle.loadPresets() + [style])
            NotificationCenter.default.post(name: .snapframeBackgroundPresetsChanged, object: nil)
        }
        window.makeFirstResponder(field)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitTextEditing()
        if forceClose || !state.hasUnsavedChanges { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \u{201C}\(item.baseName)\u{201D}?"
        alert.informativeText = "Your annotations will be lost if you don\u{2019}t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don\u{2019}t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.save() { self.forceClose = true; self.window.close() }
            case .alertSecondButtonReturn:
                self.forceClose = true
                self.window.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if counted { DockIcon.windowClosed(); counted = false }
        state.onChange = nil
        cancellables.removeAll()
        window.delegate = nil
        AnnotationEditor.closed(self)
    }
}
