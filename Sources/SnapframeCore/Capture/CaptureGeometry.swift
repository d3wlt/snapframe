import AppKit

/// A display with its frame in AppKit global coordinates (bottom-left origin, all screens in one space).
public struct DisplayInfo: Equatable {
    public var id: CGDirectDisplayID
    public var frame: CGRect
    public init(id: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }

    @MainActor
    public static var current: [DisplayInfo] {
        NSScreen.screens.compactMap { s in s.displayID.map { DisplayInfo(id: $0, frame: s.frame) } }
    }
}

/// Pure geometry used by the capture overlays and the capture pipeline.
public enum CaptureGeometry {
    /// Converts a rect in AppKit global coordinates to a display-local rect (points, top-left origin).
    public static func localRect(fromGlobal rect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - displayFrame.minX, y: displayFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Inverse of `localRect(fromGlobal:displayFrame:)`.
    public static func globalRect(fromLocal rect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX + displayFrame.minX, y: displayFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Converts a rect in Quartz/CG global coordinates (top-left origin of the primary display,
    /// as used by CGWindowList and SCWindow.frame) to AppKit global coordinates.
    public static func appKitRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display containing the point (half-open frames), else the nearest one. A pointer on the very
    /// top/right edge (y == maxY, which NSEvent.mouseLocation can report) is therefore still on its display.
    public static func display(containing p: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let hit = displays.first(where: {
            p.x >= $0.frame.minX && p.x < $0.frame.maxX && p.y >= $0.frame.minY && p.y < $0.frame.maxY
        }) { return hit }
        func distance(_ f: CGRect) -> CGFloat {
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            return dx * dx + dy * dy
        }
        return displays.min { distance($0.frame) < distance($1.frame) }
    }

    /// Final selection -> ScreenArea (display of `anchor`, rect clamped to it, top-left origin).
    public static func area(forGlobalRect rect: CGRect, anchor: CGPoint, displays: [DisplayInfo]) -> ScreenArea? {
        guard let d = display(containing: anchor, in: displays) else { return nil }
        let clamped = rect.intersection(d.frame)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return ScreenArea(displayID: d.id, rect: localRect(fromGlobal: clamped, displayFrame: d.frame))
    }

    /// Rect spanned by a drag from `anchor` to `current`, kept inside `bounds`. `square` locks 1:1.
    public static func dragRect(anchor: CGPoint, current: CGPoint, square: Bool, bounds: CGRect) -> CGRect {
        let a = CGPoint(x: min(max(anchor.x, bounds.minX), bounds.maxX), y: min(max(anchor.y, bounds.minY), bounds.maxY))
        var c = CGPoint(x: min(max(current.x, bounds.minX), bounds.maxX), y: min(max(current.y, bounds.minY), bounds.maxY))
        if square {
            let dx = c.x - a.x, dy = c.y - a.y
            let sx: CGFloat = dx < 0 ? -1 : 1, sy: CGFloat = dy < 0 ? -1 : 1
            let limitX = sx > 0 ? bounds.maxX - a.x : a.x - bounds.minX
            let limitY = sy > 0 ? bounds.maxY - a.y : a.y - bounds.minY
            let side = min(max(abs(dx), abs(dy)), limitX, limitY)
            c = CGPoint(x: a.x + sx * side, y: a.y + sy * side)
        }
        return CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
    }

    /// Moves `rect` by `delta`, keeping its size and staying inside `bounds`.
    public static func moved(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        var r = rect.offsetBy(dx: delta.x, dy: delta.y)
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        return r
    }

    /// Pixel rect inside a display image for a point rect (top-left origin on both sides).
    public static func pixelCropRect(pointRect: CGRect, displaySize: CGSize, imageSize: CGSize) -> CGRect {
        let kx = imageSize.width / max(displaySize.width, 1), ky = imageSize.height / max(displaySize.height, 1)
        let r = CGRect(x: pointRect.minX * kx, y: pointRect.minY * ky, width: pointRect.width * kx, height: pointRect.height * ky)
            .integral
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// The topmost candidate (list is front-to-back) containing the point.
    public static func topmost<T>(at p: CGPoint, in items: [T], rect: (T) -> CGRect) -> T? {
        items.first { rect($0).contains(p) }
    }
}

/// Drag bookkeeping for the area selector (global AppKit points). Pure so it can be tested.
public struct SelectionTracker {
    public private(set) var bounds: CGRect
    public private(set) var anchor: CGPoint
    public private(set) var current: CGPoint
    public private(set) var rect: CGRect
    public private(set) var maxDistance: CGFloat = 0
    private var origin: CGPoint
    private var pointer: CGPoint

    public init(start: CGPoint, bounds: CGRect) {
        self.bounds = bounds
        anchor = start
        current = start
        origin = start
        pointer = start
        rect = CGRect(origin: start, size: .zero)
    }

    public var isClick: Bool { maxDistance < 3 }

    /// `space` moves the whole selection with the mouse; `square` locks the aspect.
    public mutating func drag(to p: CGPoint, space: Bool, square: Bool) {
        maxDistance = max(maxDistance, hypot(p.x - origin.x, p.y - origin.y))
        defer { pointer = p }
        if space {
            let moved = CaptureGeometry.moved(rect, by: CGPoint(x: p.x - pointer.x, y: p.y - pointer.y), within: bounds)
            let applied = CGPoint(x: moved.minX - rect.minX, y: moved.minY - rect.minY)
            anchor = CGPoint(x: anchor.x + applied.x, y: anchor.y + applied.y)
            current = CGPoint(x: current.x + applied.x, y: current.y + applied.y)
            rect = moved
        } else {
            current = p
            rect = CaptureGeometry.dragRect(anchor: anchor, current: p, square: square, bounds: bounds)
        }
    }
}

/// "displayID x y w h" persistence for PrefKey.lastArea.
public enum AreaStorage {
    public static func encode(_ a: ScreenArea) -> String {
        func n(_ v: CGFloat) -> String { String(format: "%g", Double(v)) }
        return "\(a.displayID) \(n(a.rect.minX)) \(n(a.rect.minY)) \(n(a.rect.width)) \(n(a.rect.height))"
    }

    public static func decode(_ s: String) -> ScreenArea? {
        let p = s.split(separator: " ")
        guard p.count == 5, let id = UInt32(p[0]), let x = Double(p[1]), let y = Double(p[2]),
              let w = Double(p[3]), let h = Double(p[4]), w > 0, h > 0 else { return nil }
        return ScreenArea(displayID: id, rect: CGRect(x: x, y: y, width: w, height: h))
    }
}
