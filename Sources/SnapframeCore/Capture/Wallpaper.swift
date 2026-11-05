import AppKit

/// Resolves the Wallpaper settings (desktop / custom image / plain colour) into drawable content.
@MainActor
enum Wallpaper {
    static var plainColor: NSColor {
        NSColor(hex: Prefs.string(PrefKey.wallpaperPlainColor)) ?? NSColor(srgbRed: 0.33, green: 0.38, blue: 0.43, alpha: 1)
    }

    /// The image to show for a screen, or nil when the setting is a plain colour (or nothing loadable).
    static func image(for screen: NSScreen?) -> CGImage? {
        switch Prefs.enumValue(PrefKey.wallpaperMode, WallpaperMode.desktop) {
        case .plainColor:
            return nil
        case .custom:
            let path = (Prefs.string(PrefKey.wallpaperCustomPath) as NSString).expandingTildeInPath
            return path.isEmpty ? nil : load(URL(fileURLWithPath: path))
        case .desktop:
            guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return load(url)
        }
    }

    static func background(for screen: NSScreen?) -> WindowComposer.Background {
        if let img = image(for: screen) { return .image(img) }
        return .color(plainColor.usingColorSpace(.sRGB)?.cgColor ?? plainColor.cgColor)
    }

    private static func load(_ url: URL) -> CGImage? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
