import AppKit
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, text, pencil, highlighter, counter, redact, spotlight, crop, background

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .text: return "textformat"
        case .pencil: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .counter: return "number.circle"
        case .redact: return "checkerboard.rectangle"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        case .background: return "photo.artframe"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .text: return "Text"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        case .counter: return "Counter"
        case .redact: return "Pixelate / Blur"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        case .background: return "Background"
        }
    }

    /// Single-key shortcut.
    var key: Character? {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .text: return "t"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .counter: return "n"
        case .redact: return "b"
        case .spotlight: return "s"
        case .crop: return "c"
        case .background: return "g"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .text: return .text
        case .pencil: return .pencil
        case .highlighter: return .highlighter
        case .counter: return .counter
        case .spotlight: return .spotlight
        default: return nil // redact picks pixelate/blur at draw time
        }
    }
}

struct PaletteColor: Identifiable {
    let name: String
    let color: NSColor
    var id: String { name }

    static let all: [PaletteColor] = [
        .init(name: "Red", color: NSColor(srgbRed: 1.0, green: 0.231, blue: 0.188, alpha: 1)),
        .init(name: "Orange", color: NSColor(srgbRed: 1.0, green: 0.584, blue: 0.0, alpha: 1)),
        .init(name: "Yellow", color: NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1)),
        .init(name: "Green", color: NSColor(srgbRed: 0.204, green: 0.78, blue: 0.349, alpha: 1)),
        .init(name: "Blue", color: NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)),
        .init(name: "Purple", color: NSColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1)),
        .init(name: "Black", color: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.075, alpha: 1)),
        .init(name: "White", color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
    ]
}

/// Mutable editor state shared by the canvas (AppKit) and the toolbar/sidebar (SwiftUI).
@MainActor
final class EditorState: ObservableObject {
    struct Snapshot: Equatable {
        var annotations: [Annotation]
        var cropRect: CGRect?
        var background: BackgroundStyle?
    }

    static let widths: [CGFloat] = [3, 5, 8]

    var doc: AnnotationDocument

    @Published var tool: EditorTool = .arrow
    @Published var color: NSColor = PaletteColor.all[0].color
    @Published var widthIndex = 1
    @Published var filled = false
    @Published var rounded = false
    @Published var fontSize: CGFloat = 24
    @Published var textBackground = false
    @Published var pixelate = true
    @Published var strength: CGFloat = 12
    @Published var selection: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isDirty = false
    /// Mirrors doc.background for the sidebar.
    @Published var background: BackgroundStyle?
    @Published var zoomPercent = 100

    /// Pending (uncommitted) crop while the crop tool is active.
    var cropDraft: CGRect?

    /// Fires after every change that needs the canvas to repaint / relayout.
    var onChange: (() -> Void)?

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastUndoTag: String?
    private var savedSnapshot: Snapshot

    init(doc: AnnotationDocument) {
        self.doc = doc
        background = doc.background
        savedSnapshot = Snapshot(annotations: doc.annotations, cropRect: doc.cropRect, background: doc.background)
    }

    var lineWidth: CGFloat { Self.widths[widthIndex] }

    var snapshot: Snapshot { Snapshot(annotations: doc.annotations, cropRect: doc.cropRect, background: doc.background) }

    var selected: Annotation? {
        get { selection.flatMap { id in doc.annotations.first { $0.id == id } } }
    }

    func index(of id: UUID) -> Int? { doc.annotations.firstIndex { $0.id == id } }

    // MARK: Undo

    /// Records `before` as an undo step. Steps with the same non-nil tag in a row collapse (slider drags).
    func registerUndo(_ before: Snapshot, tag: String? = nil) {
        if let tag, tag == lastUndoTag { changed(); return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastUndoTag = tag
        changed()
    }

    /// Runs a mutation as one undoable step.
    func perform(tag: String? = nil, _ change: (inout AnnotationDocument) -> Void) {
        let before = snapshot
        change(&doc)
        registerUndo(before, tag: tag)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        doc.annotations = s.annotations
        doc.cropRect = s.cropRect
        doc.background = s.background
        cropDraft = nil
        lastUndoTag = nil
        if let sel = selection, index(of: sel) == nil { selection = nil }
        changed()
    }

    func breakCoalescing() { lastUndoTag = nil }

    /// Call after any document mutation (also during live drags, where no undo step is registered).
    func changed() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        isDirty = snapshot != savedSnapshot
        background = doc.background
        onChange?()
    }

    /// Repaint only (selection/tool/crop-draft changes that don't dirty the document).
    func refresh() { onChange?() }

    func markSaved() {
        savedSnapshot = snapshot
        isDirty = false
    }

    // MARK: Property changes (apply to the selection as well)

    func setColor(_ c: NSColor) {
        color = c
        edit(tag: "color") { $0.color = c }
    }

    func setWidthIndex(_ i: Int) {
        widthIndex = i
        edit { $0.lineWidth = Self.widths[i] }
    }

    func setFilled(_ v: Bool) { filled = v; edit { $0.filled = v } }
    func setRounded(_ v: Bool) { rounded = v; edit { $0.rounded = v } }
    func setTextBackground(_ v: Bool) { textBackground = v; edit { $0.textBackground = v } }
    func setFontSize(_ v: CGFloat) { fontSize = v; edit(tag: "font") { $0.fontSize = v } }
    func setStrength(_ v: CGFloat) { strength = v; edit(tag: "strength") { if $0.kind.isEffect { $0.strength = v } } }

    func setPixelate(_ v: Bool) {
        pixelate = v
        edit { if $0.kind == .pixelate || $0.kind == .blur { $0.kind = v ? .pixelate : .blur } }
    }

    private func edit(tag: String? = nil, _ change: (inout Annotation) -> Void) {
        guard let id = selection, let i = index(of: id) else { return }
        let before = snapshot
        change(&doc.annotations[i])
        if doc.annotations[i] == before.annotations[i] { return }
        registerUndo(before, tag: tag)
    }

    /// Loads the selected object's properties into the toolbar so editing it feels continuous.
    func adoptSelectionProperties() {
        guard let a = selected else { return }
        switch a.kind {
        case .pixelate, .blur: pixelate = a.kind == .pixelate; strength = a.strength
        case .spotlight: break
        default:
            color = a.color
            if let i = Self.widths.firstIndex(of: a.lineWidth) { widthIndex = i }
            filled = a.filled; rounded = a.rounded
            if a.kind == .text { fontSize = a.fontSize; textBackground = a.textBackground }
        }
    }

    // MARK: Background

    func updateBackground(tag: String = "background", _ change: (inout BackgroundStyle) -> Void) {
        let before = snapshot
        var style = doc.background ?? BackgroundStyle.builtIns[1]
        change(&style)
        guard style != doc.background else { return }
        doc.background = style
        registerUndo(before, tag: tag)
    }

    func applyPreset(_ preset: BackgroundStyle) {
        let before = snapshot
        doc.background = preset
        registerUndo(before)
    }

    func removeBackground() {
        guard doc.background != nil else { return }
        let before = snapshot
        doc.background = nil
        registerUndo(before)
    }

    /// True when the selected tool's options (or selected object) can be filled.
    var supportsFill: Bool {
        if let a = selected { return a.kind == .rectangle || a.kind == .ellipse }
        return tool == .rectangle || tool == .ellipse
    }
}
