import AppKit

// Every user setting lives here. SwiftUI settings views bind with
// `@AppStorage(PrefKey.x, store: Prefs.store)`; services read the typed getters below.
// Enums are stored as their String raw value.

public enum PrefKey {
    // General
    public static let startAtLogin = "startAtLogin"
    public static let playSounds = "playSounds"
    public static let shutterSound = "shutterSound"
    public static let showMenuBarIcon = "showMenuBarIcon"
    public static let exportLocation = "exportLocation"
    public static let hideDesktopIcons = "hideDesktopIcons"
    public static let afterShotQuickAccess = "after.shot.quickAccess"
    public static let afterShotCopy = "after.shot.copy"
    public static let afterShotSave = "after.shot.save"
    public static let afterShotAnnotate = "after.shot.annotate"
    public static let afterShotPin = "after.shot.pin"
    public static let afterRecQuickAccess = "after.rec.quickAccess"
    public static let afterRecCopy = "after.rec.copy"
    public static let afterRecSave = "after.rec.save"
    public static let afterRecVideoEditor = "after.rec.videoEditor"

    // Wallpaper
    public static let wallpaperMode = "wallpaper.mode"
    public static let wallpaperKeepAcrossSpaces = "wallpaper.keepAcrossSpaces"
    public static let wallpaperCustomPath = "wallpaper.customPath"
    public static let wallpaperPlainColor = "wallpaper.plainColor"
    public static let windowBackground = "window.background"
    public static let windowPadding = "window.padding"
    public static let windowShadow = "window.shadow"

    // Quick Access
    public static let qaPosition = "qa.position"
    public static let qaMoveToActiveScreen = "qa.moveToActiveScreen"
    public static let qaOverlaySize = "qa.overlaySize"
    public static let qaAutoClose = "qa.autoClose"
    public static let qaAutoCloseAction = "qa.autoCloseAction"
    public static let qaAutoCloseInterval = "qa.autoCloseInterval"
    public static let qaCloseAfterDragging = "qa.closeAfterDragging"
    public static let qaSaveBehavior = "qa.saveBehavior"

    // Recording
    public static let recShowControls = "rec.showControls"
    public static let recMenuBarTime = "rec.menuBarTime"
    public static let recScaleTo1x = "rec.scaleTo1x"
    public static let recShowCursor = "rec.showCursor"
    public static let recHighlightClicks = "rec.highlightClicks"
    public static let recClickColor = "rec.clickColor"
    public static let recShowKeystrokes = "rec.showKeystrokes"
    public static let recRememberSelection = "rec.rememberSelection"
    public static let recDimScreen = "rec.dimScreen"
    public static let recCountdown = "rec.countdown"
    public static let recVideoCodec = "rec.video.codec"
    public static let recVideoFPS = "rec.video.fps"
    public static let recVideoQuality = "rec.video.quality"
    public static let recMicrophone = "rec.audio.microphone"
    public static let recMicrophoneDeviceID = "rec.audio.microphoneDeviceID"
    public static let recSystemAudio = "rec.audio.system"
    public static let recGifFPS = "rec.gif.fps"
    public static let recGifMaxWidth = "rec.gif.maxWidth"

    // Screenshots
    public static let shotFormat = "shot.format"
    public static let shotScaleTo1x = "shot.scaleTo1x"
    public static let shotConvertSRGB = "shot.convertSRGB"
    public static let shotBorder = "shot.border"
    public static let shotBackgroundPreset = "shot.backgroundPreset"
    public static let shotSelfTimer = "shot.selfTimer"
    public static let shotShowCursor = "shot.showCursor"
    public static let shotFreezeScreen = "shot.freezeScreen"
    public static let shotCrosshairMode = "shot.crosshairMode"
    public static let shotShowMagnifier = "shot.showMagnifier"

    // Annotate
    public static let annInverseArrow = "ann.inverseArrow"
    public static let annSmoothDrawing = "ann.smoothDrawing"
    public static let annRememberBackgroundTool = "ann.rememberBackgroundTool"
    public static let annObjectShadow = "ann.objectShadow"
    public static let annAutoExpandCanvas = "ann.autoExpandCanvas"
    public static let annShowColorNames = "ann.showColorNames"
    public static let annAlwaysOnTop = "ann.alwaysOnTop"
    public static let annShowDockIcon = "ann.showDockIcon"
    public static let annBackgroundPresets = "ann.backgroundPresets" // JSON [BackgroundStyle]

    // Advanced
    public static let fileNameTemplate = "adv.fileNameTemplate"
    public static let askNameAfterCapture = "adv.askName"
    public static let add2xSuffix = "adv.add2xSuffix"
    public static let clipboardMode = "adv.clipboardMode"
    public static let pinRoundedCorners = "adv.pin.rounded"
    public static let pinShadow = "adv.pin.shadow"
    public static let pinBorder = "adv.pin.border"
    public static let historyRetention = "adv.historyRetention"
    public static let allInOneRememberLast = "adv.allInOneRememberLast"
    public static let ocrLanguage = "adv.ocr.language"
    public static let ocrKeepLineBreaks = "adv.ocr.keepLineBreaks"
    public static let ocrDetectLinks = "adv.ocr.detectLinks"
    public static let urlSchemeEnabled = "adv.urlScheme"

    // Internal state (not shown in settings)
    public static let lastArea = "state.lastArea"           // "displayID x y w h" in display points
    public static let lastRecordingArea = "state.lastRecordingArea"

    /// Prefix for shortcut keys: "shortcut.<SnapframeAction.rawValue>" = "keyCode:carbonModifiers" or "" for none.
    public static func shortcut(_ action: SnapframeAction) -> String { "shortcut.\(action.rawValue)" }
}

public enum WallpaperMode: String, CaseIterable { case desktop, custom, plainColor }
public enum WindowBackground: String, CaseIterable { case wallpaper, transparent }
public enum QuickAccessPosition: String, CaseIterable { case left, right }
public enum AutoCloseAction: String, CaseIterable { case saveAndClose, close }
public enum SaveBehavior: String, CaseIterable { case exportLocation, ask }
public enum VideoCodec: String, CaseIterable { case h264, hevc }
public enum VideoQuality: String, CaseIterable { case low, medium, high }
public enum ImageFormat: String, CaseIterable {
    case png, jpg
    public var fileExtension: String { rawValue }
}
public enum CrosshairMode: String, CaseIterable { case disabled, always, whileHoldingCommand }
public enum ClipboardMode: String, CaseIterable { case fileAndImage, file, image }
public enum HistoryRetention: String, CaseIterable {
    case never, day, threeDays, week, month
    public var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .day: return 86_400
        case .threeDays: return 3 * 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

public enum Prefs {
    // UserDefaults is thread-safe; the reference is only swapped by test/screenshot setup before any use.
    /// Overridable for tests.
    public nonisolated(unsafe) static var store: UserDefaults = .standard

    public static var defaults: [String: Any] { [
        PrefKey.startAtLogin: false,
        PrefKey.playSounds: false,
        PrefKey.shutterSound: "Default",
        PrefKey.showMenuBarIcon: true,
        PrefKey.exportLocation: (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"),
        PrefKey.hideDesktopIcons: true,
        PrefKey.afterShotQuickAccess: true,
        PrefKey.afterShotCopy: true,
        PrefKey.afterShotSave: false,
        PrefKey.afterShotAnnotate: false,
        PrefKey.afterShotPin: false,
        PrefKey.afterRecQuickAccess: true,
        PrefKey.afterRecCopy: true,
        PrefKey.afterRecSave: false,
        PrefKey.afterRecVideoEditor: true,

        PrefKey.wallpaperMode: WallpaperMode.desktop.rawValue,
        PrefKey.wallpaperKeepAcrossSpaces: false,
        PrefKey.wallpaperCustomPath: "",
        PrefKey.wallpaperPlainColor: "#55626E",
        PrefKey.windowBackground: WindowBackground.wallpaper.rawValue,
        PrefKey.windowPadding: 2,          // 0...6 ticks, 2 = default
        PrefKey.windowShadow: true,

        PrefKey.qaPosition: QuickAccessPosition.left.rawValue,
        PrefKey.qaMoveToActiveScreen: true,
        PrefKey.qaOverlaySize: 2,          // 0...4 ticks
        PrefKey.qaAutoClose: false,
        PrefKey.qaAutoCloseAction: AutoCloseAction.saveAndClose.rawValue,
        PrefKey.qaAutoCloseInterval: 30,   // seconds
        PrefKey.qaCloseAfterDragging: true,
        PrefKey.qaSaveBehavior: SaveBehavior.exportLocation.rawValue,

        PrefKey.recShowControls: true,
        PrefKey.recMenuBarTime: false,
        PrefKey.recScaleTo1x: false,
        PrefKey.recShowCursor: true,
        PrefKey.recHighlightClicks: false,
        PrefKey.recClickColor: "#FFD60A",
        PrefKey.recShowKeystrokes: false,
        PrefKey.recRememberSelection: false,
        PrefKey.recDimScreen: true,
        PrefKey.recCountdown: false,
        PrefKey.recVideoCodec: VideoCodec.h264.rawValue,
        PrefKey.recVideoFPS: 60,
        PrefKey.recVideoQuality: VideoQuality.high.rawValue,
        PrefKey.recMicrophone: false,
        PrefKey.recMicrophoneDeviceID: "",
        PrefKey.recSystemAudio: false,
        PrefKey.recGifFPS: 15,
        PrefKey.recGifMaxWidth: 1280,

        PrefKey.shotFormat: ImageFormat.png.rawValue,
        PrefKey.shotScaleTo1x: false,
        PrefKey.shotConvertSRGB: false,
        PrefKey.shotBorder: false,
        PrefKey.shotBackgroundPreset: "",  // "" = none, else BackgroundStyle.id
        PrefKey.shotSelfTimer: 5,
        PrefKey.shotShowCursor: false,
        PrefKey.shotFreezeScreen: false,
        PrefKey.shotCrosshairMode: CrosshairMode.disabled.rawValue,
        PrefKey.shotShowMagnifier: true,

        PrefKey.annInverseArrow: false,
        PrefKey.annSmoothDrawing: true,
        PrefKey.annRememberBackgroundTool: false,
        PrefKey.annObjectShadow: true,
        PrefKey.annAutoExpandCanvas: false,
        PrefKey.annShowColorNames: false,
        PrefKey.annAlwaysOnTop: false,
        PrefKey.annShowDockIcon: true,
        PrefKey.annBackgroundPresets: "[]",

        PrefKey.fileNameTemplate: "Snapframe %Y-%m-%d at %H.%M.%S",
        PrefKey.askNameAfterCapture: false,
        PrefKey.add2xSuffix: true,
        PrefKey.clipboardMode: ClipboardMode.fileAndImage.rawValue,
        PrefKey.pinRoundedCorners: true,
        PrefKey.pinShadow: true,
        PrefKey.pinBorder: true,
        PrefKey.historyRetention: HistoryRetention.week.rawValue,
        PrefKey.allInOneRememberLast: true,
        PrefKey.ocrLanguage: "auto",
        PrefKey.ocrKeepLineBreaks: false,
        PrefKey.ocrDetectLinks: true,
        PrefKey.urlSchemeEnabled: false,

        PrefKey.lastArea: "",
        PrefKey.lastRecordingArea: "",
    ] }

    public static func register() {
        var all = defaults
        for action in SnapframeAction.allCases {
            all[PrefKey.shortcut(action)] = action.defaultShortcut?.storageString ?? ""
        }
        store.register(defaults: all)
    }

    public static func bool(_ key: String) -> Bool { store.bool(forKey: key) }
    public static func int(_ key: String) -> Int { store.integer(forKey: key) }
    public static func double(_ key: String) -> Double { store.double(forKey: key) }
    public static func string(_ key: String) -> String { store.string(forKey: key) ?? "" }
    public static func set(_ value: Any?, _ key: String) { store.set(value, forKey: key) }
    public static func enumValue<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
        E(rawValue: string(key)) ?? fallback
    }

    public static var exportDirectory: URL {
        let path = (string(PrefKey.exportLocation) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    public static var imageFormat: ImageFormat { enumValue(PrefKey.shotFormat, .png) }
    public static var clipboardMode: ClipboardMode { enumValue(PrefKey.clipboardMode, .fileAndImage) }
    public static var historyRetention: HistoryRetention { enumValue(PrefKey.historyRetention, .week) }
}

public extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA"
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
