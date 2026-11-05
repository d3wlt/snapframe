import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var note: String?
    @Published private(set) var failed = false

    init() { refresh() }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            enabled = true
            if !failed { note = nil }
        case .requiresApproval:
            enabled = true
            note = "Approve Snapframe in System Settings › General › Login Items."
            failed = false
        default:
            enabled = false
            if !failed { note = nil }
        }
        Prefs.set(enabled, PrefKey.startAtLogin)
    }

    func set(_ on: Bool) {
        failed = false
        note = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failed = true
            note = "Couldn’t change the login item (\(error.localizedDescription)). Move Snapframe to the Applications folder and try again."
        }
        refresh()
    }
}

enum SystemSounds {
    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()
}

struct GeneralTab: View {
    @StateObject private var login = LoginItemModel()
    @AppStorage(PrefKey.playSounds, store: Prefs.store) private var playSounds = false
    @AppStorage(PrefKey.shutterSound, store: Prefs.store) private var shutter = "Default"
    @AppStorage(PrefKey.showMenuBarIcon, store: Prefs.store) private var showMenuBarIcon = true
    @AppStorage(PrefKey.exportLocation, store: Prefs.store) private var exportLocation = ""
    @AppStorage(PrefKey.hideDesktopIcons, store: Prefs.store) private var hideIcons = true

    @AppStorage(PrefKey.afterShotQuickAccess, store: Prefs.store) private var shotQA = true
    @AppStorage(PrefKey.afterShotCopy, store: Prefs.store) private var shotCopy = true
    @AppStorage(PrefKey.afterShotSave, store: Prefs.store) private var shotSave = false
    @AppStorage(PrefKey.afterShotAnnotate, store: Prefs.store) private var shotAnnotate = false
    @AppStorage(PrefKey.afterShotPin, store: Prefs.store) private var shotPin = false
    @AppStorage(PrefKey.afterRecQuickAccess, store: Prefs.store) private var recQA = true
    @AppStorage(PrefKey.afterRecCopy, store: Prefs.store) private var recCopy = true
    @AppStorage(PrefKey.afterRecSave, store: Prefs.store) private var recSave = false
    @AppStorage(PrefKey.afterRecVideoEditor, store: Prefs.store) private var recEditor = true

    var body: some View {
        // Login status can change in System Settings while we're in the background.
        page.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    private var page: some View {
        SettingsPage {
            SettingsRow("Startup") {
                Toggle("Start at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let note = login.note {
                    Text(note).font(.caption).foregroundStyle(login.failed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsRow("Sounds") {
                Toggle("Play sounds", isOn: $playSounds)
            }
            SettingsRow("Shutter sound") {
                Picker("Shutter sound", selection: $shutter) {
                    Text("Default").tag("Default")
                    Divider()
                    ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                }
                .popup()
                .disabled(!playSounds)
                .onChange(of: shutter) { _, new in
                    if new != "Default" { NSSound(named: NSSound.Name(new))?.play() }
                }
            }
            SettingsRow("Menu bar") {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                if !showMenuBarIcon { HelpText("Open Snapframe again to show Settings.") }
            }
            SettingsDivider()
            SettingsRow("Export location") {
                HStack(spacing: 8) {
                    Menu {
                        Button {
                            chooseFolder()
                        } label: { Text("Choose…") }
                    } label: {
                        Label((exportLocation as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    }
                    .menuStyle(.button)
                    .frame(width: 230, alignment: .leading)
                    Button("Show in Finder") { NSWorkspace.shared.open(Prefs.exportDirectory) }
                }
            }
            SettingsRow("Desktop") {
                Toggle("Hide desktop icons while capturing", isOn: $hideIcons)
            }
            SettingsDivider()
            SettingsRow("After capture") {
                afterCaptureGrid
            }
        }
    }

    private var afterCaptureGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
            GridRow {
                Text("Screenshot").gridColumnAlignment(.center)
                Text("Recording").gridColumnAlignment(.center)
                Text("Action")
            }
            .font(.caption).foregroundStyle(.secondary)
            GridRow { Divider().gridCellColumns(3) }
            row("Show Quick Access Overlay", $shotQA, $recQA)
            row("Copy file to clipboard", $shotCopy, $recCopy)
            row("Save", $shotSave, $recSave)
            row("Open Annotate tool", $shotAnnotate, nil)
            row("Pin to the screen", $shotPin, nil)
            row("Open editor (trim)", nil, $recEditor)
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ shot: Binding<Bool>?, _ rec: Binding<Bool>?) -> some View {
        GridRow {
            cell(shot, "\(title) after screenshots")
            cell(rec, "\(title) after recordings")
            Text(title)
        }
    }

    @ViewBuilder
    private func cell(_ binding: Binding<Bool>?, _ label: String) -> some View {
        if let binding {
            Toggle(label, isOn: binding).labelsHidden()
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = Prefs.exportDirectory
        if panel.runModal() == .OK, let url = panel.url { exportLocation = url.path }
    }
}
