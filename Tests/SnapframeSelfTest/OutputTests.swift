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
            TestCase("Shortcut storage round-trip") {
                let sc = Shortcut(keyCode: 21, modifiers: 768)
                try checkEqual(Shortcut(storageString: sc.storageString), sc)
                try check(Shortcut(storageString: "") == nil)
            },
        ]
    }()
}
