import Foundation
@testable import SnapframeCore

@MainActor
private func makeItem(in dir: URL, age: TimeInterval = 0, now: Date = Date(), name: String = UUID().uuidString) throws -> CapturedItem {
    let url = dir.appendingPathComponent("\(name).png")
    try Data([1, 2, 3]).write(to: url)
    return CapturedItem(kind: .image, fileURL: url, createdAt: now.addingTimeInterval(-age),
                        pixelSize: CGSize(width: 200, height: 100), scale: 2, baseName: name)
}

extension SelfTests {
    static let quickAccess: [TestCase] = { () -> [TestCase] in
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875) // visible frame above the Dock
        let history: [TestCase] = [
            TestCase("History persists across store instances and keeps newest first") {
                let dir = HistoryStore.directory
                let now = Date()
                let old = try makeItem(in: dir, age: 100, now: now)
                let new = try makeItem(in: dir, age: 10, now: now)
                let a = HistoryStore(directory: dir)
                a.add(old)
                a.add(new)
                var edited = new
                edited.savedURL = URL(fileURLWithPath: "/tmp/saved.png")
                a.update(edited)
                let b = HistoryStore(directory: dir)
                try checkEqual(b.items.map(\.id), [new.id, old.id])
                try checkEqual(b.items[0].savedURL, edited.savedURL)
                try checkEqual(b.items[0].pixelSize, new.pixelSize)
            },
            TestCase("History drops entries whose file vanished") {
                let dir = HistoryStore.directory
                let keep = try makeItem(in: dir)
                let gone = try makeItem(in: dir)
                let a = HistoryStore(directory: dir)
                a.add(keep)
                a.add(gone)
                try FileManager.default.removeItem(at: gone.fileURL)
                try checkEqual(HistoryStore(directory: dir).items.map(\.id), [keep.id])
            },
            TestCase("Shared store follows HistoryStore.directory changes") {
                let first = HistoryStore.directory
                HistoryStore.shared.add(try makeItem(in: first))
                try checkEqual(HistoryStore.shared.items.count, 1)
                let second = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-selftest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
                HistoryStore.directory = second
                try checkEqual(HistoryStore.shared.items.count, 0)
                HistoryStore.directory = first
                try checkEqual(HistoryStore.shared.items.count, 1)
            },
            TestCase("Prune removes expired in-directory files, keeps recent ones") {
                let dir = HistoryStore.directory
                let now = Date()
                Prefs.set(HistoryRetention.day.rawValue, PrefKey.historyRetention)
                let store = HistoryStore(directory: dir)
                let stale = try makeItem(in: dir, age: 2 * 86_400, now: now)
                let fresh = try makeItem(in: dir, age: 3_600, now: now)
                store.add(stale)
                store.add(fresh)
                store.prune(now: now)
                try checkEqual(store.items.map(\.id), [fresh.id])
                try check(!FileManager.default.fileExists(atPath: stale.fileURL.path), "stale file should be deleted")
                try check(FileManager.default.fileExists(atPath: fresh.fileURL.path), "fresh file must stay")
                try checkEqual(HistoryStore(directory: dir).items.map(\.id), [fresh.id])
            },
            TestCase("Prune keeps expired items that are still on screen") {
                let dir = HistoryStore.directory
                let now = Date()
                Prefs.set(HistoryRetention.never.rawValue, PrefKey.historyRetention)
                let store = HistoryStore(directory: dir)
                let open = try makeItem(in: dir, age: 3_600, now: now)
                let closed = try makeItem(in: dir, age: 3_600, now: now)
                store.add(open)
                store.add(closed)
                store.inUseIDs = { [open.id] }
                store.prune(now: now)
                try checkEqual(store.items.map(\.id), [open.id])
                try check(FileManager.default.fileExists(atPath: open.fileURL.path), "file of an open card must stay")
                try check(!FileManager.default.fileExists(atPath: closed.fileURL.path), "closed item should be deleted")
            },
            TestCase("Prune and remove never delete files outside the history directory") {
                let dir = HistoryStore.directory
                let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-external-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: elsewhere) }
                let now = Date()
                let external = try makeItem(in: elsewhere, age: 40 * 86_400, now: now)
                let external2 = try makeItem(in: elsewhere, age: 0, now: now)
                // A sibling directory sharing the history directory's name as a prefix must not count as inside.
                let sibling = URL(fileURLWithPath: dir.path + "-sibling", isDirectory: true)
                try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: sibling) }
                let lookalike = try makeItem(in: sibling, age: 40 * 86_400, now: now)
                let store = HistoryStore(directory: dir)
                [external, external2, lookalike].forEach(store.add)
                store.prune(now: now)
                try checkEqual(store.items.map(\.id), [external2.id])
                store.remove(external2, deleteFile: true)
                for item in [external, external2, lookalike] {
                    try check(FileManager.default.fileExists(atPath: item.fileURL.path), "\(item.baseName) must survive")
                }
            },
            TestCase("Retention .never keeps only the last 10 minutes") {
                let dir = HistoryStore.directory
                let now = Date()
                Prefs.set(HistoryRetention.never.rawValue, PrefKey.historyRetention)
                let store = HistoryStore(directory: dir)
                let old = try makeItem(in: dir, age: 11 * 60, now: now)
                let recent = try makeItem(in: dir, age: 5 * 60, now: now)
                store.add(old)
                store.add(recent)
                store.prune(now: now)
                try checkEqual(store.items.map(\.id), [recent.id])
                try check(!FileManager.default.fileExists(atPath: old.fileURL.path))
            },
            TestCase("Prune sweeps old unreferenced files but keeps indexed, recent and index files") {
                let dir = HistoryStore.directory
                let fm = FileManager.default
                let now = Date()
                Prefs.set(HistoryRetention.day.rawValue, PrefKey.historyRetention)
                let store = HistoryStore(directory: dir)
                let indexed = try makeItem(in: dir, age: 0, now: now)
                store.add(indexed)
                let orphanOld = dir.appendingPathComponent("orphan-old.png")
                let orphanNew = dir.appendingPathComponent("orphan-new.png")
                try Data([9]).write(to: orphanOld)
                try Data([9]).write(to: orphanNew)
                try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: orphanOld.path)
                store.prune(now: now)
                try check(!fm.fileExists(atPath: orphanOld.path), "old orphan should be swept")
                try check(fm.fileExists(atPath: orphanNew.path), "recent unreferenced file must stay")
                try check(fm.fileExists(atPath: indexed.fileURL.path), "indexed file must stay")
                try check(fm.fileExists(atPath: dir.appendingPathComponent("index.json").path), "index must stay")
            },
            TestCase("Corrupt index is set aside instead of being overwritten") {
                let dir = HistoryStore.directory
                let fm = FileManager.default
                try Data("not json".utf8).write(to: dir.appendingPathComponent("index.json"))
                let store = HistoryStore(directory: dir)
                try check(store.items.isEmpty)
                store.add(try makeItem(in: dir))
                let names = try fm.contentsOfDirectory(atPath: dir.path)
                let corrupt = names.filter { $0.hasPrefix("index.corrupt-") }
                try checkEqual(corrupt.count, 1)
                try checkEqual(try String(contentsOf: dir.appendingPathComponent(corrupt[0]), encoding: .utf8), "not json")
                try checkEqual(HistoryStore(directory: dir).items.count, 1)
            },
            TestCase("remove(deleteFile: false) keeps the file") {
                let dir = HistoryStore.directory
                let item = try makeItem(in: dir)
                let store = HistoryStore(directory: dir)
                store.add(item)
                store.remove(item, deleteFile: false)
                try check(store.items.isEmpty)
                try check(FileManager.default.fileExists(atPath: item.fileURL.path))
            },
        ]
        let layout: [TestCase] = [
            TestCase("Quick Access card width follows size ticks and clamps") {
                try checkEqual((0...4).map { QuickAccessLayout.cardWidth(tick: $0) }, [160, 200, 240, 280, 320])
                try checkEqual(QuickAccessLayout.cardWidth(tick: -3), 160)
                try checkEqual(QuickAccessLayout.cardWidth(tick: 9), 320)
            },
            TestCase("Quick Access card keeps aspect ratio within clamps") {
                try checkEqual(QuickAccessLayout.cardSize(tick: 2, aspect: 1.25), CGSize(width: 240, height: 192))
                try checkEqual(QuickAccessLayout.cardSize(tick: 2, aspect: 2), CGSize(width: 240, height: 144))
                try checkEqual(QuickAccessLayout.cardSize(tick: 2, aspect: 1), CGSize(width: 240, height: 240))
                // Ultra-wide strip: height floors at 0.6 x width; tall page: caps at 1.3 x width.
                try checkEqual(QuickAccessLayout.cardSize(tick: 0, aspect: 10), CGSize(width: 160, height: 96))
                try checkEqual(QuickAccessLayout.cardSize(tick: 0, aspect: 0.2), CGSize(width: 160, height: 208))
                try checkEqual(QuickAccessLayout.cardSize(tick: 2, aspect: .nan).width, 240)
            },
            TestCase("Slide-in nudge stays within the margin") {
                let f = CGRect(x: 16, y: 41, width: 240, height: 150)
                try check(QuickAccessLayout.slideFrame(for: f, position: .left).minX >= screen.minX)
                let r = CGRect(x: 1184, y: 41, width: 240, height: 150)
                try check(QuickAccessLayout.slideFrame(for: r, position: .right).maxX <= screen.maxX)
            },
            TestCase("Quick Access stacks newest at the bottom corner, older above") {
                let sizes = [CGSize(width: 240, height: 150), CGSize(width: 240, height: 100), CGSize(width: 240, height: 120)]
                let left = QuickAccessLayout.frames(sizes: sizes, in: screen, position: .left)
                try checkEqual(left[0], CGRect(x: 16, y: 41, width: 240, height: 150))
                try checkEqual(left[1], CGRect(x: 16, y: 201, width: 240, height: 100))
                try checkEqual(left[2], CGRect(x: 16, y: 311, width: 240, height: 120))
                let right = QuickAccessLayout.frames(sizes: sizes, in: screen, position: .right)
                try checkEqual(right.map(\.minX), [1184, 1184, 1184])
                try checkEqual(right.map(\.minY), left.map(\.minY))
            },
            TestCase("Quick Access right edge uses each card's own width and a shifted visible frame") {
                let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
                let frames = QuickAccessLayout.frames(sizes: [CGSize(width: 160, height: 100), CGSize(width: 320, height: 100)],
                                                      in: second, position: .right)
                try checkEqual(frames[0].maxX, 3344)
                try checkEqual(frames[1].maxX, 3344)
                try checkEqual(frames[0].minY, 16)
            },
            TestCase("Quick Access hides cards that no longer fit on screen") {
                let sizes = Array(repeating: CGSize(width: 240, height: 200), count: 6)
                let frames = QuickAccessLayout.frames(sizes: sizes, in: screen, position: .left)
                let visible = frames.map { QuickAccessLayout.fits($0, in: screen) }
                // Card n tops out at 241 + 210n; the limit is 900 - 16 = 884, so n = 0...3 fit (871) and n = 4 (1081) does not.
                try checkEqual(visible, [true, true, true, true, false, false])
            },
            TestCase("Pin shrinks oversized images to fit and never enlarges small ones") {
                let big = PinLayout.initialSize(for: CGSize(width: 4000, height: 1000), in: screen)
                try checkEqual(big, CGSize(width: 1296, height: 324))
                try checkEqual(PinLayout.initialSize(for: CGSize(width: 300, height: 200), in: screen), CGSize(width: 300, height: 200))
            },
            TestCase("Pin zoom keeps aspect ratio, anchor point and clamps") {
                let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
                let z = PinLayout.zoomed(frame, factor: 2, anchor: CGPoint(x: 100, y: 100), limits: 60...2000)
                try checkEqual(z, CGRect(x: 100, y: 100, width: 800, height: 400))
                let center = PinLayout.zoomed(frame, factor: 0.5, anchor: CGPoint(x: 300, y: 200), limits: 60...2000)
                try checkEqual(center, CGRect(x: 200, y: 150, width: 200, height: 100))
                let tiny = PinLayout.zoomed(frame, factor: 0.01, anchor: CGPoint(x: 300, y: 200), limits: 60...2000)
                try checkEqual(tiny.width, 60)
                try checkEqual(tiny.width / tiny.height, 2)
            },
        ]
        return history + layout
    }()
}
