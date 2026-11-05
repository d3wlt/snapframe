import AppKit

/// Persistent capture history: an `index.json` next to the stored files. Main-thread use.
/// The shared store follows `HistoryStore.directory` on every operation (tests swap it per test).
public final class HistoryStore {
    public static let shared: HistoryStore = {
        let store = HistoryStore(directory: nil)
        store.scheduleHourlyPrune()
        // Editors post the updated item (new size after a crop, etc.); keep the index in sync.
        store.updateObserver = NotificationCenter.default.addObserver(forName: .snapframeItemUpdated, object: nil,
                                                                      queue: .main) { [weak store] note in
            if let item = note.object as? CapturedItem { store?.update(item) }
        }
        return store
    }()

    /// Posted on the main thread after any change to the item list.
    public static let didChange = Notification.Name("snapframe.historyChanged")

    /// ~/Library/Application Support/Snapframe/History (created on first access). Overridable for tests.
    public static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Snapframe/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Pinned directory for stores created in tests; nil = follow `HistoryStore.directory`.
    private let fixedDirectory: URL?
    private var loadedDirectory: URL?
    private var storage: [CapturedItem] = []
    private var timer: Timer?
    private var updateObserver: NSObjectProtocol?

    /// Items still on screen (Quick Access cards, pins) are never pruned. Main thread only.
    var inUseIDs: () -> Set<UUID> = {
        MainActor.assumeIsolated { QuickAccessController.shared.openItemIDs.union(PinController.shared.openItemIDs) }
    }

    init(directory: URL?) {
        fixedDirectory = directory
    }

    private var directory: URL { fixedDirectory ?? Self.directory }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// Newest first. Entries whose file has vanished are dropped.
    public var items: [CapturedItem] {
        loadIfNeeded()
        return storage
    }

    public func add(_ item: CapturedItem) {
        loadIfNeeded()
        storage.removeAll { $0.id == item.id }
        // Keep newest-first by creation date; a fresh capture lands at index 0.
        let index = storage.firstIndex { $0.createdAt <= item.createdAt } ?? storage.count
        storage.insert(item, at: index)
        commit()
    }

    public func update(_ item: CapturedItem) {
        loadIfNeeded()
        guard let i = storage.firstIndex(where: { $0.id == item.id }) else { return }
        storage[i] = item
        commit()
    }

    /// Removes the entry. The file is deleted only when `deleteFile` is set and it lives inside the history directory.
    public func remove(_ item: CapturedItem, deleteFile: Bool = true) {
        loadIfNeeded()
        guard let i = storage.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = storage.remove(at: i)
        if deleteFile { deleteIfInside(removed.fileURL) }
        commit()
    }

    /// Deletes items (and their files) older than the retention pref. `.never` means history is off:
    /// everything older than 10 minutes goes.
    public func prune(now: Date = Date()) {
        loadIfNeeded()
        let maxAge = Prefs.historyRetention.seconds ?? 600
        let cutoff = now.addingTimeInterval(-maxAge)
        let inUse = inUseIDs()
        let expired = storage.filter { $0.createdAt < cutoff && !inUse.contains($0.id) }
        if !expired.isEmpty {
            let expiredIDs = Set(expired.map(\.id))
            storage.removeAll { expiredIDs.contains($0.id) }
            for item in expired { deleteIfInside(item.fileURL) }
            commit()
        }
        sweepUnreferencedFiles(olderThan: cutoff)
    }

    /// Deletes files directly inside the history directory that no entry references (orphans from a lost
    /// index or a crash) once their modification date is past the cutoff. The index files are never touched.
    private func sweepUnreferencedFiles(olderThan cutoff: Date) {
        let fm = FileManager.default
        let referenced = Set(storage.map { $0.fileURL.resolvingSymlinksInPath().standardizedFileURL.path })
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for url in files {
            if url.lastPathComponent.hasPrefix("index") && url.pathExtension == "json" { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff,
                  !referenced.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) else { continue }
            deleteIfInside(url)
        }
    }

    // MARK: - Internals

    private func scheduleHourlyPrune() {
        let schedule = { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                self?.prune()
            }
            self?.timer?.tolerance = 120
        }
        if Thread.isMainThread { schedule() } else { DispatchQueue.main.async(execute: schedule) }
    }

    private func loadIfNeeded() {
        let dir = directory
        if loadedDirectory == dir { return }
        loadedDirectory = dir
        storage = []
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([CapturedItem].self, from: data) else {
            // Keep the unreadable index for recovery instead of letting the next add() overwrite it.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = dir.appendingPathComponent("index.corrupt-\(stamp).json")
            do { try FileManager.default.moveItem(at: dir.appendingPathComponent("index.json"), to: aside) }
            catch { NSLog("Snapframe: could not set aside corrupt history index: \(error)") }
            NSLog("Snapframe: history index unreadable, moved to \(aside.lastPathComponent)")
            return
        }
        let fm = FileManager.default
        storage = decoded.filter { fm.fileExists(atPath: $0.fileURL.path) }
            .sorted { $0.createdAt > $1.createdAt }
        if storage.count != decoded.count { save() }
    }

    private func commit() {
        save()
        let post = { NotificationCenter.default.post(name: Self.didChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(storage).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Snapframe: could not write history index: \(error)")
        }
    }

    /// Never touches files outside the history directory (external files opened for annotate/pin).
    private func deleteIfInside(_ url: URL) {
        guard Self.isInside(url, directory: directory) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func isInside(_ url: URL, directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
