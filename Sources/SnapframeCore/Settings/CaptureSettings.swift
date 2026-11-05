import AppKit
import AVFoundation
import SwiftUI

// MARK: - Option tables (kept as data so the UI and tests agree)

enum SettingsOptions {
    /// Auto-close intervals in seconds, with their menu titles.
    static let autoCloseIntervals: [(seconds: Int, title: String)] = [
        (5, "5 s"), (10, "10 s"), (15, "15 s"), (30, "30 s"), (60, "1 min"), (120, "2 min"), (300, "5 min"),
    ]
    static let gifWidths: [(width: Int, title: String)] = [
        (640, "640 px"), (800, "800 px"), (1024, "1024 px"), (1280, "1280 px"), (0, "Original"),
    ]
    static let selfTimerSeconds = [3, 5, 10]
    static let gifFrameRates = [10, 15, 20, 30]
    static let videoFrameRates = [30, 60]
}

// MARK: - Quick Access

struct QuickAccessTab: View {
    @AppStorage(PrefKey.qaPosition, store: Prefs.store) private var position = QuickAccessPosition.left
    @AppStorage(PrefKey.qaMoveToActiveScreen, store: Prefs.store) private var moveToActive = true
    @AppStorage(PrefKey.qaOverlaySize, store: Prefs.store) private var size = 2
    @AppStorage(PrefKey.qaAutoClose, store: Prefs.store) private var autoClose = false
    @AppStorage(PrefKey.qaAutoCloseAction, store: Prefs.store) private var autoCloseAction = AutoCloseAction.saveAndClose
    @AppStorage(PrefKey.qaAutoCloseInterval, store: Prefs.store) private var interval = 30
    @AppStorage(PrefKey.qaCloseAfterDragging, store: Prefs.store) private var closeAfterDrag = true
    @AppStorage(PrefKey.qaSaveBehavior, store: Prefs.store) private var saveBehavior = SaveBehavior.exportLocation

    var body: some View {
        SettingsPage {
            SettingsRow("Position") {
                Picker("Position", selection: $position) {
                    Text("Left").tag(QuickAccessPosition.left)
                    Text("Right").tag(QuickAccessPosition.right)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            SettingsRow("Multi-display") {
                Toggle("Move to active screen", isOn: $moveToActive)
            }
            SettingsRow("Overlay size") {
                TickSlider(value: $size, maxValue: 4, captions: [0: "Small", 4: "Large"], width: 200)
            }
            SettingsDivider()
            SettingsRow("Auto-close") {
                Toggle("Enable", isOn: $autoClose)
            }
            SettingsRow("Action") {
                Picker("Action", selection: $autoCloseAction) {
                    Text("Save and Close").tag(AutoCloseAction.saveAndClose)
                    Text("Close").tag(AutoCloseAction.close)
                }
                .popup().disabled(!autoClose)
            }
            SettingsRow("Interval") {
                Picker("Interval", selection: $interval) {
                    ForEach(SettingsOptions.autoCloseIntervals, id: \.seconds) { Text($0.title).tag($0.seconds) }
                }
                .popup().disabled(!autoClose)
            }
            SettingsDivider()
            SettingsRow("Drag & drop") {
                Toggle("Close after dragging", isOn: $closeAfterDrag)
                HelpText("Close the overlay after you drag a screenshot or recording out of it.")
            }
            SettingsDivider()
            SettingsRow("Save button") {
                Picker("Save button", selection: $saveBehavior) {
                    Text("Save to “Export location”").tag(SaveBehavior.exportLocation)
                    Text("Ask where to save").tag(SaveBehavior.ask)
                }
                .popup()
                HelpText("Press with ⌥ (option) to choose the destination.")
            }
        }
    }
}

// MARK: - Recording

private enum RecordingSection: String, CaseIterable, Identifiable {
    case general = "General", video = "Video", gif = "GIF"
    var id: String { rawValue }
}

struct RecordingTab: View {
    @State private var section = RecordingSection.general

    var body: some View {
        SettingsPage {
            Picker("Section", selection: $section) {
                ForEach(RecordingSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: 260).frame(maxWidth: .infinity)
            switch section {
            case .general: RecordingGeneral()
            case .video: RecordingVideo()
            case .gif: RecordingGIF()
            }
        }
    }
}

private struct RecordingGeneral: View {
    @AppStorage(PrefKey.recShowControls, store: Prefs.store) private var showControls = true
    @AppStorage(PrefKey.recMenuBarTime, store: Prefs.store) private var menuBarTime = false
    @AppStorage(PrefKey.recScaleTo1x, store: Prefs.store) private var scale1x = false
    @AppStorage(PrefKey.recShowCursor, store: Prefs.store) private var showCursor = true
    @AppStorage(PrefKey.recHighlightClicks, store: Prefs.store) private var highlightClicks = false
    @AppStorage(PrefKey.recClickColor, store: Prefs.store) private var clickColor = "#FFD60A"
    @AppStorage(PrefKey.recShowKeystrokes, store: Prefs.store) private var keystrokes = false
    @AppStorage(PrefKey.recRememberSelection, store: Prefs.store) private var remember = false
    @AppStorage(PrefKey.recDimScreen, store: Prefs.store) private var dim = true
    @AppStorage(PrefKey.recCountdown, store: Prefs.store) private var countdown = false
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Group {
            SettingsRow("Controls") {
                Toggle("Show controls while recording", isOn: $showControls)
                Toggle("Display recording time in menu bar", isOn: $menuBarTime)
            }
            SettingsRow("Retina") {
                Toggle("Scale Retina videos to 1x", isOn: $scale1x)
            }
            SettingsDivider()
            SettingsRow("Cursor") {
                Toggle("Show cursor", isOn: $showCursor)
                HStack(spacing: 8) {
                    Toggle("Highlight clicks", isOn: $highlightClicks)
                    ColorPicker("Click color", selection: HexColor.binding($clickColor), supportsOpacity: false)
                        .labelsHidden().disabled(!highlightClicks)
                }
            }
            SettingsRow("Keystrokes") {
                Toggle("Show keystrokes", isOn: $keystrokes)
                    .onChange(of: keystrokes) { _, on in
                        if on && !AXIsProcessTrusted() {
                            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                        }
                    }
                if keystrokes && !trusted {
                    HelpText("Showing keystrokes requires Accessibility permission for Snapframe.")
                    Button("Open Accessibility Settings…") { SystemSettingsPane.open(SystemSettingsPane.accessibility) }
                }
            }
            SettingsDivider()
            SettingsRow("Selection") {
                Toggle("Remember last selection", isOn: $remember)
                Toggle("Dim screen while recording", isOn: $dim)
                Toggle("Show countdown", isOn: $countdown)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }
}

private struct MicrophoneDevice: Identifiable {
    let id: String
    let name: String
    static func available() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified)
            .devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

private struct RecordingVideo: View {
    @AppStorage(PrefKey.recVideoCodec, store: Prefs.store) private var codec = VideoCodec.h264
    @AppStorage(PrefKey.recVideoFPS, store: Prefs.store) private var fps = 60
    @AppStorage(PrefKey.recVideoQuality, store: Prefs.store) private var quality = VideoQuality.high
    @AppStorage(PrefKey.recMicrophone, store: Prefs.store) private var microphone = false
    @AppStorage(PrefKey.recMicrophoneDeviceID, store: Prefs.store) private var deviceID = ""
    @AppStorage(PrefKey.recSystemAudio, store: Prefs.store) private var systemAudio = false
    @State private var devices = MicrophoneDevice.available()

    var body: some View {
        Group {
            SettingsRow("Codec") {
                Picker("Codec", selection: $codec) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC (H.265)").tag(VideoCodec.hevc)
                }.popup()
            }
            SettingsRow("Frame rate") {
                Picker("Frame rate", selection: $fps) {
                    ForEach(SettingsOptions.videoFrameRates, id: \.self) { Text("\($0) FPS").tag($0) }
                }.popup()
            }
            SettingsRow("Quality") {
                Picker("Quality", selection: $quality) {
                    Text("Low").tag(VideoQuality.low)
                    Text("Medium").tag(VideoQuality.medium)
                    Text("High").tag(VideoQuality.high)
                }.popup()
            }
            SettingsDivider()
            SettingsRow("Microphone") {
                Toggle("Record microphone", isOn: $microphone)
                Picker("Microphone device", selection: $deviceID) {
                    Text("Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                    if !deviceID.isEmpty, !devices.contains(where: { $0.id == deviceID }) {
                        Text("Unavailable device").tag(deviceID)
                    }
                }
                .popup().disabled(!microphone)
            }
            SettingsRow("System audio") {
                Toggle("Record system audio", isOn: $systemAudio)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = MicrophoneDevice.available()
        }
    }
}

private struct RecordingGIF: View {
    @AppStorage(PrefKey.recGifFPS, store: Prefs.store) private var fps = 15
    @AppStorage(PrefKey.recGifMaxWidth, store: Prefs.store) private var maxWidth = 1280

    var body: some View {
        Group {
            SettingsRow("Frame rate") {
                Picker("Frame rate", selection: $fps) {
                    ForEach(SettingsOptions.gifFrameRates, id: \.self) { Text("\($0) FPS").tag($0) }
                }.popup()
            }
            SettingsRow("Max width", help: "Wider recordings are scaled down to keep GIF files small.") {
                Picker("Max width", selection: $maxWidth) {
                    ForEach(SettingsOptions.gifWidths, id: \.width) { Text($0.title).tag($0.width) }
                }.popup()
            }
        }
    }
}

// MARK: - Screenshots

struct ScreenshotsTab: View {
    @AppStorage(PrefKey.shotFormat, store: Prefs.store) private var format = ImageFormat.png
    @AppStorage(PrefKey.shotScaleTo1x, store: Prefs.store) private var scale1x = false
    @AppStorage(PrefKey.shotConvertSRGB, store: Prefs.store) private var srgb = false
    @AppStorage(PrefKey.shotBorder, store: Prefs.store) private var border = false
    @AppStorage(PrefKey.shotBackgroundPreset, store: Prefs.store) private var presetID = ""
    @AppStorage(PrefKey.shotSelfTimer, store: Prefs.store) private var timer = 5
    @AppStorage(PrefKey.shotShowCursor, store: Prefs.store) private var showCursor = false
    @AppStorage(PrefKey.shotFreezeScreen, store: Prefs.store) private var freeze = false
    @AppStorage(PrefKey.shotCrosshairMode, store: Prefs.store) private var crosshair = CrosshairMode.disabled
    @AppStorage(PrefKey.shotShowMagnifier, store: Prefs.store) private var magnifier = true
    @State private var presets = BackgroundStyle.loadPresets()

    var body: some View {
        SettingsPage {
            SettingsRow("File format") {
                Picker("File format", selection: $format) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPG").tag(ImageFormat.jpg)
                }.popup()
            }
            SettingsRow("Image") {
                Toggle("Scale Retina screenshots to 1x", isOn: $scale1x)
                Toggle("Convert to sRGB profile", isOn: $srgb)
                Toggle("Add 1px border", isOn: $border)
            }
            SettingsRow("Background",
                        help: "Automatically apply Background Tool preset to all screenshots. You can create presets in Annotate.") {
                Picker("Background", selection: Binding(
                    get: { presets.contains { $0.id == presetID } ? presetID : "" },
                    set: { presetID = $0 }
                )) {
                    Text("None").tag("")
                    if !presets.isEmpty { Divider() }
                    ForEach(presets) { Text($0.name).tag($0.id) }
                }.popup()
            }
            SettingsDivider()
            SettingsRow("Self-Timer") {
                Picker("Self-Timer", selection: $timer) {
                    ForEach(SettingsOptions.selfTimerSeconds, id: \.self) { Text("\($0) seconds").tag($0) }
                }.popup()
            }
            SettingsRow("Cursor", help: "This works in Fullscreen or Self-Timer modes only.") {
                Toggle("Show cursor on screenshots", isOn: $showCursor)
            }
            SettingsDivider()
            SettingsRow("Area selection") {
                Toggle("Freeze screen", isOn: $freeze)
            }
            SettingsRow("Crosshair mode") {
                Picker("Crosshair mode", selection: $crosshair) {
                    Text("Disabled").tag(CrosshairMode.disabled)
                    Text("Always").tag(CrosshairMode.always)
                    Text("While holding ⌘").tag(CrosshairMode.whileHoldingCommand)
                }.popup()
            }
            SettingsRow("Magnifier") {
                Toggle("Show magnifier", isOn: $magnifier)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            presets = BackgroundStyle.loadPresets()
        }
    }
}

// MARK: - Annotate

struct AnnotateTab: View {
    @AppStorage(PrefKey.annInverseArrow, store: Prefs.store) private var inverseArrow = false
    @AppStorage(PrefKey.annSmoothDrawing, store: Prefs.store) private var smooth = true
    @AppStorage(PrefKey.annRememberBackgroundTool, store: Prefs.store) private var rememberBackground = false
    @AppStorage(PrefKey.annObjectShadow, store: Prefs.store) private var objectShadow = true
    @AppStorage(PrefKey.annAutoExpandCanvas, store: Prefs.store) private var autoExpand = false
    @AppStorage(PrefKey.annShowColorNames, store: Prefs.store) private var colorNames = false
    @AppStorage(PrefKey.annAlwaysOnTop, store: Prefs.store) private var alwaysOnTop = false
    @AppStorage(PrefKey.annShowDockIcon, store: Prefs.store) private var dockIcon = true

    var body: some View {
        SettingsPage {
            SettingsRow("Arrows", help: "Draw arrows from the end point back to the start point.") {
                Toggle("Inverse arrow direction", isOn: $inverseArrow)
            }
            SettingsRow("Drawing") {
                Toggle("Smooth drawing", isOn: $smooth)
                Toggle("Draw shadow on objects", isOn: $objectShadow)
            }
            SettingsRow("Background tool") {
                Toggle("Remember if Background tool was opened", isOn: $rememberBackground)
            }
            SettingsRow("Canvas",
                        help: "Automatically enlarge the canvas when objects are placed or moved outside the image.") {
                Toggle("Automatically expand canvas", isOn: $autoExpand)
            }
            SettingsDivider()
            SettingsRow("Colors") {
                Toggle("Show color names", isOn: $colorNames)
            }
            SettingsRow("Window") {
                Toggle("Always on top", isOn: $alwaysOnTop)
                Toggle("Show Dock icon", isOn: $dockIcon)
            }
        }
    }
}
