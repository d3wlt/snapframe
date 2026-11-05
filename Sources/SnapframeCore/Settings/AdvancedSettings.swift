import AppKit
import ServiceManagement
import SwiftUI
import Vision

enum SettingsReset {
    /// Keys wiped by "Reset all settings": everything registered except internal state and saved
    /// Background presets (user content, not a setting).
    static func keysToReset() -> [String] {
        var keys = Array(Prefs.defaults.keys).filter {
            !$0.hasPrefix("state.") && $0 != PrefKey.annBackgroundPresets
        }
        keys += SnapframeAction.allCases.map { PrefKey.shortcut($0) }
        return keys
    }

    @MainActor
    static func perform() {
        for key in keysToReset() { Prefs.store.removeObject(forKey: key) }
        try? SMAppService.mainApp.unregister()
        HotkeyCenter.shared.reload()
    }
}

enum OCRLanguages {
    /// (identifier, localized name) for every language Vision can recognise.
    static func available() -> [(id: String, name: String)] {
        let ids = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        return ids.map { id in
            (id, Locale.current.localizedString(forIdentifier: id) ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct AdvancedTab: View {
    @AppStorage(PrefKey.fileNameTemplate, store: Prefs.store) private var template = ""
    @AppStorage(PrefKey.askNameAfterCapture, store: Prefs.store) private var askName = false
    @AppStorage(PrefKey.add2xSuffix, store: Prefs.store) private var add2x = true
    @AppStorage(PrefKey.clipboardMode, store: Prefs.store) private var clipboard = ClipboardMode.fileAndImage
    @AppStorage(PrefKey.pinRoundedCorners, store: Prefs.store) private var pinRounded = true
    @AppStorage(PrefKey.pinShadow, store: Prefs.store) private var pinShadow = true
    @AppStorage(PrefKey.pinBorder, store: Prefs.store) private var pinBorder = true
    @AppStorage(PrefKey.historyRetention, store: Prefs.store) private var retention = HistoryRetention.week
    @AppStorage(PrefKey.ocrLanguage, store: Prefs.store) private var ocrLanguage = "auto"
    @AppStorage(PrefKey.ocrKeepLineBreaks, store: Prefs.store) private var keepBreaks = false
    @AppStorage(PrefKey.ocrDetectLinks, store: Prefs.store) private var detectLinks = true
    @AppStorage(PrefKey.urlSchemeEnabled, store: Prefs.store) private var urlScheme = false
    @State private var languages = OCRLanguages.available()
    @State private var showActions = false
    @State private var confirmReset = false

    private static let retentionOptions: [(HistoryRetention, String)] = [
        (.never, "Never"), (.day, "1 day"), (.threeDays, "3 days"), (.week, "1 week"), (.month, "1 month"),
    ]

    var body: some View {
        SettingsPage {
            SettingsRow("File name") {
                TextField("File name template", text: $template)
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 300)
                Text(FileNamer.baseName(template: template))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HelpText("%Y year, %y short year, %m month, %d day, %H hour (24h), %I hour (12h), %M minute, %S second, %p AM/PM.")
                Toggle("Ask for name after every capture", isOn: $askName)
                Toggle("Add “@2x” suffix to Retina screenshots", isOn: $add2x)
            }
            SettingsRow("Copy to clipboard",
                        help: "“File & Image” pastes into Finder and chat apps as a file, and into image editors as an image.") {
                Picker("Copy to clipboard", selection: $clipboard) {
                    Text("File & Image (default)").tag(ClipboardMode.fileAndImage)
                    Text("File only").tag(ClipboardMode.file)
                    Text("Image only").tag(ClipboardMode.image)
                }.popup()
            }
            SettingsDivider()
            SettingsRow("Pinned screenshots") {
                Toggle("Rounded corners", isOn: $pinRounded)
                Toggle("Shadow", isOn: $pinShadow)
                Toggle("Border", isOn: $pinBorder)
            }
            SettingsRow("Keep history",
                        help: "You can restore old files with “Capture History” in the menu bar.") {
                TickSlider(value: Binding(
                    get: { Self.retentionOptions.firstIndex { $0.0 == retention } ?? 3 },
                    set: { retention = Self.retentionOptions[$0].0 }
                ), maxValue: Self.retentionOptions.count - 1,
                           captions: [0: "Never", 1: "1 day", 2: "3 days", 3: "1 week", 4: "1 month"], width: 300)
            }
            SettingsDivider()
            SettingsRow("Text recognition") {
                Picker("Language", selection: $ocrLanguage) {
                    Text("Automatically Detect Language").tag("auto")
                    Divider()
                    ForEach(languages, id: \.id) { Text($0.name).tag($0.id) }
                }.popup()
                Toggle("Keep line breaks", isOn: $keepBreaks)
                Toggle("Detect links", isOn: $detectLinks)
            }
            SettingsDivider()
            SettingsRow("API") {
                HStack(spacing: 6) {
                    Toggle("Allow applications to control Snapframe", isOn: $urlScheme)
                    Button {
                        showActions.toggle()
                    } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Supported actions")
                    .popover(isPresented: $showActions, arrowEdge: .trailing) { actionsPopover }
                }
                HelpText("Lets scripts and other apps trigger actions with URLs such as snapframe://capture-area.")
            }
            SettingsDivider()
            SettingsRow("Reset") {
                Button("Reset All Settings…") { confirmReset = true }
                    .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Reset", role: .destructive) { SettingsReset.perform() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every Snapframe setting and shortcut returns to its default. Your captures and saved Background presets are kept.")
                    }
            }
        }
    }

    private var actionsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Supported actions").font(.headline)
            ForEach(SnapframeAction.allCases) { action in
                Text("snapframe://\(action.rawValue)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(14)
    }
}
