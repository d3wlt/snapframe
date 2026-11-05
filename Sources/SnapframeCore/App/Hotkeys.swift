import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (needs no Accessibility permission).
@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: SnapframeAction] = [:]
    private var handlerInstalled = false
    /// While true (e.g. the shortcut recorder is focused) hotkeys are unregistered, so the keys reach the
    /// recorder (a registered Carbon hotkey would swallow them).
    public var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { unregisterAll() } else { reload() }
        }
    }
    /// Actions whose shortcut could not be registered (taken by macOS or another app).
    public private(set) var failedActions: Set<SnapframeAction> = []

    /// (Re)registers all shortcuts from Prefs. Call after any shortcut change.
    public func reload() {
        installHandlerIfNeeded()
        unregisterAll()
        failedActions = []
        guard !suspended else { return }

        for (index, action) in SnapframeAction.allCases.enumerated() {
            guard let sc = Shortcut.stored(for: action) else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x534E4150), id: id) // 'SNAP'
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actionsByID[id] = action
            } else {
                failedActions.insert(action)
                NSLog("Snapframe: could not register hotkey \(sc.displayString) for \(action.rawValue) (status \(status))")
            }
        }
        NotificationCenter.default.post(name: Self.didReload, object: nil)
    }

    public static let didReload = Notification.Name("snapframe.hotkeysReloaded")

    private func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actionsByID.removeAll()
    }

    /// True if another registered action already uses this shortcut.
    public func conflict(for shortcut: Shortcut, excluding: SnapframeAction) -> SnapframeAction? {
        SnapframeAction.allCases.first { $0 != excluding && Shortcut.stored(for: $0) == shortcut }
    }

    fileprivate func fire(id: UInt32) {
        guard !suspended, let action = actionsByID[id] else { return }
        ActionRouter.shared.perform(action)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(id: id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
