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
    /// Bumped by every show/tear-down so a slower, older `show()` doesn't put up stale covers.
    private var generation = 0

    /// Window numbers of the cover windows; the capture filter must NOT exclude these.
    var windowNumbers: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    public func toggle() {
        isHidden.toggle()
        if isHidden { Task { await show() } } else { tearDown() }
    }

    /// Hides icons for the duration of a capture if the pref is on, and gives the covers a moment to reach the screen.
    public func hideTemporarilyAndWait() async {
        guard Prefs.bool(PrefKey.hideDesktopIcons), !isHidden, !temporarilyHidden else { return }
        temporarilyHidden = true
        await show()
        try? await Task.sleep(nanoseconds: 180_000_000)
    }

    public func restoreAfterCapture() {
        guard temporarilyHidden else { return }
        temporarilyHidden = false
        if !isHidden { tearDown() }
    }

    private func show() async {
        generation += 1
        let current = generation
        let screens = NSScreen.screens
        var images: [CGImage?] = []
        for screen in screens { images.append(await Wallpaper.image(for: screen)) }
        guard current == generation, isHidden || temporarilyHidden else { return }
        guard NSScreen.screens.map(\.displayID) == screens.map(\.displayID) else { return await show() }
        tearDown(keepObserver: true)
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isHidden || self.temporarilyHidden else { return }
                    Task { await self.show() }
                }
            }
        }
        let keep = Prefs.bool(PrefKey.wallpaperKeepAcrossSpaces)
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for (screen, image) in zip(screens, images) {
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
            if let image {
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
        generation += 1
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        if !keepObserver, let o = screenObserver {
            NotificationCenter.default.removeObserver(o)
            screenObserver = nil
        }
    }
}
