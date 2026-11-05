import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        super.init()
        MenuBarController.current = self
        applyVisibility()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
    }

    private func applyVisibility() {
        let show = Prefs.bool(PrefKey.showMenuBarIcon)
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Snapframe")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Title shown next to the icon (e.g. recording time). nil restores the plain icon.
    func setTitle(_ title: String?) {
        statusItem?.button?.title = title.map { " \($0)" } ?? ""
        statusItem?.button?.imagePosition = title == nil ? .imageOnly : .imageLeading
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let groups: [[SnapframeAction]] = [
            [.captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer],
            [.recordScreen, .recordGIF],
            [.captureText],
            [.toggleDesktopIcons],
            [.openAnnotate, .pinImage],
            [.restoreLast, .captureHistory],
        ]
        for group in groups {
            for action in group { menu.addItem(item(for: action)) }
            menu.addItem(.separator())
        }
        menu.addItem(updateItem())
        menu.addItem(item(for: .openSettings))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Snapframe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(for action: SnapframeAction) -> NSMenuItem {
        var title = action.title
        if action == .toggleDesktopIcons, DesktopIconHider.shared.isHidden { title = "Show Desktop Icons" }
        if action == .recordScreen || action == .recordGIF, RecordingController.shared.isRecording { title = "Stop Recording" }
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        if let sc = Shortcut.stored(for: action) {
            let eq = sc.menuKeyEquivalent
            item.keyEquivalent = eq.key
            item.keyEquivalentModifierMask = eq.mask
        }
        return item
    }

    private func updateItem() -> NSMenuItem {
        let updates = UpdateController.shared
        let title = updates.available.map { "Install Update \($0.version)…" } ?? "Check for Updates…"
        let item = NSMenuItem(title: title, action: #selector(updateAction), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: updates.available == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle",
                             accessibilityDescription: nil)
        item.isHidden = !updates.isConfigured
        return item
    }

    @objc private func updateAction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { UpdateController.shared.installAvailable() }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = SnapframeAction(rawValue: raw) else { return }
        // Let the menu close before capturing so it isn't in the shot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ActionRouter.shared.perform(action) }
    }
}

extension MenuBarController {
    static weak var current: MenuBarController?
}

/// Public hook for other features (e.g. recording time in the menu bar).
@MainActor
public enum MenuBarStatus {
    public static func setTitle(_ title: String?) { MenuBarController.current?.setTitle(title) }
}
