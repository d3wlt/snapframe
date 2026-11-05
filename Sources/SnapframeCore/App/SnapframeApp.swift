import AppKit

public enum SnapframeApp {
    public static let bundleID = "com.dwlt.snapframe"

    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        HistoryStore.shared.prune()
        menuBar = MenuBarController()
        HotkeyCenter.shared.reload()
        CapturePermission.checkOnLaunch()
        UpdateController.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching the app again while the menu bar icon is hidden opens Settings.
        if !flag { SettingsWindow.show() }
        return true
    }

    /// snapframe://<action>  (e.g. snapframe://capture-area). Ignored unless enabled in Advanced settings.
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), url.scheme == "snapframe" else { return }
        guard Prefs.bool(PrefKey.urlSchemeEnabled) else {
            NSLog("Snapframe: URL scheme disabled, ignoring \(string)")
            return
        }
        guard let host = url.host, let action = SnapframeAction(rawValue: host) else {
            NSLog("Snapframe: unknown URL action \(string)")
            return
        }
        ActionRouter.shared.perform(action)
    }
}

/// Shows the Dock icon while editor windows are open (Annotate → "Show Dock icon").
@MainActor
public enum DockIcon {
    private static var openWindows = 0

    public static func windowOpened() {
        openWindows += 1
        if Prefs.bool(PrefKey.annShowDockIcon) { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Screen Recording permission check. CGPreflightScreenCaptureAccess never prompts;
/// CGRequestScreenCaptureAccess shows the system prompt once.
@MainActor
public enum CapturePermission {
    public static var granted: Bool { CGPreflightScreenCaptureAccess() }

    static func checkOnLaunch() {
        if !granted { _ = CGRequestScreenCaptureAccess() }
    }

    /// Call before capturing; returns false (and explains) if permission is missing.
    public static func ensure() -> Bool {
        if granted { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snapframe needs Screen Recording permission"
        alert.informativeText = "Enable Snapframe in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
