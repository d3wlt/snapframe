#!/usr/bin/env swift
// Renders the Snapframe app icon (Big Sur-style rounded square, gradient, viewfinder glyph) at every
// iconset size and packs Resources/AppIcon.icns with iconutil.
// Usage: swift scripts/make-icon.swift [output.icns]   (run from the repo root)

import AppKit

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024  // draw in a 1024-unit space
    ctx.scaleBy(x: s, y: s)

    // Icon body: 824pt square centred in the 1024 canvas (Apple's macOS template).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    // Gradient fill.
    ctx.saveGState()
    path.addClip()
    let colors = [NSColor(srgbRed: 0.36, green: 0.30, blue: 0.95, alpha: 1).cgColor,   // indigo
                  NSColor(srgbRed: 0.10, green: 0.66, blue: 0.93, alpha: 1).cgColor]   // sky
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])
    // Soft top highlight.
    let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Viewfinder: four corner brackets + a centre dot with a ring.
    let white = NSColor.white
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.setStrokeColor(white.cgColor)
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let inset: CGFloat = 225, arm: CGFloat = 150, r: CGFloat = 40
    let lo = 100 + inset, hi = 924 - inset
    func corner(_ cx: CGFloat, _ cy: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        // dx/dy point toward the interior from the corner.
        ctx.move(to: CGPoint(x: cx + dx * arm, y: cy))
        ctx.addLine(to: CGPoint(x: cx + dx * r, y: cy))
        ctx.addQuadCurve(to: CGPoint(x: cx, y: cy + dy * r), control: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy + dy * arm))
        ctx.strokePath()
    }
    corner(lo, hi, 1, -1)
    corner(hi, hi, -1, -1)
    corner(lo, lo, 1, 1)
    corner(hi, lo, -1, 1)
    ctx.setLineWidth(30)
    ctx.strokeEllipse(in: CGRect(x: 512 - 92, y: 512 - 92, width: 184, height: 184))
    ctx.setFillColor(white.cgColor)
    ctx.fillEllipse(in: CGRect(x: 512 - 48, y: 512 - 48, width: 96, height: 96))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Snapframe-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let png = drawIcon(pixels: px).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}
try fm.createDirectory(atPath: (out as NSString).deletingLastPathComponent.isEmpty ? "." : (out as NSString).deletingLastPathComponent,
                       withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
// Also drop a 1024 preview next to the iconset for visual checks when requested.
if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW"] {
    try drawIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: preview))
}
try? fm.removeItem(at: iconset)
print("wrote \(out)")
