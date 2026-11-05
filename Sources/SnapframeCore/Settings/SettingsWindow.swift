import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, wallpaper, shortcuts, quickAccess, recording, screenshots, annotate, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .wallpaper: return "Wallpaper"
        case .shortcuts: return "Shortcuts"
        case .quickAccess: return "Quick Access"
        case .recording: return "Recording"
        case .screenshots: return "Screenshots"
        case .annotate: return "Annotate"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .wallpaper: return "photo.on.rectangle"
        case .shortcuts: return "command"
        case .quickAccess: return "rectangle.stack"
        case .recording: return "video"
        case .screenshots: return "camera"
        case .annotate: return "pencil.tip"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .general
    var onHeight: ((CGFloat) -> Void)?
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SettingsRoot: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch model.tab {
            case .general: GeneralTab()
            case .wallpaper: WallpaperTab()
            case .shortcuts: ShortcutsTab()
            case .quickAccess: QuickAccessTab()
            case .recording: RecordingTab()
            case .screenshots: ScreenshotsTab()
            case .annotate: AnnotateTab()
            case .advanced: AdvancedTab()
            case .about: AboutTab()
            }
        }
        .id(model.tab)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: SettingsLayout.width, alignment: .top)
        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        .onPreferenceChange(HeightKey.self) { h in
            if h > 0 { model.onHeight?(h) }
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    let model = SettingsModel()
    let window: NSWindow
    private let host: NSHostingView<SettingsRoot>
    private var isOpen = false

    override init() {
        host = NSHostingView(rootView: SettingsRoot(model: model))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.width, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = host
        let toolbar = NSToolbar(identifier: "SnapframeSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(model.tab.rawValue)
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        model.onHeight = { [weak self] h in
            DispatchQueue.main.async { self?.setContentHeight(h, animated: true) }
        }
        select(model.tab)
        window.center()
    }

    func show(tab: SettingsTab?) {
        if let tab { select(tab) }
        if !isOpen {
            isOpen = true
            DockIcon.windowOpened()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func select(_ tab: SettingsTab) {
        model.tab = tab
        window.title = tab.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        // Pre-size from the SwiftUI ideal height; the preference callback refines it after layout.
        host.frame.size.width = SettingsLayout.width
        let ideal = host.fittingSize.height
        if ideal > 50 { setContentHeight(ideal, animated: false) }
    }

    private func setContentHeight(_ height: CGFloat, animated: Bool) {
        let maxHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsLayout.width,
                                                             height: min(height, maxHeight - 40)))
        var frame = window.frame
        guard abs(frame.height - target.height) > 0.5 || abs(frame.width - target.width) > 0.5 else { return }
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        if let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) { select(tab) }
    }

    // MARK: NSToolbarDelegate

    private var identifiers: [NSToolbarItem.Identifier] { SettingsTab.allCases.map { .init($0.rawValue) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        isOpen = false
        DockIcon.windowClosed()
    }
}

/// Settings window: a single reusable window with an icon toolbar, one tab per area.
@MainActor
public enum SettingsWindow {
    private static var controller: SettingsWindowController?

    public static func show() { show(tab: nil) }

    static func show(tab: SettingsTab?) {
        let c = controller ?? SettingsWindowController()
        controller = c
        c.show(tab: tab)
    }
}
