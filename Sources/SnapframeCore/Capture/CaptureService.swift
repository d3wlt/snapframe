import AppKit
import ScreenCaptureKit

/// A rectangle on one display, in that display's points with a top-left origin
/// (same convention as ScreenCaptureKit's sourceRect).
public struct ScreenArea: Equatable, Codable {
    public var displayID: CGDirectDisplayID
    public var rect: CGRect

    public init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }
}

@MainActor
public final class CaptureService {
    public static let shared = CaptureService()

    private var busy = false

    /// Interactive area selection then capture. `previous` reuses the last area without UI.
    public func captureArea(previous: Bool) async -> CapturedItem? {
        await exclusive {
            guard CapturePermission.ensure() else { return nil }
            let hider = DesktopIconHider.shared
            await hider.hideTemporarilyAndWait()
            defer { hider.restoreAfterCapture() }

            var area: ScreenArea
            var frozen: [CGDirectDisplayID: CGImage] = [:]
            if previous, let last = Self.validatedLastArea() {
                area = last
            } else {
                guard let sel = await AreaSelector.selectWithFrames(purpose: .screenshot) else { return nil }
                area = sel.area
                frozen = sel.frozen
                if frozen.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) } // let the overlay leave the screen
            }
            Prefs.set(AreaStorage.encode(area), PrefKey.lastArea)
            return await self.captureItem(area: area, frozen: frozen, showCursor: false)
        }
    }

    /// Hover-to-highlight window picker then capture (wallpaper background/padding/shadow per prefs).
    public func captureWindow() async -> CapturedItem? {
        await exclusive {
            guard CapturePermission.ensure() else { return nil }
            guard let pick = await WindowPicker.pick() else { return nil }
            try? await Task.sleep(nanoseconds: 150_000_000)
            do {
                let shot = try await ScreenGrabber.grabWindow(pick.window.id)
                let composed = Self.composeWindow(shot.image, windowFrame: pick.window.frame, modifiers: pick.modifiers)
                return try ItemFactory.makeImageItem(composed ?? shot.image, scale: shot.scale)
            } catch {
                Self.fail("Window capture failed", error)
                return nil
            }
        }
    }

    /// Captures the display under the cursor.
    public func captureFullscreen() async -> CapturedItem? {
        await exclusive {
            guard CapturePermission.ensure() else { return nil }
            return await self.fullscreen(screen: NSScreen.underMouse)
        }
    }

    /// Countdown (Prefs shotSelfTimer seconds) then fullscreen capture.
    public func captureSelfTimer() async -> CapturedItem? {
        await exclusive {
            guard CapturePermission.ensure() else { return nil }
            let screen = NSScreen.underMouse
            let seconds = max(0, Prefs.int(PrefKey.shotSelfTimer))
            if seconds > 0 {
                guard await CountdownHUD().run(seconds: seconds, on: screen) else { return nil }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return await self.fullscreen(screen: screen)
        }
    }

    /// Area selection then OCR; recognised text goes to the clipboard.
    public func captureText() async {
        _ = await exclusive { () -> CapturedItem? in
            guard CapturePermission.ensure() else { return nil }
            let hider = DesktopIconHider.shared
            await hider.hideTemporarilyAndWait()
            defer { hider.restoreAfterCapture() }
            guard let sel = await AreaSelector.selectWithFrames(purpose: .text) else { return nil }
            if sel.frozen.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
            do {
                let image = try await Self.image(area: sel.area, frozen: sel.frozen, showCursor: false)
                let text = try await TextRecognizer.recognize(image)
                if text.isEmpty {
                    Toast.show("No text found", symbol: "text.viewfinder")
                } else {
                    Clipboard.copyText(text)
                    Toast.show("Text copied", symbol: "doc.on.clipboard")
                }
            } catch {
                Self.fail("Text capture failed", error)
            }
            return nil
        }
    }

    // MARK: Pipeline

    /// Only one capture flow at a time (a second hotkey press while one runs is ignored).
    private func exclusive(_ body: () async -> CapturedItem?) async -> CapturedItem? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        return await body()
    }

    private func fullscreen(screen: NSScreen?) async -> CapturedItem? {
        guard let screen, let id = screen.displayID else { return nil }
        let hider = DesktopIconHider.shared
        await hider.hideTemporarilyAndWait()
        defer { hider.restoreAfterCapture() }
        let area = ScreenArea(displayID: id, rect: CGRect(origin: .zero, size: screen.frame.size))
        return await captureItem(area: area, frozen: [:], showCursor: Prefs.bool(PrefKey.shotShowCursor))
    }

    private func captureItem(area: ScreenArea, frozen: [CGDirectDisplayID: CGImage], showCursor: Bool) async -> CapturedItem? {
        do {
            let image = try await Self.image(area: area, frozen: frozen, showCursor: showCursor)
            let scale = Self.scale(of: area.displayID)
            return try ItemFactory.makeImageItem(image, scale: scale)
        } catch {
            Self.fail("Capture failed", error)
            return nil
        }
    }

    /// Pixels for an area: cropped from the frozen frame when there is one, else captured live.
    static func image(area: ScreenArea, frozen: [CGDirectDisplayID: CGImage], showCursor: Bool) async throws -> CGImage {
        let scale = scale(of: area.displayID)
        if let frame = frozen[area.displayID], let size = NSScreen.screens.first(where: { $0.displayID == area.displayID })?.frame.size {
            let crop = CaptureGeometry.pixelCropRect(pointRect: area.rect, displaySize: size,
                                                     imageSize: CGSize(width: frame.width, height: frame.height))
            if !crop.isNull, crop.width > 0, crop.height > 0, let cropped = frame.cropping(to: crop) { return cropped }
        }
        return try await ScreenGrabber.grabDisplay(area.displayID, rect: area.rect, scale: scale, showCursor: showCursor)
    }

    static func scale(of displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2
    }

    /// The saved area if its display still exists; clamped to the display.
    static func validatedLastArea() -> ScreenArea? {
        guard var a = AreaStorage.decode(Prefs.string(PrefKey.lastArea)),
              let screen = NSScreen.screens.first(where: { $0.displayID == a.displayID }) else { return nil }
        a.rect = a.rect.intersection(CGRect(origin: .zero, size: screen.frame.size))
        return a.rect.isNull || a.rect.width < 1 || a.rect.height < 1 ? nil : a
    }

    /// Applies the Wallpaper/window settings (modifiers: ⌥ = no shadow, ⇧ = transparent).
    static func composeWindow(_ window: CGImage, windowFrame: CGRect, modifiers: NSEvent.ModifierFlags) -> CGImage? {
        let transparent = modifiers.contains(.shift)
            || Prefs.enumValue(PrefKey.windowBackground, WindowBackground.wallpaper) == .transparent
        let shadow = Prefs.bool(PrefKey.windowShadow) && !modifiers.contains(.option)
        let pad = WindowComposer.paddingPixels(ticks: Prefs.int(PrefKey.windowPadding),
                                               windowSize: CGSize(width: window.width, height: window.height))
        let screen = NSScreen.screens.max {
            $0.frame.intersection(windowFrame).area < $1.frame.intersection(windowFrame).area
        }
        let background: WindowComposer.Background = transparent ? .transparent : Wallpaper.background(for: screen)
        return WindowComposer.compose(window: window, background: background, padding: pad, shadow: shadow)
    }

    private static func fail(_ title: String, _ error: Error) {
        NSLog("Snapframe: \(title): \(error)")
        Toast.show(title, symbol: "exclamationmark.triangle")
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen containing the mouse cursor.
    static var underMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }
}
