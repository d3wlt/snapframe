import AppKit
import SwiftUI

struct EditorActions {
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var saveAs: () -> Void = {}
    var done: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomFit: () -> Void = {}
    var zoomActual: () -> Void = {}
    var applyCrop: () -> Void = {}
    var cancelCrop: () -> Void = {}
    var chooseBackgroundImage: () -> Void = {}
    var saveBackgroundPreset: () -> Void = {}
}

private struct ChromeButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.2)
                          : configuration.isPressed ? Color.primary.opacity(0.14) : Color.clear)
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
    }
}

private struct HoverBackground: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .onHover { hover = $0 }
    }
}

struct EditorToolbar: View {
    @ObservedObject var state: EditorState
    let actions: EditorActions
    let showColorNames: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    if tool == .crop { Divider().frame(height: 18).padding(.horizontal, 4) }
                    Button { state.tool = tool } label: {
                        Image(systemName: tool.symbol).font(.system(size: 14, weight: .regular))
                    }
                    .buttonStyle(ChromeButtonStyle(selected: state.tool == tool))
                    .modifier(HoverBackground())
                    .help("\(tool.title) (\(tool.key.map { String($0).uppercased() } ?? ""))")
                }
                Spacer(minLength: 8)
                iconButton("arrow.uturn.backward", "Undo (\u{2318}Z)", enabled: state.canUndo, actions.undo)
                iconButton("arrow.uturn.forward", "Redo (\u{21E7}\u{2318}Z)", enabled: state.canRedo, actions.redo)
                Menu {
                    Button("Zoom In") { actions.zoomIn() }
                    Button("Zoom Out") { actions.zoomOut() }
                    Button("Fit to Window") { actions.zoomFit() }
                    Button("Actual Size") { actions.zoomActual() }
                } label: {
                    Text("\(state.zoomPercent)%").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 44)
                .help("Zoom (\u{2318}+  \u{2318}\u{2212}  \u{2318}0)")
                Divider().frame(height: 18).padding(.horizontal, 4)
                iconButton("doc.on.doc", "Copy image (\u{2318}C)", enabled: true, actions.copy)
                iconButton("square.and.arrow.down", "Save (\u{2318}S)", enabled: true, actions.save)
                Button("Done") { actions.done() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.leading, 6)
                    .help("Save and close")
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            Divider()
            OptionsRow(state: state, actions: actions, showColorNames: showColorNames)
                .frame(height: showColorNames ? 48 : 38)
            Divider()
        }
        .background(.bar)
    }

    private func iconButton(_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)) }
            .buttonStyle(ChromeButtonStyle())
            .modifier(HoverBackground())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .help(help)
    }
}

private struct OptionsRow: View {
    @ObservedObject var state: EditorState
    let actions: EditorActions
    let showColorNames: Bool

    /// The tool whose options apply: the selected object's, or the active tool's.
    private var context: EditorTool {
        if let a = state.selected {
            switch a.kind {
            case .arrow: return .arrow
            case .line: return .line
            case .rectangle: return .rectangle
            case .ellipse: return .ellipse
            case .text: return .text
            case .pencil: return .pencil
            case .highlighter: return .highlighter
            case .counter: return .counter
            case .pixelate, .blur: return .redact
            case .spotlight: return .spotlight
            }
        }
        return state.tool
    }

    var body: some View {
        HStack(spacing: 14) {
            switch context {
            case .select:
                hint("Click an object to edit it. Double-click text to change it. Press \u{232B} to delete.")
            case .spotlight:
                hint("Drag to keep an area bright and dim the rest.")
            case .background:
                hint("Pick a backdrop in the sidebar. Padding, corners and shadow apply when you save.")
            case .crop:
                hint("Drag to choose the area to keep. Return applies, Esc cancels.")
                Button("Cancel") { actions.cancelCrop() }
                Button("Apply") { actions.applyCrop() }.buttonStyle(.borderedProminent)
            case .redact:
                Picker("", selection: Binding(get: { state.pixelate }, set: { state.setPixelate($0) })) {
                    Text("Pixelate").tag(true)
                    Text("Blur").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                HStack(spacing: 6) {
                    Text("Strength").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(state.strength) }, set: { state.setStrength(CGFloat($0)) }), in: 4...40)
                        .frame(width: 140)
                }
            default:
                palette
                if context == .text {
                    HStack(spacing: 6) {
                        Text("Size").font(.caption).foregroundStyle(.secondary)
                        Stepper(value: Binding(get: { Double(state.fontSize) }, set: { state.setFontSize(CGFloat($0)) }),
                                in: 8...120, step: 2) {
                            Text("\(Int(state.fontSize))").font(.system(size: 12).monospacedDigit()).frame(width: 26, alignment: .trailing)
                        }
                    }
                    Toggle("Background", isOn: Binding(get: { state.textBackground }, set: { state.setTextBackground($0) }))
                        .toggleStyle(.checkbox)
                } else {
                    widthPicker
                }
                if context == .rectangle || context == .ellipse {
                    Toggle("Fill", isOn: Binding(get: { state.filled }, set: { state.setFilled($0) })).toggleStyle(.checkbox)
                }
                if context == .rectangle {
                    Toggle("Rounded", isOn: Binding(get: { state.rounded }, set: { state.setRounded($0) })).toggleStyle(.checkbox)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .font(.system(size: 12))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
    }

    private var inPalette: Bool { PaletteColor.all.contains { $0.color.isEqual(state.color) } }

    private var palette: some View {
        HStack(spacing: 7) {
            ForEach(PaletteColor.all) { p in
                let selected = p.color.isEqual(state.color)
                Button { state.setColor(p.color) } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(Color(nsColor: p.color))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.28), lineWidth: 0.75))
                            .frame(width: 18, height: 18)
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                        if showColorNames {
                            Text(p.name).font(.system(size: 9)).foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(p.name)
            }
            Button {
                ColorPanelBridge.shared.show(initial: state.color) { state.setColor($0) }
            } label: {
                ZStack {
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    if !inPalette {
                        Circle().fill(Color(nsColor: state.color)).padding(4)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1).padding(4))
                    }
                }
                .frame(width: 18, height: 18)
                .padding(2.5)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: inPalette ? 0 : 2))
            }
            .buttonStyle(.plain)
            .help("Custom colour")
        }
    }

    private var widthPicker: some View {
        HStack(spacing: 2) {
            ForEach(0..<EditorState.widths.count, id: \.self) { i in
                Button { state.setWidthIndex(i) } label: {
                    Capsule().fill(Color.primary).frame(width: 18, height: EditorState.widths[i] * 0.8 + 1)
                        .frame(width: 28, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(state.widthIndex == i ? Color.accentColor.opacity(0.22) : Color.clear))
                }
                .buttonStyle(.plain)
                .help(["Thin", "Medium", "Thick"][i])
            }
        }
    }
}

// MARK: Background sidebar

private extension BackgroundStyle {
    /// Same appearance regardless of id/name.
    func looksLike(_ o: BackgroundStyle) -> Bool {
        fill == o.fill && padding == o.padding && cornerRadius == o.cornerRadius && shadow == o.shadow && aspectRatio == o.aspectRatio
    }
}

private func swatchFill(_ fill: BackgroundStyle.Fill) -> AnyShapeStyle {
    switch fill {
    case .none: return AnyShapeStyle(Color.primary.opacity(0.08))
    case .color(let hex): return AnyShapeStyle(Color(nsColor: NSColor(hex: hex) ?? .gray))
    case .gradient(let a, let b, let angle):
        let r = angle * .pi / 180
        let d = CGPoint(x: cos(r), y: sin(r))
        return AnyShapeStyle(LinearGradient(colors: [Color(nsColor: NSColor(hex: a) ?? .gray), Color(nsColor: NSColor(hex: b) ?? .gray)],
                                            startPoint: UnitPoint(x: 0.5 - d.x / 2, y: 0.5 - d.y / 2),
                                            endPoint: UnitPoint(x: 0.5 + d.x / 2, y: 0.5 + d.y / 2)))
    case .image: return AnyShapeStyle(Color.gray.opacity(0.4))
    }
}

struct BackgroundSidebar: View {
    @ObservedObject var state: EditorState
    let actions: EditorActions
    @State private var userPresets = BackgroundStyle.loadPresets()

    private enum FillKind: String, CaseIterable { case gradient = "Gradient", color = "Color", image = "Image", none = "None" }

    private var style: BackgroundStyle { state.background ?? BackgroundStyle.builtIns[1] }

    private var fillKind: FillKind {
        switch style.fill {
        case .gradient: return .gradient
        case .color: return .color
        case .image: return .image
        case .none: return .none
        }
    }

    private let aspects: [(String, Double?)] = [("Auto", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("2:1", 2), ("3:4", 0.75), ("9:16", 9.0 / 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Background").font(.headline)
                    Spacer()
                    Button("Remove") { state.removeBackground() }.disabled(state.background == nil)
                }
                presetGrid
                Divider()
                Picker("", selection: Binding(get: { fillKind }, set: setKind)) {
                    ForEach(FillKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                fillControls
                Divider()
                slider("Padding", value: Binding(get: { style.padding * 100 }, set: { v in state.updateBackground { $0.padding = v / 100 } }),
                       range: 0...30, unit: "%")
                slider("Corner radius", value: Binding(get: { style.cornerRadius }, set: { v in state.updateBackground { $0.cornerRadius = v } }),
                       range: 0...48, unit: " pt")
                Toggle("Shadow", isOn: Binding(get: { style.shadow }, set: { v in state.updateBackground(tag: "bgshadow") { $0.shadow = v } }))
                HStack {
                    Text("Aspect ratio")
                    Spacer()
                    Picker("", selection: Binding(get: { style.aspectRatio ?? 0 }, set: { v in
                        state.updateBackground(tag: "bgaspect") { $0.aspectRatio = v == 0 ? nil : v }
                    })) {
                        ForEach(aspects, id: \.0) { Text($0.0).tag($0.1 ?? 0) }
                    }
                    .labelsHidden().frame(width: 90)
                }
                Button { actions.saveBackgroundPreset() } label: {
                    Label("Save as Preset\u{2026}", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                }
                .disabled(state.background == nil)
            }
            .font(.system(size: 12))
            .padding(14)
        }
        .frame(width: 280)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: .snapframeBackgroundPresetsChanged)) { _ in
            userPresets = BackgroundStyle.loadPresets()
        }
    }

    private var presetGrid: some View {
        let cols = [GridItem(.adaptive(minimum: 74), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(BackgroundStyle.builtIns + userPresets) { preset in
                let selected = state.background?.looksLike(preset) ?? false
                Button { state.applyPreset(preset) } label: {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(swatchFill(preset.fill))
                            .frame(height: 46)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.white.opacity(0.9))
                                    .frame(width: 30, height: 20)
                                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0))
                        Text(preset.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !preset.isBuiltIn {
                        Button("Delete Preset", role: .destructive) {
                            var all = BackgroundStyle.loadPresets()
                            all.removeAll { $0.id == preset.id }
                            BackgroundStyle.savePresets(all)
                            userPresets = all
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var fillControls: some View {
        switch style.fill {
        case .gradient(let from, let to, let angle):
            HStack(spacing: 10) {
                hexPicker("From", from) { h in state.updateBackground(tag: "bgfrom") { $0.fill = .gradient(fromHex: h, toHex: to, angle: angle) } }
                hexPicker("To", to) { h in state.updateBackground(tag: "bgto") { $0.fill = .gradient(fromHex: from, toHex: h, angle: angle) } }
                Spacer()
                Button { state.updateBackground { $0.fill = .gradient(fromHex: to, toHex: from, angle: angle) } } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Swap colours")
            }
            slider("Angle", value: Binding(get: { angle }, set: { v in
                state.updateBackground(tag: "bgangle") { $0.fill = .gradient(fromHex: from, toHex: to, angle: v.rounded()) }
            }), range: 0...360, unit: "\u{00B0}")
        case .color(let hex):
            hexPicker("Colour", hex) { h in state.updateBackground(tag: "bgcolor") { $0.fill = .color(hex: h) } }
        case .image(let path):
            HStack {
                Button("Choose Image\u{2026}") { actions.chooseBackgroundImage() }
                Text(path.isEmpty ? "No image" : (path as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .none:
            Text("Transparent backdrop. The screenshot keeps its rounded corners and shadow.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hexPicker(_ label: String, _ hex: String, _ set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: hex) ?? .gray) },
                set: { set((NSColor($0).usingColorSpace(.sRGB) ?? NSColor($0)).hexString) }), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(unit)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func setKind(_ kind: FillKind) {
        guard kind != fillKind else { return }
        state.updateBackground { s in
            var from = "#2193B0", to = "#6DD5ED"
            switch s.fill {
            case .gradient(let a, let b, _): from = a; to = b
            case .color(let h): from = h
            default: break
            }
            switch kind {
            case .gradient: s.fill = .gradient(fromHex: from, toHex: to, angle: 135)
            case .color: s.fill = .color(hex: from)
            case .image: s.fill = .image(path: "")
            case .none: s.fill = .none
            }
        }
        if kind == .image { actions.chooseBackgroundImage() }
    }
}

extension Notification.Name {
    static let snapframeBackgroundPresetsChanged = Notification.Name("snapframe.backgroundPresetsChanged")
}

/// Opens the shared colour panel and forwards live changes.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var handler: ((NSColor) -> Void)?

    func show(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        handler = onChange
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        handler?(sender.color.usingColorSpace(.sRGB) ?? sender.color)
    }
}
