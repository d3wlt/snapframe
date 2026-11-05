import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Pure validation rules for a recorded shortcut.
enum ShortcutValidator {
    enum Result: Equatable {
        case ok
        case needsModifier
        case conflict(SnapframeAction)
    }

    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// A shortcut needs ⌘, ⌃ or ⌥ (⇧ alone would hijack normal typing) unless it is an F-key.
    static func evaluate(_ shortcut: Shortcut, for action: SnapframeAction,
                         conflict: (Shortcut) -> SnapframeAction?) -> Result {
        let strong = UInt32(cmdKey | controlKey | optionKey)
        if shortcut.modifiers & strong == 0 && !functionKeys.contains(Int(shortcut.keyCode)) {
            return .needsModifier
        }
        if let other = conflict(shortcut) { return .conflict(other) }
        return .ok
    }

    static func message(for result: Result) -> String? {
        switch result {
        case .ok: return nil
        case .needsModifier: return "Include ⌘, ⌃ or ⌥ (or use an F-key)."
        case .conflict(let other): return "Already used by “\(other.title)”."
        }
    }
}

/// Drives one-at-a-time shortcut recording using a local key event monitor.
@MainActor
final class ShortcutRecordingSession: ObservableObject {
    @Published private(set) var recording: SnapframeAction?
    @Published private(set) var warning: (action: SnapframeAction, text: String)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var stoppedByClick: (action: SnapframeAction, at: Date)?

    func toggle(_ action: SnapframeAction) {
        if let s = stoppedByClick, s.action == action, Date().timeIntervalSince(s.at) < 0.4 {
            stoppedByClick = nil
            return // the same click already ended this recording
        }
        if recording == action { stop() } else { start(action) }
    }

    func start(_ action: SnapframeAction) {
        stop()
        recording = action
        warning = nil
        HotkeyCenter.shared.suspended = true
        monitor = localMonitor([.keyDown, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        let nc = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        recording = nil
        HotkeyCenter.shared.suspended = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let action = recording else { return event }
        if event.type == .leftMouseDown {
            stoppedByClick = (action, Date())
            stop()
            return event
        }
        let code = Int(event.keyCode)
        let mods = Shortcut.carbonModifiers(from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if code == kVK_Escape { stop(); return nil }
        if (code == kVK_Delete || code == kVK_ForwardDelete) && mods == 0 {
            save(nil, for: action)
            stop()
            return nil
        }
        let shortcut = Shortcut(keyCode: UInt32(code), modifiers: mods)
        let result = ShortcutValidator.evaluate(shortcut, for: action) {
            HotkeyCenter.shared.conflict(for: $0, excluding: action)
        }
        if let text = ShortcutValidator.message(for: result) {
            warning = (action, text)
            NSSound.beep()
        } else {
            save(shortcut, for: action)
            stop()
        }
        return nil
    }

    private func save(_ shortcut: Shortcut?, for action: SnapframeAction) {
        Prefs.set(shortcut?.storageString ?? "", PrefKey.shortcut(action))
        HotkeyCenter.shared.reload()
    }

    func restoreDefaults() {
        stop()
        warning = nil
        for action in SnapframeAction.allCases {
            Prefs.set(action.defaultShortcut?.storageString ?? "", PrefKey.shortcut(action))
        }
        HotkeyCenter.shared.reload()
    }
}

private struct ShortcutRow: View {
    let action: SnapframeAction
    @ObservedObject var session: ShortcutRecordingSession
    @AppStorage private var stored: String

    init(action: SnapframeAction, session: ShortcutRecordingSession) {
        self.action = action
        self.session = session
        _stored = AppStorage(wrappedValue: "", PrefKey.shortcut(action), store: Prefs.store)
    }

    @State private var failed = false

    private var isRecording: Bool { session.recording == action }
    private var shortcut: Shortcut? { Shortcut(storageString: stored) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                Text(action.title)
                Spacer()
                recorder
            }
            if let w = session.warning, w.action == action {
                Text(w.text)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if failed && !isRecording {
                Text("Not active: this shortcut is taken by macOS or another app.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onAppear { failed = HotkeyCenter.shared.failedActions.contains(action) }
        .onReceive(NotificationCenter.default.publisher(for: HotkeyCenter.didReload)) { _ in
            failed = HotkeyCenter.shared.failedActions.contains(action)
        }
    }

    private var recorder: some View {
        HStack(spacing: 4) {
            Button {
                session.toggle(action)
            } label: {
                Text(isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "Record Shortcut"))
                    .font(shortcut != nil && !isRecording ? .system(size: 13, weight: .medium) : .system(size: 12))
                    .foregroundStyle(shortcut != nil || isRecording ? Color.primary : Color.secondary)
                    .frame(width: 128, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.18),
                                          lineWidth: isRecording ? 2 : 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(shortcut?.displayString ?? "None")

            Button {
                if isRecording { session.stop() }
                Prefs.set("", PrefKey.shortcut(action))
                HotkeyCenter.shared.reload()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear shortcut")
            .opacity(shortcut == nil ? 0 : 1)
            .disabled(shortcut == nil)
        }
    }
}

struct ShortcutsTab: View {
    @StateObject private var session = ShortcutRecordingSession()

    var body: some View {
        SettingsPage {
            VStack(spacing: 8) {
                ForEach(SnapframeAction.allCases) { action in
                    ShortcutRow(action: action, session: session)
                }
            }
            HStack {
                Text("Click a shortcut to record it. Press ⌫ to clear, Esc to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { session.restoreDefaults() }
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                HelpText("macOS uses ⇧⌘3, ⇧⌘4 and ⇧⌘5 for its own screenshots. To use them in Snapframe, turn them off in System Settings › Keyboard › Keyboard Shortcuts › Screenshots.")
                Button("Open Keyboard Shortcuts…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .onDisappear { session.stop() }
    }
}
