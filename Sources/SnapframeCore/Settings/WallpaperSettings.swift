import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WallpaperTab: View {
    @AppStorage(PrefKey.wallpaperMode, store: Prefs.store) private var mode = WallpaperMode.desktop
    @AppStorage(PrefKey.wallpaperKeepAcrossSpaces, store: Prefs.store) private var keepAcrossSpaces = false
    @AppStorage(PrefKey.wallpaperCustomPath, store: Prefs.store) private var customPath = ""
    @AppStorage(PrefKey.wallpaperPlainColor, store: Prefs.store) private var plainColor = "#55626E"
    @AppStorage(PrefKey.windowBackground, store: Prefs.store) private var background = WindowBackground.wallpaper
    @AppStorage(PrefKey.windowPadding, store: Prefs.store) private var padding = 2
    @AppStorage(PrefKey.windowShadow, store: Prefs.store) private var shadow = true

    var body: some View {
        SettingsPage {
            SettingsRow("Wallpaper") {
                VStack(alignment: .leading, spacing: 10) {
                    radio(.desktop, "Desktop wallpaper") {
                        EmptyView()
                    }
                    Toggle("Don’t change the wallpaper when switching spaces", isOn: $keepAcrossSpaces)
                        .padding(.leading, 22)
                        .disabled(mode != .desktop)
                    radio(.custom, "Custom wallpaper") {
                        HStack(spacing: 8) {
                            Button("Choose Image…") { chooseImage() }
                            if !customPath.isEmpty {
                                Text((customPath as NSString).lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                            }
                        }
                    }
                    radio(.plainColor, "Plain color") {
                        ColorPicker("Plain color", selection: HexColor.binding($plainColor), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
            SettingsDivider()
            SettingsRow("Window screenshots", alignTop: true) {
                HStack(spacing: 14) {
                    tile(.wallpaper, "With wallpaper")
                    tile(.transparent, "Transparent")
                }
                HelpText("Hold ⇧ Shift while taking a screenshot to get a transparent background.")
            }
            SettingsRow("Padding") {
                TickSlider(value: $padding, maxValue: 6, captions: [0: "Min", 2: "Default", 6: "Max"])
            }
            SettingsRow("Shadow") {
                Toggle("Add shadow to window screenshots", isOn: $shadow)
                HelpText("Hold ⌥ (option) while taking a screenshot to disable shadow.")
            }
        }
    }

    private func radio<Extra: View>(_ value: WallpaperMode, _ title: String,
                                    @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 8) {
            Button {
                mode = value
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: mode == value ? "circle.inset.filled" : "circle")
                        .foregroundStyle(mode == value ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text(title)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(mode == value ? .isSelected : [])
            extra()
        }
    }

    private func tile(_ value: WindowBackground, _ title: String) -> some View {
        let selected = background == value
        return Button {
            background = value
        } label: {
            VStack(spacing: 6) {
                WindowTilePreview(transparent: value == .transparent)
                    .frame(width: 118, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                      lineWidth: selected ? 3 : 1))
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            mode = .custom
        }
    }
}

private struct WindowTilePreview: View {
    var transparent: Bool

    var body: some View {
        ZStack {
            if transparent {
                Checkerboard()
            } else {
                LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.95), Color(red: 0.62, green: 0.38, blue: 0.86)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 5, height: 5) }
                    Spacer()
                }
                .padding(.horizontal, 6).frame(height: 13)
                .background(Color(nsColor: .windowBackgroundColor))
                Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            }
            .frame(width: 70, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(transparent ? 0 : 0.35), radius: 5, y: 2)
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for row in 0..<Int(size.height / s) + 1 {
                for col in 0..<Int(size.width / s) + 1 {
                    let dark = (row + col) % 2 == 0
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                             with: .color(dark ? Color(white: 0.78) : Color(white: 0.95)))
                }
            }
        }
    }
}
