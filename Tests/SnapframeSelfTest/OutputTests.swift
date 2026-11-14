import Foundation
@testable import SnapframeCore

extension SelfTests {
    static let output: [TestCase] = {
        let date: Date = {
            var c = DateComponents()
            c.year = 2026; c.month = 3; c.day = 7; c.hour = 21; c.minute = 5; c.second = 9
            return Calendar(identifier: .gregorian).date(from: c)!
        }()
        return [
            TestCase("FileNamer expands template tokens") {
                try checkEqual(FileNamer.baseName(date: date, template: "Snapframe %Y-%m-%d at %H.%M.%S"), "Snapframe 2026-03-07 at 21.05.09")
                try checkEqual(FileNamer.baseName(date: date, template: "%y%m%d %I%p %% %q"), "260307 09PM % %q")
            },
            TestCase("FileNamer sanitises path separators") {
                try checkEqual(FileNamer.baseName(date: date, template: "a/b:c"), "a-b.c")
            },
            TestCase("uniqueURL keeps @2x suffix last") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                try Data().write(to: dir.appendingPathComponent("Shot@2x.png"))
                try Data().write(to: dir.appendingPathComponent("Shot 2@2x.png"))
                try checkEqual(FileNamer.uniqueURL(in: dir, fileName: "Shot@2x.png").lastPathComponent, "Shot 3@2x.png")
                try checkEqual(FileNamer.uniqueURL(in: dir, fileName: "Other.png").lastPathComponent, "Other.png")
            },
            TestCase("exportFileName adds @2x only for retina images when enabled") {
                var item = CapturedItem(kind: .image, fileURL: URL(fileURLWithPath: "/tmp/x.png"),
                                        pixelSize: CGSize(width: 200, height: 100), scale: 2, baseName: "Shot")
                try checkEqual(item.exportFileName, "Shot@2x.png")
                Prefs.set(false, PrefKey.add2xSuffix)
                try checkEqual(item.exportFileName, "Shot.png")
                Prefs.set(true, PrefKey.add2xSuffix)
                item.scale = 1
                try checkEqual(item.exportFileName, "Shot.png")
            },
            TestCase("Exporter.place onto the source file keeps it intact") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let file = dir.appendingPathComponent("Shot.png")
                try Data("pixels".utf8).write(to: file)
                try Exporter.place(file, at: file)
                try Exporter.place(file, at: dir.appendingPathComponent("../\(dir.lastPathComponent)/Shot.png"))
                try checkEqual(try Data(contentsOf: file), Data("pixels".utf8))
            },
            TestCase("Exporter.place replaces only after the copy exists") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let source = dir.appendingPathComponent("new.png"), dest = dir.appendingPathComponent("old.png")
                try Data("old".utf8).write(to: dest)
                var threw = false
                do { try Exporter.place(dir.appendingPathComponent("missing.png"), at: dest) } catch { threw = true }
                try check(threw, "expected place to throw")
                try checkEqual(try Data(contentsOf: dest), Data("old".utf8))
                try Data("new".utf8).write(to: source)
                try Exporter.place(source, at: dest)
                try checkEqual(try Data(contentsOf: dest), Data("new".utf8))
                try checkEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["new.png", "old.png"])
            },
            TestCase("syncCopies refreshes the exported copy and the clipboard link after an edit") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let file = dir.appendingPathComponent("rec.mp4"), saved = dir.appendingPathComponent("saved.mp4")
                try Data("untrimmed".utf8).write(to: file)
                try Data("untrimmed".utf8).write(to: saved)
                var item = CapturedItem(kind: .video, fileURL: file, pixelSize: CGSize(width: 10, height: 10), scale: 1, baseName: "rec")
                let link = try { () throws -> URL in
                    guard let url = Clipboard.namedCopy(of: item) else { throw CheckFailure(description: "no clipboard copy") }
                    return url
                }()
                defer { try? FileManager.default.removeItem(at: link.deletingLastPathComponent()) }
                item.savedURL = saved
                let temp = dir.appendingPathComponent(".edit.mp4")
                try Data("trimmed".utf8).write(to: temp)
                _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
                try checkEqual(try Data(contentsOf: link), Data("untrimmed".utf8))
                try Exporter.syncCopies(of: item)
                try checkEqual(try Data(contentsOf: link), Data("trimmed".utf8))
                try checkEqual(try Data(contentsOf: saved), Data("trimmed".utf8))
            },
            TestCase("syncCopies leaves an absent clipboard copy absent") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let file = dir.appendingPathComponent("rec.mp4")
                try Data("x".utf8).write(to: file)
                let item = CapturedItem(kind: .video, fileURL: file, pixelSize: CGSize(width: 10, height: 10), scale: 1, baseName: "rec")
                try Exporter.syncCopies(of: item)
                let expected = FileManager.default.temporaryDirectory.appendingPathComponent("Snapframe/\(item.id.uuidString)")
                try check(!FileManager.default.fileExists(atPath: expected.path))
            },
            TestCase("Shortcut storage round-trip") {
                let sc = Shortcut(keyCode: 21, modifiers: 768)
                try checkEqual(Shortcut(storageString: sc.storageString), sc)
                try check(Shortcut(storageString: "") == nil)
            },
        ]
    }()
}
