import AppKit
import SwiftUI

/// Hooks for the `SnapframeScreenshots` tool: builds the app's real windows and views, configured with demo
/// content, without showing them. Nothing here is used by the app itself.
@MainActor
public enum ReadmeScenes {
    /// The Settings window on the given tab (`SettingsTab` raw value, e.g. "general", "recording").
    public static func settingsWindow(tab: String) -> NSWindow {
        let controller = SettingsWindowController()
        controller.select(SettingsTab(rawValue: tab) ?? .general)
        retained.append(controller)
        return controller.window
    }

    /// The annotation editor on an image file, with the annotations applied through the editor's own state.
    public static func annotateWindow(imageURL: URL, annotations: [Annotation]) -> NSWindow? {
        guard let item = ItemFactory.itemForExternalFile(imageURL),
              let controller = EditorWindowController(item: item, index: 0) else { return nil }
        controller.state.perform { doc in doc.annotations.append(contentsOf: annotations) }
        controller.layoutOffscreen()
        retained.append(controller)
        return controller.window
    }

    /// The trim editor on a GIF or video, with the handles moved to `trim` (seconds) once the media is loaded.
    public static func trimEditorWindow(item: CapturedItem, trim: ClosedRange<Double>, playhead: Double) async -> NSWindow {
        let window = VideoEditorWindow(item: item)
        retained.append(window)
        // Wait for the media to load and the thumbnail strip to be generated.
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if window.timeline.selection.duration > 0, window.timeline.hasThumbnails { break }
        }
        window.media.pause()
        window.timeline.setTrim(start: trim.lowerBound, end: trim.upperBound)
        window.media.seek(to: playhead)
        window.timeline.setPlayhead(playhead)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Quick Access cards stacked as on screen (newest first = bottom), laid out with the app's own geometry.
    public static func quickAccessStack(items: [CapturedItem]) -> NSView {
        let tick = 2
        let sizes = items.map { item -> CGSize in
            let s = item.pointSize
            return QuickAccessLayout.cardSize(tick: tick, aspect: s.height > 0 ? s.width / s.height : 1.6)
        }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.reduce(0) { $0 + $1.height } + QuickAccessLayout.spacing * CGFloat(max(0, sizes.count - 1))
        let container = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let m = QuickAccessLayout.margin
        let frames = QuickAccessLayout.frames(sizes: sizes, in: CGRect(x: -m, y: -m, width: width + 2 * m, height: height + 2 * m),
                                              position: .left)
        for (item, frame) in zip(items, frames) {
            let card = QuickAccessCardView(item: item)
            card.frame = frame
            container.addSubview(card)
        }
        return container
    }

    /// The Capture History window showing whatever `HistoryStore.shared` holds (point it at a temp directory first).
    public static func historyWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Capture History"
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HistoryView())
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(NSSize(width: 780, height: 350))
        return w
    }

    private static var retained: [AnyObject] = []
}
