import AppKit
import Foundation
@testable import SnapframeCore

/// Solid-colour test image (top half colour `top`, bottom half `bottom`), sRGB.
private func solid(_ w: Int, _ h: Int, top: CGColor, bottom: CGColor? = nil, space: CGColorSpace? = nil) -> CGImage {
    let ctx = ImageOps.context(width: w, height: h, colorSpace: space)!
    ctx.setFillColor(bottom ?? top)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(top)
    ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))
    return ctx.makeImage()!
}

/// White canvas with black text drawn at a large size, for OCR.
@MainActor private func textImage(_ text: String, size: CGSize = CGSize(width: 900, height: 160)) -> CGImage {
    let ctx = ImageOps.context(width: Int(size.width), height: Int(size.height))!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 72, weight: .regular),
                                                  .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 30, y: 40))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

extension SelfTests {
    static let capture: [TestCase] = {
        // Main display 1440x900 at the origin; a second display left of it (1920x1080) whose top is
        // 120 pt higher; a third above the main display.
        let main = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let left = DisplayInfo(id: 2, frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080))
        let above = DisplayInfo(id: 3, frame: CGRect(x: 0, y: 900, width: 1440, height: 900))
        let displays = [main, left, above]

        return [
            TestCase("Global AppKit rect -> display-local top-left rect") {
                // 100x50 rect, 10 pt from the main display's bottom-left corner.
                let r = CaptureGeometry.localRect(fromGlobal: CGRect(x: 10, y: 10, width: 100, height: 50), displayFrame: main.frame)
                try checkEqual(r, CGRect(x: 10, y: 840, width: 100, height: 50))
                // Display left of main, extending lower than main's bottom edge (negative y).
                let l = CaptureGeometry.localRect(fromGlobal: CGRect(x: -1900, y: -100, width: 200, height: 100), displayFrame: left.frame)
                try checkEqual(l, CGRect(x: 20, y: 900, width: 200, height: 100))
                // Round-trip on every display.
                for d in displays {
                    let g = CGRect(x: d.frame.minX + 30, y: d.frame.minY + 40, width: 123, height: 77)
                    let back = CaptureGeometry.globalRect(fromLocal: CaptureGeometry.localRect(fromGlobal: g, displayFrame: d.frame),
                                                          displayFrame: d.frame)
                    try checkEqual(back, g)
                }
            },
            TestCase("Selection area picks display of the anchor and clamps to it") {
                // Dragging on the display above main, starting at its bottom-left, overflowing to the left.
                let a = CaptureGeometry.area(forGlobalRect: CGRect(x: -50, y: 900, width: 200, height: 100),
                                             anchor: CGPoint(x: 80, y: 950), displays: displays)
                try checkEqual(a?.displayID, 3)
                try checkEqual(a?.rect, CGRect(x: 0, y: 800, width: 150, height: 100))
                // Display left of main: a rect near its top edge (global y 890..900) is at local y 0.
                let b = CaptureGeometry.area(forGlobalRect: CGRect(x: -1920, y: 880, width: 100, height: 20),
                                             anchor: CGPoint(x: -1900, y: 890), displays: displays)
                try checkEqual(b?.displayID, 2)
                try checkEqual(b?.rect, CGRect(x: 0, y: 0, width: 100, height: 20))
                try check(CaptureGeometry.display(containing: CGPoint(x: -5, y: 100), in: displays)?.id == 2)
                try checkEqual(CaptureGeometry.display(containing: CGPoint(x: 700, y: 900), in: [main])?.id, 1) // y == maxY
                try check(CaptureGeometry.display(containing: CGPoint(x: 1440, y: 100), in: displays)?.id == 1,
                          "off the right edge snaps to nearest display")
            },
            TestCase("Quartz window frames convert to AppKit coordinates") {
                // Primary is 900 tall: a window at the top-left in Quartz sits at the top in AppKit.
                let r = CaptureGeometry.appKitRect(fromQuartz: CGRect(x: 100, y: 0, width: 300, height: 200), primaryHeight: 900)
                try checkEqual(r, CGRect(x: 100, y: 700, width: 300, height: 200))
                let hit = CaptureGeometry.topmost(at: CGPoint(x: 150, y: 750), in: [r, CGRect(x: 0, y: 0, width: 2000, height: 2000)]) { $0 }
                try checkEqual(hit, r)
            },
            TestCase("Drag rect: square lock and clamping") {
                let b = CGRect(x: 0, y: 0, width: 500, height: 400)
                let free = CaptureGeometry.dragRect(anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 40, y: 220), square: false, bounds: b)
                try checkEqual(free, CGRect(x: 40, y: 100, width: 60, height: 120))
                let sq = CaptureGeometry.dragRect(anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 40, y: 220), square: true, bounds: b)
                // |dx|=60, |dy|=120 -> side 120, but the left bound allows only 100.
                try checkEqual(sq, CGRect(x: 0, y: 100, width: 100, height: 100))
                let clamped = CaptureGeometry.dragRect(anchor: CGPoint(x: 450, y: 350), current: CGPoint(x: 900, y: 900), square: false, bounds: b)
                try checkEqual(clamped, CGRect(x: 450, y: 350, width: 50, height: 50))
            },
            TestCase("Holding Space moves the selection instead of resizing it") {
                var t = SelectionTracker(start: CGPoint(x: 100, y: 100), bounds: CGRect(x: 0, y: 0, width: 500, height: 400))
                t.drag(to: CGPoint(x: 200, y: 180), space: false, square: false)
                try checkEqual(t.rect, CGRect(x: 100, y: 100, width: 100, height: 80))
                t.drag(to: CGPoint(x: 260, y: 200), space: true, square: false)
                try checkEqual(t.rect, CGRect(x: 160, y: 120, width: 100, height: 80))
                // Releasing space resumes resizing from the moved anchor.
                t.drag(to: CGPoint(x: 300, y: 250), space: false, square: false)
                try checkEqual(t.rect, CGRect(x: 160, y: 120, width: 140, height: 130))
                // Moving into the edge clamps without changing the size.
                t.drag(to: CGPoint(x: 900, y: 900), space: true, square: false)
                try checkEqual(t.rect.size, CGSize(width: 140, height: 130))
                try check(t.rect.maxX <= 500 && t.rect.maxY <= 400)
                try check(!t.isClick)
                var click = SelectionTracker(start: CGPoint(x: 5, y: 5), bounds: CGRect(x: 0, y: 0, width: 50, height: 50))
                click.drag(to: CGPoint(x: 6, y: 5), space: false, square: false)
                try check(click.isClick)
            },
            TestCase("Pixel crop maps points to the frozen frame on Retina") {
                let r = CaptureGeometry.pixelCropRect(pointRect: CGRect(x: 10, y: 20, width: 100, height: 50),
                                                      displaySize: CGSize(width: 1440, height: 900),
                                                      imageSize: CGSize(width: 2880, height: 1800))
                try checkEqual(r, CGRect(x: 20, y: 40, width: 200, height: 100))
            },
            TestCase("lastArea storage round-trips") {
                let a = ScreenArea(displayID: 69_733_248, rect: CGRect(x: 12.5, y: 40, width: 300, height: 200.25))
                try checkEqual(AreaStorage.decode(AreaStorage.encode(a)), a)
                try check(AreaStorage.decode("") == nil)
                try check(AreaStorage.decode("1 2 3 0 5") == nil, "zero width is invalid")
                try check(AreaStorage.decode("x 2 3 4 5") == nil)
            },
            TestCase("Window composer: size with padding, transparent corner, wallpaper corner") {
                let win = solid(400, 300, top: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                let pad = WindowComposer.paddingPixels(ticks: 2, windowSize: CGSize(width: 400, height: 300))
                try check(pad > 0 && pad < 150, "default padding is a sensible fraction (\(pad))")
                try checkEqual(WindowComposer.paddingPixels(ticks: 0, windowSize: CGSize(width: 400, height: 300)), 0)
                try check(WindowComposer.paddingPixels(ticks: 6, windowSize: CGSize(width: 400, height: 300)) > pad)

                let t = WindowComposer.compose(window: win, background: .transparent, padding: pad, shadow: true)!
                try checkEqual(t.width, 400 + 2 * pad)
                try checkEqual(t.height, 300 + 2 * pad)
                try checkEqual(ImageOps.pixel(t, x: 0, y: 0)?.a, 0)
                try checkEqual(ImageOps.pixel(t, x: pad + 200, y: pad + 150)?.r, 255)

                let bgImage = solid(64, 32, top: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                let w = WindowComposer.compose(window: win, background: .image(bgImage), padding: pad, shadow: false)!
                let corner = ImageOps.pixel(w, x: 0, y: 0)
                try checkEqual(corner?.a, 255)
                try check((corner?.b ?? 0) > 200 && (corner?.r ?? 255) < 30, "corner shows the wallpaper")

                let none = WindowComposer.compose(window: win, background: .transparent, padding: 0, shadow: false)!
                try checkEqual(none.width, 400)
                // Padding 0 + shadow + transparent: a margin is added and the shadow shows in it.
                let ns = WindowComposer.compose(window: win, background: .transparent, padding: 0, shadow: true)!
                let m = WindowComposer.shadowMargin(for: win)
                try check(m >= 16 && ns.width == 400 + 2 * m && ns.height == 300 + 2 * m, "margin \(m), width \(ns.width)")
                try checkEqual(ImageOps.pixel(ns, x: 0, y: 0)?.a, 0)
                try check((ImageOps.pixel(ns, x: m + 200, y: m + 300 + 4)?.a ?? 0) > 20, "shadow visible below the window")
                // Opaque background with padding 0 stays exactly the window size.
                let flat = WindowComposer.compose(window: win, background: .color(CGColor(gray: 1, alpha: 1)), padding: 0, shadow: true)!
                try checkEqual(flat.width, 400)
                // A drop shadow darkens the padding next to the window.
                let shadowed = WindowComposer.compose(window: win, background: .color(CGColor(gray: 1, alpha: 1)), padding: 80, shadow: true)!
                let near = ImageOps.pixel(shadowed, x: 80 + 200, y: 80 + 300 + 6)  // just below the window (y grows downward)
                try check((near?.r ?? 255) < 235, "shadow tints the area beside the window")
            },
            TestCase("Aspect fill covers the container and centres") {
                let r = ImageOps.aspectFillRect(imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 100, height: 100))
                try checkEqual(r, CGRect(x: -50, y: 0, width: 200, height: 100))
            },
            TestCase("Post-processor: scale to 1x halves a Retina image") {
                let img = solid(400, 200, top: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
                let out = ImagePostProcessor.process(img, scale: 2, scaleTo1x: true, convertSRGB: false, border: false, presetID: "")
                try checkEqual(out.image.width, 200)
                try checkEqual(out.image.height, 100)
                try checkEqual(out.scale, 1)
                let keep = ImagePostProcessor.process(img, scale: 2, scaleTo1x: false, convertSRGB: false, border: false, presetID: "")
                try checkEqual(keep.image.width, 400)
                try checkEqual(keep.scale, 2)
                let already = ImagePostProcessor.process(img, scale: 1, scaleTo1x: true, convertSRGB: false, border: false, presetID: "")
                try checkEqual(already.image.width, 400)
            },
            TestCase("Post-processor: border pixel differs from the interior") {
                let img = solid(40, 30, top: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                let out = ImagePostProcessor.process(img, scale: 1, scaleTo1x: false, convertSRGB: false, border: true, presetID: "").image
                try checkEqual(out.width, 42)
                let edge = ImageOps.pixel(out, x: 0, y: 10)!
                let inside = ImageOps.pixel(out, x: 1, y: 10)!
                try check(edge.r < 120 && edge.r > 20, "subtle dark gray, got \(edge.r)")
                try checkEqual(inside.r, 255)
                try check((ImageOps.pixel(out, x: 21, y: 31)?.r ?? 255) < 120, "bottom edge is bordered too")
                try check((ImageOps.pixel(out, x: 21, y: 0)?.r ?? 255) < 120, "top edge is bordered too")
            },
            TestCase("Post-processor: sRGB conversion changes the colour space") {
                let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
                let img = solid(20, 20, top: CGColor(red: 1, green: 0, blue: 0, alpha: 1), space: p3)
                try check(img.colorSpace?.name != CGColorSpace.sRGB)
                let out = ImagePostProcessor.process(img, scale: 2, scaleTo1x: false, convertSRGB: true, border: false, presetID: "")
                try checkEqual(out.image.colorSpace?.name as String?, CGColorSpace.sRGB as String)
                let untouched = ImagePostProcessor.process(img, scale: 2, scaleTo1x: false, convertSRGB: false, border: false, presetID: "")
                try check(untouched.image.colorSpace?.name != CGColorSpace.sRGB)
                // Unknown preset id is ignored.
                let same = ImagePostProcessor.process(img, scale: 2, scaleTo1x: false, convertSRGB: false, border: false, presetID: "nope")
                try checkEqual(same.image.width, 20)
            },
            TestCase("Post-processor reads its flags from Prefs") {
                Prefs.set(true, PrefKey.shotScaleTo1x)
                Prefs.set(true, PrefKey.shotBorder)
                let img = solid(100, 60, top: CGColor(gray: 1, alpha: 1))
                let out = ImagePostProcessor.process(img, scale: 2)
                try checkEqual(out.scale, 1)
                try checkEqual(out.image.width, 52)
                try checkEqual(out.image.height, 32)
            },
            TestCase("OCR reads rendered text") {
                Prefs.set("auto", PrefKey.ocrLanguage)
                let text = try await TextRecognizer.recognize(textImage("Hello Snapframe 2026"))
                try check(text.localizedCaseInsensitiveContains("Hello"), "got '\(text)'")
                try check(text.localizedCaseInsensitiveContains("Snapframe"), "got '\(text)'")
                try check(text.contains("2026"), "got '\(text)'")
            },
            TestCase("OCR with an explicit language still reads text") {
                Prefs.set("en-US", PrefKey.ocrLanguage)
                let text = try await TextRecognizer.recognize(textImage("Screenshot"))
                try check(text.localizedCaseInsensitiveContains("Screenshot"), "got '\(text)'")
            },
            TestCase("Text join: spaces vs line breaks") {
                let lines = ["First line", "  second line ", "", "third"]
                try checkEqual(TextJoiner.join(lines, keepLineBreaks: false, detectLinks: true), "First line second line third")
                try checkEqual(TextJoiner.join(lines, keepLineBreaks: true, detectLinks: true), "First line\nsecond line\nthird")
                try checkEqual(TextJoiner.join([], keepLineBreaks: false, detectLinks: true), "")
            },
            TestCase("Text join: a URL split across lines is rejoined without a space") {
                let wrapped = ["Docs at https://example.com/guides/getting-", "started/index.html for details"]
                try checkEqual(TextJoiner.join(wrapped, keepLineBreaks: false, detectLinks: true),
                               "Docs at https://example.com/guides/getting-started/index.html for details")
                try checkEqual(TextJoiner.join(wrapped, keepLineBreaks: false, detectLinks: false),
                               "Docs at https://example.com/guides/getting- started/index.html for details")
                // Next line starts with a path separator.
                try checkEqual(TextJoiner.join(["Open https://example.com", "/pricing?plan=pro now"], keepLineBreaks: false, detectLinks: true),
                               "Open https://example.com/pricing?plan=pro now")
                // A URL that simply ends a sentence keeps the space; so do plain words ending in a dash.
                try checkEqual(TextJoiner.join(["See https://example.com", "Next sentence."], keepLineBreaks: false, detectLinks: true),
                               "See https://example.com Next sentence.")
                try checkEqual(TextJoiner.join(["well-", "known fact"], keepLineBreaks: false, detectLinks: true), "well- known fact")
                try checkEqual(TextJoiner.join(["https://example.com", "- bullet"], keepLineBreaks: false, detectLinks: true),
                               "https://example.com - bullet")
            },
        ]
    }()
}
