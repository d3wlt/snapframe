import AppKit
import AVFoundation
import SwiftUI

struct AboutTab: View {
    @ObservedObject private var updates = UpdateController.shared
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        SettingsPage {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                Text("Snapframe").font(.system(size: 22, weight: .semibold))
                Text(version).font(.caption).foregroundStyle(.secondary)
                Text("Screenshots and screen recordings, right from your menu bar.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 2)
                if updates.isConfigured {
                    HStack(spacing: 8) {
                        Button(updates.available.map { "Install Update \($0.version)…" } ?? "Check for Updates…") {
                            updates.installAvailable()
                        }
                        .disabled(updates.status == .checking || updates.status == .installing)
                        if let line = updateStatusLine {
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            SettingsDivider()
            Text("Permissions").font(.headline)
            VStack(spacing: 10) {
                permissionRow("Screen Recording", "rectangle.dashed.badge.record", screen ? .granted : .missing,
                              help: "Required to capture the screen.") {
                    if !CGRequestScreenCaptureAccess() { SystemSettingsPane.open(SystemSettingsPane.screenRecording) }
                }
                permissionRow("Accessibility", "keyboard", accessibility ? .granted : .optional,
                              help: "Only needed to show keystrokes in recordings.") {
                    SystemSettingsPane.open(SystemSettingsPane.accessibility)
                }
                permissionRow("Microphone", "mic", micState,
                              help: "Only needed to record your voice.") {
                    if mic == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { mic = AVCaptureDevice.authorizationStatus(for: .audio) }
                        }
                    } else {
                        SystemSettingsPane.open(SystemSettingsPane.microphone)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screen = CGPreflightScreenCaptureAccess()
            accessibility = AXIsProcessTrusted()
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var updateStatusLine: String? {
        switch updates.status {
        case .checking: return "Checking…"
        case .installing: return "Installing…"
        case .upToDate: return "Up to date"
        case .failed: return "Last check failed"
        case .idle, .available: return nil
        }
    }

    private enum PermissionState { case granted, missing, optional, notAsked }

    private var micState: PermissionState {
        switch mic {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .optional
        }
    }

    private func permissionRow(_ title: String, _ symbol: String, _ state: PermissionState, help: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Label("Not granted", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Open Settings…", action: action)
            case .optional:
                Label("Not granted", systemImage: "minus.circle").foregroundStyle(.secondary)
                Button("Open Settings…", action: action)
            case .notAsked:
                Label("Not asked yet", systemImage: "minus.circle").foregroundStyle(.secondary)
                Button("Allow…", action: action)
            }
        }
    }
}
