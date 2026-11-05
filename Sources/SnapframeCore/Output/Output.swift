import AppKit
import UniformTypeIdentifiers

public enum FileNamer {
    /// Expands the strftime-style template from Prefs (e.g. "Snapframe %Y-%m-%d at %H.%M.%S").
    /// Supported tokens: %Y %y %m %d %H %I %M %S %p %%. Unknown tokens are kept verbatim.
    public static func baseName(date: Date = Date(), template: String? = nil) -> String {
        let t = template ?? Prefs.string(PrefKey.fileNameTemplate)
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var out = ""
        var it = t.makeIterator()
        while let ch = it.next() {
            guard ch == "%" else { out.append(ch); continue }
            guard let token = it.next() else { out.append("%"); break }
            switch token {
            case "Y": out += String(format: "%04d", c.year ?? 0)
            case "y": out += String(format: "%02d", (c.year ?? 0) % 100)
            case "m": out += String(format: "%02d", c.month ?? 0)
            case "d": out += String(format: "%02d", c.day ?? 0)
            case "H": out += String(format: "%02d", c.hour ?? 0)
            case "I": out += String(format: "%02d", ((c.hour ?? 0) + 11) % 12 + 1)
            case "M": out += String(format: "%02d", c.minute ?? 0)
            case "S": out += String(format: "%02d", c.second ?? 0)
            case "p": out += (c.hour ?? 0) < 12 ? "AM" : "PM"
            case "%": out += "%"
            default: out += "%\(token)"
            }
        }
        let cleaned = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        return cleaned.isEmpty ? "Snapframe" : cleaned
    }

    /// Returns `dir/name`, appending " 2", " 3"… before the extension if the file exists.
    public static func uniqueURL(in dir: URL, fileName: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        var stem = url.deletingPathExtension().lastPathComponent
        var suffix2x = ""
        if stem.hasSuffix("@2x") { stem.removeLast(3); suffix2x = "@2x" }
        var n = 2
        repeat {
            url = dir.appendingPathComponent("\(stem) \(n)\(suffix2x)").appendingPathExtension(ext)
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}

@MainActor
public enum Exporter {
    /// Saves a copy to the export location (or asks where, if `ask`/the ask-name pref is set).
    /// Returns the saved URL and records it on the item in history.
    @discardableResult
    public static func save(_ item: CapturedItem, ask: Bool = false) -> URL? {
        var fileName = item.exportFileName
        var dir = Prefs.exportDirectory
        if ask || Prefs.bool(PrefKey.askNameAfterCapture) {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fileName
            panel.directoryURL = dir
            if let type = UTType(filenameExtension: item.fileExtension) { panel.allowedContentTypes = [type] }
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            dir = url.deletingLastPathComponent()
            fileName = url.lastPathComponent
            try? FileManager.default.removeItem(at: url) // the panel already confirmed replacing
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = FileNamer.uniqueURL(in: dir, fileName: fileName)
            try FileManager.default.copyItem(at: item.fileURL, to: dest)
            var updated = item
            updated.savedURL = dest
            HistoryStore.shared.update(updated)
            return dest
        } catch {
            NSLog("Snapframe: save failed: \(error)")
            NSSound.beep()
            return nil
        }
    }
}

@MainActor
public enum Clipboard {
    /// Copies per the clipboard-mode pref. File copies use a temp file with the export name so
    /// pasting into Finder/Slack gets a sensible file name.
    public static func copy(_ item: CapturedItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let mode = Prefs.clipboardMode
        var objects: [NSPasteboardWriting] = []
        if mode != .image || item.kind != .image, let fileURL = namedCopy(of: item) {
            objects.append(fileURL as NSURL)
        }
        if item.kind == .image, mode != .file, let image = item.loadImage() {
            objects.append(image)
        }
        pb.writeObjects(objects)
    }

    public static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Hard-links (or copies) the item into a temp folder under its export file name.
    public static func namedCopy(of item: CapturedItem) -> URL? {
        if let saved = item.savedURL, FileManager.default.fileExists(atPath: saved.path) { return saved }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapframe/\(item.id.uuidString)", isDirectory: true)
        let dest = dir.appendingPathComponent(item.exportFileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.linkItem(at: item.fileURL, to: dest) } catch {
                try FileManager.default.copyItem(at: item.fileURL, to: dest)
            }
            return dest
        } catch {
            NSLog("Snapframe: clipboard file copy failed: \(error)")
            return nil
        }
    }
}

@MainActor
public enum Sounds {
    public static func shutter() {
        guard Prefs.bool(PrefKey.playSounds) else { return }
        let name = Prefs.string(PrefKey.shutterSound)
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if name == "Default", let s = NSSound(contentsOfFile: path, byReference: true) { s.play(); return }
        (NSSound(named: NSSound.Name(name)) ?? NSSound(named: "Tink"))?.play()
    }
}

/// Runs the "After capture" actions from General settings.
@MainActor
public enum AfterCapture {
    public static func handle(_ item: CapturedItem) {
        Sounds.shutter()
        NotificationCenter.default.post(name: .snapframeItemCreated, object: item)
        var current = item
        if item.kind == .image {
            if Prefs.bool(PrefKey.afterShotCopy) { Clipboard.copy(current) }
            if Prefs.bool(PrefKey.afterShotSave), let url = Exporter.save(current) { current.savedURL = url }
            if Prefs.bool(PrefKey.afterShotQuickAccess) { QuickAccessController.shared.show(current) }
            if Prefs.bool(PrefKey.afterShotPin) { PinController.shared.pin(current) }
            if Prefs.bool(PrefKey.afterShotAnnotate) { AnnotationEditor.open(current) }
        } else {
            if Prefs.bool(PrefKey.afterRecCopy) { Clipboard.copy(current) }
            if Prefs.bool(PrefKey.afterRecSave), let url = Exporter.save(current) { current.savedURL = url }
            if Prefs.bool(PrefKey.afterRecQuickAccess) { QuickAccessController.shared.show(current) }
            if Prefs.bool(PrefKey.afterRecVideoEditor) { VideoEditor.open(current) }
        }
    }
}
