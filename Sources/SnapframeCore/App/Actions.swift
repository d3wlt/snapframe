import AppKit
import Carbon.HIToolbox

/// Every user-triggerable command. Raw values double as URL-scheme hosts (snapframe://<rawValue>)
/// and shortcut storage suffixes.
public enum SnapframeAction: String, CaseIterable, Identifiable {
    case captureArea = "capture-area"
    case capturePreviousArea = "capture-previous-area"
    case captureFullscreen = "capture-fullscreen"
    case captureWindow = "capture-window"
    case selfTimer = "self-timer"
    case captureText = "capture-text"
    case recordScreen = "record-screen"
    case recordGIF = "record-gif"
    case toggleDesktopIcons = "toggle-desktop-icons"
    case openAnnotate = "open-annotate"
    case pinImage = "pin-image"
    case restoreLast = "restore-last"
    case captureHistory = "capture-history"
    case openSettings = "open-settings"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .selfTimer: return "Self-Timer"
        case .captureText: return "Capture Text"
        case .recordScreen: return "Record Screen"
        case .recordGIF: return "Record GIF"
        case .toggleDesktopIcons: return "Hide Desktop Icons"
        case .openAnnotate: return "Open Annotation Tool"
        case .pinImage: return "Pin Image to Screen"
        case .restoreLast: return "Restore Recently Closed File"
        case .captureHistory: return "Capture History"
        case .openSettings: return "Settings…"
        }
    }

    /// SF Symbol name used in menus and settings.
    public var symbol: String {
        switch self {
        case .captureArea: return "rectangle.dashed"
        case .capturePreviousArea: return "rectangle.dashed.badge.record"
        case .captureFullscreen: return "macwindow.on.rectangle"
        case .captureWindow: return "macwindow"
        case .selfTimer: return "timer"
        case .captureText: return "text.viewfinder"
        case .recordScreen: return "record.circle"
        case .recordGIF: return "photo.stack"
        case .toggleDesktopIcons: return "eye.slash"
        case .openAnnotate: return "pencil.tip.crop.circle"
        case .pinImage: return "pin"
        case .restoreLast: return "arrow.uturn.backward"
        case .captureHistory: return "clock.arrow.circlepath"
        case .openSettings: return "gearshape"
        }
    }

    /// ⌥⇧⌘ + digit defaults avoid clashing with the macOS ⇧⌘3/4/5 screenshot shortcuts.
    public var defaultShortcut: Shortcut? {
        let mods = UInt32(cmdKey | shiftKey | optionKey)
        switch self {
        case .captureFullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: mods)
        case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: mods)
        case .captureWindow: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: mods)
        case .capturePreviousArea: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: mods)
        case .recordScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: mods)
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: mods)
        case .selfTimer: return Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: mods)
        default: return nil
        }
    }
}

/// A global keyboard shortcut. `modifiers` uses Carbon flags (cmdKey, shiftKey, optionKey, controlKey).
public struct Shortcut: Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init?(storageString: String) {
        let parts = storageString.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.init(keyCode: k, modifiers: m)
    }

    public var storageString: String { "\(keyCode):\(modifiers)" }

    public static func stored(for action: SnapframeAction) -> Shortcut? {
        Shortcut(storageString: Prefs.string(PrefKey.shortcut(action)))
    }

    public var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    public var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return (Shortcut.keyName(keyCode).lowercased(), mask)
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    public static func keyName(_ keyCode: UInt32) -> String {
        if let n = namedKeys[Int(keyCode)] { return n }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Single entry point for every command (menu, hotkey, URL scheme).
@MainActor
public final class ActionRouter {
    public static let shared = ActionRouter()

    public func perform(_ action: SnapframeAction) {
        switch action {
        case .captureArea:
            Task { if let item = await CaptureService.shared.captureArea(previous: false) { AfterCapture.handle(item) } }
        case .capturePreviousArea:
            Task { if let item = await CaptureService.shared.captureArea(previous: true) { AfterCapture.handle(item) } }
        case .captureFullscreen:
            Task { if let item = await CaptureService.shared.captureFullscreen() { AfterCapture.handle(item) } }
        case .captureWindow:
            Task { if let item = await CaptureService.shared.captureWindow() { AfterCapture.handle(item) } }
        case .selfTimer:
            Task { if let item = await CaptureService.shared.captureSelfTimer() { AfterCapture.handle(item) } }
        case .captureText:
            Task { await CaptureService.shared.captureText() }
        case .recordScreen:
            RecordingController.shared.toggle(format: .video)
        case .recordGIF:
            RecordingController.shared.toggle(format: .gif)
        case .toggleDesktopIcons:
            DesktopIconHider.shared.toggle()
        case .openAnnotate:
            if let url = Self.chooseImage() { AnnotationEditor.open(fileURL: url) }
        case .pinImage:
            if let url = Self.chooseImage() { PinController.shared.pin(fileURL: url) }
        case .restoreLast:
            QuickAccessController.shared.restoreLastClosed()
        case .captureHistory:
            HistoryWindow.show()
        case .openSettings:
            SettingsWindow.show()
        }
    }

    static func chooseImage() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
