import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
@testable import SnapframeCore

extension SelfTests {
    static let settings: [TestCase] = [
        TestCase("settings: shortcut needs a modifier unless F-key") {
            let none: (Shortcut) -> SnapframeAction? = { _ in nil }
            let a = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
            let shiftA = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
            let cmdA = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))
            let f5 = Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0)
            try checkEqual(ShortcutValidator.evaluate(a, for: .captureArea, conflict: none), .needsModifier)
            try checkEqual(ShortcutValidator.evaluate(shiftA, for: .captureArea, conflict: none), .needsModifier)
            try checkEqual(ShortcutValidator.evaluate(cmdA, for: .captureArea, conflict: none), .ok)
            try checkEqual(ShortcutValidator.evaluate(f5, for: .captureArea, conflict: none), .ok)
        },
        TestCase("settings: shortcut conflicts are reported via the hotkey center") {
            // Default ⌥⇧⌘4 belongs to captureArea; recording it for another action must conflict.
            let area = SnapframeAction.captureArea.defaultShortcut!
            let result = ShortcutValidator.evaluate(area, for: .recordGIF) {
                HotkeyCenter.shared.conflict(for: $0, excluding: .recordGIF)
            }
            try checkEqual(result, .conflict(.captureArea))
            let own = ShortcutValidator.evaluate(area, for: .captureArea) {
                HotkeyCenter.shared.conflict(for: $0, excluding: .captureArea)
            }
            try checkEqual(own, .ok)
        },
        TestCase("settings: restore defaults rewrites every shortcut") {
            let session = ShortcutRecordingSession()
            Prefs.set("", PrefKey.shortcut(.captureArea))
            Prefs.set("1:256", PrefKey.shortcut(.openSettings))
            session.restoreDefaults()
            try checkEqual(Shortcut.stored(for: .captureArea), SnapframeAction.captureArea.defaultShortcut)
            try check(Shortcut.stored(for: .openSettings) == nil, "non-default shortcut should be cleared")
        },
        TestCase("settings: hex colour round trip") {
            try checkEqual(HexColor.hex(HexColor.color("#FFD60A")), "#FFD60A")
            try checkEqual(HexColor.hex(HexColor.color("#55626E")), "#55626E")
        },
        TestCase("settings: reset keeps state and presets, clears settings and shortcuts") {
            Prefs.set("1:2", PrefKey.shortcut(.captureText))
            Prefs.set(true, PrefKey.shotBorder)
            Prefs.set("keepme", PrefKey.lastArea)
            Prefs.set("[{\"x\":1}]", PrefKey.annBackgroundPresets)
            for key in SettingsReset.keysToReset() { Prefs.store.removeObject(forKey: key) }
            try check(!Prefs.bool(PrefKey.shotBorder), "setting not reset")
            try checkEqual(Shortcut.stored(for: .captureText), SnapframeAction.captureText.defaultShortcut)
            try checkEqual(Prefs.string(PrefKey.lastArea), "keepme")
            try checkEqual(Prefs.string(PrefKey.annBackgroundPresets), "[{\"x\":1}]")
        },
        TestCase("settings: auto-close intervals match registered default") {
            let seconds = SettingsOptions.autoCloseIntervals.map(\.seconds)
            try check(seconds.contains(Prefs.int(PrefKey.qaAutoCloseInterval)), "default interval not selectable")
            try check(SettingsOptions.gifWidths.map(\.width).contains(Prefs.int(PrefKey.recGifMaxWidth)))
            try check(SettingsOptions.selfTimerSeconds.contains(Prefs.int(PrefKey.shotSelfTimer)))
            try check(SettingsOptions.gifFrameRates.contains(Prefs.int(PrefKey.recGifFPS)))
        },
    ]
}
