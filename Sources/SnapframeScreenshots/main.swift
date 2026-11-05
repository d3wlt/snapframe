import AppKit
import ImageIO
import SnapframeCore
import UniformTypeIdentifiers

// Renders the README screenshots offscreen from the app's real windows (no Screen Recording needed).
// Everything persistent (prefs, history, demo media) lives in a throwaway suite / temp directory.

// MARK: - Drawing helpers

func makeImage(width: Int, height: Int, flipped: Bool = true, _ draw: (CGRect) -> Void) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    if flipped {
        ctx.cgContext.translateBy(x: 0, y: CGFloat(height))
        ctx.cgContext.scaleBy(x: 1, y: -1)
        ctx.cgContext.textMatrix = .identity
    }
    let flip = NSGraphicsContext(cgContext: ctx.cgContext, flipped: flipped)
    NSGraphicsContext.current = flip
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

func color(_ hex: String, _ a: CGFloat = 1) -> NSColor { NSColor(hex: hex)!.withAlphaComponent(a) }

func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color c: NSColor) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c]).draw(at: p)
}

func fill(_ r: CGRect, _ c: NSColor, radius: CGFloat = 0) {
    c.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writeImage(_ image: CGImage, to url: URL) { writePNG(image, to: url) }

// MARK: - Demo content

/// A neutral fake analytics UI in points (800 x 500), drawn at 2x.
enum DemoUI {
    static let size = CGSize(width: 800, height: 500)
    static let chartRect = CGRect(x: 232, y: 170, width: 330, height: 190)
    static let statCard = CGRect(x: 232, y: 84, width: 150, height: 66)
    static let keyField = CGRect(x: 592, y: 142, width: 180, height: 30)
    static let button = CGRect(x: 592, y: 198, width: 180, height: 34)

    static func image() -> CGImage {
        makeImage(width: 1600, height: 1000) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: 2, y: 2)
            fill(CGRect(origin: .zero, size: size), color("#F4F5F8"))
            // sidebar
            fill(CGRect(x: 0, y: 0, width: 200, height: 500), color("#E6E8EE"))
            text("Orbit", CGPoint(x: 24, y: 24), size: 20, weight: .bold, color: color("#2B2F3A"))
            for (i, s) in ["Overview", "Reports", "Audience", "Revenue", "Settings"].enumerated() {
                let y = 84 + CGFloat(i) * 40
                if i == 0 { fill(CGRect(x: 12, y: y - 8, width: 176, height: 32), color("#FFFFFF"), radius: 8) }
                fill(CGRect(x: 26, y: y + 1, width: 14, height: 14), color(i == 0 ? "#5B6CFF" : "#A5ABBD"), radius: 4)
                text(s, CGPoint(x: 52, y: y), size: 14, weight: i == 0 ? .semibold : .regular, color: color("#2B2F3A"))
            }
            // header
            text("Overview", CGPoint(x: 232, y: 24), size: 24, weight: .bold, color: color("#1E2230"))
            text("Last 30 days", CGPoint(x: 232, y: 54), size: 13, color: color("#7A8094"))
            // stat cards
            for (i, (label, value)) in [("Visitors", "48.2k"), ("Signups", "3,914"), ("Conversion", "8.1%")].enumerated() {
                let r = statCard.offsetBy(dx: CGFloat(i) * 168, dy: 0)
                fill(r, .white, radius: 10)
                text(label, CGPoint(x: r.minX + 14, y: r.minY + 12), size: 12, color: color("#7A8094"))
                text(value, CGPoint(x: r.minX + 14, y: r.minY + 30), size: 22, weight: .semibold, color: color("#1E2230"))
            }
            // chart
            fill(chartRect, .white, radius: 10)
            text("Signups per week", CGPoint(x: chartRect.minX + 16, y: chartRect.minY + 14), size: 13, weight: .semibold, color: color("#2B2F3A"))
            let heights: [CGFloat] = [60, 84, 72, 110, 96, 128, 104, 70, 138, 118]
            for (i, h) in heights.enumerated() {
                let x = chartRect.minX + 20 + CGFloat(i) * 30.5
                fill(CGRect(x: x, y: chartRect.maxY - 16 - h, width: 20, height: h), color(i == 7 ? "#F2A65A" : "#5B6CFF"), radius: 4)
            }
            // form
            let form = CGRect(x: 580, y: 84, width: 204, height: 276)
            fill(form, .white, radius: 10)
            text("API access", CGPoint(x: form.minX + 14, y: form.minY + 12), size: 13, weight: .semibold, color: color("#2B2F3A"))
            text("Key", CGPoint(x: keyField.minX, y: keyField.minY - 20), size: 11, color: color("#7A8094"))
            fill(keyField, color("#F0F1F5"), radius: 6)
            text("demo-key-8f3a-91c2-77d0", CGPoint(x: keyField.minX + 10, y: keyField.minY + 8), size: 12, weight: .medium, color: color("#2B2F3A"))
            fill(button, color("#5B6CFF"), radius: 8)
            text("Create report", CGPoint(x: button.minX + 52, y: button.minY + 9), size: 13, weight: .semibold, color: .white)
            // table rows
            let table = CGRect(x: 232, y: 378, width: 552, height: 100)
            fill(table, .white, radius: 10)
            for i in 0..<3 {
                let y = table.minY + 14 + CGFloat(i) * 28
                fill(CGRect(x: table.minX + 16, y: y + 3, width: 120 + CGFloat(i * 24), height: 10), color("#DADDE6"), radius: 5)
                fill(CGRect(x: table.maxX - 96, y: y + 3, width: 70, height: 10), color("#E8EAF0"), radius: 5)
            }
        }
    }

    static func annotations() -> [Annotation] {
        let red = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
        var list: [Annotation] = []
        list.append(.rectangle(chartRect.insetBy(dx: -6, dy: -6), color: red, lineWidth: 3, rounded: true))
        list.append(.arrow(from: CGPoint(x: 612, y: 322), to: CGPoint(x: 492, y: 318), color: red, lineWidth: 4))
        list.append(.text("Dip in week 8", at: CGPoint(x: 616, y: 300), fontSize: 18, color: red, background: false))
        list.append(.counter(at: CGPoint(x: 226, y: 164), number: 1, color: blue))
        list.append(.counter(at: CGPoint(x: 578, y: 157), number: 2, color: blue))
        list.append(.counter(at: CGPoint(x: 578, y: 215), number: 3, color: blue))
        list.append(.region(.pixelate, keyField.insetBy(dx: 4, dy: 4).offsetBy(dx: 4, dy: 0), strength: 6))
        return list
    }
}

func gradientScene(_ hue: CGFloat, width: Int = 960, height: Int = 600, label: String) -> CGImage {
    makeImage(width: width, height: height) { r in
        let ctx = NSGraphicsContext.current!.cgContext
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
            NSColor(hue: fmod(hue + 0.12, 1), saturation: 0.7, brightness: 0.55, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: r.width, y: r.height), options: [])
        fill(CGRect(x: r.width * 0.1, y: r.height * 0.18, width: r.width * 0.8, height: r.height * 0.64), color("#FFFFFF", 0.92), radius: 24)
        fill(CGRect(x: r.width * 0.1, y: r.height * 0.18, width: r.width * 0.8, height: 48), color("#FFFFFF", 0.55), radius: 24)
        for i in 0..<3 {
            fill(CGRect(x: r.width * 0.14, y: r.height * 0.34 + CGFloat(i) * 56, width: r.width * (0.5 - CGFloat(i) * 0.08), height: 18),
                 color("#3A3F52", 0.25), radius: 9)
        }
        text(label, CGPoint(x: r.width * 0.14, y: r.height * 0.18 + 10), size: 22, weight: .semibold, color: color("#2B2F3A"))
    }
}

func writeGIF(to url: URL, frames: Int, delay: Double, width: Int = 800, height: Int = 500) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for i in 0..<frames {
        let t = CGFloat(i) / CGFloat(frames)
        let img = makeImage(width: width, height: height) { r in
            let ctx = NSGraphicsContext.current!.cgContext
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                NSColor(hue: 0.60 + 0.10 * t, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor,
                NSColor(hue: 0.78 + 0.10 * t, saturation: 0.7, brightness: 0.55, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: r.width, y: r.height), options: [])
            fill(CGRect(x: 60, y: 70, width: 680, height: 360), color("#FFFFFF", 0.93), radius: 20)
            text("Weekly signups", CGPoint(x: 90, y: 96), size: 24, weight: .semibold, color: color("#2B2F3A"))
            for k in 0..<12 {
                let phase = sin((t * 2 + CGFloat(k) * 0.16) * .pi) * 0.5 + 0.5
                let h = 50 + phase * 190
                fill(CGRect(x: 96 + CGFloat(k) * 50, y: 400 - h, width: 32, height: h), color(k % 5 == 3 ? "#F2A65A" : "#5B6CFF"), radius: 6)
            }
            let cx = 90 + t * 620
            fill(CGRect(x: cx - 14, y: 140 + 10 * sin(t * .pi * 4), width: 28, height: 28), color("#FF4D4D"), radius: 14)
        }
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(dest))
}

// MARK: - Rendering

@MainActor func spin(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor func snapshot(_ view: NSView, scale: Int = 2) -> CGImage {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let b = view.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width) * scale, pixelsHigh: Int(b.height) * scale, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size
    view.cacheDisplay(in: b, to: rep)
    return rep.cgImage!
}

@MainActor func snapshotWindow(_ w: NSWindow) -> CGImage {
    w.appearance = NSAppearance(named: .darkAqua)
    spin(0.3)
    w.layoutIfNeeded()
    return snapshot(w.contentView!.superview!)
}

/// Soft gradient backdrop, padding, rounded corners, drop shadow.
func present(_ images: [(CGImage, CGPoint)], size: CGSize, radius: CGFloat = 12, border: Bool = true) -> CGImage {
    // images: 2x pixels, origin in points (top-left based)
    let W = Int(size.width) * 2, H = Int(size.height) * 2
    return makeImage(width: W, height: H) { r in
        let ctx = NSGraphicsContext.current!.cgContext
        let space = CGColorSpaceCreateDeviceRGB()
        let base = CGGradient(colorsSpace: space, colors: [color("#2B2A5E").cgColor, color("#5A3F86").cgColor, color("#2F6F8F").cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: r.width, y: r.height), options: [])
        for (c, center, rad) in [("#FF7AB6", CGPoint(x: r.width * 0.85, y: r.height * 0.1), r.width * 0.45),
                                 ("#6FD3FF", CGPoint(x: r.width * 0.1, y: r.height * 0.95), r.width * 0.4)] {
            let glow = CGGradient(colorsSpace: space, colors: [color(c, 0.35).cgColor, color(c, 0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: rad, options: [])
        }
        for (image, origin) in images {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let rect = CGRect(x: origin.x * 2, y: origin.y * 2, width: w, height: h)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -36), blur: 90, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            fill(rect, .black, radius: radius * 2)
            ctx.restoreGState()
            ctx.saveGState()
            NSBezierPath(roundedRect: rect, xRadius: radius * 2, yRadius: radius * 2).addClip()
            // flipped context: draw the image upright
            ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: rect)
            ctx.restoreGState()
            if border {
                NSColor.white.withAlphaComponent(0.16).setStroke()
                let p = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius * 2, yRadius: radius * 2)
                p.lineWidth = 1
                p.stroke()
            }
        }
    }
}

func windowShot(_ image: CGImage, padding: CGFloat = 72) -> CGImage {
    let w = CGFloat(image.width) / 2, h = CGFloat(image.height) / 2
    return present([(image, CGPoint(x: padding, y: padding))], size: CGSize(width: w + 2 * padding, height: h + 2 * padding + 16))
}

// MARK: - Main

MainActor.assumeIsolated {
    let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/readme", isDirectory: true)
    try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-shots-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let suite = "snapframe.screenshots.\(UUID().uuidString)"
    defer {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: work)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .darkAqua)
    Prefs.store = UserDefaults(suiteName: suite)!
    Prefs.register()
    Prefs.set("~/Pictures/Screenshots", PrefKey.exportLocation)
    let historyDir = work.appendingPathComponent("History", isDirectory: true)
    try! FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    HistoryStore.directory = historyDir

    func save(_ image: CGImage, _ name: String) {
        writePNG(image, to: outDir.appendingPathComponent(name))
        print("wrote \(name) \(image.width)x\(image.height)")
    }

    // 1. Settings
    for (tab, name) in [("general", "settings.png")] {
        let w = ReadmeScenes.settingsWindow(tab: tab)
        spin(0.8)
        save(windowShot(snapshotWindow(w)), name)
    }

    // 2. Annotate
    let demoURL = work.appendingPathComponent("demo-dashboard@2x.png")
    writePNG(DemoUI.image(), to: demoURL)
    if let w = ReadmeScenes.annotateWindow(imageURL: demoURL, annotations: DemoUI.annotations()) {
        spin(0.8)
        save(windowShot(snapshotWindow(w)), "annotate.png")
    } else { print("annotate failed") }

    // 3. Trim editor
    let gifURL = work.appendingPathComponent("demo.gif")
    writeGIF(to: gifURL, frames: 30, delay: 0.1)
    let gifItem = CapturedItem(kind: .gif, fileURL: gifURL, pixelSize: CGSize(width: 800, height: 500), scale: 1, baseName: "Demo recording")
    var trimWindow: NSWindow?
    Task { @MainActor in
        trimWindow = await ReadmeScenes.trimEditorWindow(item: gifItem, trim: 0.6...2.4, playhead: 1.2)
    }
    while trimWindow == nil { spin(0.1) }
    spin(0.5)
    save(windowShot(snapshotWindow(trimWindow!)), "trim-editor.png")

    // 4. Quick Access
    func item(_ image: CGImage, _ name: String, kind: MediaKind = .image, ext: String = "png", date: Date) -> CapturedItem {
        let url = historyDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        writePNG(image, to: url)
        return CapturedItem(kind: kind, fileURL: url, createdAt: date, pixelSize: CGSize(width: image.width, height: image.height), scale: 2, baseName: name)
    }
    let now = Date()
    let qaGif = historyDir.appendingPathComponent("\(UUID().uuidString).gif")
    try! FileManager.default.copyItem(at: gifURL, to: qaGif)
    let newest = CapturedItem(kind: .gif, fileURL: qaGif, createdAt: now.addingTimeInterval(-30), pixelSize: CGSize(width: 800, height: 500),
                              scale: 1, baseName: "Demo recording")
    let shot1 = item(DemoUI.image(), "Snapframe 2026-11-05 at 10.42.07", date: now.addingTimeInterval(-60))
    let stack = ReadmeScenes.quickAccessStack(items: [newest, shot1])
    stack.appearance = NSAppearance(named: .darkAqua)
    spin(1.5)
    let pad: CGFloat = 64
    let placed = stack.subviews.map { card in
        (snapshot(card), CGPoint(x: pad + card.frame.minX, y: pad + stack.bounds.height - card.frame.maxY))
    }
    save(present(placed, size: CGSize(width: stack.bounds.width + 2 * pad, height: stack.bounds.height + 2 * pad), radius: 12), "quick-access.png")

    // 5. History
    var items: [CapturedItem] = []
    let scenes: [(CGFloat, String)] = [(0.58, "Settings"), (0.08, "Invoice"), (0.35, "Deploy log"), (0.75, "Mockup")]
    for (i, s) in scenes.enumerated() {
        items.append(item(gradientScene(s.0, label: s.1), "Demo \(i)", date: now.addingTimeInterval(-Double(i + 1) * 5400)))
    }
    items.insert(item(DemoUI.image(), "Demo dashboard", date: now.addingTimeInterval(-600)), at: 0)
    let gifHistory = historyDir.appendingPathComponent("\(UUID().uuidString).gif")
    try! FileManager.default.copyItem(at: gifURL, to: gifHistory)
    items.insert(CapturedItem(kind: .gif, fileURL: gifHistory, createdAt: now.addingTimeInterval(-2400), pixelSize: CGSize(width: 800, height: 500), scale: 1, baseName: "Demo recording"), at: 2)
    for i in items { HistoryStore.shared.add(i) }
    let hw = ReadmeScenes.historyWindow()
    spin(2.0)
    save(windowShot(snapshotWindow(hw)), "history.png")
}
