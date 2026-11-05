import AppKit

/// Covers desktop icons with a wallpaper window (Wallpaper settings decide what is shown).
@MainActor
public final class DesktopIconHider {
    public static let shared = DesktopIconHider()

    /// True while icons are hidden by the user's toggle (persists until toggled back).
    public private(set) var isHidden = false
    private var temporarilyHidden = false
    private var windows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?

    /// Window numbers of the cover windows; the capture filter must NOT exclude these.
    var windowNumbers: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    public func toggle() {
        isHidden.toggle()
        refresh()
    }

    /// Temporarily hides icons for the duration of a capture if the pref is on.
    public func hideTemporarily() {
        guard Prefs.bool(PrefKey.hideDesktopIcons), !isHidden, !temporarilyHidden else { return }
        temporarilyHidden = true
        refresh()
    }

    /// Like `hideTemporarily()` but also gives the windows a moment to reach the screen.
    public func hideTemporarilyAndWait() async {
        hideTemporarily()
        if temporarilyHidden { try? await Task.sleep(nanoseconds: 180_000_000) }
    }

    public func restoreAfterCapture() {
        guard temporarilyHidden else { return }
        temporarilyHidden = false
        refresh()
    }

    private func refresh() {
        if isHidden || temporarilyHidden { show() } else { tearDown() }
    }

    private func show() {
        tearDown(keepObserver: true)
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isHidden || self.temporarilyHidden else { return }
                    self.show()
                }
            }
        }
        let keep = Prefs.bool(PrefKey.wallpaperKeepAcrossSpaces)
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for screen in NSScreen.screens {
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false,
                               screen: screen)
            win.isReleasedWhenClosed = false
            win.level = level
            win.isOpaque = true
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.backgroundColor = Wallpaper.plainColor
            win.collectionBehavior = keep ? [.stationary, .canJoinAllSpaces, .ignoresCycle] : [.ignoresCycle]
            win.setFrame(screen.frame, display: false)
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = Wallpaper.plainColor.cgColor
            if let image = Wallpaper.image(for: screen) {
                view.layer?.contents = image
                view.layer?.contentsGravity = .resizeAspectFill
                view.layer?.masksToBounds = true
            }
            win.contentView = view
            win.orderFront(nil)
            windows.append(win)
        }
    }

    private func tearDown(keepObserver: Bool = false) {
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        if !keepObserver, let o = screenObserver {
            NotificationCenter.default.removeObserver(o)
            screenObserver = nil
        }
    }
}
