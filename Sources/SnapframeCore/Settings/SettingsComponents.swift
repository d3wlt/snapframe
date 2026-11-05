import AppKit
import SwiftUI

// Shared building blocks for the settings tabs: macOS-style form rows (right-aligned label column,
// control column, small secondary help text), tick sliders and colour/hex helpers.

enum SettingsLayout {
    static let width: CGFloat = 640
    static let labelWidth: CGFloat = 184
}

/// Vertical stack of rows for one tab.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(width: SettingsLayout.width, alignment: .leading)
    }
}

/// "Label:" on the left (right-aligned), controls on the right, optional help text beneath.
struct SettingsRow<Content: View>: View {
    var label: String
    var help: String?
    /// Aligns the label with the top of the content (for tall controls such as image tiles).
    var alignTop: Bool
    @ViewBuilder var content: Content

    init(_ label: String = "", help: String? = nil, alignTop: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.alignTop = alignTop
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignTop ? .top : .firstTextBaseline, spacing: 12) {
            Text(label.isEmpty ? "" : label + ":")
                .frame(width: SettingsLayout.labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                content
                if let help { HelpText(help) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct HelpText: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.vertical, 4) }
}

/// NSSlider with discrete tick marks (SwiftUI's Slider draws none on macOS) and optional captions.
struct TickSlider: View {
    @Binding var value: Int
    var maxValue: Int
    /// Captions by tick index, e.g. [0: "Min", 2: "Default", 6: "Max"].
    var captions: [Int: String] = [:]
    var width: CGFloat = 230

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            NSTickSlider(value: $value, maxValue: maxValue).frame(width: width)
            if !captions.isEmpty {
                ZStack(alignment: .topLeading) {
                    ForEach(captions.keys.sorted(), id: \.self) { index in
                        Text(captions[index] ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                // Slider knobs are inset by ~8pt; edge captions align with the edges.
                                let x = 8 + (width - 16) * CGFloat(index) / CGFloat(maxValue)
                                if index == 0 { return 0 }
                                if index == maxValue { return d.width - width }
                                return d.width / 2 - x
                            }
                    }
                }
                .frame(width: width, height: 12, alignment: .topLeading)
            }
        }
    }
}

private struct NSTickSlider: NSViewRepresentable {
    @Binding var value: Int
    var maxValue: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: Double(maxValue),
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = maxValue + 1
        slider.allowsTickMarkValuesOnly = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if Int(slider.doubleValue.rounded()) != value { slider.doubleValue = Double(value) }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NSTickSlider
        init(_ parent: NSTickSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = Int(sender.doubleValue.rounded()) }
    }
}

/// Hex <-> Color helpers for colour pickers backed by "#RRGGBB" strings.
enum HexColor {
    static func color(_ hex: String, fallback: NSColor = .gray) -> Color {
        Color(nsColor: NSColor(hex: hex) ?? fallback)
    }
    static func hex(_ color: Color) -> String { NSColor(color).hexString }
    static func binding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { color(hex.wrappedValue) }, set: { hex.wrappedValue = Self.hex($0) })
    }
}

extension View {
    /// Menu-style popup sized to its content.
    func popup() -> some View { self.labelsHidden().pickerStyle(.menu).fixedSize() }
}

enum SystemSettingsPane {
    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    static let screenRecording = "Privacy_ScreenCapture"
    static let accessibility = "Privacy_Accessibility"
    static let microphone = "Privacy_Microphone"
}
