import AppKit
@testable import SnapframeCore

/// RGBA bytes (premultiplied, sRGB) of an image, for pixel sampling.
private struct Pixels {
    let width: Int, height: Int
    let data: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        width = w; height = h
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        data = buf
    }

    /// (x, y) in top-left pixel coordinates.
    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }

    func luma(_ x: Int, _ y: Int) -> Double {
        let p = at(x, y)
        return 0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b)
    }

    func variance(in r: CGRect) -> Double {
        var vals: [Double] = []
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { vals.append(luma(x, y)) } }
        let mean = vals.reduce(0, +) / Double(vals.count)
        return vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(vals.count)
    }
}

private func solidImage(width: Int, height: Int, gray: CGFloat = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Deterministic high-variance texture.
private func noiseImage(width: Int, height: Int) -> CGImage {
    var buf = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let v = UInt8(truncatingIfNeeded: (x * 73 + y * 151 + (x ^ y) * 29) % 256)
        let i = (y * width + x) * 4
        buf[i] = v; buf[i + 1] = v &* 3; buf[i + 2] = v &* 7
    } }
    let provider = CGDataProvider(data: Data(buf) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

extension SelfTests {
    static let annotate: [TestCase] = [
        TestCase("Rectangle renders stroke, not interior or exterior (scale 2)") {
            // 100x100 pt image at scale 2 = 200x200 px.
            var doc = AnnotationDocument(baseImage: solidImage(width: 200, height: 200), scale: 2)
            doc.annotations = [.rectangle(CGRect(x: 20, y: 20, width: 60, height: 60), color: red, lineWidth: 4)]
            let out = doc.render()
            try checkEqual(out.width, 200)
            let px = Pixels(out)
            // Left edge at x = 20pt -> 40px, stroke covers 36...44 px.
            let stroke = px.at(40, 100)
            try check(stroke.r > 240 && stroke.g < 20 && stroke.b < 20, "stroke pixel \(stroke)")
            let inside = px.at(100, 100), outside = px.at(10, 10)
            try check(inside.g > 240 && inside.b > 240, "interior \(inside)")
            try check(outside.g > 240 && outside.b > 240, "outside \(outside)")
            // Stroke is 4pt = 8px thick: 36 and 43 are covered, 33 and 46 are not.
            try check(px.at(36, 100).g < 20 && px.at(43, 100).g < 20)
            try check(px.at(33, 100).g > 240 && px.at(46, 100).g > 240)
        },
        TestCase("Filled rectangle covers its interior") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 100, height: 100), scale: 1)
            doc.annotations = [.rectangle(CGRect(x: 10, y: 10, width: 50, height: 50), color: red, filled: true)]
            let px = Pixels(doc.render())
            try check(px.at(35, 35).g < 20)
            try check(px.at(70, 70).g > 240)
        },
        TestCase("Crop changes the output size and offsets content") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 200, height: 100), scale: 2)
            doc.annotations = [.rectangle(CGRect(x: 40, y: 10, width: 20, height: 20), color: red, filled: true)]
            try checkEqual(doc.render().width, 200)
            doc.cropRect = CGRect(x: 30, y: 5, width: 40, height: 30)
            let out = doc.render()
            try checkEqual(out.width, 80)
            try checkEqual(out.height, 60)
            // Rect starts at (40-30, 10-5) pt = (10, 5) pt -> (20, 10) px.
            let px = Pixels(out)
            try check(px.at(30, 20).g < 20, "inside cropped rect")
            try check(px.at(5, 5).g > 240, "outside cropped rect")
        },
        TestCase("Pixelate flattens detail inside the region only") {
            let base = noiseImage(width: 200, height: 200)
            var doc = AnnotationDocument(baseImage: base, scale: 2)
            let before = Pixels(doc.render())
            // 40x40 pt region = 80x80 px at (40,40); block = 40pt = 80px -> a single flat block.
            doc.annotations = [.region(.pixelate, CGRect(x: 20, y: 20, width: 40, height: 40), strength: 40)]
            let after = Pixels(doc.render())
            let region = CGRect(x: 40, y: 40, width: 80, height: 80)
            try check(before.variance(in: region) > 1000, "source texture has detail")
            try check(after.variance(in: region) < 5, "pixelated variance \(after.variance(in: region))")
            // Everything outside the region is byte-identical.
            var differing = 0
            for y in 0..<200 { for x in 0..<200 where !region.contains(CGPoint(x: x, y: y)) && before.at(x, y) != after.at(x, y) { differing += 1 } }
            try checkEqual(differing, 0)
        },
        TestCase("Blur softens the region and leaves the rest untouched") {
            var doc = AnnotationDocument(baseImage: noiseImage(width: 160, height: 160), scale: 1)
            let before = Pixels(doc.render())
            doc.annotations = [.region(.blur, CGRect(x: 40, y: 40, width: 60, height: 60), strength: 10)]
            let after = Pixels(doc.render())
            let region = CGRect(x: 40, y: 40, width: 60, height: 60)
            try check(after.variance(in: region) < before.variance(in: region) / 4)
            try check(after.at(5, 5) == before.at(5, 5) && after.at(150, 150) == before.at(150, 150))
        },
        TestCase("Spotlight dims everything outside its rect") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 100, height: 100), scale: 1)
            doc.annotations = [.region(.spotlight, CGRect(x: 30, y: 30, width: 40, height: 40))]
            let px = Pixels(doc.render())
            try check(px.at(50, 50).r > 250)
            try check(px.at(5, 5).r < 140 && px.at(5, 5).r > 60, "dimmed outside \(px.at(5, 5))")
        },
        TestCase("Overlapping spotlights stay bright and the expanded margin is not dimmed") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 100, height: 100), scale: 1)
            doc.annotations = [.region(.spotlight, CGRect(x: 10, y: 10, width: 40, height: 40)),
                               .region(.spotlight, CGRect(x: 30, y: 30, width: 40, height: 40))]
            var px = Pixels(doc.render())
            try check(px.at(40, 40).r > 250, "overlap \(px.at(40, 40))")
            try check(px.at(15, 15).r > 250 && px.at(65, 65).r > 250)
            try check(px.at(90, 10).r < 140, "outside dimmed once")
            doc.autoExpandCanvas = true
            doc.annotations.append(.rectangle(CGRect(x: 80, y: 80, width: 40, height: 40), color: red, filled: true))
            px = Pixels(doc.render())
            try check(px.width > 100)
            try check(px.at(px.width - 3, 5).a == 0, "margin outside the image stays transparent, not dim black")
        },
        TestCase("Dirty state follows content: clicks, selection and undo to the saved state stay clean") {
            let state = EditorState(doc: AnnotationDocument(baseImage: solidImage(width: 50, height: 50), scale: 1))
            // A click with a drawing tool: tiny object added, then removed again on mouse-up.
            state.doc.annotations.append(.arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 5)))
            state.changed()
            state.doc.annotations.removeAll()
            state.changed()
            try check(!state.isDirty, "click without drag")
            try check(!state.canUndo)
            // Selecting without moving.
            state.perform { $0.annotations.append(.rectangle(CGRect(x: 5, y: 5, width: 20, height: 20))) }
            try check(state.isDirty)
            state.markSaved()
            try check(!state.isDirty)
            state.selection = state.doc.annotations[0].id
            state.changed()
            try check(!state.isDirty, "selecting only")
            state.perform { $0.annotations.append(.counter(at: CGPoint(x: 30, y: 30), number: 1)) }
            try check(state.isDirty)
            state.undo()
            try check(!state.isDirty, "undo back to the saved state")
            state.redo()
            try check(state.isDirty)
            state.markSaved()
            state.undo()
            try check(state.isDirty, "undoing past the saved state is a change")
        },
        TestCase("Redaction drag preview is a cheap approximation confined to the region") {
            var doc = AnnotationDocument(baseImage: noiseImage(width: 400, height: 400), scale: 2)
            let region = CGRect(x: 40, y: 40, width: 120, height: 120)
            doc.annotations = [.region(.pixelate, region, strength: 20)]
            let id = doc.annotations[0].id
            let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: 400); ctx.scaleBy(x: 2, y: -2)
            AnnotationRenderer.draw(doc, in: ctx, cache: nil, previewing: [id])
            let px = Pixels(ctx.makeImage()!)
            let plain = Pixels(noiseImage(width: 400, height: 400))
            try check(px.variance(in: CGRect(x: 100, y: 100, width: 120, height: 120)) < plain.variance(in: CGRect(x: 100, y: 100, width: 120, height: 120)) / 4)
            try check(px.at(10, 10) == plain.at(10, 10) && px.at(390, 390) == plain.at(390, 390))
        },
        TestCase("Effect cache keeps one image per redaction and drops removed ones") {
            let cache = EffectCache()
            let a = UUID(), b = UUID()
            var made = 0
            func make() -> CGImage? { made += 1; return solidImage(width: 4, height: 4) }
            _ = cache.image(for: a, key: "r1", make: make)
            _ = cache.image(for: a, key: "r1", make: make)
            try checkEqual(made, 1)
            _ = cache.image(for: a, key: "r2", make: make) // geometry changed: replaces, doesn't accumulate
            _ = cache.image(for: b, key: "r1", make: make)
            try checkEqual(made, 3)
            cache.prune(keeping: [b])
            _ = cache.image(for: a, key: "r2", make: make)
            _ = cache.image(for: b, key: "r1", make: make)
            try checkEqual(made, 4)
        },
        TestCase("Inverse arrow puts the head at the start instead of the end") {
            func headWeight(inverse: Bool) -> (start: Int, end: Int) {
                var doc = AnnotationDocument(baseImage: solidImage(width: 200, height: 60), scale: 1)
                doc.annotations = [.arrow(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 180, y: 30), inverse: inverse,
                                          color: .black, lineWidth: 6)]
                let px = Pixels(doc.render())
                func dark(_ xs: ClosedRange<Int>) -> Int {
                    var n = 0
                    for x in xs { for y in 0..<60 where px.at(x, y).r < 128 { n += 1 } }
                    return n
                }
                return (dark(20...50), dark(150...180))
            }
            let normal = headWeight(inverse: false)
            let flipped = headWeight(inverse: true)
            try check(normal.end > normal.start * 2, "normal \(normal)")
            try check(flipped.start > flipped.end * 2, "inverse \(flipped)")
        },
        TestCase("Counters auto-increment and never reuse a live number") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 100, height: 100), scale: 1)
            try checkEqual(doc.nextCounterNumber, 1)
            doc.annotations.append(.counter(at: CGPoint(x: 20, y: 20), number: doc.nextCounterNumber))
            doc.annotations.append(.counter(at: CGPoint(x: 60, y: 20), number: doc.nextCounterNumber))
            try checkEqual(doc.annotations.map(\.number), [1, 2])
            doc.annotations.removeFirst()
            try checkEqual(doc.nextCounterNumber, 3)
            // Counter paints a filled badge.
            try check(Pixels(doc.render()).at(60, 12).g < 60 || Pixels(doc.render()).at(60, 20).g < 250)
        },
        TestCase("Auto-expand grows the canvas only when enabled") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 200, height: 100), scale: 2)
            doc.annotations = [.rectangle(CGRect(x: 60, y: 20, width: 80, height: 40), color: red, lineWidth: 4)]
            try checkEqual(doc.render().width, 200)
            doc.annotations = [.rectangle(CGRect(x: 60, y: 20, width: 80, height: 40), color: red, lineWidth: 4)]
            doc.annotations[0].end = CGPoint(x: 150, y: 80) // beyond the 100x50 pt image
            try checkEqual(doc.render().width, 200)
            doc.autoExpandCanvas = true
            let out = doc.render()
            try check(out.width > 200 && out.height > 100, "expanded to \(out.width)x\(out.height)")
            let px = Pixels(out)
            try check(px.at(out.width - 2, out.height - 2).a == 0, "padding stays transparent")
            try check(px.at(10, 10).g > 240 && px.at(10, 10).a == 255, "original area intact")
            // Expanded to the left/top as well.
            var left = AnnotationDocument(baseImage: solidImage(width: 100, height: 100), scale: 1, autoExpandCanvas: true)
            left.annotations = [.rectangle(CGRect(x: -20, y: -10, width: 40, height: 40), color: red, filled: true)]
            let l = Pixels(left.render())
            try checkEqual(l.width, 121) // 20pt overhang + 1pt antialiasing margin
            try checkEqual(l.height, 111)
            try check(l.at(5, 5).r > 240 && l.at(5, 5).g < 20, "object visible in the new margin")
            try check(l.at(100, 100).g > 240, "image shifted right/down")
        },
        TestCase("Object shadow falls below the object") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 100, height: 100), scale: 1, objectShadow: true)
            doc.annotations = [.rectangle(CGRect(x: 30, y: 30, width: 40, height: 40), color: red, lineWidth: 4, filled: true)]
            let withShadow = Pixels(doc.render())
            let below = withShadow.at(50, 73), above = withShadow.at(50, 27)
            try check(below.g < above.g - 15, "below \(below) above \(above)")
            doc.objectShadow = false
            try check(Pixels(doc.render()).at(50, 73).g > 250)
        },
        TestCase("Hit testing and handle resize") {
            let rect = Annotation.rectangle(CGRect(x: 10, y: 10, width: 80, height: 60), lineWidth: 4)
            try check(rect.hitTest(CGPoint(x: 10, y: 40)))
            try check(!rect.hitTest(CGPoint(x: 50, y: 40)), "interior of an outline rect is click-through")
            var resized = rect.resized(.bottomRight, to: CGPoint(x: 120, y: 100))
            try checkEqual(resized.rect, CGRect(x: 10, y: 10, width: 110, height: 90))
            resized = resized.moved(by: CGSize(width: 5, height: -5))
            try checkEqual(resized.rect.origin, CGPoint(x: 15, y: 5))
            let arrow = Annotation.arrow(from: .zero, to: CGPoint(x: 100, y: 0))
            try check(arrow.hitTest(CGPoint(x: 50, y: 3)) && !arrow.hitTest(CGPoint(x: 50, y: 30)))
        },
        TestCase("Text renders glyph pixels with an optional pill") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 200, height: 80), scale: 1)
            doc.annotations = [.text("Hello", at: CGPoint(x: 10, y: 10), fontSize: 28, color: red)]
            let box = doc.annotations[0].textBox
            let plain = Pixels(doc.render())
            var inked = 0
            for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) where plain.at(x, y).g < 128 { inked += 1 } }
            try check(inked > 30, "text pixels \(inked)")
            doc.annotations[0].textBackground = true
            let pill = Pixels(doc.render())
            try check(pill.at(Int(box.minX) + 2, Int(box.midY)).g < 60, "pill fill at the box edge")
        },
        TestCase("Background size = image + padding, adjusted for aspect ratio") {
            let img = solidImage(width: 200, height: 100)
            let style = BackgroundStyle(name: "t", fill: .color(hex: "#112233"), padding: 0.2, cornerRadius: 0, shadow: false)
            let out = BackgroundRenderer.apply(style, to: img)
            try checkEqual(out.width, 240) // 0.2 * shorter side (100) = 20 px each side
            try checkEqual(out.height, 140)
            var wide = style
            wide.aspectRatio = 2
            let w = BackgroundRenderer.apply(wide, to: img)
            try checkEqual(w.width, 280)
            try checkEqual(w.height, 140)
            let backdrop = Pixels(w).at(2, 2)
            try check(backdrop.r == 0x11 && backdrop.g == 0x22 && backdrop.b == 0x33, "backdrop \(backdrop)")
            try check(Pixels(w).at(140, 70).g > 250, "image centred")
        },
        TestCase("Background corner radius: transparent with no fill, filled with a colour") {
            let img = solidImage(width: 100, height: 100, gray: 0.5)
            var style = BackgroundStyle(name: "t", fill: .none, padding: 0, cornerRadius: 20, shadow: false)
            var px = Pixels(BackgroundRenderer.apply(style, to: img))
            try checkEqual(px.width, 100)
            try checkEqual(px.at(0, 0).a, 0)
            try checkEqual(px.at(99, 99).a, 0)
            try checkEqual(px.at(50, 50).a, 255)
            try checkEqual(px.at(50, 0).a, 255)
            try checkEqual(px.at(8, 8).a, 255) // inside a 20 px radius
            // Radius is in points: at scale 2 the same corner pixel is cut away.
            px = Pixels(BackgroundRenderer.apply(style, to: img, scale: 2))
            try checkEqual(px.at(8, 8).a, 0)
            style.fill = .color(hex: "#00FF00")
            px = Pixels(BackgroundRenderer.apply(style, to: img))
            let corner = px.at(0, 0)
            try check(corner.a == 255 && corner.g == 255 && corner.r == 0, "corner \(corner)")
            try check(px.at(50, 50).g < 150 && px.at(50, 50).r > 100, "image gray in the middle")
        },
        TestCase("Background gradient runs along its angle and shadow falls below") {
            let img = solidImage(width: 100, height: 100)
            var style = BackgroundStyle(name: "g", fill: .gradient(fromHex: "#000000", toHex: "#FFFFFF", angle: 0),
                                        padding: 0.3, cornerRadius: 0, shadow: false)
            var px = Pixels(BackgroundRenderer.apply(style, to: img))
            try check(px.at(1, 80).r < 30 && px.at(px.width - 2, 80).r > 225, "left dark, right light")
            style.fill = .gradient(fromHex: "#000000", toHex: "#FFFFFF", angle: 90)
            px = Pixels(BackgroundRenderer.apply(style, to: img))
            try check(px.at(5, 1).r < 30 && px.at(5, px.height - 2).r > 225, "top dark, bottom light")
            style.fill = .color(hex: "#FFFFFF")
            style.shadow = true
            px = Pixels(BackgroundRenderer.apply(style, to: img))
            let imgBottom = 30 + 100, imgTop = 30
            try check(px.at(80, imgBottom + 6).r < px.at(80, imgTop - 6).r - 10, "shadow offset downwards")
        },
        TestCase("Built-in presets exist and user presets round-trip through Prefs") {
            try check(BackgroundStyle.builtIns.count >= 6)
            try checkEqual(Set(BackgroundStyle.builtIns.map(\.id)).count, BackgroundStyle.builtIns.count)
            try check(BackgroundStyle.loadPresets().isEmpty)
            let mine = BackgroundStyle(id: "mine", name: "Mine", fill: .gradient(fromHex: "#111111", toHex: "#222222", angle: 45),
                                       padding: 0.12, cornerRadius: 8, shadow: false, aspectRatio: 1.5)
            BackgroundStyle.savePresets([mine])
            try checkEqual(BackgroundStyle.loadPresets(), [mine])
            try checkEqual(BackgroundStyle.preset(withID: "mine"), mine)
            try check(BackgroundStyle.preset(withID: "builtin.ocean") != nil)
            try check(BackgroundStyle.preset(withID: "") == nil)
        },
        TestCase("Document render applies the background after annotations") {
            var doc = AnnotationDocument(baseImage: solidImage(width: 100, height: 100), scale: 1)
            doc.annotations = [.rectangle(CGRect(x: 10, y: 10, width: 30, height: 30), color: red, filled: true)]
            doc.background = BackgroundStyle(name: "t", fill: .color(hex: "#0000FF"), padding: 0.1, cornerRadius: 0, shadow: false)
            let out = doc.render()
            try checkEqual(out.width, 120)
            let px = Pixels(out)
            try check(px.at(35, 35).r > 240 && px.at(35, 35).g < 20, "annotation inside the framed image")
            try check(px.at(3, 3).b == 255 && px.at(3, 3).r == 0, "backdrop")
        },
    ]
}
