import AppKit
import SwiftUI

@MainActor
public enum HistoryWindow {
    private static var window: NSWindow?
    private static let delegate = WindowDelegate()

    public static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Capture History"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 320)
        w.contentView = NSHostingView(rootView: HistoryView())
        w.delegate = delegate
        w.setFrameAutosaveName("SnapframeHistoryWindow")
        if !w.setFrameUsingName("SnapframeHistoryWindow") { w.center() }
        window = w
        DockIcon.windowOpened()
        w.makeKeyAndOrderFront(nil)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                HistoryWindow.window = nil
                DockIcon.windowClosed()
            }
        }
    }
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published var items: [CapturedItem] = []
    /// Bumped when an editor rewrites an item's file, so its cell reloads the thumbnail.
    @Published var revisions: [UUID: Int] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: HistoryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(center.addObserver(forName: .snapframeItemUpdated, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? CapturedItem)?.id
            MainActor.assumeIsolated {
                if let id { self?.revisions[id, default: 0] += 1 }
                self?.reload()
            }
        })
    }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func reload() {
        let fm = FileManager.default
        items = HistoryStore.shared.items.filter { fm.fileExists(atPath: $0.fileURL.path) }
    }
}

struct HistoryView: View {
    @StateObject private var model = HistoryModel()
    @State private var selection: UUID?

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 16, alignment: .top)]

    var body: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.items) { item in
                            HistoryCell(item: item, selected: selection == item.id, revision: model.revisions[item.id] ?? 0)
                                .onTapGesture(count: 2) { QuickAccessController.shared.show(item) }
                                .onTapGesture { selection = item.id }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var retentionNote: String {
        switch Prefs.historyRetention {
        case .never: return "History is off. Captures are removed after 10 minutes."
        case .day: return "Captures are kept for 1 day."
        case .threeDays: return "Captures are kept for 3 days."
        case .week: return "Captures are kept for 1 week."
        case .month: return "Captures are kept for 1 month."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No captures yet")
                .font(.title3.weight(.medium))
            Text("Screenshots and recordings you take show up here.\n\(retentionNote)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for item: CapturedItem) -> some View {
        Button("Copy") { Clipboard.copy(item) }
        Button("Save…") { Exporter.save(item, ask: true) }
        if item.kind == .image {
            Button("Annotate") { AnnotationEditor.open(item) }
        }
        if item.kind != .image {
            Button("Edit") { VideoEditor.open(item) }
        }
        if item.kind != .video {
            Button("Pin to Screen") { PinController.shared.pin(item) }
        }
        Button("Show in Finder") {
            let saved = item.savedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            NSWorkspace.shared.activateFileViewerSelecting([saved ?? item.fileURL])
        }
        Divider()
        Button("Delete", role: .destructive) { HistoryStore.shared.remove(item, deleteFile: true) }
    }
}

private struct HistoryCell: View {
    let item: CapturedItem
    let selected: Bool
    let revision: Int
    @State private var image: NSImage?
    @State private var duration: TimeInterval?
    @Environment(\.displayScale) private var displayScale

    private static let thumbSize = CGSize(width: 220, height: 150)

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .padding(8)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 118)
            .overlay(alignment: .bottomTrailing) { if item.kind != .image { badge.padding(8) } }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            Text(Self.caption(item.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: TaskKey(url: item.fileURL, revision: revision)) {
            let scale = displayScale
            if let hit = Thumbnails.cached(item, size: Self.thumbSize, scale: scale) {
                image = hit
            } else {
                image = await Thumbnails.thumbnail(for: item, size: Self.thumbSize, scale: scale)
            }
            duration = await Thumbnails.duration(of: item)
        }
    }

    /// Re-runs the thumbnail task when an editor overwrites the same file.
    private struct TaskKey: Hashable {
        let url: URL
        let revision: Int
    }

    private var badge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.kind == .gif ? "photo.stack" : "play.fill").font(.system(size: 8, weight: .bold))
            Text(item.kind == .gif ? "GIF" : (duration.map(Thumbnails.formatDuration) ?? "Video"))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(.black.opacity(0.65)))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func caption(_ date: Date) -> String { formatter.string(from: date) }
}
