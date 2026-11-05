import AVFoundation
import AppKit
import ApplicationServices

public enum RecordingFormat { case video, gif }

@MainActor
public final class RecordingController {
    public static let shared = RecordingController()

    private enum State { case idle, selecting, countdown, starting, recording, finishing }

    /// Everything that lives for one recording.
    private final class Session: @unchecked Sendable {
        let format: RecordingFormat
        let area: ScreenArea
        let screen: NSScreen
        let cocoaArea: CGRect
        let prefs: Snapshot
        var engine: RecordingEngine?
        var dimWindows: [DimWindow] = []
        var overlay: RecordingOverlayWindow?
        var controls: RecordingControlsHUD?
        var countdown: RecordingCountdownHUD?
        var input: InputMonitor?
        var timer: Timer?
        var clock = ElapsedClock()
        var tempURL: URL
        var cancelled = false

        init(format: RecordingFormat, area: ScreenArea, screen: NSScreen, cocoaArea: CGRect, prefs: Snapshot) {
            self.format = format
            self.area = area
            self.screen = screen
            self.cocoaArea = cocoaArea
            self.prefs = prefs
            tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Snapframe-recording-\(UUID().uuidString).mp4")
        }
    }

    /// Snapshot of the recording settings taken when a recording starts.
    struct Snapshot {
        var showControls = Prefs.bool(PrefKey.recShowControls)
        var menuBarTime = Prefs.bool(PrefKey.recMenuBarTime)
        var scaleTo1x = Prefs.bool(PrefKey.recScaleTo1x)
        var showCursor = Prefs.bool(PrefKey.recShowCursor)
        var highlightClicks = Prefs.bool(PrefKey.recHighlightClicks)
        var clickColor = NSColor(hex: Prefs.string(PrefKey.recClickColor)) ?? .systemYellow
        var showKeystrokes = Prefs.bool(PrefKey.recShowKeystrokes)
        var dimScreen = Prefs.bool(PrefKey.recDimScreen)
        var countdown = Prefs.bool(PrefKey.recCountdown)
        var codec: VideoCodec = Prefs.enumValue(PrefKey.recVideoCodec, .h264)
        var quality: VideoQuality = Prefs.enumValue(PrefKey.recVideoQuality, .high)
        var fps = max(1, Prefs.int(PrefKey.recVideoFPS))
        var systemAudio = Prefs.bool(PrefKey.recSystemAudio)
        var microphone = Prefs.bool(PrefKey.recMicrophone)
        var microphoneID = Prefs.string(PrefKey.recMicrophoneDeviceID)
        var gifFPS = max(1, Prefs.int(PrefKey.recGifFPS))
        var gifMaxWidth = max(0, Prefs.int(PrefKey.recGifMaxWidth)) // 0 = original size
    }

    private var state: State = .idle
    private var session: Session?

    /// True while any recording work is in progress, including area selection and GIF conversion.
    public var isBusy: Bool { state != .idle }

    /// True from the countdown until the recording is stopped.
    public var isRecording: Bool {
        switch state {
        case .countdown, .starting, .recording: return true
        default: return false
        }
    }

    // MARK: Public entry

    /// Starts (area selection → optional countdown → record) or stops the current recording.
    public func toggle(format: RecordingFormat) {
        switch state {
        case .idle:
            state = .selecting
            Task { await begin(format: format) }
        case .countdown:
            session?.cancelled = true // the countdown loop notices and tears down
        case .recording:
            Task { await finish(discard: false, failure: nil) }
        case .selecting, .starting, .finishing:
            break
        }
    }

    // MARK: Start

    private func begin(format: RecordingFormat) async {
        guard CapturePermission.ensure() else { state = .idle; return }
        let initial = Prefs.bool(PrefKey.recRememberSelection)
            ? RecordingMath.decodeArea(Prefs.string(PrefKey.lastRecordingArea)) : nil
        guard let selected = await AreaSelector.select(purpose: .recording, initial: initial),
              let screen = NSScreen.screens.first(where: { $0.displayID == selected.displayID }) else {
            state = .idle
            return
        }
        let rect = RecordingMath.normalized(selected.rect, displaySize: screen.frame.size)
        let area = ScreenArea(displayID: selected.displayID, rect: rect)
        Prefs.set(RecordingMath.encode(area), PrefKey.lastRecordingArea)
        await start(format: format, area: area, screen: screen)
    }

    private func start(format: RecordingFormat, area: ScreenArea, screen: NSScreen) async {
        var prefs = Snapshot()
        if format == .gif { prefs.systemAudio = false; prefs.microphone = false }
        if prefs.showKeystrokes, !(await resolveAccessibility()) { prefs.showKeystrokes = false }
        if prefs.microphone, !(await resolveMicrophone()) { prefs.microphone = false }

        let cocoa = RecordingMath.cocoaRect(area.rect, screenFrame: screen.frame)
        let s = Session(format: format, area: area, screen: screen, cocoaArea: cocoa, prefs: prefs)
        session = s
        state = .countdown

        if prefs.dimScreen {
            s.dimWindows = NSScreen.screens.map { DimWindow(screen: $0, hole: $0 == screen ? cocoa : nil) }
        }
        if prefs.highlightClicks || prefs.showKeystrokes {
            s.overlay = RecordingOverlayWindow(screen: screen, area: cocoa)
        }

        if prefs.countdown {
            let hud = RecordingCountdownHUD(center: CGPoint(x: cocoa.midX, y: cocoa.midY))
            s.countdown = hud
            for n in stride(from: 3, through: 1, by: -1) {
                hud.show(n)
                try? await Task.sleep(for: .seconds(1))
                if s.cancelled { teardown(s); return }
            }
            hud.close()
            s.countdown = nil
            try? await Task.sleep(for: .milliseconds(80)) // let the HUD leave the screen
        }
        if s.cancelled { teardown(s); return }

        state = .starting
        let engine = RecordingEngine(config: engineConfig(for: s), outputURL: s.tempURL)
        // Weak: the session owns the engine, so a strong capture would leak both.
        engine.onUnexpectedStop = { [weak self, weak s] error in
            Task { @MainActor in
                guard let self, let s, self.state == .recording, self.session === s else { return }
                await self.finish(discard: false, failure: error)
            }
        }
        s.engine = engine
        let hasSnapframeWindows = prefs.showControls || !s.dimWindows.isEmpty || s.overlay != nil
        do {
            try await engine.start(includedWindowIDs: s.overlay.map { [CGWindowID($0.windowNumber)] } ?? [],
                                   requireOwnApp: hasSnapframeWindows)
        } catch {
            teardown(s)
            showError("Recording could not start", error)
            return
        }
        if s.cancelled { await engine.cancel(); teardown(s); return }
        begin(running: s)
    }

    private func engineConfig(for s: Session) -> RecordingEngine.Config {
        let p = s.prefs
        let native = s.screen.backingScaleFactor
        var cfg = RecordingEngine.Config(area: s.area, backingScale: native, scaleTo1x: p.scaleTo1x, fps: p.fps,
                                         codec: p.codec, quality: p.quality, showCursor: p.showCursor,
                                         systemAudio: p.systemAudio, microphone: p.microphone,
                                         microphoneDeviceID: p.microphoneID, scaleOverride: nil)
        if s.format == .gif {
            cfg.fps = p.gifFPS
            cfg.codec = .h264
            cfg.quality = .high
            cfg.scaleOverride = p.scaleTo1x ? 1 : RecordingMath.gifCaptureScale(pointWidth: s.area.rect.width,
                                                                                nativeScale: native, maxWidth: p.gifMaxWidth)
        }
        return cfg
    }

    private func begin(running s: Session) {
        let p = s.prefs
        s.clock.start(at: Date())
        state = .recording

        if p.showControls {
            let hud = RecordingControlsHUD(showsMicrophone: p.microphone)
            hud.onStop = { [weak self] in self?.toggle(format: s.format) }
            hud.onPauseToggle = { [weak self] in self?.togglePause() }
            hud.onRestart = { [weak self] in self?.confirmThen(title: "Restart recording?", button: "Restart") { await self?.restart() } }
            hud.onCancel = { [weak self] in self?.confirmThen(title: "Discard recording?", button: "Discard") { await self?.finish(discard: true, failure: nil) } }
            let frame = RecordingMath.hudFrame(size: hud.frame.size, around: s.cocoaArea, in: s.screen.visibleFrame)
            hud.setFrame(frame, display: true)
            hud.orderFrontRegardless()
            s.controls = hud
        }

        if let overlay = s.overlay {
            let monitor = InputMonitor(area: s.cocoaArea, excluding: { [weak s] in s?.controls?.frame })
            monitor.start(clicks: p.highlightClicks ? { point in overlay.ring(atGlobal: point, color: p.clickColor) } : nil,
                          keys: p.showKeystrokes ? { text in overlay.showKeys(text) } : nil)
            s.input = monitor
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self, weak s] _ in
            MainActor.assumeIsolated { if let self, let s { self.tick(s) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        s.timer = timer
        tick(s)
    }

    private func tick(_ s: Session) {
        let text = RecordingMath.formatElapsed(s.clock.elapsed(at: Date()))
        s.controls?.setElapsed(text)
        if s.prefs.menuBarTime { MenuBarStatus.setTitle(text) }
    }

    // MARK: Pause / restart / stop

    private func togglePause() {
        guard state == .recording, let s = session, let engine = s.engine else { return }
        if s.clock.isPaused {
            engine.resume()
            s.clock.resume(at: Date())
        } else {
            engine.pause()
            s.clock.pause(at: Date())
        }
        s.controls?.setPaused(s.clock.isPaused)
        tick(s)
    }

    private func confirmThen(title: String, button: String, _ action: @escaping () async -> Void) {
        guard state == .recording, let s = session else { return }
        if s.clock.elapsed(at: Date()) >= 5 {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = "The recording so far will be deleted."
            alert.alertStyle = .warning
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Keep Recording")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await action() }
    }

    private func restart() async {
        guard state == .recording, let s = session else { return }
        state = .finishing
        let area = s.area, screen = s.screen, format = s.format
        let engine = s.engine
        teardown(s, keepState: true)
        await engine?.cancel()
        state = .starting
        await start(format: format, area: area, screen: screen)
    }

    private func finish(discard: Bool, failure: Error?) async {
        guard state == .recording, let s = session else { return }
        state = .finishing
        let engine = s.engine
        let format = s.format
        let screen = s.screen
        let scale = s.screen.backingScaleFactor
        let pointWidth = s.area.rect.width
        let prefs = s.prefs
        teardown(s, keepState: true)

        guard let engine else { reset(); return }
        if discard {
            await engine.cancel()
            reset()
            return
        }
        do {
            let output = try await engine.stop()
            if let failure {
                showError("Recording stopped unexpectedly", failure, extra: "The part recorded so far was saved.")
            }
            if format == .video, prefs.systemAudio, prefs.microphone {
                // Best effort: on failure the file keeps its two audio tracks.
                do { try await AudioTrackMixer.mergeAudioTracks(in: output.url) }
                catch { NSLog("Snapframe: audio mix failed: \(error)") }
            }
            var url = output.url
            var kind = MediaKind.video
            var pixelSize = output.pixelSize
            if format == .gif {
                let panel = ConvertingPanel(screen: screen)
                defer { panel.close() }
                let gifURL = FileManager.default.temporaryDirectory.appendingPathComponent("Snapframe-recording-\(UUID().uuidString).gif")
                let result = try await GIFConverter.convert(videoURL: output.url, to: gifURL, fps: prefs.gifFPS,
                                                            maxWidth: prefs.gifMaxWidth,
                                                            progress: { value in Task { @MainActor in panel.setProgress(value) } })
                try? FileManager.default.removeItem(at: output.url)
                url = result.url
                kind = .gif
                pixelSize = result.pixelSize
            }
            let itemScale = max(1, pointWidth > 0 ? pixelSize.width / pointWidth : scale)
            let item = try ItemFactory.makeMediaItem(movedFrom: url, kind: kind, pixelSize: pixelSize, scale: itemScale)
            reset()
            AfterCapture.handle(item)
        } catch {
            reset()
            if let failure {
                showError("Recording stopped unexpectedly", failure, extra: "The recording could not be saved.")
            } else {
                showError("Recording failed", error)
            }
        }
    }

    // MARK: Cleanup

    /// Closes every window and timer of the session. Idempotent.
    private func teardown(_ s: Session, keepState: Bool = false) {
        s.timer?.invalidate()
        s.timer = nil
        s.input?.stop()
        s.input = nil
        s.controls?.close()
        s.controls = nil
        s.countdown?.close()
        s.countdown = nil
        s.overlay?.close()
        s.overlay = nil
        s.dimWindows.forEach { $0.close() }
        s.dimWindows = []
        MenuBarStatus.setTitle(nil)
        if !keepState {
            if session === s { session = nil }
            state = .idle
            try? FileManager.default.removeItem(at: s.tempURL)
        }
    }

    private func reset() {
        if let s = session { try? FileManager.default.removeItem(at: s.tempURL) }
        session = nil
        state = .idle
    }

    private func showError(_ title: String, _ error: Error, extra: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = [error.localizedDescription, extra].compactMap { $0 }.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Permissions

    /// Keystrokes need Accessibility. Explains once and offers the settings pane; returns whether to show keystrokes.
    private func resolveAccessibility() async -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = "state.keystrokesAXExplained"
        guard !Prefs.store.bool(forKey: key) else { return false }
        Prefs.store.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keystrokes need Accessibility access"
        alert.informativeText = "To show pressed keys in recordings, allow Snapframe in System Settings › Privacy & Security › Accessibility. This recording will continue without keystrokes."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Continue Without")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func resolveMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Microphone access is off"
            alert.informativeText = "Allow Snapframe in System Settings › Privacy & Security › Microphone to record your voice. This recording will continue without it."
            alert.addButton(withTitle: "Open Microphone Settings")
            alert.addButton(withTitle: "Continue Without")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }
}
