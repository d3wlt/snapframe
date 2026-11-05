import AppKit
import ScreenCaptureKit

/// Thin ScreenCaptureKit wrapper. Everything here can throw (permission, display gone); callers must handle it.
@MainActor
enum ScreenGrabber {
    enum GrabError: Error { case displayNotFound, windowNotFound }

    /// Image of a display (or part of it, `rect` in display points with top-left origin).
    /// Snapframe's own windows are excluded, except the desktop-icon cover.
    static func grabDisplay(_ id: CGDirectDisplayID, rect: CGRect? = nil, scale: CGFloat, showCursor: Bool,
                            content shared: SCShareableContent? = nil) async throws -> CGImage {
        let content: SCShareableContent
        if let shared { content = shared } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw GrabError.displayNotFound }
        let keep = DesktopIconHider.shared.windowNumbers
        let own = getpid()
        let excluded = content.windows.filter { $0.owningApplication?.processID == own && !keep.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let size = rect?.size ?? CGSize(width: display.width, height: display.height)
        let config = SCStreamConfiguration()
        if let rect { config.sourceRect = rect }
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.showsCursor = showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Image of a single window without its shadow (the composer draws the shadow) and the pixel scale used.
    static func grabWindow(_ windowID: CGWindowID) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw GrabError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((info.contentRect.width * scale).rounded()))
        config.height = max(1, Int((info.contentRect.height * scale).rounded()))
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Full-display frames for every screen, keyed by display ID. Empty if capture isn't possible.
    static func grabAllDisplays() async -> [CGDirectDisplayID: CGImage] {
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        var result: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            if let img = try? await grabDisplay(id, scale: screen.backingScaleFactor, showCursor: false,
                                              content: content) { result[id] = img }
        }
        return result
    }
}
