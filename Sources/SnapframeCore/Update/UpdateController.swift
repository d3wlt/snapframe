import AppKit

/// UI side of updates: a quiet automatic check at launch and once a day, "Check for Updates…" from the menu or
/// About tab, and Install & Relaunch after confirmation.
@MainActor
public final class UpdateController: ObservableObject {
    public static let shared = UpdateController()

    public enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case installing
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    private let updater = Updater()
    private var timer: Timer?
    /// True while the install confirmation is on screen; automatic checks wait.
    private var offering = false

    public var isConfigured: Bool { updater.isConfigured }

    /// The version waiting to be installed, if a check found one.
    public var available: UpdateManifest? {
        if case .available(let m) = status { return m }
        return nil
    }

    /// Starts the background schedule: first check 30 s after launch, then every 24 h. Silent unless an update exists.
    public func start() {
        guard updater.isConfigured, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check(userInitiated: false) }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { _ in
            DispatchQueue.main.async { UpdateController.shared.check(userInitiated: false) }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Checks the feed. A user-initiated check always reports its result; an automatic one only announces updates.
    public func check(userInitiated: Bool) {
        guard status != .checking, status != .installing, !offering else { return }
        guard updater.isConfigured else {
            if userInitiated { inform("Updates aren't set up in this build.", detail: nil) }
            return
        }
        let previous = status
        status = .checking
        updater.check { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.status == .checking else { return }
                switch result {
                case .success(let manifest?):
                    self.status = .available(manifest)
                    if userInitiated {
                        self.offer(manifest)
                    } else {
                        Toast.show("Snapframe \(manifest.version) is available", symbol: "arrow.down.circle")
                    }
                case .success(nil):
                    self.status = .upToDate
                    if userInitiated {
                        self.inform("Snapframe is up to date.",
                                    detail: "Version \(self.updater.currentVersion) (\(self.updater.currentBuild)).")
                    }
                case .failure(let error):
                    // A failed background check keeps an update that was already found.
                    if case .available = previous, !userInitiated { self.status = previous } else {
                        self.status = .failed(error.description)
                    }
                    if userInitiated { self.inform("Couldn't check for updates.", detail: error.description) }
                }
            }
        }
    }

    /// Asks to install the found update (menu item "Install Update…").
    public func installAvailable() {
        if let manifest = available { offer(manifest) } else { check(userInitiated: true) }
    }

    /// Work that a restart would throw away.
    private var blockingWork: String? {
        if RecordingController.shared.isBusy { return "Finish the recording first." }
        if AnnotationEditor.hasUnsavedChanges { return "Save or close your annotations first." }
        return nil
    }

    private func offer(_ manifest: UpdateManifest) {
        if let reason = blockingWork {
            inform(reason, detail: "Snapframe restarts to install the update.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snapframe \(manifest.version) is available"
        var detail = "You have version \(updater.currentVersion). Snapframe will restart to finish."
        if let notes = manifest.notes, !notes.isEmpty { detail = notes + "\n\n" + detail }
        if updater.needsAdministrator { detail += "\n\n\(ElevatedInstall.adminNotice)" }
        alert.informativeText = detail
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.window.level = .floating
        offering = true
        let choice = alert.runModal()
        offering = false
        guard choice == .alertFirstButtonReturn else { return }
        install(manifest)
    }

    private func install(_ manifest: UpdateManifest) {
        status = .installing
        Toast.show("Downloading Snapframe \(manifest.version)…", symbol: "arrow.down.circle")
        updater.install(manifest) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success:
                    // Something started during the download: the new version is in place, but don't quit now.
                    if let reason = self.blockingWork {
                        self.status = .idle
                        self.inform("The update is installed.",
                                    detail: "\(reason) Then quit and reopen Snapframe to finish.")
                        return
                    }
                    self.updater.relaunch()
                    NSApp.terminate(nil)
                case .failure(.cancelled):
                    self.status = .available(manifest)  // the admin prompt was cancelled: nothing changed, nothing to report
                case .failure(let error):
                    self.status = .available(manifest)
                    self.inform("The update wasn't installed.", detail: error.description)
                }
            }
        }
    }

    private func inform(_ message: String, detail: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.window.level = .floating
        alert.runModal()
    }
}
